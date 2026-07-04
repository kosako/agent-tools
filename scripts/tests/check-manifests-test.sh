#!/bin/sh
# check-manifests.sh の self-test。
# 一時 directory に fixture を生成して検証する。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check="$script_dir/../check-manifests.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --- case 1: valid single-file asset + valid directory asset ---
mkdir -p "$tmp/valid/shared/workflows" "$tmp/valid/shared/skills/personal-demo-skill"
cat > "$tmp/valid/shared/workflows/personal-demo.md" <<'EOF'
# demo
EOF
cat > "$tmp/valid/shared/workflows/personal-demo.asset.yml" <<'EOF'
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
review:
  human_review: pending
EOF
cat > "$tmp/valid/shared/skills/personal-demo-skill/SKILL.md" <<'EOF'
# demo skill
EOF
cat > "$tmp/valid/shared/skills/personal-demo-skill/asset.yml" <<'EOF'
schema_version: 1
name: personal-demo-skill
kind: skill
visibility: personal
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-demo-skill
  format: directory
EOF

"$check" --root "$tmp/valid" > "$tmp/out-valid" 2>&1 \
  || fail "valid fixture should pass: $(cat "$tmp/out-valid")"
grep -q "ok: 2 manifest(s) validated" "$tmp/out-valid" \
  || fail "valid fixture should report 2 manifests: $(cat "$tmp/out-valid")"

# --- case 2: broken manifest ---
mkdir -p "$tmp/broken/shared/prompts"
cat > "$tmp/broken/shared/prompts/personal-bad.md" <<'EOF'
# bad
EOF
cat > "$tmp/broken/shared/prompts/personal-bad.asset.yml" <<'EOF'
schema_version: 2
name: Bad_Name
kind: template
visibility: work
targets: []
risk:
  prompt_injection: low
source:
  path: docs/missing.md
  format: pdf
review:
  static_check: pending
extra_field: true
EOF

if "$check" --root "$tmp/broken" > "$tmp/out-broken" 2>&1; then
  fail "broken fixture should fail"
fi
for expected in \
  "schema_version must be 1" \
  "name must be lower kebab-case" \
  "kind must be one of" \
  "must not be tracked" \
  "targets must be a non-empty list" \
  "missing risk key: privacy" \
  "source.path must be under shared/" \
  "source.format must be one of" \
  "unknown review key: static_check" \
  "unknown field: extra_field"
do
  grep -q "$expected" "$tmp/out-broken" \
    || fail "missing error '$expected' in: $(cat "$tmp/out-broken")"
done

# --- case 3: source without manifest ---
mkdir -p "$tmp/orphan/shared/agents"
cat > "$tmp/orphan/shared/agents/personal-orphan.md" <<'EOF'
# orphan
EOF

if "$check" --root "$tmp/orphan" > "$tmp/out-orphan" 2>&1; then
  fail "orphan source should fail"
fi
grep -q "missing sidecar manifest personal-orphan.asset.yml" "$tmp/out-orphan" \
  || fail "missing orphan error in: $(cat "$tmp/out-orphan")"

# --- case 4: 重複 asset name は fail する ---
mkdir -p "$tmp/dup/shared/workflows" "$tmp/dup/shared/prompts"
for d in workflows prompts; do
  k=workflow; [ "$d" = prompts ] && k=prompt
  echo "# x" > "$tmp/dup/shared/$d/personal-x.md"
  cat > "$tmp/dup/shared/$d/personal-x.asset.yml" <<EOF
schema_version: 1
name: personal-x
kind: $k
visibility: public
targets:
  - codex
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/$d/personal-x.md
  format: markdown
EOF
done

if "$check" --root "$tmp/dup" > "$tmp/out-dup" 2>&1; then
  fail "duplicate names should fail"
fi
grep -q 'duplicate asset name "personal-x"' "$tmp/out-dup" \
  || fail "missing duplicate name error in: $(cat "$tmp/out-dup")"

# --- case 4b: 同一 target に instruction asset が複数あると fail ---
mkdir -p "$tmp/dupinstr/shared/instructions"
for n in ops rules; do
  echo "# $n" > "$tmp/dupinstr/shared/instructions/personal-$n.md"
  cat > "$tmp/dupinstr/shared/instructions/personal-$n.asset.yml" <<EOF
