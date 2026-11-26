#!/bin/sh
# doctor の body の検査 (#722) の self-test。fixture と fake の tool home は一時 directory に作る。
# 実際の ~/.codex / ~/.claude / ~/.config/opencode には触れない。network access なし。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
# 書けないようにした fixture の dir が残っても消せるよう、u+w を戻してから消す。
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
ruby "$script_dir/lib/doctor-body-test.rb" "$tmp"
