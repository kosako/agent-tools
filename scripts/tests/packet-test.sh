#!/bin/sh
# personal-packet.rb の self-test (#253 PR-2)。
# dir の worktree 解決 / list の frontmatter 判定 / publish の合成・gate 連携・gh 連携・
# published 更新を tmp repo で検証する。gh は PATH 先頭の fake で置き換え、実 HOME /
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
- packet の書式の例:

```markdown
## 結果
### 2030-01-01 sample/agent
REQUEST-SAMPLE-LINE
## 次の入口
REQUEST-SAMPLE-ENTRY
```
- 入れ子の例 (4 本の fence の中に、対になっていない 3 本の fence 行。3 本で外側を閉じたと誤認すると
  直後の見出しが本物として拾われる。R293-07):

````markdown
```
## 次の入口
REQUEST-NESTED-ENTRY
````

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
rm "$repo/.agent-packets/6.md"

# dir 無し = 未運用 (正常)
empty="$tmp/empty"
git init -q "$empty"
out=$(cd "$empty" && "$pkt" list)
[ "$out" = "no active packets" ] || fail "no dir should be empty list: $out"
[ "$(cd "$empty" && "$pkt" list --json)" = "[]" ] || fail "no dir json should be []"

# ---- publish --dry-run: 合成だけ。gh は呼ばない ------------------------------------
out=$(cd "$repo" && with_gh "$pkt" publish 7 --dry-run)
echo "$out" | grep -q "^<!-- agent-packet issue=7 published=" || fail "dry-run should start with marker: $out"
echo "$out" | grep -q "NEW-SECTION-LINE" || fail "dry-run should carry latest 結果 section"
echo "$out" | grep -q "FENCED-SAMPLE-LINE" || fail "fenced sample inside the latest section is part of it and must be carried"
echo "$out" | grep -q "^### 2030-01-01 fenced/sample" && { echo "$out" | grep -q "NEW-SECTION-LINE" || fail "a '### ' inside a fence must not split the latest section (R293-06)"; }
echo "$out" | grep -q "OLD-SECTION-LINE" && fail "dry-run must not carry older 結果 sections"
echo "$out" | grep -q "NEXT-ENTRY-LINE" || fail "dry-run should carry 次の入口"
echo "$out" | grep -q "PRIVATE-COMMENT" && fail "dry-run must strip HTML comments"
echo "$out" | grep -q "COMMENT-DRAFT-LINE" && fail "a '### ' line inside a comment must not start the latest section (R293-01)"
echo "$out" | grep -q "^### 下書き" && fail "comment-internal heading must not leak (R293-01)"
echo "$out" | grep -q "受け入れ条件" && fail "dry-run must not carry 依頼"
echo "$out" | grep -q "REQUEST-SAMPLE" && fail "headings inside fenced code must not start a section (R293-06)"
echo "$out" | grep -q "REQUEST-NESTED-ENTRY" && fail "a 3-tick fence must not close a 4-tick fence (R293-07)"
[ "$(gh_calls)" -eq 0 ] || fail "dry-run must not call gh"
grep -q "^published:" "$repo/.agent-packets/7.md" && fail "dry-run must not mark published"

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
out=$(cd "$repo" && with_gh "$pkt" publish 7 --repo owner/repo)
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
         updated: Time.iso8601("2026-09-21T23:50:00+09:00"), published: nil, body: "x\n" }
mk = ->(over) { Packet::Front.new("p").tap { |f| base.merge(over).each { |k, v| f[k] = v } } }
a = mk.call({})
check("published だけ違えば same", Packet.same_except_published?(a, mk.call(published: Time.now)))
check("branch が消えれば not same", !Packet.same_except_published?(a, mk.call(branch: nil)))
check("pr が消えれば not same", !Packet.same_except_published?(a, mk.call(pr: nil)))
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
  # 投稿の瞬間に read-only になる: 投稿は済み、保存は失敗 → exit 2 だが URL と手当てを示す
  printf 'chmod 444 %s\n' "$(shq "$repo/.agent-packets/7.md")" > "$gh_hook"
  set +e
  out=$(cd "$repo" && with_gh "$pkt" publish 7 2>&1)
  rc=$?
  set -e
  rm -f "$gh_hook"
  chmod 644 "$repo/.agent-packets/7.md"
  [ "$rc" -eq 2 ] || fail "save failure after posting should be exit 2 (rc=$rc): $out"
  [ "$(gh_calls)" -eq $((calls + 1)) ] || fail "save-failure case should have posted exactly once"
  echo "$out" | grep -q "example.invalid/comment/1" || fail "save failure must report the posted url: $out"
  echo "$out" | grep -q "再実行せず" || fail "save failure must warn against retrying: $out"
  grep -q "^published:" "$repo/.agent-packets/7.md" && fail "save failure must leave the packet unchanged"
  calls=$(gh_calls)
fi

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

# ---- 引数 ----------------------------------------------------------------------------
# fake gh を当てたまま走らせる (検証が退行して投稿処理に到達したら fake の呼び出し数で分かる。R293-04)
calls_before=$(gh_calls)
set +e
(cd "$repo" && with_gh "$pkt" publish seven >/dev/null 2>&1); [ $? -eq 2 ] || fail "non-numeric issue should be exit 2"
(cd "$repo" && with_gh "$pkt" publish 7 --repo bad >/dev/null 2>&1); [ $? -eq 2 ] || fail "bad repo slug should be exit 2"
(cd "$repo" && with_gh "$pkt" publish 7 --repo -x/y >/dev/null 2>&1); [ $? -eq 2 ] || fail "leading-dash repo should be exit 2"
(cd "$repo" && with_gh "$pkt" publish 7 --bogus >/dev/null 2>&1); [ $? -eq 2 ] || fail "unknown publish option should be exit 2"
(cd "$repo" && with_gh "$pkt" list --bogus >/dev/null 2>&1); [ $? -eq 2 ] || fail "unknown list option should be exit 2"
(cd "$repo" && with_gh "$pkt" frobnicate >/dev/null 2>"$tmp/err"); [ $? -eq 2 ] || fail "unknown command should be exit 2"
grep -q "^usage:" "$tmp/err" || fail "unknown command should print usage on stderr"
(cd "$repo" && with_gh "$pkt" >/dev/null 2>&1); [ $? -eq 2 ] || fail "no args should be exit 2"
(cd "$repo" && with_gh "$pkt" --help > "$tmp/out" 2>&1); [ $? -eq 0 ] || fail "--help should be exit 0"
grep -q "^usage:" "$tmp/out" || fail "--help should print usage on stdout"
[ "$(gh_calls)" -eq "$calls_before" ] || fail "argument errors must not call gh (calls=$(gh_calls))"
set -e

echo "ok: packet self-test"
