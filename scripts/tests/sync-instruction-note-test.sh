#!/bin/sh
# sync が instruction を書き換えるときの配備の報告 (変わった節の note と、続いている session の注意) の self-test (#688)。
# 一時 directory に fixture と fake tool homes を生成して検証する。実際の tool home には触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
build="$script_dir/../build.sh"
register="$script_dir/../register.sh"
connect="$script_dir/../connect.sh"
sync="$script_dir/../sync.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# 手元の local の断片 (<XDG_CONFIG_HOME>/agent-tools/instructions.local.md。#689) を読ませず、case が置く断片だけを読ませる。
XDG_CONFIG_HOME="$tmp/xdg-config"
export XDG_CONFIG_HOME
fragment="$XDG_CONFIG_HOME/agent-tools/instructions.local.md"
source_md="$tmp/repo/shared/instructions/personal-ops.md"
codex_file="$tmp/codex/AGENTS.md"
claude_file="$tmp/claude/agent-tools/CLAUDE.md"
running='note: sessions that were already running keep the previous instruction until they reload it (Claude Code: at the next compaction or after a restart)'

# 引数の行を instruction の source に書いて、build と register をやり直す。
write_source() {
  for ws_line in "$@"; do
    printf '%s\n' "$ws_line"
  done > "$source_md"
  "$build" --root "$tmp/repo" --quiet > /dev/null
  "$register" --root "$tmp/repo" --quiet > /dev/null
}

# sync を走らせる。出力は $tmp/out、exit code は $rc。
run_sync() {
  rc=0
  "$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" "$@" \
    > "$tmp/out" 2>&1 || rc=$?
}

# 出力の中の、完全に一致する行の数。
count_line() {
  grep -c -F -x -- "$1" "$tmp/out" || true
}

# 出力の中で、完全に一致する行が最初に出る行番号 (無ければ空)。
line_no() {
  grep -n -F -x -- "$1" "$tmp/out" | head -n 1 | cut -d: -f1
}

note_count() {
  grep -c '^note: ' "$tmp/out" || true
}

expect_notes() {
  [ "$(note_count)" = "$1" ] || fail "$2: expected $1 note line(s): $(cat "$tmp/out")"
}

# --- fixture: instruction の asset を配り、所有 file を確立する ---
mkdir -p "$tmp/codex" "$tmp/claude"
make_demo_repo "$tmp/repo" instructions personal-ops instruction \
  '# 運用ルール' '' '## 言語' '' '- 日本語' '' '## public safety' '' '- secret を入れない' '' '## 消える節' '' '- 古い決まり'
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --apply --quiet > /dev/null
run_sync --apply
[ "$rc" = 0 ] || fail "baseline sync should succeed: $(cat "$tmp/out")"
expect_notes 0 "baseline (up-to-date)"

# --- case 1: dry-run は、変わった節の行だけを target ごとに 1 行出す (注意の行は出さない) ---
write_source '# 運用ルール' '' '## 新しい節' '' '- 追加' '' '## 言語' '' '- 日本語を既定にする' '' '## public safety' '' '- secret を入れない'
changed='"新しい節" (added), "言語", "消える節" (removed)'
cp "$codex_file" "$tmp/codex-before"
cp "$claude_file" "$tmp/claude-before"
run_sync
[ "$rc" = 0 ] || fail "dry-run should succeed: $(cat "$tmp/out")"
[ "$(count_line "note: [codex] instruction sections changed: $changed")" = 1 ] \
  || fail "dry-run should print the changed sections for codex once: $(cat "$tmp/out")"
[ "$(count_line "note: [claude-code] instruction sections changed: $changed")" = 1 ] \
  || fail "dry-run should print the changed sections for claude-code once: $(cat "$tmp/out")"
expect_notes 2 "dry-run"
[ "$(count_line "$running")" = 0 ] || fail "dry-run must not print the running-sessions note: $(cat "$tmp/out")"
cmp -s "$codex_file" "$tmp/codex-before" && cmp -s "$claude_file" "$tmp/claude-before" \
  || fail "dry-run must not change the owned files"
