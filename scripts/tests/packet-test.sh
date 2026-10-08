#!/bin/sh
# personal-packet.rb の self-test (#253 PR-2)。
# dir の worktree 解決 / list の frontmatter 判定 / publish の合成・gate 連携・gh 連携・
# published 更新 / check (更新先の検査。#386) を tmp repo で検証する。gh は PATH 先頭の fake で置き換え、実 HOME /
# 実 gh には触れない (HOME を隔離、network なし)。secret 形の fixture は実行時に連結する。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

packet_src="$repo_root/shared/scripts/personal-packet.rb"
gate_src="$repo_root/shared/scripts/personal-public-safety-gate.rb"
[ -f "$packet_src" ] || fail "missing $packet_src"
[ -f "$gate_src" ] || fail "missing $gate_src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

HOME="$tmp/home"
export HOME
mkdir -p "$HOME/.config/agent-tools"
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null
# 既定の excludes ($XDG_CONFIG_HOME/git/ignore) は GIT_CONFIG_GLOBAL の隔離を素通りする。`.agent-packets/`
# を global ignore に置いた machine でも submodule の fixture を作れるように外す。file:// の submodule も許す
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile /dev/null
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
# repository / index を選ぶ git の環境変数を継承していると check は判定できない (exit 2) ので外す
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

gh_token=$(printf 'ghp'; printf '_'; printf 'aaaaaaaaaabbbbbbbbbbccccccccccdddddd')

# 配備形: script と gate が同じ directory にある (dispatcher と同じ契約)。
deploy="$tmp/deploy"
mkdir -p "$deploy"
cp "$packet_src" "$deploy/personal-packet"
cp "$gate_src" "$deploy/personal-public-safety-gate"
chmod +x "$deploy/personal-packet" "$deploy/personal-public-safety-gate"
pkt="$deploy/personal-packet"

