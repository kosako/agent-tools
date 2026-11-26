#!/bin/sh
# 起動のときの依頼と回収した結果の対応を、操作の順序を並べて確かめる (#719)。実物の script を読み込み、外部の command だけを差し替える。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby "$script_dir/lib/worker-request-order-test.rb" "$repo_root" "$tmp"
