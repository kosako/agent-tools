#!/bin/sh
# personal-production-rail の索引 (references/policy-index.md) の節の案内が、参照先の本文の見出しに
# 着くことを検査する (#217)。本文は vendored のまま変えず、索引から読む節を案内する方式なので、
# re-import で見出しが変わると案内だけが古くなる。それをここで止める。
# - エントリ (## エントリ の下の ### 見出し) ごとに `**file**` と `**sections(読む節)**` の行がある。
# - sections の行の「」で囲んだ名前は、file の見出し (## / ### …) の名前とちょうど 1 つ一致する。
# - 300 行を超える file の sections には、名前を 1 つ以上挙げる (全体を読ませない)。行は改行の数ではなく
#   行の数で数える (末尾に改行の無い最後の行も 1 行)。300 行 / 301 行 × 末尾の改行の有無の fixture で、
#   この境界を毎回確かめる。
# 文言と構造の検知で、agent が節から読むことの保証ではない。
# 引数で skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

skill_dir=${1:-"$script_dir/../../shared/skills/personal-production-rail"}

# skill の directory の索引を検査する。問題があれば stderr に理由を出して 0 以外で終わる。
check_index() {
  ruby - "$1" <<'RUBY'
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
  # 改行の数ではなく行の数 (末尾に改行の無い最後の行も 1 行と数える)。
  if names.empty? && text.each_line.count > LONG_LINES
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
}

check_index "$skill_dir"

# ---- 行数の境界 -------------------------------------------------------------------------
# sections に節の名前が無い entry 1 つと、n 行の参照先 long.md を持つ skill の directory で、
# 300 行は通り、301 行は落ちることを、末尾の改行の有無の両方で確かめる。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 使い方: boundary <行数> <nl|nonl> <pass|fail>  (nl は末尾に改行を付け、nonl は付けない)
boundary() {
  b_dir="$tmp/$1-$2"
  b_file="$b_dir/references/long.md"
  mkdir -p "$b_dir/references"
  cat > "$b_dir/references/policy-index.md" <<'MD'
# fixture

## エントリ

### long

- **file**: `long.md`
- **sections(読む節)**: 全体を読む。
MD
  ruby -e 'n = Integer(ARGV[0]); s = (1..n).map { |i| "line #{i}" }.join("\n"); s += "\n" if ARGV[1] == "nl"; print s' \
    "$1" "$2" > "$b_file"
  # fixture の形を別の道具で確かめる (wc -l は改行の数、tail -c 1 は最後の byte)。
  b_newlines=$(wc -l < "$b_file" | tr -d ' ')
  b_last=$(tail -c 1 "$b_file" | od -An -tx1 | tr -d ' \n')
  case $2 in
    nl) [ "$b_newlines" -eq "$1" ] && [ "$b_last" = 0a ] || fail "fixture $1-$2 の形が違う (改行 $b_newlines 個、最後の byte $b_last)" ;;
    nonl) [ "$b_newlines" -eq $(($1 - 1)) ] && [ "$b_last" != 0a ] || fail "fixture $1-$2 の形が違う (改行 $b_newlines 個、最後の byte $b_last)" ;;
  esac

  if check_index "$b_dir" > "$tmp/out" 2> "$tmp/err"; then b_rc=0; else b_rc=$?; fi
  case $3 in
    pass)
      [ "$b_rc" -eq 0 ] || fail "$1 行 ($2) の参照先は sections に名前が無くても通るはず: $(cat "$tmp/err")"
      grep -qF "ok: policy-index-sections (1 entries)" "$tmp/out" || fail "$1 行 ($2) の検査が ok を出さない"
      ;;
    fail)
      [ "$b_rc" -ne 0 ] || fail "$1 行 ($2) の参照先は sections に名前が無いと落ちるはず"
      grep -qF "long: long.md は 300 行を超えるのに sections に節の名前が無い" "$tmp/err" ||
        fail "$1 行 ($2) の落ち方が違う: $(cat "$tmp/err")"
      ;;
  esac
}

boundary 300 nl pass
boundary 300 nonl pass
boundary 301 nl fail
boundary 301 nonl fail
echo "ok: policy-index-sections の行数の境界 (4 cases)"
