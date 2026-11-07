#!/bin/sh
# shared/scripts/personal-merged-branch-cleanup.rb の self-test (#640)。一時 directory の git repo と bare の origin、偽の gh で、消す条件を
# 1 つずつ外して branch が残ることを確かめる。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-merged-branch-cleanup.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null

# 偽の gh。応答は fixture の file から返し、呼び出しの argv を log に残す。
mkdir -p "$tmp/bin" "$tmp/fx"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/gh.log"
case "$1 $2" in
  "api repos/"*) [ -f "$FX/repo.fail" ] && { echo 'CANARY_GH_STDERR' >&2; exit 1; }; cat "$FX/repo.json" ;;
  "api user") cat "$FX/user.json" ;;
  "pr list")
    if [ -f "$FX/during.pr" ]; then
      read -r w b < "$FX/during.pr"; rm -f "$FX/during.pr"
      git worktree add -q "$w" "$b"
    fi
    cat "$FX/prs.json" ;;
  *) echo "unexpected gh: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
FX="$tmp/fx"
export FX

# origin は bare の repo。script が origin の URL を GitHub の形で読めるように、`git remote get-url` だけを偽の git で返す。
# 確かめた後に tip が動く場面は、for-each-ref と ls-remote の答えを fixture の古い OID にして作る。
git init -q --bare "$tmp/origin.git"
git init -q "$tmp/repo"
git -C "$tmp/repo" remote add origin "$tmp/origin.git"
git -C "$tmp/repo" commit -q --allow-empty -m base
git -C "$tmp/repo" push -q origin main

printf '{"full_name":"me/proj","default_branch":"main","owner":{"login":"me","type":"User"}}' > "$FX/repo.json"
printf '{"login":"me"}' > "$FX/user.json"

real_git=$(command -v git)
cat > "$tmp/bin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "remote get-url" ]; then
  case "\$*" in *--push*) f="\$FX/push.url" ;; *) f="\$FX/origin.url" ;; esac
  if [ -f "\$f" ]; then cat "\$f"; else echo https://github.com/me/proj.git; fi
  exit 0
fi
if [ "\$1" = for-each-ref ] && [ -f "\$FX/foreach.fail" ]; then exit 1; fi
if [ "\$1" = for-each-ref ] && [ -f "\$FX/stale.local" ]; then cat "\$FX/stale.local"; exit 0; fi
if [ "\$1" = ls-remote ] && [ -f "\$FX/stale.remote" ]; then cat "\$FX/stale.remote"; exit 0; fi
if [ "\$1 \$2 \$3" = "update-ref --no-deref -d" ] && [ -f "\$FX/during.delete" ]; then
  read -r w b < "\$FX/during.delete"; rm -f "\$FX/during.delete"
  "$real_git" worktree add -q "\$w" "\$b"
fi
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"

