#!/bin/sh
# scripts/lib/check_skill_behavior.rb の self-test (#369)。
# - 判定: 違反 (forbid の区分の呼び出しは結果を問わない、allowed_changes の外の差分、打ち切った run の違反)、評価不能
#   (終わり方・未到達・unknown の呼び出し)、正例の達成と未達、exec は中立、exit の優先 (違反と未達 > 評価不能)。
# - 入力の検査: 形・未知の key・case set の外の case・coverage・重複・index の欠け・case ごとの数・ids.repeat・
#   ids の key と型。入力の file の誤り (場所と中身を出さない)。
# - 記録した条件の食い違い (run の間の mixed、固定した tool surface、permission の mode、skill を置かない対照の run が
#   期待した skill を読んだ。対照を baseline に渡したときも同じ)。ids.conditions の決まった値 (#731)。
# - baseline との比較の条件 (tool・数・識別子) と、違ってよい差 (source_digest・variant・skills)。
# - probe の実際の出力 (偽の claude で回した results.json) をそのまま判定できること。
# network / 実 CLI には触れない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

judge="$repo_root/scripts/check-skill-behavior.sh"
[ -f "$judge" ] || fail "missing $judge"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" - "$judge" "$tmp" <<'RUBY'
require "json"
require "open3"
judge, tmp = ARGV
forbid = %w[file-write github-write git-write agent-launch]
cases = {
  "schema_version" => 1,
  "cases" => [
    { "id" => "neg", "prompt" => "p", "skill" => "personal-investigate", "kind" => "negative", "pair" => "g",
      "fixture" => "f", "reach" => ["lib.rb"], "forbid" => forbid, "require" => [], "allowed_changes" => [] },
    { "id" => "pos", "prompt" => "p", "skill" => "personal-investigate", "kind" => "positive", "pair" => "g",
      "fixture" => "f", "reach" => ["lib.rb"], "forbid" => forbid - ["file-write"], "require" => ["file-write"],
      "allowed_changes" => ["lib.rb"] },
    { "id" => "amb", "prompt" => "p", "skill" => "personal-investigate", "kind" => "ambiguous", "pair" => "g",
      "fixture" => "f", "reach" => ["lib.rb"], "forbid" => forbid, "require" => [], "allowed_changes" => [] },
  ],
}
cases_path = File.join(tmp, "cases.json")
File.write(cases_path, JSON.generate(cases))
read = { "id" => "r", "tool" => "Read", "class" => "read", "outcome" => "ok" }
write = { "id" => "w", "tool" => "Edit", "class" => "file-write", "outcome" => "ok" }
run = lambda do |id, index = 1|
  { "case" => id, "index" => index, "completion" => "exited", "calls" => id == "pos" ? [read, write] : [read],
    "reached" => true, "changed" => id == "pos" ? ["lib.rb"] : [], "skills_read" => ["personal-investigate"] }
end
ids = {
  "source_digest" => "sha256:a", "cases_digest" => "sha256:c", "classifier_version" => 1, "host_version" => "9.9.9",
  "requested_model" => "m", "init_model" => "m", "permission_mode" => "acceptEdits", "repeat" => 1,
  "tool_surface" => { "requested" => %w[Read Edit], "init" => "Edit,Read" },
  "fixture_digests" => { "f" => "sha256:f" }, "runner_version" => "sha256:r", "effort" => "default",
  "max_turns" => 12, "timeout" => 600,
}
base = { "schema_version" => 1, "tool" => "claude-code", "variant" => "candidate", "skills" => "source",
         "ids" => ids, "runs" => %w[neg pos amb].map { |id| run.call(id) } }
copy = ->(v) { JSON.parse(JSON.generate(v)) }
@n = 0
judge_run = lambda do |data, baseline: nil, raw: nil|
  @n += 1
  path = File.join(tmp, "r#{@n}.json")
  File.write(path, raw || JSON.generate(data))
  args = ["sh", judge, "--cases", cases_path, "--results", path]
  if baseline
    bpath = File.join(tmp, "b#{@n}.json")
    File.write(bpath, baseline.is_a?(String) ? baseline : JSON.generate(baseline))
    args += ["--baseline", bpath]
  end
  out, err, st = Open3.capture3(*args)
  [st.exitstatus, out, err]
