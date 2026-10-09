#!/bin/sh
# sync.sh の self-test。
# 一時 directory に fixture と fake tool homes を生成して検証する。
# 実際の ~/.codex / ~/.claude には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
build="$script_dir/../build.sh"
register="$script_dir/../register.sh"
sync="$script_dir/../sync.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT


run_sync() {
  "$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" "$@"
}

# --- fixture repo を build ---
mkdir -p "$tmp/codex/skills" "$tmp/claude/skills"
WAM_EXTRA='summary: demo workflow'
make_demo_repo "$tmp/repo" workflows personal-demo workflow '# demo v1'
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
---
name: personal-demo
description: demo personal-demo
---

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
WAM_EXTRA='summary: demo instruction'
write_asset_manifest "$tmp/repo/shared/workflows/personal-demo.asset.yml" \
  personal-demo instruction public shared/workflows/personal-demo.md markdown \
  codex claude-code
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
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --opencode-home "$tmp/opencode9" > "$tmp/out-noconnect" 2>&1
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
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --opencode-home "$tmp/opencode9" > "$tmp/out-instr-update" 2>&1
grep -q "update: \[codex\]" "$tmp/out-instr-update" || fail "instruction should update after rebuild: $(cat "$tmp/out-instr-update")"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --opencode-home "$tmp/opencode9" --apply --quiet > /dev/null
grep -q "demo v3 instruction" "$tmp/codex9/AGENTS.md" || fail "instruction update not applied to AGENTS.md"
head -1 "$tmp/codex9/AGENTS.md" | grep -q "agent-tools:managed" || fail "synced instruction must keep marker"

# --- case 10: catalog の build_id と generated が不一致なら run build first ---
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo v4 instruction
EOF
# build せず register だけ進める (catalog の build_id が generated より新しくなる)
"$register" --root "$tmp/repo" --quiet > /dev/null
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --opencode-home "$tmp/opencode9" > "$tmp/out-stalegen" 2>&1
grep -q "skip: \[codex\].*run build first" "$tmp/out-stalegen" \
  || fail "stale generated vs catalog should skip with run build first: $(cat "$tmp/out-stalegen")"

# --- case 11: instruction 所有先の親 dir が symlink なら conflict (素通りさせない) ---
mkdir -p "$tmp/codex11" "$tmp/claude11" "$tmp/realad"
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
ln -s "$tmp/realad" "$tmp/claude11/agent-tools"
status=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex11" --claude-home "$tmp/claude11" --opencode-home "$tmp/opencode11" --apply > "$tmp/out-adsym" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked owned parent should conflict (exit 1): $(cat "$tmp/out-adsym")"
grep -q "conflict: \[claude-code\].*symlink" "$tmp/out-adsym" || fail "missing parent symlink conflict: $(cat "$tmp/out-adsym")"
[ ! -e "$tmp/realad/CLAUDE.md" ] || fail "must not write through a symlinked parent"

# --- case 12: 空の instruction 所有先は conflict でなく run connect first ---
mkdir -p "$tmp/codex12" "$tmp/claude12"
"$build" --root "$tmp/repo" --quiet > /dev/null
"$register" --root "$tmp/repo" --quiet > /dev/null
printf '   \n\n  \n' > "$tmp/codex12/AGENTS.md"   # 空白のみ (whitespace-only) が既に存在する状態
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex12" --claude-home "$tmp/claude12" --opencode-home "$tmp/opencode12" > "$tmp/out-empty" 2>&1
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
write_asset_manifest "$tmp/srepo/shared/skills/personal-sk/asset.yml" \
  personal-sk skill public shared/skills/personal-sk directory codex
"$build" --root "$tmp/srepo" --quiet > /dev/null
"$register" --root "$tmp/srepo" --quiet > /dev/null   # catalog build_id = generated build_id
# source を変更して build せず register だけ (catalog build_id が generated より新しくなる)
echo "v2" >> "$tmp/srepo/shared/skills/personal-sk/SKILL.md"
"$register" --root "$tmp/srepo" --quiet > /dev/null
"$sync" --root "$tmp/srepo" --codex-home "$tmp/scodex" --claude-home "$tmp/sclaude" --opencode-home "$tmp/sopencode" > "$tmp/out-skstale" 2>&1
grep -q "skip: \[codex\].*run build first" "$tmp/out-skstale" \
  || fail "stale skill generated vs catalog should skip with run build first: $(cat "$tmp/out-skstale")"
# --apply しても stale skill は配置されない
"$sync" --root "$tmp/srepo" --codex-home "$tmp/scodex" --claude-home "$tmp/sclaude" --opencode-home "$tmp/sopencode" --apply --quiet > /dev/null 2>&1 || true
[ ! -e "$tmp/scodex/skills/personal-sk" ] || fail "stale skill must not be deployed before rebuild"
# rebuild すれば配置される (gate が正常系を塞がない)
"$build" --root "$tmp/srepo" --quiet > /dev/null
"$sync" --root "$tmp/srepo" --codex-home "$tmp/scodex" --claude-home "$tmp/sclaude" --opencode-home "$tmp/sopencode" --apply --quiet > /dev/null
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
write_asset_manifest "$tmp/repo14/shared/skills/personal-sk/asset.yml" \
  personal-sk skill public shared/skills/personal-sk directory codex
"$build" --root "$tmp/repo14" --quiet > /dev/null
"$register" --root "$tmp/repo14" --quiet > /dev/null
mkdir -p "$tmp/codex14"
ln -s "$tmp/realskills" "$tmp/codex14/skills"   # <home>/skills 自体を symlink にする
status=0
"$sync" --root "$tmp/repo14" --codex-home "$tmp/codex14" --claude-home "$tmp/claude14" --opencode-home "$tmp/opencode14" --apply > "$tmp/out-skparent" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked skills parent should conflict (exit 1): $(cat "$tmp/out-skparent")"
grep -q "conflict: \[codex\].*symlink" "$tmp/out-skparent" || fail "missing skills-parent symlink conflict: $(cat "$tmp/out-skparent")"
[ ! -e "$tmp/realskills/personal-sk" ] || fail "must not write through a symlinked skills parent"

# --- case 15: script artifact を <home>/agent-tools/scripts/ に配置する ---
mkdir -p "$tmp/srepo15/shared/scripts" "$tmp/scodex15" "$tmp/sclaude15"
printf '#!/bin/sh\necho v1\n' > "$tmp/srepo15/shared/scripts/personal-wrap.sh"
# script kind は human review 必須 (#147) + 承認は内容に紐づく (#148)。
# source を書き換える case (v2/v3) の前に呼び直し、現内容で approved を焼き直す。
write_wrap_manifest() {
  write_approved_script_manifest "$tmp/srepo15" shared/scripts/personal-wrap.sh \
    personal-wrap personal codex claude-code
}
write_wrap_manifest
run15() { "$sync" --root "$tmp/srepo15" --codex-home "$tmp/scodex15" --claude-home "$tmp/sclaude15" --opencode-home "$tmp/sopencode15" "$@"; }
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
write_asset_manifest "$tmp/mrepo/shared/workflows/personal-mdemo.asset.yml" \
  personal-mdemo workflow public shared/workflows/personal-mdemo.md markdown claude-code
run20() { "$sync" --root "$tmp/mrepo" --codex-home "$tmp/mcodex" --claude-home "$tmp/mclaude" --opencode-home "$tmp/mopencode" "$@"; }
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
run21() { "$sync" --root "$tmp/grepo" --codex-home "$tmp/gcodex" --claude-home "$tmp/gclaude" --opencode-home "$tmp/gopencode" "$@"; }
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
  write_asset_manifest "$tmp/prepo/shared/skills/personal-$n/asset.yml" \
    "personal-$n" skill public "shared/skills/personal-$n" directory claude-code
done
run22() { "$sync" --root "$tmp/prepo" --codex-home "$tmp/pcodex" --claude-home "$tmp/pclaude" --opencode-home "$tmp/popencode" "$@"; }
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

