#!/bin/sh
# personal-maintenance-sweep の refutation.schema.json を検査する (#347 PR 3)。
# - 形と strict な structured output の前提 (lib/schema_shape.rb)。
# - 判定の値が REFUTE.md の 3 つ (confirmed / refuted / uncertain) で、確度の値が repo-audit の
#   REPORT-FORMAT.md の表と一致する (確度の正本は REPORT-FORMAT.md)。
# - REFUTE.md が、反証に渡す所見の ID を単位の番号で振り直し、判定を ID と fingerprint の組で当てる (#425)。
# 引数で sweep と repo-audit の skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sweep_dir=${1:-"$script_dir/../../shared/skills/personal-maintenance-sweep"}
audit_dir=${2:-"$script_dir/../../shared/skills/personal-repo-audit"}
ruby -r "$script_dir/lib/schema_shape" - "$sweep_dir" "$audit_dir" <<'RUBY'
require "json"

sweep_dir, audit_dir = ARGV.fetch(0), ARGV.fetch(1)
schema = JSON.parse(File.read(File.join(sweep_dir, "refutation.schema.json")))
refute = File.read(File.join(sweep_dir, "REFUTE.md"))
format = File.read(File.join(audit_dir, "REPORT-FORMAT.md"))

SHAPE = {
  "verdicts" => [%w[id fingerprint verdict confidence evidence note].to_h { |k| [k, "string"] }],
}.freeze

errors = SchemaShape.check(schema, SHAPE)

verdict = schema.dig("properties", "verdicts", "items", "properties")
verdict = {} unless verdict.is_a?(Hash)
expected_verdicts = %w[confirmed refuted uncertain]
unless verdict.dig("verdict", "enum") == expected_verdicts
  errors << "verdict の enum #{verdict.dig("verdict", "enum").inspect} が #{expected_verdicts.inspect} でない"
end
missing = expected_verdicts.reject { |v| refute.include?("**#{v}**") }
errors << "REFUTE.md の判定の規則に #{missing.inspect} の定義が無い" unless missing.empty?

# 単位をまたぐと所見の ID (報告の中だけの通し番号) が重なるので、反証に渡す前に単位の番号を付けて
# 振り直し、取り込みでは ID と fingerprint の組で当てる (#425)。どちらかの規則が落ちると、別の単位の
# 判定が所見に当たりうる。句は文末の「。」まで含めて、所定の節の中にあることを見る (後ろに否定を足す・
# 節の外へ移すと落ちる)。改行と空白は除いて比べる。
squash = ->(s) { s.gsub(/\s+/, "") }
section = lambda do |title|
  body = refute[/^## #{Regexp.escape(title)}\n(.*?)(?=^## |\z)/m, 1]
  body && squash.call(body)
end
[
  ["反証に渡す所見の ID", "ID の振り直し",
   "反証に渡す前に、所見の ID を単位の番号を前に付けた `U<n>-<元の ID>` に振り直します (例: 単位 3 の `F01` は `U3-F01`)。"],
  ["結果の取り込み", "ID と fingerprint の組", "判定は ID と fingerprint の組で入力の所見に当てる。"],
  ["結果の取り込み", "fingerprint の不一致",
   "ID が入力にあっても fingerprint が入力の所見と違う判定は当てず、その所見は uncertain として扱う。"],
  ["結果の取り込み", "同じ ID の重複",
   "同じ ID に判定が 2 つ以上返ったときも、どれも当てずに uncertain にする (どちらも報告に書く)。"],
].each do |title, label, phrase|
  body = section.call(title)
  if body.nil?
    errors << "REFUTE.md に「#{title}」の節が無い"
  elsif !body.include?(squash.call(phrase))
    errors << "REFUTE.md の「#{title}」の節に#{label}の規則 (#{phrase.inspect}) が無い"
  end
end
expected_id = "入力の所見の ID (単位の番号を付けた U<n>-<元の ID>。例: U3-F01)"
unless verdict.dig("id", "description") == expected_id
  errors << "verdicts の id の description が #{expected_id.inspect} でない (振り直した ID の形)"
end

confidence = SchemaShape.table_values(format, "確度")
if confidence.nil?
  errors << "REPORT-FORMAT.md に「確度」の行が無い"
elsif verdict.dig("confidence", "enum") != confidence
  errors << "confidence の enum #{verdict.dig("confidence", "enum").inspect} が REPORT-FORMAT.md の確度 #{confidence.inspect} と一致しない"
end

abort "FAIL: maintenance-sweep-schema\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: maintenance-sweep-schema"
RUBY
