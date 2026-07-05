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
"$register" --root "$tmp/repo" --quiet > /dev/null   # skill も catalog build_id を照合するため register まで通す
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

# --- case 12: 空の instruction 所有先は conflict でなく run connect first ---
mkdir -p "$tmp/codex12" "$tmp/claude12"
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
printf '   \n\n  \n' > "$tmp/codex12/AGENTS.md"   # 空白のみ (whitespace-only) が既に存在する状態
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex12" --claude-home "$tmp/claude12" > "$tmp/out-empty" 2>&1
grep -q "skip: \[codex\].*run connect first" "$tmp/out-empty" \
  || fail "empty instruction owned file should say run connect first: $(cat "$tmp/out-empty")"
! grep -q "conflict: \[codex\]" "$tmp/out-empty" \
  || fail "empty owned file must not be reported as a conflict: $(cat "$tmp/out-empty")"

# --- case 13: skill も catalog build_id を照合する (stale generated は run build first) ---
# (D2: plan_instruction と対称。register 後に build せず sync しても stale skill を配置しない)
mkdir -p "$tmp/srepo/shared/skills/personal-sk" "$tmp/scodex" "$tmp/sclaude"
cat > "$tmp/srepo/shared/skills/personal-sk/SKILL.md" <<'EOF'
---
name: personal-sk
description: demo skill
---
v1
EOF
cat > "$tmp/srepo/shared/skills/personal-sk/asset.yml" <<'EOF'
schema_version: 1
name: personal-sk
kind: skill
visibility: public
targets:
  - codex
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-sk
  format: directory
EOF
"$build" --root "$tmp/srepo" --quiet > /dev/null
"$register" --root "$tmp/srepo" --quiet > /dev/null   # catalog build_id = generated build_id
# source を変更して build せず register だけ (catalog build_id が generated より新しくなる)
echo "v2" >> "$tmp/srepo/shared/skills/personal-sk/SKILL.md"
"$register" --root "$tmp/srepo" --quiet > /dev/null
"$sync" --root "$tmp/srepo" --codex-home "$tmp/scodex" --claude-home "$tmp/sclaude" > "$tmp/out-skstale" 2>&1
grep -q "skip: \[codex\].*run build first" "$tmp/out-skstale" \
  || fail "stale skill generated vs catalog should skip with run build first: $(cat "$tmp/out-skstale")"
# --apply しても stale skill は配置されない
"$sync" --root "$tmp/srepo" --codex-home "$tmp/scodex" --claude-home "$tmp/sclaude" --apply --quiet > /dev/null 2>&1 || true
[ ! -e "$tmp/scodex/skills/personal-sk" ] || fail "stale skill must not be deployed before rebuild"
# rebuild すれば配置される (gate が正常系を塞がない)
"$build" --root "$tmp/srepo" --quiet > /dev/null
"$sync" --root "$tmp/srepo" --codex-home "$tmp/scodex" --claude-home "$tmp/sclaude" --apply --quiet > /dev/null
[ -f "$tmp/scodex/skills/personal-sk/SKILL.md" ] || fail "rebuilt skill should deploy"

# --- case 14: skill 所有先の親 dir (<home>/skills) が symlink なら conflict (素通りさせない) ---
# (D3: plan_instruction の親 dir 防御と対称。rm_rf / cp_r が symlink を辿らない)
mkdir -p "$tmp/repo14/shared/skills/personal-sk" "$tmp/claude14" "$tmp/realskills"
cat > "$tmp/repo14/shared/skills/personal-sk/SKILL.md" <<'EOF'
---
name: personal-sk
description: demo skill
---
body
EOF
cat > "$tmp/repo14/shared/skills/personal-sk/asset.yml" <<'EOF'
schema_version: 1
name: personal-sk
kind: skill
visibility: public
targets:
  - codex
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-sk
  format: directory
