#!/bin/sh
# skill routing acceptance harness の判定コア (#280)。
# case set と probe 結果 (JSON) を受け、routing が破れていないか (must_not violation /
# baseline からの回帰) を判定し、token 使用量を報告する。
# Spec: docs/skill-routing-acceptance.md
# 依存: macOS 標準 Ruby のみ。network access なし (判定のみ。probe 実行は別・実機)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/check_skill_routing.rb" "$@"
