#!/bin/sh
# personal-maintenance-sweep の fix モードの、push の前の public-safety の gate を検査する (#383)。
# - FIX.md の「## 検証 (累積差分に対して)」の節にある gate の command (sh の code block) が、累積差分・`base`
#   以降の全 commit の message (`git log --format=%B "$base".."$branch"`)・PR の題名と本文を gate の入力にしている。
#   git の command は cwd の HEAD ではなく fix の branch の ref を基準にする (#419。main の checkout から走らせても
#   累積差分が空にならない)。
#   gate は RECORD.md の Issue の gate と同じ deploy 先。review の修正で commit を足したときに、追加の push の
#   前に検証と gate をやり直すことが書いてある。
# - 入口経由: 切り出した command を temp repo で実際に走らせる。差分・commit の message (最後の commit でない
#   ものを含む)・題名・本文のどれか 1 つにだけある値で止まり (exit 1)、clean なら exit 0、材料の git が失敗
#   したら exit 0 にならない (fail-closed)。gate は偽の HOME に置いた repo の gate で、止める値は偽の HOME の
#   local pattern file に置く。
# - SKILL.md の fix モードの要約 (7b) と evals.json の verify-then-publish が commit の message を挙げている。
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。
# 実 HOME / 実 git config には触れない (gate の command は偽の HOME で走らせ、git は GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を隔離する)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

sweep_dir=${1:-"$repo_root/shared/skills/personal-maintenance-sweep"}
gate_src="$repo_root/shared/scripts/personal-public-safety-gate.rb"
[ -f "$gate_src" ] || fail "missing $gate_src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- 文書の検査と、gate の command の切り出し ------------------------------------
ruby - "$sweep_dir" "$tmp/gate-block.sh" <<'RUBY'
require "json"

sweep_dir, out = ARGV.fetch(0), ARGV.fetch(1)
errors = []

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

fix = File.read(File.join(sweep_dir, "FIX.md"))
record = File.read(File.join(sweep_dir, "RECORD.md"))
block = nil
verify = section(fix, "## 検証 (累積差分に対して)")
if verify.nil?
  errors << "FIX.md に「## 検証 (累積差分に対して)」の節が無い"
else
  gated = sh_blocks(verify).select { |b| b.include?('"$gate" --stdin') }
  if gated.size != 1
    errors << "検証の節に gate (\"$gate\" --stdin) の sh の block が 1 つでない (#{gated.size} 個)"
  else
    block = gated.first
    record_gate = record.lines.find { |l| l.start_with?("gate=") }
    if record_gate.nil?
      errors << "RECORD.md に gate の deploy 先の行 (gate=…) が無い"
    elsif !block.lines.include?(record_gate)
      errors << "検証の節の gate が RECORD.md の Issue の gate と同じ deploy 先でない"
    end
    # gate に渡す入力は、block の "$gate" --stdin より前 (deploy 先の行を除く)。
    input = block[0...block.index('"$gate" --stdin')].lines.reject { |l| l.start_with?("gate=") }.join
    errors << "公開前の gate に pipe で入力を渡していない" unless input.rstrip.end_with?("|")
    {
      'git diff "$base" "$branch"' => "累積差分",
      'git log --format=%B "$base".."$branch"' => "base 以降の全 commit の message",
      '"$title"' => "PR の題名",
      '"$body_file"' => "PR の本文",
    }.each do |needle, what|
      errors << "公開前の gate の入力が「#{what}」(#{needle}) を含まない" unless input.include?(needle)
    end
    errors << "gate の block が cwd の HEAD を基準にしている (main の checkout から走らせると累積差分が空になる。#419)" if block =~ /\bHEAD\b/
    # PR の作成は cwd の今の branch に頼らない (main の checkout から続けても fix の branch の PR にする。#419 F4)。
    errors << "FIX.md の PR の作成が --head \"$branch\" を明示していない" unless fix.include?(%q{gh pr create --head "$branch"})
    # review の preflight は cwd の local HEAD を PR の head と照合するので、worktree で走らせる (#419 F5)。
    errors << "FIX.md の review が worktree ($fixdir) での実行を指定していない" unless fix.include?("review の依頼から executor の起動までは、worktree (`$fixdir`) を cwd にして")
    # 比べる側は保存した base に固定した worktree で走らせ、main の checkout を使わない (#419 F6)。
    errors << "FIX.md の比べる側が base に固定した worktree ($basedir) を作っていない" unless fix.include?(%q{--detach "$basedir" "$base"})
    errors << "FIX.md の比べる側が main の checkout を使っている (再開で main が進むと base からずれる)" if fix.include?("main の checkout (`base`)")
    # fixdir と basedir は fixes.json に保存しないので、再開では run_id と Issue 番号から導出する (#419 F8)。
    errors << "FIX.md の再開が fixdir と basedir を run_id と Issue 番号から導出していない" unless fix.include?("`fixdir` と `basedir` は保存せず、記録の `run_id` と Issue 番号から導出します")
    errors << "FIX.md の再開が保存していない fixdir を fixes.json から戻すと書いている" if fix.include?("`fixdir` を `fixes.json` から戻して")
    if block =~ /\bgit push\b|\bgh\s/
      errors << "gate の block に push / gh がある (test で走らせられない。push と PR は block の外に書く)"
      block = nil
    end
  end
  unless verify.include?("追加の push の前")
    errors << "検証の節に、review の修正で commit を足したときの追加の push の前のやり直しが書かれていない"
  end
