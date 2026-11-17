#!/bin/sh
# 外部 CLI は fixture で置き換え、packet と preflight は配備と同じ配置で使う。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby "$script_dir/lib/codex-worker-run-test.rb" "$repo_root" "$tmp"