# --- case 23b: conflict があれば、prune の削除も含めて何も適用しない (#375) ---
# fixture: 2 skill を配置後、片方を shared/ から消して managed orphan にし、新しい skill の配置先に unmanaged な
# 同名 dir を置いて conflict を作る。--prune --apply は exit 1 で、orphan も配置先も変わらない。
mkdir -p "$tmp/cprepo/shared/skills" "$tmp/cpcodex" "$tmp/cpclaude"
for n in keep gone; do
  mkdir -p "$tmp/cprepo/shared/skills/personal-$n"
  cat > "$tmp/cprepo/shared/skills/personal-$n/SKILL.md" <<EOF
---
name: personal-$n
description: demo skill $n
---
body $n
EOF
  write_asset_manifest "$tmp/cprepo/shared/skills/personal-$n/asset.yml" \
    "personal-$n" skill public "shared/skills/personal-$n" directory claude-code
done
run23b() { "$sync" --root "$tmp/cprepo" --codex-home "$tmp/cpcodex" --claude-home "$tmp/cpclaude" --opencode-home "$tmp/cpopencode" "$@"; }
"$build" --root "$tmp/cprepo" --quiet > /dev/null
"$register" --root "$tmp/cprepo" --quiet > /dev/null
run23b --apply --quiet > /dev/null
[ -f "$tmp/cpclaude/skills/personal-gone/SKILL.md" ] || fail "conflict+prune fixture should deploy personal-gone"
rm -rf "$tmp/cprepo/shared/skills/personal-gone"
mkdir -p "$tmp/cprepo/shared/skills/personal-new"
cat > "$tmp/cprepo/shared/skills/personal-new/SKILL.md" <<'EOF'
---
name: personal-new
description: demo skill new
---
body new
EOF
write_asset_manifest "$tmp/cprepo/shared/skills/personal-new/asset.yml" \
  personal-new skill public shared/skills/personal-new directory claude-code
"$build" --root "$tmp/cprepo" --prune --quiet > /dev/null
"$register" --root "$tmp/cprepo" --quiet > /dev/null
mkdir -p "$tmp/cpclaude/skills/personal-new"
echo "hand made" > "$tmp/cpclaude/skills/personal-new/SKILL.md"   # marker なし = unmanaged
status=0
run23b --prune --apply > "$tmp/out23b" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "conflict with prune should exit 1, got $status: $(cat "$tmp/out23b")"
grep -q "conflict: \[claude-code\].*personal-new" "$tmp/out23b" || fail "missing conflict line: $(cat "$tmp/out23b")"
grep -q "delete: \[claude-code\].*personal-gone (not in catalog)" "$tmp/out23b" \
  || fail "the orphan should still be planned for deletion: $(cat "$tmp/out23b")"
grep -q "nothing was applied" "$tmp/out23b" || fail "missing stop notice: $(cat "$tmp/out23b")"
[ -f "$tmp/cpclaude/skills/personal-gone/SKILL.md" ] || fail "conflict must stop the prune delete as well"
grep -q "hand made" "$tmp/cpclaude/skills/personal-new/SKILL.md" || fail "conflict target must not be overwritten"
[ -f "$tmp/cpclaude/skills/personal-keep/SKILL.md" ] || fail "catalog-backed skill must stay"

# --- case 24: script orphan は本体 + sidecar marker を対で撤去する ---
mkdir -p "$tmp/prepo/shared/scripts"
printf '#!/bin/sh\necho tool\n' > "$tmp/prepo/shared/scripts/personal-ptool.sh"
write_approved_script_manifest "$tmp/prepo" shared/scripts/personal-ptool.sh \
  personal-ptool personal claude-code
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
write_asset_manifest "$tmp/prepo/shared/skills/personal-keep2/asset.yml" \
  personal-keep2 skill public shared/skills/personal-keep2 directory claude-code
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
"$sync" --root "$tmp/erepo" --codex-home "$tmp/ecodex" --claude-home "$tmp/eclaude" --opencode-home "$tmp/eopencode" --prune --apply \
  > "$tmp/out26b" 2>&1 || fail "prune with empty catalog should succeed: $(cat "$tmp/out26b")"
! grep -q "delete:" "$tmp/out26b" || fail "empty catalog must not plan deletes: $(cat "$tmp/out26b")"
[ -f "$tmp/eclaude/skills/personal-victim/SKILL.md" ] \
  || fail "managed deployed asset must survive prune with an empty catalog"

# --- case 26: catalog が無ければ --prune は何も削除しない (fail-closed) ---
mkdir -p "$tmp/nrepo/shared/skills" "$tmp/ncodex" "$tmp/nclaude/skills/personal-x"
echo "x" > "$tmp/nclaude/skills/personal-x/SKILL.md"
"$sync" --root "$tmp/nrepo" --codex-home "$tmp/ncodex" --claude-home "$tmp/nclaude" --opencode-home "$tmp/nopencode" --prune --apply \
  > "$tmp/out26" 2>&1 || fail "prune without catalog should succeed: $(cat "$tmp/out26")"
grep -q "no catalog; run scripts/register.sh first" "$tmp/out26" \
  || fail "prune without catalog should ask for register: $(cat "$tmp/out26")"
[ -f "$tmp/nclaude/skills/personal-x/SKILL.md" ] || fail "prune without catalog must not delete anything"

# --- case 27: 所有先の非 UTF-8 バイトで crash せず判定できる (#149) ---
# 27a: unmanaged な非 UTF-8 所有先は conflict (String#strip の ArgumentError で落ちない)
mkdir -p "$tmp/codex27" "$tmp/claude27"
printf '# memo \377\376 non-utf8\n' > "$tmp/codex27/AGENTS.md"
status=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex27" --claude-home "$tmp/claude27" --opencode-home "$tmp/opencode27" > "$tmp/out27a" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "non-UTF-8 unmanaged owned file should conflict (exit 1), not crash: $(cat "$tmp/out27a")"
grep -q "conflict: \[codex\].*unmanaged" "$tmp/out27a" \
  || fail "non-UTF-8 owned file should be an unmanaged conflict: $(cat "$tmp/out27a")"

# 27b: marker が正常なら、末尾に非 UTF-8 バイトがあっても managed のまま (scrub は判定のみ)
mkdir -p "$tmp/codex27b" "$tmp/claude27b"
cp "$tmp/repo/generated/codex/instructions/AGENTS.md" "$tmp/codex27b/AGENTS.md"
printf '\377' >> "$tmp/codex27b/AGENTS.md"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex27b" --claude-home "$tmp/claude27b" --opencode-home "$tmp/opencode27b" > "$tmp/out27b" 2>&1 \
  || fail "sync with managed non-UTF-8 tail should succeed: $(cat "$tmp/out27b")"
grep -q "skip: \[codex\].*up-to-date" "$tmp/out27b" \
  || fail "managed owned file with non-UTF-8 tail should stay up-to-date: $(cat "$tmp/out27b")"

# --- case 28: 所有先 AGENTS.md 自体が symlink なら conflict (実体へ書き抜けない) (#150) ---
# (case 11 は親 dir の symlink。所有ファイル自体が symlink のケースはここで押さえる)
mkdir -p "$tmp/codex28" "$tmp/claude28"
echo "# real file elsewhere" > "$tmp/real-agents-sync.md"
ln -s "$tmp/real-agents-sync.md" "$tmp/codex28/AGENTS.md"
status=0
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex28" --claude-home "$tmp/claude28" --opencode-home "$tmp/opencode28" --apply > "$tmp/out28" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked owned AGENTS.md should conflict (exit 1): $(cat "$tmp/out28")"
grep -q "conflict: \[codex\].*symlink" "$tmp/out28" \
  || fail "missing owned-symlink conflict: $(cat "$tmp/out28")"
grep -q "# real file elsewhere" "$tmp/real-agents-sync.md" \
  || fail "must not write through a symlinked owned file"

# --- case 29: 本体不在で unmanaged な sidecar だけ残る script は conflict (上書きしない, #179 H-06) ---
# (case 17 は本体が unmanaged。本体が無く sidecar marker だけが平ファイルで残るケース。
#  旧 create 経路は本体不在だけ見て sidecar を無条件上書きしていた。)
rm -rf "$tmp/sclaude15/agent-tools"
mkdir -p "$tmp/sclaude15/agent-tools/scripts"
printf 'user-owned sidecar\n' \
  > "$tmp/sclaude15/agent-tools/scripts/personal-wrap.agent-tools-managed.yml"
