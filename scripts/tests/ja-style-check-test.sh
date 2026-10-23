#!/bin/sh
# personal-ja-style-check.rb の self-test (#556)。
# 規則 (Document) は require して直接、CLI は ruby で起動して確かめる。長さの閾値は script の定数から fixture を
# 組み立てるので、閾値を変えても test は変えない。network access なし。何も書かないことは tree_snapshot で確かめる。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-ja-style-check.rb"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp" <<'RUBY'
require "json"
require "open3"
src, tmp = ARGV
require src

doc = ->(text) { JaStyleCheck::Document.new(text) }
findings = ->(text) { doc.call(text).findings }
rules = ->(text) { findings.call(text).map(&:rule) }

l_min = JaStyleCheck::LONG_SENTENCE
run_n = JaStyleCheck::LONG_RUN
v_min = JaStyleCheck::VERY_LONG_SENTENCE
neg_n = JaStyleCheck::NEGATION_RUN
max_bytes = JaStyleCheck::MAX_INPUT_BYTES
check "thresholds are usable", l_min >= 2 && v_min > l_min && run_n >= 2 && neg_n >= 2

# 長さは文末の「。」を含む (空白は含まない)。"あ" * (l_min - 1) + "。" で長さ l_min。
long = "あ" * (l_min - 1) + "。"
short_edge = "あ" * (l_min - 2) + "。"

# --- em-dash
check "em-dash fires on U+2014", rules.call("前の文 — 後の文。") == ["em-dash"]
check "em-dash line number", findings.call("一行目。\n二行目 ― 続き。").first.line == 2
check "em-dash severity warn", findings.call("a — b。").first.severity == "warn"
check "U+2013 and U+2500 fire", rules.call("a – b。\nc ─ d。") == %w[em-dash em-dash]
check "consecutive dashes are one finding", rules.call("a —— b。") == ["em-dash"]
check "ASCII hyphen does not fire", rules.call("a - b。--json も見ない。").empty?
check "em-dash in inline code ignored", rules.call("`a — b` は見ない。").empty?
check "em-dash in html code ignored", rules.call("<code>a — b</code> は見ない。").empty?
check "em-dash in fenced code ignored", rules.call("```\n— x\n```\n").empty?
check "em-dash in tilde fence ignored", rules.call("~~~\n— x\n~~~\n").empty?
check "fence closes only with same char", rules.call("```\n~~~\n— x\n```\n").empty?
check "em-dash after fence fires", rules.call("```\nx\n```\na — b。").size == 1
check "em-dash in URL ignored", rules.call("http://example.com/a—b を見る。").empty?
check "URL ends at Japanese punctuation", rules.call("参照: http://x.example/a。" + ("できない。" * 3)) == ["negation-run"] && doc.call("参照: http://x.example/a。" + ("できない。" * 3)).stats["sentences"] == 4
check "URL ends before an opening bracket", doc.call("http://x.example/a（補足）。").stats["masked_spans"] == 1 && doc.call("http://x.example/a（補足）。").stats["chars"] == 6
check "fenced code inside a quote is ignored", rules.call("> ```\n> a — b\n> ```\n").empty?
check "em-dash after a quoted fence fires", rules.call("> ```\n> x\n> ```\n> a — b。").size == 1
check "unquoted fence is not closed by a quoted fence line", rules.call("```\n> ```\n— x\n```\n").empty?
check "heading inside a quote is not a sentence", rules.call("> ## " + "あ" * (v_min + 1)).empty?
check "table inside a quote is not a sentence", rules.call("> | " + "あ" * (v_min + 1) + " |").empty?
check "em-dash in heading fires", rules.call("## 見出し — 続き") == ["em-dash"]
check "em-dash in table fires", rules.call("| a — b |") == ["em-dash"]

# --- bold-label
check "bullet bold label with colon", rules.call("- **判断**: 中身。") == ["bold-label"]
check "numbered bold label", rules.call("1. **判断**: 中身。") == ["bold-label"]
check "task box bold label", rules.call("- [ ] **判断**: 中身。") == ["bold-label"]
check "fullwidth colon", rules.call("- **判断**： 中身。") == ["bold-label"]
check "line-start bold label with colon", rules.call("**判断**: 中身。") == ["bold-label"]
check "bullet bold lead without colon", rules.call("- **判断** 中身。") == ["bold-label"]
check "bullet that is only a bold label", rules.call("- **判断**") == ["bold-label"]
check "html bold counts as bold", rules.call("- <b>判断</b>: 中身。") == ["bold-label"]
check "whole-line bold with colon inside does not fire", rules.call("**Review process verdict: APPROVE**").empty?
check "bold inside a sentence does not fire", rules.call("これは **強調** を含む文。").empty?
check "line-start bold without colon does not fire", rules.call("**強調** から始まる文。").empty?
check "bold label in fenced code ignored", rules.call("```\n- **判断**: x\n```\n").empty?
check "bold label in heading does not fire", rules.call("## **判断**: x").empty?
check "bold-label line number", findings.call("文。\n\n- **判断**: 中身。").first.line == 3
check "bold-label severity warn", findings.call("- **判断**: 中身。").first.severity == "warn"

