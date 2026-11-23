# frozen_string_literal: true

# scripts/tests/*.sh を、決めた数ずつ並べて走らせる (#726)。CI の「Run self-tests」が呼ぶ。手元でも使える。
# 使い方: ruby scripts/tests/lib/run-all.rb [--jobs N] [--dir DIR]
# tests/lib/ に置くのは、この file 自身が test として拾われないようにするため (拾うのは dir の直下の *.sh だけ)。
#
# 並べてよい前提: test は自分の一時 dir の中だけを書き換える。repo の作業ツリー、HOME、決まった path、決まった port は、
# ほかの test と共有なので書き換えない。実時間の上限に厳しく、並べると揺れる test は ALONE に理由と一緒に入れる。
#
# 責務の境界:
#   - 1 本が失敗しても、残りを全部走らせる (1 回の CI で全失敗を見るため)。
#   - 出力は test ごとに file に取り、終わってからまとめて出す (並べても混ざらない)。止まった test が分かるように、
#     始まりの行 (start:) だけは先に出す。
#   - test の数は、この file が数える。走らせた数と見つけた数が違えば、失敗にする。
#   - test の時間の上限は付けない (job の上限と、手元では personal-safe-run が持つ)。
#
# exit: 0 全部が通った、1 失敗した test がある (INT と TERM で止められたときも)、2 使い方の誤り・test が無い。

require "fileutils"
require "tmpdir"