schema_version: 1
name: personal-$n
kind: instruction
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-$n.md
  format: markdown
EOF
done

if "$check" --root "$tmp/dupinstr" > "$tmp/out-dupinstr" 2>&1; then
  fail "duplicate instruction targets should fail"
fi
grep -q "multiple instruction assets target claude-code" "$tmp/out-dupinstr" \
  || fail "missing instruction uniqueness error in: $(cat "$tmp/out-dupinstr")"

# --- case 4c: directory format の instruction は fail ---
mkdir -p "$tmp/dirinstr/shared/instructions/personal-ops"
echo "# ops" > "$tmp/dirinstr/shared/instructions/personal-ops/CLAUDE.md"
cat > "$tmp/dirinstr/shared/instructions/personal-ops/asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-ops
  format: directory
EOF

if "$check" --root "$tmp/dirinstr" > "$tmp/out-dirinstr" 2>&1; then
  fail "directory instruction should fail"
fi
grep -q "instruction asset must be a single file" "$tmp/out-dirinstr" \
  || fail "missing directory instruction error in: $(cat "$tmp/out-dirinstr")"

# --- case 4d: YAML パース不能な manifest でもクラッシュせず error 報告 ---
mkdir -p "$tmp/yamlbad/shared/prompts"
echo "# x" > "$tmp/yamlbad/shared/prompts/personal-x.md"
printf 'name: [unclosed\n' > "$tmp/yamlbad/shared/prompts/personal-x.asset.yml"

if "$check" --root "$tmp/yamlbad" > "$tmp/out-yamlbad" 2>&1; then
  fail "unparseable manifest should fail"
fi
grep -q "YAML parse error" "$tmp/out-yamlbad" \
  || fail "missing YAML parse error (uniqueness check must not crash) in: $(cat "$tmp/out-yamlbad")"

# --- case 4e: valid YAML だが型不正 (risk が mapping でない) でもクラッシュしない ---
mkdir -p "$tmp/badtype/shared/instructions"
echo "# ops" > "$tmp/badtype/shared/instructions/personal-ops.md"
cat > "$tmp/badtype/shared/instructions/personal-ops.asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - codex
risk: low
source:
  path: shared/instructions/personal-ops.md
  format: markdown
EOF

if "$check" --root "$tmp/badtype" > "$tmp/out-badtype" 2>&1; then
  fail "malformed risk type should fail"
fi
grep -q "risk must be a mapping" "$tmp/out-badtype" \
  || fail "expected clean risk validation error (no crash) in: $(cat "$tmp/out-badtype")"

# --- case 4b: directory skill の scripts/ は fail-closed (Phase 1 未対応) ---
mkdir -p "$tmp/scriptskill/shared/skills/personal-script-skill/scripts"
cat > "$tmp/scriptskill/shared/skills/personal-script-skill/SKILL.md" <<'EOF'
---
name: personal-script-skill
description: skill with scripts
---

# script skill
EOF
echo 'print("hi")' > "$tmp/scriptskill/shared/skills/personal-script-skill/scripts/run.py"
cat > "$tmp/scriptskill/shared/skills/personal-script-skill/asset.yml" <<'EOF'
schema_version: 1
name: personal-script-skill
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-script-skill
  format: directory
EOF

if "$check" --root "$tmp/scriptskill" > "$tmp/out-scriptskill" 2>&1; then
  fail "check-manifests must reject a directory skill containing scripts/"
fi
grep -q "must not contain scripts/" "$tmp/out-scriptskill" \
  || fail "expected scripts/ fail-closed reason: $(cat "$tmp/out-scriptskill")"

# evals/ だけなら通る (非配置だが許可される)。
mkdir -p "$tmp/evalskill/shared/skills/personal-eval-skill/evals"
cat > "$tmp/evalskill/shared/skills/personal-eval-skill/SKILL.md" <<'EOF'
---
name: personal-eval-skill
description: skill with evals
---

# eval skill
EOF
echo '{"evals":[]}' > "$tmp/evalskill/shared/skills/personal-eval-skill/evals/evals.json"
cat > "$tmp/evalskill/shared/skills/personal-eval-skill/asset.yml" <<'EOF'
schema_version: 1
name: personal-eval-skill
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-eval-skill
  format: directory
