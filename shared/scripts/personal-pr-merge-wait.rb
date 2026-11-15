#!/usr/bin/env ruby
# frozen_string_literal: true

# personal-pr-merge-wait: 人が merge する PR を待つ (#675)。PR の状態を決まった間隔で読み、merge されたか、別の終わり方を
# したか、上限に達したかを exit code で返す。merge も配備もせず、GitHub に書かない。
#
# 確認には `gh pr view <番号> [--repo <repo>] --json state,headRefOid,mergeCommit` だけを使う (題名・本文・コメントは読まない)。
# gh は PATH の gh で、自分の process group で起動し、1 回 60 秒で打ち切る (stdout を閉じた後も、group に process が残る
# 間も期限で見る)。gh の stderr は出さない。
# 起動の直後に 1 回確かめ、その後は間隔ごとに確かめる。次の間隔が上限を越えるときは、上限の時刻に最後の確認をする。
#
# 使い方: personal-pr-merge-wait <PR 番号> --expect-head <40 桁> [--repo <owner/repo>] [--interval <秒>] [--timeout <秒>]
#   --interval は 1〜600 (既定 60)、--timeout は 1〜43200 (既定 7200)。
# 出力 (stdout): 起動の直後に `merge-wait: waiting (PR #<番号>、上限 <秒> 秒)` の 1 行。終わるときに、exit 0 は
#   `merge-commit:` と `head:` の行、exit 1 と 3 は `state:` と `head:` の行を出し、最後の行に `merge-wait: <結果>`。
# exit: 0 = merged (merge の時の head が --expect-head と同じ) / 1 = merged-other-head・closed・head-moved /
#   3 = timeout (上限の時刻でまだ open、head も同じ) / 2 = usage・gh の確認が 3 回続けて失敗・上限の時刻の確認が失敗・
#   止められた (SIGINT / SIGTERM)・想定外の例外 (どれも stderr に 1 行)。止められたときは、走っている gh の group を止めて
#   回収してから終わる。signal は記録だけし、決まった時点で扱う。説明は docs/pr-merge-wait.md。

require "json"