# --- sentences and long-run
check "long-run fires at run_n long sentences", rules.call(([long] * run_n).join) == ["long-run"]
check "long-run not at run_n - 1", rules.call(([long] * (run_n - 1)).join).empty?
check "sentence just below the threshold is short", rules.call(([short_edge] * run_n).join).empty?
check "long-run across lines in a paragraph", rules.call(([long] * run_n).join("\n")) == ["long-run"]
check "long-run across bullet lines", rules.call(([long] * run_n).map { |s| "- #{s}" }.join("\n")) == ["long-run"]
check "long-run resets at blank line", rules.call(([long] * (run_n - 1)).join("\n") + "\n\n" + long).empty?
check "long-run resets at heading", rules.call(([long] * (run_n - 1)).join("\n") + "\n## 見出し\n" + long).empty?
check "heading inside a quote resets the run", rules.call(([long] * (run_n - 1)).map { |s| "> #{s}" }.join("\n") + "\n> ## 見出し\n> " + long).empty?
check "quoted sentences still form a run", rules.call(([long] * run_n).map { |s| "> #{s}" }.join("\n")) == ["long-run"]
check "long-run resets at fenced code", rules.call(([long] * (run_n - 1)).join("\n") + "\n```\nx\n```\n" + long).empty?
check "short sentence breaks the run", rules.call(([long] * (run_n - 1)).join + "短い。" + long).empty?
check "long-run reports first sentence line", findings.call("短い。\n" + ([long] * run_n).join("\n")).first.line == 2
check "long-run message has the lengths", findings.call(([long] * run_n).join).first.message.include?(([l_min] * run_n).join(", "))
check "longer run is one finding", rules.call(([long] * (run_n + 2)).join) == ["long-run"]
check "long-run severity warn", findings.call(([long] * run_n).join).first.severity == "warn"
check "inline code counts as one char", rules.call(("`" + "x" * 300 + "`。") * run_n).empty?
check "placeholder counts as one char", doc.call("`abc`。").stats["chars"] == 2 && doc.call("<code>abc</code> と http://x.example/ 。").stats["chars"] == 4
check "placeholder counts toward the threshold", rules.call(("あ" * (l_min - 2) + "`xx`。") * run_n) == ["long-run"] && rules.call(("あ" * (l_min - 3) + "`xx`。") * run_n).empty?
check "list marker and bold marks are not counted", rules.call(("- **" + "あ" * (l_min - 2) + "**。\n") * run_n).empty?
check "quote marker is not counted", rules.call(("> " + short_edge + "\n") * run_n).empty?
check "whitespace is not counted", rules.call((("あ " * (l_min - 2)) + "。") * run_n).empty?
check "link text counts and url is masked", rules.call("[" + "あ" * (v_min + 1) + "](http://x.example/—)") == ["long-sentence"]
check "relative link keeps only the text", rules.call("[" + "あ" * (v_min - 1) + "](notes.md)").empty? && rules.call("[" + "あ" * (v_min - 1) + "](#section)").empty?
check "relative link text at the threshold fires", rules.call("[" + "あ" * v_min + "](notes.md)") == ["long-sentence"]

# --- long-sentence
check "long-sentence fires", rules.call("あ" * v_min + "。") == ["long-sentence"]
check "long-sentence fires at exactly the threshold", rules.call("あ" * (v_min - 1) + "。") == ["long-sentence"]
check "long-sentence not just below", rules.call("あ" * (v_min - 2) + "。").empty?
check "link syntax is not counted", rules.call("[" + "あ" * (v_min - 5) + "](http://x.example/—)").empty?
check "long-sentence message has the length", findings.call("あ" * v_min + "。").first.message.include?("(#{v_min + 1} 字)")
check "bullet without terminator is a sentence", rules.call("- " + "あ" * v_min) == ["long-sentence"]
check "exclamation and question terminate", doc.call("あ！い？う。え!お?").stats["sentences"] == 5
check "heading is not a sentence", rules.call("## " + "あ" * v_min).empty?
check "table row is not a sentence", rules.call("| " + "あ" * v_min + " |").empty?
check "long-sentence line number", findings.call("短い。\n\n" + "あ" * v_min + "。").first.line == 3

