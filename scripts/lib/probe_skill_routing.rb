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
#   - 実 tool home (~/.claude / ~/.codex) には書き込まない。候補 skill は project scope
#     (claude-code: <proj>/.claude/skills、codex: <proj>/.agents/skills) に copy し、claude-code は
#     --setting-sources project で user scope の skill を外し、codex は候補と同名の user skill を
#     skills.config の -c override で無効化する (どちらも実測済み。docs 参照)。
#   - CI では実行しない (CLI 認証と network が要る)。hard な証跡は raw log (<out>.raw/) と
#     PR / Issue に貼る summary。CI 緑を根拠にしない。
#   - 観測は CLI の event stream に依存する。field 名が変わると observed が空になり、判定は
#     primary MISS として現れる (緑には化けない)。--smoke で listing と event 形式を先に確認する。
#   - --max-turns の打ち切りは観測完了として扱う (routing の判断は最初の turn の Skill 起動で
#     出る。skill が起動した後の作業は観測対象外なので、続きを走らせない)。
#
# prompt / path は shell 文字列に埋め込まず argv 配列と stdin で渡す (#266 の欠陥クラスを
# 持ち込まない)。

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "time"
require_relative "check_skill_routing"

module ProbeSkillRouting
  class Error < StandardError; end

  TOOLS = %w[claude-code codex].freeze
  # tool ごとの project scope の skill 置き場 (公式 docs の repository-level path)。
  PROJECT_SKILL_DIRS = {
    "claude-code" => File.join(".claude", "skills"),
    "codex" => File.join(".agents", "skills"),
  }.freeze
  SMOKE_PROMPT = "あなたが今使える skill の name を、カンマ区切りで全部列挙して。他の文は書かない。"
  DEFAULT_MAX_TURNS = 2
  DEFAULT_TIMEOUT = 300

  USAGE = <<~TEXT
    usage: probe-skill-routing.sh --tool <claude-code|codex> --out <results.json>
             [--source DIR] [--cases FILE] [--variant LABEL] [--model MODEL] [--repeat N]
             [--only ID[,ID...]] [--max-turns N] [--timeout SEC] [--dry-run] [--smoke]

      --tool      観測対象の CLI (claude-code = `claude -p`, codex = `codex exec`)
      --out       results.json の出力先。raw log は <out>.raw/ に残す (judge の証跡)
      --source    候補 skill dir の親 (既定: generated/<tool>/skills。build 済みであること)
      --cases     case set (既定: scripts/lib/skill_routing_cases.json)
      --variant   結果に付ける label (既定: candidate。baseline を測るときは baseline 等)
      --model     CLI に渡す model (既定: CLI の既定。baseline と candidate で揃えること)
      --repeat    各 case の実行回数 (既定: 1)
      --only      実行する case id (comma 区切り)。coverage が欠けるので判定は exit 2 になる
      --max-turns claude-code の --max-turns (既定: #{DEFAULT_MAX_TURNS})
      --timeout   1 run の上限秒 (既定: #{DEFAULT_TIMEOUT})
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
      when "--tool", "--out", "--source", "--cases", "--variant", "--model", "--only"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")
        opts[key.delete_prefix("--").to_sym] = value
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
  # 単一行と YAML block (`>` / `|`) の両方を読む。frontmatter が無い / description が無い skill は
  # 0 文字として数える (build 側の frontmatter 検証 (#234) が正本で、ここでは gate しない)。
  def self.description_length(skill_md)
    text = File.read(skill_md)
    m = text.match(/\A---\n(.*?)\n---\n/m)
    return 0 unless m

    lines = m[1].lines
    idx = lines.index { |l| l.start_with?("description:") }
    return 0 unless idx

    first = lines[idx].sub(/\Adescription:\s*/, "").rstrip
    if %w[> | >- |-].include?(first)
      body = lines[(idx + 1)..-1].take_while { |l| l.start_with?(" ") || l.strip.empty? }
      body.map(&:strip).reject(&:empty?).join(" ").length
    else
      first.length
    end
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
  # - prompt_tokens / output_tokens: type=result の usage (run 全体の合計。turn 数に依存する)。
  # - subtype: result の subtype。error_max_turns は打ち切りであって観測失敗ではない。
  def self.parse_claude(jsonl)
    observed = []
    model = nil
    prompt_tokens = output_tokens = first_prompt_tokens = nil
    subtype = nil
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
            observed << name if name.is_a?(String)
          elsif c["type"] == "text" && c["text"].is_a?(String)
            text << c["text"]
          end
        end
      when "result"
        u = e["usage"].is_a?(Hash) ? e["usage"] : {}
        prompt_tokens = sum_usage(u, PROMPT_USAGE_KEYS)
        output_tokens = u["output_tokens"].is_a?(Integer) ? u["output_tokens"] : 0
        subtype = e["subtype"] if e["subtype"].is_a?(String)
        text = e["result"] if text.empty? && e["result"].is_a?(String)
      end
    end
    { observed: observed.uniq, model: model, prompt_tokens: prompt_tokens, output_tokens: output_tokens,
      first_prompt_tokens: first_prompt_tokens, subtype: subtype, text: text, note: nil }
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
  def self.codex_argv(opts, proj, names)
    argv = ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
            "-c", 'approval_policy="never"', "-C", proj, "-m", codex_model(opts)]
    disable = codex_disable_override(names)
    argv += ["-c", disable] if disable
    argv + ["-"]
  end

  def self.codex_home
    ENV["CODEX_HOME"] || File.join(Dir.home, ".codex")
  end

  # --model が無ければ $CODEX_HOME/config.toml の top-level model を使う。どちらも無ければ
  # エラー (model 不明のまま比較しない)。
  def self.codex_model(opts)
    return opts[:model] if opts[:model]

    config = File.join(codex_home, "config.toml")
    if File.file?(config)
      File.foreach(config) do |line|
        m = line.match(/\A\s*model\s*=\s*"([^"]+)"/)
        return m[1] if m
      end
    end
    raise Error, "codex: --model is required (no top-level model in #{config})"
  end

  def self.codex_disable_override(names)
    entries = names.map do |n|
      path = File.join(codex_home, "skills", n, "SKILL.md")
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
  def self.parse_codex(jsonl, names)
    reads = []
    usage = nil
    text = +""
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
        elsif item["type"] == "command_execution" && item["command"].is_a?(String)
          item["command"].scan(pattern) { |(name)| reads << name unless reads.include?(name) }
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
      first_prompt_tokens: nil, subtype: nil, text: text, note: note }
  end

  # --- 実行 -------------------------------------------------------------------------

  # timeout 後に reader thread を待つ上限秒。group kill 後も pipe が閉じない (kill が届かない
  # 孫 process が握っている) 場合に runner 自体がハングしないための床。
  READER_JOIN_GRACE = 5

  # argv を配列のまま起動し、timeout を超えたら kill する。stdout / stderr / status を返す
  # (timeout 時の status は nil)。
  # CLI は子 process (codex の command 実行、claude の hook 等) を持ち、それらが stdout / stderr の
  # pipe を継承する。CLI の PID だけを kill しても孫が pipe を握ったままだと read が返らず runner が
  # ハングするので、pgroup: true で新しい process group を作り、timeout 時は group 全体へ TERM →
  # KILL を送る。reader の join は bounded にし、それでも閉じない pipe は runner 側で close する。
  def self.run_command(argv, chdir:, stdin:, timeout:)
    # 入れ子起動の guard 変数を外す (Claude Code の Bash から起動された場合)。
    env = { "CLAUDECODE" => nil, "CLAUDE_CODE_ENTRYPOINT" => nil }
    out = +""
    err = +""
    status = nil
    Open3.popen3(env, *argv, chdir: chdir, pgroup: true) do |i, o, e, wait|
      i.write(stdin) if stdin
      i.close
      # timeout 時に runner 側で pipe を close すると、read 中の thread は IOError で抜ける。
      # それは意図した打ち切りなので握り (join で再送出させない)、読めた分だけを返す。
      readers = [[o, out], [e, err]].map do |io, buf|
        t = Thread.new do
          buf << io.read
        rescue IOError
          nil
        end
        t.report_on_exception = false
        t
      end
      completed = wait.join(timeout)
      unless completed
        # pgroup: true なので pgid == 子の pid。負の pid で group 全体に送る。
        kill_group(wait.pid, "TERM")
        sleep 1
        kill_group(wait.pid, "KILL")
      end
      # 正常終了でも、CLI が残した孫 process が pipe を継承していると read が返らない。timeout
      # 経路と同じく共通の deadline で bounded に待ち、閉じなければ group を KILL し (pipe が閉じて
      # 読めた分を回収してから)、それでも閉じない pipe を runner 側で閉じる。
      deadline = Time.now + READER_JOIN_GRACE
      drained = readers.map { |t| t.join([deadline - Time.now, 0].max) }.all?
      unless drained
        kill_group(wait.pid, "KILL")
        readers.each { |t| t.join(1) }
        [o, e].each { |io| io.close unless io.closed? }
        readers.each { |t| t.join(1) }
      end
      wait.join(READER_JOIN_GRACE) unless completed
      # stream を最後まで読み切れなかった run は観測として信用しない (status nil → error run)。
      status = wait.value if completed && drained
      # process group は runner 専用なので、CLI が detach したまま残した process も最後に回収する
      # (残っていなければ ESRCH で no-op)。
      kill_group(wait.pid, "KILL")
    end
    [out, err, status]
  end

  def self.kill_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def self.run_one(opts, proj, names, prompt)
    if opts[:tool] == "claude-code"
      argv = claude_argv(opts, prompt)
      out, err, status = run_command(argv, chdir: proj, stdin: nil, timeout: opts[:timeout])
      parsed = parse_claude(out)
    else
      argv = codex_argv(opts, proj, names)
      out, err, status = run_command(argv, chdir: proj, stdin: prompt, timeout: opts[:timeout])
      parsed = parse_codex(out, names).merge(model: codex_model(opts))
    end
    # 観測完了の条件: usage が取れていて、CLI が正常終了したか、または --max-turns の打ち切り
    # (claude-code の result.subtype == "error_max_turns")。打ち切りは routing の判断 (最初の
    # turn の Skill 起動) を観測した後に起きるので観測失敗ではない。認証 / API エラー等の
    # 非ゼロ終了は観測不能として error (judge は緑に数えない)。
    complete = status&.success? || parsed[:subtype] == "error_max_turns"
    ok = complete && parsed[:prompt_tokens] && parsed[:output_tokens]
    parsed.merge(argv: argv, stdout: out, stderr: err, exit: status&.exitstatus, status: ok ? "ok" : "error")
  end

  def self.main(argv, root:)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
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

    Dir.mktmpdir("skill-routing-") do |base|
      proj = prepare_project(base, opts[:tool], dirs)
      puts "isolated project: #{proj} (#{names.length} skills from #{source}, listing #{listing_chars} chars)"

      if opts[:dry_run]
        sample = opts[:tool] == "claude-code" ? claude_argv(opts, "<prompt>") : codex_argv(opts, proj, names)
        puts "argv: #{sample.map(&:inspect).join(' ')}#{opts[:tool] == 'codex' ? ' (prompt on stdin)' : ''}"
        puts "cases: #{cases.length} x repeat #{opts[:repeat]}"
        cases.each { |c| puts "  #{c['id']}: #{c['prompt']}" }
        return 0
      end

      if opts[:smoke]
        r = run_one(opts, proj, names, SMOKE_PROMPT)
        puts "status=#{r[:status]} exit=#{r[:exit].inspect} subtype=#{r[:subtype].inspect} model=#{r[:model].inspect} " \
             "first_prompt_tokens=#{r[:first_prompt_tokens].inspect} prompt_tokens=#{r[:prompt_tokens].inspect} " \
             "output_tokens=#{r[:output_tokens].inspect}"
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
      cases.each do |c|
        opts[:repeat].times do |n|
          r = run_one(opts, proj, names, c["prompt"])
          model ||= r[:model]
          File.write(File.join(raw_dir, "#{c['id']}-#{n + 1}.jsonl"), r[:stdout])
          File.write(File.join(raw_dir, "#{c['id']}-#{n + 1}.stderr"), r[:stderr]) unless r[:stderr].to_s.empty?
          run = { "case" => c["id"], "observed" => r[:observed], "prompt_tokens" => r[:prompt_tokens] || 0,
                  "output_tokens" => r[:output_tokens] || 0, "status" => r[:status] }
          # first_prompt_tokens は取れた tool (claude-code) だけ書く。judge では任意 field。
          run["first_prompt_tokens"] = r[:first_prompt_tokens] if r[:first_prompt_tokens]
          run["note"] = r[:note] if r[:note]
          runs << run
          puts "#{c['id']} [#{n + 1}/#{opts[:repeat]}]: #{r[:status]} observed=#{r[:observed].inspect} " \
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
