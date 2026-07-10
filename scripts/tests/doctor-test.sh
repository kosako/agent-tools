#!/bin/sh
# doctor.sh の self-test。
# 一時 directory に fixture と fake homes を生成して検証する。
# 実際の ~/.codex / ~/.claude / ~/.agents には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
build="$script_dir/../build.sh"
sync="$script_dir/../sync.sh"
doctor="$script_dir/../doctor.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT


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

# --- case 1b: custom home (Dir.home 外) でも生の絶対 path を出力しない (#176 Low) ---
grep -q "ok: home: \[codex\] <codex home> present" "$tmp/d1" \
  || fail "custom codex home should be redacted to label: $(cat "$tmp/d1")"
grep -q "ok: home: \[claude-code\] <claude-code home> present" "$tmp/d1" \
  || fail "custom claude home should be redacted to label: $(cat "$tmp/d1")"
grep -F -q "$tmp" "$tmp/d1" \
  && fail "doctor output must not contain raw custom home paths: $(cat "$tmp/d1")" || true

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
grep -q "fail: forbidden: agent-tools marker found in forbidden target <claude-code home>/sessions" "$tmp/d3" \
  || fail "missing forbidden fail line (path should be redacted): $(cat "$tmp/d3")"
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
grep -q "ok: catalog: present, 1 asset(s), fresh" "$tmp/d5" || fail "missing catalog ok line: $(cat "$tmp/d5")"

# mtime だけが変わっても stale にならない
touch "$tmp/repo/shared/workflows/personal-demo.asset.yml" "$tmp/repo/shared/workflows/personal-demo.md"
run_doctor > "$tmp/d5a" 2>&1 || fail "touched files should not be stale"
grep -q "ok: catalog: present, 1 asset(s), fresh" "$tmp/d5a" || fail "mtime change must not cause stale: $(cat "$tmp/d5a")"

# source content の変更は stale になる
echo "changed" >> "$tmp/repo/shared/workflows/personal-demo.md"
run_doctor > "$tmp/d5b" 2>&1 || fail "stale catalog should still exit 0"
grep -q "warn: catalog: stale (personal-demo: content changed since register)" "$tmp/d5b" \
  || fail "missing catalog stale warn: $(cat "$tmp/d5b")"

# manifest (登録判断) の変更も stale になる (#148)
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null
echo "# reviewed comment" >> "$tmp/repo/shared/workflows/personal-demo.asset.yml"
run_doctor > "$tmp/d5c" 2>&1 || fail "manifest-stale catalog should still exit 0"
grep -q "warn: catalog: stale (personal-demo: manifest changed since register)" "$tmp/d5c" \
  || fail "missing manifest stale warn: $(cat "$tmp/d5c")"
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null

# --- case 6: catalog_version 不一致は warn (re-run register) ---
ruby -i -pe 'sub(/"catalog_version": \d+/, "\"catalog_version\": 1")' "$tmp/repo/generated/catalog.json"
run_doctor > "$tmp/d6" 2>&1 || fail "version mismatch should still exit 0: $(cat "$tmp/d6")"
grep -q "warn: catalog: version mismatch" "$tmp/d6" \
  || fail "missing catalog version mismatch warn: $(cat "$tmp/d6")"

# --- case 7/8: 壊れた manifest / source 欠落 + catalog present でも doctor は crash しない ---
# (check_catalog が sources_by_name と build_id_for を直接呼ぶ経路。status と対称の best-effort)
mkdir -p "$tmp/brepo/shared/workflows" "$tmp/bcodex" "$tmp/bclaude" "$tmp/bagents"
cat > "$tmp/brepo/shared/workflows/personal-demo.md" <<'EOF'
# demo
EOF
cat > "$tmp/brepo/shared/workflows/personal-demo.asset.yml" <<'EOF'
schema_version: 1
name: personal-demo
kind: workflow
visibility: public
targets:
  - codex
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/workflows/personal-demo.md
  format: markdown
EOF
"$build" --root "$tmp/brepo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/brepo" --quiet > /dev/null   # catalog を valid に作る
run_bdoctor() {
  "$doctor" --root "$tmp/brepo" --codex-home "$tmp/bcodex" \
    --claude-home "$tmp/bclaude" --agents-home "$tmp/bagents"
}

# case 7: source ファイル欠落 (build_id が Errno) でも crash せず stale を warn
rm -f "$tmp/brepo/shared/workflows/personal-demo.md"
status=0
run_bdoctor > "$tmp/d7" 2>&1 || status=$?
grep -q "catalog:" "$tmp/d7" || fail "doctor must not crash when source file is missing: $(cat "$tmp/d7")"
grep -q "warn: catalog: stale" "$tmp/d7" || fail "missing source should warn stale, not crash: $(cat "$tmp/d7")"

# case 8: malformed YAML manifest (sources_by_name が raise) でも crash せず未検証を warn
printf 'name: personal-demo\nkind: [unbalanced\n   : :\n' > "$tmp/brepo/shared/workflows/personal-demo.asset.yml"
status=0
run_bdoctor > "$tmp/d8" 2>&1 || status=$?
grep -q "warn: catalog: freshness 未検証" "$tmp/d8" \
  || fail "broken manifest should warn (not crash) in catalog check: $(cat "$tmp/d8")"

echo "ok: doctor self-test passed"