# --- negation-run
neg = "それは正しくない。"
check "negation-run fires", rules.call(([neg] * neg_n).join) == ["negation-run"]
check "negation-run not at neg_n - 1", rules.call(([neg] * (neg_n - 1)).join).empty?
check "ません counts", rules.call((["できません。"] * neg_n).join) == ["negation-run"]
check "closing bracket before the period is allowed", rules.call((["できない)。"] * neg_n).join) == ["negation-run"]
check "positive sentence breaks the run", rules.call(([neg] * (neg_n - 1)).join + "できる。" + neg).empty?
check "negation-run resets at blank line", rules.call(([neg] * (neg_n - 1)).join + "\n\n" + neg).empty?
check "negation-run reports first line", findings.call("肯定。\n" + ([neg] * neg_n).join("\n")).first.line == 2
check "negation-run message has the count", findings.call(([neg] * neg_n).join).first.message.include?("#{neg_n} 文")
check "負けない in the middle is not an ending", rules.call((["負けないで進む。"] * neg_n).join).empty?

# --- idiom
check "idiom 側に倒す", rules.call("安全側に倒す。") == ["idiom"]
check "idiom conjugation", rules.call("安全側に倒して進む。") == ["idiom"]
check "idiom severity info", findings.call("安全側に倒す。").first.severity == "info"
check "idiom message names the idiom", findings.call("安全側に倒す。").first.message.include?("「〜側に倒す」")
check "idiom 黙って無視", rules.call("黙って無視される。") == ["idiom"]
check "idiom 黙って捨てる", rules.call("黙って捨てる。") == ["idiom"]
check "idiom 前提が崩れる", rules.call("前提が崩れる。") == ["idiom"]
check "倒す alone is not an idiom", rules.call("木を倒す。").empty?
check "黙って alone is not an idiom", rules.call("黙って待つ。").empty?
check "idiom in inline code ignored", rules.call("`安全側に倒す` と書く。").empty?

# --- structure and encoding
check "html tags are stripped", rules.call("<p>" + "あ" * (v_min - 2) + "。</p>").empty?
check "CRLF line numbers", findings.call("一。\r\n二 — 三。\r\n").first.line == 2
check "findings sorted by line", findings.call("あ" * v_min + "。\na — b。").map(&:rule) == %w[long-sentence em-dash]
check "empty text has no findings", findings.call("").empty? && doc.call("").stats["sentences"] == 0

st = doc.call("短い。長い文です。").stats
check "stats sentences and chars", st["sentences"] == 2 && st["chars"] == 9
check "stats keys", %w[lines sentences chars mean_length max_length cv long_sentences negation_endings masked_spans scrubbed].all? { |k| st.key?(k) }
check "stats masked_spans", doc.call("`a` と <code>b</code> と http://x.example/ 。").stats["masked_spans"] == 3
check "stats long_sentences and negation_endings", doc.call(long + "できない。").stats.values_at("long_sentences", "negation_endings") == [1, 1]
check "stats lines", doc.call("a\nb\n").stats["lines"] == 3

# --- CLI
cli = ->(args, stdin = "", env = {}) { Open3.capture3(env, "ruby", src, *args, stdin_data: stdin) }

o, e, s = cli.call(["--stdin"], "- **判断**: 中身 — 続き。\n")
check "cli stdin exit 0 with findings", s.exitstatus == 0 && e.empty?
check "cli text has one line per finding and a summary", o.lines.size == 3 && o.lines.last == "ja-style-check: 2 finding(s) in 1 input(s)\n"
check "cli text format", o.lines.first.start_with?("-:1: [bold-label] ") && o.lines.first.include?(" | ")
o, e, s = cli.call(["--stdin"], "問題ない文。\n")
check "cli exit 0 without findings", s.exitstatus == 0 && o == "ja-style-check: 0 finding(s) in 1 input(s)\n"

o, e, s = cli.call(["--json", "--stdin"], "a — b。")
j = JSON.parse(o)
check "json top level", s.exitstatus == 0 && j["tool"] == "personal-ja-style-check" && j["version"] == JaStyleCheck::VERSION && j["inputs"].size == 1
check "json input name and finding keys", j["inputs"][0]["name"] == "-" && j["inputs"][0]["findings"][0].keys.sort == %w[line message rule severity snippet]
check "json stats", j["inputs"][0]["stats"]["sentences"] == 1
check "json is one line", o.lines.size == 1
check "json keeps non-ascii", o.include?("ダッシュ")

