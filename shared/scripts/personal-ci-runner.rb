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
  # 規則 2: 動いている間の private の確かめは 40 秒ごとで、その gh の期限は 20 秒 (公開範囲の変化を検知するまで最大 60 秒)
  DEFAULT_POLL_SECONDS = 40
  POLL_RANGE = (1..40).freeze
  VISIBILITY_TIMEOUT_SECONDS = 20
  STOP_SECONDS = 10
  # 検知から戻るまでの期限 (秒)。docker stop (失敗したら docker kill) を STOP_RETRY_SECONDS ごとに繰り返し、期限の
  # ABANDON_SECONDS 前になっても container が終わらなければ docker の client を止める
  STOP_GIVE_UP_SECONDS = 60
  STOP_RETRY_SECONDS = 5
  ABANDON_SECONDS = 5
  # gh と docker の子 process を待つ期限 (秒)。検知の後は、検知の期限までの残りで切る
  CHILD_TIMEOUT_SECONDS = 60
  # 規則 1: 名前で見つからない記録を、container の終わりを回収していなくても外してよくなるまでの時間 (秒)
  RECORD_GRACE_SECONDS = 600
  # 記録は POST の前に 1 回だけ書く。この 4 つの key だけを持つ
  RECORD_KEYS = %w[repo name container created_at].freeze
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

  # 記録は POST の前に 1 回だけ書き、以後は書き換えない (規則 1)。runner の同一性は名前だけで決める。
  def run_once(config, repo, state, out)
    install_traps
    vis = visibility(repo, interruptible: true)
    unless vis == "private"
      out.puts "once: #{repo}: #{vis} なので runner を作りません"
      return EXIT_NOT_OK
    end

    if interrupted?
      out.puts "once: #{repo}: 止める signal を受けたので runner を作りません"
      return EXIT_NOT_OK
    end

    name = RUNNER_PREFIX + SecureRandom.hex(8)
    record = { "repo" => repo, "name" => name, "container" => name, "created_at" => Time.now.to_i }
    unless write_record(state, record)
      out.puts "once: #{repo}: state に記録できないので runner を作りません"
      return EXIT_NOT_OK
    end

    ctx = { record: record, pid: nil, alive: false }
    begin
      launch_and_wait(config, repo, ctx, state, out)
    rescue StandardError => e
      # 想定外の例外でも、container が動いていれば止め、規則 1 で後片付けをする。出力は止めた後 (出力の失敗で止めを飛ばさない)
      stop_after_failure(config, ctx)
      result = begin
        settle(record, state, ran: false, alive: ctx[:alive])
      rescue StandardError
        :kept_failed
      end
      begin
        out.puts "once: #{repo}: 想定外の失敗で止めました (#{e.class})"
        report_settle(result, record, out)
      rescue StandardError
        nil
      end
      EXIT_NOT_OK
    ensure
      reap_children
    end
  end

  def launch_and_wait(config, repo, ctx, state, out)
    record = ctx[:record]
    jit = create_jit(repo, record["name"])
    reason = launch_refusal(repo, jit)
    if reason
      out.puts "once: #{repo}: #{reason}"
      report_settle(settle(record, state, ran: false), record, out)
      return EXIT_NOT_OK
    end

    out.puts "once: #{repo}: runner を起動します (#{record['name']})"
    status = run_container(config, repo, ctx, jit)
    out.puts "once: #{repo}: #{status_label(status, record)}"
    # container が動いて終わったのを回収したときだけ ran (名前で見つからなければ、もう無いとみなしてよい)。container が
    # 動いているかもしれないこと (ctx[:alive]) は、あきらめたときと docker の client が signal で終わったときに立つ
    ran = %i[started made_public interrupted].include?(status)
    result = settle(record, state, ran: ran, alive: ctx[:alive])
    report_settle(result, record, out)
    status == :started && result == :removed ? EXIT_OK : EXIT_NOT_OK
  end

  # JIT の設定を作った後で、container を起動しない理由 (無ければ nil)。
  def launch_refusal(repo, jit)
    return "止める signal を受けました" if interrupted?
    return "runner を作れませんでした" if jit.nil?
    return "JIT の設定の形が違います" unless jit.match?(JIT_RE)
    return "作った直後の確かめで private でなくなったので止めます" unless visibility(repo, interruptible: true) == "private"
    return "止める signal を受けました" if interrupted?

    nil
  end

  def status_label(status, record)
    { started: "container が終わりました", start_failed: "container を起動できませんでした",
      made_public: "private でなくなったので container を止めました",
      interrupted: "signal を受けたので container を止めました",
      client_lost: "docker の client が signal で終わりました (container が動いているかもしれません: #{record['container']})",
      stop_failed: "container を止められませんでした (docker で手で止めてください: #{record['container']})" }.fetch(status)
  end

  # container を起動し、終わるまで待つ。JIT の設定は stdin で渡す。戻り値: :started / :start_failed / :made_public /
  # :interrupted / :client_lost / :stop_failed。docker を起動できなかったときだけ :start_failed にする (起動の後の失敗は
  # 例外の受け口に任せ、container を止めてから後片付けをする)。
  def run_container(config, repo, ctx, jit)
    reader, writer = IO.pipe
    record = ctx[:record]
    begin
      ctx[:pid] = Process.spawn(*docker(config), "run", "--rm", "-i", "--name", record["container"],
                                "--label", "#{CONTAINER_LABEL}=#{repo}",
                                "--cpus", config["cpus"].to_s, "--memory", "#{config['memory_mb']}m",
                                "--memory-swap", "#{config['memory_mb']}m", "--pids-limit", config["pids"].to_s,
                                "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
                                config["image"], "sh", "-c", INNER,
                                in: reader, out: File::NULL, err: File::NULL)
    rescue SystemCallError
      reader.close
      writer.close
      return :start_failed
    end
    reader.close
    begin
      writer.write("#{jit}\n")
    rescue Errno::EPIPE
      nil
    ensure
      writer.close
    end
    wait_container(config, repo, ctx)
  end

  # container が終わるまで待つ。signal を受けた、または private と確かめられなくなったら (検知)、規則 2 で止める:
  # 検知の時点で期限を決め (detect!)、登録を消すのを別の thread で、container を止めるのを同時に始める。
  def wait_container(config, repo, ctx)
    pid = ctx[:pid]
    next_poll = now + poll_seconds
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      if status
        ctx[:pid] = nil
        return exit_kind(status, ctx)
      end

      reason = nil
      if interrupted?
        reason = :interrupted
      elsif now >= next_poll
        next_poll = now + poll_seconds
        vis = visibility(repo, interruptible: true, timeout: VISIBILITY_TIMEOUT_SECONDS)
        reason = interrupted? ? :interrupted : (vis == "private" ? nil : :made_public)
      end
      return stop_on_detection(config, ctx, reason) if reason

      sleep 0.2
    end
  end

  def stop_on_detection(config, ctx, reason)
    detect!
    remover = Thread.new do
      Thread.current.report_on_exception = false
      delete_by_name(ctx[:record])
    end
    result = stop_until_exit(config, ctx)
    remover.join([remaining, 0].max)
    # 期限までに終わらなかった登録の削除は、子を止めて終わらせる (後の settle が名前で確かめ直す)
    unless remover.join(0)
      reap_children
      remover.join(5)
    end
    result == :exited ? reason : :stop_failed
  end

  # 想定外の例外の後: container が動いていれば、同じ規則で止める。止められなければ ctx[:alive] が立つ。
  def stop_after_failure(config, ctx)
    return if ctx[:pid].nil?

    detect!
    stop_until_exit(config, ctx)
  rescue StandardError
    ctx[:alive] = true
  end

  # docker stop (失敗したら docker kill) を、container が終わるまで STOP_RETRY_SECONDS ごとに繰り返す。期限の
  # ABANDON_SECONDS 前になっても終わらなければ、docker の client を止める。戻り値: :exited / :abandoned。あきらめたときと、
  # client が signal で終わったときは、container が動いているかもしれないので ctx[:alive] を立てる (規則 1 で記録を残す)。
  def stop_until_exit(config, ctx)
    pid = ctx[:pid]
    next_stop = now
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      if status
        ctx[:pid] = nil
        ctx[:alive] = true if status.signaled?
        return status.signaled? ? :abandoned : :exited
      end
      left = remaining
      if left <= ABANDON_SECONDS
        abandon(pid, left)
        ctx[:pid] = nil
        ctx[:alive] = true
        return :abandoned
      end
      if now >= next_stop
        stop_container(config, ctx[:record], left - ABANDON_SECONDS)
        next_stop = now + STOP_RETRY_SECONDS
      end
      sleep 0.2
    end
  rescue Errno::ECHILD
    ctx[:pid] = nil
    :exited
  end

  # docker run の exit 125・126・127 は、container を起動できなかった印。ほかは runner の終わり方で、job の成否は GitHub の側。
  # docker の client が signal で終わったときは、container が残っているかもしれない (ctx[:alive] を立てる)。
  def exit_kind(status, ctx)
    if status.signaled?
      ctx[:alive] = true
      return :client_lost
    end

    [125, 126, 127].include?(status.exitstatus) ? :start_failed : :started
  end

  # docker stop で止め、失敗したら docker kill を試す。どちらかが成功すれば true。left 秒のうちに収める (猶予と期限)。
  def stop_container(config, record, left)
    until_time = now + left
    grace = [STOP_SECONDS, left.floor - 1].min
    if grace >= 1
      _out, _err, status = run_child([*docker(config), "stop", "--time", grace.to_s, record["container"]],
                                     timeout: [left, STOP_SECONDS + 20].min)
      return true if status&.success?
    end

    rest = until_time - now
    return false if rest <= 0

    _out, _err, status = run_child([*docker(config), "kill", record["container"]], timeout: [rest, 20].min)
    status&.success? || false
  end

  # 止められない container の docker の client を止める (TERM、left のうちに KILL)。container そのものは残りうる。
  def abandon(pid, left)
    signal_child(pid, "TERM")
    until_time = now + [[left - 1, 1].max, ABANDON_SECONDS].min
    until Process.waitpid(pid, Process::WNOHANG)
      if now >= until_time
        signal_child(pid, "KILL")
        Process.waitpid(pid)
        break
      end
      sleep 0.1
    end
  rescue Errno::ECHILD
    nil
  end

  def signal_child(pid, signal)
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end

  # ---- 規則 1: 記録を外してよいとき ------------------------------------------------------------------------------

  # 登録を名前で引いて消し、記録を外してよいときだけ外す。once と cleanup が共有する。戻り値:
  # :removed (記録を外した) / :kept_failed (一覧や DELETE の失敗) / :kept_pending (名前で見つからないが、まだ外さない) /
  # :kept_alive (container が動いているかもしれない) / :kept_record (登録は消せたが記録を消せない)。
  # - 外すのは、名前で見つかって DELETE が成功か 404 だった、または、名前で見つからず ran か作ってから
  #   RECORD_GRACE_SECONDS たっている、のどちらかのとき。alive なら外さない。
  def settle(record, state, ran:, alive: false)
    result = delete_by_name(record)
    return :kept_failed if result == :failed
    return :kept_alive if alive
    return :kept_pending if result == :absent && !ran && !aged?(record)

    remove_record(state, record) ? :removed : :kept_record
  end

  def report_settle(result, record, out)
    message = {
      kept_failed: "runner の登録を消せませんでした (記録を残します。cleanup で消します)",
      kept_pending: "runner が名前で見つからないので、作られたかを確かめ直すため記録を残します (cleanup が照合し直します)",
      kept_alive: "container が動いているかもしれないので、記録を残します",
      kept_record: "runner の登録は消しましたが、記録を消せませんでした",
    }[result]
    out.puts "once: #{record['repo']}: #{message}" if message
  end

  def aged?(record)
    Time.now.to_i - record["created_at"] >= RECORD_GRACE_SECONDS
  end

  # 一覧を名前で引き、見つかった runner を DELETE する。戻り値: :deleted / :absent (名前で見つからない) /
  # :failed (一覧か DELETE の失敗・期限切れ)。DELETE が 404 なら、名前で一覧を引き直し、無いと確かめられたときだけ :deleted。
  def delete_by_name(record)
    repo = record["repo"]
    id = find_runner_id(repo, record["name"])
    return :failed if id.nil?
    return :absent if id == :none

    _out, code = gh_call("--method", "DELETE", "repos/#{repo}/actions/runners/#{id}")
    return :deleted if code == :ok
    return :failed unless code == :not_found

    find_runner_id(repo, record["name"]) == :none ? :deleted : :failed
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
        when true then container_running?(config, record) ? :running : settle(record, state, ran: false)
        when false then :busy
        else :kept_failed
        end
      end
      label = "cleanup: #{record['repo']}: #{record['name']}"
      case result
      when :removed then out.puts "#{label} の後片付けを済ませました"
      when :running, :busy then out.puts "#{label} は動いているので残します"
      when :kept_pending then out.puts "#{label} は名前で見つからないので、作ってから 10 分たつまで残します"
      else
        out.puts "#{label} の後片付けができませんでした"
        ok = false
      end
    end
    ok ? EXIT_OK : EXIT_NOT_OK
  end

  def container_running?(config, record)
    stdout, _err, status = run_child([*docker(config), "ps", "--quiet", "--filter", "name=^/?#{record['container']}$",
                                      "--filter", "label=#{CONTAINER_LABEL}"])
    # docker に問い合わせられないときは、動いているかもしれないので消さない
    return true unless status&.success?

    !stdout.strip.empty?
  end

  # 名前で runner を探す。見つかれば id、無ければ :none、判定できなければ nil (一覧の失敗、形の違い、同じ名前が 2 つ)。
  def find_runner_id(repo, name)
    pages, code = gh_get("repos/#{repo}/actions/runners?per_page=100", paginate: true)
    return nil unless code == :ok && pages.is_a?(Array)

    runners = pages.flat_map { |page| page.is_a?(Hash) && page["runners"].is_a?(Array) ? page["runners"] : [nil] }
    return nil if runners.any? { |r| !r.is_a?(Hash) }

    found = runners.select { |r| r["name"] == name }
    return :none if found.empty?
    return nil unless found.length == 1

    id = found.first["id"]
    id.is_a?(Integer) && id.positive? ? id : nil
  end

  # ---- GitHub の API ---------------------------------------------------------------------------------------------

  # 公開範囲。private と public は、private・visibility・full_name の 3 つがそろったときだけ。ほかは unknown。
  # interruptible なら、signal を受けた時点で gh を止める (unknown になる)。
  def visibility(repo, interruptible: false, timeout: CHILD_TIMEOUT_SECONDS)
    data, code = gh_get("repos/#{repo}", interruptible: interruptible, timeout: timeout)
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

  # JIT の runner を作り、JIT の設定 (無ければ nil) を返す。返事からは JIT の設定だけを使い、runner の id は使わない
  # (同一性は名前だけ。規則 1)。作られたかどうかは、後片付けが名前で一覧を引いて決める。返事の本文は外に出さない。
  def create_jit(repo, name)
    body = JSON.generate("name" => name, "runner_group_id" => RUNNER_GROUP_ID, "labels" => LABELS)
    data, code = gh_call("--method", "POST", "repos/#{repo}/actions/runners/generate-jitconfig", "--input", "-",
                         stdin: body, interruptible: true)
    return nil unless code == :ok && data.is_a?(Hash)

    jit = data["encoded_jit_config"]
    jit.is_a?(String) ? jit : nil
  end

  def gh_get(path, paginate: false, interruptible: false, timeout: CHILD_TIMEOUT_SECONDS)
    args = paginate ? [path, "--paginate", "--slurp"] : [path]
    gh_call(*args, interruptible: interruptible, timeout: timeout)
  end

  # gh api を呼ぶ。戻り値: [JSON か nil, :ok / :not_found / :failed / :aborted (止めた・期限切れ・起動できない)]。
  # gh の出力と error の本文は外に出さない。
  def gh_call(*args, stdin: "", interruptible: false, timeout: CHILD_TIMEOUT_SECONDS)
    stdout, stderr, status = run_child(["gh", "api", "--hostname", HOST, *args], stdin: stdin, interruptible: interruptible,
                                                                                timeout: timeout)
    return [nil, :aborted] if status.nil?
    return [nil, stderr.include?("(HTTP 404)") ? :not_found : :failed] unless status.success?
    return [nil, :ok] if stdout.strip.empty?

    [JSON.parse(stdout.scrub), :ok]
  rescue JSON::ParserError
    [nil, :failed]
  end

  # 子 process を起動し、stdout・stderr・status を返す。timeout 秒を過ぎたとき、または interruptible で signal を受けた
  # ときは、子を止めて (TERM → 5 秒 → KILL) status を nil にする。起動できなければ status は nil。検知の後は、timeout を
  # 検知の期限までの残りで切る (規則 2)。残りが無ければ起動しない。
  def run_child(cmd, stdin: "", timeout: CHILD_TIMEOUT_SECONDS, interruptible: false)
    timeout = [timeout, remaining].min if @deadline
    return ["", "", nil] if timeout <= 0

    Open3.popen3(*cmd) do |input, output, error, thread|
      track_child(thread.pid, true)
      feeder = Thread.new do
        input.write(stdin)
      rescue IOError, SystemCallError
        nil
      ensure
        input.close unless input.closed?
      end
      # 子を止めた後に stream が閉じられても、thread の例外を stderr に出さない
      readers = [output, error].map do |stream|
        Thread.new do
          Thread.current.report_on_exception = false
          stream.read
        end
      end
      begin
        deadline = now + timeout
        until thread.join(0.1)
          next unless now >= deadline || (interruptible && interrupted?)

          stop_child(thread)
          feeder.join(1)
          readers.each { |r| r.join(1) }
          return ["", "", nil]
        end
        feeder.join
        [readers[0].value.to_s, readers[1].value.to_s, thread.value]
      ensure
        track_child(thread.pid, false)
      end
    end
  rescue SystemCallError
    ["", "", nil]
  end

  # TERM から KILL までは 5 秒。検知の後は期限までの残りで切る (下限 1 秒。規則 2 の期限を延ばさない)。
  def stop_child(thread)
    signal_child(thread.pid, "TERM")
    grace = @deadline ? [[remaining, 1].max, 5].min : 5
    return if thread.join(grace)

    signal_child(thread.pid, "KILL")
    thread.join
  end

  # run_child が起動して、まだ終わっていない子の pid を覚える (別の thread からも呼ばれる)。
  def track_child(pid, alive)
    @children_lock ||= Mutex.new
    @children_lock.synchronize do
      @children ||= {}
      alive ? @children[pid] = true : @children.delete(pid)
    end
  end

  # 残っている子を止める (TERM、1 秒で KILL)。登録を消す thread の gh が、期限の後と once の終わりに残らないように。
  def reap_children
    pids = (@children_lock ||= Mutex.new).synchronize { (@children || {}).keys }
    return if pids.empty?

    pids.each { |pid| signal_child(pid, "TERM") }
    until_time = now + 1
    sleep 0.05 while now < until_time && pids.any? { |pid| child_alive?(pid) }
    pids.each { |pid| signal_child(pid, "KILL") if child_alive?(pid) }
  end

  def child_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
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

  # 記録を消す。消せた (もう無かった) ら true、消せなければ false。
  def remove_record(state, record)
    File.delete(record_path(state, record))
    true
  rescue Errno::ENOENT
    true
  rescue SystemCallError
    false
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
    return nil unless data.is_a?(Hash) && data.keys.sort == RECORD_KEYS.sort && valid_repo?(data["repo"]) &&
                      data["name"].is_a?(String) && data["name"].match?(RUNNER_NAME_RE) &&
                      data["container"] == data["name"] && data["created_at"].is_a?(Integer)
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

  # signal は flag を立て、検知の期限を決める (規則 2)。
  def install_traps
    @interrupted = false
    @deadline = nil
    TRAPPED_SIGNALS.each do |name|
      Signal.trap(name) do
        @interrupted = true
        @deadline ||= now + STOP_GIVE_UP_SECONDS
      end
    end
  end

  def interrupted?
    @interrupted == true
  end

  # 検知 (signal か、private と確かめられない) の時点で、戻るまでの期限を決める。すでに決まっていれば変えない。
  def detect!
    @deadline ||= now + STOP_GIVE_UP_SECONDS
  end

  # 検知の期限までの残り (秒)。期限が無ければ CHILD_TIMEOUT_SECONDS。
  def remaining
    @deadline ? @deadline - now : CHILD_TIMEOUT_SECONDS
  end
end

exit CiRunner.main(ARGV) if $PROGRAM_NAME == __FILE__