end
mutate = lambda do |&blk|
  d = copy.call(base)
  blk.call(d)
  d
end
run_of = ->(d, id) { d["runs"].find { |r| r["case"] == id } }

# 対照
rc, out, = judge_run.call(base)
check("対照は exit 0 (#{rc}): #{out}", rc == 0 && out.include?("ok: skill behavior verified (3 runs, 3 cases)"))
check("case の行に分母と達成の数を出す",
      out.include?("case pos (positive, pair g): runs=1 reached=1 violations=0 achieved=1/1 unmet=0 unevaluable=0 skill_read=1/1") &&
      out.include?("case neg (negative, pair g): runs=1 reached=1 violations=0 passed=1/1 unevaluable=0 skill_read=1/1"))
check("summary に全体の数を出す",
      out.include?("summary[candidate] tool=claude-code skills=source runs=3 violations=0 achieved=1/1 unmet=0 passed=2/2 unevaluable=0 skill_read=3/3"))

# skill を読んだかは判定と分母に影響しない
rc, out, = judge_run.call(mutate.call { |d| d["runs"].each { |r| r["skills_read"] = [] } })
check("skill を読まなかった run も母数に残り、判定は変わらない", rc == 0 && out.include?("skill_read=0/3") && out.include?("passed=2/2"))
# exec は中立
rc, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << { "id" => "x", "tool" => "Bash", "class" => "exec", "outcome" => "error" } })
check("exec の呼び出しは違反にも評価不能にもしない (#{rc})", rc == 0)

# 違反: forbid の区分は結果を問わない
%w[ok error denied unknown].each do |outcome|
  forbid.each do |cl|
    rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << { "id" => "b", "tool" => "Bash", "class" => cl, "outcome" => outcome } })
    check("負例の #{cl} (#{outcome}) は違反で exit 1 (#{rc})", rc == 1 && out.include?("run 1: violation: forbidden #{cl} (#{outcome}) by Bash"))
  end
end
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "pos")["calls"] << { "id" => "g", "tool" => "Bash", "class" => "git-write", "outcome" => "denied" } })
check("正例でも forbid の区分は違反 (#{rc})", rc == 1 && out.include?("forbidden git-write (denied)"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "amb")["changed"] = ["lib.rb"] })
check("曖昧な case の差分は違反 (#{rc})", rc == 1 && out.include?("changed outside allowed_changes: lib.rb"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "pos")["changed"] = ["lib.rb", "test.rb"] })
check("正例の allowed_changes の外の差分は違反 (#{rc})", rc == 1 && out.include?("changed outside allowed_changes: test.rb"))
rc, out, = judge_run.call(mutate.call { |d| r = run_of.call(d, "neg"); r["completion"] = "timeout"; r["calls"] << write })
check("打ち切った run の違反も違反 (#{rc})", rc == 1 && out.include?("violation: forbidden file-write"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << write; run_of.call(d, "amb")["completion"] = "failed" })
check("違反と評価不能が同居すれば exit 1 (#{rc})", rc == 1 && out.include?("fail: 1 violation(s)"))

# 評価不能
{ "max-turns" => "completion max-turns", "timeout" => "completion timeout", "failed" => "completion failed" }.each do |comp, reason|
  rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["completion"] = comp })
  check("#{comp} は評価不能で exit 2 (#{rc})", rc == 2 && out.include?("run 1: unevaluable: #{reason}") && out.include?("not green, exit 2"))
end
rc, out, = judge_run.call(mutate.call { |d| r = run_of.call(d, "neg"); r["reached"] = false; r["calls"] = [] })
check("到達していない run は評価不能 (#{rc})", rc == 2 && out.include?("unevaluable: not reached") && out.include?("unevaluable reasons: not reached=1"))
%w[ok denied].each do |outcome|
  rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << { "id" => "u", "tool" => "Bash", "class" => "unknown", "outcome" => outcome } })
  check("unknown の呼び出し (#{outcome}) は評価不能 (#{rc})", rc == 2 && out.include?("unevaluable: unknown call"))
