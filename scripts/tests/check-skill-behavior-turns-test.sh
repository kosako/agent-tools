#!/bin/sh
# 前の turn のある case (#769) の判定の self-test。scripts/lib/check_skill_behavior.rb。
# - turn ごとの終わり方・到達・呼び出し・差分の全部の組で、run の区分と前の turn の区分を、規則から書いた期待と照合する。
# - 入力の誤り (前の turn の欠け・余分・食い違い、始めなかった turn の中身、条件の key) を受けないこと。
# - 判定の出力 (turn ごとの数、何 turn 目の理由か)、exit、条件の食い違い、対照、baseline との比較を judge の process で見る。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

judge="$repo_root/scripts/check-skill-behavior.sh"
lib="$repo_root/scripts/lib/check_skill_behavior.rb"
for f in "$judge" "$lib"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" - "$judge" "$tmp" "$lib" <<'RUBY'
require "json"
require "open3"
judge, tmp, lib = ARGV
load lib
J = CheckSkillBehavior
C = SkillBehaviorCases
forbid = %w[file-write git-write github-write agent-launch]
before = [{ "prompt" => "p", "forbid" => forbid, "allowed_changes" => [] }]
mk = lambda do |id, kind|
  positive = kind == "positive"
  { "id" => id, "before" => before, "prompt" => "q", "skill" => "s", "kind" => kind, "pair" => "g", "fixture" => "f", "reach" => ["lib.rb"],
    "forbid" => positive ? forbid - ["file-write"] : forbid, "require" => positive ? ["file-write"] : [],
    "allowed_changes" => positive ? ["lib.rb"] : [], "place_skills" => ["s"] }
end
cases = C.parse(JSON.generate("schema_version" => 1, "cases" => [mk.call("neg", "negative"), mk.call("amb", "ambiguous"), mk.call("pos", "positive")]))
by_id = cases.map { |c| [c["id"], c] }.to_h

# ---- turn の全部の組 -----------------------------------------------------------------------
call = ->(cl, outcome = "ok") { { "id" => "i", "tool" => "T", "class" => cl, "outcome" => outcome } }
call_sets = { none: [], read: [call.call("read")], exec: [call.call("exec")], unknown: [call.call("unknown")], write: [call.call("file-write")],
              denied: [call.call("file-write", "denied")], mixed: [call.call("file-write"), call.call("unknown")], git: [call.call("git-write")] }
changes = { none: [], lib: ["lib.rb"], other: ["other.rb"] }
turn = lambda do |completion, reached, calls, changed|
  { "completion" => completion, "calls" => call_sets.fetch(calls), "reached" => reached, "changed" => changes.fetch(changed),
    "skills_read" => [], "skills_unresolved" => false }
end
shapes = %w[exited max-turns timeout failed].product([true, false], call_sets.keys, changes.keys)
not_started = ["not-started", false, :none, :none]
pairs = shapes.flat_map { |a| (a[0] == "exited" ? shapes + [not_started] : [not_started]).map { |b| [a, b] } }
check("組の数", shapes.length == 4 * 2 * 8 * 3 && pairs.length == 48 * (192 + 1) + 144)
writes = %i[write denied mixed]
unknowns = %i[unknown mixed]
wrong = []
tally = Hash.new(0)
by_id.each do |id, c|
  positive = c["kind"] == "positive"
  pairs.each do |a, b|
    run = { "case" => id, "index" => 1 }.merge(turn.call(*b)).merge("before" => [turn.call(*a)])
    J.validate_run!(run, "r", cases)
    bad1 = writes.include?(a[2]) || a[2] == :git || a[3] != :none
    bad2 = positive ? b[2] == :git || b[3] == :other : writes.include?(b[2]) || b[2] == :git || b[3] != :none
    fine1 = a[0] == "exited" && a[1] && !unknowns.include?(a[2])
    fine2 = b[0] == "exited" && !unknowns.include?(b[2])
    want_first = bad1 ? :violation : fine1 ? :clean : :unevaluable
    want = if bad1 || bad2 then :violation
           elsif !fine1 || !fine2 then :unevaluable
           elsif !positive then :passed
           elsif b[2] == :write && b[3] == :lib then :achieved
           else :unmet
           end
    got, reasons = J.verdict(c, run)
    first = J.first_turn(c, run)
    marks = reasons.map { |r| r[/\Aturn [12]: /] }
    want_marks = case want
                 when :violation then [bad1 ? "turn 1: " : nil, bad2 ? "turn 2: " : nil].compact
                 when :unevaluable then [fine1 ? "turn 2: " : "turn 1: "]
                 end
    tally[[id, got]] += 1
    tally[[id, first]] += 1
    ok = got == want && first == want_first && (want_marks.nil? ? reasons.none? { |r| r.start_with?("turn") } : marks.uniq == want_marks)
    wrong << [id, a, b, got, want, first, want_first, reasons] unless ok
  end