EOF
"$build" --root "$tmp/repo14" --quiet > /dev/null
"$register" --root "$tmp/repo14" --quiet > /dev/null
mkdir -p "$tmp/codex14"
ln -s "$tmp/realskills" "$tmp/codex14/skills"   # <home>/skills 自体を symlink にする
status=0
"$sync" --root "$tmp/repo14" --codex-home "$tmp/codex14" --claude-home "$tmp/claude14" --apply > "$tmp/out-skparent" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked skills parent should conflict (exit 1): $(cat "$tmp/out-skparent")"
grep -q "conflict: \[codex\].*symlink" "$tmp/out-skparent" || fail "missing skills-parent symlink conflict: $(cat "$tmp/out-skparent")"
[ ! -e "$tmp/realskills/personal-sk" ] || fail "must not write through a symlinked skills parent"

# --- case 15: script artifact を <home>/agent-tools/scripts/ に配置する ---
mkdir -p "$tmp/srepo15/shared/scripts" "$tmp/scodex15" "$tmp/sclaude15"
printf '#!/bin/sh\necho v1\n' > "$tmp/srepo15/shared/scripts/personal-wrap.sh"
# script kind は human review 必須 (#147) + 承認は内容に紐づく (#148)。
# source を書き換える case (v2/v3) の前に呼び直し、現内容で approved を焼き直す。
write_wrap_manifest() {
  wrapbid=$(ruby -r"$script_dir/../lib/build" \
    -e 'puts Build.build_id_for(ARGV[0], "shared/scripts/personal-wrap.sh", "text")' "$tmp/srepo15")
  cat > "$tmp/srepo15/shared/scripts/personal-wrap.asset.yml" <<EOF
schema_version: 1
name: personal-wrap
kind: script
visibility: personal
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
review:
  human_review: approved
  approved_build_id: $wrapbid
source:
  path: shared/scripts/personal-wrap.sh
  format: text
EOF
}
write_wrap_manifest
run15() { "$sync" --root "$tmp/srepo15" --codex-home "$tmp/scodex15" --claude-home "$tmp/sclaude15" "$@"; }
"$build" --root "$tmp/srepo15" --quiet > /dev/null
"$register" --root "$tmp/srepo15" --quiet > /dev/null

# dry-run は書き込まない
run15 > "$tmp/out15-dry" 2>&1 || fail "script dry-run should succeed: $(cat "$tmp/out15-dry")"
grep -q "create: \[claude-code\]" "$tmp/out15-dry" || fail "missing script create plan: $(cat "$tmp/out15-dry")"
[ ! -e "$tmp/sclaude15/agent-tools/scripts/personal-wrap" ] || fail "dry-run must not write script"

# --apply で本体 + sidecar marker が配置され、実行可能になる
run15 --apply > "$tmp/out15-apply" 2>&1 || fail "script apply should succeed: $(cat "$tmp/out15-apply")"
deployed="$tmp/sclaude15/agent-tools/scripts/personal-wrap"
[ -f "$deployed" ] || fail "script not deployed"
[ -x "$deployed" ] || fail "deployed script must be executable"
grep -q "echo v1" "$deployed" || fail "deployed script body wrong"
[ -f "$deployed.agent-tools-managed.yml" ] || fail "deployed script sidecar marker missing"
[ -f "$tmp/scodex15/agent-tools/scripts/personal-wrap" ] || fail "codex script not deployed"

# 変更なしなら skip (up-to-date)
run15 > "$tmp/out15-skip" 2>&1 || fail "script skip run should succeed"
grep -q "skip: \[claude-code\].*up-to-date" "$tmp/out15-skip" || fail "missing script up-to-date skip: $(cat "$tmp/out15-skip")"

# source 変更で update → apply で反映 (内容変更につき approved_build_id も焼き直す)
printf '#!/bin/sh\necho v2\n' > "$tmp/srepo15/shared/scripts/personal-wrap.sh"
write_wrap_manifest
"$build" --root "$tmp/srepo15" --quiet > /dev/null
"$register" --root "$tmp/srepo15" --quiet > /dev/null
run15 > "$tmp/out15-upd" 2>&1 || fail "script update dry-run should succeed"
grep -q "update: \[claude-code\]" "$tmp/out15-upd" || fail "missing script update plan: $(cat "$tmp/out15-upd")"
run15 --apply --quiet > /dev/null 2>&1
grep -q "echo v2" "$deployed" || fail "script update not applied"

