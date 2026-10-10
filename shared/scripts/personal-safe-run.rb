#!/usr/bin/env ruby
# frozen_string_literal: true

# safe-run: test や長時間の command を、新しい process group と、memory (group の phys_footprint の合計) と時間の
# 上限で守って起動する wrapper (#466)。親だけを止めて孫が残る問題と、macOS で `ulimit -v` が効かない問題に対処する。
# 正本: docs/safe-run.md。macOS 専用 (libproc を Fiddle で直接呼ぶ)。
#
# CLI:
#   personal-safe-run --max-footprint-mb N --max-seconds N [--report FILE] -- <command> [args...]
# - 2 つの上限は必須の正の整数 (footprint 1〜1048576 MiB、時間 1〜86400 秒)。MB は MiB (1024 × 1024 byte)。
# - --report FILE: 起動の前に、FILE の親 dir が在ることと、FILE が在らない (lstat。symlink も在るとみなす) ことを
#   確かめる。呼び出し側は実行ごとに新しい path を渡す (古い report を今回のものと読み違えないため)。
# - command は shell を通さず argv のまま、新しい process group (leader の pid = pgid) で起動する。stdin が端末なら
#   /dev/null に替える (背景の group が端末を読むと SIGTTIN で止まるため)。pipe と file はそのまま渡す。
#   stdout / stderr は継承する (透過)。safe-run 自身の診断は stderr の `personal-safe-run: ` で始まる行だけ。
#
# exit code:
# - command (leader) の exit code。leader が signal で終わったら 128 + signo。
# - 137: 上限で止めた (reason が time / footprint / monitor)。command 自身の SIGKILL と区別するには report を読む。
# - 128 + signo: safe-run が INT / TERM / HUP / QUIT / TSTP を受けて止めた (reason interrupted。TSTP は 146)。
# - 127 / 126: command が見つからない / 実行できない (shell と同じ)。report は command_started: false。
# - 2: usage の誤り、または前提の不成立 (macOS でない、Fiddle を load できない、libproc を呼べない)。command は
#   起動せず、report も書かない。
#
# 監視 (巡回は 0.25 秒ごと、時刻は monotonic。待ちは self-pipe の select で、signal で即座に起きる):
# 1. signal の記録があれば中断 (interrupted)。
# 2. leader の終了を回収せずに確かめる (proc_pid_rusage の exit 時刻が 0 でない)。終わっていれば完了。時間を過ぎて
#    いても、終了を先に観測したら正常の終了として扱う (終了の時刻は巡回の粒度でしか分からない)。
# 3. 時間の上限を過ぎていれば time。
# 4. group の member を proc_listpids で列挙し、生きている member の phys_footprint (proc_pid_rusage) を足す。生きて
#    いる member は proc_pidinfo で pgid を確かめてから足す (列挙と計測の間に再利用された別 process を数えない)。
#    zombie と消えた pid (ESRCH) は 0。それ以外の失敗 (EPERM など) と列挙の失敗はその巡回を incomplete にし、合計で
#    判定しない。後始末が終わるまで leader を回収しないので group には常に leader (生きているか zombie) が居る。
#    列挙の結果が空か leader を含まなければ列挙の失敗とみなす (libproc は syscall の失敗を 0 件に変えるため)。
#    incomplete が 3 巡回続いたら monitor。完全に測れた巡回でだけ連続回数を 0 に戻す。合計が上限を超えたら leader
#    の終了をもう一度確かめ、終わっていなければ footprint。
# 監視が想定外の error で続けられないとき、と完了した leader の終了 status を回収できないときも monitor にする。
#
# 止め方 (後始末は 1 回だけ): leader は最後まで回収しない (leader の zombie が pgid を保持するので、後始末の間に
# pgid が別の group に再利用されない)。
# 1. group に TERM → 生きている member (leader を含む。zombie は数えない) が 0 になるまで最大 2 秒 poll → 残れば
#    group に KILL → 最大 2 秒 poll。観測 (列挙や計測) が失敗するか例外を出したら「未確定」として、その段階の
#    poll を打ち切って次の段階へ進む。
# 2. 観測の結果にかかわらず、最後に group へ KILL を必ず送り (leader の zombie だけなら無害。列挙の後に fork された
#    子も止める)、leader が終わっていなければ leader にも KILL を送る (group を抜けた leader にも届く)。
# 3. leader 以外の生きた member が 0 であることを、POLL_SECONDS を置いた 2 回の連続した列挙で確かめる (見つけたら
#    KILL を送り直す)。最大 2 秒で確定できなければ cleanup incomplete。
# 4. leader を回収する (最大 2 秒)。
# 各段階は前の段階の例外にかかわらず走り、後始末の中で例外が起きたら cleanup incomplete。group への kill の ESRCH
# と EPERM (macOS は zombie だけの group に EPERM を返す) は、止まったかを観測で確かめる。無期限には待たない。
# leader が自分で終わったときは、残っている member が見えれば 1. から、見えなければ 2. から行う (leftover_killed は
# TERM の前に数えた数と、3. で新たに見つけた数の合計)。
# signal は handler で最初の 1 つだけを記録して self-pipe に 1 byte 書き (書けなくても flag は立つ)、後始末は
# handler の外で走る (2 回目の signal で猶予を延ばさず、理由も上書きしない)。起動時に無視されていた signal (nohup の
# HUP など) は trap せず無視のまま残す (command にも無視が継承される。shell と同じ)。SIGCHLD は既定の扱いに戻す
# (無視を継承すると leader の zombie が残らず、終了 status も pgid の保持も失われるため)。self-pipe は書く側を先に
# 閉じる。
#
# 順序と診断: 後始末 → report → 診断。stderr は command と共有しうる (読まれずに詰まっていることもある) ので、診断は
# 後始末と report の後にまとめて出し、1 行ずつ、書き込めることを select で確かめてから (最大 0.2 秒) PIPE_BUF 以下
# に切り詰めて書き、書けなければ捨てる。stderr に O_NONBLOCK は立てない (command と open file description を共有して
# いるので、command の書き込みまで失敗させる)。診断の失敗は終了の理由と report に影響させない。
#
# report (--report のとき。起動を試みた後は exit の直前に必ず試行する。同じ dir に排他で作った一時 file (0600)
# に書いて rename で置く。書けなければ一時 file を消して stderr に warning を出し、exit code は変えない):
#   {"version":1,"command_started":bool,"reason":null|"time"|"footprint"|"monitor"|"interrupted",
#    "signal":null|"TERM"|...,"exit_status":<safe-run の exit code>,"command_exit":int|null,
#    "command_signal":int|null,"peak_footprint_mib":number|null,"elapsed_seconds":number,
#    "leftover_killed":int,"cleanup_complete":bool}
# peak は完全に測れた巡回の合計の最大 (一度も測れなければ null)。elapsed は起動から leader の終了の観測 (または
# 止める判断) まで。
#
# 限界 (docs/safe-run.md): group を抜けた子 (setsid / setpgid) は追えない (leader が抜けると列挙の失敗として
# monitor で止まる)。safe-run への SIGKILL / SIGSTOP は捕捉できない。setuid の program は計測できず monitor で
# 止まる。端末の tostop で背景の group の書き込みが止まりうる。共有 memory は member ごとに重複して数えうる (安全側)。