status=0
run15 --apply > "$tmp/out29" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "unmanaged sidecar without body should exit 1, got $status: $(cat "$tmp/out29")"
grep -q "conflict: \[claude-code\].*sidecar marker is unmanaged" "$tmp/out29" \
  || fail "missing unmanaged-sidecar conflict: $(cat "$tmp/out29")"
grep -q "user-owned sidecar" "$tmp/sclaude15/agent-tools/scripts/personal-wrap.agent-tools-managed.yml" \
  || fail "unmanaged sidecar must not be overwritten"
[ ! -e "$tmp/sclaude15/agent-tools/scripts/personal-wrap" ] \
  || fail "body must not be created when the sidecar is unmanaged"

# --- case 30: shape 不正な catalog は crash させず fail-closed で no-catalog 扱い (#179 M-06) ---
mkdir -p "$tmp/badcat/generated"
# top-level が object でない → 旧実装は data["catalog_version"] 参照で TypeError
echo '["not","an","object"]' > "$tmp/badcat/generated/catalog.json"
"$sync" --root "$tmp/badcat" --codex-home "$tmp/bc-codex" --claude-home "$tmp/bc-claude" --opencode-home "$tmp/bc-opencode" \
  > "$tmp/out30a" 2>&1 || fail "malformed catalog must not crash sync: $(cat "$tmp/out30a")"
grep -q "no catalog" "$tmp/out30a" \
  || fail "non-object catalog should be treated as no-catalog: $(cat "$tmp/out30a")"
# assets が Array of Hash でない場合も fail-closed。version は現行の CATALOG_VERSION に合わせる (古い version だと
# 型検査より前の version 不一致の分岐で返り、型検査を外しても通ってしまう。#375)
cur_ver=$(ruby -r"$script_dir/../lib/artifact_targets" -e 'print ArtifactTargets::CATALOG_VERSION')
printf '{"catalog_version":%s,"assets":[1,2,3]}\n' "$cur_ver" > "$tmp/badcat/generated/catalog.json"
"$sync" --root "$tmp/badcat" --codex-home "$tmp/bc-codex" --claude-home "$tmp/bc-claude" --opencode-home "$tmp/bc-opencode" \
  > "$tmp/out30b" 2>&1 || fail "malformed assets must not crash sync: $(cat "$tmp/out30b")"
grep -q "no catalog" "$tmp/out30b" \
  || fail "non-Hash asset entries should be treated as no-catalog: $(cat "$tmp/out30b")"
# version 不一致も no-catalog (中身を読まない)。assets は正常な形にして、version の検査だけで決まるようにする
# (assets も壊すと、version の検査を外しても型検査が no-catalog を返してしまう。#378 review)
printf '{"catalog_version":%s,"assets":[]}\n' "$((cur_ver - 1))" > "$tmp/badcat/generated/catalog.json"
"$sync" --root "$tmp/badcat" --codex-home "$tmp/bc-codex" --claude-home "$tmp/bc-claude" --opencode-home "$tmp/bc-opencode" \
  > "$tmp/out30c" 2>&1 || fail "old catalog version must not crash sync: $(cat "$tmp/out30c")"
grep -q "no catalog" "$tmp/out30c" \
  || fail "old catalog version should be treated as no-catalog: $(cat "$tmp/out30c")"

# --- case 31: 本体不在 + managed sidecar は conflict にせず create する (#179 H-06 の許可側) ---
# (case 29 の unmanaged と対。本体だけ消えて自分の managed marker が残った状態からの再配置。)
rm -rf "$tmp/sclaude15/agent-tools"
mkdir -p "$tmp/sclaude15/agent-tools/scripts"
cp "$tmp/srepo15/generated/claude-code/scripts/personal-wrap.agent-tools-managed.yml" \
   "$tmp/sclaude15/agent-tools/scripts/personal-wrap.agent-tools-managed.yml"
run15 > "$tmp/out31" 2>&1 || fail "body-absent + managed sidecar dry-run should succeed: $(cat "$tmp/out31")"
grep -q "create: \[claude-code\]" "$tmp/out31" \
  || fail "body-absent + managed sidecar should plan create (not conflict): $(cat "$tmp/out31")"
run15 --apply --quiet > /dev/null 2>&1
[ -f "$tmp/sclaude15/agent-tools/scripts/personal-wrap" ] \
  || fail "create should deploy the body when the existing sidecar is managed"

# --- case 32: plugin artifact を <opencode home>/plugins/<name>.js に配置する (#295) ---
# fixture: approved plugin (plugin kind は常に human review 必須) と、OpenCode 側の既存 file
# (opencode.json / package.json / node_modules / 非 personal の herdr-agent-state.js)。sync が
# 書くのは plugins/personal-*.js だけで、それ以外は byte で変わらないことを見る。
mkdir -p "$tmp/plrepo/shared/plugins" "$tmp/plopen/plugins" "$tmp/plopen/node_modules/@opencode-ai/plugin" \
  "$tmp/plcodex" "$tmp/plclaude"
printf 'export default { id: "personal-plug", server: async () => ({}) };\n// v1\n' \
  > "$tmp/plrepo/shared/plugins/personal-plug.js"
# 承認は内容に紐づく (#148)。source を書き換える前に呼び直し、現内容で approved を焼き直す。
write_plug_manifest() { write_approved_plugin_manifest "$tmp/plrepo" personal-plug personal; }
write_plug_manifest
printf '{ "$schema": "https://opencode.ai/config.json" }\n' > "$tmp/plopen/opencode.json"
printf '{ "dependencies": { "@opencode-ai/plugin": "1.18.30" } }\n' > "$tmp/plopen/package.json"
printf 'export {};\n' > "$tmp/plopen/node_modules/@opencode-ai/plugin/index.js"
printf 'export const herdr = async () => ({});\n' > "$tmp/plopen/plugins/herdr-agent-state.js"
run32() {
  "$sync" --root "$tmp/plrepo" --codex-home "$tmp/plcodex" --claude-home "$tmp/plclaude" \
    --opencode-home "$tmp/plopen" "$@"
}
# opencode home のうち sync の書き先 (plugins/personal-*) 以外の file の checksum。
opencode_others() { find "$tmp/plopen" -type f ! -path "$tmp/plopen/plugins/personal-*" -exec cksum {} + | sort; }
# marker 行は実装 (PluginMarker.render) で組む。使い方: plugin_marker <name> <target> <build_id>
plugin_marker() {
  ruby -r"$script_dir/../lib/plugin_marker" -e 'puts PluginMarker.render(name: ARGV[0], target: ARGV[1],
    source: "shared/plugins/#{ARGV[0]}.js", build_id: ARGV[2])' "$@"
}
others_before=$(opencode_others)
"$build" --root "$tmp/plrepo" --quiet > /dev/null
"$register" --root "$tmp/plrepo" --quiet > /dev/null
pdeployed="$tmp/plopen/plugins/personal-plug.js"
pgen="$tmp/plrepo/generated/opencode/plugins/personal-plug.js"

# dry-run は create を plan し、何も書かない
run32 > "$tmp/out32-dry" 2>&1 || fail "plugin dry-run should succeed: $(cat "$tmp/out32-dry")"
grep -q "create: \[opencode\] .*/plugins/personal-plug.js" "$tmp/out32-dry" \
  || fail "missing plugin create plan: $(cat "$tmp/out32-dry")"
[ ! -e "$pdeployed" ] || fail "dry-run must not write plugin"

# --apply で generated と byte 一致の file (marker 行つき) が mode 0644 で置かれる
run32 --apply > "$tmp/out32-apply" 2>&1 || fail "plugin apply should succeed: $(cat "$tmp/out32-apply")"
[ -f "$pdeployed" ] || fail "plugin not deployed"
cmp -s "$pdeployed" "$pgen" || fail "deployed plugin must be byte-identical to generated"
[ "$(head -1 "$pdeployed")" = "$(plugin_marker personal-plug opencode "$(bid "$tmp/plrepo" shared/plugins/personal-plug.js text)")" ] \
  || fail "deployed plugin must start with the marker line: $(head -1 "$pdeployed")"