# fake gh: 引数を log に、--body-file の中身を capture に写し、control file の exit code で終わる。
# 生成物へ埋める path は shell literal 化する (#272)。
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
gh_log="$tmp/gh.log"
gh_body="$tmp/gh.body"
gh_rc="$tmp/gh.rc"
gh_hook="$tmp/gh.hook"
echo 0 > "$gh_rc"
{
  printf '#!/bin/sh\n'
  printf 'log=%s\nbody=%s\nrcfile=%s\nhook=%s\n' "$(shq "$gh_log")" "$(shq "$gh_body")" "$(shq "$gh_rc")" "$(shq "$gh_hook")"
  cat <<'EOF'
printf '%s\n' "$*" >> "$log"
# 投稿の瞬間に環境を変える case (投稿後の保存失敗) 用。hook file があれば実行する
if [ -f "$hook" ]; then sh "$hook"; fi
while [ $# -gt 0 ]; do
  if [ "$1" = "--body-file" ]; then cp "$2" "$body"; fi
  shift
done
rc=$(cat "$rcfile")
if [ "$rc" -ne 0 ]; then echo "fake gh: failure" >&2; exit "$rc"; fi
echo "https://example.invalid/comment/1"
EOF
} > "$fakebin/gh"
chmod +x "$fakebin/gh"
with_gh() { PATH="$fakebin:$PATH" "$@"; }
gh_calls() { if [ -f "$gh_log" ]; then wc -l < "$gh_log" | tr -d ' '; else echo 0; fi; }

# ---- repo / packets ----------------------------------------------------------
repo="$tmp/repo"
git init -q "$repo"
(cd "$repo" && git commit -q --allow-empty -m seed)
mkdir -p "$repo/.agent-packets" "$repo/sub"
cat > "$repo/.agent-packets/7.md" <<'EOF'
---
issue: 7
title: "packet seven #7"
branch: feat/7-x
pr: 8
state: review
worker: claude
updated: 2026-09-21T23:50:00+09:00
---

## 依頼

<!-- orchestrator が上書き -->
- 受け入れ条件: foo
- 結果の書式の例 (fenced code。行頭 `## ` は使わない):

```markdown
### 2030-01-01 sample/agent
REQUEST-SAMPLE-LINE
```
- 字下げした code (R293-10 の並び。字下げ行は見出しにならない):

    ~~~
    ## 次の入口
    REQUEST-INDENTED-CODE-ENTRY
    ~~~

- inline code ```三連``` を含む行 (R293-11 の並び) の後に fence:

```
### 2030-01-02 sample/agent
REQUEST-INLINE-SAMPLE
```

## 結果

### 2026-09-20 worker/claude
- OLD-SECTION-LINE

### 2026-09-21 worker/claude
- 到達点: NEW-SECTION-LINE
- 例:

~~~
### 2030-01-01 fenced/sample
FENCED-SAMPLE-LINE
~~~
<!-- PRIVATE-COMMENT
### 下書き
COMMENT-DRAFT-LINE
-->

## 次の入口

NEXT-ENTRY-LINE
EOF
cat > "$repo/.agent-packets/9.md" <<'EOF'
---
issue: 9
title: done one
state: done
worker: codex
updated: 2026-09-20T10:00:00+09:00
published: 2026-09-20T11:00:00+09:00
---
## 結果
x
EOF

# ---- dir: main root / subdir / linked worktree で同じ ----------------------------
expected="$repo/.agent-packets"
d1=$(cd "$repo" && "$pkt" dir)
d2=$(cd "$repo/sub" && "$pkt" dir)
(cd "$repo" && git worktree add -q "$tmp/wt" -b wt)
d3=$(cd "$tmp/wt" && "$pkt" dir)
[ "$(cd "$d1" && pwd -P)" = "$(cd "$expected" && pwd -P)" ] || fail "dir at root: $d1"
[ "$(cd "$d2" && pwd -P)" = "$(cd "$expected" && pwd -P)" ] || fail "dir in subdir: $d2"
[ "$(cd "$d3" && pwd -P)" = "$(cd "$expected" && pwd -P)" ] || fail "dir from linked worktree should be main root: $d3"
set +e
(cd "$tmp" && "$pkt" dir >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "dir outside git should be exit 2 (rc=$rc)"

# ---- list ----------------------------------------------------------------------
out=$(cd "$repo" && "$pkt" list)
echo "$out" | grep -q "^#7 " || fail "list should show active packet: $out"
echo "$out" | grep -q "^#9 " && fail "list should hide done packet by default: $out"
echo "$out" | grep -q "unpublished" || fail "list should flag unpublished: $out"
out=$(cd "$repo" && "$pkt" list --all)
echo "$out" | grep -q "^#9 " || fail "list --all should include done: $out"

(cd "$repo" && "$pkt" list --json --all > "$tmp/list.json")
[ "$(jget "$tmp/list.json" 0 issue)" = "7" ] || fail "json issue"
[ "$(jget "$tmp/list.json" 0 title)" = '"packet seven #7"' ] || fail "json title (quoted # kept): $(jget "$tmp/list.json" 0 title)"
[ "$(jget "$tmp/list.json" 0 pr)" = "8" ] || fail "json pr"
[ "$(jget "$tmp/list.json" 0 unpublished)" = "true" ] || fail "json unpublished (no published)"
[ "$(jget "$tmp/list.json" 1 unpublished)" = "false" ] || fail "json unpublished (published >= updated)"
[ "$(jget "$tmp/list.json" 1 branch)" = "nil" ] || fail "json optional branch nil"

# 壊れた packet: warning + exit 1、健全な行は出す
printf -- '---\nissue: 5\ntitle: t\nstate: open\nworker: claude\nupdated: 2026-09-21T00:00:00+09:00\n---\n' > "$repo/.agent-packets/6.md"
set +e
out=$(cd "$repo" && "$pkt" list 2>"$tmp/err")
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "broken packet should exit 1 (rc=$rc)"
echo "$out" | grep -q "^#7 " || fail "broken packet must not hide healthy rows: $out"
grep -q "6.md" "$tmp/err" || fail "warning should name the broken packet: $(cat "$tmp/err")"
printf -- '---\nissue: 6\ntitle: t\nstate: bogus\nworker: claude\nupdated: 2026-09-21T00:00:00+09:00\n---\n' > "$repo/.agent-packets/6.md"
set +e
(cd "$repo" && "$pkt" list >/dev/null 2>"$tmp/err")
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "invalid state should exit 1 (rc=$rc)"
grep -q "state" "$tmp/err" || fail "warning should name the field: $(cat "$tmp/err")"
# frontmatter が空行・空白・comment だけでも、深い入れ子でも、その packet だけ broken (#428)。
# 以前は Psych.parse の false で NoMethodError になり、list 全体が exit 2 で健全な行も出さなかった。
deep=$(ruby -e 'print "[" * 5000 + "]" * 5000')
for bad in empty comment deep; do
  case $bad in
    empty) printf -- '---\n\n---\n\n## 結果\n' > "$repo/.agent-packets/6.md" ;;
    comment) printf -- '---\n# comment only\n  \n---\n\n## 結果\n' > "$repo/.agent-packets/6.md" ;;
    deep) printf -- '---\nissue: 6\ntitle: t\nstate: open\nworker: claude\nupdated: 2026-09-21T00:00:00+09:00\nrun: %s\n---\n' "$deep" > "$repo/.agent-packets/6.md" ;;
  esac
  set +e
  out=$(cd "$repo" && "$pkt" list 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "frontmatter ($bad) should be a broken row, exit 1 (#428) (rc=$rc): $(cat "$tmp/err")"
  echo "$out" | grep -q "^#7 " || fail "frontmatter ($bad) must not hide healthy rows (#428): $out"
  grep -q "6.md" "$tmp/err" || fail "frontmatter ($bad): warning should name the packet: $(cat "$tmp/err")"
done
rm "$repo/.agent-packets/6.md"

# publish は pull が読めない形の写しを投稿しない (#428)。結果に規約の entry 見出しが無い / ラベルだけの行がある。
for bad in no-entry label-line; do
  case $bad in
    no-entry) body='## 結果\n\nFREE-RESULT\n\n## 次の入口\n\nNEXT\n' ;;
    label-line) body='## 結果\n\n### 2026-09-23 worker/claude\n- R\n\n**次の入口**\n\n## 次の入口\n\nNEXT\n' ;;
  esac
  printf -- '---\nissue: 31\ntitle: t\nstate: open\nworker: claude\nupdated: 2026-09-23T10:00:00+09:00\n---\n\n'"$body" > "$repo/.agent-packets/31.md"
  set +e
  (cd "$repo" && "$pkt" publish 31 --dry-run > "$tmp/out" 2> "$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "publish of a copy pull cannot read ($bad) should stop with exit 2 (#428) (rc=$rc)"
  grep -q "pull で読めない" "$tmp/err" || fail "publish ($bad) should explain the unreadable copy: $(cat "$tmp/err")"
  [ ! -s "$tmp/out" ] || fail "publish ($bad) must not print the copy"
done
rm "$repo/.agent-packets/31.md"

# 型変換で例外を投げる YAML (`!!float invalid`) が key / 値にあっても、その packet だけ broken (R293-21)
# `title: !!binary /w==` は UTF-8 でない String になり list --json の JSON 生成で落ちる (R293-22)。tag は AST で拒否
for bad in '!!float invalid: ignored' 'pr: !!float invalid' 'branch: !!binary /w=='; do
  printf -- '---\nissue: 6\ntitle: t\nstate: open\nworker: claude\nupdated: 2026-09-21T00:00:00+09:00\n%s\n---\n' "$bad" > "$repo/.agent-packets/6.md"
  set +e
  out=$(cd "$repo" && "$pkt" list 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "YAML type-conversion failure ($bad) should be a broken row, exit 1 (R293-21) (rc=$rc): $(cat "$tmp/err")"
  echo "$out" | grep -q "^#7 " || fail "R293-21 ($bad): healthy rows must still be listed: $out"
  grep -q "6.md" "$tmp/err" || fail "R293-21 ($bad): warning should name the packet: $(cat "$tmp/err")"
  set +e
  (cd "$repo" && "$pkt" list --json > "$tmp/json.out" 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "R293-22 ($bad): list --json should also degrade to exit 1 (rc=$rc)"
  [ "$(jget "$tmp/json.out" 0 issue)" = "7" ] || fail "R293-22 ($bad): list --json must still emit healthy rows"
done
rm "$repo/.agent-packets/6.md"

# dir 無し = 未運用 (正常)
empty="$tmp/empty"
git init -q "$empty"
out=$(cd "$empty" && "$pkt" list)
[ "$out" = "no active packets" ] || fail "no dir should be empty list: $out"
[ "$(cd "$empty" && "$pkt" list --json)" = "[]" ] || fail "no dir json should be []"

# ---- list: tracked / symlink の packet は読まずに飛ばす (#412) ------------------------------
# check (#386) が書き込みを拒む packet を、list も現在地として出さない。中身 (title / run) を出さず、path と
# 理由だけを warning にして exit 1。健全な packet は出し続ける。
skip_packet() { # path issue title
  printf -- '---\nissue: %s\ntitle: %s\nstate: open\nworker: claude\nupdated: 2026-09-23T10:00:00+09:00\nrun: %s\n---\n\n## 結果\n\n### 2026-09-23 worker/claude\n- R\n\n## 次の入口\n\nN\n' "$2" "$3" "$tmp/skip-run-$2" > "$1"
}
run_list() { # cwd [list の引数...] -> rc / $tmp/ls.out / $tmp/ls.err
  ls_cwd=$1
  shift
  set +e
  (cd "$ls_cwd" && "$pkt" list "$@" > "$tmp/ls.out" 2> "$tmp/ls.err")
  rc=$?
  set -e
}
lsk="$tmp/listskip"
git init -q "$lsk"
mkdir -p "$lsk/.agent-packets" "$tmp/skip-outside"
skip_packet "$lsk/.agent-packets/7.md" 7 "HEALTHY-SEVEN"
skip_packet "$lsk/.agent-packets/8.md" 8 "TRACKED-TITLE"
(cd "$lsk" && git add -f .agent-packets/8.md)
skip_packet "$tmp/skip-outside/9.md" 9 "LINKED-TITLE"
ln -s "$tmp/skip-outside/9.md" "$lsk/.agent-packets/9.md"
# regular file でない (directory) と、大文字小文字だけ違う path で index にある packet (`:(icase)` で同じ file とみなす)
mkdir "$lsk/.agent-packets/10.md"
skip_packet "$lsk/.agent-packets/11.md" 11 "ICASE-TITLE"
icase_blob=$(cd "$lsk" && git hash-object -w .agent-packets/11.md)
(cd "$lsk" && git update-index --add --cacheinfo "100644,$icase_blob,.AGENT-PACKETS/11.md")
# 飛ばす packet の中身を読まないこと: 読めない権限にしておく (読みに行けば「読めません」の warning になる)
chmod 000 "$lsk/.agent-packets/8.md" "$lsk/.agent-packets/11.md" "$tmp/skip-outside/9.md"
for fmt in "" "--json"; do
  run_list "$lsk" $fmt
  [ "$rc" -eq 1 ] || fail "list $fmt with skipped packets should exit 1 (rc=$rc): $(cat "$tmp/ls.err")"
  grep -q "HEALTHY-SEVEN" "$tmp/ls.out" || fail "list $fmt must still show the healthy packet: $(cat "$tmp/ls.out")"
  grep -q -e "TRACKED-TITLE" -e "LINKED-TITLE" -e "skip-run-8" -e "skip-run-9" "$tmp/ls.out" "$tmp/ls.err" \
    && fail "list $fmt must not show the content of skipped packets: $(cat "$tmp/ls.out" "$tmp/ls.err")"
  grep -q "8.md: 読みませんでした (git で tracked)" "$tmp/ls.err" || fail "list $fmt should say the tracked packet was skipped: $(cat "$tmp/ls.err")"
  grep -q "9.md: 読みませんでした (symlink)" "$tmp/ls.err" || fail "list $fmt should say the symlinked packet was skipped: $(cat "$tmp/ls.err")"
  grep -q "10.md: 読みませんでした (regular file でない)" "$tmp/ls.err" || fail "list $fmt should say the non-regular packet was skipped: $(cat "$tmp/ls.err")"
  grep -q "11.md: 読みませんでした (git で tracked)" "$tmp/ls.err" || fail "list $fmt should skip a packet tracked under a different case: $(cat "$tmp/ls.err")"
  grep -q "読めません" "$tmp/ls.err" && fail "list $fmt must not try to read skipped packets: $(cat "$tmp/ls.err")"
  grep -q "ICASE-TITLE" "$tmp/ls.out" && fail "list $fmt must not show the case-variant tracked packet: $(cat "$tmp/ls.out")"
done
chmod 600 "$lsk/.agent-packets/8.md" "$lsk/.agent-packets/11.md" "$tmp/skip-outside/9.md"
# packet dir 自体が tracked (submodule の gitlink): どの packet も読まない
lskg="$tmp/listskipgitlink"
git init -q "$lskg"
(cd "$lskg" && git commit -q --allow-empty -m seed)
mkdir "$lskg/.agent-packets"
skip_packet "$lskg/.agent-packets/7.md" 7 "GITLINK-SEVEN"
(cd "$lskg" && git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),.agent-packets")
run_list "$lskg" --json
[ "$rc" -eq 1 ] || fail "list under a gitlink packet dir should exit 1 (rc=$rc)"
[ "$(cat "$tmp/ls.out")" = "[]" ] || fail "list under a gitlink packet dir must not show packets: $(cat "$tmp/ls.out")"
grep -q "7.md: 読みませんでした (git で tracked)" "$tmp/ls.err" || fail "list should say the packet under a gitlink was skipped: $(cat "$tmp/ls.err")"
# tracked かを判定できない (index が壊れていて git ls-files が失敗): 何も出さずに exit 1
lskb="$tmp/listskipbroken"
git init -q "$lskb"
mkdir "$lskb/.agent-packets"
skip_packet "$lskb/.agent-packets/7.md" 7 "BROKEN-INDEX-SEVEN"
printf 'broken' > "$lskb/.git/index"
run_list "$lskb" --json
[ "$rc" -eq 1 ] || fail "list with an unreadable index should exit 1 (rc=$rc)"
[ "$(cat "$tmp/ls.out")" = "[]" ] || fail "list with an unreadable index must not show packets: $(cat "$tmp/ls.out")"
grep -q "判定できません" "$tmp/ls.err" || fail "list should say tracked cannot be determined: $(cat "$tmp/ls.err")"
# packet dir 自体が symlink: 何も読まずに exit 1
lskd="$tmp/listskipdir"
git init -q "$lskd"
ln -s "$lsk/.agent-packets" "$lskd/.agent-packets"
run_list "$lskd" --json
[ "$rc" -eq 1 ] || fail "list through a symlinked packet dir should exit 1 (rc=$rc)"
[ "$(cat "$tmp/ls.out")" = "[]" ] || fail "list through a symlinked packet dir must not read packets: $(cat "$tmp/ls.out")"
grep -q "packet dir が symlink なので読みませんでした" "$tmp/ls.err" || fail "list should say the packet dir is a symlink: $(cat "$tmp/ls.err")"
# tracked かを判定できない (repository / index を選ぶ環境変数を継承): 何も出さずに exit 1
set +e
(cd "$lsk" && env "GIT_INDEX_FILE=$tmp/skip-other.index" "$pkt" list --json > "$tmp/ls.out" 2> "$tmp/ls.err")
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "list with GIT_INDEX_FILE inherited should exit 1 (rc=$rc)"
[ "$(cat "$tmp/ls.out")" = "[]" ] || fail "list must not show packets when tracked cannot be determined: $(cat "$tmp/ls.out")"
grep -q "GIT_INDEX_FILE を継承しているので" "$tmp/ls.err" || fail "list should name the inherited variable: $(cat "$tmp/ls.err")"
# 継承した GIT_DIR が packet dir の無い repository を指していても、「packet 未運用」(0 件・exit 0) にしない
set +e
(cd "$lsk" && env "GIT_DIR=$empty/.git" "$pkt" list --json > "$tmp/ls.out" 2> "$tmp/ls.err")
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "list with GIT_DIR inherited (no packet dir there) should exit 1, not report no packets (rc=$rc): $(cat "$tmp/ls.err")"
[ "$(cat "$tmp/ls.out")" = "[]" ] || fail "list with GIT_DIR inherited must not show packets: $(cat "$tmp/ls.out")"
grep -q "GIT_DIR を継承しているので" "$tmp/ls.err" || fail "list should name GIT_DIR: $(cat "$tmp/ls.err")"

# ---- list: 起動の記録 (run / tab。#315) ------------------------------------------------
# run dir の状態は done.txt の有無で分ける (stat だけ)。記録の無い packet は今までと同じ。
runrepo="$tmp/runrepo"
git init -q "$runrepo"
mkdir -p "$runrepo/.agent-packets" "$tmp/run-fin" "$tmp/run-unfin"
: > "$tmp/run-fin/done.txt"
run_packet() { # issue state extra-frontmatter-lines
  { printf -- '---\nissue: %s\ntitle: run %s\nstate: %s\nworker: codex\n' "$1" "$1" "$2"
    printf 'updated: 2026-09-23T10:00:00+09:00\n%s---\n\n## 結果\n\n### 2026-09-23 worker/codex\n- RUN-RESULT\n\n## 次の入口\n\nRUN-NEXT\n' "$3"
  } > "$runrepo/.agent-packets/$1.md"
}
run_packet 21 open "run: $tmp/run-fin
tab: \"#21\"
"
run_packet 22 blocked "run: $tmp/run-unfin
tab: \"#22\"
"
run_packet 23 open "run: $tmp/run-gone
"
run_packet 24 review ""
(cd "$runrepo" && "$pkt" list --json > "$tmp/run.json") || fail "run/tab packets should list cleanly"
[ "$(jget "$tmp/run.json" 0 run_status)" = '"finished"' ] || fail "done.txt present -> finished: $(jget "$tmp/run.json" 0 run_status)"
[ "$(jget "$tmp/run.json" 0 tab)" = '"#21"' ] || fail "quoted tab should keep '#': $(jget "$tmp/run.json" 0 tab)"
[ "$(jget "$tmp/run.json" 0 run)" = "\"$tmp/run-fin\"" ] || fail "run path in json: $(jget "$tmp/run.json" 0 run)"
[ "$(jget "$tmp/run.json" 1 run_status)" = '"unfinished"' ] || fail "run dir without done.txt -> unfinished"
[ "$(jget "$tmp/run.json" 2 run_status)" = '"missing"' ] || fail "absent run dir -> missing"
[ "$(jget "$tmp/run.json" 2 tab)" = "nil" ] || fail "tab is optional"
[ "$(jget "$tmp/run.json" 3 run)" = "nil" ] || fail "no launch record -> run nil"
[ "$(jget "$tmp/run.json" 3 run_status)" = "nil" ] || fail "no launch record -> run_status nil"
out=$(cd "$runrepo" && "$pkt" list)
echo "$out" | grep -q "^#21 .*\[run: finished\]" || fail "text list should mark finished run: $out"
echo "$out" | grep -q "^#22 .*\[run: unfinished\]" || fail "text list should mark unfinished run: $out"
echo "$out" | grep -q "^#23 .*\[run: missing\]" || fail "text list should mark missing run dir: $out"
echo "$out" | grep "^#24 " | grep -q "run:" && fail "packet without launch record must not be marked: $out"
# 書き間違い / 不正な値は壊れた packet (黙って「記録なし」にしない。記録が消えると二重起動の検査が効かない)
for bad in 'tab: #25' 'tab: ""' 'run: tmp/relative' 'run: "/tmp/a\nb"' 'run: 12' 'run:'; do
  run_packet 25 open "$bad
"
  set +e
  (cd "$runrepo" && "$pkt" list > "$tmp/out" 2> "$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "invalid launch record ($bad) should be a broken packet, exit 1 (rc=$rc)"
  grep -q "25.md" "$tmp/err" || fail "warning should name the packet ($bad): $(cat "$tmp/err")"
  grep -q "^#21 " "$tmp/out" || fail "healthy rows must still be listed ($bad)"
done
rm "$runrepo/.agent-packets/25.md"
# 最後の run dir (last_run。#325): 完了の転記で run から移す。json には出し、text の一覧には出さない
run_packet 26 review "last_run: $tmp/run-fin
"
(cd "$runrepo" && "$pkt" list --json > "$tmp/run.json") || fail "last_run packet should list cleanly"
[ "$(jget "$tmp/run.json" 4 issue)" = "26" ] || fail "last_run packet should be the 5th row: $(jget "$tmp/run.json" 4 issue)"
[ "$(jget "$tmp/run.json" 4 last_run)" = "\"$tmp/run-fin\"" ] || fail "last_run path in json: $(jget "$tmp/run.json" 4 last_run)"
[ "$(jget "$tmp/run.json" 4 run)" = "nil" ] || fail "last_run is not a launch record (run stays nil)"
[ "$(jget "$tmp/run.json" 4 run_status)" = "nil" ] || fail "last_run must not produce run_status"
[ "$(jget "$tmp/run.json" 0 last_run)" = "nil" ] || fail "packet without last_run -> nil"
out=$(cd "$runrepo" && "$pkt" list)
echo "$out" | grep "^#26 " | grep -q -e "run:" -e "run-fin" && fail "text list must not show last_run: $out"
for bad in 'last_run: tmp/relative' 'last_run: ""' 'last_run: "/tmp/a\nb"' 'last_run: 12' 'last_run:' "run: $tmp/run-unfin
last_run: $tmp/run-fin"; do
  run_packet 25 open "$bad
"
  set +e
  (cd "$runrepo" && "$pkt" list > "$tmp/out" 2> "$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "invalid last_run ($bad) should be a broken packet, exit 1 (rc=$rc)"
  grep -q "25.md" "$tmp/err" || fail "warning should name the packet ($bad): $(cat "$tmp/err")"
  grep -q "^#26 " "$tmp/out" || fail "healthy rows must still be listed ($bad)"
done
grep -q "同時に置けません" "$tmp/err" || fail "run + last_run should be reported as such: $(cat "$tmp/err")"
rm "$runrepo/.agent-packets/25.md"
# publish: 写しに run / tab を載せず (run は local path)、published の更新で消さない
calls=$(gh_calls)
out=$(cd "$runrepo" && "$pkt" publish 21 --dry-run)
echo "$out" | grep -q "RUN-RESULT" || fail "publish dry-run should carry the latest result: $out"
echo "$out" | grep -q "run-fin" && fail "publish must not carry the run path: $out"
echo "$out" | grep -q '#21"' && fail "publish must not carry the tab: $out"
(cd "$runrepo" && with_gh "$pkt" publish 21 >/dev/null) || fail "publish with launch record should succeed"
[ "$(gh_calls)" -eq $((calls + 1)) ] || fail "publish with launch record should call gh once"
grep -q "run-fin" "$gh_body" && fail "posted body must not carry the run path"
grep -q "^run: $tmp/run-fin$" "$runrepo/.agent-packets/21.md" || fail "publish must keep run in the packet"
grep -q '^tab: "#21"$' "$runrepo/.agent-packets/21.md" || fail "publish must keep tab in the packet"
grep -q "^published: 20" "$runrepo/.agent-packets/21.md" || fail "publish should still mark published"
# last_run も写しに載せず、published の更新で消さない
out=$(cd "$runrepo" && "$pkt" publish 26 --dry-run)
echo "$out" | grep -q "run-fin" && fail "publish must not carry last_run: $out"
(cd "$runrepo" && with_gh "$pkt" publish 26 >/dev/null) || fail "publish with last_run should succeed"
[ "$(gh_calls)" -eq $((calls + 2)) ] || fail "publish with last_run should call gh once more"
grep -q "run-fin" "$gh_body" && fail "posted body must not carry last_run"
grep -q "^last_run: $tmp/run-fin$" "$runrepo/.agent-packets/26.md" || fail "publish must keep last_run in the packet"
# 以降の case は gh の呼び出し回数を 0 から数えるので、fake gh の記録を戻す
rm -f "$gh_log" "$gh_body"

cp "$repo/.agent-packets/7.md" "$tmp/7.bak"

# ---- publish --dry-run: 合成だけ。gh は呼ばない ------------------------------------
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run)
echo "$out" | grep -q "^<!-- agent-packet issue=7 published=" || fail "dry-run should start with marker: $out"
echo "$out" | grep -q "NEW-SECTION-LINE" || fail "dry-run should carry latest 結果 section"
echo "$out" | grep -q "OLD-SECTION-LINE" && fail "dry-run must not carry older 結果 sections"
echo "$out" | grep -q "FENCED-SAMPLE-LINE" || fail "fenced sample inside the latest section is part of it and must be carried"
echo "$out" | grep -q "NEXT-ENTRY-LINE" || fail "dry-run should carry 次の入口"
echo "$out" | grep -q "PRIVATE-COMMENT" && fail "dry-run must strip HTML comments"
echo "$out" | grep -q "COMMENT-DRAFT-LINE" && fail "a '### ' line inside a comment must not start the latest section (R293-01)"
echo "$out" | grep -q "^### 下書き" && fail "comment-internal heading must not leak (R293-01)"
echo "$out" | grep -q "受け入れ条件" && fail "dry-run must not carry 依頼"
echo "$out" | grep -q "REQUEST-SAMPLE" && fail "fenced sample inside 依頼 must not be carried (R293-06)"
echo "$out" | grep -q "REQUEST-INDENTED-CODE-ENTRY" && fail "an indented '## 次の入口' inside 依頼 is not a heading (R293-10)"
echo "$out" | grep -q "REQUEST-INLINE-SAMPLE" && fail "inline triple backticks must not flip fence state (R293-11)"
[ "$(gh_calls)" -eq 0 ] || fail "dry-run must not call gh"
grep -q "^published:" "$repo/.agent-packets/7.md" && fail "dry-run must not mark published"

# ---- publish: 行頭 `## ` の予約違反 / 重複は投稿前に exit 2 (fenced code の中でも。R293-06/07/09/11 の構造的な閉じ方) ----
refuse_case() {
  # $1 = 説明、stdin = 依頼に足す行
  cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
  ruby -e 'src = File.read(ARGV[0]); add = STDIN.read; src.sub!(/^- 受け入れ条件: foo\n/) { |m| m + add }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md"
  set +e
  out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$1: should be refused with exit 2 (rc=$rc): $out"
  echo "$out" | grep -q "予約\|重複" || fail "$1: should explain the reserved heading rule: $out"
  echo "$out" | grep -q "REQUEST-" && fail "$1: refused publish must not print 依頼 content"
  return 0 # 末尾の `cmd && fail` が不一致 (正常) で 1 を返し、set -e で黙って落ちるのを防ぐ
}
printf '```markdown\n## 結果\nREQUEST-FENCED-H2\n```\n' | refuse_case "column-0 H2 inside a fence"
printf '````markdown\n```\n## 次の入口\nREQUEST-NESTED-H2\n````\n' | refuse_case "H2 inside nested fences (R293-07)"
printf -- '- ```inline``` then fence:\n\n```\n## 次の入口\nREQUEST-INLINE-H2\n```\n' | refuse_case "H2 after an inline-code line (R293-11)"
printf '```markdown\n    ```\n## 次の入口\nREQUEST-INDENTED-FENCE-H2\n```\n' | refuse_case "H2 after an indented fence line (R293-09)"
printf '## 参考\nREQUEST-EXTRA-H2\n' | refuse_case "unknown H2"
printf '## 結果\nREQUEST-DUP-H2\n' | refuse_case "duplicate H2"
# R293-12: comment 除去で節境界が作り替わる並び (fence 内の `<!-- x -->## 結果` と、節をまたぐ comment)
printf '```html\n<!-- sample -->## 結果\n```\nREQUEST-ONLY\n```html\n<!--\n```\n' > "$tmp/r12.add"
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
ruby -e 'src = File.read(ARGV[0]); add = File.read(ARGV[1]); src.sub!(/^- 受け入れ条件: foo\n/) { |m| m + add }; src.sub!(/^## 次の入口\n/) { "```html\n-->\n```\n\n## 次の入口\n" }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md" "$tmp/r12.add"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "comment spanning sections should be refused (R293-12) (rc=$rc): $out"
echo "$out" | grep -q "REQUEST-ONLY" && fail "R293-12: 依頼 content must not be printed"
echo "$out" | grep -q "またいで\|入れ子\|閉じていない\|対応しない" || fail "R293-12: should explain the comment problem: $out"
# R293-14: 切り捨てる範囲 (古い entry の前) にある閉じていない `<!--` は、切り出した後では見えない。
# 節全体で検査して拒否する (下書きが公開されない)
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^## 結果\n/) { "## 結果\n<!--\n" }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unclosed comment before the latest entry should be refused (R293-14) (rc=$rc): $out"
echo "$out" | grep -q "NEW-SECTION-LINE\|OLD-SECTION-LINE\|NEXT-ENTRY-LINE" && fail "R293-14: refused publish must not print body"
echo "$out" | grep -q "入れ子\|閉じていない" || fail "R293-14: should explain the comment problem: $out"
# Codex の再現条件そのもの (後続に `-->` が一切無い): 閉じていない `<!--`
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^## 結果\n/) { "## 結果\n<!--\n" }; src.gsub!(/<!-- PRIVATE-COMMENT.*?-->\n/m) { "" }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unclosed comment with no closer at all should be refused (R293-14) (rc=$rc): $out"
echo "$out" | grep -q "NEW-SECTION-LINE\|NEXT-ENTRY-LINE" && fail "R293-14 (no closer): refused publish must not print body"
echo "$out" | grep -q "閉じていない" || fail "R293-14 (no closer): should say unclosed: $out"
# 節をまたがない・entry をまたがない comment は従来どおり除去して通る (古い entry の中の閉じた comment)
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^- OLD-SECTION-LINE\n/) { "- OLD-SECTION-LINE\n<!-- closed inside old entry -->\n" }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md"
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run) || fail "a closed comment inside an old entry must not block publish"
echo "$out" | grep -q "NEW-SECTION-LINE" || fail "closed-comment case should still carry the latest entry"
# R293-15: 最初の見出しより前 (節に入らない前文) の閉じていない `<!--` は、節単位の検査では見えない
calls=$(gh_calls)
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
# 閉じた comment を先に消してから、先頭に未閉鎖の `<!--` を置く (逆順だと lazy な gsub が未閉鎖の方を巻き込む)
ruby -e 'src = File.read(ARGV[0]); src.gsub!(/<!-- .*?-->\n?/m) { "" }; src.sub!(/^## 依頼\n/) { "<!-- 未公開の下書き\n## 依頼\n" }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md"
grep -q "^<!-- 未公開" "$repo/.agent-packets/7.md" || fail "R293-15 fixture should keep the leading unclosed comment"
cp "$repo/.agent-packets/7.md" "$tmp/7.r15"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unclosed comment before the first heading should be refused (R293-15) (rc=$rc): $out"
echo "$out" | grep -q "NEW-SECTION-LINE\|NEXT-ENTRY-LINE" && fail "R293-15: refused publish must not print body"
[ "$(gh_calls)" -eq "$calls" ] || fail "R293-15: refused publish must not call gh"
cmp -s "$tmp/7.r15" "$repo/.agent-packets/7.md" || fail "R293-15: refused publish must not modify the packet"
# R293-13: 未知 H2 の診断に本文 (secret) を出さない
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
printf '## %s\nREQUEST-SECRET-H2\n' "$gh_token" > "$tmp/r13.add"
ruby -e 'src = File.read(ARGV[0]); add = File.read(ARGV[1]); src.sub!(/^- 受け入れ条件: foo\n/) { |m| m + add }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md" "$tmp/r13.add"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown H2 carrying a secret should be refused (rc=$rc)"
echo "$out" | grep -q "$gh_token" && fail "R293-13: diagnostic must not echo the heading text (secret)"
echo "$out" | grep -q "行目" || fail "R293-13: diagnostic should carry the line number: $out"
[ "$(gh_calls)" -eq 0 ] || fail "refused cases must not call gh"
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"

# ---- publish: gate が止める (definite) → exit 1、gh を呼ばない、値を出さない -----------
cp "$repo/.agent-packets/7.md" "$tmp/7.bak"
printf '\ntoken = "%s"\n' "$gh_token" >> "$repo/.agent-packets/7.md"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "definite finding should be exit 1 (rc=$rc): $out"
echo "$out" | grep -q "github-token" || fail "gate diagnostic should be relayed: $out"
echo "$out" | grep -q "$gh_token" && fail "secret value must not be echoed"
[ "$(gh_calls)" -eq 0 ] || fail "rejected publish must not call gh"
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"

# ---- publish: gate が検査できない (壊れた local regex) → exit 2、gh を呼ばない ----------
echo "([" > "$HOME/.config/agent-tools/public-safety-patterns.local"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "gate exit 2 should propagate as exit 2 (rc=$rc): $out"
[ "$(gh_calls)" -eq 0 ] || fail "unscanned publish must not call gh"
rm "$HOME/.config/agent-tools/public-safety-patterns.local"

# ---- publish: gate 不在 → exit 2、gh を呼ばない -------------------------------------
mv "$deploy/personal-public-safety-gate" "$tmp/gate.away"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing gate should be exit 2 (rc=$rc): $out"
[ "$(gh_calls)" -eq 0 ] || fail "missing gate must not call gh"
mv "$tmp/gate.away" "$deploy/personal-public-safety-gate"

# ---- publish: 成功。gh の引数 / 本文 / published 更新 ----------------------------------
# 投稿の瞬間 (gh hook) に、更新内容は同じ dir の一時 file に書き切られ、原本はまだ不変 (R293-16)
printf 'ls %s/.7.md.tmp > %s 2>/dev/null; cmp -s %s %s && echo intact >> %s\n' \
  "$(shq "$repo/.agent-packets")" "$(shq "$tmp/at-post")" "$(shq "$tmp/7.bak")" "$(shq "$repo/.agent-packets/7.md")" "$(shq "$tmp/at-post")" > "$gh_hook"
out=$(cd "$repo" && with_gh "$pkt" publish 7 --repo owner/repo)
rm -f "$gh_hook"
grep -q "\.7\.md\.tmp" "$tmp/at-post" || fail "R293-16: updated content should be in a sibling temp file at post time: $(cat "$tmp/at-post")"
grep -q "^intact$" "$tmp/at-post" || fail "R293-16: the packet must be unchanged at post time"
[ -z "$(ls "$repo/.agent-packets"/.7.md.tmp 2>/dev/null)" ] || fail "R293-16: temp file must not remain after success"
[ "$(gh_calls)" -eq 1 ] || fail "publish should call gh once"
grep -q "^issue comment 7 --repo owner/repo --body-file " "$gh_log" || fail "gh args: $(cat "$gh_log")"
grep -q "^<!-- agent-packet issue=7 published=" "$gh_body" || fail "posted body should carry marker"
grep -q "NEW-SECTION-LINE" "$gh_body" || fail "posted body should carry latest section"
echo "$out" | grep -q "example.invalid/comment/1" || fail "should print comment url: $out"
grep -q "^published: 20" "$repo/.agent-packets/7.md" || fail "published should be written to frontmatter"
grep -q "^updated: 2026-09-21T23:50:00+09:00$" "$repo/.agent-packets/7.md" || fail "updated must be untouched"
grep -q "NEXT-ENTRY-LINE" "$repo/.agent-packets/7.md" || fail "body must be untouched"
(cd "$repo" && "$pkt" list --json > "$tmp/list2.json")
[ "$(jget "$tmp/list2.json" 0 unpublished)" = "false" ] || fail "after publish, unpublished should be false"

# 2 回目は published 行を置き換える (重複しない)
(cd "$repo" && with_gh "$pkt" publish 7 >/dev/null)
[ "$(grep -c '^published:' "$repo/.agent-packets/7.md")" -eq 1 ] || fail "published line should be replaced, not duplicated"

# ---- publish: published を更新できない表現 (引用 key / 重複) は投稿前に exit 2 (R293-02) --------
calls=$(gh_calls)
cp "$tmp/7.bak" "$tmp/7.quoted"
printf '"published": 2026-09-01T00:00:00+09:00\n' | sed '' > "$tmp/ins"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^updated:.*\n/) { |u| u + File.read(ARGV[1]) }; File.write(ARGV[0], src)' "$tmp/7.quoted" "$tmp/ins"
cp "$tmp/7.quoted" "$repo/.agent-packets/7.md"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "quoted published key should be refused before posting (rc=$rc): $out"
[ "$(gh_calls)" -eq "$calls" ] || fail "refused publish must not call gh"
cmp -s "$tmp/7.quoted" "$repo/.agent-packets/7.md" || fail "refused publish must not modify the packet"
cp "$tmp/7.bak" "$tmp/7.dup"
printf 'published: 2026-09-01T00:00:00+09:00\npublished: 2026-09-02T00:00:00+09:00\n' > "$tmp/ins"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^updated:.*\n/) { |u| u + File.read(ARGV[1]) }; File.write(ARGV[0], src)' "$tmp/7.dup" "$tmp/ins"
cp "$tmp/7.dup" "$repo/.agent-packets/7.md"
set +e
(cd "$repo" && with_gh "$pkt" publish 7 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "duplicate published lines should be refused before posting (rc=$rc)"
[ "$(gh_calls)" -eq "$calls" ] || fail "refused publish (dup) must not call gh"

# ---- publish: flow mapping で published の行置換が他 field を巻き込む → 投稿前に exit 2 (R293-05) ----
cat > "$repo/.agent-packets/7.md" <<'EOF'
---
{ issue: 7, title: flow, state: review, worker: claude,
updated: "2026-09-21T23:50:00+09:00",
published: "2026-09-01T00:00:00+09:00", branch: feat/7-flow, pr: 8
}
---

## 結果

### 2026-09-21 worker/claude
- FLOW-LINE

## 次の入口

FLOW-ENTRY
EOF
(cd "$repo" && "$pkt" list --json > "$tmp/flow.json") || fail "flow mapping should parse for list"
[ "$(jget "$tmp/flow.json" 0 branch)" = '"feat/7-flow"' ] || fail "flow mapping branch should parse"
cp "$repo/.agent-packets/7.md" "$tmp/7.flow"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "flow mapping whose published line carries other fields must be refused (rc=$rc): $out"
[ "$(gh_calls)" -eq "$calls" ] || fail "refused publish (flow) must not call gh"
cmp -s "$tmp/7.flow" "$repo/.agent-packets/7.md" || fail "refused publish (flow) must not modify the packet"

# 上の flow fixture は「無引用の日時 stamp が flow context で YAML として不正」という経路でも拒否される
# ので、same_except_published? (published 以外の field / body が不変であることの guard) は unit で
# 直接 pin する (stamp の形式が変わっても guard が残るように)。
ruby -r"$script_dir/lib/check_helper" - "$packet_src" <<'RUBY'
require ARGV[0]
base = { issue: 7, title: "t", branch: "b", pr: 1, state: "open", worker: "claude",
         updated: Time.iso8601("2026-09-21T23:50:00+09:00"), published: nil,
         run: "/tmp/run-7", tab: "#7", last_run: nil, body: "x\n" }
mk = ->(over) { Packet::Front.new("p").tap { |f| base.merge(over).each { |k, v| f[k] = v } } }
a = mk.call({})
check("published だけ違えば same", Packet.same_except_published?(a, mk.call(published: Time.now)))
check("branch が消えれば not same", !Packet.same_except_published?(a, mk.call(branch: nil)))
check("pr が消えれば not same", !Packet.same_except_published?(a, mk.call(pr: nil)))
check("run が消えれば not same (#315)", !Packet.same_except_published?(a, mk.call(run: nil)))
check("tab が消えれば not same (#315)", !Packet.same_except_published?(a, mk.call(tab: nil)))
check("last_run が変われば not same (#325)", !Packet.same_except_published?(a, mk.call(last_run: "/tmp/run-6")))
check("body が変われば not same", !Packet.same_except_published?(a, mk.call(body: "y\n")))
check("updated が変われば not same", !Packet.same_except_published?(a, mk.call(updated: Time.now + 60)))
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- publish: 書き込み不可の packet は投稿前に exit 2 / 投稿直後に不可になったら URL 付きで区別 (R293-08) ----
if [ "$(id -u)" -eq 0 ]; then
  echo "skip: running as root; write-permission cases are not meaningful" >&2
else
  cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
  chmod 444 "$repo/.agent-packets/7.md"
  set +e
  out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
  rc=$?
  set -e
  chmod 644 "$repo/.agent-packets/7.md"
  [ "$rc" -eq 2 ] || fail "read-only packet should be refused before posting (rc=$rc): $out"
  [ "$(gh_calls)" -eq "$calls" ] || fail "read-only packet must not call gh"
  echo "$out" | grep -q "書き込みできません" || fail "read-only packet should say so: $out"
  # 投稿の瞬間に file が read-only になっても、更新内容は投稿前に一時 file へ書き切ってあり rename で
  # 差し替えられる (投稿だけ残って published が更新されない経路が無い。R293-08 / R293-16)
  printf 'chmod 444 %s\n' "$(shq "$repo/.agent-packets/7.md")" > "$gh_hook"
  set +e
  out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
  rc=$?
  set -e
  rm -f "$gh_hook"
  chmod 644 "$repo/.agent-packets/7.md"
  [ "$rc" -eq 0 ] || fail "read-only at post time should still complete via rename (rc=$rc): $out"
  [ "$(gh_calls)" -eq $((calls + 1)) ] || fail "read-only-at-post case should have posted exactly once"
  grep -q "^published:" "$repo/.agent-packets/7.md" || fail "read-only-at-post case must have written published"
  [ -z "$(ls "$repo/.agent-packets"/.7.md.tmp 2>/dev/null)" ] || fail "R293-16: no temp file may remain after success"
  calls=$(gh_calls)
  # 投稿の瞬間に dir が書けなくなる → rename 失敗。投稿 1 回・URL と一時 file の案内・原本不変 (R293-16)
  cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
  printf 'chmod 555 %s\n' "$(shq "$repo/.agent-packets")" > "$gh_hook"
  set +e
  out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
  rc=$?
  set -e
  rm -f "$gh_hook"
  chmod 755 "$repo/.agent-packets"
  [ "$rc" -eq 2 ] || fail "rename failure after posting should be exit 2 (rc=$rc): $out"
  [ "$(gh_calls)" -eq $((calls + 1)) ] || fail "rename-failure case should have posted exactly once"
  echo "$out" | grep -q "example.invalid/comment/1" || fail "rename failure must report the posted url: $out"
  echo "$out" | grep -q "再実行せず" || fail "rename failure must warn against retrying: $out"
  cmp -s "$tmp/7.bak" "$repo/.agent-packets/7.md" || fail "rename failure must leave the original packet intact"
  ls "$repo/.agent-packets"/.7.md.tmp >/dev/null 2>&1 || fail "rename failure should leave the updated content in the temp file for manual recovery"
  rm -f "$repo/.agent-packets"/.7.md.tmp
  calls=$(gh_calls)
  # 読めない packet が 1 つあっても list は止まらず、健全な行を出して exit 1 (R293-18)
  printf -- '---\nissue: 6\ntitle: t\nstate: open\nworker: claude\nupdated: 2026-09-21T00:00:00+09:00\n---\n' > "$repo/.agent-packets/6.md"
  chmod 000 "$repo/.agent-packets/6.md"
  set +e
  out=$(cd "$repo" && "$pkt" list 2>"$tmp/err")
  rc=$?
  set -e
  chmod 644 "$repo/.agent-packets/6.md"
  rm "$repo/.agent-packets/6.md"
  [ "$rc" -eq 1 ] || fail "unreadable packet should be a broken row, exit 1 (R293-18) (rc=$rc)"
  echo "$out" | grep -q "^#7 " || fail "unreadable packet must not hide healthy rows: $out"
  grep -q "6.md" "$tmp/err" || fail "warning should name the unreadable packet: $(cat "$tmp/err")"
fi

# ---- publish: 同名の一時 file が既にあれば、消さずに拒否 (前回の回復用かもしれない。R293-19) ----
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
printf 'LEFTOVER-FROM-PREVIOUS-RUN\n' > "$repo/.agent-packets/.7.md.tmp"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "existing temp file should block publish (R293-19) (rc=$rc): $out"
[ "$(gh_calls)" -eq "$calls" ] || fail "existing temp file: must not call gh"
[ "$(cat "$repo/.agent-packets/.7.md.tmp")" = "LEFTOVER-FROM-PREVIOUS-RUN" ] || fail "existing temp file must be preserved (R293-19)"
cmp -s "$tmp/7.bak" "$repo/.agent-packets/7.md" || fail "existing temp file: packet must be unchanged"
echo "$out" | grep -q "既にあります" || fail "existing temp file: should explain: $out"
rm -f "$repo/.agent-packets/.7.md.tmp"

# ---- tag 付き key (`!!binary cHVibGlzaGVk`) は safe_load で published に化ける。parse 段階で拒否 (R293-20) ----
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
printf '!!binary cHVibGlzaGVk: 2026-09-01T00:00:00+09:00\n' > "$tmp/ins"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^updated:.*\n/) { |u| File.read(ARGV[1]) + u }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md" "$tmp/ins"
set +e
out=$(cd "$repo" && "$pkt" list 2>"$tmp/err")
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "tagged key should make the packet broken for list (R293-20) (rc=$rc)"
grep -q "tag" "$tmp/err" || fail "tagged key warning should mention tag: $(cat "$tmp/err")"
cp "$repo/.agent-packets/7.md" "$tmp/7.tag"
set +e
(cd "$repo" && with_gh "$pkt" publish 7 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "tagged key must be refused before posting (R293-20) (rc=$rc)"
[ "$(gh_calls)" -eq "$calls" ] || fail "refused publish (tagged key) must not call gh"
cmp -s "$tmp/7.tag" "$repo/.agent-packets/7.md" || fail "refused publish (tagged key) must not modify the packet"

# ---- publish: 別表記の published key (`"published"`) は YAML では同じ key。投稿前に拒否 (R293-17) ----
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
printf '"pub\\u006cished": "2026-09-01T00:00:00+09:00"\n' > "$tmp/ins"
ruby -e 'src = File.read(ARGV[0]); src.sub!(/^updated:.*\n/) { |u| File.read(ARGV[1]) + u }; File.write(ARGV[0], src)' "$repo/.agent-packets/7.md" "$tmp/ins"
grep -q 'pub\\u006cished' "$repo/.agent-packets/7.md" || fail "R293-17 fixture should carry the escaped key"
(cd "$repo" && "$pkt" list --json > "$tmp/alt.json") || fail "escaped key should still parse for list"
[ "$(jget "$tmp/alt.json" 0 published)" = '"2026-09-01T00:00:00+09:00"' ] || fail "escaped key should resolve to published for list"
cp "$repo/.agent-packets/7.md" "$tmp/7.alt"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "escaped published key must be refused before posting (R293-17) (rc=$rc): $out"
[ "$(gh_calls)" -eq "$calls" ] || fail "refused publish (escaped key) must not call gh"
cmp -s "$tmp/7.alt" "$repo/.agent-packets/7.md" || fail "refused publish (escaped key) must not modify the packet"

# ---- 不正 UTF-8 の packet は list で warning、publish は投稿前に exit 2 (R293-03) --------------
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
printf '\n\377bad byte\n' >> "$repo/.agent-packets/7.md"
set +e
out=$(cd "$repo" && "$pkt" list 2>"$tmp/err")
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "invalid utf-8 packet should be reported as broken (rc=$rc)"
grep -q "UTF-8" "$tmp/err" || fail "warning should say UTF-8: $(cat "$tmp/err")"
set +e
(cd "$repo" && with_gh "$pkt" publish 7 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid utf-8 packet should not be published (rc=$rc)"
[ "$(gh_calls)" -eq "$calls" ] || fail "invalid utf-8 publish must not call gh"

# ---- publish: gh 失敗 → exit 2、published は変えない、hand-off の案内 --------------------
cp "$tmp/7.bak" "$repo/.agent-packets/7.md"
echo 1 > "$gh_rc"
set +e
out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "gh failure should be exit 2 (rc=$rc): $out"
echo "$out" | grep -q "Claude か人が publish" || fail "gh failure should hand off: $out"
grep -q "^published:" "$repo/.agent-packets/7.md" && fail "failed publish must not mark published"
echo 0 > "$gh_rc"

# ---- publish: gh 不在 (PATH に無い) → exit 2 ------------------------------------------
# ruby / git の実 directory だけで PATH を組む (symlink で別 dir に置くと Apple の ruby は
# framework を解決できない)。その PATH に gh が居る環境では成立しないので skip する。
nogh_path="$(dirname "$(command -v ruby)"):$(dirname "$(command -v git)"):/bin"
if PATH="$nogh_path" command -v gh >/dev/null 2>&1; then
  echo "skip: gh shares a directory with ruby/git; cannot build a gh-less PATH" >&2
else
  set +e
  out=$(cd "$repo" && PATH="$nogh_path" "$pkt" publish 7 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing gh should be exit 2 (rc=$rc): $out"
  echo "$out" | grep -q "gh を起動できません" || fail "missing gh should say so: $out"
  grep -q "^published:" "$repo/.agent-packets/7.md" && fail "missing gh must not mark published"
fi

# ---- check: packet を書く前の更新先の検査 (#386) ------------------------------------------
# 通れば exit 0 で packet の path を 1 行、拒めば exit 1 で理由 (stderr)、判定できなければ exit 2。
# publish も書く前に同じ検査を通し、拒まれたら gh を呼ばず、packet も外の file も変えない。
chk_packet() { # path issue
  printf -- '---\nissue: %s\ntitle: chk\nstate: open\nworker: claude\nupdated: 2026-09-23T10:00:00+09:00\n---\n\n## 結果\n\n### 2026-09-23 worker/claude\n- CHK-RESULT\n\n## 次の入口\n\nCHK-NEXT\n' "$2" > "$1"
}
run_check() { # cwd issue -> rc / $tmp/chk.out / $tmp/chk.err
  set +e
  (cd "$1" && "$pkt" check "$2" > "$tmp/chk.out" 2> "$tmp/chk.err")
  rc=$?
  set -e
}
expect_refused() { # cwd issue 説明 理由の文言
  run_check "$1" "$2"
  [ "$rc" -eq 1 ] || fail "check ($3) should refuse with exit 1 (rc=$rc): $(cat "$tmp/chk.err")"
  [ ! -s "$tmp/chk.out" ] || fail "check ($3) must not print a path when refused: $(cat "$tmp/chk.out")"
  grep -q "$4" "$tmp/chk.err" || fail "check ($3) should say why ($4): $(cat "$tmp/chk.err")"
}
expect_publish_refused() { # cwd issue 説明
  pub_calls=$(gh_calls)
  set +e
  (cd "$1" && with_gh "$pkt" publish "$2" > "$tmp/pub.out" 2> "$tmp/pub.err")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "publish ($3) should stop before writing with exit 2 (rc=$rc): $(cat "$tmp/pub.err")"
  [ "$(gh_calls)" -eq "$pub_calls" ] || fail "publish ($3) must not call gh"
}

# 通常の untracked な packet: main worktree の root の実体からの path。subdir / linked worktree からも同じ
chk="$tmp/chkrepo"
git init -q "$chk"
(cd "$chk" && git commit -q --allow-empty -m seed)
mkdir -p "$chk/.agent-packets" "$chk/sub"
chk_packet "$chk/.agent-packets/7.md" 7
chk_path="$(cd "$chk" && pwd -P)/.agent-packets"
(cd "$chk" && git worktree add -q "$tmp/chkwt" -b chkwt)
for where in "$chk" "$chk/sub" "$tmp/chkwt"; do
  run_check "$where" 7
  [ "$rc" -eq 0 ] || fail "check on a plain untracked packet should pass from $where (rc=$rc): $(cat "$tmp/chk.err")"
  [ "$(cat "$tmp/chk.out")" = "$chk_path/7.md" ] || fail "check should print the main packet path from $where: $(cat "$tmp/chk.out")"
  [ ! -s "$tmp/chk.err" ] || fail "check should be quiet on success: $(cat "$tmp/chk.err")"
done
# packet が無い (これから作る) / dir も無い: exit 0。検査は file も dir も作らない
run_check "$chk" 8
[ "$rc" -eq 0 ] || fail "check on a missing packet should pass (rc=$rc): $(cat "$tmp/chk.err")"
[ "$(cat "$tmp/chk.out")" = "$chk_path/8.md" ] || fail "check should print the path of the packet to create: $(cat "$tmp/chk.out")"
[ ! -e "$chk/.agent-packets/8.md" ] || fail "check must not create the packet"
nodir="$tmp/chknodir"
git init -q "$nodir"
run_check "$nodir" 7
[ "$rc" -eq 0 ] || fail "check without a packet dir should pass (rc=$rc): $(cat "$tmp/chk.err")"
[ "$(cat "$tmp/chk.out")" = "$(cd "$nodir" && pwd -P)/.agent-packets/7.md" ] || fail "check without a packet dir should print the path: $(cat "$tmp/chk.out")"
[ ! -e "$nodir/.agent-packets" ] || fail "check must not create the packet dir"

# (a) packet dir が外を指す symlink: 拒否。publish も外の file を変えない
lnk="$tmp/chklink"
git init -q "$lnk"
mkdir -p "$tmp/chk-outside"
chk_packet "$tmp/chk-outside/7.md" 7
cp "$tmp/chk-outside/7.md" "$tmp/chk-outside.bak"
ln -s "$tmp/chk-outside" "$lnk/.agent-packets"
expect_refused "$lnk" 7 "symlinked packet dir" "packet dir が symlink"
expect_publish_refused "$lnk" 7 "symlinked packet dir"
cmp -s "$tmp/chk-outside.bak" "$tmp/chk-outside/7.md" || fail "publish through a symlinked packet dir must not change the file outside"
[ "$(ls -A "$tmp/chk-outside")" = "7.md" ] || fail "publish through a symlinked packet dir must not leave files outside: $(ls -A "$tmp/chk-outside")"
# (a) packet dir が directory でない
filedir="$tmp/chkfiledir"
git init -q "$filedir"
: > "$filedir/.agent-packets"
expect_refused "$filedir" 7 "packet dir that is a regular file" "packet dir が directory ではありません"

# (c) packet が外を指す symlink / 先の無い symlink / directory: 拒否。publish は symlink を差し替えない
rm "$lnk/.agent-packets"
mkdir "$lnk/.agent-packets"
ln -s "$tmp/chk-outside/7.md" "$lnk/.agent-packets/7.md"
expect_refused "$lnk" 7 "symlinked packet file" "packet が symlink"
expect_publish_refused "$lnk" 7 "symlinked packet file"
cmp -s "$tmp/chk-outside.bak" "$tmp/chk-outside/7.md" || fail "publish through a symlinked packet must not change the file outside"
[ -L "$lnk/.agent-packets/7.md" ] || fail "publish must not replace the symlinked packet"
ln -s "$tmp/chk-outside/8.md" "$lnk/.agent-packets/8.md"
expect_refused "$lnk" 8 "dangling symlinked packet (not a missing packet)" "packet が symlink"
[ ! -e "$tmp/chk-outside/8.md" ] || fail "check must not create the symlink target"
mkdir "$lnk/.agent-packets/9.md"
expect_refused "$lnk" 9 "directory in place of the packet" "packet が regular file ではありません"

# (d) git で tracked な packet: 拒否。publish は packet を変えない。worktree から消しても index にあれば拒否
trk="$tmp/chktracked"
git init -q "$trk"
mkdir "$trk/.agent-packets"
chk_packet "$trk/.agent-packets/7.md" 7
(cd "$trk" && git add -f .agent-packets/7.md)
cp "$trk/.agent-packets/7.md" "$tmp/chk-tracked.bak"
expect_refused "$trk" 7 "tracked packet" "tracked です"
expect_publish_refused "$trk" 7 "tracked packet"
cmp -s "$tmp/chk-tracked.bak" "$trk/.agent-packets/7.md" || fail "publish must not modify a tracked packet"
# (d) pathspec の大域設定 (GIT_*_PATHSPECS) を環境から継承しても判定は変わらない
# (GIT_LITERAL_PATHSPECS=1 だと `:(icase)` が magic でなく名前として照合され、tracked でも exit 1 になる)
for pathspec_env in GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS; do
  set +e
  (cd "$trk" && env "$pathspec_env=1" "$pkt" check 7 > "$tmp/chk.out" 2> "$tmp/chk.err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "check (tracked packet with $pathspec_env=1 inherited) should refuse with exit 1 (rc=$rc): $(cat "$tmp/chk.err")"
  grep -q "tracked です" "$tmp/chk.err" || fail "check (tracked packet with $pathspec_env=1 inherited) should say tracked: $(cat "$tmp/chk.err")"
  set +e
  (cd "$chk" && env "$pathspec_env=1" "$pkt" check 7 > "$tmp/chk.out" 2> "$tmp/chk.err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "check (untracked packet with $pathspec_env=1 inherited) should pass (rc=$rc): $(cat "$tmp/chk.err")"
done
# repository / index を選ぶ環境変数を継承していると判定できない (exit 2)。別の index を指す GIT_INDEX_FILE
# では tracked な packet も ls-files の上では追跡なしに見えるので、書いてよい判定 (exit 0) にしない
(cd "$trk" && GIT_INDEX_FILE="$tmp/chk-other.index" git read-tree --empty)
for repo_env in "GIT_INDEX_FILE=$tmp/chk-other.index" "GIT_DIR=$trk/.git" "GIT_WORK_TREE=$trk" \
  "GIT_COMMON_DIR=$trk/.git" "GIT_OBJECT_DIRECTORY=$trk/.git/objects" \
  "GIT_ALTERNATE_OBJECT_DIRECTORIES=$trk/.git/objects" "GIT_NAMESPACE=chk"; do
  set +e
  (cd "$trk" && env "$repo_env" "$pkt" check 7 > "$tmp/chk.out" 2> "$tmp/chk.err")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "check (tracked packet with ${repo_env%%=*} inherited) should be undeterminable, exit 2 (rc=$rc): $(cat "$tmp/chk.err")"
  [ ! -s "$tmp/chk.out" ] || fail "check (${repo_env%%=*} inherited) must not print a path"
  grep -q "${repo_env%%=*} を継承しているので" "$tmp/chk.err" || fail "check (${repo_env%%=*} inherited) should name the variable: $(cat "$tmp/chk.err")"
done
pub_calls=$(gh_calls)
set +e
(cd "$trk" && with_gh env "GIT_INDEX_FILE=$tmp/chk-other.index" "$pkt" publish 7 > "$tmp/pub.out" 2> "$tmp/pub.err")
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "publish (tracked packet with another GIT_INDEX_FILE) should stop with exit 2 (rc=$rc): $(cat "$tmp/pub.err")"
[ "$(gh_calls)" -eq "$pub_calls" ] || fail "publish (tracked packet with another GIT_INDEX_FILE) must not call gh"
grep -q "GIT_INDEX_FILE を継承しているので" "$tmp/pub.err" || fail "publish should name GIT_INDEX_FILE: $(cat "$tmp/pub.err")"
cmp -s "$tmp/chk-tracked.bak" "$trk/.agent-packets/7.md" || fail "publish with another GIT_INDEX_FILE must not modify the packet"
rm "$trk/.agent-packets/7.md"
expect_refused "$trk" 7 "tracked packet removed from the worktree" "tracked です"
# (d) 大文字小文字だけ違う名前で tracked (case-insensitive な file system では同じ file)
cis="$tmp/chkcase"
git init -q "$cis"
mkdir "$cis/.agent-packets"
chk_packet "$cis/.agent-packets/7.MD" 7
if [ -e "$cis/.agent-packets/7.md" ]; then
  (cd "$cis" && git add -f .agent-packets/7.MD)
  expect_refused "$cis" 7 "packet tracked under a case-only different name" "tracked です"
else
  echo "skip: case-sensitive file system; the case-only tracked packet case does not apply" >&2
fi
# (d) tracked かを判定できない (index が壊れている): exit 2
badidx="$tmp/chkbadindex"
git init -q "$badidx"
mkdir "$badidx/.agent-packets"
chk_packet "$badidx/.agent-packets/7.md" 7
printf 'not an index' > "$badidx/.git/index"
run_check "$badidx" 7
[ "$rc" -eq 2 ] || fail "check should exit 2 when git cannot tell whether the packet is tracked (rc=$rc): $(cat "$tmp/chk.err")"
[ ! -s "$tmp/chk.out" ] || fail "undeterminable check must not print a path"

# (b) packet dir の実体が main worktree の root の .agent-packets でない (git dir を外に置いた repo / bare)
git init -q --separate-git-dir="$tmp/chksep.git" "$tmp/chksep"
expect_refused "$tmp/chksep" 7 "packet dir outside the main worktree (separate git dir)" "一致しません"
[ ! -e "$tmp/.agent-packets" ] || fail "check must not create a packet dir outside the worktree"
git init -q --bare "$tmp/chkbare.git"
expect_refused "$tmp/chkbare.git" 7 "bare repository" "bare repository"
# (b) packet dir が submodule / 入れ子の repository: 中で tracked な packet は親の index に載らないので、
# dir の中から見た worktree の root で拒否する。publish も書かずに止まる
subsrc="$tmp/chksubsrc"
git init -q "$subsrc"
chk_packet "$subsrc/7.md" 7
(cd "$subsrc" && git add 7.md && git commit -q -m packet)
sub="$tmp/chksub"
git init -q "$sub"
(cd "$sub" && git commit -q --allow-empty -m seed && git submodule add -q "file://$subsrc" .agent-packets && git commit -q -m submodule)
cp "$sub/.agent-packets/7.md" "$tmp/chk-sub.bak"
expect_refused "$sub" 7 "packet tracked inside a submodule packet dir" "別の git の worktree です"
expect_publish_refused "$sub" 7 "packet tracked inside a submodule packet dir"
cmp -s "$tmp/chk-sub.bak" "$sub/.agent-packets/7.md" || fail "publish must not modify a packet inside a submodule"
nested="$tmp/chknested"
git init -q "$nested"
git init -q "$nested/.agent-packets"
chk_packet "$nested/.agent-packets/7.md" 7
(cd "$nested/.agent-packets" && git add 7.md)
expect_refused "$nested" 7 "packet dir that is a nested repository" "別の git の worktree です"
# (d) packet dir 自体に tracked な entry: deinit した submodule の gitlink だけが残る / 隣の packet が tracked
(cd "$sub" && git submodule deinit -q -f .agent-packets)
expect_refused "$sub" 7 "packet dir left as a gitlink (deinitialized submodule)" "packet dir に git で tracked な entry"
othertrk="$tmp/chkothertracked"
git init -q "$othertrk"
mkdir "$othertrk/.agent-packets"
chk_packet "$othertrk/.agent-packets/8.md" 8
(cd "$othertrk" && git add -f .agent-packets/8.md)
chk_packet "$othertrk/.agent-packets/7.md" 7
expect_refused "$othertrk" 7 "untracked packet next to a tracked one" "packet dir に git で tracked な entry"

# git の外: 判定できない (exit 2)
set +e
(cd "$tmp" && "$pkt" check 7 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "check outside git should be exit 2 (rc=$rc)"

# ---- 引数 ----------------------------------------------------------------------------
# fake gh を当てたまま走らせる (検証が退行して投稿処理に到達したら fake の呼び出し数で分かる。R293-04)
calls_before=$(gh_calls)
set +e
(cd "$repo" && with_gh "$pkt" publish seven >/dev/null 2>&1); [ $? -eq 2 ] || fail "non-numeric issue should be exit 2"
(cd "$repo" && with_gh "$pkt" publish 7 --repo bad >/dev/null 2>&1); [ $? -eq 2 ] || fail "bad repo slug should be exit 2"
(cd "$repo" && with_gh "$pkt" publish 7 --repo -x/y >/dev/null 2>&1); [ $? -eq 2 ] || fail "leading-dash repo should be exit 2"
(cd "$repo" && with_gh "$pkt" publish 7 --bogus >/dev/null 2>&1); [ $? -eq 2 ] || fail "unknown publish option should be exit 2"
(cd "$repo" && with_gh "$pkt" list --bogus >/dev/null 2>&1); [ $? -eq 2 ] || fail "unknown list option should be exit 2"
(cd "$repo" && with_gh "$pkt" check >/dev/null 2>&1); [ $? -eq 2 ] || fail "check without issue should be exit 2"
(cd "$repo" && with_gh "$pkt" check seven >/dev/null 2>&1); [ $? -eq 2 ] || fail "non-numeric check issue should be exit 2"
(cd "$repo" && with_gh "$pkt" check 0 >/dev/null 2>&1); [ $? -eq 2 ] || fail "check issue 0 should be exit 2"
(cd "$repo" && with_gh "$pkt" check 7 8 >/dev/null 2>&1); [ $? -eq 2 ] || fail "check with two issues should be exit 2"
(cd "$repo" && with_gh "$pkt" check 7 --bogus >/dev/null 2>&1); [ $? -eq 2 ] || fail "unknown check option should be exit 2"
(cd "$repo" && with_gh "$pkt" frobnicate >/dev/null 2>"$tmp/err"); [ $? -eq 2 ] || fail "unknown command should be exit 2"
grep -q "^usage:" "$tmp/err" || fail "unknown command should print usage on stderr"
(cd "$repo" && with_gh "$pkt" >/dev/null 2>&1); [ $? -eq 2 ] || fail "no args should be exit 2"
(cd "$repo" && with_gh "$pkt" --help > "$tmp/out" 2>&1); [ $? -eq 0 ] || fail "--help should be exit 0"
grep -q "^usage:" "$tmp/out" || fail "--help should print usage on stdout"
grep -q "personal-packet check <issue>" "$tmp/out" || fail "usage should list check"
[ "$(gh_calls)" -eq "$calls_before" ] || fail "argument errors must not call gh (calls=$(gh_calls))"
set -e

echo "ok: packet self-test"