require "json"

module SafeRun
  NAME = "personal-safe-run"
  MIB = 1024 * 1024
  FOOTPRINT_RANGE = (1..1_048_576).freeze
  SECONDS_RANGE = (1..86_400).freeze
  POSITIVE_RE = /\A[1-9]\d*\z/.freeze
  OPTION_KEYS = %w[--max-footprint-mb --max-seconds --report].freeze
  INTERVAL = 0.25
  INCOMPLETE_LIMIT = 3
  GRACE_SECONDS = 2.0
  POLL_SECONDS = 0.05
  # 診断の 1 行の上限 (改行を含む)。pipe への PIPE_BUF 以下の書き込みは分割されず、select が書き込めると返せば待たない。
  PIPE_BUF = 512
  DIAG_WAIT_SECONDS = 0.2
  TRAPPED_SIGNALS = %w[INT TERM HUP QUIT TSTP].freeze
  REPORT_VERSION = 1
  EXIT_USAGE = 2
  EXIT_CANNOT_EXECUTE = 126
  EXIT_NOT_FOUND = 127
  EXIT_LIMIT = 137

  # libproc (<libproc.h> / <sys/resource.h> / <sys/proc_info.h>)。offset は 2026-10-10 に macOS 26 / arm64 で
  # 実測し、phys_footprint は `footprint` CLI の値と一致することを確かめた。
  PROC_PGRP_ONLY = 2
  RUSAGE_INFO_V0 = 0
  RUSAGE_SIZE = 96 # uuid 16 byte + uint64 × 10
  RUSAGE_FOOTPRINT_OFFSET = 72 # ri_phys_footprint
  RUSAGE_EXIT_OFFSET = 88 # ri_proc_exit_abstime (0 なら終わっていない)
  PROC_PIDTBSDINFO = 3
  BSDINFO_SIZE = 136
  BSDINFO_PGID_OFFSET = 100 # pbi_pgid
  LISTPIDS_MARGIN = 64 * 4
  LISTPIDS_MAX_BYTES = 4 * MIB
  ESRCH = Errno::ESRCH::Errno

  # usage の誤り (exit 2)。
  class UsageError < StandardError; end
  # 前提の不成立 (exit 2。command を起動しない)。
  class Unsupported < StandardError; end

  Options = Struct.new(:max_footprint_mb, :max_seconds, :report, :command)
  # reason: nil (leader が自分で終わった) / "time" / "footprint" / "monitor" / "interrupted"。
  Outcome = Struct.new(:reason, :signal, :elapsed, :peak, :total)
  # status: leader の Process::Status (回収できなければ nil)。complete: cleanup が完了したか。
  Cleanup = Struct.new(:status, :leftover, :complete)

  module_function

  def usage
    "usage: #{NAME} --max-footprint-mb N --max-seconds N [--report FILE] -- <command> [args...]"
  end

  def help
    <<~TEXT
      #{usage}
      command を新しい process group で起動し、group の phys_footprint の合計 (MiB) と経過時間 (秒) の上限を
      超えたら group ごと止める (TERM → 2 秒 → KILL)。leader が終わった後に残った process も止める。
      exit: command の exit code / 137 = 上限で止めた / 128 + signo = signal で中断した /
      127・126 = 起動できない / 2 = usage の誤りか前提の不成立 (command を起動しない)。
      --report FILE: 結果を JSON で書く (FILE は在ってはいけない)。詳細は docs/safe-run.md。
    TEXT
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # safe-run 自身の診断を 1 行出す。stderr は command と共有しうる (読まれずに詰まっていることもある) ので、書き込める
  # ことを select で確かめてから (最大 DIAG_WAIT_SECONDS)、PIPE_BUF 以下に切り詰めて書き、書けなければ捨てる。
  # stderr に O_NONBLOCK は立てない (command と open file description を共有しているので、command の書き込みまで
  # 失敗させる)。書き込みの失敗 (EPIPE など) は終了の理由と report に影響させない。
  def diag(message)
    line = "#{NAME}: #{message}".byteslice(0, PIPE_BUF - 1).scrub("") + "\n"
    return unless IO.select(nil, [$stderr], nil, DIAG_WAIT_SECONDS)

    $stderr.write(line)
  rescue SystemCallError, IOError
    nil
  end

  # 監視と後始末の間の診断は溜めておき、後始末と report の後に flush_notes で出す。
  def note(message)
    @notes << message
  end

  def flush_notes
    @notes.each { |message| diag(message) }
    @notes.clear
  end

  # ---- 引数 ------------------------------------------------------------------------------------------------

  def parse_args(args)
    separator = args.index("--")
    raise UsageError, "-- と command がありません" if separator.nil?

    command = args[(separator + 1)..-1]
    raise UsageError, "-- の後に command がありません" if command.empty?

    values = {}
    rest = args[0...separator]
    until rest.empty?
      key = rest.shift
      raise UsageError, "知らない option です: #{key.inspect}" unless OPTION_KEYS.include?(key)
      raise UsageError, "#{key} が 2 回あります" if values.key?(key)
      raise UsageError, "#{key} に値がありません" if rest.empty?

      values[key] = rest.shift
    end
    report = values["--report"]
    raise UsageError, "--report の値が空です" if report && report.empty?

    Options.new(parse_limit(values, "--max-footprint-mb", FOOTPRINT_RANGE),
                parse_limit(values, "--max-seconds", SECONDS_RANGE), report, command)
  end

  def parse_limit(values, key, range)
    value = values[key]
    raise UsageError, "#{key} は必須です" if value.nil?
    unless value.match?(POSITIVE_RE) && range.cover?(value.to_i)
      raise UsageError, "#{key} は #{range.min}〜#{range.max} の整数です"
    end

    value.to_i
  end

  # 親 dir が在り、FILE が在らないこと (古い report を今回のものと読み違えないため)。
  def check_report_path(path)
    begin
      raise UsageError, "--report の親 directory がありません" unless File.stat(File.dirname(path)).directory?
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise UsageError, "--report の親 directory がありません"
    rescue SystemCallError => e
      raise UsageError, "--report の親 directory を確かめられません (#{e.class})"
    end
    begin
      File.lstat(path)
    rescue Errno::ENOENT
      return
    rescue SystemCallError => e
      raise UsageError, "--report の path を確かめられません (#{e.class})"
    end
    raise UsageError, "--report の file が既に在ります (実行ごとに新しい path を渡してください)"
  end

  # ---- libproc ---------------------------------------------------------------------------------------------

  def load_libproc
    raise Unsupported, "macOS 専用です (#{RUBY_PLATFORM})" unless RUBY_PLATFORM.include?("darwin")

    require_fiddle
    bind_libproc
    self_check
  end

  def require_fiddle
    require "fiddle"
  rescue LoadError => e
    raise Unsupported, "Fiddle を load できません (#{e.class})"
  end

  def bind_libproc
    handle = Fiddle.dlopen(nil)
    int = Fiddle::TYPE_INT
    ptr = Fiddle::TYPE_VOIDP
    @listpids = Fiddle::Function.new(handle["proc_listpids"], [int, int, ptr, int], int)
    @rusage = Fiddle::Function.new(handle["proc_pid_rusage"], [int, int, ptr], int)
    @pidinfo = Fiddle::Function.new(handle["proc_pidinfo"], [int, int, Fiddle::TYPE_LONG_LONG, ptr, int], int)
    @rusage_buf = Fiddle::Pointer.malloc(RUSAGE_SIZE, Fiddle::RUBY_FREE)
    @bsdinfo_buf = Fiddle::Pointer.malloc(BSDINFO_SIZE, Fiddle::RUBY_FREE)
  rescue Fiddle::DLError => e
    raise Unsupported, "libproc を呼べません (#{e.class})"
  end

  # 自分自身で 3 つの呼び出しと offset (pgid は getpgrp と比べる) を確かめる。守れないまま command を走らせない。
  def self_check
    status, value = pid_rusage(Process.pid)
    unless status == :ok && value[:exit_abstime].zero? && value[:footprint].positive?
      raise Unsupported, "proc_pid_rusage で自分の footprint を読めません"
    end

    status, value = pid_pgid(Process.pid)
    raise Unsupported, "proc_pidinfo で自分の pgid を読めません" unless status == :ok && value == Process.getpgrp

    pids = list_pgrp(Process.getpgrp)
    raise Unsupported, "proc_listpids で自分の process group を列挙できません" unless pids && pids.include?(Process.pid)
  end

  # rusage_info_v0 の 96 byte から phys_footprint と exit 時刻を取り出す (純粋な関数)。
  def decode_rusage(bytes)
    raise ArgumentError, "rusage_info_v0 は #{RUSAGE_SIZE} byte です" unless bytes.bytesize == RUSAGE_SIZE

    { footprint: bytes.byteslice(RUSAGE_FOOTPRINT_OFFSET, 8).unpack1("Q"),
      exit_abstime: bytes.byteslice(RUSAGE_EXIT_OFFSET, 8).unpack1("Q") }
  end

  # proc_bsdinfo の 136 byte から pgid を取り出す (純粋な関数)。
  def decode_bsdinfo_pgid(bytes)
    raise ArgumentError, "proc_bsdinfo は #{BSDINFO_SIZE} byte です" unless bytes.bytesize == BSDINFO_SIZE

    bytes.byteslice(BSDINFO_PGID_OFFSET, 4).unpack1("L")
  end

  # [:ok, {footprint:, exit_abstime:}] / [:error, errno]。zombie は成功し、exit_abstime が 0 でない。
  def pid_rusage(pid)
    rc = @rusage.call(pid, RUSAGE_INFO_V0, @rusage_buf)
    return [:error, Fiddle.last_error] unless rc.zero?

    [:ok, decode_rusage(@rusage_buf[0, RUSAGE_SIZE])]
  end

  # [:ok, pgid] / [:error, errno]。zombie には ESRCH を返す。
  def pid_pgid(pid)
    filled = @pidinfo.call(pid, PROC_PIDTBSDINFO, 0, @bsdinfo_buf, BSDINFO_SIZE)
    return [:error, Fiddle.last_error] unless filled == BSDINFO_SIZE

    [:ok, decode_bsdinfo_pgid(@bsdinfo_buf[0, BSDINFO_SIZE])]
  end

  # proc_listpids の生の結果 (pgid の group の pid)。呼び出しが負を返したら nil。buffer が足りないと切り詰めて
  # 埋めるので、埋まり切っていたら倍にして取り直す。libproc は syscall の失敗を 0 件に変えることがあるので、空の
  # 結果の意味は呼び出し側が決める。
  def list_pgrp(pgid)
    estimate = @listpids.call(PROC_PGRP_ONLY, pgid, nil, 0)
    return nil if estimate.negative?

    size = estimate + LISTPIDS_MARGIN
    while size <= LISTPIDS_MAX_BYTES
      buf = Fiddle::Pointer.malloc(size, Fiddle::RUBY_FREE)
      filled = @listpids.call(PROC_PGRP_ONLY, pgid, buf, size)
      return nil if filled.negative?
      return buf[0, filled].unpack("l*").reject(&:zero?) if filled < size

      size *= 2
    end
    nil
  end

  # command の group の member (leader を含む)。後始末が終わるまで leader を回収しないので、group には常に leader
  # (生きているか zombie) が居る。結果が空か leader を含まなければ列挙の失敗 (nil) として扱う (member 0 とは扱わない)。
  def list_group(leader)
    pids = list_pgrp(leader)
    return nil if pids.nil? || !pids.include?(leader)

    pids
  end

  # member 1 つの状態: [:alive, footprint] / [:exited] (zombie) / [:gone] (消えた、または別 group の process) /
  # [:error, errno] (測れない)。
  def member_state(pid, pgid)
    status, value = pid_rusage(pid)
    return(value == ESRCH ? [:gone] : [:error, value]) if status == :error
    return [:exited] unless value[:exit_abstime].zero?

    footprint = value[:footprint]
    status, value = pid_pgid(pid)
    return(value == ESRCH ? [:gone] : [:error, value]) if status == :error
    return [:gone] unless value == pgid

    [:alive, footprint]
  end

  # group の生きている member の phys_footprint の合計 (byte)。1 つでも測れなければ nil (incomplete)。
  def measure_group(pgid)
    pids = list_group(pgid)
    return nil if pids.nil?

    total = 0
    pids.each do |pid|
      state, value = member_state(pid, pgid)
      return nil if state == :error

      total += value if state == :alive
    end
    total
  end

  # leader 以外の生きている (または測れない) member の pid。列挙できなければ nil。
  def live_other_pids(leader)
    pids = list_group(leader)
    return nil if pids.nil?

    pids.select do |pid|
      next false if pid == leader

      state, = member_state(pid, leader)
      %i[alive error].include?(state)
    end
  end

  # leader を回収せずに、終わったか (zombie か) を確かめる。消えていたら (ESRCH) 終わったとみなす。
  def leader_exited?(leader)
    status, value = pid_rusage(leader)
    return !value[:exit_abstime].zero? if status == :ok

    value == ESRCH
  end

  # ---- 監視 -------------------------------------------------------------------------------------------------

  # 起動時に無視されていた signal (nohup の HUP など) は無視のまま残し、command にも無視を継承させる (shell と
  # 同じ)。先に無視にしてから前の扱いを見るので、無視されていた signal を handler が受ける隙間は無い。
  def install_traps(writer)
    @signal = nil
    TRAPPED_SIGNALS.each do |name|
      next if Signal.trap(name, "IGNORE") == "IGNORE"

      Signal.trap(name) do
        @signal ||= name
        # self-pipe に書けなくても (閉じた後、読む側が先に閉じた EPIPE など) flag は立っているので握る
        # (exception: false が抑えるのは EAGAIN だけで、EPIPE は送出される)。
        begin
          writer.write_nonblock("!", exception: false) unless writer.closed?
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end

  def wait_tick(reader, seconds)
    IO.select([reader], nil, nil, seconds)
  end

  def watch(leader, options, reader, started)
    deadline = started + options.max_seconds
    limit = options.max_footprint_mb * MIB
    streak = 0
    peak = nil
    loop do
      wait_tick(reader, INTERVAL)
      return Outcome.new("interrupted", @signal, now - started, peak) if @signal
      return Outcome.new(nil, nil, now - started, peak) if leader_exited?(leader)
      return Outcome.new("time", nil, now - started, peak) if now >= deadline

      total = measure_group(leader)
      if total.nil?
        streak += 1
        return Outcome.new("monitor", nil, now - started, peak) if streak >= INCOMPLETE_LIMIT

        next
      end
      streak = 0
      peak = total if peak.nil? || total > peak
      next unless total > limit
      return Outcome.new(nil, nil, now - started, peak) if leader_exited?(leader)

      return Outcome.new("footprint", nil, now - started, peak, total)
    end
  end

  # ---- 止め方 -----------------------------------------------------------------------------------------------

  # 後始末の中の 1 段階を走らせる。例外は記録して「未確定」(:unknown) を返し、次の段階を止めない (後始末の中で
  # 例外が起きたら cleanup incomplete)。
  def guarded
    yield
  rescue StandardError => e
    @cleanup_errors << e.class
    :unknown
  end

  # 期限まで POLL_SECONDS ごとに観測する。true で確定。観測が未確定 (列挙の失敗か例外) なら、その段階の poll を
  # 打ち切って false を返す (次の段階へ進む)。期限でも false。
  def poll_until(seconds)
    deadline = now + seconds
    loop do
      result = guarded { yield }
      return true if result == true
      return false if result == :unknown || now >= deadline

      sleep POLL_SECONDS
    end
  end

  # 生きている member (leader を含む。zombie は数えない) が 0 なら true、残っていれば false、列挙できなければ :unknown。
  def group_stopped?(leader)
    others = live_other_pids(leader)
    return :unknown if others.nil?

    others.empty? && leader_exited?(leader)
  end

  # 届いたかどうかは返さない (止まったかは観測で確かめる)。macOS は zombie だけの group への kill に EPERM を返す
  # (2026-10-10 実測) ので、EPERM は「止められない member がいる」とは限らない。生きた member が残れば確認の段階で
  # cleanup incomplete になる。
  def signal_group(leader, signal)
    Process.kill(signal, -leader)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  # 未回収の leader の pid は再利用されないので、group を抜けた leader にも直接 KILL を送れる。
  def kill_leader(leader)
    Process.kill("KILL", leader)
  rescue Errno::ESRCH
    nil
  rescue Errno::EPERM
    note("warning: leader に SIGKILL を送れません (EPERM)")
  end

  # leader 以外の生きた member が 0 であることを、POLL_SECONDS を置いた 2 回の連続した列挙で確かめる。生きた member
  # を見つけたら found に足して group に KILL を送り直す。期限 (GRACE_SECONDS) 内に確定できなければ false。
  def confirm_empty(leader, found)
    deadline = now + GRACE_SECONDS
    empty_in_a_row = 0
    loop do
      others = guarded { live_other_pids(leader) }
      if others.is_a?(Array) && others.empty?
        empty_in_a_row += 1
        return true if empty_in_a_row >= 2
      else
        empty_in_a_row = 0
        if others.is_a?(Array)
          found.concat(others)
          guarded { signal_group(leader, "KILL") }
        end
      end
      return false if now >= deadline

      sleep POLL_SECONDS
    end
  end

  # leader を回収する (最大 GRACE_SECONDS)。回収できなければ nil。
  def reap(leader)
    deadline = now + GRACE_SECONDS
    loop do
      begin
        _, status = Process.waitpid2(leader, Process::WNOHANG)
      rescue Errno::EINTR
        next
      rescue Errno::ECHILD
        return nil
      end
      return status if status
      return nil if now >= deadline

      sleep POLL_SECONDS
    end
  end

  # 後始末 (1 回だけ)。各段階は前の段階の例外にかかわらず走り、最後の group への KILL、leader への KILL、2 回の確認、
  # 回収は必ず試行する。reason が nil (leader が自分で終わった) なら、残っている member が見えたときだけ TERM から
  # 始め、leftover は TERM の前に数えた pid と確認で新たに見つけた pid の合計。
  def finish(leader, reason)
    @cleanup_errors = []
    counted = []
    graceful = true
    if reason.nil?
      others = guarded { live_other_pids(leader) }
      counted = others if others.is_a?(Array)
      graceful = !others.is_a?(Array) || !others.empty?
    end
    if graceful
      guarded { signal_group(leader, "TERM") }
      unless poll_until(GRACE_SECONDS) { group_stopped?(leader) }
        guarded { signal_group(leader, "KILL") }
        poll_until(GRACE_SECONDS) { group_stopped?(leader) }
      end
    end
    guarded { signal_group(leader, "KILL") }
    guarded { kill_leader(leader) } unless guarded { leader_exited?(leader) } == true
    found = []
    empty = guarded { confirm_empty(leader, found) } == true
    status = guarded { reap(leader) }
    status = nil if status == :unknown
    leftover = reason.nil? ? (counted | found).size : 0
    Cleanup.new(status, leftover, empty && !status.nil? && @cleanup_errors.empty?)
  end

  # ---- 実行 -------------------------------------------------------------------------------------------------

  def spawn_command(command)
    options = { pgroup: true }
    options[:in] = File::NULL if $stdin.tty?
    Process.spawn([command[0], command[0]], *command[1..-1], **options)
  end

  # 順序は 後始末 → report → 診断 (診断は stderr の詰まりで待たされうるので最後)。
  def supervise(options)
    @notes = []
    reader, writer = IO.pipe
    Signal.trap("CHLD", "SYSTEM_DEFAULT")
    install_traps(writer)
    started = now
    begin
      leader = spawn_command(options.command)
    rescue SystemCallError => e
      code = e.is_a?(Errno::ENOENT) ? EXIT_NOT_FOUND : EXIT_CANNOT_EXECUTE
      note("command を起動できません (#{e.class})")
      if options.report
        write_report(options.report, report_data(false, Outcome.new(nil, nil, 0.0, nil), code, Cleanup.new(nil, 0, true)))
      end
      flush_notes
      return code
    end

    outcome = nil
    begin
      outcome = watch(leader, options, reader, started)
    rescue StandardError => e
      note("監視を続けられないので command の process group を止めます (#{e.class})")
      outcome = Outcome.new("monitor", nil, now - started, nil)
    ensure
      cleanup = finish(leader, outcome ? outcome.reason : "monitor")
    end
    if outcome.reason.nil? && cleanup.status.nil?
      note("command の終了 status を回収できませんでした")
      outcome.reason = "monitor"
    end
    code = exit_code(outcome, cleanup)
    write_report(options.report, report_data(true, outcome, code, cleanup)) if options.report
    report_outcome(options, outcome, cleanup)
    flush_notes
    code
  ensure
    # 書く側を先に閉じる (handler は閉じた書く側に書かない)。
    writer&.close
    reader&.close
  end

  def exit_code(outcome, cleanup)
    case outcome.reason
    when nil
      status = cleanup.status
      status.exited? ? status.exitstatus : 128 + status.termsig
    when "interrupted" then 128 + Signal.list.fetch(outcome.signal)
    else EXIT_LIMIT
    end
  end

  def report_outcome(options, outcome, cleanup)
    case outcome.reason
    when "time"
      note("stopped (reason=time): 時間の上限 (#{options.max_seconds} 秒) を超えたので command の process group を止めました")
    when "footprint"
      note("stopped (reason=footprint): memory (phys_footprint) の合計 #{mib(outcome.total)} MiB が上限 " \
           "(#{options.max_footprint_mb} MiB) を超えたので command の process group を止めました")
    when "monitor"
      note("stopped (reason=monitor): process group を監視できないので command の process group を止めました")
    when "interrupted"
      note("stopped (reason=interrupted): SIG#{outcome.signal} を受けたので command の process group を止めました")
    end
    if cleanup.leftover.positive?
      note("warning: command の終了後に残っていた process #{cleanup.leftover} 個を止めました")
    end
    unless @cleanup_errors.empty?
      note("warning: 後始末の観測が例外を出しました (#{@cleanup_errors.uniq.join(", ")})")
    end
    note("warning: process group を止め切れませんでした (cleanup incomplete)") unless cleanup.complete
  end

  def mib(bytes)
    bytes && (bytes.to_f / MIB).round(1)
  end

  def report_data(started, outcome, code, cleanup)
    status = cleanup.status
    {
      "version" => REPORT_VERSION,
      "command_started" => started,
      "reason" => outcome.reason,
      "signal" => outcome.signal,
      "exit_status" => code,
      "command_exit" => status&.exitstatus,
      "command_signal" => status&.termsig,
      "peak_footprint_mib" => mib(outcome.peak),
      "elapsed_seconds" => outcome.elapsed.round(3),
      "leftover_killed" => cleanup.leftover,
      "cleanup_complete" => cleanup.complete
    }
  end

  # 同じ dir に排他で作った一時 file (0600) に書いて rename で置く。失敗したら一時 file を消して warning。
  def write_report(path, data)
    tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{rand(1 << 32).to_s(16)}.tmp")
    created = false
    begin
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        created = true
        file.write(JSON.generate(data) + "\n")
      end
      File.rename(tmp, path)
      created = false
    rescue SystemCallError, IOError => e
      note("warning: report を書けませんでした (#{e.class})")
    ensure
      remove_tmp(tmp) if created
    end
  end

  def remove_tmp(tmp)
    File.unlink(tmp)
  rescue SystemCallError => e
    note("warning: report の一時 file を消せませんでした (#{e.class})")
  end

  def run(args)
    if args == ["--help"] || args == ["-h"]
      $stdout.write(help)
      return 0
    end
    options = parse_args(args)
    load_libproc
    check_report_path(options.report) if options.report
    supervise(options)
  rescue UsageError => e
    diag(e.message)
    diag(usage)
    EXIT_USAGE
  rescue Unsupported => e
    diag("#{e.message} (command は起動しません)")
    EXIT_USAGE
  end
end

exit SafeRun.run(ARGV) if $PROGRAM_NAME == __FILE__
