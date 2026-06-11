#!/bin/sh
# report-only status。dotfiles が読める contract JSON を出力する。
# Spec: docs/status-manifest-contract.md
# 依存: macOS 標準 Ruby のみ。network access なし。state を変更しない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/status.rb" "$@"
