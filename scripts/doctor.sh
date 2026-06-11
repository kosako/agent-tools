#!/bin/sh
# state を変更せず local environment assumptions を inspect する。
# 依存: macOS 標準 Ruby のみ。network access なし。read-only。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/doctor.rb" "$@"
