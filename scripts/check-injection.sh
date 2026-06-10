#!/bin/sh
# Static prompt injection checks for shared assets.
# Spec: docs/prompt-injection-check.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/check_injection.rb" "$@"
