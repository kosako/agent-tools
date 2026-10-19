#!/bin/sh
# UTF-8 の locale が無い環境 (LC_ALL=C) で pipeline の入口が落ちないことの self-test (#418)。
# C locale では Ruby の Encoding.default_external が US-ASCII になり、日本語を含む source や
# marker への正規表現・scrub が例外で落ちていた。fake home でだけ検証し、実 tool homes には
# 触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
scripts="$script_dir/.."

tmpbase=$(mktemp -d)
trap 'rm -rf "$tmpbase"' EXIT
# root / home に空白を含めて、引数の引用の誤りでも落ちるようにする (setup-test と同じ)。
tmp="$tmpbase/with space"
mkdir -p "$tmp"

# fixture: 本文に日本語を含む skill と instruction。instruction は connect / sync で marker の
# parse (scrub) を通る。人が書いた CLAUDE.md にも日本語を置き、connect の import の plan で読ませる。
make_demo_repo "$tmp/repo" skills personal-demo-skill skill '# デモの skill' '日本語の本文。'
make_demo_repo "$tmp/repo" instructions personal-ops instruction '# 運用ルール' '日本語の instruction。'
mkdir -p "$tmp/codex" "$tmp/claude" "$tmp/opencode" "$tmp/agents"
printf '# 手書きの指示\n\n日本語の行。\n' > "$tmp/claude/CLAUDE.md"

# C locale で 1 つの入口を走らせ、exit 0 と、encoding の例外が出ていないことを確かめる。
# 使い方: run_c <label> <script> <arg>...
run_c() {
  rc_label=$1
  rc_script=$2
  shift 2
  rc_out=$(LC_ALL=C LANG=C LC_CTYPE=C "$scripts/$rc_script" "$@" 2>&1) || fail "$rc_label exited non-zero under LC_ALL=C: $rc_out"
  case $rc_out in
    *"invalid byte sequence"*|*"Encoding::"*) fail "$rc_label raised an encoding error under LC_ALL=C: $rc_out" ;;
  esac
}

# --- case 1: 前提の確認。C locale の Ruby は default_external が UTF-8 ではない ---
ext=$(LC_ALL=C LANG=C LC_CTYPE=C ruby -e 'print Encoding.default_external')
[ "$ext" != "UTF-8" ] || fail "precondition: LC_ALL=C did not change default_external (got $ext); this test would not exercise #418"

# --- case 2: 検査・生成・登録 ---
run_c check-manifests check-manifests.sh --quiet --root "$tmp/repo"
run_c build build.sh --quiet --root "$tmp/repo"
run_c register register.sh --quiet --root "$tmp/repo"

# --- case 3: 配備 (dry-run → apply)。instruction の marker の parse を通る ---
run_c connect-dry-run connect.sh --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude"
run_c connect-apply connect.sh --apply --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude"
run_c sync-dry-run sync.sh --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" \
  --opencode-home "$tmp/opencode"
run_c sync-apply sync.sh --apply --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" \
  --opencode-home "$tmp/opencode"
[ -f "$tmp/codex/skills/personal-demo-skill/SKILL.md" ] || fail "sync --apply under LC_ALL=C did not place the codex skill"