EOF

"$check" --root "$tmp/evalskill" > "$tmp/out-evalskill" 2>&1 \
  || fail "directory skill with only evals/ should pass: $(cat "$tmp/out-evalskill")"

# --- case 4f: directory asset 内の symlink は fail-closed (shared/ 脱出防止) ---
mkdir -p "$tmp/symskill/shared/skills/personal-sym-skill"
cat > "$tmp/symskill/shared/skills/personal-sym-skill/SKILL.md" <<'EOF'
---
name: personal-sym-skill
description: skill with a symlink
---

# sym skill
EOF
# asset dir 内に shared/ 外を指す symlink を仕込む (cp_r / build_id が辿りうる)
ln -s /etc/hosts "$tmp/symskill/shared/skills/personal-sym-skill/leak"
cat > "$tmp/symskill/shared/skills/personal-sym-skill/asset.yml" <<'EOF'
schema_version: 1
name: personal-sym-skill
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-sym-skill
  format: directory
EOF

if "$check" --root "$tmp/symskill" > "$tmp/out-symskill" 2>&1; then
  fail "directory asset with a symlink should fail"
fi
grep -q "must not contain symlinks" "$tmp/out-symskill" \
  || fail "expected symlink fail-closed reason: $(cat "$tmp/out-symskill")"

# --- case 4g: directory asset 内の特殊ファイル (FIFO) も fail-closed ---
mkdir -p "$tmp/fifoskill/shared/skills/personal-fifo-skill"
cat > "$tmp/fifoskill/shared/skills/personal-fifo-skill/SKILL.md" <<'EOF'
---
name: personal-fifo-skill
description: skill with a special file
---

# fifo skill
EOF
mkfifo "$tmp/fifoskill/shared/skills/personal-fifo-skill/pipe"
cat > "$tmp/fifoskill/shared/skills/personal-fifo-skill/asset.yml" <<'EOF'
schema_version: 1
name: personal-fifo-skill
kind: skill
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/skills/personal-fifo-skill
  format: directory
EOF

if "$check" --root "$tmp/fifoskill" > "$tmp/out-fifoskill" 2>&1; then
  fail "directory asset with a special file should fail"
fi
grep -q "must not contain special files" "$tmp/out-fifoskill" \
  || fail "expected special-file fail-closed reason: $(cat "$tmp/out-fifoskill")"

# --- case: script kind の単一ファイル asset が validate する (P3-03b) ---
mkdir -p "$tmp/scriptkind/shared/scripts"
printf '#!/bin/sh\necho hi\n' > "$tmp/scriptkind/shared/scripts/personal-demo-script.sh"
cat > "$tmp/scriptkind/shared/scripts/personal-demo-script.asset.yml" <<'EOF'
schema_version: 1
name: personal-demo-script
kind: script
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/scripts/personal-demo-script.sh
  format: text
EOF
"$check" --root "$tmp/scriptkind" > "$tmp/out-scriptkind" 2>&1 \
  || fail "script kind manifest should validate: $(cat "$tmp/out-scriptkind")"

# --- case: single-file source が symlink なら reject (shared/ の外を byte 保持で配らない) ---
mkdir -p "$tmp/symsrc/shared/scripts"
printf '#!/bin/sh\necho real\n' > "$tmp/symsrc/outside.sh"
ln -s "$tmp/symsrc/outside.sh" "$tmp/symsrc/shared/scripts/personal-sym-script.sh"
cat > "$tmp/symsrc/shared/scripts/personal-sym-script.asset.yml" <<'EOF'
schema_version: 1
name: personal-sym-script
kind: script
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/scripts/personal-sym-script.sh
  format: text
EOF
if "$check" --root "$tmp/symsrc" > "$tmp/out-symsrc" 2>&1; then
  fail "check-manifests must reject a symlinked single-file source"
fi
grep -q "must not be a symlink" "$tmp/out-symsrc" \
  || fail "expected single-file symlink rejection reason: $(cat "$tmp/out-symsrc")"

# --- case: approved_build_id の検証 (#148)。形式不正と approved なし併用を reject ---
mkdir -p "$tmp/abid/shared/workflows"
echo "# demo" > "$tmp/abid/shared/workflows/personal-abid.md"
cat > "$tmp/abid/shared/workflows/personal-abid.asset.yml" <<'EOF'
schema_version: 1
name: personal-abid
kind: workflow
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
review:
  human_review: pending
  approved_build_id: not-a-build-id