# C locale でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module PrMergeWait
  NAME = "personal-pr-merge-wait"
  EXIT_MERGED = 0
  EXIT_OTHER = 1
  EXIT_ERROR = 2
  EXIT_TIMEOUT = 3

  PR_RE = /\A[0-9]{1,10}\z/.freeze
  REPO_RE = %r{\A[\w.][\w.-]*/[\w.][\w.-]*\z}.freeze
  SHA_RE = /\A[0-9a-f]{40}\z/.freeze
  SECONDS_RE = /\A[0-9]{1,5}\z/.freeze
  FIELDS = "state,headRefOid,mergeCommit"
  INTERVAL = 1..600
  TIMEOUT = 1..43_200
  DEFAULT_INTERVAL = 60
  DEFAULT_TIMEOUT = 7200
  GH_LIMIT = 60
  MAX_FAILURES = 3
  MAX_OUTPUT = 1024 * 1024
  OPTIONS = %w[--expect-head --repo --interval --timeout].freeze

  # 終わり方ごとの exit と最後の行の語。
  RESULTS = {
    merged: [EXIT_MERGED, "merged"], merged_other_head: [EXIT_OTHER, "merged-other-head"], closed: [EXIT_OTHER, "closed"],
    head_moved: [EXIT_OTHER, "head-moved"], timeout: [EXIT_TIMEOUT, "timeout"],
  }.freeze

  class UsageError < StandardError; end
  class Failed < StandardError; end

  # SIGINT / SIGTERM を受けたしるし。
  class Interrupted < StandardError; end

  module_function

  def run(argv)
    $stdout.sync = true
    opts = parse(argv)
    watch_signals
    puts "merge-wait: waiting (PR ##{opts[:pr]}、上限 #{opts[:timeout]} 秒)"
    wait(opts)
  rescue UsageError => e
    warn "#{NAME}: #{e.message}"
    EXIT_ERROR
  rescue Failed => e
    warn "#{NAME}: #{e.message}"
    EXIT_ERROR
  rescue Interrupted => e
    # gh は check_signal が止めて回収済み。
    warn "#{NAME}: SIG#{e.message} で止められました (gh を止めて終わります)"
    EXIT_ERROR
  rescue StandardError => e
    stop_child
    # 内容を含みうる message は出さず class 名だけ。
    warn "#{NAME}: unexpected error (#{e.class})"
    EXIT_ERROR
  end

  # SIGINT / SIGTERM を受ける。trap の中では例外を上げず、届いた signal を記録して self-pipe に 1 byte 書くだけにする
  # (待っている IO.select を起こす)。止めるのは check_signal を呼ぶ決まった時点だけなので、gh の PID を覚える・消す
  # 処理の途中や、gh を止める途中で抜けない。
  def watch_signals
    @sig_r, @sig_w = IO.pipe
    %w[TERM INT].each { |sig| trap(sig) { on_signal(sig) } }
  end

  def on_signal(sig)
    @signal ||= sig
    @sig_w.write_nonblock(".", exception: false)
  end

  # 届いた signal があれば、走っている gh を止めて回収してから Interrupted を上げる。
  def check_signal
    return if @signal.nil?

    stop_child
    raise Interrupted, @signal
  end

  # 秒数だけ待つ。signal が届いたら、すぐに戻る。
  def pause(seconds)
    IO.select([@sig_r], nil, nil, seconds)
  end

  # 引数を読む。PR 番号は位置引数で 1 つだけ。option は値を取り、重複と未知は usage の誤り。
  def parse(argv)
    pr = nil
    opts = {}
    args = argv.dup
    until args.empty?
      arg = args.shift
      if arg.start_with?("-")
        raise UsageError, "知らない option: #{arg[0, 40]}" unless OPTIONS.include?(arg)
        raise UsageError, "#{arg} が 2 回あります" if opts.key?(arg)
        raise UsageError, "#{arg} に値がありません" if args.empty?

        opts[arg] = args.shift
      else
        raise UsageError, "PR 番号は 1 つだけ渡す" if pr

        pr = arg
      end
    end
    raise UsageError, "PR 番号が要ります" if pr.nil?
    raise UsageError, "PR 番号は数字だけで渡す" unless PR_RE.match?(pr)
    raise UsageError, "--expect-head が要ります" unless opts.key?("--expect-head")
    raise UsageError, "--expect-head は 40 桁の小文字の hex で渡す" unless SHA_RE.match?(opts["--expect-head"])
    raise UsageError, "--repo は owner/repo の形で渡す" if opts.key?("--repo") && !REPO_RE.match?(opts["--repo"])

    { pr: pr, expect: opts["--expect-head"], repo: opts["--repo"],
      interval: seconds(opts, "--interval", DEFAULT_INTERVAL, INTERVAL),
      timeout: seconds(opts, "--timeout", DEFAULT_TIMEOUT, TIMEOUT) }
  end

  def seconds(opts, name, default, range)
    return default unless opts.key?(name)

    value = opts[name]
    raise UsageError, "#{name} は #{range.min}〜#{range.max} の整数 (秒)" unless SECONDS_RE.match?(value) && range.cover?(value.to_i)

    value.to_i
  end

  # 確認を繰り返す。終わり方が決まったら出力して exit code を返す。
  def wait(opts)
    start = now
    failures = 0
    loop do
      check_signal
      snap = check(opts)
      if snap.nil?
        failures += 1
        raise Failed, "gh での PR の確認が #{MAX_FAILURES} 回続けて失敗しました" if failures >= MAX_FAILURES
      else
        failures = 0
        result = judge(snap, opts[:expect])
        return finish(result, snap) if result
      end

      left = opts[:timeout] - (now - start)
      # 待ちが少し早く戻っても、上限の時刻の確認を 2 回にしない。
      if left <= 0.01
        raise Failed, "上限の時刻の確認が失敗しました (PR の状態を確かめられません)" if snap.nil?

        return finish(:timeout, snap)
      end
      pause([opts[:interval], left].min)
    end
  end

  # 1 回の状態で終わり方を決める。まだ待つなら nil。
  def judge(snap, expect)
    case snap[:state]
    when "MERGED" then snap[:head] == expect ? :merged : :merged_other_head
    when "CLOSED" then :closed
    else snap[:head] == expect ? nil : :head_moved
    end
  end

  def finish(result, snap)
    code, word = RESULTS.fetch(result)
    if result == :merged
      puts "merge-commit: #{snap[:merge_commit]}"
    else
      puts "state: #{snap[:state]}"
    end
    puts "head: #{snap[:head]}"
    puts "merge-wait: #{word}"
    code
  end

  # gh で 1 回確かめる。失敗 (exit 0 でない、時間を越えた、応答の形が外れる) は nil。
  def check(opts)
    argv = ["gh", "pr", "view", opts[:pr]]
    argv += ["--repo", opts[:repo]] if opts[:repo]
    argv += ["--json", FIELDS]
    out, status = run_gh(argv)
    return nil unless status&.success?

    snapshot(parse_json(out))
  end

  def snapshot(doc)
    return nil unless doc.is_a?(Hash)

    state = doc["state"]
    head = doc["headRefOid"]
    merge = doc["mergeCommit"]
    return nil unless %w[OPEN CLOSED MERGED].include?(state) && head.is_a?(String) && SHA_RE.match?(head)

    oid = merge.is_a?(Hash) ? merge["oid"] : nil
    if state == "MERGED"
      return nil unless oid.is_a?(String) && SHA_RE.match?(oid)
    else
      return nil unless merge.nil? || (merge.is_a?(Hash) && (oid.nil? || (oid.is_a?(String) && SHA_RE.match?(oid))))
    end

    { state: state, head: head, merge_commit: oid }
  end

  def parse_json(text)
    text = text.dup.force_encoding(Encoding::UTF_8)
    return nil unless text.valid_encoding?

    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  # gh を自分の process group で起動し、stdout を読む。stdout の読み終わりと gh の group の終わりの両方を、GH_LIMIT 秒の
  # 期限で見る (gh が stdout を閉じた後も動き続けるときも、gh の子が group に残るときも、期限で止める)。gh を回収するのは、
  # group に生きている process が無くなった後だけにする。回収するまで gh の PID と group の id は再利用されないので、signal の
  # 先は必ずこの gh になる。[stdout, status] を返し、期限を越えた・出力が大きすぎて止めたときは [nil, nil]。signal が届いて
  # いれば、gh を止めて回収してから Interrupted を上げる (check_signal)。
  def run_gh(argv)
    reader, writer = IO.pipe
    begin
      @child = Process.spawn(*argv, in: File::NULL, out: writer, err: File::NULL, pgroup: true)
    rescue SystemCallError
      return [nil, nil] # gh を起動できない (確認の失敗として数える)
    ensure
      writer.close
    end
    out = +""
    deadline = now + GH_LIMIT
    reading = true
    loop do
      check_signal
      left = deadline - now
      return [nil, stop_child] if left <= 0

      if reading
        ready, = IO.select([reader, @sig_r], nil, nil, left)
        next unless ready&.include?(reader)

        chunk = reader.read_nonblock(65_536, exception: false)
        if chunk.nil?
          reading = false
        elsif chunk != :wait_readable
          out << chunk
          return [nil, stop_child] if out.bytesize > MAX_OUTPUT
        end
      else
        status = reap_if_done(@child)
        if status
          @child = nil
          return [out, status]
        end
        pause([left, 0.05].min)
      end
    end
  ensure
    reader&.close
  end

  # 走っている gh を止めて回収する。gh の group に TERM を送り、group に生きている process が無くなって gh を回収できるまで
  # 最大 2 秒待つ。残れば KILL を送って、同じく待つ。KILL の後も回収できなければ、gh の終わりを待って回収する (gh には KILL
  # が届いている)。止めたときは nil を返す (成功の status ではない)。止める間に届いた signal は記録に残るだけで、止める処理を
  # 途中で抜けない。
  def stop_child
    pid = @child
    return nil if pid.nil?

    signal_group("TERM", pid)
    unless wait_stopped(pid, now + 2)
      signal_group("KILL", pid)
      Process.waitpid(pid) unless wait_stopped(pid, now + 2)
    end
    @child = nil
    nil
  rescue Errno::ECHILD
    @child = nil
    nil
  end

  # gh を回収できたら status、期限を過ぎたら nil (gh は回収しない)。
  def wait_stopped(pid, deadline)
    until (status = reap_if_done(pid))
      return nil if now > deadline

      sleep 0.05
    end
    status
  end

  # gh の group に生きている process が無く、gh が終わっていれば、gh を回収して status を返す。まだなら nil。
  def reap_if_done(pid)
    return nil if group_alive?(pid)

    Process.wait2(pid, Process::WNOHANG)&.last
  end

  # gh の group に、生きている process があるか。gh を回収する前に限って呼ぶ。中が回収前の gh (zombie) だけになった
  # group には、macOS が EPERM を返すので、生きていないと読む。
  def group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # gh の group に signal を送る。gh は group の leader なので (leader は group を抜けられない)、gh 自身にも届く。gh を回収する
  # 前に限って呼ぶ (PID と group の id は再利用されていない)。
  def signal_group(sig, pid)
    Process.kill(sig, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

exit PrMergeWait.run(ARGV) if $PROGRAM_NAME == __FILE__