# --- case 4: 観測 (status --json は JSON を出す、doctor は通る) ---
status_json=$(LC_ALL=C LANG=C LC_CTYPE=C "$scripts/status.sh" --json --root "$tmp/repo" \
  --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" 2>&1) \
  || fail "status --json exited non-zero under LC_ALL=C: $status_json"
printf '%s' "$status_json" | ruby -rjson -e 'JSON.parse($stdin.read)' >/dev/null 2>&1 \
  || fail "status --json under LC_ALL=C did not print JSON: $status_json"
run_c doctor doctor.sh --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" \
  --opencode-home "$tmp/opencode" --agents-home "$tmp/agents"

# --- case 5: setup (dry-run) は全段を通す ---
run_c setup setup.sh --quiet --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" \
  --opencode-home "$tmp/opencode"

# --- case 6: cli.rb を require しない script も外部 encoding を UTF-8 に固定する (#432) ---
# 配布する script (shared/scripts) は単体の file で、scripts/*.sh の一部の entrypoint (probe・judge) も cli.rb を
# require しないので、#418 の固定が効かない。どれも最初の module より前 (= 何かを読む前) に固定の行を持つことを
# 確かめる (新しい script の書き忘れを落とす)。
pin='Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8'
# 使い方: assert_pinned <label> <file>
assert_pinned() {
  pin_line=$(grep -n -F -x -m 1 "$pin" "$2" | cut -d: -f1)
  module_line=$(grep -n -m 1 '^module ' "$2" | cut -d: -f1)
  [ -n "$pin_line" ] || fail "$1 does not pin Encoding.default_external to UTF-8 (#432)"
  [ -n "$module_line" ] || fail "$1 has no top-level module line to order the pin against"
  [ "$pin_line" -lt "$module_line" ] || fail "$1 pins Encoding.default_external after its first module line"
}
for src in "$repo_root"/shared/scripts/*.rb; do
  assert_pinned "$(basename "$src")" "$src"
done
entries=0
for sh_entry in "$scripts"/*.sh; do
  lib=$(sed -n 's|^exec ruby "$script_dir/lib/\([a-z_]*\.rb\)" "$@"$|\1|p' "$sh_entry")
  [ -n "$lib" ] || continue
  entries=$((entries + 1))
  grep -q -x 'require_relative "cli"' "$scripts/lib/$lib" && continue
  assert_pinned "$(basename "$sh_entry") (lib/$lib)" "$scripts/lib/$lib"
done
# exec の行の形が変わって拾える entrypoint が減ると、この検査は一部しか見なくなる (今は 12 本を拾う)。
[ "$entries" -ge 10 ] || fail "found only $entries ruby entrypoint(s) under scripts/; the exec line pattern no longer matches"

# 以降は配布する script を C locale で日本語を含む入力に当てる。git の hook や agent の hook は、LANG の無い
# 文脈 (GUI の git client・env -i など) からも起動される。
src_c() {
  sc_name=$1
  shift
  LC_ALL=C LANG=C LC_CTYPE=C ruby "$repo_root/shared/scripts/$sc_name.rb" "$@"
}
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
# repo の path にも日本語を入れる (git の出力に載る path を読む script がある)。
jp_repo="$tmp/日本語の repo"
git init -q "$jp_repo"

# --- case 7: git-identity-gate は日本語の名前の identity を読める ---
# 修正前は git var の出力への正規表現が ArgumentError になり、完全な identity でも exit 2 で commit を止めた。
identity_c() {
  (
    cd "$jp_repo" || exit 2
    GIT_AUTHOR_NAME=$1 GIT_AUTHOR_EMAIL=$2 GIT_COMMITTER_NAME=$1 GIT_COMMITTER_EMAIL=$2
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    src_c personal-git-identity-gate
  )
}
out=$(identity_c '山田 太郎' taro@example.com 2>&1) \
  || fail "git-identity-gate rejected a complete identity with a Japanese name under LC_ALL=C: $out"
set +e
out=$(identity_c '山田 太郎' '' 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "git-identity-gate should still block an empty email under LC_ALL=C (rc=$rc): $out"
case $out in
  *"author email is empty"*) ;;
  *) fail "git-identity-gate should name the empty key under LC_ALL=C: $out" ;;
esac

# --- case 8: personal-packet は日本語の path の repo で packet を読める ---
# 修正前は git worktree list の出力 (日本語の path) への正規表現が ArgumentError になり、exit 2 で止まった。
mkdir -p "$jp_repo/.agent-packets"
printf -- '---\nissue: 7\ntitle: "日本語の題"\nstate: open\nworker: claude\nupdated: 2026-10-19T00:00:00+09:00\n---\n\n## 依頼\n\n- 日本語の依頼\n\n## 結果\n\n## 次の入口\n\n- 次の一手\n' \
  > "$jp_repo/.agent-packets/7.md"
out=$(cd "$jp_repo" && src_c personal-packet list 2>&1) || fail "personal-packet list failed under LC_ALL=C: $out"
case $out in
  *"日本語の題"*) ;;
  *) fail "personal-packet list under LC_ALL=C should show the Japanese title: $out" ;;
esac
out=$(cd "$jp_repo" && src_c personal-packet check 7 2>&1) || fail "personal-packet check failed under LC_ALL=C: $out"
case $out in
  */.agent-packets/7.md) ;;
  *) fail "personal-packet check under LC_ALL=C should print the packet path: $out" ;;
esac

# --- case 9: agent の hook は日本語を含む stdin の JSON を読める ---
# safe-gh-hook は steer を返し、tool-call-record-hook は理由を記録する。どちらも fail-open なので、読めないと
# 無言で何も返さない・書かないことになる (exit code では分からない)。
hook_in='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh issue view 1 --comments # 日本語のメモ"}}'
out=$(printf '%s' "$hook_in" | src_c personal-safe-gh-hook 2>&1) \
  || fail "personal-safe-gh-hook exited non-zero under LC_ALL=C: $out"
case $out in
  *additionalContext*) ;;
  *) fail "personal-safe-gh-hook should steer a raw gh read with Japanese in the command under LC_ALL=C: $out" ;;
esac
record_dir="$tmp/record"
record_in='{"hook_event_name":"PermissionDenied","session_id":"s","tool_name":"Bash","reason":"日本語の理由"}'
out=$(printf '%s' "$record_in" | (
  unset CODEX_THREAD_ID CODEX_SANDBOX
  CLAUDECODE=1 AGENT_TOOLS_TOOL_CALL_RECORD_DIR=$record_dir
  export CLAUDECODE AGENT_TOOLS_TOOL_CALL_RECORD_DIR
  src_c personal-tool-call-record-hook
) 2>&1) || fail "personal-tool-call-record-hook exited non-zero under LC_ALL=C: $out"
grep -q '日本語の理由' "$record_dir/claude-code.jsonl" 2>/dev/null \
  || fail "personal-tool-call-record-hook should record the Japanese reason under LC_ALL=C: $out"

echo "ok: c-locale-test"