source:
  path: shared/workflows/personal-abid.md
  format: markdown
EOF
if "$check" --root "$tmp/abid" > "$tmp/out-abid" 2>&1; then
  fail "check-manifests must reject malformed approved_build_id"
fi
grep -q "approved_build_id must be a build_id" "$tmp/out-abid" \
  || fail "expected approved_build_id format error: $(cat "$tmp/out-abid")"
grep -q "approved_build_id requires review.human_review: approved" "$tmp/out-abid" \
  || fail "expected approved-pairing error: $(cat "$tmp/out-abid")"

# --- case: compatibility フィールドの検証 (#149)。typo / 不明 tool / 型不正を reject ---
mkdir -p "$tmp/compat/shared/workflows"
echo "# demo" > "$tmp/compat/shared/workflows/personal-compat.md"
cat > "$tmp/compat/shared/workflows/personal-compat.asset.yml" <<'EOF'
schema_version: 1
name: personal-compat
kind: workflow
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
compatibility:
  claude-code:
    artifact_kind: skil
  bogus-tool:
    artifact_kind: skill
source:
  path: shared/workflows/personal-compat.md
  format: markdown
EOF
if "$check" --root "$tmp/compat" > "$tmp/out-compat" 2>&1; then
  fail "check-manifests must reject invalid compatibility"
fi
grep -q "artifact_kind must be one of" "$tmp/out-compat" \
  || fail "expected artifact_kind typo error: $(cat "$tmp/out-compat")"
grep -q "compatibility has unknown tool: bogus-tool" "$tmp/out-compat" \
  || fail "expected unknown-tool error: $(cat "$tmp/out-compat")"

# --- case: source.path の path traversal を拒否する (shared/ 脱出防止の要, #150) ---
# 絶対 path
mkdir -p "$tmp/abs/shared/workflows"
echo "# x" > "$tmp/abs/shared/workflows/personal-abs.md"
cat > "$tmp/abs/shared/workflows/personal-abs.asset.yml" <<'EOF'
schema_version: 1
name: personal-abs
kind: workflow
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: /etc/passwd
  format: markdown
EOF
if "$check" --root "$tmp/abs" > "$tmp/out-abs" 2>&1; then
  fail "check-manifests must reject an absolute source.path"
fi
grep -q "source.path must be relative" "$tmp/out-abs" \
  || fail "expected absolute-path rejection: $(cat "$tmp/out-abs")"

# .. を含む相対 path
mkdir -p "$tmp/dotdot/shared/workflows"
echo "# x" > "$tmp/dotdot/shared/workflows/personal-dd.md"
cat > "$tmp/dotdot/shared/workflows/personal-dd.asset.yml" <<'EOF'
schema_version: 1
name: personal-dd
kind: workflow
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/../../etc/secret
  format: markdown
EOF
if "$check" --root "$tmp/dotdot" > "$tmp/out-dd" 2>&1; then
  fail "check-manifests must reject a '..' source.path"
fi
grep -q "source.path must not contain '..'" "$tmp/out-dd" \
  || fail "expected dotdot rejection: $(cat "$tmp/out-dd")"

# shared/ 外
mkdir -p "$tmp/outside/shared/workflows"
echo "# x" > "$tmp/outside/shared/workflows/personal-out.md"
cat > "$tmp/outside/shared/workflows/personal-out.asset.yml" <<'EOF'
schema_version: 1
name: personal-out
kind: workflow
visibility: public
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: docs/secret.md
  format: markdown
EOF
if "$check" --root "$tmp/outside" > "$tmp/out-outside" 2>&1; then
  fail "check-manifests must reject a source.path outside shared/"
fi
grep -q "source.path must be under shared/" "$tmp/out-outside" \
  || fail "expected outside-shared rejection: $(cat "$tmp/out-outside")"

# --- case 5: repository 本体の manifest が pass する ---
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
"$check" --root "$repo_root" --quiet > "$tmp/out-repo" 2>&1 \
  || fail "repository manifests should pass: $(cat "$tmp/out-repo")"

echo "ok: check-manifests self-test passed"
