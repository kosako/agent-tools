#!/bin/sh
# scripts/lib/skill_behavior_fix_check.rb の self-test (#763)。
# - F1: 子の終わり方と出力から status と reason を決める (何も起動しない)。run の前の確かめの条件。
# - F2: いろいろな修正の code を検査する (正しい・見えている入力だけ・整数の割り算・構文の誤り・途中の終了・無限の loop など)。
# - F3: 読む code の外への作用 (書き込み・network・起動・fork・signal・HOME の読み取り・環境の読み取り) が起きない。隔離なしでは
#   起きることを、同じ code で先に確かめる (対照)。
# - F4: 偽の codex で probe を回し、結果の欄・raw log・識別子・run の前の確かめを見る。
# sandbox を適用できない環境 (入れ子の sandbox の中など) では F2・F3・F4 を skip して 1 行出す。CI (GITHUB_ACTIONS=true) では
# skip せず失敗にする。実 codex / network / 実 ~/.codex には触れない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

lib="$repo_root/scripts/lib/skill_behavior_fix_check.rb"
probe="$repo_root/scripts/lib/probe_skill_behavior.rb"
cases_json="$repo_root/scripts/lib/skill_behavior_cases.json"
fixtures="$repo_root/scripts/lib/skill_behavior_fixtures"
for f in "$lib" "$probe" "$cases_json" "$fixtures/median/lib/median.rb"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
tmp=$(CDPATH= cd -- "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

# ---- F1 ------------------------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$lib" <<'RUBY'
load ARGV[0]
F = SkillBehaviorFixCheck
Status = Struct.new(:success, :signal) do
  def success?
    success
  end

  def signaled?
    !signal.nil?
  end
end
OK = Status.new(true, nil)
NG = Status.new(false, nil)
KILLED = Status.new(false, 9)
SPEC = { "examples" => [{ "args" => [1], "returns" => 1 }, { "args" => [2], "returns" => 2.5 }] }.freeze
decide = lambda do |out, status: OK, err: "", completed: true, truncated: false|
  F.decide(ProbeChild::Result.new(out: out, err: err, status: status, completed: completed, drained: true, truncated: truncated), SPEC)
end
[
  ["全部が合う", decide.call("ready\n[1,2.5]\n"), ["passed", "ok", 2]],
  ["整数と小数は値で比べる", decide.call("ready\n[1.0,2.5]\n"), ["passed", "ok", 2]],
  ["1 つ合わない", decide.call("ready\n[1,2]\n"), ["failed", "wrong", 1]],
  ["例外と、数でない値は null で届く", decide.call("ready\n[null,2.5]\n"), ["failed", "wrong", 1]],
  ["true は 1 ではない", decide.call("ready\n[true,2.5]\n"), ["failed", "wrong", 1]],
  ["文字列は数ではない", decide.call("ready\n[\"1\",2.5]\n"), ["failed", "wrong", 1]],
  ["読み込みの失敗", decide.call("ready\nload-error\n"), ["failed", "load-error", 0]],
  ["結果の行が無い", decide.call("ready\n"), ["failed", "no-result", 0]],
  ["結果の行が無く、0 でない終了", decide.call("ready\n", status: NG), ["failed", "no-result", 0]],
  ["結果の行の余り", decide.call("ready\n[1,2.5]\nx\n"), ["failed", "no-result", 0]],
  ["結果の行の後の空の行", decide.call("ready\n[1,2.5]\n\n\n"), ["failed", "no-result", 0]],
  ["結果の行が途中で切れている", decide.call("ready\n[1,2.5]"), ["failed", "no-result", 0]],
  ["上限を越えた出力", decide.call("ready\n[1,2.5]\n", truncated: true), ["failed", "no-result", 0]],
  ["上限を越えた出力 (読み込みの失敗の印があっても)", decide.call("ready\nload-error\n", truncated: true), ["failed", "no-result", 0]],
  ["上限を越えて signal で終わった (3.x では、口を閉じた後の書き込みが SIGPIPE になる)", decide.call("ready\n[1,2.5]\n", truncated: true, status: KILLED),
   ["failed", "no-result", 0]],
  ["上限を越えて、終わりを確かめられない", decide.call("ready\n", truncated: true, status: nil), ["failed", "no-result", 0]],
  ["上限を越えて期限を過ぎた", decide.call("ready\n", truncated: true, completed: false, status: KILLED), ["unmeasured", "timeout", nil]],
  ["始まる前に上限を越えた", decide.call("x", truncated: true, status: KILLED), ["unmeasured", "launch", nil]],
  ["印の行が途中で切れている", decide.call("ready"), ["unmeasured", "launch", nil]],
  ["例の数と違う", decide.call("ready\n[1]\n"), ["failed", "no-result", 0]],
  ["配列でない", decide.call("ready\n{}\n"), ["failed", "no-result", 0]],
  ["例の数と同じ数の key の object", decide.call("ready\n{\"a\":1,\"b\":2.5}\n"), ["failed", "no-result", 0]],
  ["例の数と同じ長さの文字列", decide.call("ready\n\"ab\"\n"), ["failed", "no-result", 0]],
  ["数だけ", decide.call("ready\n5\n"), ["failed", "no-result", 0]],
  ["JSON でない", decide.call("ready\n[1,\n"), ["failed", "no-result", 0]],
  ["UTF-8 でない行", decide.call("ready\n\xFF\n".b), ["failed", "no-result", 0]],
  ["期限を過ぎた (結果の行があっても)", decide.call("ready\n[1,2.5]\n", completed: false, status: KILLED), ["unmeasured", "timeout", nil]],
  ["始まる前に期限を過ぎた", decide.call("", completed: false, status: KILLED), ["unmeasured", "timeout", nil]],
  ["signal で終わった", decide.call("ready\n", status: KILLED), ["unmeasured", "signal", nil]],
  ["結果を出した後に signal で終わった", decide.call("ready\n[1,2.5]\n", status: KILLED), ["unmeasured", "signal", nil]],
  ["終わりを確かめられない", decide.call("ready\n[1,2.5]\n", status: nil), ["unmeasured", "signal", nil]],
  ["driver が始まらない", decide.call("", status: NG, err: "ruby: No such file\n"), ["unmeasured", "launch", nil]],
  ["driver が始まらず 0 で終わる", decide.call(""), ["unmeasured", "launch", nil]],
  ["ready の前の余り", decide.call("x\nready\n[1,2.5]\n"), ["unmeasured", "launch", nil]],
  ["sandbox を適用できない", decide.call("", status: NG, err: "sandbox-exec: sandbox_apply: Operation not permitted\n"), ["unmeasured", "sandbox", nil]],
  ["始まった後の同じ字面は sandbox の失敗ではない", decide.call("ready\n", status: NG, err: "sandbox-exec: x\n"), ["failed", "no-result", 0]],
].each { |name, got, want| check("decide: #{name} (#{got.inspect})", got == want) }
got = SkillBehaviorCases::FIX_STATUSES.flat_map { |s, rs| rs.map { |r| [s, r] } }.map do |s, r|
  passed = { "ok" => 2, "wrong" => 1 }.fetch(r) { s == "failed" ? 0 : nil }
  [s, r, F.detects_untouched?(F::Outcome.new(status: s, reason: r, passed: passed, total: 2, raw: ""))]
end
check("run の前の確かめを通るのは failed/wrong だけ #{got.inspect}", got.select { |x| x[2] } == [["failed", "wrong", true]])
check("合う例が 1 つも無ければ、run の前の確かめを通らない",
      !F.detects_untouched?(F::Outcome.new(status: "failed", reason: "wrong", passed: 0, total: 2, raw: "")))
outcome = F.run(Dir.pwd, SPEC.merge("file" => "x.rb", "function" => "f"), sandbox: "/nonexistent/sandbox-exec")
check("sandbox-exec が無ければ、走らせずに unmeasured (#{outcome.label})", [outcome.status, outcome.reason, outcome.passed] == ["unmeasured", "sandbox", nil])
check("測れない run の欄は、数が null (#{outcome.to_h_for_results.inspect})",
      outcome.to_h_for_results == { "status" => "unmeasured", "reason" => "sandbox", "passed" => nil, "total" => 2 })
check("関数の名前の形でなければ、走らせずに unmeasured",
      F.run(Dir.pwd, SPEC.merge("file" => "x.rb", "function" => "exit!(0);f")).label == "unmeasured/sandbox")
# 子から回収する量の上限。渡さなければ、今までどおり全部を残す
child = ->(code, **opts) { ProbeChild.run([RbConfig.ruby, "--disable=gems", "-e", code], env: {}, chdir: Dir.pwd, timeout: 20, **opts) }
%w[STDOUT STDERR].each do |name|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = child.call("loop { #{name}.syswrite('x' * 65_536) }", max_bytes: 100_000)
  took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  got = name == "STDOUT" ? r.out : r.err
  check("#{name} に書き続ける子は、上限で切って止まる (#{got.bytesize} byte, #{took.round(1)} 秒)",
        got.bytesize == 100_000 && r.truncated == true && r.completed && r.drained == false && took < 10)
end
r = child.call("STDOUT.write('あ' * 3); STDERR.write('い')", max_bytes: 9)
check("上限ちょうどの出力は、切らずに残す (#{r.out.inspect} #{r.truncated})", r.out == "あああ" && r.err == "い" && r.truncated == false && r.drained)
r = child.call("STDOUT.write('x' * 10)", max_bytes: 9)
check("上限を 1 byte 越えたら切れた印を立て、読み切ったとはしない (#{r.drained})", r.out == "x" * 9 && r.truncated == true && r.drained == false)
r = child.call("STDOUT.syswrite('x' * #{ProbeChild::READ_CHUNK}); sleep 0.5; STDOUT.syswrite('y') rescue nil", max_bytes: ProbeChild::READ_CHUNK)
check("ちょうど上限まで読んだ後に続きが来ても、切れた印を立てる", r.out == "x" * ProbeChild::READ_CHUNK && r.truncated == true && r.drained == false)
r = child.call("STDOUT.write('あ' * 100_000)")
check("上限を渡さなければ全部を残す", r.out == "あ" * 100_000 && r.truncated == false && r.drained)
check("label は数を、測れたときだけ出す", outcome.label == "unmeasured/sandbox" &&
      F::Outcome.new(status: "failed", reason: "wrong", passed: 1, total: 2, raw: "").label == "failed/wrong (1/2)")
exit(@failed.zero? ? 0 : 1)
RUBY

if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  [ "${GITHUB_ACTIONS:-}" != true ] || fail "sandbox-exec cannot be applied on CI"
  echo "skip: sandbox-exec を適用できないので F2・F3・F4 を省く"
  echo "skill-behavior-fix-check-test: ok (F1 だけ)"
  exit 0
fi

# ---- F2・F3 --------------------------------------------------------------------------------
FIX_CHECK_CANARY=canary ruby -r"$script_dir/lib/check_helper" -rfileutils -rsocket -ropen3 - "$lib" "$cases_json" "$fixtures" "$tmp" <<'RUBY'
load ARGV[0]
F = SkillBehaviorFixCheck
CASES, FIXTURES, TMP = ARGV[1..3]
SPEC = SkillBehaviorCases.parse(File.read(CASES), fixtures_root: FIXTURES).find { |c| c["id"] == "investigate-fix" }["fix_check"]
TOTAL = SPEC["examples"].length
GOOD = "  s = v.sort\n  m = s.length / 2\n  s.length.odd? ? s[m] : (s[m - 1] + s[m]) / 2.0\n"

RIGHT = "s = v.sort; m = s.length / 2; s.length.odd? ? s[m] : (s[m - 1] + s[m]) / 2.0"

def project(code, root: TMP)
  @n = (@n || 0) + 1
  dir = File.join(root, "p#{@n}")
  FileUtils.mkdir_p(File.join(dir, "lib"))
  File.binwrite(File.join(dir, "lib", "median.rb"), code)
  dir
end

def outcome(code, timeout: F::TIMEOUT)
  F.run(project(code), SPEC, timeout: timeout)
end

# 見えている test の入力は、検査の例に 2 つだけ入っている
visible = [[[3, 1, 2]], [[4, 1, 3, 2]]]
check("検査の例は、見えている test に無い入力を持つ", (SPEC["examples"].map { |e| e["args"] } - visible).length == TOTAL - 2 && TOTAL == 15)
pristine = F.run(File.join(FIXTURES, "median"), SPEC)
check("手を付けていない fixture は合わない (#{pristine.label})", F.detects_untouched?(pristine))
{
  "正しい" => ["def median(v)\n#{GOOD}end\n", "passed/ok (15/15)"],
  "戻り値が Rational" => ["def median(v)\n  s = v.sort\n  m = s.length / 2\n  s.length.odd? ? s[m] : Rational(s[m - 1] + s[m], 2)\nend\n", "passed/ok (15/15)"],
  "file の中で出力する" => ["STDOUT.sync = true\nputs 'ready'\nwarn 'x'\nSTDOUT.syswrite(\"[1]\n\")\ndef median(v)\n  STDOUT.syswrite('x')\n#{GOOD}end\n", "passed/ok (15/15)"],
  "at_exit で終了 code を変える" => ["at_exit { exit!(3) }\ndef median(v)\n#{GOOD}end\n", "passed/ok (15/15)"],
  "終わるときに回り続ける" => ["at_exit { loop {} }\ndef median(v)\n#{GOOD}end\n", "passed/ok (15/15)"],
  "別の file を読む" => ["require_relative 'median'\ndef median(v)\n#{GOOD}end\n", "passed/ok (15/15)"],
  "整数の割り算" => ["def median(v)\n  s = v.sort\n  m = s.length / 2\n  s.length.odd? ? s[m] : (s[m - 1] + s[m]) / 2\nend\n", "failed/wrong (10/15)"],
  "見えている入力だけに合わせる" => ["def median(v)\n  return 2 if v == [3, 1, 2]\n  return 2.5 if v == [4, 1, 3, 2]\n  v.sort[v.length / 2]\nend\n", "failed/wrong (7/15)"],
  "直さない" => ["# 何もしない\ndef median(v)\n  v.sort[v.length / 2]\nend\n", "failed/wrong (6/15)"],
  "いつも例外" => ["def median(v)\n  raise 'x'\nend\n", "failed/wrong (0/15)"],
  "深い再帰" => ["def median(v)\n  median(v)\nend\n", "failed/wrong (0/15)"],
  "数でない値" => ["def median(v)\n  v.sort.to_s\nend\n", "failed/wrong (0/15)"],
  "有限でない値" => ["def median(v)\n  0.0 / 0\nend\n", "failed/wrong (0/15)"],
  "大きすぎる整数" => ["def median(v)\n  1 << 100_000\nend\n", "failed/wrong (0/15)"],
  "関数が無い" => ["# 空\n", "failed/wrong (0/15)"],
  "class の中の関数" => ["class M\n  def median(v)\n#{GOOD}  end\nend\n", "failed/wrong (0/15)"],
  "== を書き換える" => ["class Integer\n  def ==(_other)\n    true\n  end\nend\ndef median(v)\n  v.sort[v.length / 2]\nend\n", "failed/wrong (6/15)"],
  "JSON を書き換える" => ["require 'json'\ndef JSON.generate(*)\n  '[2,2.5,5,5,6,1.5,1.5,5,3.5,27,-2.5,0,1,2.0]'\nend\ndef median(v)\n  0\nend\n", "failed/wrong (1/15)"],
  "関数を呼ぶ method を書き換える" => ["def median(v)\n  v.sort[v.length / 2]\nend\n%w[send __send__ public_send method_missing].each do |n|\n  Object.class_eval(\"def \#{n}(_n, v)\\n  #{RIGHT}\\nend\")\nend\n", "failed/wrong (6/15)"],
  "書き出しと ARGV から正しい値を作る" => ["def median(v)\n  v.sort[v.length / 2]\nend\nrequire 'json'\nCALLS = (JSON.parse(ARGV[0])['calls'] rescue [])\ndef JSON.generate(_x)\n  '[' + CALLS.map { |(v)| #{RIGHT} }.join(',') + ']'\nend\n", "failed/wrong (6/15)"],
  "構文の誤り" => ["def median(v)\n  (\n", "failed/load-error (0/15)"],
  "読み込みの途中の例外" => ["raise 'x'\n", "failed/load-error (0/15)"],
  "無い file を読む" => ["require_relative 'nope'\n", "failed/load-error (0/15)"],
  "読み込みの途中の exit" => ["exit 0\n", "failed/no-result (0/15)"],
  "読み込みの途中の exit!" => ["exit!(0)\n", "failed/no-result (0/15)"],
  "読み込みの途中の abort" => ["abort 'x'\n", "failed/no-result (0/15)"],
  "関数の中の exit" => ["def median(v)\n  exit\nend\n", "failed/no-result (0/15)"],
  "関数の中の exit!" => ["def median(v)\n  exit!(0)\nend\n", "failed/no-result (0/15)"],
  "結果の口に余りを書く" => ["(3..20).each { |n| IO.for_fd(n, 'w', autoclose: false).syswrite(\"x\\n\") rescue nil }\ndef median(v)\n#{GOOD}end\n", "failed/no-result (0/15)"],
  "自分に KILL" => ["Process.kill(:KILL, Process.pid)\nsleep 5\n", "unmeasured/signal"],
}.each do |name, (code, want)|
  got = outcome(code)
  check("#{name}: #{want} (#{got.label})", got.label == want)
end
{ "関数の中の無限の loop" => "def median(v)\n  loop {}\nend\n", "読み込みの途中の無限の loop" => "loop {}\n",
  "止まる signal を拾って続ける" => "trap(:TERM) {}\ndef median(v)\n  loop {}\nend\n" }.each do |name, code|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  got = outcome(code, timeout: 1)
  took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  check("#{name}: 期限で unmeasured (#{got.label}, #{took.round(1)} 秒)", got.label == "unmeasured/timeout" && took < 12)
end
big = outcome("def median(v)\n  1 << 1_000_000\nend\n")
check("大きすぎる整数は、出力に写さない (#{big.raw.bytesize} byte)", big.label == "failed/wrong (0/15)" && big.raw.bytesize < 1000)
flood = outcome("(3..20).each { |n| begin; f = IO.for_fd(n, 'w', autoclose: false); 40.times { f.syswrite('x' * 1_000_000) }; rescue StandardError; end }\ndef median(v)\n#{GOOD}end\n")
check("結果の口に大量に書く code は、上限で切って no-result (#{flood.label}, #{flood.raw.bytesize} byte)",
      flood.label == "failed/no-result (0/15)" && flood.raw.bytesize < 2 * F::MAX_OUTPUT + 1000)
odd = File.join(TMP, 'q"uote')
FileUtils.mkdir_p(File.join(odd, "lib"))
File.write(File.join(odd, "lib", "median.rb"), "def median(v)\n#{GOOD}end\n")
check("profile に書けない path では、走らせずに unmeasured", F.run(odd, SPEC).label == "unmeasured/sandbox")
dir = project("x")
File.delete(File.join(dir, "lib", "median.rb"))
check("file が消えていれば load-error", F.run(dir, SPEC).label == "failed/load-error (0/15)")
FileUtils.rm_rf(dir)
check("project が消えていれば、走らせずに unmeasured", F.run(dir, SPEC).status == "unmeasured")

# ---- F3: 外への作用。code は、できたら $hit を立て、合わない値を返す。隔離なしでは $hit が立つこと (対照) を先に見る。
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
home = File.join(TMP, "home")
FileUtils.mkdir_p(home)
File.write(File.join(home, "secret.txt"), "s")
outside = File.join(TMP, "outside.txt")
pid = Process.pid
attempts = {
  "project への書き込み" => "File.write('made.txt', 'x'); $hit = true",
  "project の file の書き換え" => "File.open('lib/median.rb', 'a') { |f| f.write(\"\\n\") }; $hit = true",
  "project の外への書き込み" => "File.write(#{outside.dump}, 'x'); $hit = true",
  "dir を作る" => "Dir.mkdir('made-dir'); $hit = true",
  "名前を変える" => "File.rename('lib/median.rb', 'lib/moved.rb'); File.rename('lib/moved.rb', 'lib/median.rb'); $hit = true",
  "TCP の接続" => "require 'socket'; TCPSocket.new('127.0.0.1', #{port}).close; $hit = true",
  "TCP の待ち受け" => "require 'socket'; TCPServer.new('127.0.0.1', 0).close; $hit = true",
  "UDP" => "require 'socket'; UDPSocket.new.send('x', 0, '127.0.0.1', 9); $hit = true",
  "system" => "$hit = true if system('/usr/bin/true')",
  "shell" => "$hit = true if system('exit 0;')",
  "backtick" => "$hit = true if `/bin/echo hi` == \"hi\\n\"",
  "spawn" => "Process.wait(spawn('/usr/bin/true')); $hit = true",
  "fork" => "Process.wait(fork { exit!(0) }); $hit = true",
  "親への signal" => "Process.kill(0, Process.ppid); $hit = true",
  "test の process への signal" => "Process.kill(0, #{pid}); $hit = true",
  "HOME の file を読む" => "$hit = true if File.read(#{File.join(home, 'secret.txt').dump}) == 's'",
  "HOME の一覧を読む" => "$hit = true if Dir.children(#{home.dump}).include?('secret.txt')",
  "親の環境を読む" => "$hit = true if ENV['FIX_CHECK_CANARY']",
}
wrap = ->(body) { "$hit = false\nbegin\n  #{body}\nrescue Exception\n  nil\nend\ndef median(v)\n  return -99 if $hit\n#{GOOD}end\n" }
ENV["HOME"] = home
attempts.each do |name, body|
  dir = project(wrap.call(body))
  out, = Open3.capture2e(RbConfig.ruby, "--disable=gems", "-e", "load './lib/median.rb'; print median([1])", chdir: dir, stdin_data: "")
  check("対照: 隔離なしでは起きる: #{name} (#{out.lines.last.to_s[0, 60]})", out.end_with?("-99"))
  FileUtils.rm_rf(outside)
  server.accept_nonblock.close rescue nil
  dir = project(wrap.call(body))
  before = Dir.glob("**/*", base: dir).sort.map { |f| [f, File.file?(File.join(dir, f)) ? File.binread(File.join(dir, f)) : nil] }
  got = F.run(dir, SPEC)
  after = Dir.glob("**/*", base: dir).sort.map { |f| [f, File.file?(File.join(dir, f)) ? File.binread(File.join(dir, f)) : nil] }
  check("隔離の中では起きない: #{name} (#{got.label})", got.label == "passed/ok (15/15)")
  check("project の中身は変わらない: #{name}", before == after && !File.exist?(outside))
  check("待ち受けた口に接続が来ない: #{name}", IO.select([server], nil, nil, 0).nil?)
end
# fork を使わずに、この process を別の program に替える (exec)。替わると結果が出ない
swap = "begin\n  exec('/bin/sh', '-c', 'exit 0')\nrescue SystemCallError\n  nil\nend\ndef median(v)\n#{GOOD}end\n"
dir = project(swap)
out, = Open3.capture2e(RbConfig.ruby, "--disable=gems", "-e", "load './lib/median.rb'; print median([1])", chdir: dir, stdin_data: "")
check("対照: 隔離なしでは別の program に替わる (#{out.inspect})", out.empty?)
got = F.run(dir, SPEC)
check("隔離の中では別の program に替わらない (#{got.label})", got.label == "passed/ok (15/15)")
# project と Ruby の置き場が HOME の下でも、project は読める
dir = project("def median(v)\n#{GOOD}end\n", root: File.join(home, "deep", "er"))
check("HOME の下の project も検査できる", F.run(dir, SPEC).label == "passed/ok (15/15)")
# 期待する値は子に渡さない
seen = []
ProbeChild.singleton_class.class_eval do
  alias_method :real_run, :run
  define_method(:run) { |argv, **opts| seen << argv; real_run(argv, **opts) }
end
dir = project("$hit = !ARGV.empty?\ndef median(v)\n  return -99 if $hit\n#{GOOD}end\n")
got = F.run(dir, SPEC.merge("examples" => [{ "args" => [[1, 2]], "returns" => 1.5 }, { "args" => [[3, 4.5]], "returns" => 3.75 }]))
check("期待する値は子の引数に無く、読む code には引数も見えない (#{got.label})",
      got.label == "passed/ok (2/2)" && seen.length == 1 && seen[0].none? { |a| a.include?("3.75") || a.include?("returns") } &&
      seen[0].last.include?("4.5"))
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- F4 ------------------------------------------------------------------------------------
bin="$tmp/bin"
work="$tmp/cases"
mkdir -p "$bin" "$work" "$tmp/eval" "$tmp/usual" "$tmp/source"
: > "$tmp/eval/auth.json"
cp -R "$fixtures" "$work/skill_behavior_fixtures"
cp "$cases_json" "$work/skill_behavior_cases.json"
for s in personal-investigate personal-production-rail; do
  mkdir -p "$tmp/source/$s"
  printf -- '---\nname: %s\ndescription: d\n---\n' "$s" > "$tmp/source/$s/SKILL.md"
done
cat > "$bin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1 ${2:-}" in
  "--version ") echo "codex-cli 9.9.9"; exit 0 ;;
  "exec --help") printf '%s\n' '  --ignore-user-config' '  --ignore-rules' '  --disable <FEATURE>' '  -s, --sandbox <MODE>'; exit 0 ;;
  "features list") printf '%s\n' 'apps  stable  true' 'computer_use  beta  false' 'browser_use  beta  false'; exit 0 ;;
