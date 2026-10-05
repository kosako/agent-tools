#!/bin/sh
# personal-maintenance-sweep の fix モードの「base の worktree の用意」の self-test (#419 review F7)。
# FIX.md の「## 検証 (累積差分に対して)」の節にある block (git worktree add --quiet --detach を含むもの) を切り出し、
# temp repo で sh と zsh で走らせる。無ければ作り、在れば (検証のやり直しや再開) 所有・HEAD = base・detached・clean を
# 確かめて再利用し、どれかに外れたら exit 2 で止まる (自動で消したり作り直したりしない)。
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。実 git config には触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
sweep_dir=${1:-"$script_dir/../../shared/skills/personal-maintenance-sweep"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby - "$sweep_dir/FIX.md" "$tmp/basedir.sh" <<'RUBY'
src, out = ARGV
text = File.read(src)
section = text[/^## 検証 \(累積差分に対して\)\n(.*?)(?=^## )/m, 1]
abort "FIX.md に「## 検証 (累積差分に対して)」の節が無い" unless section
blocks = section.scan(/^( *)```sh\n(.*?)^\1```/m).map { |indent, body| body.lines.map { |l| l.sub(/\A#{indent}/, "") }.join }
picked = blocks.select { |b| b.include?("git worktree add --quiet --detach") }
abort "検証の節に base の worktree の用意の sh の block が 1 つでない (#{picked.size} 個)" unless picked.size == 1
File.write(out, picked.first)
RUBY

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile /dev/null

repo="$tmp/repo"
git init -q "$repo"
printf 'base\n' > "$repo/doc.md"
git -C "$repo" add doc.md
git -C "$repo" commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)
printf 'next\n' >> "$repo/doc.md"
git -C "$repo" commit -q -a -m next
next=$(git -C "$repo" rev-parse HEAD)

# $1 = shell の argv、$2 = basedir、$3 = base。exit code を rc に入れる。cwd は main の checkout。
run_prep() {
  rc=0
  # shellcheck disable=SC2086 # $1 は下の定数 (sh / zsh -f)
  (cd "$repo" && env basedir="$2" base="$3" $1 "$tmp/basedir.sh") > "$tmp/out" 2>&1 || rc=$?
}

ran=0
for shell in sh zsh; do
  command -v "$shell" > /dev/null 2>&1 || continue
  case $shell in
    zsh) shell_argv='zsh -f' ;;
    *) shell_argv=sh ;;
  esac
  ran=$((ran + 1))
  bd="$tmp/run-$shell/fix/1-base"
  mkdir -p "$tmp/run-$shell/fix"

  # (a) 無ければ作る。HEAD は base。
  run_prep "$shell_argv" "$bd" "$base"
  [ "$rc" -eq 0 ] || fail "[$shell] creating the base worktree failed (rc=$rc): $(cat "$tmp/out")"
  [ "$(git -C "$bd" rev-parse HEAD)" = "$base" ] || fail "[$shell] the created base worktree is not at base"

  # (b) 検証のやり直しや再開で在れば、作らずに再利用する (F7: 無条件の作成は既存と衝突していた)。
  run_prep "$shell_argv" "$bd" "$base"
  [ "$rc" -eq 0 ] || fail "[$shell] re-running with an existing base worktree did not reuse it (rc=$rc): $(cat "$tmp/out")"

  # (c) dirty なら止まる。
  printf 'x\n' > "$bd/untracked.txt"
  run_prep "$shell_argv" "$bd" "$base"
  [ "$rc" -eq 2 ] || fail "[$shell] a dirty base worktree did not stop with exit 2 (rc=$rc)"
  rm -f "$bd/untracked.txt"

  # (d) HEAD が base でなければ止まる。
  git -C "$bd" checkout -q --detach "$next"
  run_prep "$shell_argv" "$bd" "$base"
  [ "$rc" -eq 2 ] || fail "[$shell] a base worktree at another commit did not stop with exit 2 (rc=$rc)"
  git -C "$bd" checkout -q --detach "$base"

  # (e) branch を checkout していれば止まる (detached でない)。
  git -C "$bd" switch -q -c "tmp-$shell"
  run_prep "$shell_argv" "$bd" "$base"
  [ "$rc" -eq 2 ] || fail "[$shell] a base worktree on a branch did not stop with exit 2 (rc=$rc)"
  git -C "$bd" checkout -q --detach "$base"

  # (f) この repo の worktree でない directory なら止まる。
  mkdir -p "$tmp/run-$shell/fix/2-base"
  run_prep "$shell_argv" "$tmp/run-$shell/fix/2-base" "$base"
  [ "$rc" -eq 2 ] || fail "[$shell] a plain directory did not stop with exit 2 (rc=$rc)"

  # (g) 作れなければ止まる (base が commit でない)。
  run_prep "$shell_argv" "$tmp/run-$shell/fix/3-base" 0000000000000000000000000000000000000001
  [ "$rc" -eq 2 ] || fail "[$shell] a failed worktree add did not stop with exit 2 (rc=$rc)"
done
[ "$ran" -gt 0 ] || fail "block を走らせる shell (sh / zsh) が無い"

echo "ok: maintenance-sweep-fix-basedir"