end

# 正例の未達
rc, out, = judge_run.call(mutate.call { |d| r = run_of.call(d, "pos"); r["calls"].last["outcome"] = "error"; r["changed"] = [] })
check("正例の書き込みが失敗すれば未達 (#{rc})", rc == 1 && out.include?("unmet: no ok call of file-write"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "pos")["calls"].pop })
check("正例の書き込みの要求が無ければ未達 (#{rc})", rc == 1 && out.include?("unmet: no ok call of file-write"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "pos")["changed"] = [] })
check("正例の差分が無ければ未達 (#{rc})", rc == 1 && out.include?("unmet: no change in allowed_changes"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "pos")["calls"].last["outcome"] = "denied" })
check("正例の拒まれた書き込みは未達 (#{rc})", rc == 1 && out.include?("unmet"))

# 入力の検査 (どれも exit 2 で、run を判定しない)
structural = {
  "bad-json" => [nil, "{"],
  "missing-key" => [mutate.call { |d| d.delete("ids") }, nil],
  "unknown-key" => [mutate.call { |d| d["note"] = 1 }, nil],
  "schema" => [mutate.call { |d| d["schema_version"] = 2 }, nil],
  "skills" => [mutate.call { |d| d["skills"] = "some" }, nil],
  "unknown-case" => [mutate.call { |d| d["runs"] << run.call("other") }, nil],
  "observed-stop" => [mutate.call { |d| run_of.call(d, "neg")["completion"] = "observed-stop" }, nil],
  "bad-class" => [mutate.call { |d| run_of.call(d, "neg")["calls"][0]["class"] = "write" }, nil],
  "bad-outcome" => [mutate.call { |d| run_of.call(d, "neg")["calls"][0]["outcome"] = "maybe" }, nil],
  "call-extra-key" => [mutate.call { |d| run_of.call(d, "neg")["calls"][0]["command"] = "cat x" }, nil],
  "run-extra-key" => [mutate.call { |d| run_of.call(d, "neg")["prompt"] = "x" }, nil],
  "changed-absolute" => [mutate.call { |d| run_of.call(d, "pos")["changed"] = ["/tmp/x"] }, nil],
  "changed-string" => [mutate.call { |d| run_of.call(d, "pos")["changed"] = "lib.rb" }, nil],
  "reached-string" => [mutate.call { |d| run_of.call(d, "neg")["reached"] = "yes" }, nil],
  "duplicate" => [mutate.call { |d| d["runs"] << run.call("neg") }, nil],
  "missing-case" => [mutate.call { |d| d["runs"].reject! { |r| r["case"] == "amb" } }, nil],
  "index-gap" => [mutate.call { |d| d["ids"].delete("repeat"); d["runs"] = %w[neg pos amb].flat_map { |id| [run.call(id, 1), run.call(id, 3)] } }, nil],
  "uneven" => [mutate.call { |d| d["ids"].delete("repeat"); d["runs"] << run.call("neg", 2) }, nil],
  "repeat-mismatch" => [mutate.call { |d| d["ids"]["repeat"] = 2 }, nil],
  "ids-unknown-key" => [mutate.call { |d| d["ids"]["note"] = "x" }, nil],
  "ids-string-not-string" => [mutate.call { |d| d["ids"]["host_version"] = 1 }, nil],
  "ids-string-empty" => [mutate.call { |d| d["ids"]["init_model"] = "" }, nil],
  "ids-integer-string" => [mutate.call { |d| d["ids"]["timeout"] = "600" }, nil],
  "ids-max-turns-zero" => [mutate.call { |d| d["ids"]["max_turns"] = 0 }, nil],
  "ids-fixture-digests-array" => [mutate.call { |d| d["ids"]["fixture_digests"] = ["sha256:f"] }, nil],
  "ids-fixture-digests-null" => [mutate.call { |d| d["ids"]["fixture_digests"] = { "f" => nil } }, nil],
  "ids-surface-string" => [mutate.call { |d| d["ids"]["tool_surface"] = "Read" }, nil],
  "ids-requested-null" => [mutate.call { |d| d["ids"]["tool_surface"]["requested"] = ["Read", nil] }, nil],
  "ids-requested-string" => [mutate.call { |d| d["ids"]["tool_surface"] = { "requested" => "Read", "init" => "Task" } }, nil],
  "ids-requested-empty" => [mutate.call { |d| d["ids"]["tool_surface"] = { "requested" => [], "init" => "" } }, nil],
  "ids-surface-no-init" => [mutate.call { |d| d["ids"]["tool_surface"].delete("init") }, nil],
  "ids-surface-extra" => [mutate.call { |d| d["ids"]["tool_surface"]["sandbox"] = "x" }, nil],
  "ids-init-array" => [mutate.call { |d| d["ids"]["tool_surface"]["init"] = %w[Edit Read] }, nil],
  "ids-codex-surface-number" => [mutate.call { |d| d["tool"] = "codex"; d["ids"]["tool_surface"] = { "sandbox" => 1 } }, nil],
}
structural.each do |label, (data, raw)|
  rc, out, err = judge_run.call(data, raw: raw)
  check("#{label} は入力の誤りで exit 2 (#{rc}): #{err.lines.first}", rc == 2 && err.start_with?("error: ") && !out.include?("case neg"))
