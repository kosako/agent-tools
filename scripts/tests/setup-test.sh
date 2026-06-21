#!/bin/sh
# setup.sh の self-test。
# fake home でだけ検証し、実 tool homes には決して触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
setup="$script_dir/../setup.sh"

tmpbase=$(mktemp -d)
trap 'rm -rf "$tmpbase"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# root / home に空白を含めて、引数 forwarding の quoting を検証する
# ("Application Support" のような空白入り path での破綻を捕まえる)。
tmp="$tmpbase/with space"
mkdir -p "$tmp"

# fixture: single-file skill asset (build → register → connect(noop) → sync を通せる)
mkdir -p "$tmp/shared/skills" "$tmp/codex" "$tmp/claude"
cat > "$tmp/shared/skills/personal-demo-skill.md" <<'EOF'
# demo skill

body for the demo skill.
EOF
cat > "$tmp/shared/skills/personal-demo-skill.asset.yml" <<'EOF'
schema_version: 1
name: personal-demo-skill
kind: skill
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-demo-skill.md
  format: markdown
summary: demo skill for setup-test
EOF

# 引数は quote して渡す (root/home に空白を含むため)。setup.sh 側の forwarding の
# quoting が壊れていれば、空白入り path の sub-script 呼び出しで失敗する。
# --- case 1: dry-run は全段を通すが実 home には書き込まない ---
out=$("$setup" --root "$tmp" --codex-home "$tmp/codex" --claude-home "$tmp/claude" 2>&1) \
  || fail "dry-run exited non-zero: $out"
echo "$out" | grep -q "==> build" || fail "dry-run: build step missing"
echo "$out" | grep -q "==> register" || fail "dry-run: register step missing"
echo "$out" | grep -q "==> connect" || fail "dry-run: connect step missing"
echo "$out" | grep -q "==> sync" || fail "dry-run: sync step missing"
[ -d "$tmp/codex/skills/personal-demo-skill" ] && fail "dry-run wrote to codex home"
[ -d "$tmp/claude/skills/personal-demo-skill" ] && fail "dry-run wrote to claude home"
echo "$out" | grep -q "dry-run のみ" || fail "dry-run: hint missing"

# --- case 2: --apply は skill を実 home (fake) に配置する ---
out=$("$setup" --apply --root "$tmp" --codex-home "$tmp/codex" --claude-home "$tmp/claude" 2>&1) \
  || fail "apply exited non-zero: $out"
[ -f "$tmp/codex/skills/personal-demo-skill/SKILL.md" ] || fail "apply did not place codex skill"
[ -f "$tmp/claude/skills/personal-demo-skill/SKILL.md" ] || fail "apply did not place claude skill"
# --apply では dry-run hint を出さない (setup.sh:76 の gate 反転を検出する negative coverage)
echo "$out" | grep -q "dry-run のみ" && fail "--apply must not print the dry-run hint: $out" || true

# --- case 3: 未知オプションは usage を出して exit 2 ---
rc=0
"$setup" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown option should exit 2, got $rc"

echo "ok: setup-test passed"
