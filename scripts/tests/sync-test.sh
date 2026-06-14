#!/bin/sh
# sync.sh の self-test。
# 一時 directory に fixture と fake tool homes を生成して検証する。
# 実際の ~/.codex / ~/.claude には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$script_dir/../build.sh"
register="$script_dir/../register.sh"
sync="$script_dir/../sync.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_sync() {
  "$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" "$@"
}

# --- fixture repo を build ---
mkdir -p "$tmp/repo/shared/workflows" "$tmp/codex/skills" "$tmp/claude/skills"
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo v1
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

# --- case 0: catalog が無いと sync は何も配置しない (register を促す) ---
run_sync > "$tmp/out-nocat" 2>&1 || fail "sync without catalog should succeed: $(cat "$tmp/out-nocat")"
grep -q "no catalog; run scripts/register.sh first" "$tmp/out-nocat" || fail "missing no-catalog notice: $(cat "$tmp/out-nocat")"

# register して catalog を作る (以降の case は registered 前提)
"$register" --root "$tmp/repo" --quiet > /dev/null

# --- case 1: dry-run が default で、何も書き込まれない ---
run_sync > "$tmp/out-dry" 2>&1 || fail "dry-run should succeed: $(cat "$tmp/out-dry")"
grep -q "create: \[codex\]" "$tmp/out-dry" || fail "missing codex create plan"
grep -q "create: \[claude-code\]" "$tmp/out-dry" || fail "missing claude-code create plan"
grep -q "dry-run only" "$tmp/out-dry" || fail "missing dry-run notice"
[ ! -e "$tmp/claude/skills/personal-demo" ] || fail "dry-run must not write targets"

# --- case 2: --apply で create される ---
run_sync --apply > "$tmp/out-apply" 2>&1 || fail "apply should succeed: $(cat "$tmp/out-apply")"
[ -f "$tmp/claude/skills/personal-demo/SKILL.md" ] || fail "apply should create target"
[ -f "$tmp/codex/skills/personal-demo/SKILL.md" ] || fail "apply should create codex target"

# --- case 3: 変更なしなら skip (up-to-date) ---
run_sync > "$tmp/out-skip" 2>&1 || fail "skip run should succeed"
grep -q "skip: \[codex\].*up-to-date" "$tmp/out-skip" || fail "missing up-to-date skip"
grep -q "0 change(s)" "$tmp/out-skip" || fail "expected zero pending changes"

# --- case 4: source 変更で update になり、apply で反映される ---
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo v2
EOF
"$build" --root "$tmp/repo" --quiet > /dev/null
run_sync > "$tmp/out-update" 2>&1 || fail "update dry-run should succeed"
grep -q "update: \[claude-code\]" "$tmp/out-update" || fail "missing update plan"
run_sync --apply --quiet > /dev/null 2>&1
grep -q "demo v2" "$tmp/claude/skills/personal-demo/SKILL.md" || fail "update not applied"

# --- case 5: unmanaged な同名 target は conflict で停止し、--apply でも書き込まない ---
rm -rf "$tmp/claude/skills/personal-demo"
mkdir -p "$tmp/claude/skills/personal-demo"
echo "user-owned content" > "$tmp/claude/skills/personal-demo/SKILL.md"

status=0
run_sync --apply > "$tmp/out-conflict" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "conflict should exit 1, got $status: $(cat "$tmp/out-conflict")"
grep -q "conflict: \[claude-code\].*unmanaged" "$tmp/out-conflict" || fail "missing conflict line"
grep -q "nothing was applied" "$tmp/out-conflict" || fail "missing stop notice"
grep -q "user-owned content" "$tmp/claude/skills/personal-demo/SKILL.md" \
  || fail "conflict target must not be overwritten"
grep -q "demo v2" "$tmp/codex/skills/personal-demo/SKILL.md" \
  || fail "codex target should be untouched but intact"

# --- case 6: marker の壊れた generated artifact は conflict になる ---
rm -rf "$tmp/claude/skills/personal-demo"
rm -f "$tmp/repo/generated/claude-code/skills/personal-demo/.agent-tools-managed.yml"
status=0
run_sync > "$tmp/out-badmarker" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "missing marker should exit 1: $(cat "$tmp/out-badmarker")"
grep -q "missing a valid marker" "$tmp/out-badmarker" || fail "missing marker conflict line"