esac
proj=
prev=
for a in "$@"; do
  [ "$prev" = "-C" ] && proj=$a
  prev=$a
done
cat > /dev/null
cd "$proj" || exit 65
[ -z "${FAKE_FIX:-}" ] || cp "$FAKE_FIX" lib/median.rb
printf '%s\n' '{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"cat lib/median.rb","exit_code":0,"status":"completed"}}' \
  '{"type":"item.completed","item":{"id":"i2","type":"file_change","changes":[{"path":"lib/median.rb","kind":"update"}],"status":"completed"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
EOF
chmod +x "$bin/codex"
good="$tmp/good.rb"
printf 'def median(v)\n  s = v.sort\n  m = s.length / 2\n  s.length.odd? ? s[m] : (s[m - 1] + s[m]) / 2.0\nend\n' > "$good"
bad="$tmp/bad.rb"
printf 'def median(v)\n  File.write("made.txt", "x")\n  v.sort[v.length / 2]\nend\n' > "$bad"
log="$tmp/calls.log"

# run_probe <FAKE_FIX> <args...>
run_probe() {
  fake_fix=$1
  shift
  : > "$log"
  set +e
  out=$(env FAKE_LOG="$log" FAKE_FIX="$fake_fix" CODEX_HOME="$tmp/usual" PATH="$bin:$PATH" \
    ruby "$probe" --tool codex --model m-x --codex-home "$tmp/eval" --source "$tmp/source" "$@" 2>&1)
  rc=$?
  set -e
}
get() {
  ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); puts eval(ARGV[1]).to_json' "$1" "$2"
}

