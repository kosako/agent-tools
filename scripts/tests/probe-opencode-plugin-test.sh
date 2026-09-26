#!/bin/sh
# probe-opencode-plugin.sh の self-test (#295 PR 0)。opencode も外部の network も使わない
# (mock は loopback だけ。runner を通しで動かす T2 / T6 は偽の opencode を PATH に置く)。
# node が無ければ fail にする (T7 は計測用 plugin を node で読む。skip にしない)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
probe="$script_dir/../probe-opencode-plugin.sh"
plugin="$script_dir/../lib/probe_opencode/probe-plugin.js"
helper="$script_dir/lib/probe-opencode-test.rb"

command -v node >/dev/null 2>&1 || fail "node is required (T7 loads the probe plugin with node)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- T1: 引数と exit code -------------------------------------------------------------
expect_exit() {
  name=$1; want=$2; shift 2
  status=0
  "$probe" "$@" > "$tmp/t1.out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "T1 $name: expected exit $want, got $status: $(cat "$tmp/t1.out")"
}
expect_exit real-without-flags 2 --stage real --out "$tmp/o-real"
expect_exit real-without-model 2 --stage real --real --out "$tmp/o-real"
expect_exit out-in-worktree 2 --dry-run --stage mock --out "$repo_root/probe-out-should-not-exist"
[ ! -e "$repo_root/probe-out-should-not-exist" ] || fail "T1: --out inside the worktree must not be created"
expect_exit unknown-stage 2 --stage nope --out "$tmp/o"
expect_exit managed-pass-env 2 --stage real --real --model p/m --pass-env HOME --out "$tmp/o"
mkdir -p "$tmp/nonempty" && : > "$tmp/nonempty/x"
expect_exit nonempty-out 2 --dry-run --stage mock --out "$tmp/nonempty"
# dry-run は opencode を起動しない (PATH に opencode が無くても exit 0)。
status=0
PATH=/usr/bin:/bin "$probe" --dry-run --stage all --out "$tmp/o-dry" > "$tmp/t1.out" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "T1 dry-run: expected exit 0, got $status: $(cat "$tmp/t1.out")"
grep -q '^plan (dry-run): stages=isolation,mock,serve ' "$tmp/t1.out" || fail "T1 dry-run: plan missing: $(cat "$tmp/t1.out")"
[ ! -e "$tmp/o-dry" ] || fail "T1 dry-run must not create --out"
echo "ok T1"

# --- T2 / T6: runner を偽の opencode で通しで動かす ---------------------------------------
# 偽の opencode は受け取った env を dump に書き、isolation stage が読む出力を返す。
fakebin="$tmp/fakebin"
dump="$tmp/env-dump"
mkdir -p "$fakebin"
{
  printf '#!/bin/sh\n'
  printf 'dump=%s\n' "$(shq "$dump")"
  cat <<'EOF'
{ echo "--- $*"; env; } >> "$dump"
case "$1" in
  --version) echo 1.18.30 ;;
  debug)
    case "$2" in
      paths)
        printf 'home       %s\n' "$HOME"
        printf 'config     %s/opencode\n' "$XDG_CONFIG_HOME"
        printf 'data       %s/opencode\n' "$XDG_DATA_HOME"
        printf 'tmp        %s/opencode\n' "$TMPDIR" ;;
      config) printf '{"provider":{"probe":{}},"enabled_providers":["probe"]}\n' ;;
    esac ;;
  models) printf 'probe/claude-probe\nprobe/gpt-5-probe\n' ;;
esac
EOF
} > "$fakebin/opencode"
chmod +x "$fakebin/opencode"

status=0
env CLAUDECODE=1 CODEX_THREAD_ID=probe-thread OPENCODE_CONFIG=/nonexistent/opencode.json GH_TOKEN=probe-token \
  PATH="$fakebin:$PATH" "$probe" --stage isolation --out "$tmp/o-iso" > "$tmp/iso.out" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "T2: runner with the fake opencode: exit $status: $(cat "$tmp/iso.out")"
