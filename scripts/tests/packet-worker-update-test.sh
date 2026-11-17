#!/bin/sh
# worker-update を隔離した repository で検証する。network と実 packet は使わない。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby "$script_dir/lib/packet-worker-update-test.rb" "$repo_root/shared/scripts/personal-packet.rb" "$tmp"