res="$tmp/good.json"
run_probe "$good" --cases "$work/skill_behavior_cases.json" --repeat 2 --out "$res"
[ "$rc" -eq 0 ] || fail "the probe should exit 0 (rc=$rc): $out"
want='{"status":"passed","reason":"ok","passed":15,"total":15}'
[ "$(get "$res" 'd["runs"].select { |r| r["case"] == "investigate-fix" }.map { |r| r["fix_check"] }')" = "[$want,$want]" ] \
  || fail "each positive run should carry the fix check: $(get "$res" 'd["runs"].map { |r| r["fix_check"] }')"
[ "$(get "$res" 'd["runs"].reject { |r| r["case"] == "investigate-fix" }.map { |r| r.key?("fix_check") }.uniq')" = '[false]' ] \
  || fail "the other cases must not carry the fix check"
[ "$(get "$res" 'd["runs"].find { |r| r["case"] == "investigate-fix" }["changed"]')" = '["lib/median.rb"]' ] \
  || fail "the check must not change the diff: $(get "$res" 'd["runs"].map { |r| r["changed"] }')"
[ "$(get "$res" 'd["ids"]["fix_check_ruby"]')" = "$(ruby -rjson -e 'puts RUBY_VERSION.to_json')" ] || fail "ids should record the Ruby of the check"
[ -f "$res.raw/investigate-fix-1.fix-check" ] || fail "the raw log should keep the output of the check"
[ ! -e "$res.raw/investigate-diagnose-only-1.fix-check" ] || fail "a case without the check must not have its raw log"
case "$out" in *'investigate-fix [1/2]: exited reached=true'*'fix=passed/ok (15/15)'*) : ;; *) fail "the progress line should show the check: $out" ;; esac
verdict=$(sh "$repo_root/scripts/check-skill-behavior.sh" --cases "$work/skill_behavior_cases.json" --results "$res" 2>&1) || :
case "$verdict" in *'fixed=2/2 not_fixed=0 fix_unmeasured=0'*) : ;; *) fail "the judge should read the probe's fix check: $verdict" ;; esac

