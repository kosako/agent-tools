#!/bin/sh
# generated artifacts の tool directories への反映 (default: dry-run)。
# Spec: docs/sync-policy.md, docs/status-manifest-contract.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/sync.rb" "$@"
