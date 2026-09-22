#!/usr/bin/env ruby
# frozen_string_literal: true

# codex-worker-preflight: Claude が Codex を worker として委譲起動する前に行う、capability と
# 境界の決定的検査 (#254。規範の正本は personal-codex-worker skill の「起動前 preflight」)。
#
# 何を守るか: worker の Codex に GitHub connector (account 側の app) や MCP server の tool を
# 持たせない。approval policy は「承認を求める操作は失敗する」側に固定するが、それで止まるのは
# 承認を求める操作だけで、connector tool ごとの承認設定 (approval_mode) が自動承認なら素通り
# する (2026-09-22、codex 0.154.0 で実測)。`--ignore-user-config` でも connector は消えない
# (account 側の設定)。消えるのは `--disable apps` と `-c mcp_servers.<id>.enabled=false` で、
# 本 script はそれを組める前提 (CLI の flag / feature 行 / config の server 一覧) を検査し、
# 起動 argv を出す。
#
# 判定 (fail-closed):
# - exit 1 (BLOCKED): Codex の session 内 (CODEX_SANDBOX / CODEX_THREAD_ID) から呼ばれた
#   (委譲は Claude → Codex の一方通行) / codex CLI が無い・版が読めない / `codex exec --help` に
#   要る flag が無い / `codex features list` に disable 対象の feature 行が無い
# - exit 2 (検査できない): usage / Codex home の config を安全に解釈できない (header を tokenize
#   できない、mcp_servers の id が bare key でない、`[mcp_servers.<id>]` table 以外の表記
#   (dotted key / inline table / 親 table 直下の key) で server が定義されている、複数行文字列が
#   閉じていない) / 下位 command の出力を読めない
# - exit 0: 起動可。stdout に検査結果と launch argv (`--json` なら JSON 1 個)
#
# config の読み方は行単位の最小解釈で、読むのは mcp_servers の section id と apps の tool ごとの
# approval_mode だけ。TOML parser を持たないので、server の列挙が欠けうる表記は「読める」に
# 倒さず exit 2 にする。mcp_servers 以外の section は quoted な id でも読み飛ばす (個人の config
# には plugins の quoted section がある)。
#
# 検査しないこと (honest): 実際の tool surface。起動して model に列挙させないと分からないので、
# 本 script は決定的に読めるものだけを見る。surface の実測は acceptance probe に置く。
# 副作用ゼロ・network なし。読むのは codex / herdr の help・status・feature 一覧と、Codex home
# の config のみ。値は argv 配列で下位 command に渡し、shell を介さない。出力に config の
# 値そのもの (path / URL / policy 等の生値) は載せず、section id と件数だけを出す。

require "json"

