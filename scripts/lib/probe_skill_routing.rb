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
#     --setting-sources project で user scope の skill を外す。codex の user scope 排除は
#     0.153.4 で未検証 (--smoke で可視 skill を確認してから使う)。
#   - CI では実行しない (CLI 認証と network が要る)。hard な証跡は raw log (<out>.raw/) と
#     PR / Issue に貼る summary。CI 緑を根拠にしない。
#   - 観測は CLI の event stream に依存する。field 名が変わると observed が空になり、判定は
#     primary MISS として現れる (緑には化けない)。--smoke で listing と event 形式を先に確認する。
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

  def self.claude_argv(opts, prompt)
    argv = ["claude", "-p", "--setting-sources", "project", "--output-format", "stream-json", "--verbose",
            "--max-turns", opts[:max_turns].to_s, "--no-session-persistence"]
    argv += ["--model", opts[:model]] if opts[:model]
    argv + [prompt]
  end

  # stream-json を読んで observed / token / model を取り出す。
  # - Skill tool の起動: type=assistant の content[].tool_use で name == "Skill"。skill 名は
  #   input.skill (無ければ input.name)。
  # - usage: type=result の usage。prompt は input + cache_creation + cache_read の合計 (skill
  #   listing は system prompt 側なので cache 側に現れる)。
  def self.parse_claude(jsonl)
    observed = []
    model = nil
    prompt_tokens = output_tokens = nil
    is_error = false
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
        prompt_tokens = %w[input_tokens cache_creation_input_tokens cache_read_input_tokens]
                        .sum { |k| u[k].is_a?(Integer) ? u[k] : 0 }
        output_tokens = u["output_tokens"].is_a?(Integer) ? u["output_tokens"] : 0
        is_error = e["is_error"] == true
        text = e["result"] if text.empty? && e["result"].is_a?(String)
      end
    end
    { observed: observed.uniq, model: model, prompt_tokens: prompt_tokens, output_tokens: output_tokens,
      is_error: is_error, text: text }
  end

  # --- adapter: codex (0.153.4 で未検証。--smoke で確認してから使う) ------------------------

  def self.codex_argv(opts, proj)
    argv = ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
            "-c", 'approval_policy="never"', "-C", proj]
    argv += ["-m", opts[:model]] if opts[:model]
    argv + ["-"]
  end

  # codex の JSONL event 名は版で変わるため、構造ではなく内容で観測する:
  # - observed: いずれかの event の本文に project scope の skill path (<proj>/.agents/skills/<name>/)
  #   が現れた skill。skill の起動 = SKILL.md の読み取りなので、read / command の event に path が出る。
  # - token: input_tokens と output_tokens を両方持つ hash を再帰的に探し、最後に現れたものを採る
  #   (累計 usage は turn 末尾に出る)。
  # - model: いずれかの event の "model" 文字列。
  def self.parse_codex(jsonl, proj, names)
    observed = []
    model = nil
    usage = nil
    text = +""
    prefix = File.join(proj, PROJECT_SKILL_DIRS.fetch("codex"))
    jsonl.each_line do |line|
      names.each { |n| observed << n if line.include?(File.join(prefix, n) + "/") }
      e = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless e.is_a?(Hash)

      model ||= find_string(e, "model")
      u = find_usage(e)
      usage = u if u
      msg = e["msg"].is_a?(Hash) ? e["msg"] : e
      text = msg["message"] if msg["type"].to_s.include?("message") && msg["message"].is_a?(String)
    end
    prompt_tokens = usage ? usage["input_tokens"] : nil
    output_tokens = usage ? usage["output_tokens"] : nil
    { observed: observed.uniq, model: model, prompt_tokens: prompt_tokens, output_tokens: output_tokens,
      is_error: false, text: text }
  end

  def self.find_string(obj, key)
    case obj
    when Hash
      return obj[key] if obj[key].is_a?(String)
      obj.each_value { |v| (r = find_string(v, key)) && (return r) }
    when Array
      obj.each { |v| (r = find_string(v, key)) && (return r) }
    end
    nil
  end

  def self.find_usage(obj)
    found = nil
    case obj
    when Hash
      if obj["input_tokens"].is_a?(Integer) && obj["output_tokens"].is_a?(Integer)
        found = obj
      end
      obj.each_value { |v| (r = find_usage(v)) && (found = r) }
    when Array
      obj.each { |v| (r = find_usage(v)) && (found = r) }
    end
    found
  end

  # --- 実行 -------------------------------------------------------------------------

  # argv を配列のまま起動し、timeout を超えたら kill する。stdout / stderr / status を返す。
  def self.run_command(argv, chdir:, stdin:, timeout:)
    # 入れ子起動の guard 変数を外す (Claude Code の Bash から起動された場合)。
    env = { "CLAUDECODE" => nil, "CLAUDE_CODE_ENTRYPOINT" => nil }
    out = +""
    err = +""
    status = nil
    Open3.popen3(env, *argv, chdir: chdir) do |i, o, e, wait|
      i.write(stdin) if stdin
      i.close
      readers = [Thread.new { out << o.read }, Thread.new { err << e.read }]
      unless wait.join(timeout)
        Process.kill("TERM", wait.pid) rescue nil
        sleep 1
        Process.kill("KILL", wait.pid) rescue nil
        readers.each(&:join)
        return [out, err, nil]
      end
      readers.each(&:join)
      status = wait.value
    end
    [out, err, status]
  end

  def self.run_one(opts, proj, names, prompt)
    if opts[:tool] == "claude-code"
      argv = claude_argv(opts, prompt)
      out, err, status = run_command(argv, chdir: proj, stdin: nil, timeout: opts[:timeout])
      parsed = parse_claude(out)
    else
      argv = codex_argv(opts, proj)
      out, err, status = run_command(argv, chdir: proj, stdin: prompt, timeout: opts[:timeout])
      parsed = parse_codex(out, proj, names)
    end
    ok = status&.success? && !parsed[:is_error] && parsed[:prompt_tokens] && parsed[:output_tokens]
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
        sample = opts[:tool] == "claude-code" ? claude_argv(opts, "<prompt>") : codex_argv(opts, proj)
        puts "argv: #{sample.map(&:inspect).join(' ')}#{opts[:tool] == 'codex' ? ' (prompt on stdin)' : ''}"
        puts "cases: #{cases.length} x repeat #{opts[:repeat]}"
        cases.each { |c| puts "  #{c['id']}: #{c['prompt']}" }
        return 0
      end

      if opts[:smoke]
        r = run_one(opts, proj, names, SMOKE_PROMPT)
        puts "status=#{r[:status]} exit=#{r[:exit].inspect} model=#{r[:model].inspect} " \
             "prompt_tokens=#{r[:prompt_tokens].inspect} output_tokens=#{r[:output_tokens].inspect}"
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
          runs << { "case" => c["id"], "observed" => r[:observed], "prompt_tokens" => r[:prompt_tokens] || 0,
                    "output_tokens" => r[:output_tokens] || 0, "status" => r[:status] }
          puts "#{c['id']} [#{n + 1}/#{opts[:repeat]}]: #{r[:status]} observed=#{r[:observed].inspect} " \
               "tokens=#{r[:prompt_tokens].inspect}/#{r[:output_tokens].inspect}"
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
