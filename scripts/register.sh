#!/bin/sh
# shared assets を検証し、generated/catalog.json に登録状態を記録する。
# Spec: docs/register-catalog.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/register.rb" "$@"