module CodexWorkerPreflight
  VERSION = "2"

  # 起動時に `--disable` で外す feature。`codex features list` に行が無ければ BLOCKED
  # (存在しない feature を disable しようとして CLI が止まる形へ倒さない)。
  DISABLE_FEATURES = %w[apps computer_use browser_use].freeze

  # `codex exec --help` に無ければ BLOCKED にする marker (名前 => help 本文に現れる文字列)。
  REQUIRED_HELP_MARKERS = {
    "sandbox flag" => "--sandbox",
    "workspace-write mode" => "workspace-write",
    "config override" => "--config",
    "feature disable" => "--disable",
    "result file" => "--output-last-message",
    "stdin prompt" => "`-`",
  }.freeze

  BARE_KEY_RE = /\A[A-Za-z0-9_-]+\z/
  # key 行: bare / dotted bare / quoted な key と `=` 以降の生の値。
  KEY_LINE_RE = /\A\s*([A-Za-z0-9_-]+(?:\s*\.\s*[A-Za-z0-9_-]+)*|"(?:[^"\\]|\\.)*"|'[^']*')\s*=\s*(.*)\z/
  MULTILINE_DELIMS = ['"""', "'''"].freeze
  AUTO_APPROVE_MODES = %w[approve auto].freeze

  Blocked = Class.new(StandardError)
  ConfigError = Class.new(ArgumentError)

  module_function

  def usage
    "usage: personal-codex-worker-preflight [--codex-home DIR] [--json]"
  end

  # 下位 command を argv 配列で起動して stdout + stderr を読む。無ければ nil。
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

  # Codex home の config.toml を行単位で読む。返すのは mcp_servers の section id と、apps の
  # tool ごとの approval_mode が自動承認になっている件数だけ。
  def parse_config(text)
    result = { mcp_servers: [], apps_auto_approve_tools: 0 }
    section = nil   # nil = top-level、それ以外は [[name, :bare|:quoted], ...]
    multiline = nil # 複数行文字列の閉じ delimiter を待っている間だけ non-nil
    text.each_line do |raw|
      line = raw.chomp.sub(/\r\z/, "")
      if multiline
        multiline = nil if line.include?(multiline)
        next
      end

      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      if stripped.start_with?("[")
        section = parse_section_header(stripped)
        register_mcp_section(result, section)
        next
      end

      multiline = inspect_key_line(result, section, line)
    end
    raise ConfigError, "config の複数行文字列が閉じていません" if multiline

    result[:mcp_servers].uniq!
    result
  end

  # `[a.b."c"]` を segment の配列にする。tokenize できない header は fail-closed。
  def parse_section_header(line)
    raise ConfigError, "config の array table ([[...]]) は未対応です" if line.start_with?("[[")

    m = /\A\[(.*)\]\s*(?:#.*)?\z/.match(line)
    raise ConfigError, "config の section header を解釈できません" unless m

    tokenize_key_path(m[1])
  end

  # dotted key path を [[name, :bare|:quoted], ...] にする。segment は bare / basic string /
  # literal string。それ以外 (空 segment、閉じていない引用、末尾の dot) は fail-closed。
  def tokenize_key_path(path)
    s = path.strip
    raise ConfigError, "config の section header を解釈できません" if s.empty?

    segments = []
    pos = 0
    loop do
      rest = s[pos..-1]
      if (m = /\A([A-Za-z0-9_-]+)/.match(rest))
        segments << [m[1], :bare]
      elsif (m = /\A"((?:[^"\\]|\\.)*)"/.match(rest))
        segments << [m[1], :quoted]
      elsif (m = /\A'([^']*)'/.match(rest))
        segments << [m[1], :quoted]
      else
        raise ConfigError, "config の section header を解釈できません"
      end
      pos += m[0].size
      rest = s[pos..-1]
      break if rest.empty?

      dot = /\A\s*\.\s*/.match(rest)
      raise ConfigError, "config の section header を解釈できません" if dot.nil? || dot[0].size == rest.size

      pos += dot[0].size
    end
    segments
  end

  # `[mcp_servers.<id>]` だけを server として数える。親 table `[mcp_servers]` は server ではない。
  # id が quoted なら `-c mcp_servers.<id>.enabled=false` に安全に埋められないので fail-closed。
  def register_mcp_section(result, segments)
    return unless segments.first == ["mcp_servers", :bare]
    return if segments.size == 1

    id, kind = segments[1]
    raise ConfigError, "config の mcp_servers の id は bare key だけ対応しています" unless kind == :bare

    result[:mcp_servers] << id
  end

  def apps_tool_section?(segments)
    segments.size == 4 && segments[0][0] == "apps" && segments[2][0] == "tools"
  end

  # key 行を見て、(1) server 列挙が欠けうる表記 (top-level の `mcp_servers.…` / `mcp_servers = {…}`、
  # 親 table `[mcp_servers]` 直下の key) は fail-closed、(2) apps tool の approval_mode を数え、
  # (3) 複数行文字列が開いたらその delimiter を返す (呼び出し側が閉じるまで読み飛ばす)。
  def inspect_key_line(result, section, line)
    m = KEY_LINE_RE.match(line)
    return nil unless m

    key, value = m[1], m[2]
    if section.nil? && key.match?(/\Amcp_servers(\s*\.|\z)/)
      raise ConfigError, "config の mcp_servers は [mcp_servers.<id>] table 以外の表記に未対応です"
    end
    if section == [["mcp_servers", :bare]]
      raise ConfigError, "config の mcp_servers は [mcp_servers.<id>] table 以外の表記に未対応です"
    end

    if (delim = multiline_open(value))
      return delim
    end

    if section && apps_tool_section?(section) && key == "approval_mode" &&
       (sv = /\A"([^"]*)"/.match(value)) && AUTO_APPROVE_MODES.include?(sv[1])
      result[:apps_auto_approve_tools] += 1
    end
    nil
  end

  # 値が複数行文字列を開いて同じ行で閉じていなければ、その delimiter を返す。
  def multiline_open(value)
    MULTILINE_DELIMS.each do |delim|
      next unless value.start_with?(delim)
      return delim unless value[delim.size..-1].include?(delim)
    end
    nil
  end

  def herdr_state
    out = run_capture(%w[herdr status])
    out && out.include?("status: running") ? "running" : "unavailable"
  end

  # 起動 argv。`<run dir>` は launcher が run directory に置き換える placeholder。
  def launch_argv(mcp_ids, features)
    argv = ["codex", "exec", "-s", "workspace-write", "-c", 'approval_policy="never"']
    features.each { |f| argv.push("--disable", f) }
    mcp_ids.each { |id| argv.push("-c", "mcp_servers.#{id}.enabled=false") }
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
    config = parse_config(File.file?(config_path) ? File.read(config_path, encoding: "UTF-8") : "")

    {
      status: "ok",
      codex_version: version,
      disable_features: DISABLE_FEATURES.dup,
      mcp_servers: config[:mcp_servers],
      apps_auto_approve_tools: config[:apps_auto_approve_tools],
      herdr: herdr_state,
      launch_argv: launch_argv(config[:mcp_servers], DISABLE_FEATURES),
    }
  end

  def print_text(r)
    puts "codex: #{r[:codex_version]}"
    puts "exec flags: ok"
    puts "disable features: #{r[:disable_features].join(' ')}"
    puts "mcp servers: #{r[:mcp_servers].empty? ? '(none)' : r[:mcp_servers].join(' ')}"
    puts "apps auto-approve tools: #{r[:apps_auto_approve_tools]} (apps は --disable するので起動には影響しない)"
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
