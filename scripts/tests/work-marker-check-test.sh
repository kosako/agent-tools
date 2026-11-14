#!/bin/sh
# personal-work-marker-check.rb の self-test (#661)。
# 規則 (Document) は require して直接、CLI は ruby で起動して確かめる。fixture は docs/work-markers.md の v4 の形
# (review の結果の Independence の行は v4 で、Target の行は v3 で足した形、pr の本文の Closes の行は v2 で絞った形、review の結果の残りの 3 行と
# escape の行は v1 から同じ) と、実際に投稿した結果コメント (#659・#638) の形から作る。#663 の review の round 1・2 の入力の例も含む。network access なし。何も書かないことは
# tree_snapshot で確かめる。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-work-marker-check.rb"
templates="$repo_root/shared/skills/personal-review-request/TEMPLATES.md"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

ruby -r"$script_dir/lib/check_helper" - "$src" "$templates" <<'RUBY'
require "open3"
src, templates = ARGV
require src

doc = ->(kind, text) { WorkMarkerCheck::Document.new(kind, text) }
errs = ->(kind, text) { doc.call(kind, text).errors.map(&:rule) }
notes = ->(kind, text) { doc.call(kind, text).findings.select(&:note).map(&:rule) }
cli = lambda do |args, input = "", env = {}|
  o, e, s = Open3.capture3(env, "ruby", src, *args, stdin_data: input, binmode: true)
  [o.force_encoding(Encoding::UTF_8), e.force_encoding(Encoding::UTF_8), s]
end

heading = "## 📋 レビュー結果（by Codex）"
verdict = ->(v) { "**Review process verdict: #{v}**" }
summary = ->(m, s, n) { "**Finding summary: 🔴 must #{m} / 🟡 should #{s} / ⚪ nit #{n}**" }
target = "**Target: base main #{'a' * 40} / head #{'b' * 40}**"
indep = "**Independence: cross-review verified (author=claude)**"
# 結果コメントの本文。Target と Independence の行は既定で末尾に足す (その行そのものを確かめる case は raw で組む)。
result = ->(*lines) { (lines + [target, indep]).join("\n") + "\n" }
raw = ->(*lines) { lines.join("\n") + "\n" }
ok_result = result.call(heading, "", verdict.call("APPROVE"), summary.call(0, 0, 0))

# --- review-result: 合う形
check "template-shaped result is ok", errs.call("review-result", ok_result).empty?
# 実際に #659 に投稿した結果コメントの形 (Target・Independence の行と、転記の節を含む)。
posted = <<~MD
  ## 📋 レビュー結果（by Codex）

  **Review process verdict: APPROVE**
  **Finding summary: 🔴 must 0 / 🟡 should 0 / ⚪ nit 0**
  **Target: base main 7d78772bdaa486a1b3a18c4eeb2bedb923561825 / head 4da1a25fd179d1b5a8639fefb1e9344745997b7b**
  **Independence: cross-review verified (author=claude)**

  PR 全体の merge readiness は required checks 等を別途確認する。

  ### 🔴 must

  なし

  ### Codex の所見 (転記)

  指定 OID の静的レビューです。
MD
check "posted #659 result is ok", errs.call("review-result", posted).empty?
check "round suffix after the heading is ok", errs.call("review-result", result.call("#{heading}round 2", verdict.call("APPROVE"), summary.call(0, 0, 0))).empty?
check "reviewer Claude is ok", errs.call("review-result", ok_result.sub("by Codex", "by Claude")).empty?
check "pin-check heading is ok", errs.call("review-result", ok_result.sub("by Codex", "by personal-dependabot-pin-check")).empty?
check "REJECT with must is ok", errs.call("review-result", result.call(heading, verdict.call("REJECT"), summary.call(2, 1, 0))).empty?
check "Warning with should only is ok", errs.call("review-result", result.call(heading, verdict.call("Warning"), summary.call(0, 2, 3))).empty?
check "APPROVE with nit only is ok", errs.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(0, 0, 4))).empty?
check "CRLF line endings are ok", errs.call("review-result", ok_result.gsub("\n", "\r\n")).empty?
check "trailing spaces after the marker lines are ok", errs.call("review-result", raw.call(heading, verdict.call("APPROVE") + "  ", summary.call(0, 0, 0) + "\t", target + " ", indep + " \t")).empty?
check "branch-like base ref is ok", errs.call("review-result", ok_result.sub("base main ", "base issue-662/target.line ")).empty?
# 実際に #638 に投稿した pin-check の結果コメントの 5 行 (v3 の頃の投稿で、v4 の形も満たす)。
pin_posted = raw.call("## 📋 レビュー結果（by personal-dependabot-pin-check）", "", verdict.call("APPROVE"), summary.call(0, 0, 0),
                      "**Target: base main 33fd951faa7758876a665bf013b0be729ec8c834 / head 812ae65eeb2d0e1609428d437fa0f30425bdd0b7**",
                      "**Independence: deterministic check (dependabot pin)**")
