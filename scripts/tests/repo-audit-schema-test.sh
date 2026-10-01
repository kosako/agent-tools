#!/bin/sh
# personal-repo-audit の findings.schema.json を検査する (#347 PR 2)。
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

# strict の前提を再帰で確かめる。
walk = lambda do |node, path|
  case node["type"]
  when "object"
    errors << "#{path}: additionalProperties が false でない" unless node["additionalProperties"] == false
    props = (node["properties"] || {}).keys.sort
    req = (node["required"] || []).sort
    errors << "#{path}: required #{req} が properties #{props} と一致しない" unless props == req
    (node["properties"] || {}).each { |k, v| walk.call(v, "#{path}.#{k}") }
  when "array"
    walk.call(node["items"] || {}, "#{path}[]")
  end
end
walk.call(schema, "$")

# REPORT-FORMAT.md の「所見の欄」の表から、欄の値の集合を読む (2 列目を " / " で分ける)。
table_values = lambda do |label|
  row = format.lines.find { |l| l.start_with?("| #{label} |") }
  next nil unless row
  row.split("|")[2].strip.split(" / ").map(&:strip)
end
finding = schema.dig("properties", "findings", "items", "properties") || {}
{ "種別" => "kind", "深刻度" => "severity", "確度" => "confidence" }.each do |label, key|
  expected = table_values.call(label)
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
