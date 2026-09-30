#!/bin/sh
# shared/plugins/personal-agent-tools.js (OpenCode plugin, #295 PR 1 / PR 2) の self-test。
# build.sh で tmp の最小 fixture から生成した plugin (marker 行つき) を node で import し、
# server(fakeCtx, {timeoutMs}) が返す hooks 経由で safe-gh の注記、品質ループ (fast-edit-check /
# changed-scope-qa)、fail-open を確かめる (node 側: lib/opencode-plugin-test.mjs)。hook script は
# shared/scripts の実物を tmp の home に置いて呼ぶ。check は tmp の git repo と記録つきの fake を使う。
# 実物の tool home も network も使わない。node が無ければ fail にする (skip にしない)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
build="$script_dir/../build.sh"
node_cases="$script_dir/lib/opencode-plugin-test.mjs"
hook_source="$repo_root/shared/scripts/personal-safe-gh-hook.rb"
fast_edit_source="$repo_root/shared/scripts/personal-fast-edit-check.rb"
qa_source="$repo_root/shared/scripts/personal-changed-scope-qa.rb"

command -v node >/dev/null 2>&1 || fail "node is required (the plugin cases run with node)"
for source in "$hook_source" "$fast_edit_source" "$qa_source"; do
  [ -f "$source" ] || fail "missing hook script source: $source"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- 1. 実 asset を最小 fixture に写して build し、marker 行つきの生成物を得る ---
fixture="$tmp/fixture"
mkdir -p "$fixture/shared/plugins"
cp "$repo_root/shared/plugins/personal-agent-tools.js" \
  "$repo_root/shared/plugins/personal-agent-tools.asset.yml" \
  "$fixture/shared/plugins/"

"$build" --root "$fixture" > "$tmp/build.out" 2>&1 \
  || fail "build of the plugin fixture should pass: $(cat "$tmp/build.out")"
grep -q "built: generated/opencode/plugins/personal-agent-tools.js" "$tmp/build.out" \
  || fail "build did not report the plugin artifact: $(cat "$tmp/build.out")"
generated="$fixture/generated/opencode/plugins/personal-agent-tools.js"
[ -f "$generated" ] || fail "missing generated plugin"
head -1 "$generated" | grep -q '^/\* agent-tools:managed v=1 repo=agent-tools name=personal-agent-tools target=opencode artifact_kind=plugin ' \
  || fail "generated plugin must start with the plugin marker: $(head -1 "$generated")"
echo "ok build fixture"

# --- 2. node の case (入口経由。HOME は node 側が case ごとに tmp へ向ける) ---
mkdir -p "$tmp/work"
node "$node_cases" "$generated" "$hook_source" "$fast_edit_source" "$qa_source" "$tmp/work" \
  || fail "node cases failed"

echo "all opencode-plugin tests passed"
