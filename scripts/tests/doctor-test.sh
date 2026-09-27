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
    --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" --agents-home "$tmp/agents"
}

# --- fixture repo ---
mkdir -p "$tmp/codex/skills" "$tmp/claude/skills" "$tmp/agents"
WAM_EXTRA='summary: demo workflow'
make_demo_repo "$tmp/repo" workflows personal-demo workflow '# demo'
"$build" --root "$tmp/repo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/repo" --quiet > /dev/null
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" --apply --quiet > /dev/null

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
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" > /dev/null 2>&1 \
  && fail "sync should also report the conflict" || true

# --- case 5: catalog があれば build_id で鮮度を check する ---
rm -rf "$tmp/codex/skills/personal-demo"
"$sync" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" --opencode-home "$tmp/opencode" --apply --quiet > /dev/null
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
write_asset_manifest "$tmp/brepo/shared/workflows/personal-demo.asset.yml" \
  personal-demo workflow public shared/workflows/personal-demo.md markdown codex
"$build" --root "$tmp/brepo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/brepo" --quiet > /dev/null   # catalog を valid に作る
run_bdoctor() {
  "$doctor" --root "$tmp/brepo" --codex-home "$tmp/bcodex" \
    --claude-home "$tmp/bclaude" --opencode-home "$tmp/bopencode" --agents-home "$tmp/bagents"
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

# --- case 9: deployed_but_inactive target は warn で報告する (crash しない) (#186) ---
# 「一度配布 → 後で gate」を catalog の registration 変更で再現。doctor の state→level map に
# 新語彙が無いと .fetch が KeyError で crash するため、その回帰も兼ねる。
mkdir -p "$tmp/gcodex/skills" "$tmp/gclaude/skills" "$tmp/gagents"
WAM_EXTRA='summary: demo workflow'
make_demo_repo "$tmp/grepo" workflows personal-demo workflow '# demo'
"$build" --root "$tmp/grepo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/grepo" --quiet > /dev/null
"$sync" --root "$tmp/grepo" --codex-home "$tmp/gcodex" --claude-home "$tmp/gclaude" --opencode-home "$tmp/gopencode" --apply --quiet > /dev/null
ruby -rjson -e '
  path = ARGV[0]
  catalog = JSON.parse(File.read(path))
  catalog["assets"].each { |a| a["registration"] = "human_review_required" }
  File.write(path, JSON.pretty_generate(catalog))
' "$tmp/grepo/generated/catalog.json"
status=0
"$doctor" --root "$tmp/grepo" --codex-home "$tmp/gcodex" \
  --claude-home "$tmp/gclaude" --opencode-home "$tmp/gopencode" --agents-home "$tmp/gagents" > "$tmp/d9" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "deployed_but_inactive should warn, not fail/crash (exit $status): $(cat "$tmp/d9")"
grep -q "warn: target: \[codex\] personal-demo deployed_but_inactive" "$tmp/d9" \
  || fail "missing deployed_but_inactive warn line: $(cat "$tmp/d9")"

# --- case 10: opencode home は先頭行 marker が正しい plugin の数を出し、生の path を出さない (#295) ---
mkdir -p "$tmp/plrepo/shared/plugins" "$tmp/plcodex" "$tmp/plclaude" "$tmp/plopen/plugins" "$tmp/plagents"
printf 'export default { id: "personal-plug", server: async () => ({}) };\n' > "$tmp/plrepo/shared/plugins/personal-plug.js"
write_approved_plugin_manifest "$tmp/plrepo" personal-plug personal
"$build" --root "$tmp/plrepo" --quiet > /dev/null
"$script_dir/../register.sh" --root "$tmp/plrepo" --quiet > /dev/null
"$sync" --root "$tmp/plrepo" --codex-home "$tmp/plcodex" --claude-home "$tmp/plclaude" --opencode-home "$tmp/plopen" --apply --quiet > /dev/null
# 数えないもの: marker の無い personal-*.js、非 personal の file、別 tool 向けの marker、file 名と name が違う marker
echo "hand made" > "$tmp/plopen/plugins/personal-junk.js"
echo "herdr" > "$tmp/plopen/plugins/herdr-agent-state.js"
ruby -r"$script_dir/../lib/plugin_marker" -e 'puts PluginMarker.render(name: "personal-foreign", target: "claude-code",
  source: "shared/plugins/personal-foreign.js", build_id: "sha256:" + "0" * 64)' > "$tmp/plopen/plugins/personal-foreign.js"
# marker の name が file 名と違うものは、sync の所有判定 (target + name) では unmanaged なので doctor も数えない
ruby -r"$script_dir/../lib/plugin_marker" -e 'puts PluginMarker.render(name: "personal-other", target: "opencode",
  source: "shared/plugins/personal-other.js", build_id: "sha256:" + "0" * 64)' > "$tmp/plopen/plugins/personal-mismatch.js"
# 使い方: run_pdoctor <opencode home> [extra args]
run_pdoctor() {
  rpd_home=$1
  shift
  "$doctor" --root "$tmp/plrepo" --codex-home "$tmp/plcodex" --claude-home "$tmp/plclaude" \
    --opencode-home "$rpd_home" --agents-home "$tmp/plagents" "$@"
}
run_pdoctor "$tmp/plopen" > "$tmp/d10" 2>&1 || fail "doctor with a plugin should pass: $(cat "$tmp/d10")"
grep -q "ok: home: \[opencode\] <opencode home> present, 1 personal plugin(s)" "$tmp/d10" \
  || fail "opencode home line should count only managed plugins: $(cat "$tmp/d10")"
