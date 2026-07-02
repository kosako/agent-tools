#!/bin/sh
# Credential 隔離 acceptance harness の判定コア。
# probe 結果 (JSON) を受け、隔離が破れていないか判定する。
# Spec: docs/credential-isolation-acceptance.md
# 依存: macOS 標準 Ruby のみ。network access なし (判定のみ。probe 実行は別・実機)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/check_credential_isolation.rb" "$@"
