#!/usr/bin/env ruby
# frozen_string_literal: true

# codex-worker-preflight: Claude が Codex を worker として委譲起動する前に行う、capability と
# 境界の決定的検査 (#254。規範の正本は personal-codex-worker skill の「起動前 preflight」)。
#
# 何を守るか: worker の Codex に、GitHub connector (account 側の app)、MCP server (config.toml
# で定義したもの、ChatGPT app が Codex home に足す bootstrap のもの)、computer / browser 系の
# tool、execpolicy の allow rule (一致した command を追加承認なしに sandbox 外で実行しうる) を
# 持たせない。MCP server は Codex の command sandbox の外で動く process で、bootstrap の JS REPL
# は特に境界の穴になる。approval policy は「承認を求める操作は失敗する」側に固定するが、それで
# 止まるのは承認を求める操作だけで、connector tool ごとの承認設定が自動承認なら素通りする。
#
# 実測 (2026-09-22、codex 0.154.0) で唯一これらを全部外せた起動形:
#   codex exec --ignore-user-config --ignore-rules -s workspace-write -c approval_policy="never"
#     --disable apps --disable computer_use --disable browser_use
#     [-c model="<user config の model>"] [-c model_reasoning_effort="<同 effort>"] -o <result> -
# `--ignore-user-config` で config.toml と bootstrap の MCP server が読まれなくなり (AGENTS.md
# と skills は読まれる。worker は main の clone で動かし、その clone の git dir だけを `--add-dir` で
# 開ける (`workspace-write` は workdir の内側でも `.git` を保護するため。#307)、`--disable apps` で account 側の
# connector が消える。`-c mcp_servers.<name>.enabled=false` は config.toml に無い bootstrap の
# server に対して config load を落とす (invalid transport) ので使わない。`--ignore-rules` は
# user / project の execpolicy `.rules` を読まない指定 (`--ignore-user-config` とは別)。
# model / effort は user config が読まれなくなる分を再指定する。
#
# model / effort の出所は 2 つ。`--model` / `--effort` で明示されればそれを使い config は
# 読まない。無ければ config.toml の top-level (最初の table header より前) から `model` /
# `model_reasoning_effort` を読む。TOML parser は持たないので、top-level の各行を
# 「空行 / comment / `bare_key = <1 行で閉じる scalar か平坦な配列>`」だけに分類し、それ以外の行
# (複数行文字列、複数行の配列、入れ子や `#` `[` `]` を要素に含む配列、inline table、quoted /
# dotted key、escape を含む文字列) が 1 つでもあれば、model を「無し」に倒さず fail-closed
# (exit 2) にする。独立した検査は持たず、この分類 1 本で判定する (除去しても捕捉できない冗長な
# 検査を置かない)。remedy は `--model` / `--effort` の明示。model / effort の値は basic string
# 1 行で、charset は `[A-Za-z0-9._-]+` に限る。
#
# 判定:
# - exit 1 (BLOCKED): Codex の session 内 (CODEX_SANDBOX / CODEX_THREAD_ID) から呼ばれた
#   (委譲は Claude → Codex の一方通行) / codex CLI が無い・版が読めない / `codex exec --help` に
#   要る flag が無い / `codex features list` に disable 対象の feature 行が無い。Codex の 3 command
#   (`--version` / `exec --help` / `features list`) は exit 0 のときだけ出力を信用する
# - exit 2 (検査できない): usage / user config の top-level を安全に解釈できない / model・effort の
#   値が不正
# - exit 0: 起動可。stdout に検査結果と launch argv (`--json` なら JSON 1 個)
#
# herdr の状態 (`herdr status`) は起動経路 (herdr pane か直接か) を launcher が選ぶための任意の
# 表示で、herdr が無い・止まっていても BLOCKED にはしない (上の exit 非ゼロ規則の対象外)。
#
# 検査しないこと (honest): 実際の tool surface と、allow rule が本当に無効になるか。起動して
# 確かめるしかないので acceptance probe に置く。副作用ゼロ・network なし。読むのは codex / herdr
# の help・status・feature 一覧と、user config の top-level だけ。値は argv 配列で下位 command に
# 渡し、shell を介さない。出力に model / effort 以外の config の値は載せない。`--codex-home DIR`
# は config.toml の場所の上書き。

require "json"
require "digest"

