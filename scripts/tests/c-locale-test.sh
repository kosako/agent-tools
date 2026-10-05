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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fixture: 本文に日本語を含む skill と instruction。instruction は connect / sync で marker の
# parse (scrub) を通る。人が書いた CLAUDE.md にも日本語を置き、connect の import の plan で読ませる。
make_demo_repo "$tmp/repo" skills personal-demo-skill skill '# デモの skill' '日本語の本文。'
make_demo_repo "$tmp/repo" instructions personal-ops instruction '# 運用ルール' '日本語の instruction。'
mkdir -p "$tmp/codex" "$tmp/claude" "$tmp/opencode"
printf '# 手書きの指示\n\n日本語の行。\n' > "$tmp/claude/CLAUDE.md"
homes="--codex-home $tmp/codex --claude-home $tmp/claude"

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
# shellcheck disable=SC2086 # homes は空白を含まない一時 path を単語分割して渡す
run_c connect-dry-run connect.sh --root "$tmp/repo" $homes
# shellcheck disable=SC2086
run_c connect-apply connect.sh --apply --root "$tmp/repo" $homes
# shellcheck disable=SC2086
run_c sync-dry-run sync.sh --root "$tmp/repo" $homes --opencode-home "$tmp/opencode"
# shellcheck disable=SC2086
run_c sync-apply sync.sh --apply --root "$tmp/repo" $homes --opencode-home "$tmp/opencode"
[ -f "$tmp/codex/skills/personal-demo-skill/SKILL.md" ] || fail "sync --apply under LC_ALL=C did not place the codex skill"

# --- case 4: 観測 (status --json は JSON を出す、doctor は通る) ---
# shellcheck disable=SC2086
status_json=$(LC_ALL=C LANG=C LC_CTYPE=C "$scripts/status.sh" --json --root "$tmp/repo" $homes --opencode-home "$tmp/opencode" 2>&1) \
  || fail "status --json exited non-zero under LC_ALL=C: $status_json"
printf '%s' "$status_json" | ruby -rjson -e 'JSON.parse($stdin.read)' >/dev/null 2>&1 \
  || fail "status --json under LC_ALL=C did not print JSON: $status_json"
# shellcheck disable=SC2086
run_c doctor doctor.sh --root "$tmp/repo" $homes --opencode-home "$tmp/opencode"

# --- case 5: setup (dry-run) は全段を通す ---
# shellcheck disable=SC2086
run_c setup setup.sh --quiet --root "$tmp/repo" $homes --opencode-home "$tmp/opencode"

echo "ok: c-locale-test"