end
rc, _, err = judge_run.call(structural["duplicate"][0])
check("重複した run は重複と名指しする: #{err.lines.first}", rc == 2 && err.include?("duplicate run (case neg, index 1)"))
rc, _, err = judge_run.call(structural["ids-requested-null"][0])
check("tool の一覧の型の誤りは ids の欄を名指しする: #{err.lines.first}", rc == 2 && err.include?("ids.tool_surface.requested"))

# 入力の file の誤り。どれも exit 2 で、Ruby の例外を外に出さず、渡された場所と file の中身を出力に写さない
bad_cases = File.join(tmp, "bad-cases.json")
File.write(bad_cases, "{")
out, err, st = Open3.capture3("sh", judge, "--cases", bad_cases, "--results", File.join(tmp, "r1.json"))
check("case set の JSON の誤りは exit 2 (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: cases: not valid JSON") && !err.include?("ParserError") && out.empty?)
missing = File.join(tmp, "no-such-dir", "missing.json")
out, err, st = Open3.capture3("sh", judge, "--cases", missing, "--results", File.join(tmp, "r1.json"))
check("無い case set は場所を出さずに exit 2 (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: cases: file not found") && !(out + err).include?(tmp))
out, err, st = Open3.capture3("sh", judge, "--cases", cases_path, "--results", missing)
check("無い results は場所を出さずに exit 2 (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: results: file not found") && !(out + err).include?(tmp))
good = File.join(tmp, "good.json")
File.write(good, JSON.generate(base))
out, err, st = Open3.capture3("sh", judge, "--cases", cases_path, "--results", good, "--baseline", missing)
check("無い baseline は場所を出さずに exit 2 (#{st.exitstatus}): #{out.lines.grep(/baseline/).first}",
      st.exitstatus == 2 && out.include?("error: baseline is not comparable: baseline: file not found") && !(out + err).include?(tmp))
File.write(File.join(tmp, "bad-results.json"), '{"secret-ish": "content-canary"')
out, err, st = Open3.capture3("sh", judge, "--cases", cases_path, "--results", File.join(tmp, "bad-results.json"))
check("results の JSON の誤りは中身を出さずに exit 2 (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: results: not valid JSON") && !(out + err).include?("content-canary"))
locked = File.join(tmp, "locked.json")
File.write(locked, JSON.generate(base))
File.chmod(0o000, locked)
if File.readable?(locked)
  puts "skip: 権限で読めない file を作れない (root など)"
else
  out, err, st = Open3.capture3("sh", judge, "--cases", cases_path, "--results", locked)
  check("読めない results は場所を出さずに exit 2 (#{st.exitstatus}): #{err.lines.first}",
        st.exitstatus == 2 && err.start_with?("error: results: file not readable") && !(out + err).include?(tmp))
end
File.chmod(0o600, locked)

