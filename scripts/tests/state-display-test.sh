#!/bin/sh
# status と doctor の target の表示 (#723) の self-test。fixture と fake の tool home は一時 directory に作る。
# 実際の ~/.codex / ~/.claude / ~/.config/opencode には触れない。network access なし。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby "$script_dir/lib/state-display-test.rb" "$tmp"
