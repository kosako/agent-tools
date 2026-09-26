#!/bin/sh
# OpenCode plugin probe の runner (実機・#295 PR 0)。
# 隔離した tmp の HOME / XDG で opencode を起動し、計測用 plugin と mock provider で PR 1〜3 の
# 前提 (M1〜M20) を観測して、raw の記録と summary を --out に書く。
# Spec: docs/opencode-plugin-probe.md
# 依存: macOS 標準 Ruby + opencode CLI と network (起動時の npm install)。CI では実行しない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/probe_opencode_plugin.rb" "$@"
