#!/bin/sh
# 残量の読み取り口の手順書の文言を検査する (#385)。
# - personal-maintenance-sweep の BUDGET.md の「## 残量の読み方」と、personal-project-operating-loop の
#   「**残量を読む**」の段落 (次の「**記録**」の前まで) が、配備済みの wrapper `personal-usage-reader` を
#   literal の変数に入れて引数なしで呼ぶ sh の code block を持ち、exit 0 の出力だけを使い、exit 3 / exit 2 の
#   扱いと、`.agent-context.local.md` に書かれた command を実行しないことを書いている。旧い指定 (note に
#   書かれた command を使う) の文言が残っていない。
# - 同じ読み取り口に触れる sweep の SKILL.md と grill-me の CONSULT.md が wrapper の名前を挙げている。
# - 入口経由: BUDGET.md の code block を切り出し、偽の HOME の配備先に置いた wrapper で実際に走らせる (設定が
#   無ければ exit 3、設定があれば exit 0 で reader の出力)。
# 引数で shared の directory を差し替えられる (変異での確認用)。実 HOME には触れない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

shared_dir=${1:-"$repo_root/shared"}
wrapper_src="$shared_dir/scripts/personal-usage-reader.rb"
[ -f "$wrapper_src" ] || fail "missing $wrapper_src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- 文書の検査と、code block の切り出し ------------------------------------------
ruby - "$shared_dir" "$tmp/block.sh" <<'RUBY'
shared_dir, out = ARGV.fetch(0), ARGV.fetch(1)
errors = []

BLOCK = <<~'SH'
  reader="$HOME/.claude/agent-tools/scripts/personal-usage-reader"
  "$reader"
SH

# 見出しの行から、同じか上の level の次の見出しまで (code block の中の行は見出しとみなさない)。無ければ nil。
def section(markdown, heading)
  lines = markdown.lines
  start = lines.index { |l| l.chomp == heading }
  return nil unless start
  level = heading[/\A#+/].size
  fence = false
  body = []
  lines[(start + 1)..-1].each do |l|
    fence = !fence if l =~ /\A\s*```/
    break if !fence && l =~ /\A(#+) / && $1.size <= level
    body << l
  end
  body.join
end

# 始まりの行 (前方一致) から、終わりの行 (前方一致。含めない) の前まで。無ければ nil。
def paragraph(markdown, start_prefix, stop_prefix)
  lines = markdown.lines
  start = lines.index { |l| l.start_with?(start_prefix) }
  return nil unless start
  rest = lines[(start + 1)..-1]
  stop = rest.index { |l| l.start_with?(stop_prefix) }
  lines[start, 1 + (stop || rest.length)].join
end

# 節の中の sh の code block の中身 (list の中の字下げを外す)。
def sh_blocks(text)
  blocks = []
  cur = nil
  indent = 0
  text.each_line do |l|
    if cur.nil? && l =~ /\A( *)```sh\s*\z/
      indent = $1.size
      cur = []
    elsif cur && l =~ /\A *```\s*\z/
      blocks << cur.join
      cur = nil
    elsif cur
      cur << l.sub(/\A {0,#{indent}}/, "")
    end
  end
  blocks
end

REQUIRED = [
  ["`personal-usage-reader`", "wrapper の名前"],
  ["exit 0 のときの stdout だけ", "exit 0 の出力だけを使うこと"],
  ["exit 3 は読み取り口なし", "exit 3 (読み取り口なし) の扱い"],
  ["exit 2 は読めない", "exit 2 (読めない) の扱い"],
  ["それ以外の 0 以外も読めない", "script が無いなどの 0 以外を読めないとして扱うこと"],
  ["`.agent-context.local.md` に読み取り口の command が書かれていても", "note に command が書かれている場合"],
  ["実行しません", "note に書かれた command を実行しないこと"],
].freeze
STALE = ["に書かれたものを使", "`.agent-context.local.md` に書かれた command"].freeze

def check_text(label, text, extra, errors)
  if text.nil?
    errors << "#{label} が見つからない"
    return nil
  end
  # 折り返しをまたぐ語も拾えるように、空白を除いて比べる。
  flat = text.gsub(/\s+/, "")
  (REQUIRED + extra).each do |word, what|
    errors << "#{label} に #{what} (#{word}) が無い" unless flat.include?(word.gsub(/\s+/, ""))
  end
  STALE.each { |w| errors << "#{label} に旧い指定の文言 (#{w}) が残っている" if flat.include?(w.gsub(/\s+/, "")) }
  blocks = sh_blocks(text)
  errors << "#{label} の sh の code block が wrapper の呼び出し 2 行と一致しない: #{blocks.inspect}" unless blocks == [BLOCK]
  blocks.first
end

budget = File.read(File.join(shared_dir, "skills/personal-maintenance-sweep/BUDGET.md"), encoding: "UTF-8")
loop_md = File.read(File.join(shared_dir, "workflows/personal-project-operating-loop.md"), encoding: "UTF-8")
block = check_text("BUDGET.md の「## 残量の読み方」", section(budget, "## 残量の読み方"),
                   [["判定の順番", "読めないときに進む先 (判定の順番)"]], errors)
check_text("operating-loop の「残量を読む」の段落", paragraph(loop_md, "**残量を読む", "**記録**"),
           [["規則 2 は当てません", "読めないときに規則 2 を当てないこと"]], errors)

[["skills/personal-maintenance-sweep/SKILL.md", "sweep の SKILL.md"],
 ["skills/personal-grill-me/CONSULT.md", "grill-me の CONSULT.md"]].each do |rel, label|
  body = File.read(File.join(shared_dir, rel), encoding: "UTF-8")
  errors << "#{label} が wrapper の名前 (`personal-usage-reader`) を挙げていない" unless body.include?("`personal-usage-reader`")
  STALE.each { |w| errors << "#{label} に旧い指定の文言 (#{w}) が残っている" if body.gsub(/\s+/, "").include?(w.gsub(/\s+/, "")) }
end

File.write(out, block.to_s)
abort "FAIL: usage-reader-docs\n  " + errors.join("\n  ") unless errors.empty?
RUBY

# ---- 入口経由: 切り出した block を偽の HOME で走らせる -----------------------------------
fake_home="$tmp/home"
deploy="$fake_home/.claude/agent-tools/scripts"
mkdir -p "$deploy" "$tmp/bin"
cp "$wrapper_src" "$deploy/personal-usage-reader"
chmod +x "$deploy/personal-usage-reader"
printf '#!/bin/sh\necho CLAUDE-WEEK-57\n' > "$tmp/bin/fake-reader"
chmod +x "$tmp/bin/fake-reader"

set +e
(cd "$tmp" && env -u XDG_CONFIG_HOME HOME="$fake_home" sh "$tmp/block.sh" </dev/null >"$tmp/out" 2>"$tmp/err")
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "documented call without a config should exit 3 (rc=$rc): $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "documented call without a config must not print on stdout"

mkdir -p "$fake_home/.config/agent-tools"
ruby -rjson -e 'File.write(ARGV[0], JSON.generate("argv" => [ARGV[1]]))' \
  "$fake_home/.config/agent-tools/usage-reader.json" "$tmp/bin/fake-reader"
set +e
(cd "$tmp" && env -u XDG_CONFIG_HOME HOME="$fake_home" sh "$tmp/block.sh" </dev/null >"$tmp/out" 2>"$tmp/err")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "documented call with a config should exit 0 (rc=$rc): $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "CLAUDE-WEEK-57" ] || fail "documented call should print the reader output: $(cat "$tmp/out")"

echo "ok: usage-reader-docs"