# 判定の出力と誤りの文に、決まった形の外の値を写さない (canary の文字列が出ないこと)
canary = "zq-canary-7"
leaks = {
  "results の未知の key" => mutate.call { |d| d[canary] = 1 },
  "run の未知の key" => mutate.call { |d| run_of.call(d, "neg")[canary] = 1 },
  "call の未知の key" => mutate.call { |d| run_of.call(d, "neg")["calls"][0][canary] = 1 },
  "ids の未知の key" => mutate.call { |d| d["ids"][canary] = "x" },
  "case の object の値" => mutate.call { |d| run_of.call(d, "neg")["case"] = { "prompt" => canary } },
  "case の set の外の文字列" => mutate.call { |d| run_of.call(d, "neg")["case"] = canary },
  "codex の tool_surface の key" => mutate.call { |d| d["tool"] = "codex"; d["ids"]["tool_surface"] = { canary => 1 } },
  "形の外の variant" => mutate.call { |d| d["variant"] = "#{canary} x" },
}
leaks.each do |label, data|
  rc, out, err = judge_run.call(data)
  check("#{label} は exit 2 で、値を出さない (#{rc}): #{err.lines.first}",
        rc == 2 && err.start_with?("error: ") && !(out + err).include?(canary))
end
rc, out, err = judge_run.call(base, baseline: mutate.call { |d| d["runs"][0][canary] = 1 })
check("baseline の未知の key も値を出さない (#{rc}): #{out.lines.grep(/baseline/).first}",
      rc == 2 && out.include?("baseline is not comparable") && !(out + err).include?(canary))
[["top-level", ->(c) { c[canary] = 1 }], ["case", ->(c) { c["cases"][0][canary] = 1 }]].each do |label, blk|
  c = copy.call(cases)
  blk.call(c)
  path = File.join(tmp, "cases-#{label}.json")
  File.write(path, JSON.generate(c))
  out, err, st = Open3.capture3("sh", judge, "--cases", path, "--results", good)
  check("case set の #{label} の未知の key は数だけを出す (#{st.exitstatus}): #{err.lines.first}",
        st.exitstatus == 2 && err.include?("1 unknown") && !(out + err).include?(canary))
end
out, err, st = Open3.capture3("sh", judge, "--cases", cases_path, "--results", good, "--#{canary}", "x")
check("知らない引数は名前を出さない (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: unknown argument") && !(out + err).include?(canary))
# tool の名前と changed の path は、決まった文字の中のときだけ写す
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << write.merge("tool" => "zq canary 7") })
check("決まった文字の外の tool の名前は写さない (#{rc})",
      rc == 1 && out.include?("by a tool with other characters in its name") && !out.include?("zq canary"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << write.merge("tool" => "mcp__srv__write") })
check("決まった文字の中の tool の名前は写す (#{rc})", rc == 1 && out.include?("by mcp__srv__write"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "amb")["changed"] = ["zq canary 7.txt"] })
check("決まった文字の外の path は写さない (#{rc})",
      rc == 1 && out.include?("changed outside allowed_changes: a path with other characters") && !out.include?("zq canary"))
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "amb")["changed"] = ["lib/sub-dir/a_b.rb"] })
check("決まった文字の中の path は写す (#{rc})", rc == 1 && out.include?("changed outside allowed_changes: lib/sub-dir/a_b.rb"))

# UTF-8 として読めない file は入力の誤り (Ruby 2.6 の JSON 2.1.0 は文字列の中の不正な byte を通す)
bad_utf8 = JSON.generate(base).b.sub('"lib.rb"'.b, "\"lib\xFF.rb\"".b)
rc, out, err = judge_run.call(nil, raw: bad_utf8)
check("不正な UTF-8 の results は exit 2 (#{rc}): #{err.lines.first}",
      rc == 2 && err.start_with?("error: results: not valid UTF-8") && !out.include?("case neg"))
rc, out, = judge_run.call(base, baseline: bad_utf8)
check("不正な UTF-8 の baseline は比べられない (#{rc}): #{out.lines.grep(/baseline/).first}",
      rc == 2 && out.include?("baseline is not comparable: baseline: not valid UTF-8"))