ruby -e 'exit((File.stat(ARGV[0]).mode & 0o777) == 0o644)' "$pdeployed" || fail "deployed plugin mode must be 0644"
[ ! -e "$tmp/plcodex/plugins" ] && [ ! -e "$tmp/plclaude/plugins" ] || fail "plugin must land only in the opencode home"
[ "$others_before" = "$(opencode_others)" ] \
  || fail "apply must not touch OpenCode's own files (opencode.json / package.json / node_modules / herdr-agent-state.js)"

# 変更なしなら skip (up-to-date)
run32 > "$tmp/out32-skip" 2>&1 || fail "plugin skip run should succeed"
grep -q "skip: \[opencode\].*up-to-date" "$tmp/out32-skip" || fail "missing plugin up-to-date skip: $(cat "$tmp/out32-skip")"

# source 変更で update → apply で反映
printf 'export default { id: "personal-plug", server: async () => ({}) };\n// v2\n' \
  > "$tmp/plrepo/shared/plugins/personal-plug.js"
write_plug_manifest
"$build" --root "$tmp/plrepo" --quiet > /dev/null
"$register" --root "$tmp/plrepo" --quiet > /dev/null
run32 > "$tmp/out32-upd" 2>&1 || fail "plugin update dry-run should succeed"
grep -q "update: \[opencode\]" "$tmp/out32-upd" || fail "missing plugin update plan: $(cat "$tmp/out32-upd")"
run32 --apply --quiet > /dev/null 2>&1
grep -q "// v2" "$pdeployed" || fail "plugin update not applied"
cmp -s "$pdeployed" "$pgen" || fail "updated plugin must be byte-identical to generated"

# --- case 33: catalog の build_id と generated が不一致なら run build first (stale generated) ---
printf 'export default { id: "personal-plug", server: async () => ({}) };\n// v3\n' \
  > "$tmp/plrepo/shared/plugins/personal-plug.js"
write_plug_manifest
"$register" --root "$tmp/plrepo" --quiet > /dev/null   # build せず register だけ
run33_rc=0
run32 --apply > "$tmp/out33" 2>&1 || run33_rc=$?
[ "$run33_rc" -eq 0 ] || fail "stale plugin generated should skip (exit 0): $(cat "$tmp/out33")"
grep -q "skip: \[opencode\].*run build first" "$tmp/out33" \
  || fail "stale generated plugin should skip with run build first: $(cat "$tmp/out33")"
grep -q "// v2" "$pdeployed" || fail "stale generated plugin must not be deployed"
# 整合を戻す (以降の case は v3 を配置済みにする)
"$build" --root "$tmp/plrepo" --quiet > /dev/null
"$register" --root "$tmp/plrepo" --quiet > /dev/null
run32 --apply --quiet > /dev/null 2>&1
pbid=$(bid "$tmp/plrepo" shared/plugins/personal-plug.js text)

# --- case 34: unmanaged / symlink / directory の target は conflict で停止し、--apply でも書かない ---
# 使い方: expect_plugin_conflict <label> <reason regex>
expect_plugin_conflict() {
  epc_rc=0
  run32 --apply > "$tmp/out34" 2>&1 || epc_rc=$?
  [ "$epc_rc" -eq 1 ] || fail "$1 should conflict (exit 1), got $epc_rc: $(cat "$tmp/out34")"
  grep -q "conflict: \[opencode\].*$2" "$tmp/out34" || fail "$1: missing conflict reason '$2': $(cat "$tmp/out34")"
  grep -q "nothing was applied" "$tmp/out34" || fail "$1: missing stop notice"
}
# 34a: marker の無い同名 file
echo "user plugin" > "$pdeployed"
expect_plugin_conflict "unmarked same-name plugin" "existing target is unmanaged"
grep -q "user plugin" "$pdeployed" || fail "unmarked plugin must not be overwritten"
# 34b: 別の name の marker
printf '%s\nexport default {};\n' "$(plugin_marker personal-other opencode "$pbid")" > "$pdeployed"
expect_plugin_conflict "plugin with another asset's marker" "existing target is unmanaged"
# 34c: instruction の marker (HTML コメント) は plugin の管理として認めない
imarker=$(ruby -r"$script_dir/../lib/instruction_marker" -e 'puts InstructionMarker.render(name: "personal-plug",
  target: "opencode", source: "shared/plugins/personal-plug.js", build_id: ARGV[0])' "$pbid")
printf '%s\nexport default {};\n' "$imarker" > "$pdeployed"
expect_plugin_conflict "plugin with an instruction marker" "existing target is unmanaged"
# 34d: 別 tool (claude-code) 向けの marker
printf '%s\nexport default {};\n' "$(plugin_marker personal-plug claude-code "$pbid")" > "$pdeployed"
expect_plugin_conflict "plugin with a claude-code marker" "existing target is unmanaged"
# 34e: target が symlink (実体は触らない)
rm -f "$pdeployed"
echo "real plugin elsewhere" > "$tmp/real-plugin.js"
ln -s "$tmp/real-plugin.js" "$pdeployed"
expect_plugin_conflict "symlinked plugin" "existing target is a symlink"
[ -L "$pdeployed" ] || fail "symlinked plugin must not be replaced"
grep -q "real plugin elsewhere" "$tmp/real-plugin.js" || fail "symlink destination must be untouched"
rm -f "$pdeployed"
# 34f: plugins/ 自体が symlink (home の外へ書き抜けない)
mv "$tmp/plopen/plugins" "$tmp/plopen/plugins.real"
mkdir -p "$tmp/real-plugins"
ln -s "$tmp/real-plugins" "$tmp/plopen/plugins"
expect_plugin_conflict "symlinked plugins dir" "existing target is a symlink"
[ ! -e "$tmp/real-plugins/personal-plug.js" ] || fail "must not write through a symlinked plugins dir"
rm "$tmp/plopen/plugins"
mv "$tmp/plopen/plugins.real" "$tmp/plopen/plugins"
# 34g: target が directory
mkdir -p "$pdeployed"
expect_plugin_conflict "directory at plugin path" "existing target is not a regular file"
[ -d "$pdeployed" ] || fail "directory at plugin path must be left in place"
rmdir "$pdeployed"
# 復旧
run32 --apply --quiet > /dev/null 2>&1
cmp -s "$pdeployed" "$pgen" || fail "plugin should be redeployed after conflicts are cleared"

# --- case 35: 非 personal の file と TOOL_KINDS 外の場所は plan にも prune にも出ない ---
# opencode home の skills/personal-x と agent-tools/scripts/personal-x に target=opencode の marker を
# 置いても走査しない (OpenCode が ~/.claude と同じ形で読む skills/ を消さないため)。
yaml_marker() {
  ruby -r"$script_dir/../lib/yaml_marker" -e 'puts YamlMarker.render(name: ARGV[0], target: ARGV[1],
    source: ARGV[2], build_id: ARGV[3])' "$@"
}
mkdir -p "$tmp/plopen/skills/personal-x" "$tmp/plopen/agent-tools/scripts"
echo "skill body" > "$tmp/plopen/skills/personal-x/SKILL.md"
yaml_marker personal-x opencode shared/skills/personal-x "sha256:$(printf '%064d' 0)" \
  > "$tmp/plopen/skills/personal-x/.agent-tools-managed.yml"
echo "script body" > "$tmp/plopen/agent-tools/scripts/personal-x"
yaml_marker personal-x opencode shared/scripts/personal-x.sh "sha256:$(printf '%064d' 0)" \
  > "$tmp/plopen/agent-tools/scripts/personal-x.agent-tools-managed.yml"
