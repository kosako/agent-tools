#!/bin/sh
# connect.sh の self-test。
# 一時 directory に fixture と fake tool homes を生成して検証する。
# 実際の ~/.codex / ~/.claude には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$script_dir/../build.sh"
connect="$script_dir/../connect.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_connect() {
  "$connect" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" "$@"
}

# --- fixture: instruction asset ---
mkdir -p "$tmp/repo/shared/instructions" "$tmp/codex" "$tmp/claude"
cat > "$tmp/repo/shared/instructions/personal-ops.md" <<'EOF'
# operating rules

ドキュメントは日本語を既定にする。
EOF
cat > "$tmp/repo/shared/instructions/personal-ops.asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-ops.md
  format: markdown
EOF

# --- case 0: build 前は connect する artifact が無い ---
run_connect > "$tmp/c0" 2>&1 || fail "connect without artifacts should succeed: $(cat "$tmp/c0")"
grep -q "no instruction artifacts to connect" "$tmp/c0" || fail "missing no-artifacts notice: $(cat "$tmp/c0")"

"$build" --root "$tmp/repo" --quiet > /dev/null

# --- case 1: dry-run は plan を出すが書き込まない ---
run_connect > "$tmp/c1" 2>&1 || fail "dry-run should succeed: $(cat "$tmp/c1")"
grep -q "create: \[claude-code\] owned" "$tmp/c1" || fail "missing claude owned create: $(cat "$tmp/c1")"
grep -q "add-import: \[claude-code\] import" "$tmp/c1" || fail "missing claude import plan: $(cat "$tmp/c1")"
grep -q "create: \[codex\] owned" "$tmp/c1" || fail "missing codex owned create: $(cat "$tmp/c1")"
grep -q "dry-run only" "$tmp/c1" || fail "missing dry-run notice"
[ ! -e "$tmp/claude/agent-tools/CLAUDE.md" ] || fail "dry-run must not write owned file"
[ ! -e "$tmp/claude/CLAUDE.md" ] || fail "dry-run must not write import file"
[ ! -e "$tmp/codex/AGENTS.md" ] || fail "dry-run must not write codex owned file"

# --- case 2: --apply で所有ファイルと import が作られる ---
run_connect --apply > "$tmp/c2" 2>&1 || fail "apply should succeed: $(cat "$tmp/c2")"
[ -f "$tmp/claude/agent-tools/CLAUDE.md" ] || fail "owned CLAUDE.md not created"
head -1 "$tmp/claude/agent-tools/CLAUDE.md" | grep -q "agent-tools:managed" || fail "owned file missing marker"
grep -q "ドキュメントは日本語" "$tmp/claude/agent-tools/CLAUDE.md" || fail "owned file missing body"
grep -q '^@agent-tools/CLAUDE.md$' "$tmp/claude/CLAUDE.md" || fail "import line not added"
[ -f "$tmp/codex/AGENTS.md" ] || fail "codex AGENTS.md not created (empty file should be claimable)"
head -1 "$tmp/codex/AGENTS.md" | grep -q "target=codex" || fail "codex owned missing marker"

# --- case 3: 冪等 (再 apply は skip、0 changes) ---
run_connect --apply > "$tmp/c3" 2>&1 || fail "second apply should succeed: $(cat "$tmp/c3")"
grep -q "skip: \[claude-code\] owned.*already connected" "$tmp/c3" || fail "owned should skip when connected: $(cat "$tmp/c3")"
grep -q "skip: \[claude-code\] import.*already present" "$tmp/c3" || fail "import should skip when present"
grep -q "skip: \[codex\] owned.*already connected" "$tmp/c3" || fail "codex owned should skip"
grep -q "0 change(s)" "$tmp/c3" || fail "idempotent run should have 0 changes"

# --- case 4: 人間が書いた CLAUDE.md の内容を保持して import を足す ---
mkdir -p "$tmp/codex2" "$tmp/claude2"
printf '# my notes\nhello\n' > "$tmp/claude2/CLAUDE.md"
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex2" --claude-home "$tmp/claude2" --apply > /dev/null 2>&1
grep -q "hello" "$tmp/claude2/CLAUDE.md" || fail "existing CLAUDE.md content must be preserved"
grep -q '^@agent-tools/CLAUDE.md$' "$tmp/claude2/CLAUDE.md" || fail "import appended to existing CLAUDE.md"

# --- case 5: codex AGENTS.md に unmanaged な中身があると conflict (書き込まない) ---
mkdir -p "$tmp/codex3" "$tmp/claude3"
echo "my codex notes" > "$tmp/codex3/AGENTS.md"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex3" --claude-home "$tmp/claude3" --apply > "$tmp/c5" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "unmanaged codex AGENTS.md should conflict (exit 1): $(cat "$tmp/c5")"
grep -q "conflict: \[codex\] owned.*unmanaged" "$tmp/c5" || fail "missing codex conflict: $(cat "$tmp/c5")"
grep -q "my codex notes" "$tmp/codex3/AGENTS.md" || fail "unmanaged codex file must not be overwritten"
grep -q "nothing was applied" "$tmp/c5" || fail "conflict should stop all writes"
[ ! -e "$tmp/claude3/agent-tools/CLAUDE.md" ] || fail "conflict must stop claude writes too"

# --- case 6: claude CLAUDE.md が symlink なら conflict (置き換えない) ---
mkdir -p "$tmp/codex4" "$tmp/claude4"
echo "real" > "$tmp/realclaude.md"
ln -s "$tmp/realclaude.md" "$tmp/claude4/CLAUDE.md"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex4" --claude-home "$tmp/claude4" --apply > "$tmp/c6" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlink CLAUDE.md should conflict: $(cat "$tmp/c6")"
grep -q "conflict: \[claude-code\] import.*symlink" "$tmp/c6" || fail "missing symlink conflict: $(cat "$tmp/c6")"
[ -L "$tmp/claude4/CLAUDE.md" ] || fail "symlink must not be replaced"

echo "ok: connect self-test passed"