grep -q "ok: target: \[opencode\] personal-plug managed" "$tmp/d10" || fail "missing opencode target line: $(cat "$tmp/d10")"
grep -F -q "$tmp" "$tmp/d10" && fail "doctor output must not contain the raw opencode home path: $(cat "$tmp/d10")" || true
! grep -q "XDG_CONFIG_HOME" "$tmp/d10" || fail "XDG warn must not appear when --opencode-home is given: $(cat "$tmp/d10")"
# home が無ければ info (tool not installed?)
run_pdoctor "$tmp/no-such-opencode" > "$tmp/d10b" 2>&1 || fail "missing opencode home should not fail: $(cat "$tmp/d10b")"
grep -q "info: home: \[opencode\] <opencode home> not present" "$tmp/d10b" || fail "missing opencode home should be info: $(cat "$tmp/d10b")"
# --opencode-home が複数あれば後勝ち
run_pdoctor "$tmp/no-such-opencode" --opencode-home "$tmp/plopen" > "$tmp/d10c" 2>&1 \
  || fail "duplicate --opencode-home should pass: $(cat "$tmp/d10c")"
grep -q "ok: home: \[opencode\] <opencode home> present, 1 personal plugin(s)" "$tmp/d10c" \
  || fail "duplicate --opencode-home should take the last value: $(cat "$tmp/d10c")"

# --- case 11: XDG_CONFIG_HOME の warn は --opencode-home を省いたときだけ (#295) ---
# HOME を tmp に差し替える唯一の case: 既定の home (~/.config/opencode) を偽の HOME の下に向け、
# 実物の ~/.config/opencode を読まない。home flag を全部省いても既定は偽の HOME の下になる。
fake_home="$tmp/home11"
mkdir -p "$fake_home/.config/opencode" "$tmp/xdg11"
xdg_warn="warn: home: \[opencode\] \$XDG_CONFIG_HOME/opencode differs from the default ~/.config/opencode"
# 11a: flag なし + XDG が既定と食い違う → warn (exit は 0 のまま)
HOME="$fake_home" XDG_CONFIG_HOME="$tmp/xdg11" "$doctor" --root "$tmp/plrepo" > "$tmp/d11a" 2>&1 \
  || fail "XDG mismatch should warn, not fail: $(cat "$tmp/d11a")" # no-opencode-home: HOME を偽に差し替えた XDG の case (既定 home は偽 HOME の下)
grep -q "$xdg_warn" "$tmp/d11a" || fail "missing XDG warn when --opencode-home is omitted: $(cat "$tmp/d11a")"
grep -q "home: \[opencode\] ~/.config/opencode present, 0 personal plugin(s)" "$tmp/d11a" \
  || fail "default opencode home should be shown with tilde: $(cat "$tmp/d11a")"
grep -F -q "$tmp/xdg11" "$tmp/d11a" && fail "XDG warn must not print the raw XDG path: $(cat "$tmp/d11a")" || true
# 11b: --opencode-home を渡せば、XDG が食い違っていても warn しない
HOME="$fake_home" XDG_CONFIG_HOME="$tmp/xdg11" "$doctor" --root "$tmp/plrepo" --opencode-home "$tmp/plopen" > "$tmp/d11b" 2>&1 \
  || fail "doctor with --opencode-home under XDG should pass: $(cat "$tmp/d11b")"
! grep -q "XDG_CONFIG_HOME" "$tmp/d11b" || fail "XDG warn must not appear when --opencode-home is given: $(cat "$tmp/d11b")"
# 11c: XDG が既定と一致 / 空 (未設定と同じ) なら warn しない
HOME="$fake_home" XDG_CONFIG_HOME="$fake_home/.config" "$doctor" --root "$tmp/plrepo" > "$tmp/d11c" 2>&1 \
  || fail "doctor with matching XDG should pass: $(cat "$tmp/d11c")" # no-opencode-home: 同上
! grep -q "XDG_CONFIG_HOME" "$tmp/d11c" || fail "XDG warn must not appear when XDG matches the default: $(cat "$tmp/d11c")"
HOME="$fake_home" XDG_CONFIG_HOME= "$doctor" --root "$tmp/plrepo" > "$tmp/d11d" 2>&1 \
  || fail "doctor with empty XDG should pass: $(cat "$tmp/d11d")" # no-opencode-home: 同上
! grep -q "XDG_CONFIG_HOME" "$tmp/d11d" || fail "empty XDG_CONFIG_HOME must count as unset: $(cat "$tmp/d11d")"

# --- case 12: plugin の deployed_but_inactive は warn のまま (fail にしない) (#295) ---
ruby -rjson -e '
  path = ARGV[0]
  catalog = JSON.parse(File.read(path))
  catalog["assets"].each { |a| a["registration"] = "human_review_required" }
  File.write(path, JSON.pretty_generate(catalog))
' "$tmp/plrepo/generated/catalog.json"
status=0
run_pdoctor "$tmp/plopen" > "$tmp/d12" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "plugin deployed_but_inactive should warn, not fail (exit $status): $(cat "$tmp/d12")"
grep -q "warn: target: \[opencode\] personal-plug deployed_but_inactive" "$tmp/d12" \
  || fail "missing plugin deployed_but_inactive warn: $(cat "$tmp/d12")"

echo "ok: doctor self-test passed"
