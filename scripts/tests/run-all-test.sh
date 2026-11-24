#!/bin/sh
# scripts/tests/lib/run-all.rb (test を並べて走らせる runner。#726) の self-test。
# - T1: 引数と、走らせる test の拾い方 (直下の *.sh の file だけ、名前の順)。
# - T2: 終わり方 (成功、失敗、signal、起動できない) の 2 本の組の全部と、並べる数の全部で、exit code と出力の規則。
#   1 本が失敗しても残りを走らせること、走らせた数を数えることも、この組で見る。
# - T3: 同時に走ること、並べても出力が混ざらないこと、stdin が空なこと。
# - T4: 単独で走らせる test の表 (ほかが終わった後に 1 本ずつ、無い名前は exit 2、--dir では使わない)。
# - T5: INT と TERM で、走っている test の子まで止まること。
# - T6: workflow が runner を呼び、job の名前と必要な check の一覧が合うこと。
# 題材の test は、この test の一時 dir の中に作る。repo の test は走らせない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

runner="$script_dir/lib/run-all.rb"
[ -f "$runner" ] || fail "missing $runner"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 題材の test を作る: mk <dir> <name> <本文>
mk() {
  printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}
# runner を走らせ、exit code を確かめる。出力は out と err に残す。
run() {
  run_want=$1
  shift
  run_got=0
  ruby "$runner" "$@" > "$tmp/out" 2> "$tmp/err" || run_got=$?
  [ "$run_got" -eq "$run_want" ] || fail "run $*: expected exit $run_want, got $run_got: $(cat "$tmp/out" "$tmp/err")"
}

# --- T1: 引数と、拾い方 -------------------------------------------------------------------------
mkdir "$tmp/pick" "$tmp/pick/lib" "$tmp/pick/dir-test.sh" "$tmp/empty"
mk "$tmp/pick" b-test.sh 'echo b'
mk "$tmp/pick" "a test.sh" 'echo "a with a space"'
mk "$tmp/pick" c-test.txt 'echo not a test'
mk "$tmp/pick/lib" d-test.sh 'echo not reached'
run 0 --dir "$tmp/pick"
[ "$(grep -c '^start: ' "$tmp/out")" -eq 2 ] || fail "pick: expected two tests: $(cat "$tmp/out")"
[ "$(grep '^start: ' "$tmp/out" | head -n 1)" = "start: $tmp/pick/a test.sh" ] || fail "pick: not in name order: $(cat "$tmp/out")"
grep -qx "a with a space" "$tmp/out" && grep -qx "b" "$tmp/out" || fail "pick: missing output: $(cat "$tmp/out")"
grep -q '^total [0-9]* s over 2 tests, wall [0-9]* s, 1 jobs$' "$tmp/out" || fail "pick: missing the summary: $(cat "$tmp/out")"
run 0 --dir "$tmp/pick/"
grep -qx "start: $tmp/pick/b-test.sh" "$tmp/out" || fail "pick: a trailing slash changes the label: $(cat "$tmp/out")"
run 2 --dir "$tmp/empty"
grep -q 'no tests' "$tmp/err" || fail "empty: missing the reason: $(cat "$tmp/err")"
run 2 --dir "$tmp/no-such-dir"
run 2 --dir
for bad in 0 17 -1 1.5 x '' ' 3' 100 3x; do run 2 --dir "$tmp/pick" --jobs "$bad"; done
run 2 --jobs
run 2 --dir "$tmp/pick" extra
run 0 --help
for good in 1 3 16; do run 0 --dir "$tmp/pick" --jobs "$good"; done

# --- T2: 終わり方の組の全部 -----------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$runner" "$tmp" <<'RUBY'
require "stringio"
require ARGV[0]
tmp = ARGV[1]
# 終わり方の名前から、[本文 (nil は起動できない file), FAIL の行の中身 (nil は成功), 出力]。
ENDINGS = {
  "pass" => ["echo hello", nil, "hello\n"],
  "silent" => ["exit 0", nil, ""],
  "nonl" => ["printf tail", nil, "tail\n"],
  "fail1" => ["echo why >&2; exit 1", "exit 1", "why\n"],
  "fail77" => ["exit 77", "exit 77", ""],
  "term" => ["kill -TERM $$", "signal 15", ""],
  "kill" => ["kill -KILL $$", "signal 9", ""],
  "noexec" => [nil, "cannot start", "EACCES\n"],
}.freeze
# 終わり方ごとの file は 1 つだけ作り、組には hard link で置く (macOS は、新しい script の初回の起動に約 0.1 秒かける)。
pool = Dir.mktmpdir("pool-", tmp)
ENDINGS.each do |ending, (body, _failure, _output)|
  File.write(File.join(pool, ending), "#!/bin/sh\n#{body}\n")
  File.chmod(body ? 0o755 : 0o644, File.join(pool, ending))
