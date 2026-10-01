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
ruby - "$skill_dir" <<'RUBY'
require "json"

dir = ARGV.fetch(0)
schema = JSON.parse(File.read(File.join(dir, "findings.schema.json")))
format = File.read(File.join(dir, "REPORT-FORMAT.md"))
errors = []

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

# 形と strict の前提を同時に確かめる。
check = lambda do |node, shape, path|
  unless node.is_a?(Hash)
    errors << "#{path}: schema の node が object でない"
    next
  end
  case shape
  when Hash
    errors << "#{path}: type が object でない (#{node["type"].inspect})" unless node["type"] == "object"
    errors << "#{path}: additionalProperties が false でない" unless node["additionalProperties"] == false
    props = node["properties"].is_a?(Hash) ? node["properties"] : {}
    errors << "#{path}: properties #{props.keys.sort} が期待 #{shape.keys.sort} と一致しない" unless props.keys.sort == shape.keys.sort
    req = node["required"].is_a?(Array) ? node["required"].sort : []
    errors << "#{path}: required #{req} が properties #{props.keys.sort} と一致しない" unless req == props.keys.sort
    shape.each { |k, sub| check.call(props[k], sub, "#{path}.#{k}") if props.key?(k) }
  when Array
    errors << "#{path}: type が array でない (#{node["type"].inspect})" unless node["type"] == "array"
    check.call(node["items"], shape.first, "#{path}[]")
  else
    errors << "#{path}: type が #{shape} でない (#{node["type"].inspect})" unless node["type"] == shape
  end
end
check.call(schema, SHAPE, "$")

# REPORT-FORMAT.md の「所見の欄」の表から、欄の値の集合を読む (2 列目を " / " で分ける)。
table_values = lambda do |label|
  row = format.lines.find { |l| l.start_with?("| #{label} |") }
  next nil unless row
  row.split("|")[2].strip.split(" / ").map(&:strip)
end
finding = schema.dig("properties", "findings", "items", "properties") || {}
{ "種別" => "kind", "深刻度" => "severity", "確度" => "confidence" }.each do |label, key|
  expected = table_values.call(label)
  actual = finding.is_a?(Hash) ? finding.dig(key, "enum") : nil
  if expected.nil?
    errors << "REPORT-FORMAT.md に「#{label}」の行が無い"
  elsif actual != expected
    errors << "#{key} の enum #{actual.inspect} が REPORT-FORMAT.md の #{label} #{expected.inspect} と一致しない"
  end
end

abort "FAIL: repo-audit-schema\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: repo-audit-schema"
RUBY