check "posted #638 pin-check result is ok", errs.call("review-result", pin_posted).empty?

# 雛形 (TEMPLATES.md の結果の block) の 5 行が、検査の形と同じ文字である (雛形を変えたらここで気づく)。
tpl = File.read(templates, encoding: "UTF-8")
tpl_heading = tpl.lines.map(&:chomp).find { |l| l.start_with?("## 📋 レビュー結果（by ") }
check "template heading exists", !tpl_heading.nil?
%w[Codex Claude personal-dependabot-pin-check].each do |r|
  check "template lists reviewer #{r}", tpl_heading.to_s.include?(r)
  check "template heading form matches for #{r}", WorkMarkerCheck::RESULT_HEADING.match?(tpl_heading.to_s.sub(/（by .*）/, "（by #{r}）"))
end
check "template verdict line form matches", tpl.lines.map(&:chomp).any? { |l| l == "**Review process verdict: REJECT | Warning | APPROVE**" }
tpl_summary = tpl.lines.map(&:chomp).find { |l| l.start_with?("**Finding summary:") }
check "template summary form matches", WorkMarkerCheck::FINDING_SUMMARY.match?(tpl_summary.to_s.gsub(" N", " 0"))
tpl_target = tpl.lines.map(&:chomp).find { |l| l.start_with?("**Target:") }
check "template target line exists", tpl_target == "**Target: base <base ref> <base OID> / head <head OID>**"
check "template target form matches", WorkMarkerCheck::TARGET_LINE.match?(tpl_target.to_s.sub("<base ref>", "main").sub("<base OID>", "a" * 40).sub("<head OID>", "b" * 40))

# --- review-result: 崩れた形
check "half-width parens in heading", errs.call("review-result", ok_result.sub("（by Codex）", "(by Codex)")) == ["result-heading"]
check "unknown reviewer", errs.call("review-result", ok_result.sub("by Codex", "by OpenCode")) == ["result-heading"]
check "heading without emoji", errs.call("review-result", ok_result.sub("📋 ", "")) == ["result-heading"]
check "indented heading", errs.call("review-result", ok_result.sub(heading, "  #{heading}")) == ["result-heading"]
check "duplicate heading", errs.call("review-result", ok_result + heading + "\n") == ["result-heading"]
check "verdict in a list item", errs.call("review-result", ok_result.sub(verdict.call("APPROVE"), "- #{verdict.call('APPROVE')}")) == ["verdict-line"]
check "verdict without bold", errs.call("review-result", ok_result.sub(verdict.call("APPROVE"), "Review process verdict: APPROVE")) == ["verdict-line"]
check "verdict with unknown value", errs.call("review-result", ok_result.sub("APPROVE", "LGTM")) == ["verdict-line"]
check "lowercase verdict value", errs.call("review-result", ok_result.sub("APPROVE", "approve")) == ["verdict-line"]
check "duplicate verdict", errs.call("review-result", ok_result + verdict.call("APPROVE") + "\n") == ["verdict-line"]
check "duplicate verdict inside a code block", errs.call("review-result", ok_result + "```\n" + verdict.call("APPROVE") + "\n```\n") == ["verdict-line"]
check "summary with an emoji variation selector", errs.call("review-result", ok_result.sub("⚪", "⚪\u{FE0F}")) == ["finding-summary"]
check "summary with a different separator", errs.call("review-result", ok_result.sub(" / 🟡", ", 🟡")) == ["finding-summary"]
check "summary missing", errs.call("review-result", result.call(heading, verdict.call("APPROVE"))) == ["finding-summary"]
check "all five missing", errs.call("review-result", "本文だけ\n").sort == %w[finding-summary independence-line result-heading target-line verdict-line]
check "APPROVE with must", errs.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(1, 0, 0))) == ["verdict-mismatch"]
check "Warning with must", errs.call("review-result", result.call(heading, verdict.call("Warning"), summary.call(1, 1, 0))) == ["verdict-mismatch"]
check "APPROVE with should", errs.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(0, 1, 0))) == ["verdict-mismatch"]
check "Warning with nothing", errs.call("review-result", result.call(heading, verdict.call("Warning"), summary.call(0, 0, 1))) == ["verdict-mismatch"]
check "REJECT without must", errs.call("review-result", result.call(heading, verdict.call("REJECT"), summary.call(0, 1, 0))) == ["verdict-mismatch"]
miss = doc.call("review-result", ok_result.sub(verdict.call("APPROVE"), "- #{verdict.call('APPROVE')}")).errors.first
check "missing marker points at the near line", miss.line == 3
check "mismatch points at the verdict line", doc.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(1, 0, 0))).errors.first.line == 2

