#!/bin/sh
# personal-pr-merge-wait.rb の self-test (#675)。
# 本物の gh には触れない。PATH の先頭に置いた偽の gh が、呼ばれた回数で決めた応答を返し、受け取った argv・pid・時刻と、
# 呼ばれた時点の script の stdout を記録する。終わり方ごとの exit と出力の行、確認の間隔と上限の時刻の最後の確認、失敗の
# 数え方、入力の誤り、gh に求める field、止められたときに gh とその group を残さないこと (後始末の間に届く 2 回目の signal、
# 確かめる間の待ちの最中の signal、TERM を受け流す group の子を含む) を確かめる。gh の 1 回の上限 (60 秒) は、上限の定数を
# 差し替えて、gh を起動する部分を直接呼んで確かめる (stdout を閉じた後も動く gh、group に子を残して終わる gh、止めている間に
# 届く signal、gh を起動した直後と回収した直後に届く signal)。locale が C でも同じ結果になることも見る。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-pr-merge-wait.rb"
[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" -rjson -rrbconfig -rfileutils - "$src" "$tmp" <<'RUBY'
src, tmp = ARGV
tmp = File.realpath(tmp)
H = "a" * 40
B = "b" * 40
M = "c" * 40
bin = File.join(tmp, "bin")
FileUtils.mkdir_p(bin)
GH = File.join(bin, "gh")
File.write(GH, <<~RB)
  #!#{RbConfig.ruby}
  # encoding: UTF-8
  require "json"
  d = ENV.fetch("T675_CASE")
  log = File.join(d, "calls.jsonl")
  n = File.exist?(log) ? File.readlines(log).size : 0
  steps = ENV.fetch("T675_STEPS").split(",")
  step = steps[[n, steps.size - 1].min]
  # TERM を受け流す gh。呼び出しの記録より前に trap を置き、止める側が TERM を送る時点で必ず効いているようにする。
  trap("TERM") {} if step == "stubborn"
  # 同じ process group に子を持つ gh。family の子は TERM を受け流し、orphan の子は stdout を閉じて (pipe を握らずに)
  # gh が終わった後も残る。子が動き始めてから呼び出しを記録し、止める側の signal より先に子の trap が効くようにする。
  if %w[family orphan].include?(step)
    require "rbconfig"
    ready = File.join(d, "child.ready")
    code = 'trap("TERM") {} if ARGV[2] == "family"; File.write(ARGV[0], "r"); sleep 8; File.write(ARGV[1], "x")'
    child = Process.spawn(RbConfig.ruby, "-e", code, ready, File.join(d, "child-natural-end"), step,
                          out: step == "orphan" ? File::NULL : $stdout)
    File.write(File.join(d, "child.pid"), child.to_s)
    t0 = Time.now
    sleep 0.01 until File.exist?(ready) || Time.now - t0 > 5
  end
  out = File.join(d, "out")
  File.open(log, "a") do |f|
    f.puts JSON.generate("argv" => ARGV, "pid" => Process.pid, "time" => Process.clock_gettime(Process::CLOCK_MONOTONIC),
                         "stdout" => File.exist?(out) ? File.binread(out).force_encoding(Encoding::UTF_8) : nil)
  end
  case step
  when "fail" then warn "GH-STDERR-CANARY"; exit 1
  when "json" then puts "{"; exit 0
  when "shape" then puts "{}"; exit 0
  when "nomerge" then puts JSON.generate("state" => "MERGED", "headRefOid" => "#{H}", "mergeCommit" => nil); exit 0
  when "badsha" then puts JSON.generate("state" => "OPEN", "headRefOid" => "#{H}".upcase, "mergeCommit" => nil); exit 0
  when "hang", "stubborn", "family"
    sleep 8
    File.write(File.join(d, "natural-end"), "x")
    exit 1
  when "closeout"
    # stdout を閉じても終わらない gh ($stdout.close は fd 1 を閉じないので reopen で閉じる)。
    $stdout.reopen(File::NULL)
    sleep 8
    File.write(File.join(d, "natural-end"), "x")
    exit 1
  end
  state = { "open" => "OPEN", "merged" => "MERGED", "other" => "MERGED", "closed" => "CLOSED", "moved" => "OPEN",
            "orphan" => "MERGED" }.fetch(step)
  head = %w[other moved].include?(step) ? "#{B}" : "#{H}"
  puts JSON.generate("state" => state, "headRefOid" => head, "mergeCommit" => state == "MERGED" ? { "oid" => "#{M}" } : nil)
RB
File.chmod(0o755, GH)

$n = 0
# script を起動する。[exit, stdout の行, stderr の行, gh の呼び出しの記録, case の directory] を返す。
# signals は、gh の最初の呼び出しの後に script へ送る signal の並び (0.5 秒おき)。delay は、最初の signal を送る前に
# 足す待ち。返す値の最後の要素は、最初の signal を送ってから script が終わるまでの秒数 (signal が無ければ nil)。
def run_case(steps, args, path: nil, env: {}, signals: [], delay: 0)
  $n += 1
  d = File.join(ENV.fetch("T675_TMP"), "case#{$n}")
  FileUtils.mkdir_p(d)
  out = File.join(d, "out")
  err = File.join(d, "err")
  log = File.join(d, "calls.jsonl")
  full = { "T675_CASE" => d, "T675_STEPS" => steps, "PATH" => path || "#{File.dirname(GH)}:#{ENV.fetch('PATH')}" }.merge(env)
  pid = Process.spawn(full, RbConfig.ruby, SRC, *args, out: out, err: err)
  signaled = nil
  unless signals.empty?
    t0 = Time.now
    sleep 0.02 until (File.exist?(log) && File.size(log) > 0) || Time.now - t0 > 5
    sleep delay
    signaled = Time.now
    signals.each_with_index do |sig, i|
      sleep 0.5 if i.positive?
      Process.kill(sig, pid)
    end
  end
  _pid, status = Process.wait2(pid)
  took = signaled && Time.now - signaled
  calls = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  [status.exitstatus, File.readlines(out, chomp: true), File.readlines(err, chomp: true), calls, d, took]
end

def alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

SRC = src
ENV["T675_TMP"] = tmp
base = ["675", "--expect-head", H, "--repo", "fixture/repo", "--interval", "1", "--timeout", "8"]
waiting = "merge-wait: waiting (PR #675、上限 8 秒)"

# ---- 終わり方ごとの exit と出力
s, out, err, calls, = run_case("merged", base)
check "merged with the expected head: exit 0", s == 0
check "merged: stdout is waiting, merge-commit, head, result", out == [waiting, "merge-commit: #{M}", "head: #{H}", "merge-wait: merged"]
check "merged: stderr is empty", err.empty?
check "merged: one gh call", calls.size == 1
check "gh is asked only for state, head and merge commit", calls[0]["argv"] == ["pr", "view", "675", "--repo", "fixture/repo", "--json", "state,headRefOid,mergeCommit"]
check "the waiting line is out before the first gh call", calls[0]["stdout"] == "#{waiting}\n"
{ "other" => [1, "MERGED", B, "merged-other-head"], "closed" => [1, "CLOSED", H, "closed"], "moved" => [1, "OPEN", B, "head-moved"] }.each do |step, (code, state, head, word)|
  s, out, err, calls, = run_case(step, base)
  check "#{word}: exit #{code} with state and head", s == code && out == [waiting, "state: #{state}", "head: #{head}", "merge-wait: #{word}"] && err.empty? && calls.size == 1
end
s, out, _err, calls, = run_case("merged", ["675", "--expect-head", H])
check "without --repo, gh resolves the repo (no --repo in argv)", s == 0 && calls[0]["argv"] == ["pr", "view", "675", "--json", "state,headRefOid,mergeCommit"]
check "the default timeout is 7200 seconds", out[0] == "merge-wait: waiting (PR #675、上限 7200 秒)"

# ---- 間隔と上限
s, out, _err, calls, = run_case("open,open,merged", base)
gaps = calls.each_cons(2).map { |a, b| b["time"] - a["time"] }
check "open, open, merged: exit 0 after 3 checks", s == 0 && calls.size == 3 && out.last == "merge-wait: merged"
check "checks are an interval apart", gaps.all? { |g| (0.8..1.8).cover?(g) }
check "nothing is printed while waiting", calls.all? { |c| c["stdout"] == "#{waiting}\n" }
s, out, err, calls, = run_case("open", base[0..-3] + ["--timeout", "2"])
check "timeout: exit 3 with state and head", s == 3 && out.drop(1) == ["state: OPEN", "head: #{H}", "merge-wait: timeout"] && err.empty?
check "timeout: checks at start, after 1 second and at the deadline", calls.size == 3 && (1.7..2.8).cover?(calls[-1]["time"] - calls[0]["time"])
s, out, _err, calls, = run_case("open,merged", ["675", "--expect-head", H, "--interval", "2", "--timeout", "1"])
check "a last check at the deadline when the next interval passes it", s == 0 && calls.size == 2 && (0.8..1.8).cover?(calls[1]["time"] - calls[0]["time"])

# ---- 確認の失敗
s, out, err, calls, = run_case("fail,fail,fail,merged", base)
check "three failed checks in a row: exit 2", s == 2 && calls.size == 3 && out == [waiting] && err.size == 1
check "gh stderr is not passed through", !err.join.include?("GH-STDERR-CANARY")
s, _out, _err, calls, = run_case("json,shape,nomerge,merged", base)
check "broken JSON, a wrong shape and a merge without a merge commit are failures", s == 2 && calls.size == 3
s, _out, _err, calls, = run_case("badsha,fail,fail,merged", base)
check "an upper-case head is a failure", s == 2 && calls.size == 3
s, out, _err, calls, = run_case("fail,fail,open,fail,fail,merged", base)
check "a good check resets the failure count", s == 0 && calls.size == 6 && out.last == "merge-wait: merged"
s, _out, _err, calls, = run_case("fail,fail,open,fail,fail,fail,merged", base)
check "three failures after the reset: exit 2", s == 2 && calls.size == 6
s, out, err, calls, = run_case("open,fail", base[0..-3] + ["--timeout", "1"])
check "a failed check at the deadline: exit 2 (state unknown)", s == 2 && calls.size == 2 && out == ["merge-wait: waiting (PR #675、上限 1 秒)"] && err.size == 1
# gh の無い PATH (Ruby 2.6 は起動に uname を使うので、/usr/bin と /bin は残す)。
s, out, err, calls, = run_case("merged", base, path: "/usr/bin:/bin")
check "no gh on the PATH: three failed checks, exit 2", s == 2 && calls.empty? && out == [waiting] && err.size == 1

# ---- 入力の誤り (gh を呼ばない)
[[], ["675"], ["675", "--expect-head"], ["6x", "--expect-head", H], ["-1", "--expect-head", H], ["675", "676", "--expect-head", H],
 ["675", "--expect-head", "a" * 39], ["675", "--expect-head", "A" * 40], ["675", "--expect-head", H, "--expect-head", H],
 ["675", "--expect-head", H, "--repo", "owner"], ["675", "--expect-head", H, "--repo", "-o/r"], ["675", "--expect-head", H, "--repo", "o/r/x"],
 ["675", "--expect-head", H, "--interval", "0"], ["675", "--expect-head", H, "--interval", "601"], ["675", "--expect-head", H, "--interval", "1.5"],
 ["675", "--expect-head", H, "--timeout", "0"], ["675", "--expect-head", H, "--timeout", "43201"], ["675", "--expect-head", H, "--timeout"],
 ["675", "--expect-head", H, "--unknown", "x"]].each do |args|
  s, out, err, calls, = run_case("merged", args)
  # 長い値は「先頭の文字*長さ」に縮め、どの入力で落ちたかを名前で区別できるようにする。
  label = args.map { |a| a.size > 20 ? "#{a[0]}*#{a.size}" : a }.join(" ")
  check "usage error (#{label}): exit 2, one stderr line, no gh call, no output", s == 2 && err.size == 1 && calls.empty? && out.empty?
end
s, = run_case("merged", ["675", "--expect-head", H, "--interval", "600", "--timeout", "43200"])
check "the largest interval and timeout are accepted", s == 0

# ---- 止められたとき
%w[TERM INT].each do |sig|
  s, out, err, calls, d = run_case("hang", base, signals: [sig])
  sleep 0.3
  check "SIG#{sig}: exit 2 with one stderr line", s == 2 && out == [waiting] && err.size == 1
  check "SIG#{sig}: the running gh is stopped, not left to finish", calls.size == 1 && !alive?(calls[0]["pid"]) && !File.exist?(File.join(d, "natural-end"))
end
# gh が TERM を受け流すので、止めるのに KILL まで 2 秒かかる。その間に 2 回目の signal が届いても、後始末を終えてから
# exit 2 で終わる (backtrace を出して gh を残さない)。
s, out, err, calls, d = run_case("stubborn", base, signals: %w[TERM INT])
check "a second signal during the clean-up: exit 2 with one stderr line", s == 2 && out == [waiting] && err.size == 1
check "a second signal during the clean-up: the gh that ignores TERM is killed", calls.size == 1 && !alive?(calls[0]["pid"]) && !File.exist?(File.join(d, "natural-end"))
# 確かめる間の待ち (間隔 5 秒) の最中に signal が届く。待ちを切り上げてすぐ止め、新しい gh を起動しない。
s, out, err, calls, _d, took = run_case("open", ["675", "--expect-head", H, "--interval", "5", "--timeout", "8"],
                                        signals: ["TERM"], delay: 0.4)
check "a signal while waiting between checks: exit 2 at once", s == 2 && err.size == 1 && took < 2
check "a signal while waiting between checks: no new gh call", calls.size == 1 && out == ["merge-wait: waiting (PR #675、上限 8 秒)"]
# gh は TERM で終わるが、同じ group の子が TERM を受け流す。gh を回収する前に group を KILL し、子も残さない。
s, out, err, calls, d = run_case("family", base, signals: ["TERM"])
child = File.read(File.join(d, "child.pid")).to_i
# 落ちたときの後始末の対象: まだ gh の group (id は gh の PID) にいる子だけ。PID が再利用された別の process は止めない。
left = alive?(child) && (Process.getpgid(child) rescue nil) == calls[0]["pid"]
check "a child in the gh group that ignores TERM: exit 2 with one stderr line", s == 2 && out == [waiting] && err.size == 1
check "a child in the gh group that ignores TERM is killed with the group", !left && !alive?(child) && !alive?(calls[0]["pid"]) && !File.exist?(File.join(d, "child-natural-end"))
Process.kill("KILL", child) if left

# ---- locale が C
s, out, = run_case("merged", base, env: { "LC_ALL" => "C", "LANG" => "C" })
check "C locale: same result", s == 0 && out.last == "merge-wait: merged"

# ---- gh を起動する部分を直接呼ぶ (gh の 1 回の上限の定数を 1 秒に差し替える)
require SRC
PrMergeWait.send(:remove_const, :GH_LIMIT)
PrMergeWait.const_set(:GH_LIMIT, 1)
PrMergeWait.watch_signals
ENV["PATH"] = "#{File.dirname(GH)}:#{ENV.fetch('PATH')}"
VIEW = ["gh", "pr", "view", "675", "--json", "state,headRefOid,mergeCommit"].freeze

def direct_case(name, steps)
  d = File.join(ENV.fetch("T675_TMP"), name)
  FileUtils.mkdir_p(d)
  ENV["T675_CASE"] = d
  ENV["T675_STEPS"] = steps
  d
end

def first_gh_pid(dir)
  JSON.parse(File.readlines(File.join(dir, "calls.jsonl")).first)["pid"]
end

def timed
  t0 = Time.now
  value = yield
  [value, Time.now - t0]
end

# 届いた signal の記録を消し、self-pipe を作り直す (前の case の signal を次の case に持ち込まない)。
def reset_signal
  PrMergeWait.instance_variable_set(:@signal, nil)
  PrMergeWait.watch_signals
end

d = direct_case("limit", "hang")
(out, status), took = timed { PrMergeWait.run_gh(VIEW) }
check "a gh call past the limit is stopped and counts as a failure", out.nil? && status.nil? && took < 4
check "the stopped gh is reaped and gone", !alive?(first_gh_pid(d)) && !File.exist?(File.join(d, "natural-end"))

# stdout を閉じた後も動き続ける gh も、上限で止める (EOF の後も期限を見る)。
d = direct_case("closeout", "closeout")
(out, status), took = timed { PrMergeWait.run_gh(VIEW) }
check "a gh that closes stdout and keeps running is stopped at the limit", out.nil? && status.nil? && took < 4
check "the gh that closed stdout is reaped and gone", !alive?(first_gh_pid(d)) && !File.exist?(File.join(d, "natural-end"))

# gh は正常に終わるが、同じ group に子が残る。group が空になるまで gh を回収せず、上限で group ごと止めて失敗に数える。
d = direct_case("orphan", "orphan")
(out, status), took = timed { PrMergeWait.run_gh(VIEW) }
child = File.read(File.join(d, "child.pid")).to_i
check "a gh that leaves a child in its group is not taken as finished", out.nil? && status.nil? && took < 4
check "the child left in the gh group is stopped", !alive?(child) && !File.exist?(File.join(d, "child-natural-end"))

# 上限を越えた gh (TERM を受け流す) を止めている間に SIGTERM が届く。止める途中では抜けずに KILL して回収し、
# signal は記録に残る (次の確かめる時点で Interrupted になる)。
d = direct_case("limit-signal", "stubborn")
Thread.new do
  sleep 1.5
  Process.kill("TERM", Process.pid)
end
raised = nil
(out, status), took = timed do
  PrMergeWait.run_gh(VIEW)
rescue PrMergeWait::Interrupted => e
  raised = e
  nil
end
check "a signal while stopping a gh past the limit does not break off the stop", raised.nil? && out.nil? && status.nil? && took > 2.5 && took < 6
check "the gh that ignores TERM is killed and reaped", !alive?(first_gh_pid(d)) && !File.exist?(File.join(d, "natural-end"))
begin
  PrMergeWait.check_signal
rescue PrMergeWait::Interrupted => e
  raised = e.message
end
check "the signal kept during the stop is raised at the next check", raised == "TERM"
reset_signal

# gh を起動した直後 (PID を覚える前) に signal が届く。gh を覚えてから止め、残さない。
d = direct_case("spawn-race", "hang")
spawned = nil
tp = TracePoint.new(:c_return) do |t|
  next unless t.method_id == :spawn && t.defined_class == Process.singleton_class

  t.disable
  spawned = t.return_value
  Process.kill("TERM", Process.pid)
end
raised = nil
begin
  tp.enable
  PrMergeWait.run_gh(VIEW)
rescue PrMergeWait::Interrupted => e
  raised = e.message
ensure
  tp.disable
end
# この gh は test の process の子なので、まだ回収されずに動いているか (= 落ちて残ったか) を waitpid で確かめられる。
running = spawned.is_a?(Integer) &&
          begin
            Process.waitpid(spawned, Process::WNOHANG).nil?
          rescue Errno::ECHILD
            false # script が回収済み (自分のものではなくなった PID は止めない)
          end
check "a signal right after spawning gh: Interrupted after the gh is stopped", raised == "TERM" && spawned.is_a?(Integer)
check "a signal right after spawning gh: the gh is not left running", spawned.is_a?(Integer) && !running && !File.exist?(File.join(d, "natural-end"))
if running # 落ちたときだけ、回収されていない自分の子の gh を止めて回収する
  Process.kill("KILL", spawned)
  Process.waitpid(spawned)
end
reset_signal

# gh を回収した直後 (PID を消す前) に signal が届く。run を通して、確かめた結果より signal を優先して exit 2 で終わること
# (結果の行を出さない) と、回収した gh の group には signal を送らないことを確かめる。
direct_case("reap-race", "merged")
sent = []
original = PrMergeWait.method(:signal_group)
PrMergeWait.define_singleton_method(:signal_group) do |*args|
  sent << args
  original.call(*args)
end
tp = TracePoint.new(:c_return) do |t|
  next unless t.method_id == :wait2 && t.defined_class == Process.singleton_class && t.return_value

  t.disable
  Process.kill("TERM", Process.pid)
end
require "stringio"
outs = StringIO.new
errs = StringIO.new
real_out = $stdout
real_err = $stderr
begin
  $stdout = outs
  $stderr = errs
  tp.enable
  code = PrMergeWait.run(["675", "--expect-head", H, "--interval", "1", "--timeout", "8"])
ensure
  tp.disable
  $stdout = real_out
  $stderr = real_err
end
check "a signal right after reaping gh: run exits 2 with one stderr line and no result line", code == 2 && errs.string.lines.size == 1 && outs.string == "merge-wait: waiting (PR #675、上限 8 秒)\n"
check "a signal right after reaping gh: no signal to the reaped gh group", sent.empty?
PrMergeWait.define_singleton_method(:signal_group, original)
reset_signal

# 確かめる間の待ちの最中に signal が届いていたら、次の確認で gh を起動せずに止まる。外からの test では、起動してすぐ
# 止められた gh は呼び出しを記録する前に終わりうるので、起動の回数は TracePoint で数える。
direct_case("no-spawn-after-signal", "open")
spawns = 0
tp = TracePoint.new(:c_call) do |t|
  spawns += 1 if t.method_id == :spawn && t.defined_class == Process.singleton_class
end
PrMergeWait.on_signal("TERM")
raised = nil
begin
  tp.enable
  PrMergeWait.wait(pr: "675", expect: H, repo: nil, interval: 1, timeout: 8)
rescue PrMergeWait::Interrupted => e
  raised = e.message
ensure
  tp.disable
end
check "a signal received while waiting: stops without starting a new gh", raised == "TERM" && spawns.zero?
reset_signal

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: pr-merge-wait-test"
