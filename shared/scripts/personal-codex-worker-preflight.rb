#!/usr/bin/env ruby
# frozen_string_literal: true

# codex-worker-preflight: Claude が Codex を worker として委譲起動する前に行う、capability と
# 境界の決定的検査 (#254。規範の正本は personal-codex-worker skill の「起動前 preflight」)。
#
# 何を守るか: worker の Codex に、GitHub connector (account 側の app)、MCP server (config.toml
# で定義したもの、ChatGPT app が Codex home に足す bootstrap のもの)、computer / browser 系の
# tool を持たせない。MCP server は Codex の command sandbox の外で動く process で、bootstrap の
# JS REPL は特に境界の穴になる。approval policy は「承認を求める操作は失敗する」側に固定するが、
# それで止まるのは承認を求める操作だけで、connector tool ごとの承認設定が自動承認なら素通りする。
#
# 実測 (2026-09-22、codex 0.154.0) で唯一これらを全部外せた起動形:
#   codex exec --ignore-user-config -s workspace-write -c approval_policy="never"
#     --disable apps --disable computer_use --disable browser_use
#     -c model="<user config の model>" -c model_reasoning_effort="<同 effort>" -o <result> -
# `--ignore-user-config` で config.toml と bootstrap の MCP server が読まれなくなり (AGENTS.md
# と skills は読まれ、linked worktree での commit も通る)、`--disable apps` で account 側の
# connector が消える。`-c mcp_servers.<name>.enabled=false` は config.toml に無い bootstrap の
# server に対して config load を落とす (invalid transport) ので使わない。model / effort は
# user config が読まれなくなる分を再指定する (無ければ Codex の既定に委ねる)。
#
# 判定 (fail-closed):
# - exit 1 (BLOCKED): Codex の session 内 (CODEX_SANDBOX / CODEX_THREAD_ID) から呼ばれた
#   (委譲は Claude → Codex の一方通行) / codex CLI が無い・版が読めない / `codex exec --help` に
#   要る flag が無い / `codex features list` に disable 対象の feature 行が無い
# - exit 2 (検査できない): usage / user config の model / model_reasoning_effort を一意に読めない
#   (top-level に同じ key が複数ある、値が argv に安全に埋められない文字を含む)
# - exit 0: 起動可。stdout に検査結果と launch argv (`--json` なら JSON 1 個)
#
# model / effort の読み取りは、config.toml の最初の table header より前 (top-level) にある
# `model = "…"` / `model_reasoning_effort = "…"` の行だけを見る最小解釈で、TOML parser は
# 持たない。読めるのは model の選択だけで境界には関わらず、選ばれた model は起動 log に出る。
# 同じ key が 2 回以上あれば (複数行文字列の中身を拾った疑いを含む) fail-closed にする。
#
# 検査しないこと (honest): 実際の tool surface。起動して model に列挙させないと分からないので、
# 本 script は決定的に読めるものだけを見る。surface の実測は acceptance probe に置く。
# 副作用ゼロ・network なし。読むのは codex / herdr の help・status・feature 一覧と、user config
# の 2 行だけ。値は argv 配列で下位 command に渡し、shell を介さない。出力に config の他の値は
# 載せない。`--codex-home DIR` は config.toml の場所の上書き。

require "json"