# --- case 16: catalog の build_id と generated が不一致なら run build first (stale generated) ---
printf '#!/bin/sh\necho v3\n' > "$tmp/srepo15/shared/scripts/personal-wrap.sh"
write_wrap_manifest
"$register" --root "$tmp/srepo15" --quiet > /dev/null   # build せず register だけ
run15 > "$tmp/out16" 2>&1 || fail "stale script dry-run should succeed"
grep -q "skip: \[claude-code\].*run build first" "$tmp/out16" \
  || fail "stale generated script should skip with run build first: $(cat "$tmp/out16")"
# 整合を戻す (以降の case は v3 を配置済みにする)
"$build" --root "$tmp/srepo15" --quiet > /dev/null
"$register" --root "$tmp/srepo15" --quiet > /dev/null
run15 --apply --quiet > /dev/null 2>&1

# --- case 17: unmanaged な同名 script は conflict で停止し、--apply でも上書きしない ---
rm -f "$deployed" "$deployed.agent-tools-managed.yml"
echo "user-owned script" > "$deployed"   # marker なし
status=0
run15 --apply > "$tmp/out17" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "unmanaged script should exit 1, got $status: $(cat "$tmp/out17")"
grep -q "conflict: \[claude-code\].*unmanaged" "$tmp/out17" || fail "missing script unmanaged conflict: $(cat "$tmp/out17")"
grep -q "user-owned script" "$deployed" || fail "unmanaged script must not be overwritten"

# --- case 18: 配置先の親 (agent-tools) が symlink なら conflict (素通りさせない) ---
rm -rf "$tmp/sclaude15/agent-tools"
mkdir -p "$tmp/realat"
ln -s "$tmp/realat" "$tmp/sclaude15/agent-tools"
status=0
run15 --apply > "$tmp/out18" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked agent-tools parent should exit 1: $(cat "$tmp/out18")"
grep -q "conflict: \[claude-code\].*symlink" "$tmp/out18" || fail "missing script parent symlink conflict: $(cat "$tmp/out18")"
[ ! -e "$tmp/realat/scripts/personal-wrap" ] || fail "must not write through symlinked agent-tools parent"

# --- case 19: 本体未存在でも sidecar marker が symlink なら conflict (素通りさせない) ---
# (apply は sidecar も書き込む。create 分岐で sidecar の symlink を見逃すと home 外へ追従する)
rm -rf "$tmp/sclaude15/agent-tools"
mkdir -p "$tmp/sclaude15/agent-tools/scripts" "$tmp/realmarker"
ln -s "$tmp/realmarker/stolen.yml" "$deployed.agent-tools-managed.yml"
status=0
run15 --apply > "$tmp/out19" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked sidecar should exit 1: $(cat "$tmp/out19")"
grep -q "conflict: \[claude-code\].*symlink" "$tmp/out19" || fail "missing sidecar symlink conflict: $(cat "$tmp/out19")"
[ ! -e "$tmp/realmarker/stolen.yml" ] || fail "must not write through symlinked sidecar marker"
[ ! -e "$deployed" ] || fail "script body must not be created when sidecar is unsafe"

# --- case 20: register 後に manifest が変わった entry は配置せず register を促す (#148) ---
# (登録判断 (risk / review / targets) は manifest 依存。判断ごと stale なので fail-closed に skip)
mkdir -p "$tmp/mrepo/shared/workflows" "$tmp/mcodex" "$tmp/mclaude"
printf '# demo\n' > "$tmp/mrepo/shared/workflows/personal-mdemo.md"
cat > "$tmp/mrepo/shared/workflows/personal-mdemo.asset.yml" <<'EOF'
schema_version: 1
name: personal-mdemo
kind: workflow
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/workflows/personal-mdemo.md
  format: markdown
