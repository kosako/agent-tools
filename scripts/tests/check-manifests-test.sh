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
  static_check: pending
  llm_review: allowed
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
kind: tool
visibility: work
targets: []
risk:
  prompt_injection: low
source:
  path: docs/missing.md
  format: pdf
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

# --- case 5: repository 本体の manifest が pass する ---
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
"$check" --root "$repo_root" --quiet > "$tmp/out-repo" 2>&1 \
  || fail "repository manifests should pass: $(cat "$tmp/out-repo")"

echo "ok: check-manifests self-test passed"