run32 --prune --apply > "$tmp/out35" 2>&1 || fail "prune with out-of-scope files should succeed: $(cat "$tmp/out35")"
! grep -q "personal-x" "$tmp/out35" || fail "opencode skills/ and agent-tools/scripts/ must not be scanned: $(cat "$tmp/out35")"
! grep -q "herdr-agent-state" "$tmp/out35" || fail "non-personal plugin must not appear in plans: $(cat "$tmp/out35")"
[ -f "$tmp/plopen/skills/personal-x/SKILL.md" ] || fail "opencode skills/personal-x must be left in place"
[ -f "$tmp/plopen/agent-tools/scripts/personal-x" ] || fail "opencode agent-tools/scripts/personal-x must be left in place"
[ "$others_before" = "$(opencode_others | grep -v "/skills/\|/agent-tools/")" ] \
  || fail "prune must not touch OpenCode's own files"

# --- case 36: human_review_required と manifest_stale は skip (配置しない) ---
# 36a: 未承認の plugin (plugin kind は risk が low でも human review 必須)
printf 'export default { id: "personal-plug2", server: async () => ({}) };\n' > "$tmp/plrepo/shared/plugins/personal-plug2.js"
write_asset_manifest "$tmp/plrepo/shared/plugins/personal-plug2.asset.yml" \
  personal-plug2 plugin personal shared/plugins/personal-plug2.js text opencode
"$build" --root "$tmp/plrepo" --quiet > /dev/null
run36_rc=0
"$register" --root "$tmp/plrepo" --quiet > /dev/null || run36_rc=$?
[ "$run36_rc" -eq 3 ] || fail "unapproved plugin should register as human_review_required (exit 3), got $run36_rc"
run32 --apply > "$tmp/out36a" 2>&1 || fail "sync with a gated plugin should exit 0: $(cat "$tmp/out36a")"
grep -q "skip: \[opencode\].*personal-plug2.js (human_review_required)" "$tmp/out36a" \
  || fail "gated plugin must skip with human_review_required: $(cat "$tmp/out36a")"
[ ! -e "$tmp/plopen/plugins/personal-plug2.js" ] || fail "unreviewed plugin must not be deployed"
rm -f "$tmp/plrepo/shared/plugins/personal-plug2.js" "$tmp/plrepo/shared/plugins/personal-plug2.asset.yml"
"$build" --root "$tmp/plrepo" --prune --quiet > /dev/null
"$register" --root "$tmp/plrepo" --quiet > /dev/null
# 36b: register 後に manifest が変わった entry は配置せず register を促す (#148)
echo "# edited after register" >> "$tmp/plrepo/shared/plugins/personal-plug.asset.yml"
run32 --apply > "$tmp/out36b" 2>&1 || fail "manifest-stale plugin sync should exit 0: $(cat "$tmp/out36b")"
grep -q "skip: \[opencode\].*manifest changed; run scripts/register.sh first" "$tmp/out36b" \
  || fail "missing manifest-stale skip for plugin: $(cat "$tmp/out36b")"
write_plug_manifest
"$register" --root "$tmp/plrepo" --quiet > /dev/null

# --- case 37: --prune は管理下の orphan plugin だけを消し、管理外 / symlink / .ts は触らない ---
# 現役の personal-plug-keep を足してから personal-plug を撤去する (catalog が空だと prune は何もしない)。
printf 'export default { id: "personal-plug-keep", server: async () => ({}) };\n' \
  > "$tmp/plrepo/shared/plugins/personal-plug-keep.js"
write_approved_plugin_manifest "$tmp/plrepo" personal-plug-keep personal
"$build" --root "$tmp/plrepo" --quiet > /dev/null
"$register" --root "$tmp/plrepo" --quiet > /dev/null
run32 --apply --quiet > /dev/null
[ -f "$tmp/plopen/plugins/personal-plug-keep.js" ] || fail "prune fixture should deploy personal-plug-keep"
rm -f "$tmp/plrepo/shared/plugins/personal-plug.js" "$tmp/plrepo/shared/plugins/personal-plug.asset.yml"
"$build" --root "$tmp/plrepo" --prune --quiet > /dev/null
"$register" --root "$tmp/plrepo" --quiet > /dev/null
echo "hand made plugin" > "$tmp/plopen/plugins/personal-stray.js"                   # marker なし
ln -s "$tmp/real-plugin.js" "$tmp/plopen/plugins/personal-linked.js"                # symlink
printf '%s\nexport default {};\n' "$(plugin_marker personal-old opencode "$pbid")" \
  > "$tmp/plopen/plugins/personal-old.ts"                                            # .ts は扱わない

# --prune なしの sync は orphan に触れない
run32 > "$tmp/out37-noprune" 2>&1 || fail "sync without --prune should succeed"
! grep -q "personal-plug.js" "$tmp/out37-noprune" || fail "plugin orphan must not appear without --prune: $(cat "$tmp/out37-noprune")"
# dry-run は delete を列挙するだけで消さない
run32 --prune > "$tmp/out37-dry" 2>&1 || fail "plugin prune dry-run should succeed: $(cat "$tmp/out37-dry")"
grep -q "delete: \[opencode\].*personal-plug.js (not in catalog)" "$tmp/out37-dry" \
  || fail "missing plugin delete plan: $(cat "$tmp/out37-dry")"
grep -q "dry-run only" "$tmp/out37-dry" || fail "plugin prune without --apply must stay dry-run"
[ -f "$pdeployed" ] || fail "dry-run prune must not delete the plugin"
# --prune --apply で orphan だけ消える
run32 --prune --apply > "$tmp/out37" 2>&1 || fail "plugin prune apply should succeed: $(cat "$tmp/out37")"
[ ! -e "$pdeployed" ] || fail "managed plugin orphan should be deleted"
[ -f "$tmp/plopen/plugins/personal-plug-keep.js" ] || fail "prune must keep the catalog-backed plugin"
grep -q "skip: \[opencode\].*personal-stray.js (orphan is unmanaged; left in place)" "$tmp/out37" \
  || fail "missing unmanaged plugin orphan skip: $(cat "$tmp/out37")"
grep -q "skip: \[opencode\].*personal-linked.js (orphan is a symlink; left in place)" "$tmp/out37" \
  || fail "missing symlink plugin orphan skip: $(cat "$tmp/out37")"
[ -f "$tmp/plopen/plugins/personal-stray.js" ] || fail "unmanaged plugin orphan must be left in place"
[ -L "$tmp/plopen/plugins/personal-linked.js" ] || fail "symlink plugin orphan must be left in place"
grep -q "real plugin elsewhere" "$tmp/real-plugin.js" || fail "symlink destination must be untouched"
! grep -q "personal-old" "$tmp/out37" || fail ".ts must be ignored by prune: $(cat "$tmp/out37")"
[ -f "$tmp/plopen/plugins/personal-old.ts" ] || fail ".ts must be left in place"
[ -f "$tmp/plopen/plugins/herdr-agent-state.js" ] || fail "non-personal plugin must be left in place"

# --- case 38: valid だが空の catalog では plugin も --prune で消さない (fail-closed) ---
mkdir -p "$tmp/plerepo/shared" "$tmp/pleopen/plugins"
"$register" --root "$tmp/plerepo" --quiet > /dev/null   # manifest ゼロ → assets: []
printf '%s\nexport default {};\n' "$(plugin_marker personal-victim opencode "$pbid")" \
  > "$tmp/pleopen/plugins/personal-victim.js"
"$sync" --root "$tmp/plerepo" --codex-home "$tmp/plecodex" --claude-home "$tmp/pleclaude" \
  --opencode-home "$tmp/pleopen" --prune --apply > "$tmp/out38" 2>&1 \
  || fail "plugin prune with empty catalog should succeed: $(cat "$tmp/out38")"
! grep -q "delete:" "$tmp/out38" || fail "empty catalog must not plan plugin deletes: $(cat "$tmp/out38")"
[ -f "$tmp/pleopen/plugins/personal-victim.js" ] || fail "managed plugin must survive prune with an empty catalog"

# --- case: home の path に glob の特殊文字があっても orphan を列挙する (#427 の 1) ---
# home の skills/ を pattern に連結すると `[me]` と `{x}` が glob として読まれ、orphan が見えないまま prune が空振りする。
whome="$tmp/ho[me] {x}"
mkdir -p "$tmp/wrepo/shared/skills/personal-wkeep" "$tmp/wrepo/shared/skills/personal-wgone" \
  "$whome/codex" "$whome/claude"