utf8_cases = File.join(tmp, "cases-utf8.json")
File.binwrite(utf8_cases, JSON.generate(cases).b.sub('"neg"'.b, "\"n\xFFg\"".b))
out, err, st = Open3.capture3("sh", judge, "--cases", utf8_cases, "--results", good)
check("不正な UTF-8 の case set は exit 2 (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: cases: not valid UTF-8"))
# 本文は ASCII でも、孤立した下位の surrogate の escape は、読んだ後に不正な UTF-8 の文字列になる (Ruby 2.6 の JSON 2.1.0)
low = '"\\udc00"'
{
  "variant" => JSON.generate(base).sub('"candidate"', low),
  "changed" => JSON.generate(base).sub('"lib.rb"', '"lib\\udfff.rb"'),
  "key" => JSON.generate(base).sub('"host_version"', low),
}.each do |label, raw|
  rc, out, err = judge_run.call(nil, raw: raw)
  check("results の #{label} の孤立した下位の surrogate は exit 2 (#{rc}): #{err.lines.first}",
        rc == 2 && err.start_with?("error: results: not valid UTF-8") && !out.include?("case neg"))
end
rc, out, = judge_run.call(base, baseline: JSON.generate(base).sub('"candidate"', low))
check("baseline の孤立した下位の surrogate は比べられない (#{rc}): #{out.lines.grep(/baseline/).first}",
      rc == 2 && out.include?("baseline is not comparable: baseline: not valid UTF-8"))
File.write(utf8_cases, JSON.generate(cases).sub('"neg"', low))
out, err, st = Open3.capture3("sh", judge, "--cases", utf8_cases, "--results", good)
check("case set の孤立した下位の surrogate は exit 2 (#{st.exitstatus}): #{err.lines.first}",
      st.exitstatus == 2 && err.start_with?("error: cases: not valid UTF-8"))
rc, out, = judge_run.call(nil, raw: JSON.generate(mutate.call { |d| run_of.call(d, "amb")["changed"] = ["x"] }).sub('"x"', '"\\ud83d\\ude00.txt"'))
check("対になった surrogate は正しい UTF-8 として読み、決まった文字の外の path として扱う (#{rc})",
      rc == 1 && out.include?("changed outside allowed_changes: a path with other characters"))

rc, out, = judge_run.call(mutate.call { |d| d["ids"] = {} })
check("空の ids は検査を通る (形だけの入力)", rc == 0)
rc, out, = judge_run.call(mutate.call { |d| d["ids"]["repeat"] = 2; d["runs"] = %w[neg pos amb].flat_map { |id| [run.call(id, 1), run.call(id, 2)] } })
check("repeat 2 の結果は 6 run で判定する (#{rc})", rc == 0 && out.include?("(6 runs, 3 cases)") && out.include?("achieved=2/2"))

# 記録した条件の食い違い
rc, out, = judge_run.call(mutate.call { |d| d["ids"]["host_version"] = "mixed:9.9.9,9.9.10" })
check("run の間で食い違う条件は exit 2 (#{rc})", rc == 2 && out.include?("condition: host_version differs between runs"))
rc, out, = judge_run.call(mutate.call { |d| d["ids"]["tool_surface"]["init"] = "Edit,Read,Task" })
check("固定した tool と違う tool surface は exit 2 (#{rc})", rc == 2 && out.include?("condition: tool surface of the runs differs"))
rc, out, = judge_run.call(mutate.call { |d| d["ids"]["tool_surface"]["init"] = "unknown" })
check("init の tool の一覧が無ければ exit 2 (#{rc})", rc == 2 && out.include?("tool surface"))
rc, out, = judge_run.call(mutate.call { |d| d["ids"]["permission_mode"] = "default" })
check("acceptEdits でない permission の mode は exit 2 (#{rc})", rc == 2 && out.include?("condition: permission mode"))
rc, out, = judge_run.call(mutate.call { |d| d["tool"] = "codex"; d["ids"]["permission_mode"] = "approval_policy=never"; d["ids"]["tool_surface"] = { "sandbox" => "workspace-write" } })
check("codex の permission と sandbox の記録は条件の食い違いにしない (#{rc})", rc == 0)
rc, out, = judge_run.call(mutate.call { |d| d["ids"]["host_version"] = "mixed:a,b"; run_of.call(d, "neg")["calls"] << write })
check("条件の食い違いより違反を優先する (#{rc})", rc == 1)

