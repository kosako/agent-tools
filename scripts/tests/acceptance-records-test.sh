#!/bin/sh
# 受け入れの記録 (docs/acceptance-records.md) を doctor が読んで今の engine の版と比べる規則 (#725) の self-test。
# Issue #725 の期待値の表の行を見る。版は PATH の上の偽の CLI (claude / codex / herdr) で固定し、実の CLI には触れない。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 偽の CLI: FAKE_<NAME>_OUT を 1 行目に出し、FAKE_<NAME>_RC で終わる。FAKE_<NAME>_SLEEP があれば先に待つ
mkdir -p "$tmp/bin"
for name in claude codex herdr; do
  up=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  cat > "$tmp/bin/$name" <<EOF
#!/bin/sh
[ -z "\${FAKE_${up}_SLEEP:-}" ] || sleep "\$FAKE_${up}_SLEEP"
[ -z "\${FAKE_${up}_OUT+x}" ] || printf '%s\n' "\$FAKE_${up}_OUT"
exit "\${FAKE_${up}_RC:-0}"
EOF
  chmod +x "$tmp/bin/$name"
done

ruby -r"$script_dir/lib/check_helper" - "$repo_root/scripts/lib/acceptance_records.rb" "$tmp/bin" "$repo_root/docs/acceptance-records.md" <<'RUBY'
load ARGV[0]
A = AcceptanceRecords
ENV["PATH"] = "#{ARGV[1]}:/usr/bin:/bin"
HEAD = "## 記録\n\n| 項目 | engine | agent-tools | dotfiles | 日時 | 根拠 |\n| --- | --- | --- | --- | --- | --- |\n"
GOOD = {
  "hook-claude" => "| hook-claude | claude-code 2.1.332 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |",
  "hook-codex" => "| hook-codex | codex 0.171.0 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |",
  "worker-run" => "| worker-run | codex 0.171.0; herdr 0.9.5 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |",
  "notify" => "| notify | claude-code 2.1.332; herdr 0.9.5 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |",
  "resume" => "| resume | claude-code 2.1.332; codex 0.171.0; herdr 0.9.5 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |",
}.freeze
NOW = { "claude-code" => "2.1.332", "codex" => "0.171.0", "herdr" => "0.9.5" }.freeze

def doc(rows)
  HEAD + rows.map { |r| r + "\n" }.join
end

def run(text, now = NOW)
  rows, problems = A.parse(text)
  [A.evaluate(rows, ->(e) { now[e] }), problems]
end
def line_for(result, item)
  result.find { |_, m| m.start_with?("#{item} ") }
end

