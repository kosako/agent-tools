#!/bin/sh
# personal-codex-worker の §9 (回収と trailer 検査と PR) の、push の前の公開する内容の gate を走らせて検査する (#522)。
# - LAUNCH.md の「## 9. 回収 (fetch) と trailer 検査と PR」の節にある gate の command (sh の code block のうち
#   "$gate" --stdin を含むもの) を切り出し、gate の deploy 先の行 (gate=<tool home>/…) を偽の HOME の gate に
#   差し替えて temp repo で走らせる。
# - 直線の範囲で値が無ければ exit 0、累積差分にある値で止まる (exit 1)、範囲に merge commit があれば値が無くても
#   gate に通さずに止まり (exit 1)、理由を gate-publish.err に残す。commit の一覧を取れない (base が無い) ときも
#   exit 0 にならない (fail-closed)。
# 引数で worker の skill の directory を差し替えられる (変異での確認用)。
# 実 HOME / 実 git config には触れない (gate の command は偽の HOME で走らせ、git は GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を隔離する)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

worker_dir=${1:-"$repo_root/shared/skills/personal-codex-worker"}
gate_src="$repo_root/shared/scripts/personal-public-safety-gate.rb"
[ -f "$gate_src" ] || fail "missing $gate_src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
gate_bin="$home/.claude/agent-tools/scripts/personal-public-safety-gate"