[ -s "$dump" ] || fail "T2: the fake opencode was not called"
for name in CLAUDECODE CODEX_THREAD_ID OPENCODE_CONFIG GH_TOKEN; do
  if grep -q "^$name=" "$dump"; then fail "T2: $name leaked into the child env"; fi
done
# 各起動 (--- 行) の env が tmp を指すこと。
ruby -e '
  blocks = File.read(ARGV[0]).split(/^--- .*\n/).reject(&:empty?)
  abort "FAIL: T2: no env blocks" if blocks.empty?
  blocks.each do |b|
    env = b.lines.map { |l| l.chomp.split("=", 2) }.select { |kv| kv.length == 2 }.to_h
    base = env["HOME"].to_s.sub(%r{/home\z}, "")
    abort "FAIL: T2: HOME is not the probe tmp: #{env["HOME"]}" unless base.include?("/opencode-probe-") && env["HOME"] != ARGV[1]
    { "XDG_CONFIG_HOME" => "/xdg/config", "XDG_DATA_HOME" => "/xdg/data", "XDG_CACHE_HOME" => "/xdg/cache",
      "XDG_STATE_HOME" => "/xdg/state", "OPENCODE_DB" => "/opencode.db", "GIT_CONFIG_GLOBAL" => "/gitconfig",
      "TMPDIR" => "/tmp" }.each do |k, suffix|
      abort "FAIL: T2: #{k} must be <tmp>#{suffix}: #{env[k]}" unless env[k] == base + suffix
    end
    abort "FAIL: T2: GIT_CONFIG_NOSYSTEM must be 1" unless env["GIT_CONFIG_NOSYSTEM"] == "1"
  end
' "$dump" "$HOME" || fail "T2: child env is not isolated"
echo "ok T2"

for f in summary.json summary.md facts.json hooks.jsonl; do
  case $f in hooks.jsonl) continue ;; esac
  [ -s "$tmp/o-iso/$f" ] || fail "T6: $f was not written"
done
for f in summary.json summary.md; do
  if grep -q "$HOME" "$tmp/o-iso/$f"; then fail "T6: $f contains \$HOME"; fi
  if grep -q 'opencode-probe-\|/private/var/\|/var/folders/' "$tmp/o-iso/$f"; then fail "T6: $f contains the tmp path"; fi
done
[ "$(jget "$tmp/o-iso/summary.json" items 0 id)" = '"M1"' ] || fail "T6: summary.json items"
[ "$(jget "$tmp/o-iso/summary.json" items 0 observed paths_under_tmp)" = true ] || fail "T6: M1 paths_under_tmp: $(jget "$tmp/o-iso/summary.json" items 0)"
echo "ok T6"

# --- T3 / T4 / T5 (Ruby) ----------------------------------------------------------------
canary="PROBECANARY$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$canary" > "$tmp/canary"
ruby "$helper" t3 "$tmp" || fail "T3"
ruby "$helper" t4 "$tmp" || fail "T4"
mkdir -p "$tmp/t5"
ruby "$helper" t5 "$tmp/t5" || fail "T5"

# --- T7: 記録の allowlist (plugin と mock の header) --------------------------------------
if grep -q "$canary" "$tmp/mock-requests.jsonl"; then fail "T7: header canary leaked into mock-requests.jsonl"; fi
: > "$tmp/hooks.jsonl"
PROBE_HOOKS_OUT="$tmp/hooks.jsonl" PROBE_PRIMARY=probe-plugin PROBE_NONCE=PROBE-NONCE-t7 PROBE_MODE=annotate,mark,notify \
  node "$script_dir/lib/probe-opencode-plugin-test.mjs" "$plugin" "$tmp/hooks.jsonl" "$canary" || fail "T7"

echo "all probe-opencode-plugin tests passed"
