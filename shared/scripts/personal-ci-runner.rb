#!/usr/bin/env ruby
# frozen_string_literal: true

# personal-ci-runner: 個人 project の private の repo の CI を、手元の machine の self-hosted runner で走らせる本体 (#803)。
# 1 job ごとに GitHub の just-in-time (JIT) の runner を作り、新しい container で動かし、終わったら登録を消す。
#
# 正本: docs/ci-runner.md。
#
# 強度ラベル (偽らない): 手順の守りであって境界ではない。守るのは、public の repo に runner を登録しないこと (起動のたびに
# API で private を確かめる)、人が設定に書いた repo だけを扱うこと、container に host の mount・docker の socket・gh の token を
# 渡さないこと、JIT の設定を host の argv・env・log・state・`docker inspect`・`docker top` に残さないこと。同じ container の
# job は、runner の process の初めの env から JIT の設定を読みうる (その 1 job の runner の資格に限られる)。
#
# 使い方: personal-ci-runner check | once <owner/repo> | cleanup
# - check: 設定を検査し、repo ごとに公開範囲 (private / public / unknown) を 1 行ずつ出す。runner は作らない。
# - once: 1 job の runner を 1 つ動かし、container が終わるまで待つ。終わったら登録を消す。
# - cleanup: state に記録した runner のうち、container が動いていないものの登録を消す。
# exit: 0 = 成功 / 1 = private でない・判定できない・起動や後片付けの失敗 / 2 = 使い方・設定の誤り / 3 = 同じ repo の once が動いている

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"

