#!/bin/sh
# setup.sh の self-test。
# fake home でだけ検証し、実 tool homes には決して触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
setup="$script_dir/../setup.sh"

tmpbase=$(mktemp -d)
trap 'rm -rf "$tmpbase"' EXIT


# root / home に空白を含めて、引数 forwarding の quoting を検証する
# ("Application Support" のような空白入り path での破綻を捕まえる)。
tmp="$tmpbase/with space"
mkdir -p "$tmp"

# fixture: single-file skill asset (build → register → connect(noop) → sync を通せる) と、
# opencode に配る approved plugin (sync だけが --opencode-home を受け、connect には渡らない, #295)
mkdir -p "$tmp/shared/skills" "$tmp/shared/plugins" "$tmp/codex" "$tmp/claude" "$tmp/opencode"
cat > "$tmp/shared/skills/personal-demo-skill.md" <<'EOF'
---
name: personal-demo-skill
description: demo personal-demo-skill
---

# demo skill

body for the demo skill.
EOF
WAM_EXTRA='summary: demo skill for setup-test'
write_asset_manifest "$tmp/shared/skills/personal-demo-skill.asset.yml" \
  personal-demo-skill skill public shared/skills/personal-demo-skill.md markdown \
  codex claude-code
printf 'export default { id: "personal-demo-plugin", server: async () => ({}) };\n' \
  > "$tmp/shared/plugins/personal-demo-plugin.js"
write_approved_plugin_manifest "$tmp" personal-demo-plugin personal

# 引数は quote して渡す (root/home に空白を含むため)。setup.sh 側の forwarding の
# quoting が壊れていれば、空白入り path の sub-script 呼び出しで失敗する。
# --- case 1: dry-run は全段を通すが実 home には書き込まない ---
out=$("$setup" --root "$tmp" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" 2>&1) \
  || fail "dry-run exited non-zero: $out"
echo "$out" | grep -q "==> build" || fail "dry-run: build step missing"
echo "$out" | grep -q "==> register" || fail "dry-run: register step missing"
echo "$out" | grep -q "==> connect" || fail "dry-run: connect step missing"
echo "$out" | grep -q "==> sync" || fail "dry-run: sync step missing"
[ -d "$tmp/codex/skills/personal-demo-skill" ] && fail "dry-run wrote to codex home"
[ -d "$tmp/claude/skills/personal-demo-skill" ] && fail "dry-run wrote to claude home"
[ -e "$tmp/opencode/plugins" ] && fail "dry-run wrote to opencode home"
echo "$out" | grep -q "dry-run のみ" || fail "dry-run: hint missing"

# --- case 2: --apply は skill を実 home (fake) に配置する ---
out=$("$setup" --apply --root "$tmp" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" 2>&1) \
  || fail "apply exited non-zero: $out"
[ -f "$tmp/codex/skills/personal-demo-skill/SKILL.md" ] || fail "apply did not place codex skill"
[ -f "$tmp/claude/skills/personal-demo-skill/SKILL.md" ] || fail "apply did not place claude skill"
[ -f "$tmp/opencode/plugins/personal-demo-plugin.js" ] || fail "apply did not place the plugin in the opencode home"
[ ! -e "$tmp/codex/plugins" ] && [ ! -e "$tmp/claude/plugins" ] || fail "plugin must land only in the opencode home"
# --apply では dry-run hint を出さない (setup.sh:76 の gate 反転を検出する negative coverage)
echo "$out" | grep -q "dry-run のみ" && fail "--apply must not print the dry-run hint: $out" || true

# --- case 3: 未知オプションは usage を出して exit 2 ---
rc=0
"$setup" --bogus >/dev/null 2>&1 || rc=$? # no-opencode-home: usage で止まる parse-only の case
[ "$rc" -eq 2 ] || fail "unknown option should exit 2, got $rc"

# --- case 4: register が exit 3 (human review 待ち) を返しても止まらず、登録できる asset だけを配置する (#517) ---
# 登録できる skill (case 1 と同じ) と、宣言 risk が medium で未承認の skill (register は human_review_required) を混ぜる。
proot="$tmp/pending-root"
mkdir -p "$proot/shared/skills" "$tmp/p-codex" "$tmp/p-claude" "$tmp/p-opencode"
cp "$tmp/shared/skills/personal-demo-skill.md" "$tmp/shared/skills/personal-demo-skill.asset.yml" "$proot/shared/skills/"
cat > "$proot/shared/skills/personal-pending-skill.md" <<'EOF'
---
name: personal-pending-skill
description: demo personal-pending-skill
---
# pending skill
body for the pending skill.
EOF
WAM_EXTRA='summary: pending skill for setup-test'
write_asset_manifest "$proot/shared/skills/personal-pending-skill.asset.yml" \
  personal-pending-skill skill public shared/skills/personal-pending-skill.md markdown \
  codex claude-code
sed 's/prompt_injection: low/prompt_injection: medium/' "$proot/shared/skills/personal-pending-skill.asset.yml" \
  > "$tmp/pending.asset.yml"
mv "$tmp/pending.asset.yml" "$proot/shared/skills/personal-pending-skill.asset.yml"
out=$("$setup" --apply --root "$proot" --codex-home "$tmp/p-codex" --claude-home "$tmp/p-claude" \
  --opencode-home "$tmp/p-opencode" 2>&1) || fail "setup should continue past a pending registration: $out"
# 注記は register の exit 3 の分岐でだけ出る (exit 3 の経路を通ったことの確認)
echo "$out" | grep -q "note: human review 待ちの asset があります" || fail "setup should note the pending asset: $out"
echo "$out" | grep -q "==> sync" || fail "setup should reach sync after the pending registration: $out"
[ -f "$tmp/p-codex/skills/personal-demo-skill/SKILL.md" ] || fail "the registrable codex skill should be placed: $out"
[ -f "$tmp/p-claude/skills/personal-demo-skill/SKILL.md" ] || fail "the registrable claude skill should be placed: $out"
[ ! -e "$tmp/p-codex/skills/personal-pending-skill" ] || fail "the pending codex skill must not be placed"
[ ! -e "$tmp/p-claude/skills/personal-pending-skill" ] || fail "the pending claude skill must not be placed"

echo "ok: setup-test passed"
