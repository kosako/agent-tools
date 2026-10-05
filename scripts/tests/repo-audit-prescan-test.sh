#!/bin/sh
# personal-repo-audit の PRESCAN.md の「docs の壊れた path の参照」の self-test (#419)。
# - PRESCAN.md の節の sh の code block を切り出し、temp repo で実際に走らせる。
# - scope が directory ならその下の Markdown を、file ならその file だけを見る。以前は scope を directory と
#   みなした pathspec (scope/*.md) だけだったので、file を渡すと対象が 0 件になり、候補が無いように見えた。
# 引数で repo-audit の skill の directory を差し替えられる (変異での確認用)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
skill_dir=${1:-"$script_dir/../../shared/skills/personal-repo-audit"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 節の sh の block を切り出し、末尾の scope の引数 ('.') を位置引数に差し替える。
ruby - "$skill_dir/PRESCAN.md" "$tmp/prescan.sh" <<'RUBY'
src, out = ARGV
text = File.read(src)
block = text[/^## 2\. docs の壊れた path の参照\n.*?^```sh\n(.*?)^```/m, 1]
abort "PRESCAN.md に「## 2. docs の壊れた path の参照」の sh の block が無い" unless block
tail = %q{' sh '.'}
abort "block の末尾が「#{tail}」でない (scope の引数を差し替えられない)" unless block.rstrip.end_with?(tail)
File.write(out, block.rstrip.delete_suffix(tail) + %q{' sh "$1"} + "\n")
RUBY

# 実 git config (global の hooksPath を含む) に触れない。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
# 既定の global ignore (実 HOME / XDG の下) が fixture を除外しないようにする。
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile /dev/null

repo="$tmp/repo"
git init -q "$repo"
mkdir -p "$repo/docs"
printf '# a\n\n[壊れた link](missing.md)\n' > "$repo/docs/a.md"
printf '# b\n\n[正しい link](a.md)\n' > "$repo/docs/b.md"
git -C "$repo" add docs
git -C "$repo" commit -q -m fixture

run_prescan() {
  (cd "$repo" && sh "$tmp/prescan.sh" "$1") > "$tmp/out" 2>&1 || fail "prescan exited non-zero for scope $1: $(cat "$tmp/out")"
}

# --- case 1: directory の scope は、その下の壊れた link を出す ---
run_prescan docs
grep -q '^docs/a.md:3: missing.md$' "$tmp/out" || fail "directory scope did not report the broken link: $(cat "$tmp/out")"

# --- case 2: file の scope でも、その file の壊れた link を出す (#419) ---
run_prescan docs/a.md
grep -q '^docs/a.md:3: missing.md$' "$tmp/out" || fail "file scope did not report the broken link (pathspec treated the file as a directory?): $(cat "$tmp/out")"

# --- case 3: 壊れた link の無い file の scope は候補 0 件、別の file の候補を出さない ---
run_prescan docs/b.md
if grep -v '^## ' "$tmp/out" | grep -q .; then
  fail "file scope reported candidates outside the file: $(cat "$tmp/out")"
fi

echo "ok: repo-audit-prescan"