# C locale でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module CiRunner
  NAME = "personal-ci-runner"
  USAGE = "usage: #{NAME} check | once <owner/repo> | cleanup"
  EXIT_OK = 0
  EXIT_NOT_OK = 1
  EXIT_USAGE = 2
  EXIT_BUSY = 3

  HOST = "github.com"
  CONFIG_ENV = "AGENT_TOOLS_CI_RUNNER_CONFIG"
  STATE_ENV = "AGENT_TOOLS_CI_RUNNER_STATE_DIR"
  POLL_ENV = "AGENT_TOOLS_CI_RUNNER_POLL_SECONDS"
  CONFIG_KEYS = %w[docker_context image cpus memory_mb pids repos].freeze
  RANGES = { "cpus" => 1..16, "memory_mb" => 512..65_536, "pids" => 64..65_536 }.freeze
  MAX_REPOS = 20
  MAX_CONFIG_BYTES = 64 * 1024
  IMAGE_RE = %r{\Aghcr\.io/actions/actions-runner@sha256:[0-9a-f]{64}\z}.freeze
  CONTEXT_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/.freeze
  REPO_RE = %r{\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+\z}.freeze
  # JIT の設定は base64 の 1 行 (64 KiB まで)。外れたら container に渡さない。
  JIT_RE = %r{\A[A-Za-z0-9+/=]{1,65536}\z}.freeze
  RUNNER_PREFIX = "agent-tools-ci-"
  RUNNER_NAME_RE = /\Aagent-tools-ci-[0-9a-f]{16}\z/.freeze
  LABELS = %w[self-hosted linux arm64].freeze
  # repo の runner の既定の group
  RUNNER_GROUP_ID = 1
  CONTAINER_LABEL = "agent-tools.ci-runner"
  DEFAULT_POLL_SECONDS = 60
  POLL_RANGE = (1..3600).freeze
  STOP_SECONDS = 10
  # container の中の shell。stdin の 1 行を env に入れて、run.sh を引数なしで起動する (argv に JIT の設定を載せない)。
  INNER = 'IFS= read -r c || exit 90; export ACTIONS_RUNNER_INPUT_JITCONFIG="$c"; unset c; exec ./run.sh'
  TRAPPED_SIGNALS = %w[INT TERM HUP].freeze

  class UsageError < StandardError; end
  class ConfigError < StandardError; end

  # JSON の key の重なりを誤りにする object (JSON.parse の object_class)。
  class StrictObject < Hash
    def []=(key, value)
      raise ConfigError, "JSON の key が重なっています" if key?(key)

      super
    end
  end

  module_function

  def main(argv, out: $stdout, err: $stderr)
    unless ENV["GH_REPO"].to_s.empty? && ENV["GH_HOST"].to_s.empty?
      err.puts "#{NAME}: GH_REPO か GH_HOST が立っているので止めます (gh が別の repo や host を見るため)"
      return EXIT_USAGE
    end

    command, *rest = argv
    case command
    when "check"
      raise UsageError, "check は引数を取りません" unless rest.empty?

      check(load_config, out)
    when "once"
      raise UsageError, "once には repo を 1 つ渡します" unless rest.length == 1

      once(load_config, rest.first, out)
    when "cleanup"
      raise UsageError, "cleanup は引数を取りません" unless rest.empty?

      cleanup(load_config, out)
    else
      raise UsageError, "subcommand は check / once / cleanup です"
    end
  rescue UsageError => e
    err.puts "#{NAME}: #{e.message}"
    err.puts USAGE
    EXIT_USAGE
  rescue ConfigError => e
    err.puts "#{NAME}: 設定の誤り: #{e.message}"
    EXIT_USAGE
  rescue StandardError => e
    # 想定外の例外。message には外の値が入りうるので、class の名前だけを出す
    err.puts "#{NAME}: 想定外の失敗で止めました (#{e.class})"
    EXIT_NOT_OK
  end

  # ---- 設定 ------------------------------------------------------------------------------------------------------

  def config_path
    value = ENV[CONFIG_ENV].to_s
    value.empty? ? File.join(Dir.home, ".config", "agent-tools", "ci-runner.json") : value
  end

  # 設定を読む。人が手で書く file なので、symlink・regular file でないもの・自分の持ち物でないもの・group か other が書ける
  # もの (親の directory も) は誤りにする。「無い」は ENOENT だけ (#814 の review と同じ)。
  def load_config
    path = config_path
    raise ConfigError, "設定の path は絶対 path にします" unless path.start_with?(File::SEPARATOR)

    begin
      File.lstat(path)
    rescue Errno::ENOENT
      raise ConfigError, "設定がありません"
    end
    parent = File.lstat(File.dirname(path))
    raise ConfigError, "設定の親の directory を group か other が書けます" if (parent.mode & 0o022).positive?

    text = File.open(path, File::RDONLY | File::NOFOLLOW) do |f|
      st = f.stat
      raise ConfigError, "設定が regular file ではありません" unless st.file?
      raise ConfigError, "設定が自分の持ち物ではありません" unless st.uid == Process.uid
      raise ConfigError, "設定を group か other が書けます" if (st.mode & 0o022).positive?
      raise ConfigError, "設定が大きすぎます" if st.size > MAX_CONFIG_BYTES

      f.read
    end
    validate_config(JSON.parse(text, object_class: StrictObject))
  rescue Errno::ELOOP
    raise ConfigError, "設定が symlink です"
  rescue JSON::ParserError
    raise ConfigError, "設定を JSON として読めません"
  rescue SystemCallError
    raise ConfigError, "設定を読めません"
  end

  def validate_config(data)
    raise ConfigError, "top-level が object ではありません" unless data.is_a?(Hash)

    unknown = data.keys - CONFIG_KEYS
    raise ConfigError, "知らない key があります: #{unknown.map(&:to_s).sort.join(', ')}" unless unknown.empty?

    missing = CONFIG_KEYS - data.keys
    raise ConfigError, "足りない key があります: #{missing.join(', ')}" unless missing.empty?

    raise ConfigError, "docker_context の形が違います" unless data["docker_context"].is_a?(String) &&
                                                         data["docker_context"].match?(CONTEXT_RE)
    raise ConfigError, "image は ghcr.io/actions/actions-runner@sha256:<64 桁> の形にします" unless
      data["image"].is_a?(String) && data["image"].match?(IMAGE_RE)

    RANGES.each do |key, range|
      value = data[key]
      raise ConfigError, "#{key} は #{range.min}〜#{range.max} の整数にします" unless value.is_a?(Integer) && range.cover?(value)
    end
    validate_repos(data["repos"])
    data
  end

  def validate_repos(repos)
    unless repos.is_a?(Array) && (1..MAX_REPOS).cover?(repos.length)
      raise ConfigError, "repos は 1〜#{MAX_REPOS} 個の配列にします"
    end
    repos.each do |repo|
      raise ConfigError, "repos に owner/name の形でない値があります" unless valid_repo?(repo)
    end
    raise ConfigError, "repos に同じ repo が重なっています" unless repos.map(&:downcase).uniq.length == repos.length
  end

  def valid_repo?(repo)
    return false unless repo.is_a?(String) && repo.match?(REPO_RE)

    !%w[. ..].include?(repo.split("/", 2).last)
  end

  # ---- check -----------------------------------------------------------------------------------------------------

  def check(config, out)
    results = config["repos"].map do |repo|
      vis = visibility(repo)
      out.puts "#{repo} #{vis}"
      vis
    end
    results.all?("private") ? EXIT_OK : EXIT_NOT_OK
  end

  # ---- once ------------------------------------------------------------------------------------------------------

  def once(config, repo, out)
    raise UsageError, "repo の形が違います" unless valid_repo?(repo)

    listed = config["repos"].find { |r| r.casecmp?(repo) }
    raise UsageError, "#{repo} は設定の repos にありません" if listed.nil?

    state = state_dir
    with_lock(state, listed) do |locked|
      case locked
      when :unavailable
        out.puts "once: #{listed}: lock の file を用意できないので runner を作りません"
        next EXIT_NOT_OK
      when false
        out.puts "once: #{listed}: 同じ repo の once が動いています"
        next EXIT_BUSY
      end
      run_once(config, listed, state, out)
    end
  end

  def run_once(config, repo, state, out)
    install_traps
    vis = visibility(repo)
    unless vis == "private"
      out.puts "once: #{repo}: #{vis} なので runner を作りません"
      return EXIT_NOT_OK
    end

    if interrupted?
      out.puts "once: #{repo}: 止める signal を受けたので runner を作りません"
      return EXIT_NOT_OK
    end

    name = RUNNER_PREFIX + SecureRandom.hex(8)
    record = { "repo" => repo, "name" => name, "container" => name }
    unless write_record(state, record)
      out.puts "once: #{repo}: state に記録できないので runner を作りません"
      return EXIT_NOT_OK
    end

    id, jit = create_jit(repo, name)
    record["id"] = id if id
    write_record(state, record) if id
    reason = launch_refusal(repo, id, jit)
    if reason
      out.puts "once: #{repo}: #{reason}"
      finish(config, record, state, out)
      return EXIT_NOT_OK
    end

    out.puts "once: #{repo}: runner を起動します (#{name})"
    status = run_container(config, repo, record, jit)
    out.puts "once: #{repo}: #{status_label(status)}"
    cleaned = finish(config, record, state, out)
    status == :started && cleaned ? EXIT_OK : EXIT_NOT_OK
  end

  # JIT の設定を作った後で、container を起動しない理由 (無ければ nil)。
  def launch_refusal(repo, id, jit)
    return "runner を作れませんでした" if id.nil? || jit.nil?
    return "JIT の設定の形が違います" unless jit.match?(JIT_RE)
    return "作った直後の確かめで private でなくなったので止めます" unless visibility(repo) == "private"
    return "止める signal を受けました" if interrupted?

    nil
  end

  def status_label(status)
    { started: "container が終わりました", start_failed: "container を起動できませんでした",
      made_public: "private でなくなったので container を止めました",
      interrupted: "signal を受けたので container を止めました" }.fetch(status)
  end

  # container を起動し、終わるまで待つ。JIT の設定は stdin で渡す。戻り値: :started / :start_failed / :made_public /
  # :interrupted。
  def run_container(config, repo, record, jit)
    reader, writer = IO.pipe
    pid = Process.spawn(*docker(config), "run", "--rm", "-i", "--name", record["container"],
                        "--label", "#{CONTAINER_LABEL}=#{repo}",
                        "--cpus", config["cpus"].to_s, "--memory", "#{config['memory_mb']}m",
                        "--memory-swap", "#{config['memory_mb']}m", "--pids-limit", config["pids"].to_s,
                        "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
                        config["image"], "sh", "-c", INNER,
                        in: reader, out: File::NULL, err: File::NULL)
    reader.close
    begin
      writer.write("#{jit}\n")
    rescue Errno::EPIPE
      nil
    ensure
      writer.close
    end
    wait_container(config, repo, record, pid)
  rescue SystemCallError
    :start_failed
  end

  def wait_container(config, repo, record, pid)
    next_poll = now + poll_seconds
    stopped = nil
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      return stopped || exit_kind(status) if status

      if stopped.nil? && interrupted?
        stopped = :interrupted
        stop_container(config, record)
      elsif stopped.nil? && now >= next_poll
        next_poll = now + poll_seconds
        unless visibility(repo) == "private"
          stopped = :made_public
          stop_container(config, record)
        end
      end
      sleep 0.2
    end
  end

  # docker run の exit 125・126・127 は、container を起動できなかった印。ほかは runner の終わり方で、job の成否は GitHub の側。
  def exit_kind(status)
    [125, 126, 127].include?(status.exitstatus) ? :start_failed : :started
  end

  def stop_container(config, record)
    Open3.capture3(*docker(config), "stop", "--time", STOP_SECONDS.to_s, record["container"])
  rescue SystemCallError
    nil
  end

  # 登録を消し、消せたら (もう無かったら) 記録を外す。消せなければ記録を残して false (cleanup が後で消す)。
  def finish(config, record, state, out)
    result = remove_registration(record)
    if result == :failed
      out.puts "once: #{record['repo']}: runner の登録を消せませんでした (記録を残します。cleanup で消します)"
      return false
    end
    remove_record(state, record)
    true
  end

  # ---- cleanup ---------------------------------------------------------------------------------------------------

  def cleanup(config, out)
    state = state_dir
    ok = true
    records(state).each do |path, record|
      if record.nil?
        out.puts "cleanup: 読めない記録があります (#{File.basename(path)})"
        ok = false
        next
      end
      result = with_lock(state, record["repo"]) do |locked|
        case locked
        when true then cleanup_one(config, record, path, out)
        when false then :busy
        else :failed
        end
      end
      case result
      when :removed then out.puts "cleanup: #{record['repo']}: #{record['name']} の登録を消しました"
      when :running, :busy then out.puts "cleanup: #{record['repo']}: #{record['name']} は動いているので残します"
      else
        out.puts "cleanup: #{record['repo']}: #{record['name']} の登録を消せませんでした"
        ok = false
      end
    end
    ok ? EXIT_OK : EXIT_NOT_OK
  end

  def cleanup_one(config, record, path, out)
    return :running if container_running?(config, record)

    result = remove_registration(record)
    return :failed if result == :failed

    File.delete(path)
    :removed
  rescue SystemCallError
    :failed
  end

  def container_running?(config, record)
    stdout, _err, status = Open3.capture3(*docker(config), "ps", "--quiet", "--filter", "name=^/?#{record['container']}$",
                                          "--filter", "label=#{CONTAINER_LABEL}")
    # docker に問い合わせられないときは、動いているかもしれないので消さない
    return true unless status.success?

    !stdout.strip.empty?
  rescue SystemCallError
    true
  end

  # 記録の runner の登録を消す。戻り値: :deleted / :gone / :failed。id のある記録は、API の runner の名前が記録と一致する
  # ときだけ消す。id の無い記録 (作りかけ) は、名前で一覧から探す。
  def remove_registration(record)
    repo = record["repo"]
    id = record["id"] || find_runner_id(repo, record["name"])
    return :gone if id == :none
    return :failed if id.nil?

    runner, code = gh_get("repos/#{repo}/actions/runners/#{id}")
    return :gone if code == :not_found
    return :failed unless runner.is_a?(Hash) && runner["name"] == record["name"] && runner["name"].match?(RUNNER_NAME_RE)

    _out, code = gh_call("--method", "DELETE", "repos/#{repo}/actions/runners/#{id}")
    { ok: :deleted, not_found: :gone }.fetch(code, :failed)
  end

  # 名前で runner を探す。見つかれば id、無ければ :none、判定できなければ nil。
  def find_runner_id(repo, name)
    pages, code = gh_get("repos/#{repo}/actions/runners?per_page=100", paginate: true)
    return nil unless code == :ok && pages.is_a?(Array)

    runners = pages.flat_map { |page| page.is_a?(Hash) && page["runners"].is_a?(Array) ? page["runners"] : [nil] }
    return nil if runners.any? { |r| !r.is_a?(Hash) }

    found = runners.find { |r| r["name"] == name }
    found.nil? ? :none : found["id"]
  end

  # ---- GitHub の API ---------------------------------------------------------------------------------------------

  # 公開範囲。private と public は、private・visibility・full_name の 3 つがそろったときだけ。ほかは unknown。
  def visibility(repo)
    data, code = gh_get("repos/#{repo}")
    return "unknown" unless code == :ok && data.is_a?(Hash)
    return "unknown" unless data["full_name"].is_a?(String) && data["full_name"].casecmp?(repo)

    if data["private"] == true && data["visibility"] == "private"
      "private"
    elsif data["private"] == false && data["visibility"] == "public"
      "public"
    else
      "unknown"
    end
  end

  # JIT の runner を作る。戻り値: [id か nil, JIT の設定か nil]。返事の本文は外に出さない。
  def create_jit(repo, name)
    body = JSON.generate("name" => name, "runner_group_id" => RUNNER_GROUP_ID, "labels" => LABELS)
    data, code = gh_call("--method", "POST", "repos/#{repo}/actions/runners/generate-jitconfig", "--input", "-",
                         stdin: body)
    return [nil, nil] unless code == :ok && data.is_a?(Hash)

    id = data.dig("runner", "id")
    jit = data["encoded_jit_config"]
    [id.is_a?(Integer) ? id : nil, jit.is_a?(String) ? jit : nil]
  end

  def gh_get(path, paginate: false)
    args = paginate ? [path, "--paginate", "--slurp"] : [path]
    gh_call(*args)
  end

  # gh api を呼ぶ。戻り値: [JSON か nil, :ok / :not_found / :failed]。gh の出力と error の本文は外に出さない。
  def gh_call(*args, stdin: "")
    stdout, stderr, status = Open3.capture3("gh", "api", "--hostname", HOST, *args, stdin_data: stdin)
    unless status.success?
      return [nil, stderr.include?("(HTTP 404)") ? :not_found : :failed]
    end
    return [nil, :ok] if stdout.strip.empty?

    [JSON.parse(stdout.scrub), :ok]
  rescue JSON::ParserError, SystemCallError
    [nil, :failed]
  end

  # ---- state -----------------------------------------------------------------------------------------------------

  def state_dir
    value = ENV[STATE_ENV].to_s
    base = ENV["XDG_STATE_HOME"].to_s
    dir = if !value.empty? then value
          elsif base.start_with?(File::SEPARATOR) then File.join(base, "agent-tools", "ci-runner")
          else File.join(Dir.home, ".local", "state", "agent-tools", "ci-runner")
          end
    raise ConfigError, "state の dir は絶対 path にします" unless dir.start_with?(File::SEPARATOR)

    FileUtils.mkdir_p(dir, mode: 0o700)
    st = File.lstat(dir)
    raise ConfigError, "state の dir が directory ではありません" unless st.directory?
    raise ConfigError, "state の dir が自分の持ち物ではありません" unless st.uid == Process.uid
    raise ConfigError, "state の dir を group か other が使えます" if (st.mode & 0o077).positive?

    dir
  rescue SystemCallError
    raise ConfigError, "state の dir を用意できません"
  end

  def record_path(state, record)
    File.join(state, "#{record['name']}.json")
  end

  # 記録を一時 file に書いて rename で置く (途中で止まっても、書きかけの記録を置かない)。書けなければ false。
  def write_record(state, record)
    path = record_path(state, record)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.generate(record)) }
    File.rename(tmp, path)
    true
  rescue SystemCallError
    begin
      File.delete(tmp) if tmp
    rescue SystemCallError
      nil
    end
    false
  end

  def remove_record(state, record)
    File.delete(record_path(state, record))
  rescue Errno::ENOENT
    nil
  end

  # 記録の一覧: [[path, record か nil]]。形の違う記録は nil (読めない記録として知らせる)。
  def records(state)
    Dir.children(state).sort.select { |n| n.match?(/\Aagent-tools-ci-[0-9a-f]{16}\.json\z/) }.map do |n|
      path = File.join(state, n)
      [path, read_record(path)]
    end
  end

  def read_record(path)
    data = File.open(path, File::RDONLY | File::NOFOLLOW) { |f| f.stat.file? ? JSON.parse(f.read) : nil }
    return nil unless data.is_a?(Hash) && valid_repo?(data["repo"]) && data["name"].is_a?(String) &&
                      data["name"].match?(RUNNER_NAME_RE) && data["container"] == data["name"]
    return nil if data.key?("id") && !data["id"].is_a?(Integer)
    return nil unless File.basename(path) == "#{data['name']}.json"

    data
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # repo ごとの lock。取れれば true、ほかの process が持っていれば false、lock の file を用意できなければ :unavailable を
  # block に渡す。
  def with_lock(state, repo)
    path = File.join(state, "lock-#{Digest::SHA256.hexdigest(repo.downcase)[0, 16]}")
    file = begin
      File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
    rescue SystemCallError
      nil
    end
    return yield(:unavailable) if file.nil?

    begin
      yield(file.flock(File::LOCK_EX | File::LOCK_NB) ? true : false)
    ensure
      file.close
    end
  end

  # ---- そのほか --------------------------------------------------------------------------------------------------

  def docker(config)
    ["docker", "--context", config["docker_context"]]
  end

  def poll_seconds
    value = ENV[POLL_ENV].to_s
    return DEFAULT_POLL_SECONDS if value.empty?

    seconds = Integer(value, 10)
    POLL_RANGE.cover?(seconds) ? seconds : DEFAULT_POLL_SECONDS
  rescue ArgumentError
    DEFAULT_POLL_SECONDS
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def install_traps
    @interrupted = false
    TRAPPED_SIGNALS.each { |name| Signal.trap(name) { @interrupted = true } }
  end

  def interrupted?
    @interrupted == true
  end
end

exit CiRunner.main(ARGV) if $PROGRAM_NAME == __FILE__