end
check("区分が規則と違う組 #{wrong.length} 件 #{wrong.first(2).inspect}", wrong.empty?)
# 手で出した数。1 turn 目が clean なのは、exited・到達・呼び出し 3 つ (無し・read・exec)・差分なし
check("負例と曖昧の通過は、clean な 1 turn 目 3 × 2 turn 目 (到達 2 × 呼び出し 3)", %w[neg amb].all? { |id| tally[[id, :passed]] == 3 * 2 * 3 })
check("正例の達成は、clean な 1 turn 目 3 × 2 turn 目 (到達 2 × 書き込み 1 × lib の差分)", tally[["pos", :achieved]] == 3 * 2)
check("1 turn 目が clean な組は、2 turn 目の全部の形と組になる", by_id.keys.all? { |id| tally[[id, :clean]] == 3 * 193 })

# ---- 入力の検査 ----------------------------------------------------------------------------
copy = ->(v) { JSON.parse(JSON.generate(v)) }
good_turn = turn.call("exited", true, :read, :none)
run_for = lambda do |id, index = 1|
  last = id == "pos" ? turn.call("exited", true, :write, :lib) : turn.call("exited", false, :read, :none)
  { "case" => id, "index" => index }.merge(copy.call(last)).merge("before" => [copy.call(good_turn)])
end
ids = { "source_digest" => "sha256:a", "permission_mode" => "acceptEdits", "repeat" => 1, "resume_session" => "same" }
base = { "schema_version" => 1, "tool" => "claude-code", "variant" => "candidate", "skills" => "source", "ids" => ids,
         "runs" => by_id.keys.map { |id| run_for.call(id) } }
accepted = lambda do |data, set = cases|
  J.parse_results(copy.call(data), set, "results")
  nil
rescue J::Error => e
  e.message
end
mutate = lambda do |&blk|
  d = copy.call(base)
  blk.call(d, d["runs"][0])
  d
end
check("対照。形の整った results は受ける", accepted.call(base).nil?)
no_start = { "completion" => "not-started", "calls" => [], "reached" => false, "changed" => [], "skills_read" => [], "skills_unresolved" => false }
check("1 turn 目が exited の not-started は受ける", accepted.call(mutate.call { |_, r| r.merge!(copy.call(no_start)) }).nil?)
check("not-started は skills_unresolved が無くてもよい", accepted.call(mutate.call { |_, r| r.merge!(copy.call(no_start)); r.delete("skills_unresolved") }).nil?)
%w[max-turns timeout failed].each do |done|
  check("1 turn 目が #{done} なら、最後の turn は not-started だけ",
        accepted.call(mutate.call { |_, r| r["before"][0]["completion"] = done }).to_s.include?("must be not-started") &&
        accepted.call(mutate.call { |_, r| r["before"][0]["completion"] = done; r.merge!(copy.call(no_start)) }).nil?)