for n in wkeep wgone; do
  cat > "$tmp/wrepo/shared/skills/personal-$n/SKILL.md" <<EOF
---
name: personal-$n
description: demo skill $n
---
body $n
EOF
  write_asset_manifest "$tmp/wrepo/shared/skills/personal-$n/asset.yml" \
    "personal-$n" skill public "shared/skills/personal-$n" directory claude-code
done
runw() { "$sync" --root "$tmp/wrepo" --codex-home "$whome/codex" --claude-home "$whome/claude" --opencode-home "$whome/opencode" "$@"; }
"$build" --root "$tmp/wrepo" --quiet > /dev/null
"$register" --root "$tmp/wrepo" --quiet > /dev/null
runw --apply --quiet > /dev/null
[ -f "$whome/claude/skills/personal-wgone/SKILL.md" ] || fail "glob-special home fixture should deploy personal-wgone"
rm -rf "$tmp/wrepo/shared/skills/personal-wgone"
"$build" --root "$tmp/wrepo" --prune --quiet > /dev/null
"$register" --root "$tmp/wrepo" --quiet > /dev/null
runw --prune > "$tmp/outw-dry" 2>&1 || fail "prune dry-run with a glob-special home should succeed: $(cat "$tmp/outw-dry")"
grep -q "delete: \[claude-code\].*personal-wgone (not in catalog)" "$tmp/outw-dry" \
  || fail "orphan under a glob-special home must be listed: $(cat "$tmp/outw-dry")"
runw --prune --apply > "$tmp/outw-apply" 2>&1 || fail "prune apply with a glob-special home should succeed: $(cat "$tmp/outw-apply")"
[ ! -e "$whome/claude/skills/personal-wgone" ] || fail "orphan under a glob-special home should be deleted"
[ -f "$whome/claude/skills/personal-wkeep/SKILL.md" ] || fail "prune under a glob-special home must keep the catalog-backed skill"

# --- case 39: update の途中で generated の copy が失敗しても、配置先は旧版のまま残り、一時 dir も残らない (#431 の 3) ---
# fixture: directory skill を v1 で配置し、v2 を build + register してから generated の SKILL.md を読めなくする。
# 旧実装は rm_rf(target) → cp_r なので、copy が途中で落ちると配置先が marker だけ (または空) になり、次の sync は
# それを up-to-date と見る。root は mode によらず読めるので再現できない (黙って通さず、理由を出して fail)。
[ "$(id -u)" -ne 0 ] || fail "case 39 needs a non-root user: root reads a mode-000 file, so the copy failure cannot be reproduced"
mkdir -p "$tmp/arepo/shared/skills/personal-atomic" "$tmp/arepo/shared/scripts" "$tmp/acodex" "$tmp/aclaude"
write_atomic_skill() {
  cat > "$tmp/arepo/shared/skills/personal-atomic/SKILL.md" <<EOS
---
name: personal-atomic
description: demo skill atomic
---
$1
EOS
}
write_atomic_skill v1
write_asset_manifest "$tmp/arepo/shared/skills/personal-atomic/asset.yml" \
  personal-atomic skill public shared/skills/personal-atomic directory claude-code
run39() { "$sync" --root "$tmp/arepo" --codex-home "$tmp/acodex" --claude-home "$tmp/aclaude" --opencode-home "$tmp/aopencode" "$@"; }
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
run39 --apply --quiet > /dev/null
atarget="$tmp/aclaude/skills/personal-atomic"
agen="$tmp/arepo/generated/claude-code/skills/personal-atomic"
grep -q "^v1$" "$atarget/SKILL.md" || fail "case 39 fixture should deploy v1"
tree_snapshot "$atarget" > "$tmp/out39-before"
write_atomic_skill v2
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
chmod 0000 "$agen/SKILL.md"
status=0
run39 --apply > "$tmp/out39" 2>&1 || status=$?
chmod 0644 "$agen/SKILL.md"
[ "$status" -eq 1 ] || fail "copy failure during update should exit 1, got $status: $(cat "$tmp/out39")"
tree_snapshot "$atarget" > "$tmp/out39-after"
cmp -s "$tmp/out39-before" "$tmp/out39-after" \
  || fail "target must keep the old version when the copy fails: $(diff "$tmp/out39-before" "$tmp/out39-after" || true)"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "no staging dir may remain next to the target after a failed copy: $(ls -A "$tmp/aclaude/skills")"
run39 > "$tmp/out39-next" 2>&1 || fail "sync after a failed update should succeed: $(cat "$tmp/out39-next")"
grep -q "update: \[claude-code\].*personal-atomic" "$tmp/out39-next" \
  || fail "the next sync must still plan the update, not up-to-date: $(cat "$tmp/out39-next")"

# --- case 40: 退避した旧 dir を消し残したら、新版は配置済みのまま理由を出して止まり、旧の写しが残る (#431 の 3, #469 review) ---
# fixture: 配置済み (v1) の skill の中に書き込み不可の subdir (中に file) を置く。rm_rf はその file を消せず、例外も
# 出さない。旧実装は残った dir の中へ cp_r が入れ子に copy し、apply は成功と出していた。今は旧 dir を
# .agent-tools-old-<name> に退避してから新版を rename で置くので、消し残しは退避先に残り、配置先は新版で揃う。
# v2 は case 39 で build + register 済み (update のまま)。root は mode によらず消せるので、case 39 と同じく非 root が前提。
aold="$tmp/aclaude/skills/.agent-tools-old-personal-atomic"
mkdir -p "$atarget/stuck"
echo "keep" > "$atarget/stuck/keep"
chmod 0555 "$atarget/stuck"
status=0
run39 --apply > "$tmp/out40" 2>&1 || status=$?
if [ -d "$aold/stuck" ]; then chmod 0755 "$aold/stuck"; fi
if [ -d "$atarget/stuck" ]; then chmod 0755 "$atarget/stuck"; fi
[ "$status" -eq 1 ] || fail "unremovable old copy should exit 1, got $status: $(cat "$tmp/out40")"
grep -q "fail: could not remove the copy of the old version .*/\.agent-tools-old-personal-atomic" "$tmp/out40" \
  || fail "the stop must name the leftover old copy: $(cat "$tmp/out40")"
grep -q "^v2$" "$atarget/SKILL.md" || fail "the new version must be in place after the stop"
cmp -s "$agen/.agent-tools-managed.yml" "$atarget/.agent-tools-managed.yml" || fail "the new marker must be in place after the stop"
[ -f "$aold/stuck/keep" ] || fail "the old copy must remain at the old path: $(ls -A "$tmp/aclaude/skills")"
[ "$(ls -A "$tmp/aclaude/skills" | tr '\n' ' ')" = ".agent-tools-old-personal-atomic personal-atomic " ] \
  || fail "skills/ must hold only the target and the old copy (no staging dir): $(ls -A "$tmp/aclaude/skills")"
run39 > "$tmp/out40-next" 2>&1 || fail "sync after the stop should succeed: $(cat "$tmp/out40-next")"
grep -q "skip: \[claude-code\].*personal-atomic (up-to-date)" "$tmp/out40-next" \
  || fail "the next sync must see the new version as up-to-date: $(cat "$tmp/out40-next")"
rm -rf "$aold"

