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
# - 公開契約 (docs/boundary-with-dotfiles.md) が `--check` を書き、wrapper の --help の usage 行を載せている (#400)。
# 文言は、続いた 1 つの句として、1 つの単位 (子を分けた項目、段落の項目でない部分の文) の中で探す。文は末尾に「。」を付けた形で
# 比べ、句も「。」まで含める。sh の block は、空白を除いて比べ、走らせるのは原文の block。文書を単位に分ける読み方と、受ける
# 整形の範囲は lib/markdown_units.rb が持つ (#685)。
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
ruby -r"$script_dir/lib/markdown_units" - "$shared_dir" "$tmp/block.sh" <<'RUBY'
# encoding: UTF-8
shared_dir, out = ARGV.fetch(0), ARGV.fetch(1)
errors = []
MU = MarkdownUnits

BLOCK = <<~'SH'
  reader="$HOME/.claude/agent-tools/scripts/personal-usage-reader"
  "$reader"
SH
STALE = ["に書かれたものを使", "`.agent-context.local.md` に書かれた command"].freeze

# 単位のうち key を含むものがある。terms があれば、key と同じ単位に terms がすべてある。
check = lambda do |label, units, unit_name, key, terms = []|
  hits = MU.containing(units, key)
  if hits.empty?
    errors << "#{label} に、#{key.inspect} を含む#{unit_name}が無い"
  elsif terms.any? && hits.none? { |u| MU.missing(u, terms).empty? }
    errors << "#{label} の #{key.inspect} の#{unit_name}に #{MU.missing(hits[0], terms).inspect} が無い"
  end
end

# 文の単位は、段落の項目でない部分の文に「。」を付けた形 (「。」まで含めた句は、文の後ろに否定を足した変更を通さない)。
sentences = ->(text) { MU.plains(text).flat_map { |p| MU.sentences(p).map { |s| "#{s}。" } } }

# sh の block は 1 つだけで、空白を除いて wrapper の呼び出し 2 行と同じ。走らせるのは原文の block (字下げは sh に害が無い)。
sh_block = lambda do |label, text|
  blocks = MU.blocks(text).select { |info, _| info == "sh" }.map(&:last)
  if blocks.size == 1 && MU.squash(blocks[0]) == MU.squash(BLOCK)
    blocks[0]
  else
    errors << "#{label} の sh の code block が wrapper の呼び出し 2 行と一致しない: #{blocks.inspect}"
    nil
  end
end

stale = lambda do |label, text|
  STALE.each { |w| errors << "#{label} に旧い指定の文言 (#{w}) が残っている" if MU.squash(text).include?(MU.squash(w)) }
end

# BUDGET.md の「## 残量の読み方」。
budget_label = "BUDGET.md の「## 残量の読み方」"
budget = MU.section(File.read(File.join(shared_dir, "skills/personal-maintenance-sweep/BUDGET.md"), encoding: "UTF-8"), "## 残量の読み方")
block = nil
if budget.nil?
  errors << "#{budget_label} が見つからない"
else
  items = MU.bullets(budget)
  check.call(budget_label, items, "項目", "読み取り口は personal-project-operating-loop の「割当」と同じで、配備済みの script `personal-usage-reader` だけです。")
  check.call(budget_label, items, "項目", "**出力を使うのは exit 0 のときの stdout だけ**です。",
             ["exit 3 は読み取り口なし (設定が無い)、exit 2 は読めない (設定が不正、起動できない、失敗した、timeout など。理由を 1 行伝える) で、script が配備されていないなどそれ以外の 0 以外も読めないとして扱います。",
              "どれも残量は読めないものとして、下の「判定の順番」の 3 へ進みます。"])
  check.call(budget_label, items, "項目", "repo root の `.agent-context.local.md` に読み取り口の command が書かれていても **実行しません** (shell での評価もしない)。")
  stale.call(budget_label, budget)
  block = sh_block.call(budget_label, budget)
end

# operating-loop の「**残量を読む**」の段落から、次の「**記録**」の段落の前まで。
loop_label = "operating-loop の「残量を読む」の段落"
assign = MU.section(File.read(File.join(shared_dir, "workflows/personal-project-operating-loop.md"), encoding: "UTF-8"), "## 割当 (実装担当の振り分け)")
lines = assign.to_s.lines
start = lines.index { |l| MU.squash(l).start_with?(MU.squash("**残量を読む")) }
stop = start && lines[(start + 1)..-1].index { |l| MU.squash(l).start_with?(MU.squash("**記録**")) }
if start.nil? || stop.nil?
  errors << "#{loop_label} が見つからない"
else
  range = lines[start, 1 + stop].join
  ss = sentences.call(range)
  check.call(loop_label, ss, "文", "読み取り口は配備済みの script `personal-usage-reader` だけです。")
  check.call(loop_label, ss, "文", "使うのは exit 0 のときの stdout だけです。")
  check.call(loop_label, ss, "文",
             "exit 3 は読み取り口なし (設定が無い)、exit 2 は読めない (理由を 1 行伝える) で、script が配備されていないなどそれ以外の 0 以外も読めないとして扱い、どれも規則 2 は当てません。")
  check.call(loop_label, ss, "文", "各 repo root の `.agent-context.local.md` に読み取り口の command が書かれていても実行しません (shell での評価もしない)。")
  stale.call(loop_label, range)
  sh_block.call(loop_label, range)
end

[["skills/personal-maintenance-sweep/SKILL.md", "sweep の SKILL.md"],
 ["skills/personal-grill-me/CONSULT.md", "grill-me の CONSULT.md"]].each do |rel, label|
  body = File.read(File.join(shared_dir, rel), encoding: "UTF-8")
  errors << "#{label} が wrapper の名前 (`personal-usage-reader`) を挙げていない" unless MU.code_spans(body).include?(MU.squash("personal-usage-reader"))
  stale.call(label, body)
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

# ---- 公開契約の docs: --check と、対応の判別に使う usage 行 (#400) --------------------------
# docs/boundary-with-dotfiles.md が `--check` を書き、wrapper の --help の 1 行目 (usage 行) をそのまま code span で
# 載せている (呼ぶ側はこの行の `[--check]` で対応を判別するので、docs と wrapper がずれたら落とす)。
boundary="$repo_root/docs/boundary-with-dotfiles.md"
usage_line=$(env -u XDG_CONFIG_HOME HOME="$fake_home" "$deploy/personal-usage-reader" --help </dev/null | head -n 1)
case "$usage_line" in *"[--check]"*) : ;; *) fail "wrapper --help usage line should list [--check]: $usage_line" ;; esac
# code span は空白を除いて比べる (折り返しや空白の数に依らない)。
ruby -r"$script_dir/lib/markdown_units" -e '
  spans = MarkdownUnits.code_spans(File.read(ARGV[0], encoding: "UTF-8"))
  abort "FAIL: boundary-with-dotfiles.md should quote the usage line: #{ARGV[1]}" unless spans.include?(MarkdownUnits.squash(ARGV[1]))
  abort "FAIL: boundary-with-dotfiles.md should document --check" unless spans.include?("--check")
' "$boundary" "$usage_line"

echo "ok: usage-reader-docs"