# 順: plan の行、節の行、ok の行。
last_plan=$(grep -n -E '^(create|update|skip|delete|conflict): ' "$tmp/out" | tail -n 1 | cut -d: -f1)
first_note=$(grep -n '^note: ' "$tmp/out" | head -n 1 | cut -d: -f1)
last_note=$(grep -n '^note: ' "$tmp/out" | tail -n 1 | cut -d: -f1)
ok_line=$(grep -n '^ok: dry-run only' "$tmp/out" | cut -d: -f1)
[ "$last_plan" -lt "$first_note" ] && [ "$last_note" -lt "$ok_line" ] \
  || fail "dry-run order should be plan, notes, ok: $(cat "$tmp/out")"

# --- case 2: --quiet の dry-run は note を出さない ---
run_sync --quiet
[ "$rc" = 0 ] || fail "quiet dry-run should succeed: $(cat "$tmp/out")"
expect_notes 0 "quiet dry-run"

# --- case 3: --apply は、節の行の後に注意の行を 1 回だけ出し、その後に ok を出す ---
run_sync --apply
[ "$rc" = 0 ] || fail "apply should succeed: $(cat "$tmp/out")"
[ "$(count_line "note: [codex] instruction sections changed: $changed")" = 1 ] \
  && [ "$(count_line "note: [claude-code] instruction sections changed: $changed")" = 1 ] \
  || fail "apply should print the changed sections for both targets: $(cat "$tmp/out")"
[ "$(count_line "$running")" = 1 ] || fail "apply should print the running-sessions note once: $(cat "$tmp/out")"
expect_notes 3 "apply"
last_plan=$(grep -n -E '^(create|update|skip|delete|conflict): ' "$tmp/out" | tail -n 1 | cut -d: -f1)
codex_note=$(line_no "note: [codex] instruction sections changed: $changed")
claude_note=$(line_no "note: [claude-code] instruction sections changed: $changed")
running_note=$(line_no "$running")
ok_line=$(grep -n '^ok: applied' "$tmp/out" | cut -d: -f1)
[ "$last_plan" -lt "$codex_note" ] && [ "$last_plan" -lt "$claude_note" ] \
  && [ "$codex_note" -lt "$running_note" ] && [ "$claude_note" -lt "$running_note" ] && [ "$running_note" -lt "$ok_line" ] \
  || fail "apply order should be plan, section notes, running-sessions note, ok: $(cat "$tmp/out")"
grep -q '日本語を既定にする' "$codex_file" && grep -q '日本語を既定にする' "$claude_file" \
  || fail "apply should update the owned files"

# --- case 4: 書き換えた後 (up-to-date) は note を出さない ---
run_sync --apply
[ "$rc" = 0 ] || fail "second apply should succeed: $(cat "$tmp/out")"
expect_notes 0 "up-to-date"

# --- case 5: 節に違いが無い update (build_id と節の前後の空行だけが違う) は note を出さない ---
write_source '# 運用ルール' '' '## 新しい節' '' '' '- 追加' '' '## 言語' '' '- 日本語を既定にする' '' '## public safety' '' '- secret を入れない' '' ''
run_sync
grep -q '^update: \[codex\]' "$tmp/out" && grep -q '^update: \[claude-code\]' "$tmp/out" \
  || fail "precondition: a source change should plan an update: $(cat "$tmp/out")"
expect_notes 0 "marker-only update (dry-run)"
run_sync --apply
[ "$rc" = 0 ] || fail "marker-only apply should succeed: $(cat "$tmp/out")"
expect_notes 0 "marker-only update (apply)"

# --- case 6: --quiet の apply は note を出さずに書き換える ---
write_source '# 運用ルール' '' '## 言語' '' '- quiet で配る'
run_sync --apply --quiet
[ "$rc" = 0 ] || fail "quiet apply should succeed: $(cat "$tmp/out")"
expect_notes 0 "quiet apply"
grep -q 'quiet で配る' "$codex_file" && grep -q 'quiet で配る' "$claude_file" || fail "quiet apply should update the owned files"

