#!/bin/sh
# local の断片 (<XDG_CONFIG_HOME>/agent-tools/instructions.local.md) を、sync が instruction の所有ファイルに足すことの
# self-test (#689)。fake な tool home と一時 dir の XDG_CONFIG_HOME / HOME でだけ検証し、実物の tool home と
# ~/.config/agent-tools には触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
build="$script_dir/../build.sh"
register="$script_dir/../register.sh"
connect="$script_dir/../connect.sh"
sync="$script_dir/../sync.sh"
status_sh="$script_dir/../status.sh"
doctor="$script_dir/../doctor.sh"
lib="$script_dir/../lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
XDG_CONFIG_HOME="$tmp/xdg"
export XDG_CONFIG_HOME
frag="$XDG_CONFIG_HOME/agent-tools/instructions.local.md"
mkdir -p "$XDG_CONFIG_HOME/agent-tools" "$tmp/codex" "$tmp/claude" "$tmp/opencode" "$tmp/agents"

make_demo_repo "$tmp/repo" instructions personal-ops instruction '# operating rules' '' '共通の規則。'
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
gen_codex="$tmp/repo/generated/codex/instructions/AGENTS.md"
gen_claude="$tmp/repo/generated/claude-code/instructions/CLAUDE.md"
owned_codex="$tmp/codex/AGENTS.md"
owned_claude="$tmp/claude/agent-tools/CLAUDE.md"

run_sync() {
  "$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" "$@"
}
run_doctor() {
  "$doctor" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" \
    --agents-home "$tmp/agents"
}
run_status() {
  "$status_sh" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" \
    --json
}

# 所有ファイルが generated と同じ bytes か。
expect_generated() {
  cmp -s "$gen_codex" "$owned_codex" || fail "$1: codex owned file should equal generated"
  cmp -s "$gen_claude" "$owned_claude" || fail "$1: claude owned file should equal generated"
}

# 所有ファイルが「generated + 空行 + 見出し 1 行 + 空行 + 断片の本文 (末尾の改行を補う)」か。
expect_fragment_added() {
  for ef_pair in "$gen_codex:$owned_codex" "$gen_claude:$owned_claude"; do
    ruby -r"$lib/local_instructions" -e '
      gen, owned, frag = ARGV.map { |p| File.binread(p) }
      body = frag.end_with?("\n") ? frag : frag + "\n"
      expected = gen + "\n" + LocalInstructions::HEADING.b + "\n\n" + body
      abort "owned file is not generated + the fragment section" unless owned == expected
    ' "${ef_pair%%:*}" "${ef_pair#*:}" "$frag" || fail "$1: ${ef_pair#*:} should be generated + the fragment section"
  done
}

# sync の plan の行 (dry-run の出力) に、両方の tool の instruction の <action> がある。
expect_plan() {
  grep -q "^$2: \[codex\] .*AGENTS.md" "$1" || fail "codex instruction should be $2: $(cat "$1")"
  grep -q "^$2: \[claude-code\] .*CLAUDE.md" "$1" || fail "claude instruction should be $2: $(cat "$1")"
}

