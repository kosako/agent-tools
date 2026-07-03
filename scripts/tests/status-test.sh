#!/bin/sh
# status.sh の self-test。
# 一時 directory に fixture と fake tool homes を生成して検証する。
# 実際の ~/.codex / ~/.claude には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$script_dir/../build.sh"
sync="$script_dir/../sync.sh"
status_sh="$script_dir/../status.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_status() {
  "$status_sh" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --json
}

# JSON から値を取り出す。
jget() {
  ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig(*ARGV[1..-1].map { |k| k =~ /\A\d+\z/ ? k.to_i : k }).inspect' "$@"
}

# --- fixture repo ---
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

# --- case 1: build 前。generated 0、sync_targets は空 ---
run_status > "$tmp/s1" 2>&1 || fail "status should succeed: $(cat "$tmp/s1")"
[ "$(jget "$tmp/s1" contract_version)" = "2" ] || fail "contract_version should be 2"
[ "$(jget "$tmp/s1" register catalog_present)" = "false" ] || fail "catalog_present should be false before register"
[ "$(jget "$tmp/s1" assets total)" = "1" ] || fail "assets.total should be 1"
[ "$(jget "$tmp/s1" checks manifest_validation)" = '"pass"' ] || fail "manifest check should pass"
[ "$(jget "$tmp/s1" checks prompt_injection_static)" = '"pass"' ] || fail "injection check should pass"
[ "$(jget "$tmp/s1" generated total)" = "0" ] || fail "generated.total should be 0"

# --- case 2: build + register 後。missing が報告される ---
"$build" --root "$tmp/repo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null
run_status > "$tmp/s2" 2>&1
[ "$(jget "$tmp/s2" generated total)" = "2" ] || fail "generated.total should be 2"
[ "$(jget "$tmp/s2" generated stale)" = "0" ] || fail "generated.stale should be 0"
# catalog は target-artifact 単位 (catalog_version 3)。2 target なので registered=2。
[ "$(jget "$tmp/s2" register registered)" = "2" ] || fail "register.registered should be 2 (target-artifact unit)"
[ "$(jget "$tmp/s2" register unsupported)" = "0" ] || fail "register.unsupported should be present and 0"
[ "$(jget "$tmp/s2" sync_targets 0 state)" = '"missing"' ] || fail "target should be missing"

# --- case 3: sync apply 後は managed ---
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --apply --quiet > /dev/null
run_status > "$tmp/s3" 2>&1
[ "$(jget "$tmp/s3" sync_targets 0 state)" = '"managed"' ] || fail "target should be managed"
[ "$(jget "$tmp/s3" sync_targets 1 state)" = '"managed"' ] || fail "both targets should be managed"

# --- case 3b: managed でも register 後に manifest を変えたら target は stale (#148) ---
# (source 不変で managed のままでも、登録判断が古いと再 register が要る = stale 表示)
printf '\nsummary: demo workflow (edited)\n' >> "$tmp/repo/shared/workflows/personal-demo.asset.yml"
run_status > "$tmp/s3b" 2>&1
[ "$(jget "$tmp/s3b" sync_targets 0 state)" = '"stale"' ] \
  || fail "manifest change should make managed target stale: $(cat "$tmp/s3b")"
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null   # 元の状態へ (再 register で fresh)
run_status > "$tmp/s3c" 2>&1
[ "$(jget "$tmp/s3c" sync_targets 0 state)" = '"managed"' ] \
  || fail "re-register should restore managed: $(cat "$tmp/s3c")"

# --- case 4: source 変更で generated.stale と target stale が出る ---
cat > "$tmp/repo/shared/workflows/personal-demo.md" <<'EOF'
# demo v2
EOF
run_status > "$tmp/s4" 2>&1
[ "$(jget "$tmp/s4" generated stale)" = "2" ] || fail "generated should be stale after source change"
"$build" --root "$tmp/repo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null   # sync は catalog build_id を照合するため rebuild 後は register まで
run_status > "$tmp/s4b" 2>&1
[ "$(jget "$tmp/s4b" generated stale)" = "0" ] || fail "rebuild should clear stale"
[ "$(jget "$tmp/s4b" sync_targets 0 state)" = '"stale"' ] || fail "target should be stale after rebuild"