# --- case 7: conflict で止まるときは note を出さず、何も書き換えない ---
write_source '# 運用ルール' '' '## 言語' '' '- conflict の前の変更'
cp "$codex_file" "$tmp/codex-before"
mv "$claude_file" "$tmp/claude-real"
ln -s "$tmp/claude-real" "$claude_file"
run_sync
[ "$rc" = 1 ] && grep -q '^conflict: \[claude-code\]' "$tmp/out" && grep -q '^update: \[codex\]' "$tmp/out" \
  || fail "precondition: a symlink target should conflict while codex plans an update: $(cat "$tmp/out")"
expect_notes 0 "conflict (dry-run)"
run_sync --apply
[ "$rc" = 1 ] || fail "apply with a conflict should fail: $(cat "$tmp/out")"
expect_notes 0 "conflict (apply)"
cmp -s "$codex_file" "$tmp/codex-before" || fail "apply with a conflict must not change the owned files"
rm "$claude_file"
mv "$tmp/claude-real" "$claude_file"
run_sync --apply
[ "$rc" = 0 ] || fail "apply after removing the conflict should succeed: $(cat "$tmp/out")"
expect_notes 3 "after the conflict is removed"

# --- case 8: 10 個を超える節は数だけを出し、長い名前は 80 字で切る ---
long_name=$(ruby -e 'print "長" * 81')
cut_name=$(ruby -e 'print "長" * 80')
write_source '# 運用ルール' '' "## $long_name" '' '- a' \
  '## 節 2' '- b' '## 節 3' '- c' '## 節 4' '- d' '## 節 5' '- e' '## 節 6' '- f' \
  '## 節 7' '- g' '## 節 8' '- h' '## 節 9' '- i' '## 節 10' '- j' '## 節 11' '- k' '## 節 12' '- l'
run_sync
many="\"$cut_name\" (added), \"節 2\" (added), \"節 3\" (added), \"節 4\" (added), \"節 5\" (added), \"節 6\" (added), \"節 7\" (added), \"節 8\" (added), \"節 9\" (added), \"節 10\" (added), and 3 more"
[ "$(count_line "note: [codex] instruction sections changed: $many")" = 1 ] \
  || fail "more than 10 sections should be cut to 10 names and a count: $(cat "$tmp/out")"
if grep -q -F -- "$long_name" "$tmp/out"; then fail "a section name longer than 80 chars should be cut: $(cat "$tmp/out")"; fi
run_sync --apply --quiet

# --- case 9: fence の中の見出しと ### は区切りにせず、同じ名前の節は 1 つにまとめる ---
write_source '# 運用ルール' '' '## 手順' '' '```sh' '## fence の中' '```' '' '### 細目' '' '- 前' '' '## 手順' '' '- 後ろ'
run_sync --apply --quiet
write_source '# 運用ルール' '' '## 手順' '' '```sh' '## fence の中を変えた' '```' '' '### 細目を変えた' '' '- 前' '' '## 手順' '' '- 後ろ'
run_sync
[ "$(count_line 'note: [codex] instruction sections changed: "手順"')" = 1 ] \
  || fail "headings in a fence and ### should stay inside their section, and same-name sections should merge: $(cat "$tmp/out")"
run_sync --apply --quiet

# --- case 10: local の断片だけの変化は "local instructions" の 1 つの節として出し、中の見出しを出さない ---
mkdir -p "$(dirname "$fragment")"
printf '%s\n' '## 手元の秘密の見出し' '' '- 手元だけの決まり' > "$fragment"
run_sync --apply
[ "$rc" = 0 ] || fail "apply with a new fragment should succeed: $(cat "$tmp/out")"
[ "$(count_line 'note: [codex] instruction sections changed: "local instructions" (added)')" = 1 ] \
  && [ "$(count_line 'note: [claude-code] instruction sections changed: "local instructions" (added)')" = 1 ] \
  || fail "a new fragment should be reported as one added section: $(cat "$tmp/out")"
