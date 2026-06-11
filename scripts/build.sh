#!/bin/sh
# shared source assets から tool 別 artifacts を generated/ に生成する。
# Spec: adapters/<tool>/README.md, docs/status-manifest-contract.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/build.rb" "$@"