# --- case 41: 正常の create / update の後に一時 dir / 一時 file が残らず、marker と本体が揃う (#431 の 3) ---
# skill は create (case 40 の残骸を消してから) と update、script は create と update を見る。
rm -rf "$atarget"
printf '#!/bin/sh\necho atool v1\n' > "$tmp/arepo/shared/scripts/personal-atool.sh"
write_atool_manifest() {
  write_approved_script_manifest "$tmp/arepo" shared/scripts/personal-atool.sh personal-atool personal claude-code
}
write_atool_manifest
ascripts="$tmp/aclaude/agent-tools/scripts"
# 使い方: expect_clean_deploy <label> <SKILL.md の本文の行> <script の本文の行>
expect_clean_deploy() {
  "$build" --root "$tmp/arepo" --quiet > /dev/null
  "$register" --root "$tmp/arepo" --quiet > /dev/null
  run39 --apply > "$tmp/out41" 2>&1 || fail "$1 should succeed: $(cat "$tmp/out41")"
  grep -q "^$2$" "$atarget/SKILL.md" || fail "$1: skill body not deployed"
  cmp -s "$agen/.agent-tools-managed.yml" "$atarget/.agent-tools-managed.yml" || fail "$1: skill marker must match generated"
  [ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
    || fail "$1: skills/ must hold only the target (no staging dir): $(ls -A "$tmp/aclaude/skills")"
  [ -x "$ascripts/personal-atool" ] || fail "$1: script body missing or not executable"
  grep -q "$3" "$ascripts/personal-atool" || fail "$1: script body not deployed"
  cmp -s "$tmp/arepo/generated/claude-code/scripts/personal-atool.agent-tools-managed.yml" \
    "$ascripts/personal-atool.agent-tools-managed.yml" || fail "$1: script sidecar marker must match generated"
  [ "$(ls -A "$ascripts" | tr '\n' ' ')" = "personal-atool personal-atool.agent-tools-managed.yml " ] \
    || fail "$1: scripts/ must hold only the body and the sidecar (no staging file): $(ls -A "$ascripts")"
}
expect_clean_deploy "create" v2 "echo atool v1"
write_atomic_skill v3
printf '#!/bin/sh\necho atool v2\n' > "$tmp/arepo/shared/scripts/personal-atool.sh"
write_atool_manifest
expect_clean_deploy "update" v3 "echo atool v2"

# 使い方: mode_of <file>  (permission bits を 8 進で出す。mode を 000 にして戻す case が使う)
mode_of() { ruby -e 'printf("%o", File.stat(ARGV[0]).mode & 0o777)' "$1"; }

# --- case 42: script の本体の copy が失敗したら、旧本体と旧 sidecar はそのまま残り、一時 file も残らない (#469 review) ---
# fixture: case 41 の配置 (v2) に対して v3 を build + register し、generated の本体を読めなくする。
printf '#!/bin/sh\necho atool v3\n' > "$tmp/arepo/shared/scripts/personal-atool.sh"
write_atool_manifest
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
agen_script="$tmp/arepo/generated/claude-code/scripts/personal-atool"
agen_sidecar="$agen_script.agent-tools-managed.yml"
tree_snapshot "$ascripts" > "$tmp/out42-before"
body_mode=$(mode_of "$agen_script")
chmod 0000 "$agen_script"
status=0
run39 --apply > "$tmp/out42" 2>&1 || status=$?
chmod "$body_mode" "$agen_script"
[ "$status" -eq 1 ] || fail "script body copy failure should exit 1, got $status: $(cat "$tmp/out42")"
tree_snapshot "$ascripts" > "$tmp/out42-after"
cmp -s "$tmp/out42-before" "$tmp/out42-after" \
  || fail "old body and old sidecar must stay and no staging file may remain: $(diff "$tmp/out42-before" "$tmp/out42-after" || true)"

# --- case 43: sidecar の配置が失敗したら、本体は新・sidecar は旧のまま止まり、取り除いて再実行すると update で収束する (#469 review) ---
# generated の sidecar を読めなくしても plan が先に読んで止まる (apply に届かない) ので、sidecar の一時 file の path に
# directory を置いて、本体の配置の後・sidecar の配置の前で止める (本体 → sidecar の順の途中の状態)。
cp "$ascripts/personal-atool.agent-tools-managed.yml" "$tmp/out43-old-sidecar"
sidecar_staging="$ascripts/.agent-tools-staging-personal-atool.agent-tools-managed.yml"
mkdir "$sidecar_staging"
status=0
run39 --apply > "$tmp/out43" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "sidecar placement failure should exit 1, got $status: $(cat "$tmp/out43")"
grep -q "fail: could not remove the leftover staging file .*/\.agent-tools-staging-personal-atool\.agent-tools-managed\.yml" "$tmp/out43" \
  || fail "the stop must name the sidecar staging file: $(cat "$tmp/out43")"
grep -q "echo atool v3" "$ascripts/personal-atool" || fail "body must already be the new version when the sidecar placement fails"
cmp -s "$tmp/out43-old-sidecar" "$ascripts/personal-atool.agent-tools-managed.yml" \
  || fail "sidecar must stay the old version when its placement fails"
[ "$(ls -A "$ascripts" | tr '\n' ' ')" = ".agent-tools-staging-personal-atool.agent-tools-managed.yml personal-atool personal-atool.agent-tools-managed.yml " ] \
  || fail "scripts/ must hold only the body, the sidecar and the directory that blocked the sidecar: $(ls -A "$ascripts")"
rmdir "$sidecar_staging"
run39 > "$tmp/out43-next" 2>&1 || fail "sync after the sidecar failure should succeed: $(cat "$tmp/out43-next")"
grep -q "update: \[claude-code\].*personal-atool" "$tmp/out43-next" \
  || fail "the old sidecar must make the next sync plan an update: $(cat "$tmp/out43-next")"
run39 --apply > "$tmp/out43-apply" 2>&1 || fail "re-run should converge: $(cat "$tmp/out43-apply")"
cmp -s "$agen_sidecar" "$ascripts/personal-atool.agent-tools-managed.yml" || fail "re-run must bring the sidecar to the new version"
[ "$(ls -A "$ascripts" | tr '\n' ' ')" = "personal-atool personal-atool.agent-tools-managed.yml " ] \
  || fail "no staging file may remain after convergence: $(ls -A "$ascripts")"

# --- case 44: 一時 dir / 一時 file の path に消せないものがあれば、何も書かずに止まる (#469 review) ---
# 44a: skill。一時 dir の path に消せない dir (書き込み不可の subdir の中に file) を置く。前回の残りなら消して使うが、
# 消せなければ止める (残った dir の中へ入れ子に copy しない)。
write_atomic_skill v4
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
astaging="$tmp/aclaude/skills/.agent-tools-staging-personal-atomic"
mkdir -p "$astaging/stuck"
echo "keep" > "$astaging/stuck/keep"
chmod 0555 "$astaging/stuck"
tree_snapshot "$atarget" > "$tmp/out44a-before"
status=0
run39 --apply > "$tmp/out44a" 2>&1 || status=$?
chmod 0755 "$astaging/stuck"
[ "$status" -eq 1 ] || fail "unremovable staging dir should exit 1, got $status: $(cat "$tmp/out44a")"
grep -q "fail: could not remove the leftover staging dir .*/\.agent-tools-staging-personal-atomic" "$tmp/out44a" \
  || fail "the stop must name the staging dir: $(cat "$tmp/out44a")"
tree_snapshot "$atarget" > "$tmp/out44a-after"
cmp -s "$tmp/out44a-before" "$tmp/out44a-after" || fail "target must not change when the staging dir cannot be removed"
[ ! -e "$astaging/personal-atomic" ] || fail "generated must not be copied into the leftover staging dir"
rm -rf "$astaging"
run39 --apply --quiet > /dev/null
grep -q "^v4$" "$atarget/SKILL.md" || fail "skill should converge after the staging dir is removed"
# 44b: script。一時 file の path に directory を置く (create の状態)。rm_f は directory を消せず、cp はその中へ入れ子に
# copy し、create なら続く rename が配置先に directory を置いて成功と出てしまう。
rm -f "$ascripts/personal-atool" "$ascripts/personal-atool.agent-tools-managed.yml"
mkdir "$ascripts/.agent-tools-staging-personal-atool"
status=0
run39 --apply > "$tmp/out44b" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "directory at the staging file path should exit 1, got $status: $(cat "$tmp/out44b")"
grep -q "fail: could not remove the leftover staging file .*/\.agent-tools-staging-personal-atool" "$tmp/out44b" \
  || fail "the stop must name the staging file: $(cat "$tmp/out44b")"
[ ! -e "$ascripts/personal-atool" ] || fail "nothing may be placed at the script path when the staging path is taken"
[ ! -e "$ascripts/personal-atool.agent-tools-managed.yml" ] || fail "no sidecar may be written when the body was not placed"
[ -z "$(ls -A "$ascripts/.agent-tools-staging-personal-atool")" ] || fail "generated must not be copied into the directory at the staging path"
rmdir "$ascripts/.agent-tools-staging-personal-atool"
run39 --apply --quiet > /dev/null
[ -x "$ascripts/personal-atool" ] || fail "script should converge after the directory is removed"

# --- case 45: 退避の後・配置の前で止まった状態 (配置先が無く退避した旧 dir だけ) からの再実行は、旧版を消さずに戻す (#469 review 2) ---
# fixture: v4 を配置した状態から mv で中断状態を作り、v5 を build + register する。(a) copy が失敗する apply (generated の
# SKILL.md を mode 000。case 39 と同じ) でも配置先に v4 が戻り、old も staging も残らない。(b) 障害を取り除くと v5 が配置される。
# 旧実装は old を「前回の残り」として消してから copy したので、そこで copy が失敗すると唯一の旧版も失われた。
mv "$atarget" "$aold"
write_atomic_skill v5
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
chmod 0000 "$agen/SKILL.md"
status=0
run39 --apply > "$tmp/out45a" 2>&1 || status=$?
chmod 0644 "$agen/SKILL.md"
[ "$status" -eq 1 ] || fail "copy failure after an interrupted switch should exit 1, got $status: $(cat "$tmp/out45a")"
grep -q "^v4$" "$atarget/SKILL.md" || fail "the old version must be put back at the target before the copy is attempted"
[ ! -e "$aold" ] || fail "the old copy must not remain after it was put back"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "skills/ must hold only the target after the recovery: $(ls -A "$tmp/aclaude/skills")"
run39 --apply > "$tmp/out45b" 2>&1 || fail "apply after the obstacle is removed should succeed: $(cat "$tmp/out45b")"
grep -q "^v5$" "$atarget/SKILL.md" || fail "the new version should be deployed once the copy succeeds"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "skills/ must hold only the target after convergence: $(ls -A "$tmp/aclaude/skills")"

# --- case 46: 配置の rename だけが失敗したら、退避した旧版を戻して止まり、staging も old も残らない (#469 review 2) ---
# sync.sh は `exec ruby lib/sync.rb` で起動するので、RUBYOPT=-r<file> でその ruby だけに test 専用の patch を読ませる
# (実装に test 用の hook は入れない)。patch は INJECT_RENAME_AT で選んだ File.rename (placement = source が staging で
# destination が配置先 / evacuation = source が配置先で destination が .agent-tools-old-) だけを INJECT_RENAME_ERROR の
# 例外にする (INJECT_RENAME_AFTER=1 なら実処理を行ってから raise。復旧の rename はどちらにも当たらない)。RUBYOPT は空白で分割されるので、
# path に空白があれば理由を出して fail。patch が効いた根拠は fail: の行の例外 class (Errno::EIO)。RUBYOPT を付けない対照
# (46c) が同じ fixture で v6 に更新されることで、注入が他の起動に漏れていないことも見る。
case $tmp in *[[:space:]]*) fail "case 46 needs a tmp path without whitespace for RUBYOPT: $tmp" ;; esac
inject="$tmp/inject-rename.rb"
cat > "$inject" <<'RB'
class << File
  alias_method :rename_without_injection, :rename
  def rename(from, to)
    at = ENV.fetch("INJECT_RENAME_AT")
    hit = (at == "placement" && File.basename(from).start_with?(".agent-tools-staging-") && File.basename(to) == "personal-atomic") ||
          (at == "evacuation" && File.basename(from) == "personal-atomic" && File.basename(to).start_with?(".agent-tools-old-"))
    return rename_without_injection(from, to) unless hit

    rename_without_injection(from, to) if ENV.fetch("INJECT_RENAME_AFTER") == "1"
    raise Object.const_get(ENV.fetch("INJECT_RENAME_ERROR")), "injected"
  end
