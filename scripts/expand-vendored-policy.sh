#!/bin/sh
# vendor する takt の policy の {{include:…}} を展開する (#622)。手順は
# shared/skills/personal-production-rail/references/policies/NOTICE.md。
# 依存: macOS 標準 Ruby のみ。network access なし (取得は呼び出し側)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/expand_vendored_policy.rb" "$@"