r, p = run(doc([]))
check("01 空の表は全項目が not recorded", r.map(&:last) == A::ITEMS.keys.map { |i| "#{i} not recorded" } && p.empty?)
check("02 表の無い本文は nil (doctor は 1 行の warn)", A.parse("# x\n\n本文\n").nil? && A.parse("## 記録\n\n本文\n").nil?)
check("02 見出しの行が違う表も nil", A.parse("## 記録\n\n| 項目 | engine |\n| --- | --- |\n").nil?)
check("02 記録の節の直下に表が無ければ、次の節の表は読まない", A.parse("## 記録\n\n## 次の節\n\n" + HEAD.sub("## 記録\n\n", "")).nil?)
r, _ = run(doc(GOOD.values_at("hook-claude", "hook-codex", "worker-run", "resume")))
check("03 1 項目の行だけ無ければ、その項目だけ not recorded", line_for(r, "notify") == ["warn", "notify not recorded"] && line_for(r, "hook-claude").first == "ok")
r, p = run(doc(GOOD.values))
check("04 全 engine の版が同じなら ok", r.all? { |l, _| l == "ok" } && p.empty?)
check("04 ok は日時と根拠を出す", line_for(r, "hook-codex") == ["ok", "hook-codex (2026-11-28, #725)"])
r, _ = run(doc(GOOD.values), NOW.merge("codex" => "0.172.0"))
check("05 1 engine の版が違えば unconfirmed で旧と新を出す", line_for(r, "hook-codex") == ["warn", "hook-codex unconfirmed (codex 0.171.0 -> 0.172.0)"])
check("07 複数 engine の行は、変わった engine だけを出す", line_for(r, "worker-run") == ["warn", "worker-run unconfirmed (codex 0.171.0 -> 0.172.0)"])
check("05 変わっていない項目は ok のまま", line_for(r, "notify").first == "ok")
r, _ = run(doc(GOOD.values), NOW.merge("codex" => "0.172.0", "herdr" => "0.9.6"))
check("06 2 engine が違えば両方を出す", line_for(r, "resume") == ["warn", "resume unconfirmed (codex 0.171.0 -> 0.172.0; herdr 0.9.5 -> 0.9.6)"])
r, _ = run(doc([GOOD["hook-codex"].sub("2f57b0a", "abcdef1").sub("1a2b3c4", "0000000")]))
check("08・09 commit だけが違っても比べない (ok)", line_for(r, "hook-codex").first == "ok")
r, _ = run(doc(GOOD.values), NOW.merge("herdr" => nil))
check("10〜12 版を読めない engine は unreadable", line_for(r, "worker-run") == ["warn", "worker-run unconfirmed (herdr version unreadable)"])
r, p = run(doc([GOOD["hook-codex"].sub("codex 0.171.0", "codex v0.171.0")]))
check("15 v を付けた記録は形の異常で、その項目は not recorded", p == ["row 1: engine column must be '<engine> <version>' joined by '; '"] && line_for(r, "hook-codex") == ["warn", "hook-codex not recorded"])
r, _ = run(doc(GOOD.values), NOW.merge("codex" => "0.171.0-alpha.1"))
check("16 接尾辞の違いも別の版", line_for(r, "hook-codex") == ["warn", "hook-codex unconfirmed (codex 0.171.0 -> 0.171.0-alpha.1)"])
r, _ = run(doc([GOOD["worker-run"].sub("codex 0.171.0; herdr 0.9.5", "codex 0.171.0")]))
check("19 記録の engine が足りなければ unconfirmed (組が違う)", line_for(r, "worker-run") == ["warn", "worker-run unconfirmed (engines differ from the item: codex)"])
r, _ = run(doc([GOOD["hook-codex"].sub("codex 0.171.0", "codex 0.171.0; herdr 0.9.5")]))
check("18 記録の engine が余れば unconfirmed (組が違う)", line_for(r, "hook-codex") == ["warn", "hook-codex unconfirmed (engines differ from the item: codex, herdr)"])
bad = {
  "20 版の形" => GOOD["hook-codex"].sub("0.171.0", "0.171"),
  "21 知らない項目" => GOOD["hook-codex"].sub("| hook-codex |", "| hook-x |"),
  "22 列の数" => GOOD["hook-codex"].sub(" #725 |", " #725 | extra |"),
  "24 agent-tools が空" => GOOD["hook-codex"].sub("| 2f57b0a |", "|  |"),
  "24 dotfiles の形" => GOOD["hook-codex"].sub("1a2b3c4", "main"),
  "24 日時の形" => GOOD["hook-codex"].sub("2026-11-28", "11/28"),
  "24 根拠の形" => GOOD["hook-codex"].sub("#725", "725"),
  "同じ engine を 2 回" => GOOD["hook-codex"].sub("codex 0.171.0", "codex 0.171.0; codex 0.171.0"),
}
bad.each do |name, row|
  r, p = run(doc([row, GOOD["hook-claude"]]))
  check("#{name}: 形の異常を 1 つ出し、その行は使わない", p.length == 1 && p.first.start_with?("row 1: ") && line_for(r, "hook-codex") == ["warn", "hook-codex not recorded"])
  check("25 #{name}: 正しいほかの行は比べる", line_for(r, "hook-claude").first == "ok")