end
run = lambda do |endings, jobs|
  dir = Dir.mktmpdir("pair-", tmp)
  endings.each_with_index { |ending, i| File.link(File.join(pool, ending), File.join(dir, "#{i}-#{ending}.sh")) }
  out = StringIO.new
  code = RunAll.new(dir: dir, jobs: jobs, label: "L", out: out).run
  [code, out.string]
end
wrong = []
count = 0
ENDINGS.keys.product(ENDINGS.keys).each do |pair|
  [1, 2].each do |jobs|
    count += 1
    code, text = run.call(pair, jobs)
    failures = pair.map { |e| ENDINGS.fetch(e)[1] }
    blocks = pair.each_with_index.map do |ending, i|
      _, failure, output = ENDINGS.fetch(ending)
      "--- L/#{i}-#{ending}.sh\n#{output}" + (failure ? "FAIL: L/#{i}-#{ending}.sh (#{failure})\n" : "")
    end
    ok = code == (failures.compact.empty? ? 0 : 1) && blocks.all? { |b| text.include?(b) } &&
         text.scan(/^start: /).length == 2 && text.scan(/^--- L\//).length == 2 &&
         text.scan(/^FAIL: /).length == failures.compact.length && text.match?(/^total \d+ s over 2 tests, wall \d+ s, #{jobs} jobs$/) &&
         (text[/^failed: (\d+)/, 1] || "0").to_i == failures.compact.length
    wrong << [pair, jobs, code, text] unless ok
  end
end
check "endings: every pair of endings, with 1 and 2 jobs (#{count}): #{wrong.first.inspect}", wrong.empty? && count == ENDINGS.length**2 * 2
# 遅い順の 10 本まで。
code, text = run.call(["silent"] * 12, 4)
slowest = text.split("--- slowest tests (seconds)\n").last.lines.take_while { |l| l.match?(/\A\d+\tL\//) }
check "summary: at most ten slowest tests: #{slowest.length}", code == 0 && slowest.length == 10
# 走らせた数と見つけた数が違えば、失敗にする。
dir = Dir.mktmpdir("lost-", tmp)
%w[a b].each { |n| File.write(File.join(dir, "#{n}-test.sh"), "#!/bin/sh\nexit 0\n"); File.chmod(0o755, File.join(dir, "#{n}-test.sh")) }
out = StringIO.new
lossy = RunAll.new(dir: dir, jobs: 1, label: "L", out: out)
lossy.define_singleton_method(:drain) { |queue, limit| RunAll.instance_method(:drain).bind(self).call(queue.first(1), limit) }
check "summary: a run that loses a test is a failure: #{out.string}", lossy.run == 1 && out.string.include?("FAIL: ran 1 of 2 tests")
exit(@failed.zero? ? 0 : 1)
RUBY

# --- T3: 同時に走る、混ざらない、stdin が空 -------------------------------------------------------------
mkdir "$tmp/par" "$tmp/marks"
# 3 本とも、ほかの 2 本の印を見るまで終わらない。3 本が同時に走れば通り、順に走れば時間切れで落ちる。
for n in a b c; do
  mk "$tmp/par" "$n-test.sh" "echo '$n 1'; : > '$tmp/marks/$n'; i=0
while [ ! -e '$tmp/marks/a' ] || [ ! -e '$tmp/marks/b' ] || [ ! -e '$tmp/marks/c' ]; do
  i=\$((i + 1)); [ \"\$i\" -le \"\${PAR_TRIES:-200}\" ] || exit 9; sleep 0.05
done
for k in 2 3 4; do echo '$n '\$k; sleep 0.05; done"
done
run 0 --dir "$tmp/par" --jobs 3
for n in a b c; do
  grep -A 4 -x -- "--- $tmp/par/$n-test.sh" "$tmp/out" > "$tmp/block" || fail "par: no block for $n: $(cat "$tmp/out")"
  printf -- '--- %s\n%s 1\n%s 2\n%s 3\n%s 4\n' "$tmp/par/$n-test.sh" "$n" "$n" "$n" "$n" | cmp -s - "$tmp/block" \
    || fail "par: the output of $n is mixed with another: $(cat "$tmp/out")"
done
# 対照: 2 本までなら、3 本目の印が出ないので落ちる (同時に走る数の上限が効いている)。
rm -f "$tmp/marks"/*
PAR_TRIES=8 run 1 --dir "$tmp/par" --jobs 2
[ "$(grep -c '^FAIL: .* (exit 9)$' "$tmp/out")" -ge 1 ] || fail "par: the control with two jobs did not time out: $(cat "$tmp/out")"
mkdir "$tmp/stdin"
mk "$tmp/stdin" a-test.sh 'if read x; then echo "got $x"; exit 1; fi; echo "stdin is empty"'
echo "from the caller" | ruby "$runner" --dir "$tmp/stdin" > "$tmp/out" || fail "stdin: $(cat "$tmp/out")"
grep -qx 'stdin is empty' "$tmp/out" || fail "stdin: $(cat "$tmp/out")"

# --- T4: 単独で走らせる test の表 -----------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$runner" "$tmp" "$script_dir" <<'RUBY'
require "stringio"
require ARGV[0]
tmp = ARGV[1]
dir = Dir.mktmpdir("alone-", tmp)
state = File.join(tmp, "alone-state")
Dir.mkdir(state)
# 走っている間だけ印を置き、相手の印を待つ。b と d (並べる test) は、互いの印を見るまで長く待つ (混んでいてもすれ違わない)。
# a と c (単独の test) は、相手の印が出ないことを見るために、短く待つ。並べて走らせれば、相手の印が見える。
%w[a b c d].each do |n|
  path = File.join(dir, "#{n}-test.sh")
  other = { "a" => "c", "b" => "d", "c" => "a", "d" => "b" }.fetch(n)
  tries = %w[b d].include?(n) ? 200 : 16
  wait = ->(mark) { "i=0; until [ -e '#{state}/#{other}.#{mark}' ] || [ $i -ge #{tries} ]; do i=$((i + 1)); sleep 0.05; done\n" }
  # 見終わった印 (met) も待ち合わせる。先に終わった側の run の印が消えて、相手が見逃すのを防ぐ。
  meet = %w[b d].include?(n) ? ": > '#{state}/#{n}.met'\n#{wait.call('met')}" : ""
  File.write(path, "#!/bin/sh\n: > '#{state}/#{n}.run'\n#{wait.call('run')}ls '#{state}' | grep run | grep -v '^#{n}' > '#{state}/#{n}.saw'\n" \
                   "#{meet}rm '#{state}/#{n}.run'\nexit 0\n")
  File.chmod(0o755, path)
end
out = StringIO.new
code = RunAll.new(dir: dir, jobs: 4, label: "L", alone: { "a-test.sh" => "why", "c-test.sh" => "why" }, out: out).run
saw = %w[a b c d].map { |n| [n, File.read(File.join(state, "#{n}.saw")).split] }.to_h
started = out.string.scan(/^start: L\/(\w)/).flatten
check "alone: they run after the others, one at a time, in name order: #{started.inspect} #{saw.inspect}",
      code == 0 && started == %w[b d a c] && saw["a"].empty? && saw["c"].empty? && saw["b"] == ["d.run"] && saw["d"] == ["b.run"]
missing = begin
  RunAll.new(dir: dir, jobs: 1, label: "L", alone: { "gone-test.sh" => "why" }, out: StringIO.new).run
  nil
rescue RunAll::Usage => e
  e.message
end
check "alone: a name that does not exist is a usage error: #{missing.inspect}", missing.to_s.include?("gone-test.sh")
check "alone: every entry of the table is a test of this repository, with a reason: #{RunAll::ALONE.inspect}",
      (RunAll::ALONE.keys - RunAll.names(ARGV[2])).empty? && RunAll::ALONE.values.all? { |why| why.to_s.length >= 10 }
check "alone: --dir does not use the table, and the default dir does", RunAll::TESTS_DIR == File.realpath(ARGV[2])
check "this repository has tests to run: #{RunAll.names(RunAll::TESTS_DIR).length}",
      RunAll.names(RunAll::TESTS_DIR).include?("run-all-test.sh") && RunAll.names(RunAll::TESTS_DIR).length >= 90
exit(@failed.zero? ? 0 : 1)
RUBY

# --- T5: INT と TERM ---------------------------------------------------------------------------------
mkdir "$tmp/hang"
mk "$tmp/hang" a-test.sh "echo 'a started'; sleep 60 & echo \$! > '$tmp/hang.child'; : > '$tmp/hang.ready'; wait"
mk "$tmp/hang" b-test.sh "trap '' TERM; echo \$\$ > '$tmp/hang.stubborn'; while :; do sleep 0.1; done"
mk "$tmp/hang" c-test.sh 'echo never'
for sig in TERM INT; do
  rm -f "$tmp/hang.ready" "$tmp/hang.stubborn" "$tmp/hang.child"
  # sh は、後ろで走らせる command の INT を無視に設定する。runner に届くように、Ruby から起動して送る。
  ruby - "$runner" "$tmp" "$sig" <<'RUBY' || fail "hang: $sig: see above"
runner, tmp, sig = ARGV
out = File.join(tmp, "hang.out")
pid = Process.spawn("ruby", runner, "--dir", File.join(tmp, "hang"), "--jobs", "2", out: [out, "w"], err: %i[child out], pgroup: true)
limit = Time.now + 20
sleep 0.05 until (File.exist?("#{tmp}/hang.ready") && File.size?("#{tmp}/hang.stubborn")) || Time.now > limit
Process.kill(sig, pid)
done = nil
sleep 0.05 until (done = Process.wait2(pid, Process::WNOHANG)) || Time.now > limit
Process.kill("KILL", -pid) unless done
child = File.read("#{tmp}/hang.child").to_i
gone = [child, File.read("#{tmp}/hang.stubborn").to_i].all? do |p|
  begin
    Process.kill(0, p)
    false
  rescue Errno::ESRCH
    true
  end
end
stubborn = File.read("#{tmp}/hang.stubborn").to_i
# runner が止めなかった題材を残さない (test が落ちるときも)。
[child, stubborn].each do |p|
  begin
    Process.kill("KILL", p) if p > 1
  rescue Errno::ESRCH
    nil
  end
end
text = File.read(out)
ok = done && done[1].exitstatus == 1 && gone && text.include?("interrupted; running: #{tmp}/hang/a-test.sh, #{tmp}/hang/b-test.sh") &&
     text.include?("a started") && !text.include?("c-test.sh") && !text.include?("total ")
unless ok
  warn "done=#{done.inspect} gone=#{gone} text=#{text}"
  exit 1
end
RUBY
done
pgrep -f "$tmp/hang" >/dev/null 2>&1 && fail "hang: a process of the fixture is still running"

# INT と TERM が届く位置の全部。位置は、k 本目を始めた直後と、終わりを数えた直後 (最後の 1 本を含む)。
# どこで届いても exit 1 で、集計を出さず、届いた後に新しい test を始めない。
ruby -r"$script_dir/lib/check_helper" - "$runner" "$tmp" <<'RUBY'
require "stringio"
require ARGV[0]
tmp = ARGV[1]
pool = File.join(tmp, "quick.sh")
File.write(pool, "#!/bin/sh\nexit 0\n")
File.chmod(0o755, pool)
dir = Dir.mktmpdir("sig-", tmp)
3.times { |i| File.link(pool, File.join(dir, "#{i}-test.sh")) }
alone = { "2-test.sh" => "why" }
wrong = []
cases = %i[start finish].product([1, 2, 3], %w[INT TERM], [1, 2, 3], [{}, alone])
cases.each do |point, nth, sig, jobs, table|
  out = StringIO.new
  runner = RunAll.new(dir: dir, jobs: jobs, label: "L", alone: table, out: out)
  calls = 0
  at = nil
  runner.define_singleton_method(point) do |*args|
    super(*args)
    calls += 1
    next unless calls == nth

    at = out.string.scan(/^start: /).length
    Process.kill(sig, Process.pid)
    sleep 0.02
  end
  code = runner.run
  text = out.string
  ok = code == 1 && !text.include?("total ") && text.include?("interrupted; running:") && text.scan(/^start: /).length == at
  wrong << [point, nth, sig, jobs, table.keys, code, text] unless ok
end
check "signals: at every point, INT and TERM end as exit 1, without starting another test (#{cases.length}): #{wrong.first.inspect}",
      wrong.empty? && cases.length == 72
# 対照: 届かなければ、同じ dir は exit 0 で、集計を出す。
out = StringIO.new
check "signals: the same tests pass without a signal", RunAll.new(dir: dir, jobs: 2, label: "L", out: out).run == 0 && out.string.include?("over 3 tests")
exit(@failed.zero? ? 0 : 1)
RUBY

# --- T6: workflow ------------------------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" -ryaml -rjson - "$repo_root/.github/workflows/test.yml" "$repo_root/.github/repo-baseline.json" <<'RUBY'
text = File.read(ARGV[0], encoding: "UTF-8")
job = YAML.load(text).fetch("jobs").fetch("self-tests")
step = job.fetch("steps").find { |s| s["name"] == "Run self-tests" }
required = JSON.parse(File.read(ARGV[1])).fetch("required_checks")
names = job.fetch("strategy").fetch("matrix").fetch("ruby").map { |r| "self-tests (#{r})" }
check "workflow: the job names are the required checks: #{names.inspect}", names.sort == required.sort && !job.key?("name")
script = step.fetch("run").lines.reject { |l| l.strip.start_with?("#") }
calls = script.select { |l| l.include?("run-all.rb") }
check "workflow: the step calls the runner once, as its last command: #{calls.inspect}",
      calls.length == 1 && script.last.strip == "ruby scripts/tests/lib/run-all.rb --jobs 3"
check "workflow: nothing hides a failure of the step", !step.key?("continue-on-error") && !job.key?("continue-on-error") && !step.key?("if")
check "workflow: no other loop runs the tests", text.lines.reject { |l| l.strip.start_with?("#") }.none? { |l| l.include?("scripts/tests/*.sh") }
exit(@failed.zero? ? 0 : 1)
RUBY

echo "run-all-test: ok"
