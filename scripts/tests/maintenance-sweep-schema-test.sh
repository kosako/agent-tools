#!/bin/sh
# personal-maintenance-sweep の refutation.schema.json を検査する (#347 PR 3)。
# - 形と strict な structured output の前提 (lib/schema_shape.rb)。
# - 判定の値が REFUTE.md の 3 つ (confirmed / refuted / uncertain) で、確度の値が repo-audit の
#   REPORT-FORMAT.md の表と一致する (確度の正本は REPORT-FORMAT.md)。
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

confidence = SchemaShape.table_values(format, "確度")
if confidence.nil?
  errors << "REPORT-FORMAT.md に「確度」の行が無い"
elsif verdict.dig("confidence", "enum") != confidence
  errors << "confidence の enum #{verdict.dig("confidence", "enum").inspect} が REPORT-FORMAT.md の確度 #{confidence.inspect} と一致しない"
end

abort "FAIL: maintenance-sweep-schema\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: maintenance-sweep-schema"
RUBY