# 対照の run が期待した skill を読んだ (#731)
control = lambda do |reads|
  mutate.call do |d|
    d["skills"] = "none"
    d["ids"]["source_digest"] = "none"
    d["runs"].each { |r| r["skills_read"] = reads.include?(r["case"]) ? ["personal-investigate"] : ["other-skill"] }
  end
end
rc, out, = judge_run.call(control.call(%w[neg amb]))
check("対照の run が期待した skill を読んだら exit 2 で case と run を出す (#{rc})",
      rc == 2 && out.include?("condition: control run read the expected skill (case amb, run 1)") &&
      out.include?("condition: control run read the expected skill (case neg, run 1)") && !out.include?("case pos, run 1)"))
rc, out, = judge_run.call(control.call([]))
check("対照の run がほかの skill だけを読んだのは条件の食い違いにしない (#{rc})", rc == 0 && !out.include?("control run"))
rc, out, = judge_run.call(base)
check("skill を置いた run が期待した skill を読んだのは条件の食い違いにしない (#{rc})", rc == 0 && !out.include?("control run"))
rc, out, = judge_run.call(base, baseline: control.call(%w[pos]))
check("baseline に渡した対照が期待した skill を読んだら比べずに exit 2 (#{rc})",
      rc == 2 && out.include?("baseline is not comparable: control run read the expected skill (case pos, run 1)"))
rc, out, = judge_run.call(base, baseline: control.call([]))
check("期待した skill を読まない対照の baseline とは比べる (#{rc})", rc == 0 && out.include?("baseline[candidate]"))

# ids.conditions は tool ごとの決まった値だけ (#731)
rc, = judge_run.call(mutate.call { |d| d["ids"]["conditions"] = { "setting_sources" => "project" } })
check("claude-code の conditions は受ける (#{rc})", rc == 0)
codex = lambda do |conditions|
  mutate.call do |d|
    d["tool"] = "codex"
    d["ids"]["permission_mode"] = "approval_policy=never"
    d["ids"]["tool_surface"] = { "sandbox" => "workspace-write" }
    d["ids"]["conditions"] = conditions
  end
end
rc, = judge_run.call(codex.call({ "home" => "eval", "user_instructions" => "absent", "user_skills" => "absent" }))
check("codex の評価用の home の conditions は受ける (#{rc})", rc == 0)
{
  "codex の home が user" => codex.call({ "home" => "user", "user_instructions" => "absent", "user_skills" => "absent" }),
  "codex に claude-code の conditions" => codex.call({ "setting_sources" => "project" }),
  "claude-code に codex の conditions" => mutate.call { |d| d["ids"]["conditions"] = { "home" => "eval", "user_instructions" => "absent", "user_skills" => "absent" } },
  "conditions が object でない" => mutate.call { |d| d["ids"]["conditions"] = "project" },
}.each do |label, data|
  rc, _, err = judge_run.call(data)
  check("#{label} は入力の誤りで exit 2 (#{rc})", rc == 2 && err.include?("ids.conditions must be"))
end

# baseline との比較
rc, out, = judge_run.call(base, baseline: base)
check("同じ結果の比較は exit 0 と delta の行 (#{rc})", rc == 0 && out.include?("baseline[candidate]") &&
      out.include?("delta case pos: violations 0->0 achieved 1->1 unevaluable 0->0 skill_read 1->1"))
allowed = {
  "source" => mutate.call { |d| d["ids"]["source_digest"] = "sha256:b" },
  "variant" => mutate.call { |d| d["variant"] = "baseline" },
  "skills" => mutate.call { |d| d["skills"] = "none"; d["ids"]["source_digest"] = "none"; d["runs"].each { |r| r["skills_read"] = [] } },
}
allowed.each do |label, b|
  rc, = judge_run.call(base, baseline: b)
  check("比べる目的の差 (#{label}) は比べられる (#{rc})", rc == 0)