# --- review-result: Target の行 (v3)
no_target = raw.call(heading, verdict.call("APPROVE"), summary.call(0, 0, 0), indep)
check "target missing (the v2 form)", errs.call("review-result", no_target) == ["target-line"]
check "target missing points at line 0", doc.call("review-result", no_target).errors.first.line == 0
check "target with short OIDs", errs.call("review-result", ok_result.sub("a" * 40, "a" * 8)) == ["target-line"]
check "target with uppercase hex", errs.call("review-result", ok_result.sub("b" * 40, "B" * 40)) == ["target-line"]
check "target without the base ref", errs.call("review-result", ok_result.sub("base main ", "base ")) == ["target-line"]
check "target in the executor form (@)", errs.call("review-result", ok_result.sub("main ", "main @ ")) == ["target-line"]
check "target without the slash between base and head", errs.call("review-result", ok_result.sub(" / head ", " head ")) == ["target-line"]
check "target without bold", errs.call("review-result", ok_result.sub(target, target.delete("*"))) == ["target-line"]
check "target with trailing text", errs.call("review-result", ok_result.sub(target, target + " (round 2)")) == ["target-line"]
check "target in a list item", errs.call("review-result", ok_result.sub(target, "- " + target)) == ["target-line"]
check "duplicate target", errs.call("review-result", ok_result + target + "\n") == ["target-line"]
check "broken target points at the near line", doc.call("review-result", ok_result.sub(target, "- " + target)).errors.first.line == 5

# --- review-result: Independence の行 (v4、#668)
no_indep = raw.call(heading, verdict.call("APPROVE"), summary.call(0, 0, 0), target)
check "independence missing (the v3 form)", errs.call("review-result", no_indep) == ["independence-line"]
check "independence missing points at line 0", doc.call("review-result", no_indep).errors.first.line == 0
WorkMarkerCheck::INDEPENDENCE_VALUES.each do |v|
  check "independence value is ok: #{v}", errs.call("review-result", ok_result.sub(indep, "**Independence: #{v}**")).empty?
end
# 雛形の Independence の行の選択肢が、検査の閉じた表と同じ (雛形か表の片方だけを変えたらここで気づく)。
tpl_indep = tpl.lines.map(&:chomp).find { |l| l.start_with?("**Independence:") }
check "template independence values match the table",
      tpl_indep.to_s.delete_prefix("**Independence: ").delete_suffix("**").split(" | ") == WorkMarkerCheck::INDEPENDENCE_VALUES