g() { "$real_git" -C "$tmp/repo" "$@"; }
# branch を作って tip の OID を出す。
mkbranch() { # $1=name
  g branch "$1" main
  g switch -q "$1"
  g commit -q --allow-empty -m "work on $1"
  g switch -q main
  g rev-parse "$1"
}
pushed() { # $1=name
  g push -q origin "$1"
}
prs() { # $1=name $2=oid  $3=base (既定 main) $4=cross (既定 false) $5=mergedAt の JSON (既定 文字列)
  printf '[{"number":7,"headRefName":"%s","headRefOid":"%s","baseRefName":"%s","isCrossRepository":%s,"mergedAt":%s}]' \
    "$1" "$2" "${3:-main}" "${4:-false}" "${5:-\"2026-11-01T00:00:00Z\"}" > "$FX/prs.json"
}
has_local() { g rev-parse --verify --quiet "refs/heads/$1" > /dev/null; }
has_remote() { [ -n "$(g ls-remote --refs origin "refs/heads/$1")" ]; }
# 実行して exit code を $rc に、stdout を $tmp/out に、stderr を $tmp/err に残す。
run() {
  rc=0
  ( cd "$tmp/repo" && env -u GH_REPO PATH="$tmp/bin:$PATH" ruby "$src" "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
}
expect() { # $1=rc $2=stdout の 1 行 $3=label
  [ "$rc" = "$1" ] || fail "$3: expected exit $1, got $rc: $(cat "$tmp/out") $(cat "$tmp/err")"
  grep -qxF -- "$2" "$tmp/out" || fail "$3: missing '$2' in: $(cat "$tmp/out")"
}

# ---- 消せる: local だけ。branch の設定も外れ、remote には触らない ---------------------------------
oid=$(mkbranch feat/a); pushed feat/a; prs feat/a "$oid"
g config branch.feat/a.remote origin
run feat/a
expect 0 "deleted: feat/a (merged in #7)" "local delete"
has_local feat/a && fail "local branch should be gone"
has_remote feat/a || fail "remote branch must stay without --remote"
[ -z "$(g config --get-regexp '^branch\.feat/a\.' || true)" ] || fail "branch config should be removed"

# ---- --remote: local と remote の両方を消す -----------------------------------------------------
oid=$(mkbranch feat/b); pushed feat/b; prs feat/b "$oid"
run --remote feat/b
expect 0 "deleted: feat/b (merged in #7, remote too)" "remote delete"
has_local feat/b && fail "local feat/b should be gone"
has_remote feat/b && fail "remote feat/b should be gone"

# ---- --remote: remote が自動で消えた後は local だけ消す -----------------------------------------
oid=$(mkbranch feat/c); prs feat/c "$oid"
run --remote feat/c
expect 0 "deleted: feat/c (merged in #7)" "remote already gone"
has_local feat/c && fail "local feat/c should be gone"

# ---- --remote: local が無く remote だけ残っている ----------------------------------------------
oid=$(mkbranch feat/d); pushed feat/d; prs feat/d "$oid"
g update-ref -d refs/heads/feat/d "$oid"
run --remote feat/d
expect 0 "deleted: feat/d (merged in #7, remote too)" "remote only"
has_remote feat/d && fail "remote feat/d should be gone"

# ---- どちらにも無い: 何度実行してもよい ----------------------------------------------------------
run --remote feat/gone
expect 0 "absent: feat/gone" "absent"

# ほかの branch の接頭になる名前を、その branch と取り違えない (for-each-ref は接頭でも一致する)
oid=$(mkbranch prefix/child); prs prefix "$oid"
run prefix
expect 0 "absent: prefix" "prefix of another branch"
has_local prefix/child || fail "prefix of another branch: child must stay"

# ---- --dry-run: 消さない -------------------------------------------------------------------------
oid=$(mkbranch feat/e); pushed feat/e; prs feat/e "$oid"
run --remote --dry-run feat/e
expect 0 "would-delete: feat/e (merged in #7)" "dry-run"
has_local feat/e || fail "dry-run must keep local"
has_remote feat/e || fail "dry-run must keep remote"

# ---- 条件を外す: どれも branch を残して exit 1 ----------------------------------------------------
# merge の後に commit を足した
oid=$(mkbranch feat/f); prs feat/f "$oid"
g switch -q feat/f; g commit -q --allow-empty -m later; g switch -q main
run feat/f
expect 1 "refused: feat/f (tip-is-not-merged-head)" "tip moved"
has_local feat/f || fail "tip moved: branch must stay"

# merged の PR が無い
oid=$(mkbranch feat/g); printf '[]' > "$FX/prs.json"
run feat/g
expect 1 "refused: feat/g (no-merged-pr)" "no pr"
has_local feat/g || fail "no pr: branch must stay"

# stacked の親に入っただけ
oid=$(mkbranch feat/h); prs feat/h "$oid" feat/parent
run feat/h
expect 1 "refused: feat/h (base-is-not-default-branch)" "stacked"
has_local feat/h || fail "stacked: branch must stay"

# fork の同じ名前の branch の PR は数えない
oid=$(mkbranch feat/i); prs feat/i "$oid" main true
run feat/i
expect 1 "refused: feat/i (no-merged-pr)" "fork"
has_local feat/i || fail "fork: branch must stay"

# mergedAt の無い PR は数えない
oid=$(mkbranch feat/j); prs feat/j "$oid" main false null
run feat/j
expect 1 "refused: feat/j (no-merged-pr)" "mergedAt null"
has_local feat/j || fail "mergedAt null: branch must stay"

# 別の名前の head の PR は数えない (gh の filter の外れに備える)
oid=$(mkbranch feat/k); prs feat/other "$oid"
run feat/k
expect 1 "refused: feat/k (no-merged-pr)" "other head name"
has_local feat/k || fail "other head name: branch must stay"

# default branch
main_oid=$(g rev-parse main); prs main "$main_oid"
run main
expect 1 "refused: main (default-branch)" "default branch"
has_local main || fail "default branch must stay"

# worktree で checkout 中
oid=$(mkbranch feat/l); prs feat/l "$oid"
g worktree add -q "$tmp/wt-l" feat/l
run feat/l
expect 1 "refused: feat/l (checked-out)" "checked out"
has_local feat/l || fail "checked out: branch must stay"
g worktree remove "$tmp/wt-l"

# remote の OID が違う (local も remote も残す)
oid=$(mkbranch feat/m); pushed feat/m; prs feat/m "$oid"
g switch -q feat/m; g commit -q --allow-empty -m later; g push -q origin feat/m; new=$(g rev-parse HEAD); g switch -q main
g update-ref refs/heads/feat/m "$oid"
run --remote feat/m
expect 1 "refused: feat/m (remote-differs)" "remote differs"
has_local feat/m || fail "remote differs: local must stay"
has_remote feat/m || fail "remote differs: remote must stay"
[ "$(g ls-remote --refs origin refs/heads/feat/m | cut -f1)" = "$new" ] || fail "remote differs: remote must not move"

# origin が別の repo を指す: remote も local も消さない
oid=$(mkbranch feat/n); pushed feat/n; prs feat/n "$oid"
printf 'https://github.com/someone/else.git\n' > "$FX/origin.url"
run --remote feat/n
expect 1 "refused: feat/n (origin-is-another-repo)" "origin mismatch"
has_local feat/n || fail "origin mismatch: local must stay"
has_remote feat/n || fail "origin mismatch: remote must stay"
rm -f "$FX/origin.url"

# origin が別の repo を指す: --remote が無くても local を消さない (別の repo の PR を根拠にしない)
oid=$(mkbranch feat/n2); prs feat/n2 "$oid"
printf 'https://github.com/someone/else.git\n' > "$FX/origin.url"
run feat/n2
expect 1 "refused: feat/n2 (origin-is-another-repo)" "origin mismatch without --remote"
has_local feat/n2 || fail "origin mismatch without --remote: local must stay"
# fetch の URL が複数あって 1 つでも外れれば止まる
printf 'https://github.com/me/proj.git\nhttps://github.com/someone/else.git\n' > "$FX/origin.url"
run feat/n2
expect 1 "refused: feat/n2 (origin-is-another-repo)" "second fetch url mismatch"
has_local feat/n2 || fail "second fetch url mismatch: local must stay"
# GitHub の URL の形で読めない
printf 'https://github.com.example.org/me/proj.git\n' > "$FX/origin.url"
run feat/n2
expect 1 "refused: feat/n2 (origin-is-another-repo)" "lookalike host"
has_local feat/n2 || fail "lookalike host: local must stay"
rm -f "$FX/origin.url"

# push の URL が別の repo を指す: --remote では何も消さない。push の URL が複数あって 1 つでも外れれば同じ
oid=$(mkbranch feat/n3); pushed feat/n3; prs feat/n3 "$oid"
printf 'https://github.com/someone/else.git\n' > "$FX/push.url"
run --remote feat/n3
expect 1 "refused: feat/n3 (origin-is-another-repo)" "push url mismatch"
has_local feat/n3 || fail "push url mismatch: local must stay"
has_remote feat/n3 || fail "push url mismatch: remote must stay"
printf 'https://github.com/me/proj.git\nhttps://github.com/someone/else.git\n' > "$FX/push.url"
run --remote feat/n3
expect 1 "refused: feat/n3 (origin-is-another-repo)" "second push url mismatch"
has_remote feat/n3 || fail "second push url mismatch: remote must stay"
# --remote が無ければ push しないので、push の URL は見ない
run feat/n3
expect 0 "deleted: feat/n3 (merged in #7)" "push url is not read without --remote"
has_remote feat/n3 || fail "push url without --remote: remote must stay"
rm -f "$FX/push.url"

# 壊れた ref を「無い」と読まない: remote だけの経路に進まず、exit 2 で何も消さない
oid=$(mkbranch feat/n4); pushed feat/n4; prs feat/n4 "$oid"
printf 'garbage\n' > "$tmp/repo/.git/refs/heads/feat/n4"
run --remote feat/n4
[ "$rc" = 2 ] || fail "broken ref should exit 2, got $rc: $(cat "$tmp/out")"
has_remote feat/n4 || fail "broken ref: remote must stay"
printf '%s\n' "$oid" > "$tmp/repo/.git/refs/heads/feat/n4"
# 指す先の無い OID: PR の head と違うので消さない
printf '1111111111111111111111111111111111111111\n' > "$tmp/repo/.git/refs/heads/feat/n4"
run feat/n4
expect 1 "refused: feat/n4 (tip-is-not-merged-head)" "ref to a missing object"
printf '%s\n' "$oid" > "$tmp/repo/.git/refs/heads/feat/n4"
# ref を読めない
: > "$FX/foreach.fail"
run --remote feat/n4
rm -f "$FX/foreach.fail"
[ "$rc" = 2 ] || fail "unreadable refs should exit 2, got $rc: $(cat "$tmp/out")"
has_local feat/n4 || fail "unreadable refs: local must stay"
has_remote feat/n4 || fail "unreadable refs: remote must stay"

# gh の照会の間に checkout された: PR を確かめた後に見るので消さない
oid=$(mkbranch feat/n5); pushed feat/n5; prs feat/n5 "$oid"
printf '%s feat/n5\n' "$tmp/wt-n5" > "$FX/during.pr"
run --remote feat/n5
expect 1 "refused: feat/n5 (checked-out)" "checked out during the gh query"
has_local feat/n5 || fail "checked out during the gh query: local must stay"
has_remote feat/n5 || fail "checked out during the gh query: remote must stay"
g worktree remove "$tmp/wt-n5"

# 消す直前に checkout された: 比較では止まらないので、消した後に見直して同じ OID で戻す。branch の設定も残す
oid=$(mkbranch feat/n6); prs feat/n6 "$oid"
g config branch.feat/n6.remote origin
printf '%s feat/n6\n' "$tmp/wt-n6" > "$FX/during.delete"
run feat/n6
expect 1 "refused: feat/n6 (checked-out)" "checked out just before the delete"
[ "$(g rev-parse feat/n6)" = "$oid" ] || fail "checked out just before the delete: ref must be restored"
[ "$("$real_git" -C "$tmp/wt-n6" symbolic-ref HEAD)" = refs/heads/feat/n6 ] || fail "worktree must stay on the branch"
[ "$("$real_git" -C "$tmp/wt-n6" rev-parse HEAD)" = "$oid" ] || fail "worktree HEAD must resolve"
[ "$(g config branch.feat/n6.remote)" = origin ] || fail "branch config must stay"
g worktree remove "$tmp/wt-n6"

# 記号の ref は、指す先ではなく ref だけを消す
oid=$(mkbranch feat/target); g symbolic-ref refs/heads/feat/sym refs/heads/feat/target; prs feat/sym "$oid"
run feat/sym
expect 0 "deleted: feat/sym (merged in #7)" "symbolic ref"
has_local feat/sym && fail "symbolic ref should be gone"
[ "$(g rev-parse feat/target)" = "$oid" ] || fail "symbolic ref: target must stay"

# 比較つきの削除: 確かめた後に local の tip が動いたら、消さずに残す
oid=$(mkbranch feat/o); prs feat/o "$oid"
g switch -q feat/o; g commit -q --allow-empty -m later; new=$(g rev-parse HEAD); g switch -q main
printf '%s refs/heads/feat/o\n' "$oid" > "$FX/stale.local"
run feat/o
rm -f "$FX/stale.local"
expect 1 "refused: feat/o (local-delete-failed)" "local moved after the check"
[ "$(g rev-parse feat/o)" = "$new" ] || fail "local moved: branch must stay at the new tip"

# 比較つきの削除: 確かめた後に remote が動いたら、remote の削除が失敗し、local も残す
oid=$(mkbranch feat/o2); pushed feat/o2; prs feat/o2 "$oid"
g switch -q feat/o2; g commit -q --allow-empty -m later; g push -q origin feat/o2; new=$(g rev-parse HEAD); g switch -q main
g update-ref refs/heads/feat/o2 "$oid"
printf '%s\trefs/heads/feat/o2\n' "$oid" > "$FX/stale.remote"
run --remote feat/o2
rm -f "$FX/stale.remote"
expect 1 "refused: feat/o2 (remote-delete-failed)" "remote moved after the check"
has_local feat/o2 || fail "remote moved: local must stay"
[ "$(g ls-remote --refs origin refs/heads/feat/o2 | cut -f1)" = "$new" ] || fail "remote moved: remote must stay at the new tip"

# 個人の repo でない (organization)
oid=$(mkbranch feat/p); prs feat/p "$oid"
printf '{"full_name":"me/proj","default_branch":"main","owner":{"login":"me","type":"Organization"}}' > "$FX/repo.json"
run feat/p
expect 1 "refused: feat/p (not-personal-repo)" "organization"
has_local feat/p || fail "organization: branch must stay"
# 他人の repo
printf '{"full_name":"me/proj","default_branch":"main","owner":{"login":"someone","type":"User"}}' > "$FX/repo.json"
run feat/p
expect 1 "refused: feat/p (not-personal-repo)" "other owner"
has_local feat/p || fail "other owner: branch must stay"
printf '{"full_name":"me/proj","default_branch":"main","owner":{"login":"me","type":"User"}}' > "$FX/repo.json"

# ---- 複数の branch: 消せるものは消し、止まったものがあれば exit 1 ----------------------------------
oid=$(mkbranch feat/q); prs feat/q "$oid"
oid2=$(mkbranch feat/r)
run feat/r feat/q
[ "$rc" = 1 ] || fail "mixed: expected exit 1, got $rc"
# prs.json は feat/q のものなので feat/r は名前が合わず止まり、feat/q は消える
grep -qxF "refused: feat/r (no-merged-pr)" "$tmp/out" || fail "mixed: feat/r should be refused: $(cat "$tmp/out")"
grep -qxF "deleted: feat/q (merged in #7)" "$tmp/out" || fail "mixed: feat/q should be deleted: $(cat "$tmp/out")"
has_local feat/r || fail "mixed: feat/r must stay"
has_local feat/q && fail "mixed: feat/q should be gone"
[ "$(g rev-parse feat/r)" = "$oid2" ] || fail "mixed: feat/r must not move"

# ---- 判定できない・使い方の誤り: exit 2 で何も消さない。gh の stderr は出さない ----------------------
oid=$(mkbranch feat/s); prs feat/s "$oid"
: > "$FX/repo.fail"
run feat/s
[ "$rc" = 2 ] || fail "gh failure should exit 2, got $rc"
has_local feat/s || fail "gh failure: branch must stay"
grep -qF CANARY_GH_STDERR "$tmp/out" "$tmp/err" && fail "gh stderr must not be shown" || :
rm -f "$FX/repo.fail"

printf '{"nope":1}' > "$tmp/fx/prs.json"
run feat/s
[ "$rc" = 2 ] || fail "bad pr list shape should exit 2, got $rc"
has_local feat/s || fail "bad shape: branch must stay"
printf 'not json' > "$tmp/fx/prs.json"
run feat/s
[ "$rc" = 2 ] || fail "invalid json should exit 2, got $rc"
prs feat/s "short-oid"
run feat/s
[ "$rc" = 2 ] || fail "bad oid in pr list should exit 2, got $rc"
has_local feat/s || fail "bad oid: branch must stay"

: > "$FX/gh.log"
for bad in '--force' '@{-1}' '-x' 'feat/../x' 'a b' 'x.lock' ''; do
  run "$bad"
  [ "$rc" = 2 ] || fail "bad name '$bad' should exit 2, got $rc"
done
run
[ "$rc" = 2 ] || fail "no branch should exit 2, got $rc"
run --repo
[ "$rc" = 2 ] || fail "--repo without a value should exit 2, got $rc"
run --repo '-bad/repo' feat/s
[ "$rc" = 2 ] || fail "--repo with a bad value should exit 2, got $rc"
[ ! -s "$FX/gh.log" ] || fail "usage errors must not call gh: $(cat "$FX/gh.log")"

# GH_REPO があるときは --repo が要る (ほかの理由で止まらないように、PR の fixture は正しい形にしておく)
prs feat/s "$oid"
rc=0
( cd "$tmp/repo" && env GH_REPO=x/y PATH="$tmp/bin:$PATH" ruby "$src" feat/s ) > "$tmp/out" 2> "$tmp/err" || rc=$?
[ "$rc" = 2 ] || fail "GH_REPO without --repo should exit 2, got $rc"
grep -qF GH_REPO "$tmp/err" || fail "GH_REPO: should say why: $(cat "$tmp/err")"
has_local feat/s || fail "GH_REPO: branch must stay"

# --repo は gh の呼び出しに渡る
: > "$FX/gh.log"
run --repo me/proj --dry-run feat/s
expect 0 "would-delete: feat/s (merged in #7)" "--repo"
grep -qxF "api repos/me/proj" "$FX/gh.log" || fail "--repo should reach gh api: $(cat "$FX/gh.log")"

# ---- asset: docs の正本がある -----------------------------------------------------------------------
[ -f "$repo_root/docs/merged-branch-cleanup.md" ] || fail "missing docs/merged-branch-cleanup.md"

echo "ok: merged-branch-cleanup self-test passed"