# --- case 5: unmanaged 同名 target は conflict ---
rm -rf "$tmp/claude/skills/personal-demo"
mkdir -p "$tmp/claude/skills/personal-demo"
echo "user-owned" > "$tmp/claude/skills/personal-demo/SKILL.md"
run_status > "$tmp/s5" 2>&1
grep -q '"conflict"' "$tmp/s5" || fail "conflict state missing: $(cat "$tmp/s5")"

# --- case 6: manifest error で checks が fail になる ---
cat > "$tmp/repo/shared/workflows/personal-demo.asset.yml" <<'EOF'
schema_version: 1
name: personal-demo
kind: bogus
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
run_status > "$tmp/s6" 2>&1
[ "$(jget "$tmp/s6" checks manifest_validation)" = '"fail"' ] || fail "manifest check should fail"
[ "$(jget "$tmp/s6" assets manifest_errors)" = "1" ] || fail "manifest_errors should be 1"

# --- case 7: status は read-only (fixture を一切変更しない) ---
before=$(find "$tmp/repo" "$tmp/codex" "$tmp/claude" -type f | sort)
ls_before=$(find "$tmp/repo" "$tmp/codex" "$tmp/claude" -type f -exec cksum {} + | sort)
run_status > /dev/null 2>&1
after=$(find "$tmp/repo" "$tmp/codex" "$tmp/claude" -type f | sort)
ls_after=$(find "$tmp/repo" "$tmp/codex" "$tmp/claude" -type f -exec cksum {} + | sort)
[ "$before" = "$after" ] || fail "status must not add or remove files"
[ "$ls_before" = "$ls_after" ] || fail "status must not modify files"

# --- case 8: 出力に absolute local path と secret-like string が含まれない ---
grep -q "$tmp" "$tmp/s3" && fail "status output must not contain absolute paths"
grep -qiE "token|credential|api[_-]?key" "$tmp/s3" && fail "status output must not contain secret-like keys"

# --- case 9: repository 本体で contract JSON が出る ---
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
"$status_sh" --root "$repo_root" --json > "$tmp/s9" 2>&1 || fail "repo status should succeed"
[ "$(jget "$tmp/s9" repo present)" = "true" ] || fail "repo.present should be true"

# --- case 10: instruction の generated も generated.total に数える ---
mkdir -p "$tmp/irepo/shared/instructions" "$tmp/icodex" "$tmp/iclaude"
cat > "$tmp/irepo/shared/instructions/personal-ops.md" <<'EOF'
# ops
EOF
cat > "$tmp/irepo/shared/instructions/personal-ops.asset.yml" <<'EOF'
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
"$build" --root "$tmp/irepo" --quiet > /dev/null
"$status_sh" --root "$tmp/irepo" --codex-home "$tmp/icodex" --claude-home "$tmp/iclaude" --json > "$tmp/is10" 2>&1
[ "$(jget "$tmp/is10" generated total)" = "2" ] || fail "instruction generated should count (2 targets): $(cat "$tmp/is10")"
[ "$(jget "$tmp/is10" generated stale)" = "0" ] || fail "fresh instruction should not be stale"
# source 変更で instruction も stale になる
echo "changed" >> "$tmp/irepo/shared/instructions/personal-ops.md"
"$status_sh" --root "$tmp/irepo" --codex-home "$tmp/icodex" --claude-home "$tmp/iclaude" --json > "$tmp/is10b" 2>&1
[ "$(jget "$tmp/is10b" generated stale)" = "2" ] || fail "changed instruction source should be stale: $(cat "$tmp/is10b")"