# status の deployment の state (両方の tool の instruction)。
expect_status_state() {
  run_status > "$tmp/status.json" 2>&1 || fail "status should succeed: $(cat "$tmp/status.json")"
  for es_tool in codex claude-code; do
    es_state=$(ruby -rjson -e '
      t = JSON.parse(File.read(ARGV[0]))["sync_targets"].find { |x| x["tool"] == ARGV[1] && x["name"] == "personal-ops" }
      puts t ? t["state"] : "none"
    ' "$tmp/status.json" "$es_tool")
    [ "$es_state" = "$1" ] || fail "status state for [$es_tool] should be $1, got $es_state"
  done
}

# --- case 1: 断片が無いとき、配る instruction は generated と同じ (今と同じ) ---
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --apply --quiet > /dev/null
run_sync > "$tmp/out1" 2>&1 || fail "sync without a fragment should succeed: $(cat "$tmp/out1")"
expect_plan "$tmp/out1" "skip"
grep -q "up-to-date" "$tmp/out1" || fail "without a fragment the owned files should be up-to-date: $(cat "$tmp/out1")"
expect_generated "absent"
run_doctor > "$tmp/doc1" 2>&1 || true
grep -q "^info: local-instructions: absent$" "$tmp/doc1" || fail "doctor should report absent: $(cat "$tmp/doc1")"

# --- case 2: 断片が在ると、dry-run は update を出し、apply で両方の所有ファイルに足す ---
canary1="local-fragment-canary-$$-one"
printf '# 手元の規則\n\n- %s\n' "$canary1" > "$frag"
run_sync > "$tmp/out2" 2>&1 || fail "sync dry-run with a fragment should succeed: $(cat "$tmp/out2")"
expect_plan "$tmp/out2" "update"
expect_generated "dry-run must not write"
expect_status_state "stale"
run_sync --apply > "$tmp/out2b" 2>&1 || fail "sync apply with a fragment should succeed: $(cat "$tmp/out2b")"
expect_fragment_added "present"
run_sync > "$tmp/out2c" 2>&1 || fail "sync after apply should succeed: $(cat "$tmp/out2c")"
expect_plan "$tmp/out2c" "skip"
expect_status_state "managed"
# generated と catalog (repo の中) には断片の中身が入らない。
if grep -r -q -F "$canary1" "$tmp/repo"; then
  fail "the fragment must not appear in the repo (generated / catalog)"
fi
run_doctor > "$tmp/doc2" 2>&1 || true
grep -q "^ok: local-instructions: present$" "$tmp/doc2" || fail "doctor should report present: $(cat "$tmp/doc2")"
if grep -q -F "$canary1" "$tmp/doc2" "$tmp/status.json" "$tmp/out2" "$tmp/out2b"; then
  fail "doctor / status / sync must not print the fragment"
fi

# --- case 3: 断片だけを変えると update になる (末尾に改行の無い断片は補う) ---
canary2="local-fragment-canary-$$-two"
printf '%s' "- $canary2" > "$frag"
run_sync > "$tmp/out3" 2>&1 || fail "sync dry-run after changing the fragment should succeed: $(cat "$tmp/out3")"
expect_plan "$tmp/out3" "update"
run_sync --apply > /dev/null 2>&1 || fail "sync apply after changing the fragment should succeed"
expect_fragment_added "changed"
if grep -q -F "$canary1" "$owned_codex" "$owned_claude"; then
  fail "the old fragment should be gone after the update"
fi

# --- case 4: 空白だけの断片は何も足さない (generated に戻る) ---
printf ' \n\n\t\n' > "$frag"
run_sync > "$tmp/out4" 2>&1 || fail "sync dry-run with an empty fragment should succeed: $(cat "$tmp/out4")"
expect_plan "$tmp/out4" "update"
run_sync --apply > /dev/null 2>&1 || fail "sync apply with an empty fragment should succeed"
expect_generated "empty"
run_doctor > "$tmp/doc4" 2>&1 || true
grep -q "^info: local-instructions: present but empty" "$tmp/doc4" \
  || fail "doctor should report an empty fragment: $(cat "$tmp/doc4")"

# --- case 5: 断片を消すと generated に戻る ---
printf '%s\n' "$canary1" > "$frag"
run_sync --apply > /dev/null 2>&1 || fail "sync apply before removing the fragment should succeed"
expect_fragment_added "before removal"
rm "$frag"
run_sync > "$tmp/out5" 2>&1 || fail "sync dry-run after removing the fragment should succeed: $(cat "$tmp/out5")"
expect_plan "$tmp/out5" "update"
run_sync --apply > /dev/null 2>&1 || fail "sync apply after removing the fragment should succeed"
expect_generated "removed"

# --- case 6: 不正な断片は conflict で、所有ファイルを変えない (断片を外した内容も置かない) ---
# 先に正しい断片を配っておき、不正にしたときに generated へ戻されないことも確かめる。
printf '%s\n' "$canary1" > "$frag"
run_sync --apply > /dev/null 2>&1 || fail "sync apply before the invalid cases should succeed"
snapshot_before=$(tree_snapshot "$tmp/codex"; tree_snapshot "$tmp/claude")
# 引数は、断片を不正にした方法の名前 (失敗の表示用)。doctor の exit は、fixture の repo が git の repo でない
# ことでも 0 にならないので、行だけを見る。
expect_invalid() {
  status=0
  run_sync --apply > "$tmp/out6" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "$1: sync should stop with exit 1, got $status: $(cat "$tmp/out6")"
  expect_plan "$tmp/out6" "conflict"
  grep -q "local instructions file is invalid" "$tmp/out6" || fail "$1: conflict should name the fragment: $(cat "$tmp/out6")"
  [ "$(tree_snapshot "$tmp/codex"; tree_snapshot "$tmp/claude")" = "$snapshot_before" ] \
    || fail "$1: owned files must not change"
  run_doctor > "$tmp/doc6" 2>&1 || true
  grep -q "^fail: local-instructions: invalid: " "$tmp/doc6" || fail "$1: doctor should report invalid: $(cat "$tmp/doc6")"
}
printf '%s\n' "$canary2" > "$tmp/elsewhere.md"
rm "$frag"
ln -s "$tmp/elsewhere.md" "$frag"
expect_invalid "symlink"
if grep -q -F "$canary2" "$tmp/out6" "$tmp/doc6"; then
  fail "the symlink target must not be printed"
fi
rm "$frag"
printf 'bad \377\376 bytes\n' > "$frag"
expect_invalid "non-UTF-8"
rm "$frag"
ruby -e 'File.binwrite(ARGV[0], "a" * 8193)' "$frag"
expect_invalid "too large"
rm "$frag"
mkdir "$frag"
expect_invalid "directory"
rmdir "$frag"
# FIFO は書き手が居なければ空として読めてしまうので、開いた fd の種類で弾く。
mkfifo "$frag"
expect_invalid "fifo"
rm "$frag"

# 8 KiB ちょうどは受け付ける (上限は 8 KiB を超えたとき)。
ruby -e 'File.binwrite(ARGV[0], "b" * 8191 + "\n")' "$frag"
run_sync --apply > "$tmp/out6b" 2>&1 || fail "a fragment of exactly 8 KiB should be accepted: $(cat "$tmp/out6b")"
expect_fragment_added "8 KiB"

# --- case 7: connect は今のまま generated を置き、断片を足すのは sync だけ ---
mkdir -p "$tmp/codex7" "$tmp/claude7"
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex7" --claude-home "$tmp/claude7" --apply --quiet > /dev/null
cmp -s "$gen_codex" "$tmp/codex7/AGENTS.md" || fail "connect should place the generated codex instruction only"
cmp -s "$gen_claude" "$tmp/claude7/agent-tools/CLAUDE.md" || fail "connect should place the generated claude instruction only"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex7" --claude-home "$tmp/claude7" --opencode-home "$tmp/opencode" \
  > "$tmp/out7" 2>&1 || fail "sync after connect should succeed: $(cat "$tmp/out7")"
grep -q "^update: \[codex\] .*AGENTS.md" "$tmp/out7" || fail "sync after connect should add the fragment: $(cat "$tmp/out7")"

# --- case 8: 場所の決め方。XDG_CONFIG_HOME は絶対 path のときだけ使い、無ければ HOME/.config ---
mkdir -p "$tmp/home/.config/agent-tools"
canary3="local-fragment-canary-$$-home"
printf '%s\n' "$canary3" > "$tmp/home/.config/agent-tools/instructions.local.md"
env -u XDG_CONFIG_HOME HOME="$tmp/home" "$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" \
  --opencode-home "$tmp/opencode" --apply > "$tmp/out8" 2>&1 || fail "sync with the HOME default should succeed: $(cat "$tmp/out8")"
grep -q -F "$canary3" "$owned_codex" || fail "without XDG_CONFIG_HOME the fragment should come from HOME/.config"
env XDG_CONFIG_HOME=relative/xdg HOME="$tmp/home" "$sync" --root "$tmp/repo" --codex-home "$tmp/codex" \
  --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" > "$tmp/out8b" 2>&1 \
  || fail "sync with a relative XDG_CONFIG_HOME should succeed: $(cat "$tmp/out8b")"
expect_plan "$tmp/out8b" "skip"
ruby -r"$lib/local_instructions" -e '
  abort "relative HOME should not locate the file" unless LocalInstructions.path({ "HOME" => "rel" }).nil?
  r = LocalInstructions.read({ "HOME" => "rel" })
  abort "relative HOME should be invalid, got #{r.state}" unless r.state == :invalid
  p = LocalInstructions.path({ "XDG_CONFIG_HOME" => "", "HOME" => "/h" })
  abort "empty XDG_CONFIG_HOME should fall back to HOME, got #{p}" unless p == "/h/.config/agent-tools/instructions.local.md"
' || fail "path resolution"

echo "ok: local-instructions self-test passed"
