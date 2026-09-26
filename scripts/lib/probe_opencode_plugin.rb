#!/usr/bin/env ruby
# frozen_string_literal: true

# OpenCode plugin probe の runner (実機・#295 PR 0)。Spec: docs/opencode-plugin-probe.md。
#
# 隔離した tmp (HOME / XDG / DB / git config / project) で opencode を起動し、計測用 plugin
# (probe_opencode/probe-plugin.js) と mock provider (probe_opencode/mock_openai.rb) で、PR 1〜3 の
# 前提 (M1〜M20) を観測する。raw の記録と summary を --out に書く。
#
# 責務境界 (honest):
#   - runner は観測と、source からの予測との突き合わせだけを行う。PR 1〜3 をどう直すかは人と
#     orchestrator が summary を読んで決める。
#   - CI では実行しない (opencode CLI と network が要る)。self-test は opencode を使わない範囲だけ。
#   - 実物の OpenCode の config / DB / auth は読ませない。system の managed config は env で
#     外せないので隔離の外に残る (docs に honest-label)。
#   - TUI / PTY の表示と、普段の起動経路での env の漏れ (M17 / M20) は人が確かめる。
#
# 値は shell 文字列に埋め込まず argv 配列で渡す (#266 の欠陥クラスを持ち込まない)。

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "time"
require "tmpdir"
require_relative "probe_opencode/isolation"
require_relative "probe_opencode/judge"
require_relative "probe_opencode/mock_openai"
require_relative "probe_opencode/process"

