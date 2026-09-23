#!/bin/sh
# pipeline script の root 既定値と、shared/ の無い root での fail-closed の self-test (#305)。
# scripts/ を写した fixture repo を一時 directory に作り、repo 外の cwd から --root なしで
# 起動する (実 repo の generated/ には触れない)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- fixture: scripts/ を写した repo (path に空白を含める) と、repo 外の cwd ---
repo="$tmp/repo space"
elsewhere="$tmp/elsewhere"
mkdir -p "$repo" "$elsewhere" "$tmp/codex" "$tmp/claude"
cp -R "$repo_root/scripts" "$repo/scripts"
make_demo_repo "$repo" instructions personal-ops instruction \
  '# operating rules' '' 'ドキュメントは日本語を既定にする。'

# repo 外の cwd から、fixture repo の script を起動する。
# 使い方: run_script <script> <args>... (出力は $tmp/out、exit code は $rc)
run_script() {
  rs_script=$1
  shift
  rc=0
  (cd "$elsewhere" && "$repo/scripts/$rs_script" "$@") > "$tmp/out" 2>&1 || rc=$?
}

# --- case 1: 既定 root は cwd ではなく script の属する repo (8 entry point) ---
# 各 script の出力は、root が cwd (空の dir) だった場合と区別できる値で確かめる。
run_script check-manifests.sh
[ "$rc" = 0 ] && grep -q "ok: 1 manifest(s) validated" "$tmp/out" \
  || fail "check-manifests should validate the fixture repo: $(cat "$tmp/out")"

run_script check-injection.sh
[ "$rc" = 0 ] && grep -q "ok: 2 file(s) scanned" "$tmp/out" \
  || fail "check-injection should scan the fixture repo: $(cat "$tmp/out")"

run_script build.sh
[ "$rc" = 0 ] && grep -q "ok: 2 artifact(s) built" "$tmp/out" \
  || fail "build should build the fixture repo: $(cat "$tmp/out")"
[ -f "$repo/generated/codex/instructions/AGENTS.md" ] || fail "build output should land in the fixture repo"

run_script register.sh
[ "$rc" = 0 ] && grep -q "2 registered" "$tmp/out" \
  || fail "register should register the fixture repo: $(cat "$tmp/out")"
[ -f "$repo/generated/catalog.json" ] || fail "catalog should land in the fixture repo"

run_script status.sh --json --codex-home "$tmp/codex" --claude-home "$tmp/claude"
[ "$rc" = 0 ] || fail "status should succeed: $(cat "$tmp/out")"
[ "$(jget "$tmp/out" repo present)" = "true" ] || fail "status should see shared/ of the fixture repo: $(cat "$tmp/out")"

run_script doctor.sh --codex-home "$tmp/codex" --claude-home "$tmp/claude" --agents-home "$tmp/agents"
grep -q "ok: repo: present=true" "$tmp/out" || fail "doctor should see the fixture repo: $(cat "$tmp/out")"

run_script connect.sh --codex-home "$tmp/codex" --claude-home "$tmp/claude"
[ "$rc" = 0 ] && grep -q "create: \[claude-code\] owned" "$tmp/out" \
  || fail "connect should plan from the fixture repo's artifacts: $(cat "$tmp/out")"

run_script sync.sh --codex-home "$tmp/codex" --claude-home "$tmp/claude"
[ "$rc" = 0 ] && grep -q "(run connect first)" "$tmp/out" \
  || fail "sync should read the fixture repo's catalog: $(cat "$tmp/out")"

# cwd には何も作らない (build / register は dry-run でも generated/ を書くので、root を
# 取り違えると cwd に generated/catalog.json ができる)
[ -z "$(ls -A "$elsewhere")" ] || fail "nothing should be written to the cwd: $(ls -A "$elsewhere")"

# --- case 2: shared/ の無い root は build / register / setup が非 0 で止まり、何も書かない ---
noshared="$tmp/no-shared"
mkdir -p "$noshared"

run_script build.sh --root "$noshared"
[ "$rc" != 0 ] || fail "build should fail without shared/: $(cat "$tmp/out")"
grep -q "no shared/ directory under root" "$tmp/out" || fail "build should say why: $(cat "$tmp/out")"
[ ! -e "$noshared/generated" ] || fail "build must not write generated/ without shared/"

run_script register.sh --root "$noshared"
[ "$rc" != 0 ] || fail "register should fail without shared/: $(cat "$tmp/out")"
grep -q "no shared/ directory under root" "$tmp/out" || fail "register should say why: $(cat "$tmp/out")"
[ ! -e "$noshared/generated" ] || fail "register must not write a catalog without shared/"

run_script setup.sh --root "$noshared" --codex-home "$tmp/codex" --claude-home "$tmp/claude"
[ "$rc" != 0 ] || fail "setup should stop without shared/: $(cat "$tmp/out")"
[ ! -e "$noshared/generated" ] || fail "setup must not write generated/ without shared/"

echo "ok: root-default self-test"