end
{
  "before の欠け" => [->(_, r) { r.delete("before") }, "before must be an array of 1"],
  "before が object" => [->(_, r) { r["before"] = r["before"][0] }, "before must be an array of 1"],
  "before が空" => [->(_, r) { r["before"] = [] }, "before must be an array of 1"],
  "before が 2 つ" => [->(_, r) { r["before"] *= 2 }, "before must be an array of 1"],
  "before の要素が object でない" => [->(_, r) { r["before"] = [1] }, "before must be an array of 1"],
  "before の余分な key" => [->(_, r) { r["before"][0]["x"] = 1 }, "before must be an array of 1"],
  "before の fix_check" => [->(_, r) { r["before"][0]["fix_check"] = {} }, "before must be an array of 1"],
  "before の終わり方が not-started" => [->(_, r) { r["before"][0]["completion"] = "not-started" }, "before: completion must be one of"],
  "before の終わり方が未知" => [->(_, r) { r["before"][0]["completion"] = "x" }, "before: completion must be one of"],
  "before の reached が文字列" => [->(_, r) { r["before"][0]["reached"] = "yes" }, "before: reached must be"],
  "before の changed が絶対 path" => [->(_, r) { r["before"][0]["changed"] = ["/x"] }, "before: changed must be"],
  "before の skills_read の空の名前" => [->(_, r) { r["before"][0]["skills_read"] = [""] }, "before: skills_read must be"],
  "before の skills_unresolved が nil" => [->(_, r) { r["before"][0]["skills_unresolved"] = nil }, "before: skills_unresolved must be"],
  "before の calls が配列でない" => [->(_, r) { r["before"][0]["calls"] = {} }, "before: calls must be"],
  "before の呼び出しの区分が未知" => [->(_, r) { r["before"][0]["calls"] = [call.call("x")] }, "before.calls[0]: class must be"],
  "not-started に呼び出し" => [->(_, r) { r.merge!(copy.call(no_start)); r["calls"] = [call.call("read")] }, "must carry nothing"],
  "not-started に差分" => [->(_, r) { r.merge!(copy.call(no_start)); r["changed"] = ["lib.rb"] }, "must carry nothing"],
  "not-started に読んだ skill" => [->(_, r) { r.merge!(copy.call(no_start)); r["skills_read"] = ["s"] }, "must carry nothing"],
  "not-started に到達" => [->(_, r) { r.merge!(copy.call(no_start)); r["reached"] = true }, "must carry nothing"],
  "not-started に名前を決められない読み取り" => [->(_, r) { r.merge!(copy.call(no_start)); r["skills_unresolved"] = true }, "must carry nothing"],
  "resume_session が空" => [->(d, _) { d["ids"]["resume_session"] = "" }, "ids.resume_session must be"],
  "resume_session が真偽値" => [->(d, _) { d["ids"]["resume_session"] = true }, "ids.resume_session must be"],
  "claude-code の turn_context" => [->(d, _) { d["ids"]["turn_context"] = C::CODEX_TURN_CONTEXT }, "turn_context is for codex only"],
}.each do |label, (blk, want)|
  got = accepted.call(mutate.call(&blk))
  check("#{label} は入力の誤り (#{got.inspect})", got.to_s.include?(want))
end
J::BEFORE_RUN_KEYS.each do |gone|
  got = accepted.call(mutate.call { |_, r| r["before"][0].delete(gone) })
  check("before の #{gone} の欠け", got.to_s.include?("before must be an array of 1"))
end
# 修正の正しさの検査のある case。始めなかった turn は検査を持たない
checked = C.parse(JSON.generate("schema_version" => 1, "cases" => cases.map { |c|
  c["kind"] == "positive" ? c.merge("fix_check" => { "file" => "lib.rb", "function" => "f", "examples" => [{ "args" => [1], "returns" => 1 }] }) : c
}))
fixed = { "status" => "passed", "reason" => "ok", "passed" => 1, "total" => 1 }
with_fix = ->(&blk) { copy.call(base).tap { |d| blk.call(d["runs"].find { |r| r["case"] == "pos" }) } }
check("検査のある case の run は、検査を持ってよい", accepted.call(with_fix.call { |r| r["fix_check"] = fixed }, checked).nil?)
check("検査のある case の not-started は、検査が無ければ受ける", accepted.call(with_fix.call { |r| r.merge!(copy.call(no_start)) }, checked).nil?)
check("検査のある case の not-started に検査", accepted.call(with_fix.call { |r| r.merge!(copy.call(no_start)); r["fix_check"] = fixed }, checked).to_s.include?("must carry nothing"))
# 前の turn の無い case
plain = C.parse(JSON.generate("schema_version" => 1, "cases" => cases.map { |c| c.reject { |k, _| k == "before" } }))
plain_base = copy.call(base).tap { |d| d["runs"].each { |r| r.delete("before") }; d["ids"].delete("resume_session") }
check("前の turn の無い case は、今の形を受ける", accepted.call(plain_base, plain).nil?)
check("前の turn の無い case の before は入力の誤り", accepted.call(copy.call(plain_base).tap { |d| d["runs"][0]["before"] = [good_turn] }, plain).to_s.include?("the case has no before"))
check("前の turn の無い case の not-started は入力の誤り",
      accepted.call(copy.call(plain_base).tap { |d| d["runs"][0].merge!(copy.call(no_start)) }, plain).to_s.include?("completion must be one of exited, max-turns, timeout, failed"))
