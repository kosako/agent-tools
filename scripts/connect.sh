#!/bin/sh
# instruction の所有ファイルを確立し、人間の instruction ファイルから繋ぎ込む。
# 人間のファイルに触る唯一の操作 (日常 build/sync は触らない)。
# Spec: docs/instruction-artifact-kind.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/connect.rb" "$@"