end
r, p = run(doc([GOOD["hook-codex"], GOOD["hook-codex"].sub("2026-11-28", "2026-11-29")]))
check("23 同じ項目の 2 行は異常で、どちらも使わない", p == ["item hook-codex has more than one row"] && line_for(r, "hook-codex") == ["warn", "hook-codex not recorded"])
# #810 の review: 2 行目の形が崩れていても、同じ項目の 2 行として数え、1 行目も使わない
r, p = run(doc([GOOD["hook-codex"], GOOD["hook-codex"].sub("0.171.0", "0.171")]))
check("23 2 行目が形の異常でも、同じ項目の 1 行目を使わない", line_for(r, "hook-codex") == ["warn", "hook-codex not recorded"] &&
      p.include?("item hook-codex has more than one row") && p.any? { |x| x.start_with?("row 2: ") })
# #810 の review: 表の途中の | で始まらない行は、形の異常として知らせ、後の行も読む (黙って止めない)
r, p = run(doc([GOOD["hook-claude"], "hook-codex | codex 0.171.0 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |", GOOD["notify"]]))
check("22 表の途中の | で始まらない行は形の異常", p == ["row 2: expected 6 columns"])
check("22 その後の行も読む", line_for(r, "notify").first == "ok" && line_for(r, "hook-codex") == ["warn", "hook-codex not recorded"])
r, p = run(doc([GOOD["hook-codex"], "hook-codex は直した"]))
check("23 | で始まらない行の項目の名前は数えない (形の異常だけ)", line_for(r, "hook-codex").first == "ok" && p == ["row 2: expected 6 columns"])
r, _ = run(doc([GOOD["hook-codex"]]) + "\n| hook-claude | claude-code 2.1.332 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |\n")
check("表は空行で終わる (空行の後の行は読まない)", line_for(r, "hook-claude") == ["warn", "hook-claude not recorded"])
r, _ = run(doc(GOOD.values), NOW.merge("codex" => "0.172.0", "herdr" => nil))
check("26 変わった engine と読めない engine を両方出し、ok にしない", line_for(r, "worker-run") == ["warn", "worker-run unconfirmed (codex 0.171.0 -> 0.172.0; herdr version unreadable)"])
check("28 判定は ok と warn だけ (今の fail と exit を変えない)", (r.map(&:first) - %w[ok warn]).empty?)
r, _ = run(doc(GOOD.values) + "\n## 次の節\n\n| 項目 | engine | agent-tools | dotfiles | 日時 | 根拠 |\n| --- | --- | --- | --- | --- | --- |\n| hook-x | codex 1.0.0 | aaaaaaa | bbbbbbb | 2026-01-01 | #1 |\n")
check("06 読むのは ## 記録 の直後の表だけ", r.all? { |l, _| l == "ok" })

# 今の版の読み方 (偽の CLI)。1 行目の形だけを受け、生の出力は返さない
ENV["FAKE_CLAUDE_OUT"] = "2.1.332 (Claude Code)"
ENV["FAKE_CODEX_OUT"] = "codex-cli 0.171.0"
ENV["FAKE_HERDR_OUT"] = "herdr 0.9.5"
check("版を読む: 3 つの engine", A::ENGINES.keys.map { |e| A.read_version(e) } == %w[2.1.332 0.171.0 0.9.5])
ENV["FAKE_CODEX_OUT"] = "codex-cli 0.171.0-alpha.1"
check("16 版の接尾辞は 1 語に含める", A.read_version("codex") == "0.171.0-alpha.1")
ENV["FAKE_CODEX_OUT"] = "codex-cli v0.171.0"
check("11 形の違う出力は読めない (v 付き)", A.read_version("codex").nil?)
ENV["FAKE_CODEX_OUT"] = "/Users/someone/private/path codex-cli 0.171.0"
check("14 path を含む出力は読めない (生の出力は返さない)", A.read_version("codex").nil?)
ENV["FAKE_CODEX_OUT"] = "codex-cli 0.171.0"
ENV["FAKE_CODEX_RC"] = "3"
check("12 非ゼロで終われば読めない", A.read_version("codex").nil?)
ENV.delete("FAKE_CODEX_RC")
ENV["FAKE_CODEX_OUT"] = "x" * 5000
check("上限の 4 KiB を越える出力は読めない", A.read_version("codex").nil?)
ENV["FAKE_CODEX_OUT"] = "codex-cli 0.171.0\n" + "x" * 5000
check("1 行目が正しくても、上限を越えた出力は読めない", A.read_version("codex").nil?)
ENV["FAKE_CODEX_OUT"] = "codex-cli 0.171.0"
ENV["FAKE_CODEX_SLEEP"] = "30"
t0 = Time.now
check("13 止まらない CLI は期限で読めない", A.read_version("codex").nil? && Time.now - t0 < 15)
ENV.delete("FAKE_CODEX_SLEEP")
ENV["PATH"] = "/usr/bin:/bin"
check("10 CLI が無ければ読めない", A.read_version("herdr").nil?)