end

skill = File.read(File.join(sweep_dir, "SKILL.md"))
summary = section(skill, "### 7b. 修正する (fix モードだけ)")
if summary.nil?
  errors << "SKILL.md に「### 7b. 修正する (fix モードだけ)」の節が無い"
elsif !summary.include?("commit の message")
  errors << "SKILL.md の fix モードの要約が、public-safety の gate の対象に commit の message を挙げていない"
end

evals = JSON.parse(File.read(File.join(sweep_dir, "evals", "evals.json")))
assertion = evals.fetch("evals", []).flat_map { |e| e["assertions"] || [] }
  .find { |a| a["id"] == "verify-then-publish" }
if assertion.nil?
  errors << "evals.json に assertion verify-then-publish が無い"
elsif !assertion["text"].to_s.include?("commit の message")
  errors << "evals.json の verify-then-publish が commit の message を挙げていない"
end

abort "FAIL: maintenance-sweep-fix-gate\n  " + errors.join("\n  ") unless errors.empty?
File.write(out, block)
RUBY

# ---- 入口経由: 切り出した command を temp repo で走らせる --------------------------
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile /dev/null
# repository を選ぶ環境変数が継承されていると、temp repo でなくそちらを読む。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# 偽の HOME の deploy 先に repo の gate を置き、止める値を local pattern file に置く。
home="$tmp/home"
gate_bin="$home/.claude/agent-tools/scripts/personal-public-safety-gate"
mkdir -p "$(dirname "$gate_bin")" "$home/.config/agent-tools"
cp "$gate_src" "$gate_bin"
chmod +x "$gate_bin"
marker=sweep-fix-gate-marker
printf '%s\n' "$marker" > "$home/.config/agent-tools/public-safety-patterns.local"

repo="$tmp/repo"
git init -q "$repo"
printf 'base\n' > "$repo/doc.md"
git -C "$repo" add doc.md
git -C "$repo" commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)

title_clean='docs: clean (sweep #1)'
title_dirty="docs: $marker (sweep #1)"
printf 'clean body\n' > "$tmp/body-clean.md"
printf 'body %s\n' "$marker" > "$tmp/body-dirty.md"

# base の上に fix の commit を作り直す。$1 = doc.md に足す行、残りの引数 = commit ごとの message の本文の行
# (1 つ目が最初の commit。2 つ目以降は空の commit を重ねる)。
make_fix() {
  git -C "$repo" checkout -q -B sweep/fix-1 "$base"
  printf '%s\n' "$1" >> "$repo/doc.md"
  shift
  git -C "$repo" commit -q -a -m 'docs: fix (sweep #1)' -m "$1"
  shift
  for mf_msg in "$@"; do
    git -C "$repo" commit -q --allow-empty -m 'docs: review (sweep #1)' -m "$mf_msg"
  done
}