f1 = File.join(tmp, "a.md")
File.write(f1, "a — b。\n")
f2 = File.join(tmp, "b.md")
File.write(f2, "良い文。\n")
o, e, s = cli.call(["--json", f1, f2])
j = JSON.parse(o)
check "multiple files", s.exitstatus == 0 && j["inputs"].map { |i| i["name"] } == [f1, f2]
check "findings per file", j["inputs"][0]["findings"].size == 1 && j["inputs"][1]["findings"].empty?
check "text output names the file", cli.call([f1])[0].start_with?("#{f1}:1: [em-dash]")
check "option order does not matter", cli.call([f1, "--json"])[2].exitstatus == 0 && JSON.parse(cli.call([f1, "--json"])[0])["inputs"].size == 1

check "no args is usage (2)", cli.call([])[2].exitstatus == 2
check "usage text", cli.call([])[1].start_with?("usage: personal-ja-style-check")
check "stdin plus file is usage (2)", cli.call(["--stdin", f1])[2].exitstatus == 2
r = cli.call(["--foo", f1])
check "unknown option is usage (2)", r[2].exitstatus == 2 && r[1].start_with?("usage:")
r = cli.call(["-"])
check "bare dash is usage (2)", r[2].exitstatus == 2 && r[1].start_with?("usage:")
check "usage prints nothing on stdout", cli.call([])[0].empty?

o, e, s = cli.call([File.join(tmp, "none.md")])
check "missing file (2)", s.exitstatus == 2 && e.start_with?("ja-style-check: error:") && o.empty?
o, e, s = cli.call([tmp])
check "directory (2)", s.exitstatus == 2 && e.start_with?("ja-style-check: error:")
big = File.join(tmp, "big.md")
File.write(big, "a" * (max_bytes + 1))
check "over the size limit (2)", cli.call([big])[2].exitstatus == 2
edge = File.join(tmp, "max.md")
File.write(edge, "a" * max_bytes)
check "exactly the size limit is ok", cli.call([edge])[2].exitstatus == 0
check "stdin over the size limit (2)", cli.call(["--stdin"], "a" * (max_bytes + 1))[2].exitstatus == 2
check "one bad file stops the run (2)", cli.call([f1, File.join(tmp, "none.md")])[2].exitstatus == 2

bad = File.join(tmp, "bad.md")
File.binwrite(bad, "a \xff b — c。\n".b)
o, e, s = cli.call(["--json", bad])
j = JSON.parse(o)
check "invalid utf-8 is scrubbed and flagged", s.exitstatus == 0 && j["inputs"][0]["stats"]["scrubbed"] == true
check "invalid utf-8 still checks", j["inputs"][0]["findings"].map { |f| f["rule"] } == ["em-dash"]
check "valid utf-8 is not flagged", JSON.parse(cli.call(["--json", f1])[0])["inputs"][0]["stats"]["scrubbed"] == false

o, e, s = cli.call(["--stdin"], "a — b。", { "LC_ALL" => "C", "LANG" => "C" })
check "C locale works", s.exitstatus == 0 && o.include?("[em-dash]")
ja = File.join(tmp, "試験.md")
File.write(ja, "a — b。\n")
o, e, s = cli.call([ja], "", { "LC_ALL" => "C", "LANG" => "C" })
check "C locale with a non-ascii file name (text)", s.exitstatus == 0 && o.start_with?("#{ja}:1: [em-dash]")
o, e, s = cli.call(["--json", ja], "", { "LC_ALL" => "C", "LANG" => "C" })
check "C locale with a non-ascii file name (json)", s.exitstatus == 0 && JSON.parse(o)["inputs"][0]["name"] == ja
o, e, s = cli.call([File.join(tmp, "無い.md")], "", { "LC_ALL" => "C", "LANG" => "C" })
check "C locale error message for a non-ascii file name", s.exitstatus == 2 && e.start_with?("ja-style-check: error:")
o, e, s = cli.call(["\xff.md".b])
check "invalid utf-8 argv does not crash", s.exitstatus == 2 && e.start_with?("ja-style-check: error:")
o, e, s = cli.call(["-\xff".b])
check "invalid utf-8 option is usage (2)", s.exitstatus == 2 && e.start_with?("usage:")
check "display_name keeps valid utf-8", JaStyleCheck.display_name("試験.md") == "試験.md"
check "display_name replaces invalid bytes", JaStyleCheck.display_name("\xff.md".b.force_encoding(Encoding::UTF_8)) == "�.md"

exit(@failed.zero? ? 0 : 1)
RUBY

# 何も書かない: 入力の directory の中身 (mode と hash) が実行の前後で変わらない。
mkdir "$tmp/in"
printf 'a — b。\n- **x**: y\n' > "$tmp/in/t.md"
before=$(tree_snapshot "$tmp/in")
ruby "$src" "$tmp/in/t.md" > /dev/null
ruby "$src" --json "$tmp/in/t.md" > /dev/null
after=$(tree_snapshot "$tmp/in")
[ "$before" = "$after" ] || fail "script changed the input directory"

echo "ok: ja-style-check-test"