[ "$(count_line "$running")" = 1 ] || fail "a fragment change should print the running-sessions note: $(cat "$tmp/out")"
printf '%s\n' '## 手元の別の見出し' '' '- 手元だけの別の決まり' '' '# 断片の中の大見出し' > "$fragment"
run_sync --apply
[ "$(count_line 'note: [codex] instruction sections changed: "local instructions"')" = 1 ] \
  || fail "a changed fragment should be reported as one changed section: $(cat "$tmp/out")"
if grep -q -e '手元' -e '断片の中' "$tmp/out"; then fail "the fragment's headings and body must not be printed: $(cat "$tmp/out")"; fi
rm "$fragment"
run_sync --apply
[ "$(count_line 'note: [codex] instruction sections changed: "local instructions" (removed)')" = 1 ] \
  || fail "a removed fragment should be reported as one removed section: $(cat "$tmp/out")"

# --- case 11: 所有 file に非 UTF-8 の byte があっても、crash せずに節の行を出す ---
printf '## 壊れた節\n\n\377\376 bytes\n' >> "$codex_file"
run_sync
[ "$rc" = 0 ] || fail "non-UTF-8 bytes in the owned file should not crash sync: $(cat "$tmp/out")"
[ "$(count_line 'note: [codex] instruction sections changed: "壊れた節" (removed)')" = 1 ] \
  || fail "a section with non-UTF-8 bytes in the owned file should be reported as removed: $(cat "$tmp/out")"
[ "$(note_count)" = 1 ] || fail "only the changed target should get a note: $(cat "$tmp/out")"

# --- case 12: 書き込みが止まったら、注意の行を出さない (注意は書き込みが終わった後に出す) ---
# 一時 file の path に消せない directory を置くと、sync は書き込みの前に fail で止まる (sync-test の case 44 と同じ止め方)。
run_sync --apply --quiet
write_source '# 運用ルール' '' '## 手順' '' '- 書き込みが止まる変更'
cp "$codex_file" "$tmp/codex-before"
cp "$claude_file" "$tmp/claude-before"
mkdir "$tmp/codex/.agent-tools-staging-AGENTS.md"
run_sync --apply
[ "$rc" = 1 ] && grep -q '^fail: could not remove the leftover staging file' "$tmp/out" \
  || fail "precondition: an unremovable staging path should stop the apply: $(cat "$tmp/out")"
cmp -s "$codex_file" "$tmp/codex-before" && cmp -s "$claude_file" "$tmp/claude-before" \
  || fail "precondition: the stopped apply must leave the owned files unchanged"
[ "$(count_line 'note: [codex] instruction sections changed: "手順"')" = 1 ] \
  || fail "the section notes are printed before the write: $(cat "$tmp/out")"
[ "$(count_line "$running")" = 0 ] || fail "a stopped apply must not print the running-sessions note: $(cat "$tmp/out")"
rmdir "$tmp/codex/.agent-tools-staging-AGENTS.md"
run_sync --apply
[ "$rc" = 0 ] && [ "$(count_line "$running")" = 1 ] || fail "the retried apply should print the running-sessions note: $(cat "$tmp/out")"

# --- case 13: 書き換えない plan (未接続の空の所有 file) には note を出さない ---
mkdir -p "$tmp/codex13" "$tmp/claude13"
printf '   \n\n' > "$tmp/codex13/AGENTS.md"
rc=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex13" --claude-home "$tmp/claude13" --opencode-home "$tmp/opencode13" \
  > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && grep -q '^skip: \[codex\].*run connect first' "$tmp/out" \
  || fail "precondition: an empty owned file should skip with run connect first: $(cat "$tmp/out")"
expect_notes 0 "unconnected target"

echo "ok: sync-instruction-note-test"
