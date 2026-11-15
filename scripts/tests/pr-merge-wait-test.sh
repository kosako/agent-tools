#!/bin/sh
# personal-pr-merge-wait.rb の self-test (#675)。
# 本物の gh には触れない。PATH の先頭に置いた偽の gh が、呼ばれた回数で決めた応答を返し、受け取った argv・pid・時刻と、
# 呼ばれた時点の script の stdout を記録する。終わり方ごとの exit と出力の行、確認の間隔と上限の時刻の最後の確認、失敗の
# 数え方、入力の誤り、gh に求める field、止められたときに gh を残さないこと (後始末の間に届く 2 回目の signal を含む) を
# 確かめる。gh の 1 回の上限 (60 秒) は、上限の定数を差し替えて、gh を起動する部分を直接呼んで確かめる (止めている間に
# 届く signal も)。locale が C でも同じ結果になることも見る。
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
  when "hang", "stubborn"
    sleep 8
    File.write(File.join(d, "natural-end"), "x")
    exit 1
  end
  state = { "open" => "OPEN", "merged" => "MERGED", "other" => "MERGED", "closed" => "CLOSED", "moved" => "OPEN" }.fetch(step)
  head = %w[other moved].include?(step) ? "#{B}" : "#{H}"
  puts JSON.generate("state" => state, "headRefOid" => head, "mergeCommit" => state == "MERGED" ? { "oid" => "#{M}" } : nil)
RB
File.chmod(0o755, GH)

$n = 0
# script を起動する。[exit, stdout の行, stderr の行, gh の呼び出しの記録, case の directory] を返す。
# signals は、gh の最初の呼び出しの後に script へ送る signal の並び (0.5 秒おき)。
def run_case(steps, args, path: nil, env: {}, signals: [])
  $n += 1
  d = File.join(ENV.fetch("T675_TMP"), "case#{$n}")
  FileUtils.mkdir_p(d)
  out = File.join(d, "out")
  err = File.join(d, "err")
  log = File.join(d, "calls.jsonl")
  full = { "T675_CASE" => d, "T675_STEPS" => steps, "PATH" => path || "#{File.dirname(GH)}:#{ENV.fetch('PATH')}" }.merge(env)
  pid = Process.spawn(full, RbConfig.ruby, SRC, *args, out: out, err: err)
  unless signals.empty?
    t0 = Time.now
    sleep 0.02 until (File.exist?(log) && File.size(log) > 0) || Time.now - t0 > 5
    signals.each_with_index do |sig, i|
      sleep 0.5 if i.positive?
      Process.kill(sig, pid)
    end
  end
  _pid, status = Process.wait2(pid)
  calls = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  [status.exitstatus, File.readlines(out, chomp: true), File.readlines(err, chomp: true), calls, d]
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

# ---- locale が C
s, out, = run_case("merged", base, env: { "LC_ALL" => "C", "LANG" => "C" })
check "C locale: same result", s == 0 && out.last == "merge-wait: merged"

# ---- gh の 1 回の上限 (定数を差し替えて、gh を起動する部分を直接呼ぶ)
require SRC
PrMergeWait.send(:remove_const, :GH_LIMIT)
PrMergeWait.const_set(:GH_LIMIT, 1)
d = File.join(tmp, "limit")
FileUtils.mkdir_p(d)
ENV["T675_CASE"] = d
ENV["T675_STEPS"] = "hang"
ENV["PATH"] = "#{File.dirname(GH)}:#{ENV.fetch('PATH')}"
t0 = Time.now
out, status = PrMergeWait.run_gh(["gh", "pr", "view", "675", "--json", "state,headRefOid,mergeCommit"])
took = Time.now - t0
gh_pid = JSON.parse(File.readlines(File.join(d, "calls.jsonl")).first)["pid"]
check "a gh call past the limit is stopped and counts as a failure", out.nil? && status.nil? && took < 4
check "the stopped gh is reaped and gone", !alive?(gh_pid) && !File.exist?(File.join(d, "natural-end"))

# 上限を越えた gh (TERM を受け流す) を止めている間に SIGTERM が届く。止める途中では抜けず、KILL して回収してから
# Interrupted が上がる。
d = File.join(tmp, "limit-signal")
FileUtils.mkdir_p(d)
ENV["T675_CASE"] = d
ENV["T675_STEPS"] = "stubborn"
trap("TERM") { PrMergeWait.on_signal("TERM") }
Thread.new do
  sleep 1.5
  Process.kill("TERM", Process.pid)
end
raised = nil
t0 = Time.now
begin
  PrMergeWait.run_gh(["gh", "pr", "view", "675", "--json", "state,headRefOid,mergeCommit"])
rescue PrMergeWait::Interrupted => e
  raised = e.message
end
took = Time.now - t0
trap("TERM", "DEFAULT")
gh_pid = JSON.parse(File.readlines(File.join(d, "calls.jsonl")).first)["pid"]
check "a signal while stopping a gh past the limit is raised after the stop", raised == "TERM" && took > 2.5 && took < 6
check "the gh is reaped before the signal is raised", !alive?(gh_pid) && !File.exist?(File.join(d, "natural-end"))

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: pr-merge-wait-test"