check "independence with an unknown value", errs.call("review-result", ok_result.sub(indep, "**Independence: independent**")) == ["independence-line"]
check "independence not-established without the author", errs.call("review-result", ok_result.sub(indep, "**Independence: not-established**")) == ["independence-line"]
check "independence with an unknown author", errs.call("review-result", ok_result.sub(indep, "**Independence: cross-review verified (author=unknown)**")) == ["independence-line"]
check "independence without bold", errs.call("review-result", ok_result.sub(indep, indep.delete("*"))) == ["independence-line"]
check "independence with a prefix", errs.call("review-result", ok_result.sub(indep, "参考: " + indep)) == ["independence-line"]
check "independence in a list item", errs.call("review-result", ok_result.sub(indep, "- " + indep)) == ["independence-line"]
check "independence with trailing text", errs.call("review-result", ok_result.sub(indep, indep + " (round 2)")) == ["independence-line"]
check "duplicate independence", errs.call("review-result", ok_result + indep + "\n") == ["independence-line"]
check "conflicting independence", errs.call("review-result", ok_result + "**Independence: second-opinion only**\n") == ["independence-line"]
# 正しい行と、表の外の値の行が並んだ結果は、どちらの順でも通さない (行の形で数える。#678 の review の F1)。
["**Independence: not-established**", "**Independence: independent**", "**Independence: cross-review verified (author=claude)** (参考)",
 "**Independence:**", "**Independence: second-opinion only"].each do |extra|
  check "a valid line followed by an off-table line (#{extra})", errs.call("review-result", ok_result + extra + "\n") == ["independence-line"]
  check "an off-table line followed by a valid line (#{extra})", errs.call("review-result", ok_result.sub(indep, extra + "\n" + indep)) == ["independence-line"]
end
check "an off-table value alone points at its line", doc.call("review-result", ok_result.sub(indep, "**Independence: not-established**")).errors.map(&:line) == [6]
check "duplicate independence inside a code block", errs.call("review-result", ok_result + "```\n" + indep + "\n```\n") == ["independence-line"]
check "broken independence points at the near line", doc.call("review-result", ok_result.sub(indep, "- " + indep)).errors.first.line == 6

# --- escape-issue
check "origin line is ok", errs.call("escape-issue", "本文。\n\n元の PR: #654\n").empty?
check "two origins are ok", errs.call("escape-issue", "元の PR: #653, #654\n").empty?
check "other repository origin is ok", errs.call("escape-issue", "元の PR: owner/repo#12\n").empty?
check "mixed origins are ok", errs.call("escape-issue", "元の PR: #1, owner/repo#2\n").empty?
check "origin in a list item", errs.call("escape-issue", "- 元の PR: #654\n") == ["origin-pr"]
check "origin with a full-width colon", errs.call("escape-issue", "元の PR：#654\n") == ["origin-pr"]
check "origin without the space", errs.call("escape-issue", "元のPR: #654\n") == ["origin-pr"]
check "origin without #", errs.call("escape-issue", "元の PR: 654\n") == ["origin-pr"]
check "origin with a different separator", errs.call("escape-issue", "元の PR: #1 #2\n") == ["origin-pr"]
check "origin with trailing text", errs.call("escape-issue", "元の PR: #654 (docs の誤り)\n") == ["origin-pr"]
check "origin missing", errs.call("escape-issue", "本文だけ。\n") == ["origin-pr"]
check "origin missing points at line 0", doc.call("escape-issue", "本文だけ。\n").errors.first.line == 0
check "duplicate origin", errs.call("escape-issue", "元の PR: #1\n元の PR: #2\n") == ["origin-pr"]