end
RB
# 使い方: run46 <例外 class> <placement|evacuation> <実処理を行ってから raise するなら 1、しないなら 0>
run46() {
  RUBYOPT="-r$inject" INJECT_RENAME_ERROR=$1 INJECT_RENAME_AT=$2 INJECT_RENAME_AFTER=$3 "$sync" --root "$tmp/arepo" --codex-home "$tmp/acodex" \
    --claude-home "$tmp/aclaude" --opencode-home "$tmp/aopencode" --apply
}
write_atomic_skill v6
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
tree_snapshot "$atarget" > "$tmp/out46-before"
# 46a: 例外 (Errno::EIO) は ApplyError に変えて fail: で止める。旧版は戻る
status=0
run46 Errno::EIO placement 0 > "$tmp/out46a" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "placement rename failure should exit 1, got $status: $(cat "$tmp/out46a")"
grep -q "fail: could not put the new version at .*personal-atomic (Errno::EIO); the old version was put back" "$tmp/out46a" \
  || fail "the stop must say the old version was put back: $(cat "$tmp/out46a")"
tree_snapshot "$atarget" > "$tmp/out46a-after"
cmp -s "$tmp/out46-before" "$tmp/out46a-after" \
  || fail "the old version must be back at the target after the placement fails: $(diff "$tmp/out46-before" "$tmp/out46a-after" || true)"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "neither staging nor old may remain after the placement fails: $(ls -A "$tmp/aclaude/skills")"
# 46b: 割り込み (Interrupt。SystemCallError ではない) でも ensure が旧版を戻す。uncaught の Interrupt で ruby は
# SIGINT で終わる (実測 exit 130) ので、exit code は 0 でないことだけを見る
status=0
run46 Interrupt placement 0 > "$tmp/out46b" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "an interrupt during the placement must not exit 0: $(cat "$tmp/out46b")"
tree_snapshot "$atarget" > "$tmp/out46b-after"
cmp -s "$tmp/out46-before" "$tmp/out46b-after" \
  || fail "the old version must be back at the target after an interrupt: $(diff "$tmp/out46-before" "$tmp/out46b-after" || true)"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "neither staging nor old may remain after an interrupt: $(ls -A "$tmp/aclaude/skills")"
# 46c: 対照。注入が無ければ同じ fixture で v6 に更新される
run39 --apply > "$tmp/out46c" 2>&1 || fail "apply without the injection should succeed: $(cat "$tmp/out46c")"
grep -q "^v6$" "$atarget/SKILL.md" || fail "the new version should be deployed without the injection"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "skills/ must hold only the target after the control run: $(ls -A "$tmp/aclaude/skills")"

# --- case 47: 退避の rename を行った直後に割り込まれても、退避先と配置先の実在で判断して旧版を戻す (#469 review 3) ---
# 「退避した / 配置した」の flag で判断すると、退避の rename が済んでから flag が立つまでの隙間で割り込まれたときに
# 配置先が欠落したまま終わる。注入は退避の rename を実際に行ってから Interrupt を raise する。
write_atomic_skill v7
"$build" --root "$tmp/arepo" --quiet > /dev/null
"$register" --root "$tmp/arepo" --quiet > /dev/null
tree_snapshot "$atarget" > "$tmp/out47-before"
status=0
run46 Interrupt evacuation 1 > "$tmp/out47" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "an interrupt right after the evacuation must not exit 0: $(cat "$tmp/out47")"
tree_snapshot "$atarget" > "$tmp/out47-after"
cmp -s "$tmp/out47-before" "$tmp/out47-after" \
  || fail "the old version must be back at the target after an interrupt right after the evacuation: $(diff "$tmp/out47-before" "$tmp/out47-after" || true)"
[ "$(ls -A "$tmp/aclaude/skills")" = "personal-atomic" ] \
  || fail "neither staging nor old may remain after an interrupt right after the evacuation: $(ls -A "$tmp/aclaude/skills")"
# 対照: 注入が無ければ v7 に更新される
run39 --apply > "$tmp/out47c" 2>&1 || fail "apply without the injection should succeed: $(cat "$tmp/out47c")"
grep -q "^v7$" "$atarget/SKILL.md" || fail "the new version should be deployed without the injection"

echo "ok: sync self-test passed"