class RunAll
  class Usage < StandardError; end

  TESTS_DIR = File.expand_path("..", __dir__)
  JOBS = (1..16).freeze
  SLOWEST = 10
  # 1 本ずつ、ほかが終わった後に走らせる test と、その理由。
  ALONE = {
    "opencode-plugin-test.sh" => "短い時間の上限で題材の script を止める。混むと、script が pid を書く前に止まる。手元で core の 2 倍に並べると揺れた",
    "safe-run-test.sh" => "続けて届く signal の順序と、止めるまでの実時間を見る。手元で core の 2 倍に並べると揺れた",
  }.freeze
  # 止めるときに、TERM から KILL までに待つ秒。
  GRACE = 2
  POLL = 0.05
  CHILD_MARK = "c"
  STOP_MARK = "s"

  Test = Struct.new(:name, :label, :log, :pid, :started, :seconds, :failure, keyword_init: true)

  # out は出力先。alone は単独で走らせる test の表 (--dir を渡したときは空)。
  def initialize(dir:, jobs:, label:, alone: {}, out: $stdout)
    @dir = dir
    @jobs = jobs
    @label = label
    @alone = alone
    @out = out
    @running = {}
    @done = []
  end

  # 走らせる test の名前 (dir の直下の *.sh の file を、名前の順に)。
  def self.names(dir)
    Dir.children(dir).select { |n| n.end_with?(".sh") && File.file?(File.join(dir, n)) }.sort
  end

  def run
    names = self.class.names(@dir)
    raise Usage, "no tests (*.sh) in the directory" if names.empty?

    unknown = @alone.keys - names
    raise Usage, "ALONE names a test that does not exist: #{unknown.join(', ')}" unless unknown.empty?

    started = now
    Dir.mktmpdir("run-all-") do |logs|
      @logs = logs
      with_signals do
        drain(names - @alone.keys, @jobs) && drain(names & @alone.keys, 1)
      end
    end
    return 1 if @interrupted

    summary(names.length, now - started)
    @done.length == names.length && @done.none?(&:failure) ? 0 : 1
  end

  private

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def say(line)
    @out.write("#{line}\n")
  end

  # queue の test を、limit 本まで並べて走らせ切る。止められたら false。
  def drain(queue, limit)
    queue = queue.dup
    until queue.empty? && @running.empty?
      start(queue.shift) while !queue.empty? && @running.length < limit
      # どれも起動できなかったとき。子が無いと wait2 は例外を上げる。
      next if @running.empty?

      pid, status = Process.wait2(-1, Process::WNOHANG)
      if pid
        finish(@running.delete(pid), status) if @running.key?(pid)
      elsif interrupted?
        stop
        return false
      end
    end
    true
  end

  # 子が終わるか、INT か TERM が届くまで待つ。INT か TERM なら true。
  # CHLD は、wait2 と select の間に届いても pipe に残るので、取りこぼさない。1 秒の期限は、その念のため。
  def interrupted?
    return false unless IO.select([@signal_reader], nil, nil, 1)

    @signal_reader.read_nonblock(4096).include?(STOP_MARK)
  rescue IO::WaitReadable
    false
  end

  def start(name)
    test = Test.new(name: name, label: "#{@label}/#{name}", log: File.join(@logs, "#{name}.log"), started: now)
    say "start: #{test.label}"
    # 名前を shell に解釈させない ([path, argv0] の形)。group を分けるのは、止めるときに test の子まで届かせるため。
    path = File.join(@dir, name)
    test.pid = Process.spawn([path, path], in: File::NULL, out: [test.log, "w"], err: %i[child out], pgroup: true)
    @running[test.pid] = test
  rescue SystemCallError => e
    File.write(test.log, "#{e.class.name.split('::').last}\n")
    complete(test, "cannot start")
  end

  def finish(test, status)
    failure = if status.signaled? then "signal #{status.termsig}"
              elsif !status.success? then "exit #{status.exitstatus}"
              end
    complete(test, failure)
  end

  def complete(test, failure)
    test.seconds = now - test.started
    test.failure = failure
    @done << test
    print_log(test)
    say "FAIL: #{test.label} (#{failure})" if failure
  end

  def print_log(test)
    say "--- #{test.label}"
    text = File.file?(test.log) ? File.binread(test.log) : ""
    @out.write(text)
    @out.write("\n") unless text.empty? || text.end_with?("\n")
  end

  def summary(found, wall)
    say "--- slowest tests (seconds)"
    @done.sort_by { |t| [-t.seconds, t.name] }.first(SLOWEST).each { |t| say "#{t.seconds.round}\t#{t.label}" }
    total = @done.map(&:seconds).sum.round
    say "total #{total} s over #{@done.length} tests, wall #{wall.round} s, #{@jobs} jobs"
    say "FAIL: ran #{@done.length} of #{found} tests" unless @done.length == found
    failed = @done.select(&:failure)
    say "failed: #{failed.length} (#{failed.map(&:label).join(', ')})" unless failed.empty?
  end

  # --- 止める -------------------------------------------------------------------------------
  # signal の handler では記録だけをする (handler の中で例外を上げたり待ったりしない)。
  # 走っている子は多くて 16 本なので、読む前に pipe が埋まることはない。
  def with_signals
    @signal_reader, writer = IO.pipe
    marks = { "CHLD" => CHILD_MARK, "INT" => STOP_MARK, "TERM" => STOP_MARK }
    previous = marks.map { |name, mark| [name, trap(name) { writer.write_nonblock(mark) rescue nil }] }
    yield
  ensure
    previous&.each { |name, handler| trap(name, handler || "DEFAULT") }
    [@signal_reader, writer].compact.each(&:close)
  end

  # 走っている test の group を止め、それまでの出力を出す (止まっていた test を調べられるように)。
  def stop
    @interrupted = true
    tests = @running.values
    say "interrupted; running: #{tests.map(&:label).join(', ')}"
    tests.each { |t| signal_group("TERM", t.pid) }
    deadline = now + GRACE
    sleep POLL while now < deadline && tests.any? { |t| group_alive?(t.pid) }
    tests.each { |t| signal_group("KILL", t.pid) }
    tests.each do |t|
      begin
        Process.wait(t.pid)
      rescue Errno::ECHILD
        nil
      end
      print_log(t)
    end
    @running.clear
  end

  def signal_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  # leader を回収しながら、group に生きている process が残っているかを見る (EPERM は zombie だけの group)。
  def group_alive?(pid)
    begin
      Process.wait(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      nil
    end
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # --- 入口 -------------------------------------------------------------------------------
  USAGE = "usage: run-all.rb [--jobs N] [--dir DIR]"

  public

  def self.parse(argv)
    opts = { jobs: 1 }
    until argv.empty?
      case (key = argv.shift)
      when "--jobs"
        value = argv.shift.to_s
        raise Usage, "--jobs must be an integer from #{JOBS.min} to #{JOBS.max}" unless value.match?(/\A[0-9]{1,2}\z/) && JOBS.cover?(value.to_i)

        opts[:jobs] = value.to_i
      when "--dir"
        opts[:dir] = argv.shift
        raise Usage, "--dir must be a directory" unless opts[:dir] && File.directory?(opts[:dir])
      else
        raise Usage, "unknown argument: #{key}"
      end
    end
    opts
  end

  def self.main(argv)
    $stdout.sync = true
    $stdout.binmode
    if argv == ["--help"] || argv == ["-h"]
      puts USAGE
      return 0
    end
    opts = parse(argv.dup)
    given = opts[:dir]
    new(dir: given ? File.expand_path(given) : TESTS_DIR, jobs: opts[:jobs], label: given ? given.chomp("/") : "scripts/tests",
        alone: given ? {} : ALONE).run
  rescue Usage => e
    warn "error: #{e.message}"
    warn USAGE
    2
  end
end

exit RunAll.main(ARGV) if $PROGRAM_NAME == __FILE__