EOF
run20() { "$sync" --root "$tmp/mrepo" --codex-home "$tmp/mcodex" --claude-home "$tmp/mclaude" "$@"; }
"$build" --root "$tmp/mrepo" --quiet > /dev/null
"$register" --root "$tmp/mrepo" --quiet > /dev/null
run20 > "$tmp/out20a" 2>&1 || fail "fresh manifest sync should succeed: $(cat "$tmp/out20a")"
grep -q "create: \[claude-code\]" "$tmp/out20a" || fail "fresh manifest should plan create: $(cat "$tmp/out20a")"
echo "# edited after register" >> "$tmp/mrepo/shared/workflows/personal-mdemo.asset.yml"
status=0
run20 --apply > "$tmp/out20b" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "manifest-stale sync should exit 0 (skip): $(cat "$tmp/out20b")"
grep -q "skip: \[claude-code\].*manifest changed; run scripts/register.sh first" "$tmp/out20b" \
  || fail "missing manifest-stale skip reason: $(cat "$tmp/out20b")"
[ ! -e "$tmp/mclaude/skills/personal-mdemo" ] || fail "manifest-stale entry must not be deployed"

# --- case 21: 未レビュー (human_review_required) の asset は --apply でも配置しない (#150) ---
# (register の review gate を sync が尊重すること。connect には同等テストがあるが sync に無かった)
mkdir -p "$tmp/grepo/shared/skills/personal-gated" "$tmp/gcodex" "$tmp/gclaude"
cat > "$tmp/grepo/shared/skills/personal-gated/SKILL.md" <<'EOF'
---
name: personal-gated
description: pending review skill
---

# gated
EOF
cat > "$tmp/grepo/shared/skills/personal-gated/asset.yml" <<'EOF'
schema_version: 1
name: personal-gated
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: medium
  privacy: low
source:
  path: shared/skills/personal-gated
  format: directory
EOF
run21() { "$sync" --root "$tmp/grepo" --codex-home "$tmp/gcodex" --claude-home "$tmp/gclaude" "$@"; }
"$build" --root "$tmp/grepo" --quiet > /dev/null
# 宣言 medium + 未承認 → register は human_review_required (exit 3, 非致命)
status=0
"$register" --root "$tmp/grepo" --quiet > /dev/null || status=$?
[ "$status" -eq 3 ] || fail "pending skill should register as human_review_required (exit 3), got $status"
status=0
run21 --apply > "$tmp/out21" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "sync of gated asset should exit 0 (skip): $(cat "$tmp/out21")"
grep -q "skip: \[claude-code\].*human_review_required" "$tmp/out21" \
  || fail "gated asset must skip with human_review_required reason: $(cat "$tmp/out21")"
[ ! -e "$tmp/gclaude/skills/personal-gated" ] || fail "unreviewed asset must not be deployed"

# --- case 22: --prune は catalog に載らない managed orphan を撤去する (#154) ---
# fixture: 2 skill を配置後、片方を shared/ から消して build --prune + register し直す。
mkdir -p "$tmp/prepo/shared/skills/personal-keep" "$tmp/prepo/shared/skills/personal-gone" \
  "$tmp/pcodex" "$tmp/pclaude"
for n in keep gone; do
  cat > "$tmp/prepo/shared/skills/personal-$n/SKILL.md" <<EOF
---
name: personal-$n
description: demo skill $n
---
body $n
EOF
  cat > "$tmp/prepo/shared/skills/personal-$n/asset.yml" <<EOF
schema_version: 1
name: personal-$n
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-$n
  format: directory
EOF
done
run22() { "$sync" --root "$tmp/prepo" --codex-home "$tmp/pcodex" --claude-home "$tmp/pclaude" "$@"; }
"$build" --root "$tmp/prepo" --quiet > /dev/null
"$register" --root "$tmp/prepo" --quiet > /dev/null
run22 --apply --quiet > /dev/null
[ -f "$tmp/pclaude/skills/personal-gone/SKILL.md" ] || fail "prune fixture should deploy personal-gone"
# personal-gone を shared/ から撤去して catalog を作り直す
rm -rf "$tmp/prepo/shared/skills/personal-gone" "$tmp/prepo/shared/skills/personal-gone.asset.yml" 2>/dev/null
rm -rf "$tmp/prepo/shared/skills/personal-gone"
"$build" --root "$tmp/prepo" --prune --quiet > /dev/null
"$register" --root "$tmp/prepo" --quiet > /dev/null