# docs の項目の表は ITEMS と同じ (名前、順、engine)
text = File.read(ARGV[2], encoding: "UTF-8")
section = text[/^## 項目\n(.*?)^## /m, 1].to_s
items = section.lines.grep(/\A\| `/).map { |l| c = l.split("|").map(&:strip); [c[1].delete("`"), c[3].split(", ")] }
check("docs の項目の表は ITEMS と同じ", items == A::ITEMS.to_a)
check("docs の記録の表は読める", !A.parse(text).nil?)
exit(@failed.zero? ? 0 : 1)
RUBY

# doctor から: 記録の file の無い --root でも 1 行の warn で exit 0。CLI の無い環境 (CI と同じ) でも exit 0 (27)
mkdir -p "$tmp/repo"
set +e
out=$(env PATH="/usr/bin:/bin:$(dirname "$(command -v ruby)")" "$repo_root/scripts/doctor.sh" --root "$tmp/repo" \
  --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" --agents-home "$tmp/agents" 2>&1)
set -e
# 空の fixture では doctor はほかの検査で fail になるので、exit ではなく acceptance の行の level を見る (28: fail を足さない)
if printf '%s\n' "$out" | grep -q "^fail: acceptance"; then fail "acceptance must not report fail: $out"; fi
printf '%s\n' "$out" | grep -q '^warn: acceptance: cannot read the records table in docs/acceptance-records.md$' \
  || fail "doctor should warn once when the records file is missing: $out"
[ "$(printf '%s\n' "$out" | grep -c '^warn: acceptance:')" -eq 1 ] || fail "only one acceptance line without the file: $out"
mkdir -p "$tmp/repo/docs"
{ printf '## 記録\n\n| 項目 | engine | agent-tools | dotfiles | 日時 | 根拠 |\n| --- | --- | --- | --- | --- | --- |\n'
  printf '| hook-codex | codex 0.171.0 | 2f57b0a | 1a2b3c4 | 2026-11-28 | #725 |\n'; } > "$tmp/repo/docs/acceptance-records.md"
set +e
out=$(env PATH="$tmp/bin:/usr/bin:/bin:$(dirname "$(command -v ruby)")" FAKE_CODEX_OUT="codex-cli 0.172.0" "$repo_root/scripts/doctor.sh" --root "$tmp/repo" \
  --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" --agents-home "$tmp/agents" 2>&1)
set -e
# 空の fixture では doctor はほかの検査で fail になるので、exit ではなく acceptance の行の level を見る (28: fail を足さない)
if printf '%s\n' "$out" | grep -q "^fail: acceptance"; then fail "acceptance must not report fail: $out"; fi
printf '%s\n' "$out" | grep -q '^warn: acceptance: hook-codex unconfirmed (codex 0.171.0 -> 0.172.0)$' \
  || fail "doctor should report the changed codex version: $out"
printf '%s\n' "$out" | grep -q '^warn: acceptance: notify not recorded$' || fail "doctor should report unrecorded items: $out"
echo "acceptance-records-test: ok"