module CodexWorkerPreflight
  VERSION = "4"

  # 起動時に `--disable` で外す feature。`codex features list` に行が無ければ BLOCKED
  # (存在しない feature を disable しようとして CLI が止まる形へ倒さない)。
  DISABLE_FEATURES = %w[apps computer_use browser_use].freeze

  # `codex exec --help` に無ければ BLOCKED にする marker (名前 => help 本文に現れる文字列)。
  REQUIRED_HELP_MARKERS = {
    "sandbox flag" => "--sandbox",
    "workspace-write mode" => "workspace-write",
    "config override" => "--config",
    "feature disable" => "--disable",
    "user config ignore" => "--ignore-user-config",
    "result file" => "--output-last-message",
    "stdin prompt" => "`-`",
  }.freeze

  # user config から再指定する key (TOML key => launch argv に載せる config key)。
  MODEL_KEYS = %w[model model_reasoning_effort].freeze
  # `-c key="value"` の value は TOML の basic string として解釈されるので、引用符や escape を
  # 含まない文字だけを通す。
  MODEL_VALUE_RE = /\A[A-Za-z0-9._-]+\z/

  Blocked = Class.new(StandardError)

  module_function

  def usage
    "usage: personal-codex-worker-preflight [--codex-home DIR] [--json]"
  end

  # 下位 command を argv 配列で起動して stdout + stderr を読む。exit 0 以外と不在は nil。
  def run_capture(argv)
    out = IO.popen(argv, err: [:child, :out], &:read)
    $?.success? ? out : nil
  rescue Errno::ENOENT
    nil
  end

  def parse_version(out)
    m = /codex-cli (\d+\.\d+\.\d+)/.match(out.to_s)
    m && m[1]
  end

  def missing_help_markers(help)
    text = help.to_s
    REQUIRED_HELP_MARKERS.reject { |_, marker| text.include?(marker) }.keys
  end

  # `codex features list` の行 (`<name>  <stage>  <true|false>`、列は 2 空白以上) を読む。
  def parse_features(out)
    features = {}
    out.to_s.each_line do |line|
      m = /\A(\S+)\s{2,}(.+?)\s{2,}(true|false)\s*\z/.match(line.chomp)
      next unless m

      features[m[1]] = { stage: m[2], enabled: m[3] == "true" }
    end
    features
  end

  # config.toml の top-level (最初の table header より前) から model / model_reasoning_effort を
  # 読む。無ければ nil (Codex の既定に委ねる)。同じ key が 2 回以上、または値が安全に埋められない
  # 形なら fail-closed (ArgumentError → exit 2)。
  def read_model_selection(text)
    found = Hash.new { |h, k| h[k] = [] }
    text.to_s.each_line do |raw|
      line = raw.chomp.sub(/\r\z/, "")
      break if line.lstrip.start_with?("[")

      km = /\A\s*(model|model_reasoning_effort)\s*=\s*(.*)\z/.match(line)
      next unless km

      # key があるのに basic string 1 行の形でなければ、黙って「無し」に倒さず fail-closed。
      vm = /\A"([^"]*)"\s*(?:#.*)?\z/.match(km[2])
      raise ArgumentError, "user config の #{km[1]} を安全に読めません (1 行の basic string だけ対応)" unless vm

      found[km[1]] << vm[1]
    end
    selection = {}
    MODEL_KEYS.each do |key|
      values = found[key]
      next if values.empty?
      raise ArgumentError, "user config の #{key} が top-level に複数あり一意に読めません" if values.size > 1
      raise ArgumentError, "user config の #{key} の値に argv へ安全に埋められない文字があります" unless values.first.match?(MODEL_VALUE_RE)

      selection[key] = values.first
    end
    selection
  end

  def herdr_state
    out = run_capture(%w[herdr status])
    out && out.include?("status: running") ? "running" : "unavailable"
  end

  # 起動 argv。`<run dir>` は launcher が run directory に置き換える placeholder。
  def launch_argv(features, selection)
    argv = ["codex", "exec", "--ignore-user-config", "-s", "workspace-write", "-c", 'approval_policy="never"']
    features.each { |f| argv.push("--disable", f) }
    MODEL_KEYS.each { |key| argv.push("-c", "#{key}=\"#{selection[key]}\"") if selection[key] }
    argv.push("-o", "<run dir>/result.md", "-")
  end

  def codex_home(override)
    return override if override

    env = ENV["CODEX_HOME"].to_s
    env.empty? ? File.join(Dir.home, ".codex") : env
  end

  def parse_args(argv)
    opts = { codex_home: nil, json: false }
    args = argv.dup
    until args.empty?
      arg = args.shift
      case arg
      when "--json" then opts[:json] = true
      when "--codex-home"
        dir = args.shift
        raise ArgumentError, usage if dir.nil? || dir.empty? || dir.start_with?("-")

        opts[:codex_home] = dir
      else
        raise ArgumentError, usage
      end
    end
    opts
  end

  def inspect_environment(opts)
    if ENV.key?("CODEX_SANDBOX") || ENV.key?("CODEX_THREAD_ID")
      raise Blocked, "asymmetry: Codex の session 内から worker は起動しない (委譲は Claude → Codex の一方通行)"
    end

    version = parse_version(run_capture(%w[codex --version]))
    raise Blocked, "capability: codex CLI が無いか、版を読めません" unless version

    help = run_capture(%w[codex exec --help])
    raise Blocked, "capability: `codex exec --help` を読めません" unless help

    missing = missing_help_markers(help)
    raise Blocked, "capability: codex exec に無い flag: #{missing.join(', ')}" unless missing.empty?

    features_out = run_capture(%w[codex features list])
    raise Blocked, "capability: `codex features list` を読めません" unless features_out

    features = parse_features(features_out)
    absent = DISABLE_FEATURES.reject { |f| features.key?(f) }
    raise Blocked, "capability: features list に無い feature (disable できない): #{absent.join(', ')}" unless absent.empty?

    config_path = File.join(codex_home(opts[:codex_home]), "config.toml")
    selection = read_model_selection(File.file?(config_path) ? File.read(config_path, encoding: "UTF-8") : "")

    {
      status: "ok",
      codex_version: version,
      disable_features: DISABLE_FEATURES.dup,
      model: selection["model"],
      model_reasoning_effort: selection["model_reasoning_effort"],
      herdr: herdr_state,
      launch_argv: launch_argv(DISABLE_FEATURES, selection),
    }
  end

  def print_text(r)
    puts "codex: #{r[:codex_version]}"
    puts "exec flags: ok"
    puts "disable features: #{r[:disable_features].join(' ')}"
    puts "model: #{r[:model] || '(codex default)'}"
    puts "model_reasoning_effort: #{r[:model_reasoning_effort] || '(codex default)'}"
    puts "herdr: #{r[:herdr]}"
    puts "launch: #{r[:launch_argv].join(' ')}"
  end

  def run(argv)
    opts = parse_args(argv)
    result = inspect_environment(opts)
    opts[:json] ? puts(JSON.generate(result)) : print_text(result)
    0
  rescue Blocked => e
    stage, reason = e.message.split(": ", 2)
    if opts && opts[:json]
      puts JSON.generate(status: "BLOCKED", blocked_at: stage, reason: reason)
    else
      warn "codex-worker-preflight: BLOCKED (#{stage}): #{reason}"
    end
    1
  rescue ArgumentError => e
    warn "codex-worker-preflight: error: #{e.message}"
    2
  rescue StandardError => e
    warn "codex-worker-preflight: unexpected error (#{e.class})"
    2
  end
end

exit CodexWorkerPreflight.run(ARGV) if $PROGRAM_NAME == __FILE__