module ProbeOpencodePlugin
  class Error < StandardError; end

  Isolation = ProbeOpencode::Isolation
  Mock = ProbeOpencode::MockOpenAI
  Child = ProbeOpencode::Child

  STAGES = %w[isolation serve mock real tui-plan all].freeze
  # all に含める stage。real は --real のときだけ足す。tui-plan は人が操作するので含めない。
  ALL_STAGES = %w[isolation mock serve].freeze
  DEFAULT_TIMEOUT = 120
  PLUGIN_SOURCE = File.join(__dir__, "probe_opencode", "probe-plugin.js")
  PROMPT_NOTE = "(automated probe: the mock provider drives the tool calls)"
  REAL_PROMPT = "This is an automated probe. Use the bash tool exactly once to run: echo PROBE-BASH-OK -- " \
                "then reply with only the first line of the bash tool result, copied verbatim, and nothing else."
  NOTIFY_MODES = %w[annotate mark notify].freeze

  # mock stage の run。label は記録の突き合わせに使う (judge.rb が同じ label を読む)。
  MOCK_RUNS = [
    { label: "tools-claude", model: "claude-probe", scenario: "tools", modes: NOTIFY_MODES },
    { label: "tools-gpt", model: "gpt-5-probe", scenario: "tools-patch", modes: %w[annotate mark] },
    { label: "pure", model: "claude-probe", scenario: "bash-env", modes: %w[annotate mark], pure: true },
    { label: "throw-shell-env", model: "claude-probe", scenario: "touch-mark", modes: %w[throw-shell-env] },
    { label: "throw-before", model: "claude-probe", scenario: "touch-mark", modes: %w[throw-before] },
    { label: "throw-after", model: "claude-probe", scenario: "touch-mark", modes: %w[annotate throw-after] },
    { label: "slow-after", model: "claude-probe", scenario: "touch-mark", modes: %w[annotate slow-after] },
    { label: "reject-event", model: "claude-probe", scenario: "bash-env", modes: %w[reject-event] },
    { label: "ask", model: "claude-probe", scenario: "ask", modes: [] },
    { label: "task", model: "claude-probe", scenario: "task", modes: [] },
    { label: "spawn", model: "claude-probe", scenario: "bash-env", modes: %w[spawn] },
    { label: "throw-init", model: "claude-probe", scenario: "bash-env", modes: %w[annotate], throw_init: "probe-global-b" },
    { label: "claude-compat", model: "claude-probe", scenario: "bash-env", modes: [], canaries: true },
    { label: "claude-compat-disabled", model: "claude-probe", scenario: "bash-env", modes: [], canaries: true,
      extra_env: { "OPENCODE_DISABLE_CLAUDE_CODE" => "1" } },
    # M18: mark を立て、shell.env の目印が OpenCode 内部の git に届くかも見る。
    { label: "snapshot", model: "claude-probe", scenario: "tools", modes: %w[annotate mark], snapshot: true },
  ].freeze

  SERVE_RUNS = [
    { label: "serve-plugin", modes: NOTIFY_MODES },
    { label: "serve-pure", modes: %w[annotate mark], pure: true },
    { label: "serve-throw-shell-env", modes: %w[throw-shell-env] },
    { label: "serve-reject-event", modes: %w[reject-event] },
  ].freeze

  USAGE = <<~TEXT
    usage: probe-opencode-plugin.sh --stage <isolation|serve|mock|real|tui-plan|all> --out DIR
             [--real] [--model provider/model] [--pass-env NAME]... [--shell sh|user]
             [--timeout SEC] [--keep] [--dry-run]

      --stage     isolation = M1 (debug paths / config / models)。mock = opencode run と mock provider。
                  serve = opencode serve の API で `!` / PTY / prompt / abort。real = 実 model の smoke
                  (M16。--real と --model が要る)。tui-plan = 人が TUI で確かめる手順を出し、mock を
                  動かしたまま待つ (M17 / M20)。all = isolation + mock + serve (+ --real なら real)
      --out       記録の出力先。git の worktree の外で、無いか空の dir
      --real      実 provider に送る stage を許す (real、または all に real を足す)
      --model     real の model (provider/model)
      --pass-env  real の opencode に値を渡す env の名前 (値は記録しない)。複数回指定できる
      --shell     bash tool の shell。sh = /bin/sh (既定)、user = $SHELL の binary (rc は tmp の HOME のもの)
      --timeout   opencode の 1 process の上限秒 (既定: #{DEFAULT_TIMEOUT})。tui-plan では待つ秒数
      --keep      tmp の隔離 dir を消さずに残す (path を表示する)
      --dry-run   opencode を起動せずに plan を出す

    exit: 0 = 観測を完了した (判定は summary に書く), 2 = usage・入力・環境の error
  TEXT

  # --- 引数 -------------------------------------------------------------------------

  def self.parse_argv(argv)
    opts = { pass_env: [], shell: "sh", timeout: DEFAULT_TIMEOUT }
    i = 0
    while i < argv.length
      key = argv[i]
      case key
      when "--stage", "--out", "--model", "--shell"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

        opts[key.delete_prefix("--").to_sym] = value
        i += 2
      when "--pass-env"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

        opts[:pass_env] << value
        i += 2
      when "--timeout"
        value = argv[i + 1]
        raise Error, "#{key} requires a positive integer" unless value&.match?(/\A[1-9][0-9]*\z/)

        opts[:timeout] = value.to_i
        i += 2
      when "--real", "--keep", "--dry-run"
        opts[key.delete_prefix("--").tr("-", "_").to_sym] = true
        i += 1
      else
        raise Error, "unknown argument: #{key}"
      end
    end
    raise Error, "--stage is required" unless opts[:stage]
    raise Error, "--stage must be one of #{STAGES.join(', ')}" unless STAGES.include?(opts[:stage])
    raise Error, "--out is required" unless opts[:out]
    raise Error, "--shell must be sh or user" unless %w[sh user].include?(opts[:shell])
    opts[:stages] = opts[:stage] == "all" ? ALL_STAGES + (opts[:real] ? ["real"] : []) : [opts[:stage]]
    if opts[:stages].include?("real")
      raise Error, "--stage real requires --real" unless opts[:real]
      raise Error, "--stage real requires --model provider/model" unless opts[:model]&.match?(%r{\A[^/\s]+/\S+\z})
    end
    opts[:pass_env].each { |name| Isolation.valid_pass_env!(name) }
    opts
  end

  # --out は git の worktree / .git の外で、無いか空の dir に限る (raw を tracked にしないため)。
  def self.check_out!(out)
    path = File.expand_path(out)
    raise Error, "--out is not a directory: #{out}" if File.exist?(path) && !File.directory?(path)
    raise Error, "--out must be empty or absent: #{out}" if File.directory?(path) && !Dir.empty?(path)

    probe = path
    probe = File.dirname(probe) until File.directory?(probe)
    stdout, _, status = Open3.capture3({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }, "git", "-C", probe, "rev-parse",
                                       "--is-inside-work-tree", "--is-inside-git-dir")
    raise Error, "--out must be outside a git worktree: #{out}" if status.success? && stdout.split.include?("true")

    path
  end

  def self.in_path?(cmd, path)
    path.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) && !File.directory?(File.join(d, cmd)) }
  end

  def self.shell_path(opts, parent_env)
    return "/bin/sh" if opts[:shell] == "sh"

    sh = parent_env["SHELL"].to_s
    raise Error, "--shell user: $SHELL is not an absolute executable path" unless sh.start_with?("/") && File.executable?(sh)

    sh
  end

  # --- 実行 -------------------------------------------------------------------------

  def self.probe_env(ctx, label, modes, throw_init = nil)
    env = { "PROBE_HOOKS_OUT" => File.join(ctx[:out], "hooks.jsonl"), "PROBE_RUN" => label,
            "PROBE_PRIMARY" => Isolation::PRIMARY_PLUGIN, "PROBE_NONCE" => ctx[:nonce], "PROBE_MODE" => modes.join(",") }
    env["PROBE_THROW_INIT"] = throw_init if throw_init
    env
  end

  def self.env_for(ctx, label, modes, throw_init: nil, extra: {}, pass_env: [])
    Isolation.child_env(ctx[:layout], shell: ctx[:shell], parent_env: ctx[:parent_env], pass_env: pass_env,
                                      extra: probe_env(ctx, label, modes, throw_init).merge(extra))
  end

  def self.append_jsonl(path, records)
    File.open(path, "a") { |f| records.each { |r| f.puts(JSON.generate(r)) } }
  end

  def self.record_events(ctx, label, stdout)
    events = stdout.each_line.map do |l|
      JSON.parse(l)
    rescue JSON::ParserError
      nil
    end.compact
    append_jsonl(File.join(ctx[:out], "run-events.jsonl"), events.map { |e| { "run" => label, "event" => e } })
    events.length
  end

  def self.save_stderr(ctx, label, text)
    dir = File.join(ctx[:out], "stderr")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{label}.txt"), text)
  end

  def self.run_argv(model, message, pure: false)
    ["opencode", "run", "--format", "json", "--title", "probe", "--log-level", "DEBUG", "-m", model] +
      (pure ? ["--pure"] : []) + [message]
  end

  def self.opencode_run(ctx, label:, stage:, argv:, env:, spec: {})
    ctx[:mock].run_label = label if ctx[:mock]
    marker = File.join(ctx[:layout].project, "probe-executed")
    FileUtils.rm_f(marker)
    res = Child.run(argv, env: env, chdir: ctx[:layout].project, timeout: ctx[:opts][:timeout])
    save_stderr(ctx, label, res.err)
    fact = {
      "label" => label, "stage" => stage, "command" => argv[1], "model" => argv[argv.index("-m") + 1],
      "modes" => spec[:modes], "pure" => spec[:pure] == true, "throw_init" => spec[:throw_init],
      "extra_env" => (spec[:extra_env] || {}).keys, "exit" => res.exitstatus, "timed_out" => res.timed_out,
      "duration_ms" => res.duration_ms, "events" => record_events(ctx, label, res.out),
      "stderr_has_plugin" => res.err.match?(/plugin/i), "stderr_has_error" => res.err.match?(/error/i),
      "executed_marker" => File.exist?(marker)
    }
    ctx[:runs] << fact
    puts "#{label}: exit=#{res.exitstatus.inspect} timed_out=#{res.timed_out} #{res.duration_ms}ms events=#{fact['events']}"
    fact
  end

  def self.write_mock_config(ctx, snapshot: false)
    Isolation.write_config(ctx[:layout], Isolation.opencode_config(shell: ctx[:shell], mock_url: ctx[:mock]&.base_url || "http://127.0.0.1:9/v1", snapshot: snapshot))
  end

  # --- stage ------------------------------------------------------------------------

  def self.stage_isolation(ctx)
    write_mock_config(ctx)
    env = env_for(ctx, "isolation", [])
    base = ctx[:layout].base
    paths = Child.run(%w[opencode debug paths], env: env, chdir: ctx[:layout].project, timeout: ctx[:opts][:timeout])
    labels = paths.out.each_line.map { |l| l.strip.split(/\s+/, 2) }.select { |k, v| k && v&.start_with?("/") }
    config = Child.run(%w[opencode debug config], env: env, chdir: ctx[:layout].project, timeout: ctx[:opts][:timeout])
    cfg = begin
      JSON.parse(config.out)
    rescue JSON::ParserError
      nil
    end
    models = Child.run(%w[opencode models], env: env, chdir: ctx[:layout].project, timeout: ctx[:opts][:timeout])
    model_providers = models.out.each_line.map { |l| l.strip[%r{\A([^/\s]+)/\S+\z}, 1] }.compact.uniq.sort
    ctx[:facts]["isolation"] = {
      "paths_all_under_tmp" => labels.empty? ? nil : labels.all? { |_, v| v.start_with?(base) },
      "outside_labels" => labels.reject { |_, v| v.start_with?(base) }.map(&:first),
      "config_providers" => cfg.is_a?(Hash) && cfg["provider"].is_a?(Hash) ? cfg["provider"].keys.sort : nil,
      "enabled_providers" => cfg.is_a?(Hash) ? cfg["enabled_providers"] : nil,
      "models_providers" => models.exitstatus == 0 ? model_providers : nil,
      "exits" => { "paths" => paths.exitstatus, "config" => config.exitstatus, "models" => models.exitstatus },
    }
    save_stderr(ctx, "isolation", [paths.err, config.err, models.err].join("\n"))
    puts "isolation: paths=#{paths.exitstatus.inspect} config=#{config.exitstatus.inspect} models=#{models.exitstatus.inspect}"
  end

  def self.stage_mock(ctx)
    MOCK_RUNS.each do |spec|
      write_mock_config(ctx, snapshot: spec[:snapshot] == true)
      spec[:canaries] ? Isolation.place_claude_canaries(ctx[:layout], ctx[:canaries]) : Isolation.remove_claude_canaries(ctx[:layout])
      env = env_for(ctx, spec[:label], spec[:modes], throw_init: spec[:throw_init], extra: spec[:extra_env] || {})
      argv = run_argv("#{Isolation::PROVIDER_ID}/#{spec[:model]}", "PROBE-SCENARIO:#{spec[:scenario]} #{PROMPT_NOTE}", pure: spec[:pure] == true)
      fact = opencode_run(ctx, label: spec[:label], stage: "mock", argv: argv, env: env, spec: spec)
      # 最初の run で event が 1 つも出ないなら、mock と OpenCode の組み合わせが壊れている。
      # 残りの run も timeout まで待つだけなので止める (該当する M は unknown になる)。
      if spec.equal?(MOCK_RUNS.first) && fact["events"].zero?
        ctx[:facts]["mock_aborted"] = "#{spec[:label]} produced no events (see stderr/#{spec[:label]}.txt)"
        puts "mock: #{ctx[:facts]['mock_aborted']}; skipping the remaining mock runs"
        break
      end
    end
    Isolation.remove_claude_canaries(ctx[:layout])
    write_mock_config(ctx)
  end

  def self.shq(s)
    "'" + s.gsub("'") { "'\\''" } + "'"
  end

  def self.names_of(text)
    ProbeOpencode::Judge.names_from(text)
  end

  def self.new_session(client)
    status, body = client.post("/session", { "title" => "probe" })
    [status, body.is_a?(Hash) ? body["id"] : nil]
  end

  def self.serve_shell(client)
    status, sid = new_session(client)
    return { "session_status" => status } unless sid

    st, msg = client.post("/session/#{sid}/shell", { "agent" => "build", "command" => Mock::ENV_NAMES_CMD })
    parts = msg.is_a?(Hash) && msg["parts"].is_a?(Array) ? msg["parts"] : []
    tool = parts.find { |p| p.is_a?(Hash) && p["type"] == "tool" }
    output = tool && tool.dig("state", "output")
    { "session_id" => sid, "status" => st, "part_status" => tool && tool.dig("state", "status"),
      "names" => names_of(output), "ok_marker" => output.to_s.include?(Mock::OK_MARKER) }
  end

  def self.serve_pty(ctx, client, label)
    file = File.join(ctx[:layout].tmp, "pty-#{label}.txt")
    FileUtils.rm_f(file)
    cmd = "(#{Mock::ENV_NAMES_CMD}) > #{shq(file)} 2>&1"
    status, body = client.post("/pty", { "command" => "/bin/sh", "args" => ["-c", cmd], "cwd" => ctx[:layout].project, "title" => "probe" })
    deadline = Time.now + 5
    sleep 0.2 until (File.file?(file) && File.read(file).include?(Mock::OK_MARKER)) || Time.now > deadline
    id = body.is_a?(Hash) ? body["id"] : nil
    client.delete("/pty/#{id}") if id
    written = File.file?(file)
    { "status" => status, "file_written" => written, "names" => written ? names_of(File.read(file)) : nil }
  end

  def self.prompt_body(scenario)
    { "model" => { "providerID" => Isolation::PROVIDER_ID, "modelID" => "claude-probe" },
      "parts" => [{ "type" => "text", "text" => "PROBE-SCENARIO:#{scenario} #{PROMPT_NOTE}" }] }
  end

  def self.serve_prompt(client)
    status, sid = new_session(client)
    return { "session_status" => status } unless sid

    st, = client.post("/session/#{sid}/message", prompt_body("bash-env"))
    { "session_id" => sid, "status" => st }
  end

  def self.serve_abort(client)
    status, sid = new_session(client)
    return { "session_status" => status } unless sid

    st, = client.post("/session/#{sid}/prompt_async", prompt_body("slow"))
    sleep 1.5
    abort_status, = client.post("/session/#{sid}/abort", {})
    sleep 1.0
    { "session_id" => sid, "prompt_async_status" => st, "abort_status" => abort_status }
  end

  def self.serve_run(ctx, spec)
    label = spec[:label]
    ctx[:mock].run_label = label
    password = SecureRandom.hex(16)
    env = env_for(ctx, label, spec[:modes], extra: { "OPENCODE_SERVER_PASSWORD" => password })
    argv = %w[opencode serve --hostname 127.0.0.1 --port 0 --log-level DEBUG] + (spec[:pure] ? ["--pure"] : [])
    srv = Child::Serve.new(argv, env: env, chdir: ctx[:layout].project, timeout: ctx[:opts][:timeout])
    port = srv.start
    fact = { "label" => label, "stage" => "serve", "command" => "serve", "modes" => spec[:modes], "pure" => spec[:pure] == true,
             "listening" => !port.nil? }
    if port
      client = Child::Client.new(port: port, password: password, directory: ctx[:layout].project, timeout: ctx[:opts][:timeout])
      fact["shell"] = serve_shell(client)
      fact["pty"] = serve_pty(ctx, client, label)
      fact["prompt"] = serve_prompt(client)
      fact["abort"] = serve_abort(client)
      sleep 1.0
      status, = client.get("/session")
      fact["alive_after"] = srv.alive? && status == 200
    end
    fact["exit_before_stop"] = srv.exitstatus
    srv.stop
    save_stderr(ctx, label, srv.err)
    ctx[:runs] << fact
    puts "#{label}: listening=#{fact['listening']} alive_after=#{fact['alive_after'].inspect}"
    fact
  end

  def self.stage_serve(ctx)
    write_mock_config(ctx)
    SERVE_RUNS.each do |spec|
      fact = serve_run(ctx, spec)
      next if fact["listening"]

      ctx[:facts]["serve_aborted"] = "#{spec[:label]} did not print the listen URL (see stderr/#{spec[:label]}.txt)"
      puts "serve: #{ctx[:facts]['serve_aborted']}; skipping the remaining serve runs"
      break
    end
  end

  def self.stage_real(ctx)
    provider = ctx[:opts][:model].split("/", 2).first
    Isolation.write_config(ctx[:layout], Isolation.opencode_config(shell: ctx[:shell], real_provider: provider))
    env = env_for(ctx, "real", %w[annotate mark], pass_env: ctx[:opts][:pass_env])
    argv = run_argv(ctx[:opts][:model], REAL_PROMPT)
    opencode_run(ctx, label: "real", stage: "real", argv: argv, env: env, spec: { modes: %w[annotate mark] })
    write_mock_config(ctx)
  end

  def self.tui_checklist(script)
    <<~TEXT
      TUI の手動 checklist (M17 / M8・M10・M11 の TUI 側)。別の terminal で次を起動する:
        #{script}
      0. model に probe/claude-probe を選ぶ (mock provider。実 provider は見えない)
      1. `PROBE-SCENARIO:bash-env` と送る → bash の結果の先頭に nonce の行が出るか (M11: 注記が表示に出るか)
      2. 応答の後に toast "probe toast" が出るか (M11 / M17)
      3. `!env | cut -d= -f1 | grep -xE 'OPENCODE|AGENT|AGENT_TOOLS_PROBE_MARK' | sort` の結果 (M17: `!` の結果)
      4. terminal (PTY) を開き、同じ command の結果 (M17: PTY に目印が立たないこと。有無だけ)
      5. 終了したら、この runner を Ctrl-C で止める (hooks.jsonl は --out に残る)
      M20 (普段の起動経路での漏れ。手動・有無だけ): herdr の pane と、Claude の session の中の terminal から
      普段どおり opencode を起動し、`!env | cut -d= -f1 | grep -xE 'CLAUDECODE|CODEX_THREAD_ID|CODEX_SANDBOX' | sort`
      の結果 (名前だけ) を記録する。値は記録しない。
    TEXT
  end

  def self.stage_tui_plan(ctx)
    write_mock_config(ctx)
    env = env_for(ctx, "tui", NOTIFY_MODES)
    script = File.join(ctx[:layout].base, "tui-launch.sh")
    assigns = env.map { |k, v| shq("#{k}=#{v}") }.join(" ")
    File.write(script, "#!/bin/sh\ncd #{shq(ctx[:layout].project)} || exit 2\nexec env -i #{assigns} opencode\n")
    File.chmod(0o755, script)
    ctx[:mock].run_label = "tui"
    puts tui_checklist(script)
    puts "waiting up to #{ctx[:opts][:timeout]}s (Ctrl-C to finish)"
    begin
      sleep ctx[:opts][:timeout]
    rescue Interrupt
      puts "tui-plan: stopped"
    end
  end

  # --- 後処理 -------------------------------------------------------------------------

  def self.log_hosts(layout)
    Dir.glob(File.join(layout.log_dir, "*")).flat_map do |f|
      File.read(f).scan(%r{https?://([A-Za-z0-9.-]+)}).flatten
    end.uniq.sort.reject { |h| h == "127.0.0.1" }
  end

  def self.app_log_found_in(layout, nonce)
    Dir.glob(File.join(layout.log_dir, "*")).select { |f| File.read(f).include?("probe-log-#{nonce}") }.map { |f| File.join("<data>", "opencode", "log", File.basename(f)) }
  end

  def self.install_state(layout)
    { "global_plugin_pkg" => File.directory?(File.join(layout.opencode_config_dir, "node_modules", "@opencode-ai", "plugin")),
      "project_plugin_pkg" => File.directory?(File.join(layout.project, ".opencode", "node_modules", "@opencode-ai", "plugin")) }
  end

  def self.opencode_version(ctx)
    res = Child.run(%w[opencode --version], env: env_for(ctx, "version", []), chdir: ctx[:layout].project, timeout: ctx[:opts][:timeout])
    res.exitstatus == 0 ? res.out.strip : nil
  end

  def self.plan(opts, shell)
    lines = ["plan (dry-run): stages=#{opts[:stages].join(',')} shell=#{shell} timeout=#{opts[:timeout]}s"]
    opts[:stages].each do |stage|
      case stage
      when "isolation" then lines << "  isolation: opencode debug paths / debug config / models"
      when "mock"
        MOCK_RUNS.each do |r|
          lines << "  mock #{r[:label]}: #{run_argv("#{Isolation::PROVIDER_ID}/#{r[:model]}", "PROBE-SCENARIO:#{r[:scenario]}", pure: r[:pure] == true).join(' ')} modes=#{r[:modes].join(',')}"
        end
      when "serve" then SERVE_RUNS.each { |r| lines << "  serve #{r[:label]}: modes=#{r[:modes].join(',')} pure=#{r[:pure] == true} (! / pty / prompt / abort)" }
      when "real" then lines << "  real: #{run_argv(opts[:model], '<prompt>').join(' ')} pass-env=#{opts[:pass_env].join(',')}"
      when "tui-plan" then lines << "  tui-plan: write tui-launch.sh, print the checklist, keep the mock running"
      end
    end
    lines << "  child env keys: #{Isolation.child_env(Isolation.layout('<tmp>'), shell: shell, parent_env: { 'PATH' => '<PATH>' }).keys.join(' ')} + PROBE_*"
    lines.join("\n")
  end

  def self.main(argv, parent_env: ENV.to_h)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
    out = check_out!(opts[:out])
    shell = shell_path(opts, parent_env)
    if opts[:dry_run]
      puts plan(opts, shell)
      return 0
    end
    raise Error, "opencode not found in PATH" unless in_path?("opencode", parent_env.fetch("PATH"))

    FileUtils.mkdir_p(out)
    # OpenCode は realpath で path を出す (macOS の /var は /private/var) ので、realpath で持つ。
    base = File.realpath(Dir.mktmpdir("opencode-probe-"))
    layout = Isolation.layout(base)
    nonce = "PROBE-NONCE-#{SecureRandom.hex(8)}"
    canaries = { "claude_rules" => "PROBE-CANARY-RULES-#{SecureRandom.hex(6)}", "claude_skill" => "PROBE-CANARY-SKILL-#{SecureRandom.hex(6)}" }
    ctx = { opts: opts, out: out, layout: layout, parent_env: parent_env, shell: shell, nonce: nonce, canaries: canaries,
            runs: [], facts: {} }
    real_paths = Isolation.real_state_paths(parent_env)
    before = Isolation.mtimes(real_paths)
    begin
      Isolation.prepare(layout, parent_env: parent_env, shell: shell)
      Isolation.install_plugins(layout, PLUGIN_SOURCE)
      ctx[:mock] = Mock.new(log_path: File.join(out, "mock-requests.jsonl"), nonce: nonce, real_home: parent_env.fetch("HOME"), canaries: canaries)
      ctx[:mock].start
      version = opencode_version(ctx)
      opts[:stages].each { |stage| send("stage_#{stage.tr('-', '_')}", ctx) }
    ensure
      ctx[:mock]&.stop
      FileUtils.cp(layout.git_hooks_out, File.join(out, "git-hooks.jsonl")) if File.file?(layout.git_hooks_out)
      facts = ctx[:facts].merge(
        "nonce" => nonce, "shell" => opts[:shell], "runs" => ctx[:runs],
        "real_mtime" => { "before" => before, "after" => Isolation.mtimes(real_paths) },
        "install" => install_state(layout), "log_hosts" => log_hosts(layout), "app_log_found_in" => app_log_found_in(layout, nonce)
      )
      File.write(File.join(out, "facts.json"), JSON.pretty_generate(facts) + "\n")
      if opts[:keep]
        puts "kept: #{base}"
      else
        FileUtils.rm_rf(base)
      end
    end
    meta = { "opencode_version" => version, "date" => Time.now.utc.iso8601, "stages" => opts[:stages], "shell" => opts[:shell],
             "platform" => RUBY_PLATFORM, "model" => opts[:model], "aborted" => ctx[:facts].select { |k, _| k.end_with?("_aborted") } }
    ProbeOpencode::Judge.write(out, meta, [[base, "<tmp>"], [parent_env.fetch("HOME"), "~"]])
    puts "wrote #{File.join(out, 'summary.md')}"
    0
  rescue Error, ProbeOpencode::Error, JSON::ParserError, SystemCallError => e
    warn "error: #{e.message}"
    warn USAGE if e.message.match?(/\A(--|unknown argument)/)
    2
  end
end

if $PROGRAM_NAME == __FILE__
  exit ProbeOpencodePlugin.main(ARGV)
end
