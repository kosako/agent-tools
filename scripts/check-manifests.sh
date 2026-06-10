#!/bin/sh
# Static validation for sidecar asset manifests.
# Spec: docs/asset-manifest-schema.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/check_manifests.rb" "$@"
