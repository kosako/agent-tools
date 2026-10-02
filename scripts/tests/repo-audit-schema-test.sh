#!/bin/sh
# personal-repo-audit の findings.schema.json を検査する (#347 PR 2)。
# - 形: root から各欄までの key と型が、下の SHAPE (sweep が読む契約) と一致する。
# - strict な structured output の前提: どの object も additionalProperties: false で、全 key が required。
#   Codex の --output-schema は、これが崩れた schema を受け付けない。
# - 値の集合 (種別 / 深刻度 / 確度) が REPORT-FORMAT.md の表と一致する (正本は REPORT-FORMAT.md)。
# 引数で skill の directory を差し替えられる (変異での確認用)。既定は repo の shared/skills/personal-repo-audit。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
skill_dir=${1:-"$script_dir/../../shared/skills/personal-repo-audit"}
ruby -r "$script_dir/lib/schema_shape" - "$skill_dir" <<'RUBY'
require "json"

dir = ARGV.fetch(0)
schema = JSON.parse(File.read(File.join(dir, "findings.schema.json")))
format = File.read(File.join(dir, "REPORT-FORMAT.md"))

# 期待する形。object は key => 子の形の Hash、array は [要素の形]、葉は型の名前。
strings = ->(*keys) { keys.to_h { |k| [k, "string"] } }
SHAPE = {
  "summary" => "string",
  "findings" => [
    strings.call("id", "fingerprint", "dimension", "kind", "severity", "confidence",
                 "claim", "evidence", "impact", "recommendation", "decision_reason")
      .merge("locations" => ["string"], "needs_decision" => "boolean"),
  ],
  "not_problems" => [strings.call("location", "apparent_issue", "reason")],
  "decisions" => [strings.call("finding_id", "question")],
  "scope" => strings.call("uncommitted", "prescan")
    .merge("seen" => ["string"], "partial" => ["string"], "not_seen" => ["string"]),
}.freeze

errors = SchemaShape.check(schema, SHAPE)

finding = schema.dig("properties", "findings", "items", "properties")
finding = {} unless finding.is_a?(Hash)
{ "種別" => "kind", "深刻度" => "severity", "確度" => "confidence" }.each do |label, key|
  expected = SchemaShape.table_values(format, label)
  actual = finding.dig(key, "enum")
  if expected.nil?
    errors << "REPORT-FORMAT.md に「#{label}」の行が無い"
  elsif actual != expected
    errors << "#{key} の enum #{actual.inspect} が REPORT-FORMAT.md の #{label} #{expected.inspect} と一致しない"
  end
end

abort "FAIL: repo-audit-schema\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: repo-audit-schema"
RUBY