# 切り出した command を $shell_argv で走らせ、exit code を rc に、出力を $tmp/out に入れる。
# $1 = base、$2 = 題名、$3 = 本文の file。
run_block() {
  rc=0
  # shell_argv は下の case で決めた定数 (sh / zsh -f) なので、分割して渡す。
  # shellcheck disable=SC2086
  (cd "$repo" && env -u BASH_ENV -u ENV HOME="$home" base="$1" branch=sweep/fix-1 title="$2" body_file="$3" \
    $shell_argv "$tmp/gate-block.sh") > "$tmp/out" 2>&1 || rc=$?
}

blocked() {
  [ "$rc" -eq 1 ] && grep -q '^public-safety-gate: blocked: stdin:' "$tmp/out"
}

ran=0
for shell in sh zsh; do
  command -v "$shell" > /dev/null 2>&1 || continue
  case $shell in
    zsh) shell_argv='zsh -f' ;;
    *) shell_argv=sh ;;
  esac
  ran=$((ran + 1))

  # (a) どこにも値が無ければ通る。
  make_fix 'clean line' 'clean message'
  run_block "$base" "$title_clean" "$tmp/body-clean.md"
  [ "$rc" -eq 0 ] || fail "[$shell] clean な入力で gate の command が exit 0 でない (rc=$rc): $(cat "$tmp/out")"

  # (b) commit の message にだけ値がある。
  make_fix 'clean line' "worktree: $marker"
  run_block "$base" "$title_clean" "$tmp/body-clean.md"
  blocked || fail "[$shell] commit の message にだけある値で止まらない (公開前の gate が commit の message を含まない。rc=$rc)"

  # (c) 最後でない commit の message にだけ値がある (base 以降の全 commit を見る)。
  make_fix 'clean line' "worktree: $marker" 'clean review message'
  run_block "$base" "$title_clean" "$tmp/body-clean.md"
  blocked || fail "[$shell] 最後でない commit の message にある値で止まらない (公開前の gate が base 以降の全 commit の message を含まない。rc=$rc)"

  # (d) 累積差分にだけ値がある (最後の commit でない差分を含む)。
  make_fix "line $marker" 'clean message' 'clean review message'
  run_block "$base" "$title_clean" "$tmp/body-clean.md"
  blocked || fail "[$shell] 累積差分にだけある値で止まらない (rc=$rc)"

  # (e) PR の題名にだけ値がある。
  make_fix 'clean line' 'clean message'
  run_block "$base" "$title_dirty" "$tmp/body-clean.md"
  blocked || fail "[$shell] PR の題名にだけある値で止まらない (rc=$rc)"

  # (f) PR の本文にだけ値がある。
  run_block "$base" "$title_clean" "$tmp/body-dirty.md"
  blocked || fail "[$shell] PR の本文にだけある値で止まらない (rc=$rc)"

  # (h) main の checkout (HEAD = base) から走らせても、fix の branch の差分と message で止まる (#419)。
  make_fix 'clean line' "message $marker"
  git -C "$repo" checkout -q --detach "$base"
  run_block "$base" "$title_clean" "$tmp/body-clean.md"
  blocked || fail "[$shell] HEAD が base の checkout から走らせると、branch の commit の message にある値で止まらない (rc=$rc)"

  # (g) 材料の git が失敗したら (base が無い)、gate が残りだけを読んで exit 0 にならない。
  run_block 0000000000000000000000000000000000000001 "$title_clean" "$tmp/body-clean.md"
  [ "$rc" -ne 0 ] || fail "[$shell] 材料の git が失敗しても gate の command が exit 0 になる (fail-open)"
done
[ "$ran" -gt 0 ] || fail "gate の command を走らせる shell (sh / zsh) が無い"

echo "ok: maintenance-sweep-fix-gate"
