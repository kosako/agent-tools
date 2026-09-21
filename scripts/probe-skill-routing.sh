#!/bin/sh
# skill routing acceptance harness の probe runner (実機・#280)。
# 候補 skill だけが見える隔離 project で claude / codex を headless 実行し、どの skill が発火したかと
# token 使用量を観測して results.json を書く。判定は check-skill-routing.sh。
# Spec: docs/skill-routing-acceptance.md
# 依存: macOS 標準 Ruby + 観測対象の CLI (claude / codex) と network。CI では実行しない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/probe_skill_routing.rb" "$@"