# --- pr
pr = ->(title, body = nil) { body.nil? ? "#{title}\n" : "#{title}\n\n#{body}" }
loose = ->(title, body) { notes.call("pr", pr.call(title, body)).include?("loose-closing") }
check "title ref and closes agree", errs.call("pr", pr.call("x を直す (#12)", "本文。\n\nCloses #12\n")).empty?
check "title ref only is ok with a note", errs.call("pr", pr.call("x (#12)", "本文。\n")).empty? && notes.call("pr", pr.call("x (#12)", "本文。\n")) == ["no-closes"]
check "title only (no body) is ok", errs.call("pr", pr.call("x (#12)")).empty?
check "closes only is ok with a note", errs.call("pr", pr.call("docs: x (sweep #5)", "Closes #6\n")).empty? && notes.call("pr", pr.call("docs: x (sweep #5)", "Closes #6\n")) == ["no-title-ref"]
check "neither is an error", errs.call("pr", pr.call("x を直す", "本文。\n")) == ["issue-link"]
check "title and closes disagree", errs.call("pr", pr.call("x (#1)", "Closes #2\n")) == ["issue-mismatch"]
check "mismatch points at the closes line", doc.call("pr", pr.call("x (#1)", "本文。\n\nCloses #2\n")).errors.first.line == 5
check "title among several closes is ok", errs.call("pr", pr.call("x (#1)", "Closes #1\nCloses #2\n")).empty?
check "number followed by digits is whole", errs.call("pr", pr.call("x (#7)", "Closes #70\n")) == ["issue-mismatch"]
check "trailing spaces after closes are ok", errs.call("pr", pr.call("x (#7)", "Closes #7  \n")).empty?
check "other repository closes is not compared", errs.call("pr", pr.call("x (#1)", "Closes owner/repo#2\n")).empty?
check "other repository closes alone is not a link", errs.call("pr", pr.call("x", "Closes owner/repo#2\n")) == ["issue-link"]
check "the title line is not read for closes", errs.call("pr", pr.call("Closes #3", "本文。\n")) == ["issue-link"]
check "title ref must be at the end", errs.call("pr", pr.call("(#3) x", "本文。\n")) == ["issue-link"]
check "title ref allows trailing spaces", errs.call("pr", pr.call("x (#3)  ", "本文。\n")).empty?
check "bom before the title is ignored", errs.call("pr", "\u{FEFF}" + pr.call("x (#3)")).empty?

# Markdown を解釈しない: 決まった形の行は code block の中でも数え、形の外の keyword は note になる (#663 の review)。
check "closes in a code block still counts", errs.call("pr", pr.call("x (#1)", "```\nCloses #2\n```\n")) == ["issue-mismatch"]
check "closes in a code block still links", errs.call("pr", pr.call("x", "```\nCloses #2\n```\n")).empty?
# 決まった形の外 (行の先頭でない、別の keyword、後ろに文字がある) は紐付けにならず、note で知らせる。
%w[close closed fix fixes fixed resolve resolves resolved].each do |kw|
  check "keyword #{kw} alone is not a link", errs.call("pr", pr.call("x", "#{kw} #7\n")) == ["issue-link"]
  check "keyword #{kw} is a loose note", loose.call("x", "#{kw} #7\n")
end
{
  "lowercase closes" => "closes #7\n",
  "uppercase CLOSES" => "CLOSES #7\n",
  "closes with a colon" => "Closes: #7\n",
  "closes in a list item" => "- Closes #7\n",
  "indented closes" => "    Closes #7\n",
  "tab-indented closes" => "\tCloses #7\n",
  "closes with trailing text" => "Closes #7 と直す\n",
  "two numbers on one line" => "Closes #7, #8\n",
  "closes in inline code" => "`Closes #7` と書く\n",
  "closes in html code" => "<code>Closes #7</code>\n",
  "closes in a sentence" => "この PR は fixes #7 です。\n",
}.each do |label, body|
  check "#{label} is not a link", errs.call("pr", pr.call("x", body)) == ["issue-link"]
  check "#{label} is a loose note", loose.call("x", body)
end
check "keyword inside a word is not a note", !loose.call("x", "enclosed #7\n")
check "placeholder number is not a note", !loose.call("x (#1)", "本文に `Closes #<番号>` を書く。\n")
check "loose note points at the first line", doc.call("pr", pr.call("x (#1)", "本文。\n- Closes #2\n- fixes #3\n")).findings.find { |f| f.rule == "loose-closing" }.line == 4
check "strict line is not a loose note", !loose.call("x (#1)", "Closes #1\n")
# round 2 の例 (WM004・WM005): どちらも誤った exit にならず、note になる。
wm004 = pr.call("x (#1)", "- 項目\n\n  続き\n\n    Closes #2\n")
check "WM004 example is ok with a note", errs.call("pr", wm004).empty? && loose.call("x (#1)", "- 項目\n\n  続き\n\n    Closes #2\n")
wm005_body = "- ```text\n  Closes #2\n  ```\n\nCloses #1\n"
check "WM005 example is ok with a note", errs.call("pr", pr.call("x (#1)", wm005_body)).empty? && loose.call("x (#1)", wm005_body)
begin
  doc.call("pr", "x (#1)\n本文が 2 行目\n")
  check "non-empty second line raises", false