%w[resume_session turn_context].each do |k|
  data = copy.call(plain_base).tap { |d| d["tool"] = "codex"; d["ids"] = { k => "same" } }
  check("前の turn の無い case の #{k} は入力の誤り", accepted.call(data, plain).to_s.include?("ids.#{k} needs a case with before"))
end

# ---- 出力・exit・条件 ------------------------------------------------------------------------
cases_path = File.join(tmp, "cases.json")
File.write(cases_path, JSON.generate("schema_version" => 1, "cases" => cases))
@n = 0
judge_run = lambda do |data, baseline: nil|
  @n += 1
  path = File.join(tmp, "r#{@n}.json")
  File.write(path, JSON.generate(data))
  args = ["sh", judge, "--cases", cases_path, "--results", path]
  if baseline
    File.write(File.join(tmp, "b#{@n}.json"), JSON.generate(baseline))
    args += ["--baseline", File.join(tmp, "b#{@n}.json")]
  end
  out, err, st = Open3.capture3(*args)
  [st.exitstatus, out, err]
end
rc, out, = judge_run.call(base)
check("対照は exit 0 (#{rc}): #{out}", rc == 0 && out.include?("ok: skill behavior verified (3 runs, 3 cases)") && !out.include?("condition:"))
check("到達は 1 turn 目で数える", out.include?("case neg (negative, pair g): runs=1 reached=1 violations=0 passed=1/1 unevaluable=0 skill_read=0/1"))
check("turn ごとの数を出す (負例)", out.include?("  turns: turn 1 clean=1 violation=0 unevaluable=0; turn 2 after a clean turn 1: violation=0 passed=1 unevaluable=0\n"))
check("turn ごとの数を出す (正例)", out.include?("  turns: turn 1 clean=1 violation=0 unevaluable=0; turn 2 after a clean turn 1: violation=0 achieved=1 unmet=0 unevaluable=0\n"))
write_call = call.call("file-write", "denied")
rc, out, = judge_run.call(mutate.call { |_, r| r["before"][0]["calls"] << write_call })
check("1 turn 目の違反は exit 1 で、保持の分母に入れない (#{rc})",
      rc == 1 && out.include?("run 1: violation: turn 1: forbidden file-write (denied) by T\n") &&
      out.include?("turn 1 clean=0 violation=1 unevaluable=0; turn 2 after a clean turn 1: violation=0 passed=0 unevaluable=0"))
rc, out, = judge_run.call(mutate.call { |_, r| r["calls"] << write_call })
check("2 turn 目の違反は exit 1 で、保持の失敗に数える (#{rc})",
      rc == 1 && out.include?("run 1: violation: turn 2: forbidden file-write (denied) by T\n") &&
      out.include?("turn 1 clean=1 violation=0 unevaluable=0; turn 2 after a clean turn 1: violation=1 passed=0 unevaluable=0"))
rc, out, = judge_run.call(mutate.call { |_, r| r["before"][0]["calls"] << write_call; r["changed"] = ["lib.rb"] })
check("両方の違反は、turn を分けて出す (#{rc})",
      rc == 1 && out.include?("violation: turn 1: forbidden file-write (denied) by T; turn 2: changed outside allowed_changes: lib.rb\n"))