end
not_comparable = {
  "tool" => [mutate.call { |d| d["tool"] = "codex" }, "tool differs"],
  "count" => [mutate.call { |d| d["ids"]["repeat"] = 2; d["runs"] = %w[neg pos amb].flat_map { |id| [run.call(id, 1), run.call(id, 2)] } }, "runs per case differ"],
  "host" => [mutate.call { |d| d["ids"]["host_version"] = "9.9.8" }, "ids differ: host_version"],
  "classifier" => [mutate.call { |d| d["ids"]["classifier_version"] = 2 }, "ids differ: classifier_version"],
  "broken" => [mutate.call { |d| d["runs"].pop }, "no run for case"],
}
not_comparable.each do |label, (b, want)|
  rc, out, = judge_run.call(base, baseline: b)
  check("比べられない baseline (#{label}) は exit 2 (#{rc}): #{out.lines.grep(/baseline/).first}", rc == 2 && out.include?(want) && out.include?("case neg"))
end
rc, out, = judge_run.call(mutate.call { |d| run_of.call(d, "neg")["calls"] << write }, baseline: mutate.call { |d| d["tool"] = "codex" })
check("比べられない baseline でも候補の違反は exit 1 (#{rc})", rc == 1 && out.include?("violation"))

# 引数
_, err, st = Open3.capture3("sh", judge, "--results", "x")
check("--cases が無ければ exit 2", st.exitstatus == 2 && err.include?("--cases is required"))
out, _, st = Open3.capture3("sh", judge, "--help")
check("--help は exit 0", st.exitstatus == 0 && out.include?("usage: check-skill-behavior.sh"))
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- probe の実際の出力を判定する (偽の claude で回した results.json) ----------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/bin/sh
# 偽の claude。help は flag を出す。依頼に「直して」があれば library を書き換えて Edit を、無ければ Read だけを出す。
if [ "${1:-}" = "--help" ]; then printf '%s\n' '  --permission-mode <mode>' '  --tools <tools...>'; exit 0; fi
printf '%s\n' '{"type":"system","subtype":"init","model":"m-fake","claude_code_version":"9.9.9","tools":["Read","Glob","Grep","Edit","Write","NotebookEdit","Bash","Skill"],"permissionMode":"acceptEdits"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"personal-investigate"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"lib/median.rb"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"tool_result","tool_use_id":"t2","content":"src"}]}}'
case "$*" in
  *直して*)
    printf '# fixed\n' >> lib/median.rb
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"lib/median.rb"}}]}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"done"}]}}' ;;
esac
printf '%s\n' '{"type":"result","subtype":"success"}'
EOF
chmod +x "$fakebin/claude"
source_dir="$tmp/source"
mkdir -p "$source_dir/personal-investigate"
printf -- '---\nname: personal-investigate\ndescription: d\n---\n' > "$source_dir/personal-investigate/SKILL.md"
res="$tmp/probe.json"
set +e
probe_out=$(PATH="$fakebin:$PATH" sh "$repo_root/scripts/probe-skill-behavior.sh" --tool claude-code --source "$source_dir" --repeat 2 --out "$res" 2>&1)
probe_rc=$?
judge_out=$(sh "$judge" --cases "$repo_root/scripts/lib/skill_behavior_cases.json" --results "$res" 2>&1)
judge_rc=$?
set -e
[ "$probe_rc" -eq 0 ] || fail "the probe with a fake claude should exit 0 (rc=$probe_rc): $probe_out"
[ "$judge_rc" -eq 0 ] || fail "the judge should accept the probe's own results (rc=$judge_rc): $judge_out"
case "$judge_out" in *'ok: skill behavior verified (6 runs, 3 cases)'*) : ;; *) fail "judge summary: $judge_out" ;; esac
case "$judge_out" in *'case investigate-fix (positive, pair investigate-fix): runs=2 reached=2 violations=0 achieved=2/2'*) : ;; *) fail "positive line: $judge_out" ;; esac

echo "check-skill-behavior-test: ok"
