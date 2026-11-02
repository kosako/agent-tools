#!/bin/sh
# personal-maintenance-sweep の `upstream` の単位 (参照元の pin の検査, #623) の手順の self-test。
# SKILL.md・REFUTE.md・RECORD.md・BUDGET.md が、単位の足し方・script の出力の扱い・反証にかけないこと・確かめられない
# ときに止めないことを、それぞれ句として書いているかを見る (改行と行頭の空白は詰めて比べる)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sweep="$script_dir/../../shared/skills/personal-maintenance-sweep"

exec ruby - "$sweep" <<'RUBY'
dir = ARGV.fetch(0)
squash = ->(s) { s.gsub(/\n[ \t]*/, "") }
read = ->(name) { squash.call(File.read(File.join(dir, name), encoding: "UTF-8")) }

want = {
  "SKILL.md" => [
    "参照元の pin の後の更新は `personal-upstream-pin-check` で読むだけ (手順 3 の `upstream` の単位)",
    "HEAD の commit に `.github/upstream-pins.json` がある repo では、AI を使わない `upstream` の単位 (観点 `upstream` × 領域 `.github/upstream-pins.json`) を 1 つ足します (#623)",
    "fix の入口 (b) の run は監査をしないので、どちらも足しません",
    "配備済みの `personal-upstream-pin-check`",
    "参照元の本文は読まない",
    "Codex の session では `pending` のまま残し、Claude Code の session の再開でかける",
    "反証にかけず、所見を confirmed として単位を `refuted` にし、手順 5 から他の単位と同じく進める",
    "所見なしで `done` にし、報告に「参照元を確かめられない」と理由 (stderr) を書く。sweep は止めない",
    "exit と stderr は state の単位の `upstream_check` に残す",
    "手順 3 の `ci` と `upstream` の単位は監査の結果に含まれないので、反証の前に足してかける",
    "`ci` と `upstream` の単位は監査で Codex を起動しないので記録が無く、`pending` なら手順 3 のとおり script をかけ直す",
    "| 参照元を確かめられない (`personal-upstream-pin-check` が無い、exit 2 で stdout が空、stdout が所見の JSON の形でない) | sweep は止めない。`upstream` の単位を所見なしで `done` にし、報告に理由を書く |",
  ],
  "REFUTE.md" => [
    "`upstream` の単位の所見 (`SKILL.md` 手順 3。参照元の blob の hash の比較) は入力に入れない",
  ],
  "RECORD.md" => [
    "`upstream` の単位は personal-upstream-pin-check の stdout",
    "personal-upstream-pin-check の結果 (`exit` は exit code、`stderr` は全文)",
    "所見は反証にかけないので、保存したら単位は `refuted` になる",
    "「## 反証」の節は、検証役と判定の 2 行の代わりに",
    "`- 反証: 省略 (AI の判断を含まない決まった規則の検査。personal-upstream-pin-check)`",
  ],
  "BUDGET.md" => [
    "AI を使わない `upstream` の単位も 1 つ加わります (#623)",
    "(プリセットの推定 ÷ 単位の数。`ci` と `upstream` の単位は数えない)",
  ],
}

errors = []
want.each do |name, clauses|
  body = read.call(name)
  clauses.each { |c| errors << "#{name} に句が無い: #{c}" unless body.include?(squash.call(c)) }
end

if errors.empty?
  puts "ok: maintenance-sweep-upstream"
else
  errors.each { |e| warn "FAIL: #{e}" }
  exit 1
end
RUBY