# --- case 7: symlink target は conflict として扱い、決して触らない ---
"$build" --root "$tmp/repo" --quiet > /dev/null
rm -rf "$tmp/codex/skills/personal-demo"
mkdir -p "$tmp/real-skill"
echo "real content" > "$tmp/real-skill/SKILL.md"
ln -s "$tmp/real-skill" "$tmp/codex/skills/personal-demo"

status=0
run_sync --apply > "$tmp/out-symlink" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlink target should exit 1: $(cat "$tmp/out-symlink")"
grep -q "conflict: \[codex\].*symlink" "$tmp/out-symlink" || fail "missing symlink conflict line"
[ -L "$tmp/codex/skills/personal-demo" ] || fail "symlink must not be replaced"
grep -q "real content" "$tmp/real-skill/SKILL.md" || fail "symlink destination must be untouched"

# --- case 8: skill -> instruction 転換後、catalog 列挙なので stale skill は配置されない ---
"$build" --root "$tmp/repo" --quiet > /dev/null
cat > "$tmp/repo/shared/workflows/personal-demo.asset.yml" <<'EOF'
schema_version: 1
name: personal-demo
kind: instruction
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
summary: demo instruction
EOF
# 古い generated skill artifact は残したまま、catalog だけ instruction で作り直す。
# catalog 列挙なので skill entry は出ず、instruction は未 build なので run build first。
"$register" --root "$tmp/repo" --quiet > /dev/null
run_sync > "$tmp/out-kindswitch" 2>&1 || fail "sync after kind switch should succeed: $(cat "$tmp/out-kindswitch")"
grep -q "skip: \[codex\].*run build first" "$tmp/out-kindswitch" \
  || fail "instruction without build should skip: $(cat "$tmp/out-kindswitch")"
! grep -q "create: \[codex\]" "$tmp/out-kindswitch" \
  || fail "stale skill artifact must not be synced after kind switch: $(cat "$tmp/out-kindswitch")"

# --- case 9: instruction は connect が所有を確立し、sync が update する ---
mkdir -p "$tmp/codex9" "$tmp/claude9"
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
# 未接続では instruction を配置せず connect を促す
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" > "$tmp/out-noconnect" 2>&1
grep -q "skip: \[codex\].*run connect first" "$tmp/out-noconnect" \
  || fail "instruction without connect should skip: $(cat "$tmp/out-noconnect")"
# connect で所有を確立
"$script_dir/../connect.sh" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --apply --quiet > /dev/null
[ -f "$tmp/codex9/AGENTS.md" ] || fail "connect should create owned AGENTS.md"
# source を変更して rebuild → sync が update
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo v3 instruction
EOF
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" > "$tmp/out-instr-update" 2>&1
grep -q "update: \[codex\]" "$tmp/out-instr-update" || fail "instruction should update after rebuild: $(cat "$tmp/out-instr-update")"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --apply --quiet > /dev/null
grep -q "demo v3 instruction" "$tmp/codex9/AGENTS.md" || fail "instruction update not applied to AGENTS.md"
head -1 "$tmp/codex9/AGENTS.md" | grep -q "agent-tools:managed" || fail "synced instruction must keep marker"

# --- case 10: catalog の build_id と generated が不一致なら run build first ---
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo v4 instruction
EOF
# build せず register だけ進める (catalog の build_id が generated より新しくなる)
"$register" --root "$tmp/repo" --quiet > /dev/null
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" > "$tmp/out-stalegen" 2>&1
grep -q "skip: \[codex\].*run build first" "$tmp/out-stalegen" \
  || fail "stale generated vs catalog should skip with run build first: $(cat "$tmp/out-stalegen")"

# --- case 11: instruction 所有先の親 dir が symlink なら conflict (素通りさせない) ---
mkdir -p "$tmp/codex11" "$tmp/claude11" "$tmp/realad"
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
ln -s "$tmp/realad" "$tmp/claude11/agent-tools"
status=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex11" --claude-home "$tmp/claude11" --apply > "$tmp/out-adsym" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked owned parent should conflict (exit 1): $(cat "$tmp/out-adsym")"
grep -q "conflict: \[claude-code\].*symlink" "$tmp/out-adsym" || fail "missing parent symlink conflict: $(cat "$tmp/out-adsym")"
[ ! -e "$tmp/realad/CLAUDE.md" ] || fail "must not write through a symlinked parent"

echo "ok: sync self-test passed"