# --- case 11: 壊れた (malformed YAML) manifest があっても status は crash しない (B1) ---
mkdir -p "$tmp/brepo/shared/workflows" "$tmp/bcodex" "$tmp/bclaude"
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
"$build" --root "$tmp/brepo" --quiet > /dev/null   # generated artifact を作る (fresh? が走る)
# manifest を malformed YAML に壊す (load_all が Psych::SyntaxError を raise する状況)
printf 'name: personal-demo\nkind: [unbalanced\n   : :\n' > "$tmp/brepo/shared/workflows/personal-demo.asset.yml"
"$status_sh" --root "$tmp/brepo" --codex-home "$tmp/bcodex" --claude-home "$tmp/bclaude" --json > "$tmp/s11" 2>&1 \
  || fail "status must not crash on a broken manifest: $(cat "$tmp/s11")"
[ "$(jget "$tmp/s11" checks manifest_validation)" = '"fail"' ] || fail "broken manifest should report manifest=fail: $(cat "$tmp/s11")"
[ "$(jget "$tmp/s11" generated total)" = "1" ] || fail "generated artifact should still be counted with a broken manifest: $(cat "$tmp/s11")"
[ "$(jget "$tmp/s11" generated stale)" = "1" ] || fail "broken manifest should degrade freshness to stale: $(cat "$tmp/s11")"

# --- case 12: source ファイルが消えても status は crash しない (B2: build_id の Errno) ---
# 有効な manifest + generated artifact のまま source 本体を削除すると build_id_for が Errno。
rm -f "$tmp/irepo/shared/instructions/personal-ops.md"
"$status_sh" --root "$tmp/irepo" --codex-home "$tmp/icodex" --claude-home "$tmp/iclaude" --json > "$tmp/s12" 2>&1 \
  || fail "status must not crash when an instruction source file is missing: $(cat "$tmp/s12")"
[ "$(jget "$tmp/s12" generated stale)" = "2" ] || fail "missing source should make instruction stale, not crash: $(cat "$tmp/s12")"

# --- case 13: script の generated も generated.total に数え、sync_target を報告する ---
mkdir -p "$tmp/screpo/shared/scripts" "$tmp/sccodex" "$tmp/scclaude"
printf '#!/bin/sh\necho hi\n' > "$tmp/screpo/shared/scripts/personal-wrap.sh"
# script kind は human review 必須 (#147) + 承認は内容に紐づく (#148)。
scbid=$(ruby -r"$script_dir/../lib/build" \
  -e 'puts Build.build_id_for(ARGV[0], "shared/scripts/personal-wrap.sh", "text")' "$tmp/screpo")
cat > "$tmp/screpo/shared/scripts/personal-wrap.asset.yml" <<EOF
schema_version: 1
name: personal-wrap
kind: script
visibility: personal
targets:
  - claude-code
risk:
  prompt_injection: low
  privacy: low
review:
  human_review: approved
  approved_build_id: $scbid
source:
  path: shared/scripts/personal-wrap.sh
  format: text
EOF
"$build" --root "$tmp/screpo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/screpo" --quiet > /dev/null
"$status_sh" --root "$tmp/screpo" --codex-home "$tmp/sccodex" --claude-home "$tmp/scclaude" --json > "$tmp/sc13" 2>&1
# generated は本体 1 つだけ数える (sidecar marker は含めない)
[ "$(jget "$tmp/sc13" generated total)" = "1" ] || fail "script generated should count body only (not sidecar): $(cat "$tmp/sc13")"
[ "$(jget "$tmp/sc13" generated stale)" = "0" ] || fail "fresh script should not be stale"
[ "$(jget "$tmp/sc13" sync_targets 0 state)" = '"missing"' ] || fail "script target should be missing before sync: $(cat "$tmp/sc13")"
# source 変更で script も stale になる
printf '#!/bin/sh\necho changed\n' > "$tmp/screpo/shared/scripts/personal-wrap.sh"
"$status_sh" --root "$tmp/screpo" --codex-home "$tmp/sccodex" --claude-home "$tmp/scclaude" --json > "$tmp/sc13b" 2>&1
[ "$(jget "$tmp/sc13b" generated stale)" = "1" ] || fail "changed script source should be stale: $(cat "$tmp/sc13b")"

echo "ok: status self-test passed"
