#!/bin/sh
# opencode home の canary (#295)。書き込みの経路を持つ suite (sync-test / setup-test /
# root-default-test) を偽の HOME の下で回し、既定の opencode home (<HOME>/.config/opencode) に
# 置いた管理下の canary plugin が byte で残り、その下に entry が増減しないことを確かめる。
# --opencode-home を 1 つ外した call site があると、既定の home (= 偽の HOME の下) に書く /
# 消すので、ここで落ちる (sync --apply は plugins/personal-*.js を作り、sync --prune --apply は
# marker つきの canary を orphan として消す)。読み取りだけの call site (status / doctor) は
# ここでは捕まらないので scripts/tests/opencode-home-callsites-test.sh (静的な検査) が守る。
#
# CI では self-tests の loop とは別 step で実行する (tests/lib/ は loop の glob に乗らない)。
# HOME を差し替えるのは、この canary と doctor-test の XDG case だけ (suite 本体では差し替え
# ない: git の global config が見えなくなるため。ここでは identity の入った GIT_CONFIG_GLOBAL を
# 与えて補う)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)   # scripts/tests
# shellcheck source=test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_home="$tmp/home"
opencode_home="$fake_home/.config/opencode"
mkdir -p "$opencode_home/plugins" "$opencode_home/node_modules/@opencode-ai/plugin"

# 偽の HOME では ~/.gitconfig が見えないので、identity は GIT_CONFIG_GLOBAL で与える。
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name canary
git config --file "$GIT_CONFIG_GLOBAL" user.email canary@example.com

# canary: 管理下の marker (実装の PluginMarker.render で組む) を持つ personal-canary.js。catalog に
# 載らない managed plugin なので、既定の home を --prune --apply が走査すれば消される。
# OpenCode 側の file も置き、sync が触らないことを同時に見る。
ruby -r"$script_dir/../lib/plugin_marker" -rdigest -e '
  puts PluginMarker.render(name: "personal-canary", target: "opencode",
                           source: "shared/plugins/personal-canary.js",
                           build_id: "sha256:" + Digest::SHA256.hexdigest("canary"))
  puts "export default { id: \"personal-canary\", server: async () => ({}) };"
' > "$opencode_home/plugins/personal-canary.js"
printf '{ "$schema": "https://opencode.ai/config.json" }\n' > "$opencode_home/opencode.json"
printf '{ "dependencies": { "@opencode-ai/plugin": "1.18.30" } }\n' > "$opencode_home/package.json"
printf 'export {};\n' > "$opencode_home/node_modules/@opencode-ai/plugin/index.js"
cp "$opencode_home/plugins/personal-canary.js" "$tmp/canary.expected"

# 偽の HOME の下の全 entry (file / dir / symlink) と file の checksum。
snapshot() {
  find "$fake_home" -mindepth 1 | sort
  find "$fake_home" -type f -exec cksum {} + | sort
}
before=$(snapshot)

for suite in sync-test setup-test root-default-test; do
  echo "--- $suite (HOME=<fake>)"
  HOME="$fake_home" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$script_dir/$suite.sh" > "$tmp/$suite.log" 2>&1 \
    || fail "$suite failed under the canary HOME: $(tail -20 "$tmp/$suite.log")"
done

cmp -s "$opencode_home/plugins/personal-canary.js" "$tmp/canary.expected" \
  || fail "canary plugin was modified or removed under the default opencode home (a write path is missing --opencode-home)"
after=$(snapshot)
[ "$before" = "$after" ] || fail "files changed under the fake HOME (a call site is missing --opencode-home):
--- before
$before
--- after
$after"

echo "ok: opencode home canary passed"