# --prune なしの sync は orphan に触れない (従来挙動)
run22 > "$tmp/out22-noprune" 2>&1 || fail "sync without --prune should succeed"
! grep -q "personal-gone" "$tmp/out22-noprune" || fail "orphan must not appear without --prune"

# --prune の dry-run は delete を列挙するだけで消さない
run22 --prune > "$tmp/out22-dry" 2>&1 || fail "prune dry-run should succeed: $(cat "$tmp/out22-dry")"
grep -q "delete: \[claude-code\].*personal-gone (not in catalog)" "$tmp/out22-dry" \
  || fail "missing delete plan: $(cat "$tmp/out22-dry")"
grep -q "dry-run only" "$tmp/out22-dry" || fail "prune without --apply must stay dry-run"
[ -d "$tmp/pclaude/skills/personal-gone" ] || fail "dry-run prune must not delete"

# --prune --apply で削除される。現役 (personal-keep) は残る
run22 --prune --apply > "$tmp/out22-apply" 2>&1 || fail "prune apply should succeed: $(cat "$tmp/out22-apply")"
[ ! -e "$tmp/pclaude/skills/personal-gone" ] || fail "prune apply should delete orphan"
[ -f "$tmp/pclaude/skills/personal-keep/SKILL.md" ] || fail "prune must keep catalog-backed skill"

# --- case 23: unmanaged / symlink の orphan は削除せず可視化するだけ ---
mkdir -p "$tmp/pclaude/skills/personal-handmade"
echo "hand made" > "$tmp/pclaude/skills/personal-handmade/SKILL.md"   # marker なし
mkdir -p "$tmp/real-orphan"
ln -s "$tmp/real-orphan" "$tmp/pclaude/skills/personal-linked"
status=0
run22 --prune --apply > "$tmp/out23" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "unmanaged orphan must not block prune (exit 0): $(cat "$tmp/out23")"
grep -q "skip: \[claude-code\].*personal-handmade (orphan is unmanaged; left in place)" "$tmp/out23" \
  || fail "missing unmanaged orphan skip: $(cat "$tmp/out23")"
grep -q "skip: \[claude-code\].*personal-linked (orphan is a symlink; left in place)" "$tmp/out23" \
  || fail "missing symlink orphan skip: $(cat "$tmp/out23")"
[ -f "$tmp/pclaude/skills/personal-handmade/SKILL.md" ] || fail "unmanaged orphan must be left in place"
[ -L "$tmp/pclaude/skills/personal-linked" ] || fail "symlink orphan must be left in place"
[ -e "$tmp/real-orphan" ] || fail "symlink destination must be untouched"
rm -rf "$tmp/pclaude/skills/personal-handmade" "$tmp/pclaude/skills/personal-linked"

# --- case 24: script orphan は本体 + sidecar marker を対で撤去する ---
mkdir -p "$tmp/prepo/shared/scripts"
printf '#!/bin/sh\necho tool\n' > "$tmp/prepo/shared/scripts/personal-ptool.sh"
ptoolbid=$(ruby -r"$script_dir/../lib/build" \
  -e 'puts Build.build_id_for(ARGV[0], "shared/scripts/personal-ptool.sh", "text")' "$tmp/prepo")
cat > "$tmp/prepo/shared/scripts/personal-ptool.asset.yml" <<EOF
schema_version: 1
name: personal-ptool
kind: script
visibility: personal
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
review:
  human_review: approved
  approved_build_id: $ptoolbid
source:
  path: shared/scripts/personal-ptool.sh
  format: text