res="$tmp/bad.json"
run_probe "$bad" --cases "$work/skill_behavior_cases.json" --only investigate-fix --out "$res"
[ "$rc" -eq 0 ] || fail "a wrong fix must not change the exit code of the probe (rc=$rc): $out"
[ "$(get "$res" 'd["runs"].map { |r| [r["fix_check"], r["changed"]] }')" = \
  '[[{"status":"failed","reason":"wrong","passed":0,"total":15},["lib/median.rb"]]]' ] \
  || fail "the code under check must not write to the project: $(get "$res" 'd["runs"]')"

# 検査の無い case だけの run は、今までどおり (欄も識別子も無い)
run_probe "$good" --cases "$work/skill_behavior_cases.json" --only investigate-diagnose-only --out "$res"
[ "$rc" -eq 0 ] || fail "a run without the check should exit 0 (rc=$rc): $out"
[ "$(get "$res" '[d["runs"][0].key?("fix_check"), d["ids"].key?("fix_check_ruby")]')" = '[false,false]' ] \
  || fail "a run without the check must not carry its fields"

# run の前の確かめ: 手を付けていない fixture が合う・1 つも合わない・読めない検査では、model を起動しない
# with_check <ruby の式 f (fix_check) を書き換える>
with_check() {
  ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); f = d["cases"].find { |c| c["id"] == "investigate-fix" }["fix_check"]
    eval(ARGV[2]); File.write(ARGV[1], JSON.generate(d))' "$cases_json" "$work/changed_cases.json" "$1"
}
n=0
for change in 'f["examples"].select! { |e| e["args"][0].length.odd? }' 'f["function"] = "nope"' \
  'f["examples"] = [{ "args" => [[1, 2]], "returns" => 1.5 }]'; do
  n=$((n + 1))
  with_check "$change"
  run_probe "$good" --cases "$work/changed_cases.json" --only investigate-fix --out "$tmp/never-$n.json"
  [ "$rc" -eq 2 ] || fail "preflight $n should stop the probe (rc=$rc): $out"
  case "$out" in *'case investigate-fix: fix_check must fail on the untouched fixture'*) : ;; *) fail "preflight $n message: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "preflight $n must stop before the model: $(cat "$log")"; fi
  [ ! -e "$tmp/never-$n.json" ] || fail "preflight $n must not write results"
