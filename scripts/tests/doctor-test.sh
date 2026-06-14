#!/bin/sh
# doctor.sh の self-test。
# 一時 directory に fixture と fake homes を生成して検証する。
# 実際の ~/.codex / ~/.claude / ~/.agents には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$script_dir/../build.sh"
sync="$script_dir/../sync.sh"
doctor="$script_dir/../doctor.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_doctor() {
  "$doctor" --root "$tmp/repo" --codex-home "$tmp/codex" \
    --claude-home "$tmp/claude" --agents-home "$tmp/agents"
}

# --- fixture repo ---
mkdir -p "$tmp/repo/shared/workflows" "$tmp/codex/skills" "$tmp/claude/skills" "$tmp/agents"
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo
EOF
cat > "$tmp/repo/shared/workflows/personal-demo.asset.yml" <<'EOF'
schema_version: 1
name: personal-demo
kind: workflow
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/workflows/personal-demo.md
  format: markdown
summary: demo workflow
EOF
"$build" --root "$tmp/repo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --apply --quiet > /dev/null

# --- case 1: 健全な環境では exit 0 で各 check が ok ---
run_doctor > "$tmp/d1" 2>&1 || fail "doctor should pass: $(cat "$tmp/d1")"
for expected in \
  "ok: ruby:" \
  "ok: check: manifest_validation=pass" \
  "ok: check: prompt_injection_static=pass" \
  "ok: target: \[codex\] personal-demo managed" \
  "ok: home: \[codex\]" \
  "ok: forbidden: no agent-tools markers" \
  "ok: catalog: present" \
  "doctor: ok"
do
  grep -q "$expected" "$tmp/d1" || fail "missing '$expected' in: $(cat "$tmp/d1")"
done

# --- case 2: doctor は read-only ---
before=$(find "$tmp" -type f -exec cksum {} + | sort)
run_doctor > /dev/null 2>&1
after=$(find "$tmp" -type f -exec cksum {} + | sort)
[ "$before" = "$after" ] || fail "doctor must not modify anything"

# --- case 3: 禁止 target に marker が紛れ込むと fail ---
mkdir -p "$tmp/claude/sessions"
cp "$tmp/claude/skills/personal-demo/.agent-tools-managed.yml" "$tmp/claude/sessions/"
status=0
run_doctor > "$tmp/d3" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "marker in forbidden target should exit 1: $(cat "$tmp/d3")"
grep -q "fail: forbidden: agent-tools marker found" "$tmp/d3" || fail "missing forbidden fail line"
rm -rf "$tmp/claude/sessions"

# --- case 4: unmanaged 同名 target は fail として現れる ---
rm -rf "$tmp/codex/skills/personal-demo/.agent-tools-managed.yml"
status=0
run_doctor > "$tmp/d4" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "conflict target should exit 1"
grep -q "fail: target: \[codex\] personal-demo conflict" "$tmp/d4" || fail "missing conflict line"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" > /dev/null 2>&1 \
  && fail "sync should also report the conflict" || true

# --- case 5: catalog があれば build_id で鮮度を check する ---
rm -rf "$tmp/codex/skills/personal-demo"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --apply --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null
run_doctor > "$tmp/d5" 2>&1 || fail "doctor with catalog should pass: $(cat "$tmp/d5")"
grep -q "ok: catalog: present, 2 asset(s), fresh" "$tmp/d5" || fail "missing catalog ok line: $(cat "$tmp/d5")"

# mtime だけが変わっても stale にならない
touch "$tmp/repo/shared/workflows/personal-demo.asset.yml" "$tmp/repo/shared/workflows/personal-demo.md"
run_doctor > "$tmp/d5a" 2>&1 || fail "touched files should not be stale"
grep -q "ok: catalog: present, 2 asset(s), fresh" "$tmp/d5a" || fail "mtime change must not cause stale: $(cat "$tmp/d5a")"

# source content の変更は stale になる
echo "changed" >> "$tmp/repo/shared/workflows/personal-demo.md"
run_doctor > "$tmp/d5b" 2>&1 || fail "stale catalog should still exit 0"
grep -q "warn: catalog: stale (personal-demo: content changed since register)" "$tmp/d5b" \
  || fail "missing catalog stale warn: $(cat "$tmp/d5b")"

# --- case 6: catalog_version 不一致は warn (re-run register) ---
ruby -i -pe 'sub(/"catalog_version": 2/, "\"catalog_version\": 1")' "$tmp/repo/generated/catalog.json"
run_doctor > "$tmp/d6" 2>&1 || fail "version mismatch should still exit 0: $(cat "$tmp/d6")"
grep -q "warn: catalog: version mismatch" "$tmp/d6" \
  || fail "missing catalog version mismatch warn: $(cat "$tmp/d6")"

echo "ok: doctor self-test passed"