EOF
"$build" --root "$tmp/prepo" --quiet > /dev/null
"$register" --root "$tmp/prepo" --quiet > /dev/null
run22 --apply --quiet > /dev/null
pdeployed="$tmp/pclaude/agent-tools/scripts/personal-ptool"
[ -f "$pdeployed" ] || fail "script prune fixture should deploy personal-ptool"
rm -f "$tmp/prepo/shared/scripts/personal-ptool.sh" "$tmp/prepo/shared/scripts/personal-ptool.asset.yml"
"$build" --root "$tmp/prepo" --prune --quiet > /dev/null
"$register" --root "$tmp/prepo" --quiet > /dev/null
run22 --prune --apply > "$tmp/out24" 2>&1 || fail "script prune should succeed: $(cat "$tmp/out24")"
grep -q "delete: \[claude-code\].*personal-ptool (not in catalog)" "$tmp/out24" \
  || fail "missing script delete plan: $(cat "$tmp/out24")"
[ ! -e "$pdeployed" ] || fail "script orphan body should be deleted"
[ ! -e "$pdeployed.agent-tools-managed.yml" ] || fail "script orphan sidecar should be deleted"

# --- case 25: catalog に entry があれば registration 状態によらず prune しない ---
# (human_review_required でも asset は shared/ に実在する。撤去は catalog 不在のときだけ)
mkdir -p "$tmp/prepo/shared/skills/personal-keep2"
cat > "$tmp/prepo/shared/skills/personal-keep2/SKILL.md" <<'EOF'
---
name: personal-keep2
description: gated skill
---
body
EOF
cat > "$tmp/prepo/shared/skills/personal-keep2/asset.yml" <<'EOF'
schema_version: 1
name: personal-keep2
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-keep2
  format: directory
EOF
"$build" --root "$tmp/prepo" --quiet > /dev/null
"$register" --root "$tmp/prepo" --quiet > /dev/null
run22 --apply --quiet > /dev/null
[ -f "$tmp/pclaude/skills/personal-keep2/SKILL.md" ] || fail "keep2 should deploy"
# risk を medium に上げて human_review_required にする (entry は残る)
cat > "$tmp/prepo/shared/skills/personal-keep2/asset.yml" <<'EOF'
schema_version: 1
name: personal-keep2
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: medium
  privacy: low
source:
  path: shared/skills/personal-keep2
  format: directory
EOF
"$build" --root "$tmp/prepo" --quiet > /dev/null
"$register" --root "$tmp/prepo" --quiet > /dev/null || true   # exit 3 (human_review_required)
run22 --prune --apply > "$tmp/out25" 2>&1 || fail "prune with gated entry should succeed: $(cat "$tmp/out25")"
! grep -q "delete: .*personal-keep2" "$tmp/out25" || fail "gated entry must not be pruned: $(cat "$tmp/out25")"
[ -f "$tmp/pclaude/skills/personal-keep2/SKILL.md" ] || fail "gated deployed skill must be kept"

# --- case 26b: valid だが空の catalog ({"assets": []}) でも --prune は何も削除しない ---
# (manifest ゼロの repo (間違った --root 等) で register すると valid な空 catalog が
#  できる。catalog_present だけを条件にすると全 deployed が orphan 扱いで全削除される)
mkdir -p "$tmp/erepo/shared" "$tmp/ecodex" "$tmp/eclaude"
"$register" --root "$tmp/erepo" --quiet > /dev/null   # manifest ゼロ → assets: []
ruby -rjson -e 'j = JSON.parse(File.read(ARGV[0])); exit(j["assets"].empty? ? 0 : 1)' \
  "$tmp/erepo/generated/catalog.json" || fail "empty repo register should write an empty catalog"
mkdir -p "$tmp/eclaude/skills/personal-victim"
cat > "$tmp/eclaude/skills/personal-victim/.agent-tools-managed.yml" <<'EOF'
repo: agent-tools
name: personal-victim
target: claude-code
artifact_kind: skill
source: shared/skills/personal-victim
build_id: sha256:000000000000
EOF
echo "victim" > "$tmp/eclaude/skills/personal-victim/SKILL.md"
"$sync" --root "$tmp/erepo" --codex-home "$tmp/ecodex" --claude-home "$tmp/eclaude" --prune --apply \
  > "$tmp/out26b" 2>&1 || fail "prune with empty catalog should succeed: $(cat "$tmp/out26b")"
