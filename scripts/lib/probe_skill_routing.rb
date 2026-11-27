#!/usr/bin/env ruby
# frozen_string_literal: true

# skill routing acceptance harness の probe runner (実機・#280 A-1)。
# Spec: docs/skill-routing-acceptance.md。
#
# 候補 skill 一式だけが見える隔離 project を一時 directory に作り、case set の各 prompt を
# claude / codex の headless 実行に流して「どの skill が発火したか」と token 使用量を観測し、
# 判定コア (check_skill_routing.rb) の入力 results.json を生成する。
#
# 責務境界 (honest):
#   - runner は「観測」だけを行う。判定は check-skill-routing.sh、緑/赤の解釈は人間の責務。
#   - probe 自身は tool home (~/.claude / ~/.codex) に書き込まない。claude-code の子 process には自動の memory を止める環境を
#     渡す (#770。止めないと、run ごとに ~/.claude/projects の下に dir ができる)。CLI 自身が home に置く状態の file (認証・
#     cache・log など) は見ていない。候補 skill は project scope
#     (claude-code: <proj>/.claude/skills、codex: <proj>/.agents/skills) に copy し、claude-code は
#     --setting-sources project で user scope の skill を外し、codex は候補と同名の user skill を
#     skills.config の -c override で無効化する (どちらも実測済み。docs 参照)。
#   - 外部へ書ける経路を残さない: claude-code は MCP を読まず (--strict-mcp-config)、codex は監査 / review
#     と同じ境界 (--ignore-user-config / --ignore-rules / --disable apps 等) で起動し、起動の前に flag と
#     feature の在否を確かめる (#372)。case の prompt は PR への書き込みなどを頼むものを含むため。
#   - CI では実行しない (CLI 認証と network が要る)。hard な証跡は raw log (<out>.raw/) と
#     PR / Issue に貼る summary。CI 緑を根拠にしない。
#   - 観測は CLI の event stream に依存する。field 名が変わると observed が空になる。全 run で空なら judge は観測の
#     全損として exit 2 にするが、一部の run だけなら primary MISS として現れるだけで exit 0 のままになりうる
#     (#582)。--smoke で listing と event 形式を先に確認する。
#   - --max-turns の打ち切りは観測完了として扱う (routing の判断は最初の turn の Skill 起動で
#     出る。skill が起動した後の作業は観測対象外なので、続きを走らせない)。
#   - codex には --max-turns 相当が無い。--timeout で打ち切った run だけに、skill を読んでから作業に入った印
#     (CODEX_ROUTING_GAP) を当て、立っていれば観測完了 (observed-stop) にする (#302)。
#
# prompt / path は shell 文字列に埋め込まず argv 配列と stdin で渡す (#266 の欠陥クラスを
# 持ち込まない)。

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "time"
require_relative "auto_memory"
require_relative "check_skill_routing"
require_relative "probe_child"
require_relative "yaml_util"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
# この entrypoint は cli.rb (#418 の固定) を require しないので、同じ固定を各自で持つ。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ProbeSkillRouting
  class Error < StandardError; end

  TOOLS = %w[claude-code codex].freeze
  # tool ごとの project scope の skill 置き場 (公式 docs の repository-level path)。
  PROJECT_SKILL_DIRS = {
    "claude-code" => File.join(".claude", "skills"),
    "codex" => File.join(".agents", "skills"),
  }.freeze
  SMOKE_PROMPT = "あなたが今使える skill の name を、カンマ区切りで全部列挙して。他の文は書かない。"

  # --- reads: 読んだ skill の痕跡の全部 (#720) -----------------------------------------------
  # observed (primary の推定。Codex は探索読みを圧縮する) とは別に、読み取りの痕跡を全部残す。judge は must_not を
  # これでも見て、observed に無い痕跡を「要確認」にする。痕跡は入力の文字列 (command・Read の file_path) に現れた
  # SKILL.md だけで、出力は見ない。痕跡が無いことは、読まなかった証明ではない。
  # 要素: skill (名前を決められなければ nil)、path (現れた表記)、via (skill・read・command)、copy、sha256。
  # copy: candidate (実体が候補の SKILL.md)・same-content (別の置き場で中身が同じ)・other (中身が違う)・
  # unknown (file に解決できない・名前を決められない)・listing (Claude Code の Skill の呼び出し。listing の skill)。
  READ_VIAS = %w[skill read command].freeze
  READ_COPIES = %w[candidate same-content other unknown listing].freeze
  # SKILL.md の直前の path の切れ目。空白・引用符・shell の区切りの記号で切る (引用の中の空白は扱わない)。
  PATH_BREAK = /[\s"'`;|&<>()=]/.freeze

  # text に現れた SKILL.md ごとに [skill 名か nil, path の表記] を返す。名前は今の observed と同じ規則
  # (直前が `/<name>/`) で決めるので、observed の名前は必ず reads に入る。
  def self.skill_md_mentions(text, names)
    return [] unless text.is_a?(String) && text.include?("SKILL.md")

    tail = names.empty? ? nil : %r{/(#{names.map { |n| Regexp.escape(n) }.join('|')})/SKILL\.md\z}
    found = []
    offset = 0
    while (i = text.index("SKILL.md", offset))
      stop = i + "SKILL.md".length
      prefix = text[0...stop]
      name = tail && (m = tail.match(prefix)) ? m[1] : nil
      start = prefix.rindex(PATH_BREAK)
      found << [name, prefix[(start ? start + 1 : 0)..]]
      offset = stop
    end
    found
  end

  # path の表記を file に解決して copy を決める。~/・$HOME/・${HOME}/ は home で、相対の path は proj から解き、
  # realpath (symlink と .. を解く) の実体で比べる。字面では決めない。解決できなければ unknown。
  def self.classify_copy(name, path, proj:, home:, tool:)
    return ["unknown", nil] if name.nil? || proj.nil? || path.nil?

    expanded = path.sub(%r{\A(?:~|\$HOME|\$\{HOME\})(?=/)}) { home.to_s }
    return ["unknown", nil] if expanded.start_with?("~", "$") || expanded.match?(/[$`]/) || (home.nil? && expanded != path)

    # File.expand_path は .. を字面で消す (symlink を解く前で、存在しない中間の dir も通す) ので使わない。
    # 字面の正規化をせずに proj とつなぎ、realpath に .. を実体の上で解かせる (中間の dir が無ければ失敗する)。
    real = begin
      File.realpath(expanded.start_with?("/") ? expanded : File.join(proj, expanded))
    rescue SystemCallError
      nil
    end
    return ["unknown", nil] unless real && File.file?(real)

    sha = Digest::SHA256.file(real).hexdigest
    candidate = begin
      File.realpath(File.join(proj, PROJECT_SKILL_DIRS.fetch(tool), name, "SKILL.md"))
    rescue SystemCallError
      nil
    end
    return ["candidate", sha] if candidate && real == candidate

    [candidate && Digest::SHA256.file(candidate).hexdigest == sha ? "same-content" : "other", sha]
  end

  def self.read_entry(name, path, via, proj:, home:, tool:)
    copy, sha = classify_copy(name, path, proj: proj, home: home, tool: tool)
    { "skill" => name, "path" => path, "via" => via, "copy" => copy, "sha256" => sha }
  end
  DEFAULT_MAX_TURNS = 2
  DEFAULT_TIMEOUT = 300
  # Codex の起動で disable する feature と、起動の前に `codex exec --help` で確かめる flag (#372)。
  CODEX_DISABLE_FEATURES = %w[apps computer_use browser_use].freeze
  CODEX_HELP_MARKERS = %w[--ignore-user-config --ignore-rules --disable].freeze

  USAGE = <<~TEXT
    usage: probe-skill-routing.sh --tool <claude-code|codex> --out <results.json>
             [--source DIR] [--cases FILE] [--variant LABEL] [--model MODEL] [--repeat N]
             [--only ID[,ID...]] [--max-turns N] [--timeout SEC] [--codex-home DIR] [--dry-run] [--smoke]

      --tool      観測対象の CLI (claude-code = `claude -p`, codex = `codex exec`)
      --out       results.json の出力先。raw log は <out>.raw/ に残す (judge の証跡)
      --source    候補 skill dir の親 (既定: generated/<tool>/skills。build 済みであること)
      --cases     case set (既定: scripts/lib/skill_routing_cases.json)
      --variant   結果に付ける label (既定: candidate。baseline を測るときは baseline 等)
      --model     CLI に渡す model (baseline と candidate で揃えること)。claude-code は省略すると CLI の既定。
                  codex は省略すると Codex home ($CODEX_HOME、未設定なら ~/.codex) の config.toml の top-level の
                  model を使い、それも無ければエラー (CLI の既定には任せない)
      --repeat    各 case の実行回数 (既定: 1)
      --only      実行する case id (comma 区切り)。coverage が欠けるので判定は exit 2 になる
      --max-turns claude-code の --max-turns (既定: #{DEFAULT_MAX_TURNS})
      --timeout   1 run の上限秒 (既定: #{DEFAULT_TIMEOUT})
                  codex で上限に達した run は、skill を読んでから作業に入った印があれば観測完了
                  (completion: observed-stop、token は取らない)。無ければ error
      --codex-home 評価用の Codex の home (codex の run では必須。--dry-run では省ける)。人がその dir で
                  一度ログインしておく。子の CODEX_HOME にこれを、子の HOME に run ごとの空の dir を渡す (#802)。
                  model の取得はふだんの Codex home のまま。条件は docs/skill-routing-acceptance.md の「隔離」
      --dry-run   隔離 project の配置と実行 argv を表示して終了 (CLI を起動しない)
      --smoke     case set の代わりに「見えている skill を列挙する」prompt を 1 回流し、
                  隔離と event 形式を確認する (results.json は書かない)

    exit: 0 = 観測完了 (判定は check-skill-routing.sh), 2 = usage / 入力 / 環境エラー
  TEXT

  # --- 引数 -------------------------------------------------------------------------

  def self.parse_argv(argv)
    opts = { repeat: 1, max_turns: DEFAULT_MAX_TURNS, timeout: DEFAULT_TIMEOUT, variant: "candidate" }
    i = 0
    while i < argv.length
      key = argv[i]
      case key
      when "--tool", "--out", "--source", "--cases", "--variant", "--model", "--only", "--codex-home"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")
        opts[key.delete_prefix("--").tr("-", "_").to_sym] = value
        i += 2
      when "--repeat", "--max-turns", "--timeout"
        value = argv[i + 1]
        raise Error, "#{key} requires a positive integer" unless value&.match?(/\A[1-9][0-9]*\z/)
        opts[key.delete_prefix("--").tr("-", "_").to_sym] = value.to_i
        i += 2
      when "--dry-run"
        opts[:dry_run] = true
        i += 1
      when "--smoke"
        opts[:smoke] = true
        i += 1
      else
        raise Error, "unknown argument: #{key}"
      end
    end
    raise Error, "--tool is required" unless opts[:tool]
    raise Error, "--tool must be one of #{TOOLS.join(', ')}" unless TOOLS.include?(opts[:tool])
    raise Error, "--out is required" unless opts[:out] || opts[:dry_run] || opts[:smoke]
    raise Error, "--codex-home is only for --tool codex" if opts[:codex_home] && opts[:tool] != "codex"
    if opts[:tool] == "codex" && !opts[:codex_home] && !opts[:dry_run]
      raise Error, "--codex-home is required for --tool codex (an eval-only Codex home; docs/skill-routing-acceptance.md)"
    end
    opts
  end

  # --- 隔離 project -----------------------------------------------------------------

  def self.source_dir(opts, root)
    dir = opts[:source] || File.join(root, "generated", opts[:tool], "skills")
    raise Error, "source dir not found: #{dir} (run scripts/build.sh first)" unless File.directory?(dir)
    dir
  end

  # source 配下の skill dir (SKILL.md を持つ直下 dir) を名前順で返す。
  def self.skill_dirs(source)
    dirs = Dir.children(source).sort.map { |n| File.join(source, n) }
                .select { |d| File.directory?(d) && File.file?(File.join(d, "SKILL.md")) }
    raise Error, "no skill (dir with SKILL.md) under #{source}" if dirs.empty?
    dirs
  end

  # frontmatter の description を取り出す (listing の静的 context 量の指標用)。
  # frontmatter を YAML として読み、配布先の parser が読むのと同じ値の文字数を数える (#417。行の字面を数えると、
  # YAML のコメントで切れた description を全文の長さで数える)。frontmatter が無い / description が文字列でない
  # skill は 0 文字として数える。形の検査 (コメントによる切り詰めを含む) は check-manifests が正本で、ここでは
  # gate しない (切れた description の before も測れるように)。YAML として読めなければ数えられないので止める。
  def self.description_length(skill_md)
    text = File.read(skill_md)
    # check-manifests (validate_skill_entrypoint) と同じ切り出し方にする (block scalar の末尾の改行も同じに読む)
    return 0 unless text.start_with?("---\n", "---\r\n")

    parts = text.sub(/\A---\r?\n/, "").split(/^---\r?\n/, 2)
    return 0 if parts.length < 2

    data = begin
      YamlUtil.safe_load(parts[0], skill_md)
    rescue Psych::Exception => e
      raise Error, "#{skill_md}: frontmatter を YAML として読めない (#{e.message})"
    end
    description = data.is_a?(Hash) ? data["description"] : nil
    description.is_a?(String) ? description.length : 0
  end

  def self.prepare_project(base, tool, dirs)
    proj = File.join(base, "proj")
    target = File.join(proj, PROJECT_SKILL_DIRS.fetch(tool))
    FileUtils.mkdir_p(target)
    dirs.each { |d| FileUtils.cp_r(d, File.join(target, File.basename(d))) }
    proj
  end

  # --- adapter: claude-code -----------------------------------------------------------

  # --strict-mcp-config (かつ --mcp-config 無し) で MCP server を読まない。headless では MCP の
  # 起動が最初の API call に間に合うかが run ごとに揺れ、tool 定義の分だけ prompt 量が変わる
  # (baseline の実測で 25 tool / 72 tool の 2 群に割れ、first_prompt_tokens に ±2.7k の差が出た)。
  # routing の観測に MCP は不要なので、条件を固定する側に倒す。
  def self.claude_argv(opts, prompt)
    argv = ["claude", "-p", "--setting-sources", "project", "--strict-mcp-config",
            "--output-format", "stream-json", "--verbose",
            "--max-turns", opts[:max_turns].to_s, "--no-session-persistence"]
    argv += ["--model", opts[:model]] if opts[:model]
    argv + [prompt]
  end

  # prompt 側の token として合算する usage の key (input + cache_creation + cache_read。skill
  # listing は system prompt 側なので cache に現れる)。
  PROMPT_USAGE_KEYS = %w[input_tokens cache_creation_input_tokens cache_read_input_tokens].freeze

  # stream-json を読んで observed / token / model を取り出す (2.1.277 で実測した形)。
  # - Skill tool の起動: type=assistant の content[].tool_use で name == "Skill"。skill 名は
  #   input.skill (無ければ input.name)。
  # - first_prompt_tokens: 最初の assistant message の usage の prompt 合計 = 最初の API call の
  #   context 量。listing (description) の大きさが最も素直に出る指標。
  # - prompt_tokens / output_tokens: type=result の usage (run 全体の合計。turn 数に依存する)。usage が取れなければ
  #   nil (観測不能)。
  # - subtype: result の subtype。error_max_turns は打ち切りであって観測失敗ではない。
  # - memory_states: init ごとの、自動の memory の状態 (memory_paths から。#770)。
  # reads (#720): Skill の呼び出し (copy は listing)、Read の file_path と Bash の command に現れた SKILL.md。
  # names・proj・home は copy の判定に使う (無ければ名前を決められない読み取りと unknown になる)。
  def self.parse_claude(jsonl, names: [], proj: nil, home: nil)
    observed = []
    reads = []
    model = nil
    prompt_tokens = output_tokens = first_prompt_tokens = nil
    subtype = nil
    memory_states = []
    text = +""
    jsonl.each_line do |line|
      e = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless e.is_a?(Hash)

      case e["type"]
      when "system"
        model ||= e["model"] if e["model"].is_a?(String)
        memory_states << AutoMemory.state(e) if e["subtype"] == "init"
      when "assistant"
        if first_prompt_tokens.nil?
          u = e.dig("message", "usage")
          first_prompt_tokens = sum_usage(u, PROMPT_USAGE_KEYS) if u.is_a?(Hash)
        end
        content = e.dig("message", "content")
        next unless content.is_a?(Array)
        content.each do |c|
          next unless c.is_a?(Hash)
          if c["type"] == "tool_use" && c["name"] == "Skill"
            input = c["input"].is_a?(Hash) ? c["input"] : {}
            name = input["skill"] || input["name"]
            if name.is_a?(String)
              observed << name
              reads << { "skill" => name, "path" => nil, "via" => "skill", "copy" => "listing", "sha256" => nil }
            end
          elsif c["type"] == "tool_use" && %w[Read Bash].include?(c["name"])
            input = c["input"].is_a?(Hash) ? c["input"] : {}
            if c["name"] == "Read"
              path = input["file_path"]
              if path.is_a?(String) && path.end_with?("SKILL.md")
                tail = names.empty? ? nil : %r{(?:\A|/)(#{names.map { |n| Regexp.escape(n) }.join('|')})/SKILL\.md\z}
                name = tail && (m = tail.match(path)) ? m[1] : nil
                reads << read_entry(name, path, "read", proj: proj, home: home, tool: "claude-code")
              end
            else
              skill_md_mentions(input["command"], names).each do |name, path|
                reads << read_entry(name, path, "command", proj: proj, home: home, tool: "claude-code")
              end
            end
          elsif c["type"] == "text" && c["text"].is_a?(String)
            text << c["text"]
          end
        end
      when "result"
        # usage が無い・input_tokens / output_tokens が整数でない result は観測不能として nil にする (run_one が
        # error にする。key が在って 0 の正当な 0 token とは区別する。#516)。cache の token は在るときだけ足す。
        u = e["usage"]
        if u.is_a?(Hash) && u["input_tokens"].is_a?(Integer) && u["output_tokens"].is_a?(Integer)
          prompt_tokens = sum_usage(u, PROMPT_USAGE_KEYS)
          output_tokens = u["output_tokens"]
        else
          prompt_tokens = output_tokens = nil
        end
        subtype = e["subtype"] if e["subtype"].is_a?(String)
        text = e["result"] if text.empty? && e["result"].is_a?(String)
      end
    end
    { observed: observed.uniq, model: model, prompt_tokens: prompt_tokens, output_tokens: output_tokens,
      first_prompt_tokens: first_prompt_tokens, subtype: subtype, text: text, note: nil, memory_states: memory_states,
      reads: reads }
  end

  def self.sum_usage(usage, keys)
    keys.sum { |k| usage[k].is_a?(Integer) ? usage[k] : 0 }
  end

  # --- adapter: codex (Codex CLI 0.153.4 で実測) ---------------------------------------------

  # codex は user scope (~/.codex/skills) の skill を、project scope に同名の skill があっても両方
  # listing に載せる (0.153.4 で実測。--ignore-user-config でも消えない)。候補と同名の user skill を
  # skills.config (path 単位の enabled=false) の -c override で無効化し、listing に候補だけが載る
  # ようにする。他の user skill / plugin skill は実環境に合わせて残す (両 variant に等しく載る)。
  # model は event に出ないので -m で明示し、results.json に記録する値と一致させる。
  # 境界 (#372): case の prompt には PR への書き込みを頼むものがあり、read-only の sandbox は MCP /
  # connector の tool の呼び出しを止めない。監査 / review の起動と同じく、user config (MCP server、
  # bootstrap の MCP) と execpolicy の rules を読まず、sandbox の外へ届く feature を disable する。
  # user config を読まないので effort は Codex の既定になり、plugin skill は listing から消える
  # (どちらも baseline と candidate に等しく効く)。
  def self.codex_argv(opts, proj, names)
    argv = ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules", "-s", "read-only", "-c", 'approval_policy="never"']
    CODEX_DISABLE_FEATURES.each { |f| argv.push("--disable", f) }
    argv.push("-C", proj, "-m", codex_model(opts))
    disable = codex_disable_override(names, opts[:codex_home])
    argv += ["-c", disable] if disable
    argv + ["-"]
  end

  # 起動の前に、境界の flag が `codex exec --help` に在り、disable する feature の行が
  # `codex features list` に在ることを確かめる。どちらも exit 0 のときだけ出力を信じ、欠けていれば
  # 存在しない flag を試さずに止める (無い feature を --disable に渡すと CLI が止まる)。
  # env は子 process にだけ足す環境 (behavior の probe が評価用の Codex の home を渡す。#731)。
  def self.codex_preflight!(env: nil)
    help = capture_ok(%w[codex exec --help], env: env)
    raise Error, "codex: `codex exec --help` failed" unless help

    missing = CODEX_HELP_MARKERS.reject { |m| help.include?(m) }
    raise Error, "codex: exec lacks boundary flag(s): #{missing.join(', ')}" unless missing.empty?

    features = capture_ok(%w[codex features list], env: env)
    raise Error, "codex: `codex features list` failed" unless features

    listed = features.each_line.map { |l| l.split.first }
    absent = CODEX_DISABLE_FEATURES - listed
    raise Error, "codex: features list lacks feature(s) to disable: #{absent.join(', ')}" unless absent.empty?
  end

  def self.capture_ok(argv, env: nil)
    out, status = env ? Open3.capture2e(env, *argv) : Open3.capture2e(*argv)
    status.success? ? out : nil
  rescue SystemCallError
    nil
  end

  # codex の子 process にだけ渡す環境 (#802)。CODEX_HOME は評価用の home、HOME は run ごとの空の dir。親の process の
  # 環境は変えない (PATH などはそのまま継ぐ)。
  def self.codex_env(opts, home)
    { "CODEX_HOME" => opts.fetch(:codex_home), "HOME" => home }
  end

  # 空の dir を作って HOME に使い、終わったら消す (#802)。Dir.mktmpdir は mode 0700 で作る。temp project とは別の
  # 置き場。消せなければ残った path を warn に出す (子は read-only の sandbox なので、ふつうは中身が増えない)。
  def self.with_empty_home(prefix)
    dir = Dir.mktmpdir(prefix)
    yield dir
  ensure
    if dir
      begin
        FileUtils.remove_entry(dir)
      rescue SystemCallError => e
        warn "warn: could not remove the empty home #{dir} (#{e.class})"
      end
    end
  end

  # 親の process のふだんの Codex home (model の取得と、評価用の home がこれと別の実体かの照合に使う。#802)。
  # 子の Codex には渡さない (子の CODEX_HOME は --codex-home の評価用の home)。
  def self.codex_home
    ENV["CODEX_HOME"] || File.join(Dir.home, ".codex")
  end

  # 評価用の Codex の home に在ってはいけない file (大文字小文字を区別しない。#731)。
  EVAL_HOME_FORBIDDEN = %w[agents.md agents.override.md].freeze

  # 評価用の Codex の home を確かめ、実 path を返す (#731。#802 で routing の probe と共有)。auth.json の中身は読まない。
  def self.eval_codex_home!(dir)
    raise Error, "--codex-home must be an absolute path" unless dir.start_with?("/")

    st = begin
      File.lstat(dir)
    rescue Errno::ENOENT
      raise Error, "--codex-home does not exist"
    end
    raise Error, "--codex-home must not be a symlink" if st.symlink?
    raise Error, "--codex-home must be a directory" unless st.directory?

    real = File.realpath(dir)
    usual = codex_home
    # 文字列ではなく実体で比べる (大文字小文字を区別しない file system では、同じ dir の実 path の表記が変わりうる)
    if File.exist?(usual) && File.identical?(usual, real)
      raise Error, "--codex-home must not be the usual Codex home"
    end

    auth = begin
      File.lstat(File.join(real, "auth.json"))
    rescue Errno::ENOENT
      raise Error, "--codex-home has no auth.json (log in once with CODEX_HOME set to the dir)"
    end
    raise Error, "--codex-home: auth.json must be a regular file" unless auth.file?

    found = Dir.children(real).select { |n| EVAL_HOME_FORBIDDEN.include?(n.downcase) }
    raise Error, "--codex-home must not have #{found.sort.join(', ')}" unless found.empty?

    skills = File.join(real, "skills")
    if File.symlink?(skills)
      raise Error, "--codex-home: skills must not be a symlink"
    elsif File.directory?(skills)
      user = Dir.children(skills).reject { |n| n.start_with?(".") }
      raise Error, "--codex-home must not have user skills (#{user.length} under skills/)" unless user.empty?
    elsif File.exist?(skills)
      raise Error, "--codex-home: skills must be a directory"
    end
    real
  rescue SystemCallError => e
    raise Error, "--codex-home could not be checked (#{e.class})"
  end

  # 各 codex exec の前に、評価用の home を検査し直し、最初に確かめた dir と同じ実体かも確かめる (#731。review の
  # round 1)。run の間に AGENTS.md や skill が足された、dir を差し替えられた、のどれでも起動せずに止める。
  def self.recheck_codex_home!(opts)
    real = eval_codex_home!(opts[:codex_home])
    st = File.stat(real)
    return if real == opts[:codex_home] && [st.dev, st.ino] == opts[:codex_home_id]

    raise Error, "--codex-home changed during the probe"
  rescue SystemCallError => e
    raise Error, "--codex-home could not be checked (#{e.class})"
  end

  # --model が無ければ $CODEX_HOME/config.toml の top-level model を使う。どちらも無ければ
  # エラー (model 不明のまま比較しない)。top-level は最初の table header より前で、profile 等の
  # table の model は読まない (probe は --ignore-user-config で起動するので、Codex 側も profile を
  # 解釈し直さない)。
  def self.codex_model(opts)
    return opts[:model] if opts[:model]

    config = File.join(codex_home, "config.toml")
    if File.file?(config)
      File.foreach(config) do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")
        break if stripped.start_with?("[")

        m = line.match(/\A\s*model\s*=\s*"([^"]+)"/)
        return m[1] if m
      end
    end
    raise Error, "codex: --model is required (no top-level model in #{config})"
  end

  # 子の Codex home (--codex-home) の user scope に候補と同名の skill があれば無効にする。評価用の home は user の
  # skill を持てない (eval_codex_home!) ので、ふつうは空。home が無い (--dry-run で省いた) ときも空。
  def self.codex_disable_override(names, child_codex_home)
    return nil unless child_codex_home

    entries = names.map do |n|
      path = File.join(child_codex_home, "skills", n, "SKILL.md")
      next unless File.file?(path)

      "{path=\"#{toml_escape(path)}\",enabled=false}"
    end.compact
    entries.empty? ? nil : "skills.config=[#{entries.join(',')}]"
  end

  # TOML basic string の escape (path に backslash / 二重引用符が含まれても壊れないように)。
  def self.toml_escape(s)
    s.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
  end

  # codex で「探索読み」とみなす閾値: 1 run で inventory のこれ以上の skill の SKILL.md を読んだら、
  # routing の判断ではなく skill 一覧の把握とみなし、最初に読んだ skill だけを observed にする
  # (残りは note に残す)。Claude Code の Skill tool 呼び出しと違い、codex は file を読むだけなので
  # 安価に全部読める run がある (baseline 24 run 中 1 run が 12 本すべてを順に読んだ)。
  CODEX_SURVEY_THRESHOLD = 6

  # codex の「routing の判断が終わった」印 (#302): 候補 skill の SKILL.md を読んだ後に、SKILL.md を読まない tool の
  # item がこの数だけ続いた (skill を読んでから作業に入った)。--timeout で打ち切った run だけに使い、満たせば観測完了
  # (completion: observed-stop) に数える。tool の item は下の type の item.completed で、agent_message などは数にも
  # 数え直しにも入れない。SKILL.md を含む command (候補か否か、前に / があるかを問わない。`cd <dir> && cat SKILL.md`
  # の形を含む) は数を 0 に戻す。知らない type は数えない
  # (条件を満たしにくくする向き)。2026-09-21 の raw log (48 run) で当てて、observed が変わるのは 1 run だけだった。
  CODEX_ROUTING_GAP = 2
  CODEX_TOOL_ITEM_TYPES = %w[command_execution file_change mcp_tool_call web_search].freeze

  # codex exec --json の event (0.153.4 で実測): thread.started / turn.started / item.started /
  # item.completed (item.type = agent_message | command_execution | error ...) / turn.completed
  # (usage: input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, ...)。
  # - observed: command_execution の **command 文字列** に `/<name>/SKILL.md` が現れた skill (読んだ順、
  #   重複なし)。scope は問わない: listing から外した user scope (~/.codex/skills/<name>/) や
  #   `.system/../<name>/` を model が推測して読む run が実測で多く、project path だけでは起動を
  #   取りこぼす。出力 (aggregated_output) は見ない (ls の結果に全 skill の path が並ぶと誤検知する)。
  # - prompt_tokens / output_tokens: turn.completed の usage。turn 内の全 API call の合計で、最初の
  #   call だけの値は event に無いので first_prompt_tokens は取らない (judge では n/a)。
  # - text: 最後の agent_message。model は event に出ない (caller が argv の値を使う)。
  # - routing_done: 上の CODEX_ROUTING_GAP の印が立ったか (一度立てば、後の読み取りで戻さない)。
  # - reads (#720): 上の observed の圧縮の前の、SKILL.md の読み取りの痕跡の全部 (重複を除かない。名前を決められない
  #   `cd <dir> && cat SKILL.md` の形も skill を nil にして残す)。proj と home は copy の判定に使う。
  def self.parse_codex(jsonl, names, proj: nil, home: nil)
    reads = []
    all_reads = []
    usage = nil
    text = +""
    gap = 0
    routing_done = false
    pattern = %r{/(#{names.map { |n| Regexp.escape(n) }.join('|')})/SKILL\.md}
    jsonl.each_line do |line|
      e = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless e.is_a?(Hash)

      case e["type"]
      when "item.completed"
        item = e["item"].is_a?(Hash) ? e["item"] : {}
        if item["type"] == "agent_message"
          text = item["text"] if item["text"].is_a?(String)
        elsif CODEX_TOOL_ITEM_TYPES.include?(item["type"])
          command = item["type"] == "command_execution" && item["command"].is_a?(String) ? item["command"] : ""
          command.scan(pattern) { |(name)| reads << name unless reads.include?(name) }
          skill_md_mentions(command, names).each do |name, path|
            all_reads << read_entry(name, path, "command", proj: proj, home: home, tool: "codex")
          end
          if command.include?("SKILL.md")
            gap = 0
          elsif !reads.empty?
            gap += 1
            routing_done ||= gap >= CODEX_ROUTING_GAP
          end
        end
      when "turn.completed"
        usage = e["usage"] if e["usage"].is_a?(Hash)
      end
    end
    observed = reads
    note = nil
    if reads.length >= CODEX_SURVEY_THRESHOLD
      observed = reads.first(1)
      note = "survey: read #{reads.length} skills (#{reads.join(', ')}); counted the first only"
    end
    prompt_tokens = usage && usage["input_tokens"].is_a?(Integer) ? usage["input_tokens"] : nil
    output_tokens = usage && usage["output_tokens"].is_a?(Integer) ? usage["output_tokens"] : nil
    { observed: observed, model: nil, prompt_tokens: prompt_tokens, output_tokens: output_tokens,
      first_prompt_tokens: nil, subtype: nil, text: text, note: note, routing_done: routing_done, reads: all_reads }
  end

  # --- 実行 -------------------------------------------------------------------------

  # argv を配列のまま起動し、timeout を超えたら kill する。ProbeChild の Result (out / err / status / completed /
  # drained) をそのまま返す。process group の起動・期限・中断を含む後片付けは ProbeChild が持つ (#568)。
  def self.run_command(argv, chdir:, stdin:, timeout:, env: {})
    # 入れ子起動の guard 変数を外す (Claude Code の Bash から起動された場合)。env は子 process に足す環境。
    env = { "CLAUDECODE" => nil, "CLAUDE_CODE_ENTRYPOINT" => nil }.merge(env)
    ProbeChild.run(argv, env: env, chdir: chdir, stdin: stdin, timeout: timeout)
  end

  # run の終わり方 (results.json の completion)。ok に数えるのは OK_COMPLETIONS の 3 つだけ。
  # - exited / max-turns: 終了の状態が取れていて (timeout で kill した run と stream を読み切れなかった run は取れない)、
  #   usage が取れていて、CLI が正常終了したか、--max-turns の打ち切り (claude-code の result.subtype ==
  #   "error_max_turns")。打ち切りは routing の判断 (最初の turn の Skill 起動) を観測した後に起きるので観測失敗では
  #   ない。打ち切りの result があっても、終了の状態が取れない run はここに入らない (#516)。
  # - observed-stop (#302): codex の run が --timeout で打ち切られ、stdout を読み切れていて、打ち切りの前に
  #   routing_done (CODEX_ROUTING_GAP) が立った。打ち切りの run の usage は信用しないので token は取らない。
  # - timeout: 打ち切った run で、observed-stop の条件 (読み切れた・印が立った) を満たさないもの。
  # - failed: 期限の中で終わった run で、exited / max-turns に当たらないもの (非ゼロ終了・usage なし・読み切れない)。
  #   終わり方は、期限の中で終わった run (exited / max-turns / failed) と打ち切った run (observed-stop / timeout) に
  #   分かれる。認証 / API エラー等の
  #   非ゼロ終了を、skill の読み取りが見えたことだけで ok にしない。
  OK_COMPLETIONS = %w[exited max-turns observed-stop].freeze

  def self.completion(tool, result, parsed)
    status = result.completed && result.drained ? result.status : nil
    usage = parsed[:prompt_tokens] && parsed[:output_tokens]
    if status && usage && status.success?
      "exited"
    elsif status && usage && parsed[:subtype] == "error_max_turns"
      "max-turns"
    elsif !result.completed && result.drained && tool == "codex" && parsed[:routing_done]
      "observed-stop"
    elsif !result.completed
      "timeout"
    else
      "failed"
    end
  end

  def self.run_one(opts, proj, names, prompt)
    if opts[:tool] == "claude-code"
      argv = claude_argv(opts, prompt)
      r = run_command(argv, chdir: proj, stdin: nil, timeout: opts[:timeout], env: AutoMemory::ENV_OFF)
      parsed = parse_claude(r.out, names: names, proj: proj, home: Dir.home)
    else
      # 起動の前に評価用の home を検査し直す (#802。挙動の評価と同じ)。copy の判定の ~ は子の HOME で展開する。
      recheck_codex_home!(opts)
      argv = codex_argv(opts, proj, names)
      r = nil
      parsed = nil
      with_empty_home("skill-routing-home-") do |home|
        r = run_command(argv, chdir: proj, stdin: prompt, timeout: opts[:timeout], env: codex_env(opts, home))
        parsed = parse_codex(r.out, names, proj: proj, home: home).merge(model: codex_model(opts))
      end
    end
    done = completion(opts[:tool], r, parsed)
    parsed = parsed.merge(prompt_tokens: nil, output_tokens: nil) if done == "observed-stop"
    status = r.completed && r.drained ? r.status : nil
    parsed.merge(argv: argv, stdout: r.out, stderr: r.err, exit: status&.exitstatus, completion: done,
                 status: OK_COMPLETIONS.include?(done) ? "ok" : "error")
  end

  # raw log の保存先 (<raw_dir>/<case id>-<n>.<ext>)。case id の文字集合は parse_cases が限っているが、
  # 多層防御として、file 名が区切りを含まない 1 つの path 要素で、展開した保存先の directory が raw dir と
  # 一致しなければ書かずに止める (raw dir の外に file を作らない)。'a/../b' のように字面の正規化では
  # raw dir に戻る id も、書き込みは raw dir の中の symlink を経て外に届きうるので止める。
  def self.raw_log_path(raw_dir, id, n, ext)
    name = "#{id}-#{n}.#{ext}"
    path = File.join(raw_dir, name)
    unless File.basename(path) == name && File.dirname(File.absolute_path(path)) == File.absolute_path(raw_dir)
      raise Error, "raw log path for case id #{id.inspect} is outside #{raw_dir}"
    end
    path
  end

  def self.main(argv, root:)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
    if opts[:codex_home]
      opts[:codex_home] = eval_codex_home!(opts[:codex_home])
      st = File.stat(opts[:codex_home])
      opts[:codex_home_id] = [st.dev, st.ino]
    end
    source = source_dir(opts, root)
    dirs = skill_dirs(source)
    names = dirs.map { |d| File.basename(d) }
    listing_chars = dirs.sum { |d| description_length(File.join(d, "SKILL.md")) }

    cases_path = opts[:cases] || File.join(root, "scripts", "lib", "skill_routing_cases.json")
    raise Error, "cases file not found: #{cases_path}" unless File.file?(cases_path)
    cases = CheckSkillRouting.parse_cases(File.read(cases_path))[:cases]
    if opts[:only]
      wanted = opts[:only].split(",")
      unknown = wanted - cases.map { |c| c["id"] }
      raise Error, "--only: unknown case id(s): #{unknown.join(', ')}" unless unknown.empty?
      cases = cases.select { |c| wanted.include?(c["id"]) }
    end
    # prompt は argv / stdin で渡すが、先頭 '-' は CLI に option と解釈されうるので弾く。
    bad = cases.select { |c| c["prompt"].start_with?("-") }
    raise Error, "prompt must not start with '-': #{bad.map { |c| c['id'] }.join(', ')}" unless bad.empty?
    # dry-run は CLI を起動しないので確かめない。確かめは run と同じ条件 (評価用の CODEX_HOME と空の HOME) で、確かめの
    # 専用の空の HOME を使う (run ごとの HOME はまだ無い。#802)。
    if opts[:tool] == "codex" && !opts[:dry_run]
      with_empty_home("skill-routing-preflight-home-") { |home| codex_preflight!(env: codex_env(opts, home)) }
    end

    Dir.mktmpdir("skill-routing-") do |base|
      proj = prepare_project(base, opts[:tool], dirs)
      puts "isolated project: #{proj} (#{names.length} skills from #{source}, listing #{listing_chars} chars)"

      if opts[:dry_run]
        sample = opts[:tool] == "claude-code" ? claude_argv(opts, "<prompt>") : codex_argv(opts, proj, names)
        puts "argv: #{sample.map(&:inspect).join(' ')}#{opts[:tool] == 'codex' ? ' (prompt on stdin)' : ''}"
        if opts[:tool] == "codex"
          home_line = opts[:codex_home] ? "#{opts[:codex_home]} (CODEX_HOME for the child; HOME is an empty dir per run)" : "not set (required for runs)"
          puts "codex home: #{home_line}"
        end
        puts "cases: #{cases.length} x repeat #{opts[:repeat]}"
        cases.each { |c| puts "  #{c['id']}: #{c['prompt']}" }
        return 0
      end

      if opts[:smoke]
        r = run_one(opts, proj, names, SMOKE_PROMPT)
        puts "status=#{r[:status]} exit=#{r[:exit].inspect} subtype=#{r[:subtype].inspect} model=#{r[:model].inspect} " \
             "first_prompt_tokens=#{r[:first_prompt_tokens].inspect} prompt_tokens=#{r[:prompt_tokens].inspect} " \
             "output_tokens=#{r[:output_tokens].inspect} completion=#{r[:completion]}"
        puts "observed=#{r[:observed].inspect}"
        puts "text: #{r[:text].to_s.strip[0, 800]}"
        unless r[:stderr].to_s.empty?
          puts "stderr: #{r[:stderr].to_s.strip[0, 400]}"
        end
        return r[:status] == "ok" ? 0 : 2
      end

      raw_dir = "#{opts[:out]}.raw"
      FileUtils.mkdir_p(raw_dir)
      runs = []
      model = nil
      memory_states = []
      cases.each do |c|
        opts[:repeat].times do |n|
          # 保存先は CLI を起動する前に確かめる (保存できない run を走らせない)。
          jsonl_path = raw_log_path(raw_dir, c["id"], n + 1, "jsonl")
          stderr_path = raw_log_path(raw_dir, c["id"], n + 1, "stderr")
          r = run_one(opts, proj, names, c["prompt"])
          model ||= r[:model]
          memory_states << r[:memory_states] if r[:memory_states]
          File.write(jsonl_path, r[:stdout])
          File.write(stderr_path, r[:stderr]) unless r[:stderr].to_s.empty?
          # observed-stop の run は token を取らないので null。ほかは今までどおり、取れなければ 0 (error run)。
          stopped = r[:completion] == "observed-stop"
          run = { "case" => c["id"], "observed" => r[:observed],
                  "prompt_tokens" => stopped ? nil : r[:prompt_tokens] || 0,
                  "output_tokens" => stopped ? nil : r[:output_tokens] || 0,
                  "status" => r[:status], "completion" => r[:completion] }
          # first_prompt_tokens は取れた tool (claude-code) だけ書く。judge では任意 field。
          run["first_prompt_tokens"] = r[:first_prompt_tokens] if r[:first_prompt_tokens]
          run["note"] = r[:note] if r[:note]
          run["reads"] = r[:reads] if r[:reads]
          runs << run
          puts "#{c['id']} [#{n + 1}/#{opts[:repeat]}]: #{r[:status]} (#{r[:completion]}) observed=#{r[:observed].inspect} " \
               "tokens=first:#{r[:first_prompt_tokens].inspect} total:#{r[:prompt_tokens].inspect} " \
               "out:#{r[:output_tokens].inspect}#{r[:note] ? " (#{r[:note]})" : ''}"
        end
      end
      results = {
        "schema_version" => CheckSkillRouting::RESULTS_SCHEMA_VERSION,
        "tool" => opts[:tool],
        "model" => opts[:model] || model || "unknown",
        "variant" => opts[:variant],
        "source" => source,
        "skills" => names,
        "listing_chars" => listing_chars,
        "cases" => cases_path,
        "generated_at" => Time.now.utc.iso8601,
        "runs" => runs,
      }
      # 自動の memory を止めたこと (#770。claude-code だけ)。
      results["auto_memory"] = AutoMemory.record(memory_states) if opts[:tool] == "claude-code"
      # Codex の子の home の条件 (#802。codex だけ)。judge は比較の両側でこれが同じかを確かめる。
      results["codex_isolation"] = CheckSkillRouting::CODEX_ISOLATION if opts[:tool] == "codex"
      File.write(opts[:out], JSON.pretty_generate(results) + "\n")
      errors = runs.count { |r| r["status"] != "ok" }
      puts "wrote #{opts[:out]} (#{runs.length} runs, #{errors} error run(s), raw: #{raw_dir})"
      puts "judge: scripts/check-skill-routing.sh --cases #{cases_path} --results #{opts[:out]}"
    end
    0
  rescue Error, CheckSkillRouting::Error, JSON::ParserError, SystemCallError => e
    warn "error: #{e.message}"
    warn USAGE if e.is_a?(Error) && e.message.match?(/\A(--|unknown argument)/)
    2
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("../..", __dir__)
  exit ProbeSkillRouting.main(ARGV, root: root)
end