rescue WorkMarkerCheck::InputError
  check "non-empty second line raises", true
end
begin
  doc.call("pr", "\n\nCloses #1\n")
  check "empty title raises", false
rescue WorkMarkerCheck::InputError
  check "empty title raises", true
end

# --- CLI
o, e, s = cli.call(%w[--kind review-result --stdin], ok_result)
check "cli ok exits 0", s.exitstatus == 0 && o.end_with?("work-marker-check: review-result: ok (markers v4)\n") && e.empty?
canary = "CANARY-本文-#{Process.pid}"
bad = result.call(heading.sub("（", "("), canary, verdict.call("APPROVE"), summary.call(1, 0, 0))
o, e, s = cli.call(%w[--kind review-result --stdin], bad)
check "cli errors exit 1", s.exitstatus == 1 && o.include?("[result-heading]") && o.include?("[verdict-mismatch]") && o.include?("2 error(s)")
check "cli output does not echo the input", !o.include?(canary) && !e.include?(canary)
o, e, s = cli.call(%w[--stdin --kind escape-issue], "元の PR: #1\n")
check "option order does not matter", s.exitstatus == 0
o, e, s = cli.call(%w[--kind pr --stdin], "x (#1)\n\n本文。\n")
check "notes do not fail", s.exitstatus == 0 && o.include?("note: [no-closes]")
[[[], "no args"], [%w[--stdin], "no kind"], [%w[--kind pr], "no stdin"], [%w[--kind other --stdin], "unknown kind"],
 [%w[--kind --stdin], "kind without value"], [%w[--kind pr --kind pr --stdin], "kind twice"],
 [%w[--kind pr --stdin extra], "extra arg"], [%w[--kind pr --stdin --json], "unknown option"]].each do |(args, label)|
  o, e, s = cli.call(args, "x (#1)\n")
  check "usage: #{label}", s.exitstatus == 2 && e.start_with?("usage:") && o.empty?
end
o, e, s = cli.call(%w[--kind pr --stdin], "x (#1)\n本文\n")
check "cli non-empty second line exits 2", s.exitstatus == 2 && e.start_with?("work-marker-check: error:") && o.empty?
o, e, s = cli.call(%w[--kind escape-issue --stdin], "元の PR: #1\n" + ("a" * WorkMarkerCheck::MAX_INPUT_BYTES))
check "cli over the size limit exits 2", s.exitstatus == 2 && e.include?("byte を超える")
o, e, s = cli.call(%w[--kind escape-issue --stdin], "元の PR: #1\n\xff".b)
check "cli invalid utf-8 exits 2", s.exitstatus == 2 && e.include?("UTF-8")
o, e, s = cli.call(%w[--kind review-result --stdin], "")
check "cli empty input reports missing lines", s.exitstatus == 1 && o.include?("5 error(s)")
o, e, s = cli.call(%w[--kind pr --stdin], "")
check "cli empty pr input exits 2", s.exitstatus == 2 && e.start_with?("work-marker-check: error:")
o, e, s = cli.call(%w[--kind review-result --stdin], ok_result + ("a" * (WorkMarkerCheck::MAX_INPUT_BYTES - ok_result.bytesize)))
check "cli input of exactly the limit is read", s.exitstatus == 0
o, e, s = cli.call(%w[--kind review-result --stdin], ok_result, { "LC_ALL" => "C", "LANG" => "C" })
check "C locale works", s.exitstatus == 0

exit(@failed.zero? ? 0 : 1)
RUBY

# 何も書かない: 入力の directory の中身 (mode と hash) が実行の前後で変わらない。
mkdir "$tmp/in"
printf '元の PR: #1\n' > "$tmp/in/t.md"
before=$(tree_snapshot "$tmp/in")
(cd "$tmp/in" && ruby "$src" --kind escape-issue --stdin < t.md > /dev/null)
(cd "$tmp/in" && ruby "$src" --kind pr --stdin < t.md > /dev/null) || true
after=$(tree_snapshot "$tmp/in")
[ "$before" = "$after" ] || fail "script changed the input directory"

echo "ok: work-marker-check-test"