! grep -q "delete:" "$tmp/out26b" || fail "empty catalog must not plan deletes: $(cat "$tmp/out26b")"
[ -f "$tmp/eclaude/skills/personal-victim/SKILL.md" ] \
  || fail "managed deployed asset must survive prune with an empty catalog"

# --- case 26: catalog が無ければ --prune は何も削除しない (fail-closed) ---
mkdir -p "$tmp/nrepo/shared/skills" "$tmp/ncodex" "$tmp/nclaude/skills/personal-x"
echo "x" > "$tmp/nclaude/skills/personal-x/SKILL.md"
"$sync" --root "$tmp/nrepo" --codex-home "$tmp/ncodex" --claude-home "$tmp/nclaude" --prune --apply \
  > "$tmp/out26" 2>&1 || fail "prune without catalog should succeed: $(cat "$tmp/out26")"
grep -q "no catalog; run scripts/register.sh first" "$tmp/out26" \
  || fail "prune without catalog should ask for register: $(cat "$tmp/out26")"
[ -f "$tmp/nclaude/skills/personal-x/SKILL.md" ] || fail "prune without catalog must not delete anything"

# --- case 27: 所有先の非 UTF-8 バイトで crash せず判定できる (#149) ---
# 27a: unmanaged な非 UTF-8 所有先は conflict (String#strip の ArgumentError で落ちない)
mkdir -p "$tmp/codex27" "$tmp/claude27"
printf '# memo \377\376 non-utf8\n' > "$tmp/codex27/AGENTS.md"
status=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex27" --claude-home "$tmp/claude27" > "$tmp/out27a" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "non-UTF-8 unmanaged owned file should conflict (exit 1), not crash: $(cat "$tmp/out27a")"
grep -q "conflict: \[codex\].*unmanaged" "$tmp/out27a" \
  || fail "non-UTF-8 owned file should be an unmanaged conflict: $(cat "$tmp/out27a")"

# 27b: marker が正常なら、末尾に非 UTF-8 バイトがあっても managed のまま (scrub は判定のみ)
mkdir -p "$tmp/codex27b" "$tmp/claude27b"
cp "$tmp/repo/generated/codex/instructions/AGENTS.md" "$tmp/codex27b/AGENTS.md"
printf '\377' >> "$tmp/codex27b/AGENTS.md"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex27b" --claude-home "$tmp/claude27b" > "$tmp/out27b" 2>&1 \
  || fail "sync with managed non-UTF-8 tail should succeed: $(cat "$tmp/out27b")"
grep -q "skip: \[codex\].*up-to-date" "$tmp/out27b" \
  || fail "managed owned file with non-UTF-8 tail should stay up-to-date: $(cat "$tmp/out27b")"

# --- case 28: 所有先 AGENTS.md 自体が symlink なら conflict (実体へ書き抜けない) (#150) ---
# (case 11 は親 dir の symlink。所有ファイル自体が symlink のケースはここで押さえる)
mkdir -p "$tmp/codex28" "$tmp/claude28"
echo "# real file elsewhere" > "$tmp/real-agents-sync.md"
ln -s "$tmp/real-agents-sync.md" "$tmp/codex28/AGENTS.md"
status=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex28" --claude-home "$tmp/claude28" --apply > "$tmp/out28" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked owned AGENTS.md should conflict (exit 1): $(cat "$tmp/out28")"
grep -q "conflict: \[codex\].*symlink" "$tmp/out28" \
  || fail "missing owned-symlink conflict: $(cat "$tmp/out28")"
grep -q "# real file elsewhere" "$tmp/real-agents-sync.md" \
  || fail "must not write through a symlinked owned file"

echo "ok: sync self-test passed"
