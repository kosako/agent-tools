#!/bin/sh
# personal-grill-with-docs の書き込み先の規則が文書に残っていることを検査する (#386)。
# 文言の検知で、振る舞いの保証ではない (この skill は対話型で evals は自動で走らない。期待挙動は
# evals.json の case 5)。
# - SKILL.md の「書き込み先の規則」の節に、repo の中に収まること・symlink を拒むこと・書き込む時点で
#   確かめることなどの語がある (節の外にだけ語があっても規則として読まれないので、節に範囲を絞る)。
# - CONTEXT.md の inline 更新とファイル構成の節、CONTEXT-FORMAT.md の判定、ADR-FORMAT.md の遅延作成と
#   採番が、その節を参照している。
# 引数で skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
skill_dir=${1:-"$script_dir/../../shared/skills/personal-grill-with-docs"}
ruby - "$skill_dir" <<'RUBY'
skill_dir = ARGV.fetch(0)

RULE = "書き込み先の規則".freeze
REF = "「#{RULE}」".freeze
FORMAT_REF = "SKILL.md の#{REF}".freeze
H1 = /\A# /.freeze
H2 = /\A## /.freeze
H2_OR_H3 = /\A###? /.freeze

# [file, 節の名前, 始まりの行, 終わりの行, 節にあるべき語]。始まりの行は範囲に含め、終わりの行
# (始まりの次の行から探す) は含めない。終わりが無ければ file の末尾まで。
TARGETS = [
  ["SKILL.md", "規則の節", /\A## #{RULE}\s*\z/, H2,
   ["data", "正規化", "repo の中に収まる", "絶対 path", "書き込む時点", "symlink", "regular file",
    "親 directory", "解決した先が repo の中でも", "1 行"]],
  ["SKILL.md", "CONTEXT.md の inline 更新の節", /\A### CONTEXT\.md を inline 更新\s*\z/, H2_OR_H3, [REF]],
  ["SKILL.md", "ファイル構成の節", /\A## ファイル構成\s*\z/, H2, [REF]],
  ["CONTEXT-FORMAT.md", "判定", /\A判定:\s*\z/, H2, [FORMAT_REF]],
  ["ADR-FORMAT.md", "遅延作成の段落", H1, H2, [FORMAT_REF]],
  ["ADR-FORMAT.md", "採番の節", /\A## 採番\s*\z/, H2, [FORMAT_REF]],
].freeze

def section(lines, start_re, stop_re)
  first = lines.index { |l| l =~ start_re }
  return nil if first.nil?
  rest = lines[(first + 1)..-1]
  stop = rest.index { |l| l =~ stop_re }
  lines[first, 1 + (stop || rest.length)]
end

errors = []
TARGETS.each do |rel, label, start_re, stop_re, words|
  path = File.join(skill_dir, rel)
  unless File.file?(path)
    errors << "#{rel}: file が無い"
    next
  end
  lines = section(File.read(path, encoding: "UTF-8").split("\n"), start_re, stop_re)
  if lines.nil?
    errors << "#{rel}: #{label} (#{start_re.source}) が見つからない"
    next
  end
  # 折り返しの位置で落ちないよう、空白と改行を除いて比べる。
  body = lines.join("\n").gsub(/\s+/, "")
  missing = words.reject { |w| body.include?(w.gsub(/\s+/, "")) }
  next if missing.empty?
  errors << "#{rel}: #{label}に書き込み先の規則の語 #{missing.inspect} が無い"
end

abort "FAIL: grill-docs-write-target\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: grill-docs-write-target"
RUBY