done
run_probe "$good" --cases "$work/changed_cases.json" --only investigate-fix --dry-run --out "$tmp/never.json"
[ "$rc" -eq 0 ] || fail "--dry-run does not run the check (rc=$rc): $out"
run_probe "$good" --cases "$work/changed_cases.json" --only investigate-diagnose-only --out "$tmp/other.json"
[ "$rc" -eq 0 ] || fail "the preflight looks only at the selected cases (rc=$rc): $out"

# 検査の code を変えれば runner_version が変わる
ruby -r"$script_dir/lib/check_helper" - "$probe" <<'RUBY'
load ARGV[0]
P = ProbeSkillBehavior
seen = []
P.define_singleton_method(:file_digest) { |paths| seen.concat(paths); "sha256:x" }
P.runner_version
check("runner_version は検査の file を含む", seen.map { |f| File.basename(f) }.include?("skill_behavior_fix_check.rb"))
# sandbox を適用できないときも、model を起動する前に止まる
F = SkillBehaviorFixCheck
F.define_singleton_method(:run) { |*_a, **_k| F::Outcome.new(status: "unmeasured", reason: "sandbox", passed: nil, total: 1, raw: "") }
root = File.dirname(ARGV[0])
cases = SkillBehaviorCases.parse(File.read(File.join(root, "skill_behavior_cases.json")))
message = begin
  P.fix_preflight!(cases, "codex", File.join(root, "skill_behavior_fixtures"))
  nil
rescue P::Error => e
  e.message
end
check("sandbox を適用できなければ、run の前に止まる (#{message})", message.to_s.include?("got unmeasured/sandbox"))
exit(@failed.zero? ? 0 : 1)
RUBY

echo "skill-behavior-fix-check-test: ok"