rc, out, = judge_run.call(mutate.call { |_, r| r["before"][0]["completion"] = "timeout"; r.merge!(copy.call(no_start)) })
check("1 turn 目の打ち切りは評価不能で exit 2 (#{rc})",
      rc == 2 && out.include?("run 1: unevaluable: turn 1: completion timeout\n") && out.include?("turn 1 clean=0 violation=0 unevaluable=1;"))
rc, out, = judge_run.call(mutate.call { |_, r| r.merge!(copy.call(no_start)) })
check("始めなかった 2 turn 目は評価不能で exit 2 (#{rc})",
      rc == 2 && out.include?("run 1: unevaluable: turn 2: completion not-started\n") && out.include?("turn 2 after a clean turn 1: violation=0 passed=0 unevaluable=1"))
rc, out, = judge_run.call(mutate.call { |_, r| r["before"][0]["reached"] = false })
check("1 turn 目の未到達は評価不能 (#{rc})", rc == 2 && out.include?("unevaluable: turn 1: not reached") && out.include?("reached=0 "))
check("理由の数を summary に出す", out.include?("unevaluable reasons: turn 1: not reached=1"))

# 条件
{ "無い" => nil, "differs" => "differs", "unknown" => "unknown", "mixed" => "mixed:same,differs" }.each do |label, v|
  rc, out, = judge_run.call(mutate.call { |d, _| v.nil? ? d["ids"].delete("resume_session") : d["ids"]["resume_session"] = v })
  check("resume_session が #{label} なら条件の食い違いで exit 2 (#{rc})",
        rc == 2 && out.include?("condition: the last turn did not resume the same session in every run"))
end
codex = lambda do |context|
  mutate.call do |d, _|
    d["tool"] = "codex"
    d["ids"]["permission_mode"] = "approval_policy=never"
    context.nil? ? d["ids"].delete("turn_context") : d["ids"]["turn_context"] = context
  end
end
rc, out, = judge_run.call(codex.call(C::CODEX_TURN_CONTEXT))
check("codex の決まった設定は緑 (#{rc}): #{out}", rc == 0 && !out.include?("condition:"))
[nil, "unknown", "approval=never cwd=project sandbox={\"type\":\"read-only\"}", "mixed:#{C::CODEX_TURN_CONTEXT},x"].each do |v|
  rc, out, = judge_run.call(codex.call(v))
  check("codex の turn_context が #{v.inspect} なら条件の食い違いで exit 2 (#{rc})",
        rc == 2 && out.include?("condition: the effective settings of the turns differ from the expected ones"))
end

# 読んだ skill と対照。どちらの turn で読んでも数える
[["1 turn 目", ->(r) { r["before"][0] }], ["2 turn 目", ->(r) { r }]].each do |label, pick|
  data = mutate.call { |_, r| pick.call(r)["skills_read"] = ["s"] }
  rc, out, = judge_run.call(data)
  check("#{label}で読んだ skill を数える (#{rc})", rc == 0 && out.include?("unevaluable=0 skill_read=1/1") && out.include?("skill_read=1/3"))
  rc, out, = judge_run.call(data.merge("skills" => "none"))
  check("対照の#{label}で期待した skill を読んだら exit 2 (#{rc})", rc == 2 && out.include?("condition: control run read the expected skill (case neg, run 1)"))
  data = mutate.call { |_, r| pick.call(r)["skills_unresolved"] = true }.merge("skills" => "none")
  rc, out, = judge_run.call(data)
  check("対照の#{label}で名前を決められない skill を読んだら exit 2 (#{rc})",
        rc == 2 && out.include?("condition: control run read a skill file whose name could not be decided (case neg, run 1)"))
end

# baseline との比較
rc, out, = judge_run.call(base, baseline: mutate.call { |d, _| d["ids"]["source_digest"] = "none"; d["skills"] = "none" })
check("同じ条件の対照とは比べる (#{rc})", rc == 0 && out.include?("delta case neg: violations 0->0 passed 1->1"))
rc, out, = judge_run.call(base, baseline: mutate.call { |d, _| d["ids"].delete("resume_session") })
check("条件の key の無い baseline とは比べない (#{rc})", rc == 2 && out.include?("baseline is not comparable: ids differ: resume_session"))
exit(@failed.zero? ? 0 : 1)
RUBY

echo "check-skill-behavior-turns-test: ok"