# ---- gate の command の切り出し ----------------------------------------------------
ruby - "$worker_dir/LAUNCH.md" "$gate_bin" "$tmp/gate-block.sh" <<'RUBY'
launch, gate_bin, out = ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2)
lines = File.read(launch).lines
start = lines.index { |l| l.start_with?("## 9. ") }
abort "FAIL: codex-worker-publish-gate: LAUNCH.md に「## 9.」の節が無い" unless start
body = []
fence = false
lines[(start + 1)..-1].each do |l|
  fence = !fence if l =~ /\A\s*```/
  break if !fence && l =~ /\A## /
  body << l
end
blocks = []
cur = nil
body.each do |l|
  if cur.nil? && l =~ /\A```sh\s*\z/
    cur = []
  elsif cur && l =~ /\A```\s*\z/
    blocks << cur.join
    cur = nil
  elsif cur
    cur << l
  end
end
gated = blocks.select { |b| b.include?('"$gate" --stdin') }
abort "FAIL: codex-worker-publish-gate: §9 に gate (\"$gate\" --stdin) の sh の block が 1 つでない (#{gated.size} 個)" unless gated.size == 1
block = gated.first
deploy = "gate=<tool home>/agent-tools/scripts/personal-public-safety-gate\n"
abort "FAIL: codex-worker-publish-gate: gate の block の先頭が deploy 先の行でない" unless block.start_with?(deploy)
abort "FAIL: codex-worker-publish-gate: gate の block に push / gh がある (test で走らせられない)" if block =~ /\bgit\b[^\n]*\bpush\b|\bgh\s/
File.write(out, block.sub(deploy, "gate=#{gate_bin}\n"))
RUBY

# ---- 切り出した command を temp repo で走らせる ----------------------------------------
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
mkdir -p "$(dirname "$gate_bin")" "$home/.config/agent-tools"
cp "$gate_src" "$gate_bin"
chmod +x "$gate_bin"
marker=worker-publish-gate-marker
printf '%s\n' "$marker" > "$home/.config/agent-tools/public-safety-patterns.local"

repo="$tmp/repo"
git init -q "$repo"
printf 'base\n' > "$repo/doc.md"
git -C "$repo" add doc.md
git -C "$repo" commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)
branch=codex/issue-1
printf 'clean body\n' > "$tmp/body.md"

# base の上に直線の branch を作る。$1 = doc.md に足す行。
make_linear() {
  git -C "$repo" checkout -q -B "$branch" "$base"
  printf '%s\n' "$1" >> "$repo/doc.md"
  git -C "$repo" commit -q -a -m 'docs: work (#1)'
}

# base の上に merge commit を含む branch を作る。$1 が空でなければ、1 つ目の merge の解決でだけ doc.md にその行を
# 足し、2 つ目の merge の解決で消す (累積差分にも merge でない commit の差分にも残らない)。
make_merge() {
  for mm_side in 1 2; do
    git -C "$repo" checkout -q -B "side-$mm_side" "$base"
    printf 'side %s\n' "$mm_side" > "$repo/side$mm_side.md"
    git -C "$repo" add "side$mm_side.md"
    git -C "$repo" commit -q -m "docs: side $mm_side"
  done
  git -C "$repo" checkout -q -B "$branch" "$base"
  printf 'clean line\n' >> "$repo/doc.md"
  git -C "$repo" commit -q -a -m 'docs: work (#1)'
  git -C "$repo" merge -q --no-ff --no-commit side-1 > /dev/null 2>&1
  [ -z "$1" ] || printf '%s\n' "$1" >> "$repo/doc.md"
  git -C "$repo" commit -q -a -m 'docs: merge side 1 (#1)'
  if [ -n "$1" ]; then
    git -C "$repo" merge -q --no-ff --no-commit side-2 > /dev/null 2>&1
    grep -v -F -x -- "$1" "$repo/doc.md" > "$tmp/doc.md.new"
    mv "$tmp/doc.md.new" "$repo/doc.md"
    git -C "$repo" commit -q -a -m 'docs: merge side 2 (#1)'
  fi
  git -C "$repo" checkout -q main
}

# 切り出した command を $shell_argv で走らせ、exit code を rc に入れる。$1 = base の OID。
# gate の出力は run dir の gate-publish.err に残る (§9 の形のまま)。
run_block() {
  rm -rf "$tmp/run"
  mkdir -p "$tmp/run"
  rc=0
  # shell_argv は下の case で決めた定数 (sh / zsh -f) なので、分割して渡す。
  # shellcheck disable=SC2086
  env -u BASH_ENV -u ENV HOME="$home" main="$repo" base_oid="$1" branch="$branch" title='docs: work (#1)' \
    body_file="$tmp/body.md" run="$tmp/run" $shell_argv "$tmp/gate-block.sh" > "$tmp/out" 2>&1 || rc=$?
}

ran=0
for shell in sh zsh; do
  command -v "$shell" > /dev/null 2>&1 || continue
  case $shell in
    zsh) shell_argv='zsh -f' ;;
    *) shell_argv=sh ;;
  esac
  ran=$((ran + 1))

  # (a) 直線の範囲で値が無ければ通る。
  make_linear 'clean line'
  run_block "$base"
  [ "$rc" -eq 0 ] || fail "[$shell] clean な直線の範囲で exit 0 でない (rc=$rc): $(cat "$tmp/out" "$tmp/run/gate-publish.err")"

  # (b) 累積差分にある値で止まる (gate が入力を読んでいる)。
  make_linear "line $marker"
  run_block "$base"
  [ "$rc" -eq 1 ] || fail "[$shell] 累積差分にある値で止まらない (rc=$rc)"
  grep -q '^public-safety-gate: blocked: stdin:' "$tmp/run/gate-publish.err" \
    || fail "[$shell] 値で止めた gate の出力が gate-publish.err に無い: $(cat "$tmp/run/gate-publish.err")"

  # (c) 範囲に merge commit があれば、値が無くても gate に通さずに止まり、理由を残す。
  make_merge ''
  run_block "$base"
  [ "$rc" -eq 1 ] || fail "[$shell] merge commit を含む範囲で止まらない (rc=$rc): $(cat "$tmp/out")"
  grep -q '公開する範囲に merge commit がある' "$tmp/run/gate-publish.err" \
    || fail "[$shell] merge commit で止めた理由が gate-publish.err に無い: $(cat "$tmp/run/gate-publish.err")"

  # (d) merge の解決でだけ足して後の merge の解決で消した値の場面も、merge commit として止まる。
  make_merge "line $marker"
  if git -C "$repo" diff "$base" "$branch" | grep -q -F -- "$marker"; then
    fail "[$shell] (d) の前提が崩れた: 累積差分に値がある"
  fi
  run_block "$base"
  [ "$rc" -eq 1 ] || fail "[$shell] merge の解決にだけある値の場面で止まらない (rc=$rc)"

  # (e) commit の一覧を取れない (base が無い) ときも exit 0 にならない (fail-closed)。
  make_linear 'clean line'
  run_block 0000000000000000000000000000000000000001
  [ "$rc" -ne 0 ] || fail "[$shell] base が無くても gate の command が exit 0 になる (fail-open)"
done
[ "$ran" -gt 0 ] || fail "gate の command を走らせる shell (sh / zsh) が無い"

echo "ok: codex-worker-publish-gate"
