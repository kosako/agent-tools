#!/bin/sh
# shared/plugins/personal-agent-tools.js (OpenCode plugin, #295 PR 1 / PR 2) の self-test。
# build.sh で tmp の最小 fixture から生成した plugin (marker 行つき) を node で import し、
# server(fakeCtx, {timeoutMs}) が返す hooks 経由で safe-gh の注記、品質ループ (fast-edit-check /
# changed-scope-qa)、fail-open を確かめる (node 側: lib/opencode-plugin-test.mjs)。hook script は
# shared/scripts の実物を tmp の home に置いて呼ぶ。check は tmp の git repo と記録つきの fake を使う。
# 実物の tool home も network も使わない。node が無ければ fail にする (skip にしない)。
# 生成物は ESM 構文の .js なので、隣に {"type":"module"} の package.json を置いてモジュール形式を明示し、
# Node の構文の自動判定と祖先の package.json に頼らない (#396)。
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
# 回帰 (#396): fixture の祖先に {"type":"commonjs"} の package.json を置く。plugin の隣の宣言 (2.) が
# 無ければ、Node の版によらず import が SyntaxError で落ちる。
printf '{"type":"commonjs"}\n' > "$tmp/package.json"

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
# import する生成物の隣に {"type":"module"} の package.json を置いて、モジュール形式を明示する (#396)。
printf '{"type":"module"}\n' > "$fixture/generated/opencode/plugins/package.json"
mkdir -p "$tmp/work"
node "$node_cases" "$generated" "$hook_source" "$fast_edit_source" "$qa_source" "$tmp/work" \
  || fail "node cases failed"
# 構文の自動判定の無い Node の再現 (flag を受け付ける Node のときだけ。work dir は分ける)。
if no_detect=$(node_options_without_detect_module); then
  mkdir -p "$tmp/work-no-detect"
  NODE_OPTIONS=$no_detect node "$node_cases" "$generated" "$hook_source" "$fast_edit_source" "$qa_source" "$tmp/work-no-detect" \
    || fail "node cases failed without the syntax detection (NODE_OPTIONS=$no_detect)"
  echo "ok node cases without the syntax detection"
else
  echo "skip: node cases without the syntax detection (this node does not accept --no-experimental-detect-module in NODE_OPTIONS)"
fi

echo "all opencode-plugin tests passed"
