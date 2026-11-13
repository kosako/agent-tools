#!/bin/sh
# personal-work-marker-check.rb の self-test (#661)。
# 規則 (Document) は require して直接、CLI は ruby で起動して確かめる。fixture は docs/work-markers.md の v1 の形と、
# 実際に投稿した結果コメント (#659) の形から作る。network access なし。何も書かないことは tree_snapshot で確かめる。
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
result = ->(*lines) { lines.join("\n") + "\n" }
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
check "trailing spaces after the marker lines are ok", errs.call("review-result", result.call(heading, verdict.call("APPROVE") + "  ", summary.call(0, 0, 0) + "\t")).empty?

# 雛形 (TEMPLATES.md の結果の block) の 3 行が、検査の形と同じ文字である (雛形を変えたらここで気づく)。
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
check "all three missing", errs.call("review-result", "本文だけ\n").sort == %w[finding-summary result-heading verdict-line]
check "APPROVE with must", errs.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(1, 0, 0))) == ["verdict-mismatch"]
check "Warning with must", errs.call("review-result", result.call(heading, verdict.call("Warning"), summary.call(1, 1, 0))) == ["verdict-mismatch"]
check "APPROVE with should", errs.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(0, 1, 0))) == ["verdict-mismatch"]
check "Warning with nothing", errs.call("review-result", result.call(heading, verdict.call("Warning"), summary.call(0, 0, 1))) == ["verdict-mismatch"]
check "REJECT without must", errs.call("review-result", result.call(heading, verdict.call("REJECT"), summary.call(0, 1, 0))) == ["verdict-mismatch"]
miss = doc.call("review-result", ok_result.sub(verdict.call("APPROVE"), "- #{verdict.call('APPROVE')}")).errors.first
check "missing marker points at the near line", miss.line == 3
check "mismatch points at the verdict line", doc.call("review-result", result.call(heading, verdict.call("APPROVE"), summary.call(1, 0, 0))).errors.first.line == 2

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
check "title ref and closes agree", errs.call("pr", pr.call("x を直す (#12)", "本文。\n\nCloses #12\n")).empty?
check "title ref only is ok with a note", errs.call("pr", pr.call("x (#12)", "本文。\n")).empty? && notes.call("pr", pr.call("x (#12)", "本文。\n")) == ["no-closes"]
check "title only (no body) is ok", errs.call("pr", pr.call("x (#12)")).empty?
check "closes only is ok with a note", errs.call("pr", pr.call("docs: x (sweep #5)", "Closes #6\n")).empty? && notes.call("pr", pr.call("docs: x (sweep #5)", "Closes #6\n")) == ["no-title-ref"]
check "neither is an error", errs.call("pr", pr.call("x を直す", "本文。\n")) == ["issue-link"]
check "title and closes disagree", errs.call("pr", pr.call("x (#1)", "Closes #2\n")) == ["issue-mismatch"]
check "mismatch points at the closes line", doc.call("pr", pr.call("x (#1)", "本文。\n\nCloses #2\n")).errors.first.line == 5
check "title among several closes is ok", errs.call("pr", pr.call("x (#1)", "Closes #1\nCloses #2\n")).empty?
%w[close closes closed fix fixes fixed resolve resolves resolved CLOSES Fixes].each do |kw|
  check "keyword #{kw} is read", errs.call("pr", pr.call("x", "#{kw} #7\n")).empty?
end
check "keyword with a colon is read", errs.call("pr", pr.call("x", "Closes: #7\n")).empty?
check "keyword inside a word is not read", errs.call("pr", pr.call("x", "enclosed #7\n")) == ["issue-link"]
check "number followed by digits is whole", errs.call("pr", pr.call("x (#7)", "Closes #70\n")) == ["issue-mismatch"]
check "closes in inline code is an example", errs.call("pr", pr.call("x", "`Closes #7` と書く\n")) == ["issue-link"]
check "closes in html code is an example", errs.call("pr", pr.call("x", "<code>Closes #7</code>\n")) == ["issue-link"]
check "closes in a code block is an example", errs.call("pr", pr.call("x", "```\nCloses #7\n```\n")) == ["issue-link"]
check "closes after the code block is read", errs.call("pr", pr.call("x", "```\nx\n```\nCloses #7\n")).empty?
check "other repository closes is not compared", errs.call("pr", pr.call("x (#1)", "Closes owner/repo#2\n")).empty?
check "other repository closes alone is not a link", errs.call("pr", pr.call("x", "Closes owner/repo#2\n")) == ["issue-link"]
check "the title line is not read for closes", errs.call("pr", pr.call("Closes #3", "本文。\n")) == ["issue-link"]
check "title ref must be at the end", errs.call("pr", pr.call("(#3) x", "本文。\n")) == ["issue-link"]
check "title ref allows trailing spaces", errs.call("pr", pr.call("x (#3)  ", "本文。\n")).empty?
check "bom before the title is ignored", errs.call("pr", "\u{FEFF}" + pr.call("x (#3)")).empty?
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
check "cli ok exits 0", s.exitstatus == 0 && o.end_with?("work-marker-check: review-result: ok (markers v1)\n") && e.empty?
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
