#!/bin/sh
# personal-production-rail の索引 (references/policy-index.md) の節の案内が、参照先の本文の見出しに
# 着くことを検査する (#217)。本文は vendored のまま変えず、索引から読む節を案内する方式なので、
# re-import で見出しが変わると案内だけが古くなる。それをここで止める。
# - エントリ (## エントリ の下の ### 見出し) ごとに `**file**` と `**sections(読む節)**` の行がある。
# - sections の行の「」で囲んだ名前は、file の見出し (## / ### …) の名前とちょうど 1 つ一致する。
# - 300 行を超える file の sections には、名前を 1 つ以上挙げる (全体を読ませない)。
# 文言と構造の検知で、agent が節から読むことの保証ではない。
# 引数で skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
skill_dir=${1:-"$script_dir/../../shared/skills/personal-production-rail"}
ruby - "$skill_dir" <<'RUBY'
refs = File.join(ARGV.fetch(0), "references")
index_path = File.join(refs, "policy-index.md")
abort "FAIL: policy-index-sections\n  policy-index.md が無い: #{index_path}" unless File.file?(index_path)

LONG_LINES = 300
SECTIONS_KEY = "**sections(読む節)**".freeze

lines = File.read(index_path, encoding: "UTF-8").split("\n")
first = lines.index { |l| l =~ /\A## エントリ\s*\z/ }
abort "FAIL: policy-index-sections\n  「## エントリ」の節が無い" if first.nil?
rest = lines[(first + 1)..-1]
stop = rest.index { |l| l =~ /\A## / }
body = rest[0, stop || rest.length]

# ### 見出しごとにエントリへ分ける。
entries = []
body.each do |l|
  if l =~ /\A### (\S+)\s*\z/
    entries << [$1, []]
  elsif !entries.empty?
    entries.last[1] << l
  end
end

# "- **key**: …" の bullet を、字下げした継続行ごと 1 つの文字列にする。
def bullet(entry_lines, key)
  start = entry_lines.index { |l| l.start_with?("- #{key}") }
  return nil if start.nil?
  text = [entry_lines[start]]
  entry_lines[(start + 1)..-1].each do |l|
    break unless l =~ /\A {2,}\S/
    text << l.strip
  end
  text.join(" ")
end

errors = []
errors << "エントリが 1 つも無い" if entries.empty?
entries.each do |name, entry_lines|
  file_line = bullet(entry_lines, "**file**")
  rel = file_line && file_line[/`([^`]+)`/, 1]
  if rel.nil?
    errors << "#{name}: **file** の行が無い"
    next
  end
  path = File.join(refs, rel)
  unless File.file?(path)
    errors << "#{name}: file が無い: #{rel}"
    next
  end
  sections = bullet(entry_lines, SECTIONS_KEY)
  if sections.nil?
    errors << "#{name}: #{SECTIONS_KEY} の行が無い"
    next
  end
  text = File.read(path, encoding: "UTF-8")
  headings = text.split("\n").map { |l| l[/\A\#{2,6} (.+?)\s*\z/, 1] }.compact
  names = sections.scan(/「([^」]+)」/).flatten
  if names.empty? && text.count("\n") > LONG_LINES
    errors << "#{name}: #{rel} は #{LONG_LINES} 行を超えるのに sections に節の名前が無い"
  end
  names.uniq.each do |n|
    hits = headings.count(n)
    errors << "#{name}: 「#{n}」は #{rel} の見出しに無い" if hits.zero?
    errors << "#{name}: 「#{n}」は #{rel} の見出しに #{hits} 個ある (どの節か決まらない)" if hits > 1
  end
end

abort "FAIL: policy-index-sections\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: policy-index-sections (#{entries.length} entries)"
RUBY