module CodexWorkerPreflight
  VERSION = "6"
  GIT_MUTABLE_FILES = %w[HEAD index COMMIT_EDITMSG ORIG_HEAD packed-refs].freeze
  GIT_MUTABLE_DIRS = %w[objects refs logs].freeze

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
    "rules ignore" => "--ignore-rules",
    "result file" => "--output-last-message",
    "extra writable dir" => "--add-dir",
    "stdin prompt" => "`-`",
  }.freeze

  # user config から再指定する key (option 名 => TOML / config key)。
  MODEL_KEYS = { "--model" => "model", "--effort" => "model_reasoning_effort" }.freeze
  # `-c key="value"` の value は TOML の basic string として解釈されるので、引用符や escape を
  # 含まない文字だけを通す。
  MODEL_VALUE_RE = /\A[A-Za-z0-9._-]+\z/

  # 配列の要素として受け入れる形: `#` / `[` / `]` / escape を含まない basic string、literal
  # string、bare scalar。入れ子や、comment 文字・括弧を含む文字列は受け入れない (その行で配列が
  # 閉じたかを文脈なしに判定できないため。fail-closed)。
  ARRAY_ITEM = /(?:"[^"\\#\[\]]*"|'[^'#\[\]]*'|[A-Za-z0-9._:+-]+)/

  # top-level の行として受け入れる形 (これ以外は fail-closed)。value は 1 行で閉じる
  # basic string / literal string / bare scalar / 平坦な配列のどれか。
  TOP_LEVEL_LINE_RE = %r{
    \A\s*(?<key>[A-Za-z0-9_-]+)\s*=\s*
    (?:"(?<basic>[^"\\]*)"|'[^']*'|[A-Za-z0-9._:+-]+
      |\[\s*(?:#{ARRAY_ITEM}(?:\s*,\s*#{ARRAY_ITEM})*\s*,?)?\s*\])
    \s*(?:\#.*)?\z
  }x

  # repository の選択を変える env。preflight の検査と、起動する worker の実行環境がずれるので、
  # 1 つでも立っていたら検査自体を信じない (exit 2)。
  REPO_SELECTING_ENV = %w[
    GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE
    GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
    GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  ].freeze
  # `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` は個数が動くので prefix で見る。
  REPO_SELECTING_ENV_PREFIX = %w[GIT_CONFIG_KEY_ GIT_CONFIG_VALUE_].freeze

  Blocked = Class.new(StandardError)

  module_function

  def usage
    "usage: personal-codex-worker-preflight --clone DIR [--codex-home DIR] [--model NAME] " \
      "[--effort LEVEL] [--json] | --verify-git-snapshot FILE --clone DIR"
  end

  # `.git` snapshot の allowlist は Git が commit / ref 更新に書く領域だけ。
  # file type も記録し、許可領域内でも既存の固定 file / directory の型変更は許可しない。
  def mutable_git_path?(path)
    GIT_MUTABLE_FILES.include?(path) || GIT_MUTABLE_DIRS.any? { |dir| path == dir || path.start_with?(dir + "/") }
  end

  def valid_mutable_entry?(path, entry)
    return true unless entry
    return entry["type"] == "file" if GIT_MUTABLE_FILES.include?(path)
    return entry["type"] == "dir" if GIT_MUTABLE_DIRS.include?(path)

    return false if entry["type"] == "symlink" || entry["type"] == "other"

    true
  end

  def git_snapshot(root)
    entries = {}
    walk = lambda do |dir, prefix|
      Dir.children(dir).sort.each do |name|
        path = [prefix, name].reject(&:empty?).join("/")
        full = File.join(dir, name)
        stat = File.lstat(full)
        entry = if stat.symlink?
                  { "type" => "symlink", "target" => File.readlink(full) }
                elsif stat.directory?
                  { "type" => "dir" }
                elsif stat.file?
                  { "type" => "file", "sha256" => Digest::SHA256.file(full).hexdigest }
                else
                  { "type" => "other" }
                end
        entries[path] = entry
        walk.call(full, path) if stat.directory?
      end
    end
    walk.call(root, "")
    entries
  end

  def snapshot_git_dir(path)
    raise ArgumentError, "snapshot: .git が directory ではありません" unless File.directory?(path) && !File.symlink?(path)

    entries = git_snapshot(path)
    { "schema" => 1, "git_dir" => File.realpath(path), "entries" => entries }
  end

  def verify_git_snapshot(snapshot_path, clone_path)
    document = JSON.parse(File.read(snapshot_path, encoding: "UTF-8"))
    snapshot = document.is_a?(Hash) ? (document["git_snapshot"] || document) : nil
    unless snapshot.is_a?(Hash) && snapshot["schema"] == 1 && snapshot["entries"].is_a?(Hash)
      raise ArgumentError, "snapshot: 形式が不正です"
    end
    root = File.realpath(clone_path)
    git_dir = File.join(root, ".git")
    unless snapshot["git_dir"] == git_dir
      raise ArgumentError, "snapshot: clone の .git path が一致しません"
    end
    unless File.directory?(git_dir) && !File.symlink?(git_dir) && File.realpath(git_dir) == git_dir
      raise ArgumentError, "snapshot: .git が directory ではありません"
    end
    current = git_snapshot(git_dir)
    before = snapshot["entries"]
    paths = (before.keys | current.keys).sort
    changed = paths.select do |path|
      if mutable_git_path?(path)
        !valid_mutable_entry?(path, before[path]) || !valid_mutable_entry?(path, current[path])
      else
        before[path] != current[path]
      end
    end
    unless changed.empty?
      raise ArgumentError, "snapshot: allowlist 外の .git entry が変化しました: #{changed.join(', ')}"
    end
    true
  rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => e
    raise ArgumentError, "snapshot: 読み取りまたは照合に失敗しました (#{e.class})"
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

  # config.toml の top-level から model / model_reasoning_effort を読む。無ければ空 (Codex の
  # 既定に委ねる)。top-level に分類できない行があれば、その行が model と無関係でも fail-closed
  # (複数行文字列の中身を key として拾う経路を残さないため)。
  def read_model_selection(text)
    found = Hash.new { |h, k| h[k] = [] }
    text.to_s.each_line do |raw|
      line = raw.chomp.sub(/\r\z/, "")
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")
      break if stripped.start_with?("[")

      m = TOP_LEVEL_LINE_RE.match(line)
      raise ArgumentError, "user config の top-level に解釈できない行があります (--model / --effort で明示してください)" unless m

      key = m[:key]
      next unless MODEL_KEYS.value?(key)
      raise ArgumentError, "user config の #{key} は basic string 1 行の形だけ対応しています" if m[:basic].nil?

      found[key] << m[:basic]
    end
    selection = {}
    MODEL_KEYS.each_value do |key|
      values = found[key]
      next if values.empty?
      raise ArgumentError, "user config の #{key} が top-level に複数あり一意に読めません" if values.size > 1

      selection[key] = validate_model_value(key, values.first)
    end
    selection
  end

  def validate_model_value(key, value)
    raise ArgumentError, "#{key} の値に argv へ安全に埋められない文字があります" unless value.to_s.match?(MODEL_VALUE_RE)

    value
  end

  def herdr_state
    out = run_capture(%w[herdr status])
    out && out.include?("status: running") ? "running" : "unavailable"
  end

  # 起動 argv。`<run dir>` は launcher が run directory に置き換える placeholder。
  # `--add-dir` は **worker 自身の clone の git dir 1 つだけ**。workspace-write の sandbox は workdir の
  # 内側でも `.git` を保護するため、これが無いと worker は commit できない (codex 0.154.0 で実測)。
  # main の Git 管理領域は渡さない (validate_clone が orchestrator の repository を拒否する)。
  def launch_argv(features, selection, clone_git_dir)
    argv = ["codex", "exec", "--ignore-user-config", "--ignore-rules", "-s", "workspace-write",
            "-c", 'approval_policy="never"']
    features.each { |f| argv.push("--disable", f) }
    argv.push("--add-dir", clone_git_dir)
    MODEL_KEYS.each_value { |key| argv.push("-c", "#{key}=\"#{selection[key]}\"") if selection[key] }
    argv.push("-o", "<run dir>/result.md", "-")
  end

  # worker を動かす clone の検査。満たさなければ ArgumentError (exit 2) で、launch argv を作らない。
  # 返すのは `--add-dir` に渡す git dir の物理 path。
  def validate_clone(path)
    set_env = REPO_SELECTING_ENV.select { |v| ENV.key?(v) } +
              ENV.keys.select { |k| REPO_SELECTING_ENV_PREFIX.any? { |pre| k.start_with?(pre) } }
    set_env = set_env.uniq.sort
    unless set_env.empty?
      raise ArgumentError, "clone: repository を選ぶ環境変数が立っています (検査と起動がずれる): " \
        "#{set_env.join(', ')}"
    end

    raise ArgumentError, "clone: directory ではありません: #{path}" unless File.directory?(path)

    root = real_path(path)
    raise ArgumentError, "clone: path を解決できません: #{path}" unless root

    entry = File.join(root, ".git")
    # `.git` が symlink だと、解決先 (例: main の git dir) を開けてしまうので、entry 自体が
    # **その clone の中にある実体の directory** であることを要求する。
    if File.symlink?(entry)
      raise ArgumentError, "clone: <clone>/.git が symlink です (解決先を開けない): #{path}"
    end

    git_dir = real_path(entry)
    unless git_dir && File.directory?(git_dir)
      raise ArgumentError, "clone: <clone>/.git が directory ではありません (linked worktree は不可): #{path}"
    end
    # root は realpath 済みで、entry の symlink も上で弾いてあるので、通常の入力ではここは常に等しい。
    # 検査の途中で `.git` が symlink に差し替わる競合を狭めるための defense-in-depth で、
    # **self-test の変異では捕捉できない** (競合を作らないと到達しない)。完全には防げず、
    # honest-label は LAUNCH の §3 に書いてある。
    unless git_dir == entry
      raise ArgumentError, "clone: <clone>/.git の解決先が clone の外です: #{path}"
    end

    resolved = run_capture(["git", "-C", root, "rev-parse", "--absolute-git-dir"]).to_s.strip
    actual = resolved.empty? ? nil : real_path(resolved)
    unless actual == git_dir
      raise ArgumentError, "clone: git repository の git dir が <clone>/.git と一致しません: #{path}"
    end

    # orchestrator 自身の Git 管理領域を渡させない。**worktree root ではなく common git dir** を
    # 比べる (orchestrator が linked worktree に居ると root は違うが、同じ object store を指す)。
    # 判定できないときも通さない (preflight は orchestrator の repository の中から実行する)。
    self_common = common_git_dir(nil)
    unless self_common
      raise ArgumentError, "clone: orchestrator の repository を確認できません " \
        "(repository の中から実行してください)"
    end
    clone_common = common_git_dir(root)
    # `.git` が実 directory でも、その中の `commondir` file で common dir を別の場所へ向けられる
    # (実測: `--absolute-git-dir` は `<clone>/.git` のまま、`--git-common-dir` だけが別 repository を
    # 指す)。許可するのは `<clone>/.git` なので、common dir がそれと同じであることを要求する。
    if clone_common && clone_common != git_dir
      raise ArgumentError, "clone: git の common dir が <clone>/.git と一致しません " \
        "(commondir による切替は不可): #{path}"
    end
    # ここも defense-in-depth: 直前の `--absolute-git-dir` が通っていれば common dir も取れるので、
    # **self-test の変異では捕捉できない**。git 側の挙動が変わったときに黙って通さないための保険。
    unless clone_common
      raise ArgumentError, "clone: clone の git 管理領域を確認できません: #{path}"
    end
    # 等値だけでなく **包含**も拒否する。submodule の中から superproject を渡すと
    # self_common (`<super>/.git/modules/<sub>`) は clone_common (`<super>/.git`) の内側にあり、
    # 等値検査だけでは通ってしまう (実測)。開ける git_dir が自分の管理領域を含む形も同じ。
    # (`git_dir` は上の検査で clone_common と同じ dir に決まっているので、ここでは common dir の
    #  2 方向だけを見る)
    if contains_path?(clone_common, self_common) || contains_path?(self_common, clone_common)
      raise ArgumentError, "clone: orchestrator 自身の Git 管理領域を含みます " \
        "(main / linked worktree / submodule の親子は不可)"
    end

    # Git が認識する worktree root が検査した root と一致すること。`core.worktree` で作業ツリーを
    # すげ替えた repository と bare repository をここで落とす (実測: repo-local な core.worktree は
    # `--show-toplevel` を別 dir にする / bare は worktree 無しで失敗する)。
    toplevel_out = run_capture(["git", "-C", root, "rev-parse", "--path-format=absolute",
                                "--show-toplevel"]).to_s.strip
    toplevel = toplevel_out.empty? ? nil : real_path(toplevel_out)
    unless toplevel == root
      raise ArgumentError, "clone: Git が使う作業ツリーが clone と一致しません " \
        "(core.worktree / bare repository は不可): #{path}"
    end

    [root, git_dir]
  end

  # `parent` が `child` を含む (同一を含む) か。path component 単位で見る。
  def contains_path?(parent, child)
    return false unless parent && child

    child == parent || child.start_with?(parent.end_with?("/") ? parent : parent + "/")
  end

  # repository の common git dir (worktree を跨いで同じ object store を指す) の物理 path。
  # `repo` が nil なら cwd の repository。解決できなければ nil。
  def common_git_dir(repo)
    argv = ["git"]
    argv.push("-C", repo) if repo
    argv.push("rev-parse", "--path-format=absolute", "--git-common-dir")
    out = run_capture(argv).to_s.strip
    out.empty? ? nil : real_path(out)
  end

  def real_path(path)
    File.realpath(path)
  rescue SystemCallError
    nil
  end

  def codex_home(override)
    return override if override

    env = ENV["CODEX_HOME"].to_s
    env.empty? ? File.join(Dir.home, ".codex") : env
  end

  def parse_args(argv)
    opts = { codex_home: nil, clone: nil, json: false, explicit: {} }
    args = argv.dup
    until args.empty?
      arg = args.shift
      case arg
      when "--json" then opts[:json] = true
      when "--codex-home", "--clone", "--model", "--effort"
        value = args.shift
        raise ArgumentError, usage if value.nil? || value.empty? || value.start_with?("-")

        case arg
        when "--codex-home" then opts[:codex_home] = value
        when "--clone" then opts[:clone] = value
        else
          key = MODEL_KEYS.fetch(arg)
          opts[:explicit][key] = validate_model_value(key, value)
        end
      else
        raise ArgumentError, usage
      end
    end
    opts
  end

  # 明示 (--model / --effort) があれば config を読まない。片方だけ明示されたときも読まない
  # (config の解釈を「一部だけ」混ぜると出所が追えなくなる)。
  def model_selection(opts)
    return opts[:explicit] unless opts[:explicit].empty?

    config_path = File.join(codex_home(opts[:codex_home]), "config.toml")
    read_model_selection(File.file?(config_path) ? File.read(config_path, encoding: "UTF-8") : "")
  end

  def inspect_environment(opts)
    if ENV.key?("CODEX_SANDBOX") || ENV.key?("CODEX_THREAD_ID")
      raise Blocked, "asymmetry: Codex の session 内から worker は起動しない (委譲は Claude → Codex の一方通行)"
    end

    # --clone は必須 (worker は clone の中でしか動かさない)。非対称の判定を usage で隠さないよう、
    # asymmetry の後に置く。
    raise ArgumentError, usage if opts[:clone].nil?

    clone_root, clone_git_dir = validate_clone(opts[:clone])

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

    selection = model_selection(opts)

    {
      status: "ok",
      codex_version: version,
      disable_features: DISABLE_FEATURES.dup,
      model: selection["model"],
      model_reasoning_effort: selection["model_reasoning_effort"],
      model_source: opts[:explicit].empty? ? "config" : "explicit",
      herdr: herdr_state,
      clone_root: clone_root,
      clone_git_dir: clone_git_dir,
      git_snapshot: snapshot_git_dir(clone_git_dir),
      launch_argv: launch_argv(DISABLE_FEATURES, selection, clone_git_dir),
    }
  end

  def print_text(r)
    puts "codex: #{r[:codex_version]}"
    puts "exec flags: ok"
    puts "disable features: #{r[:disable_features].join(' ')}"
    puts "model: #{r[:model] || '(codex default)'} (#{r[:model_source]})"
    puts "model_reasoning_effort: #{r[:model_reasoning_effort] || '(codex default)'} (#{r[:model_source]})"
    puts "herdr: #{r[:herdr]}"
    puts "clone root: #{r[:clone_root]}"
    puts "clone git dir: #{r[:clone_git_dir]}"
    puts "launch: #{r[:launch_argv].join(' ')}"
  end

  def run(argv)
    if argv[0] == "--verify-git-snapshot"
      raise ArgumentError, usage unless argv.length == 4 && argv[2] == "--clone"

      verify_git_snapshot(argv[1], argv[3])
      puts "git snapshot: ok"
      return 0
    end
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
