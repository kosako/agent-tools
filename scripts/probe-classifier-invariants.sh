#!/bin/sh
# 分類器の不変条件の試行の入口 (#754)。
# 挙動の評価の分類器が read と区分した command を、隔離した一時 dir の中で走らせ、不変条件
# (fixture の tree を変えない、canary を走らせない) を確かめる。今ある入口は --preflight と --command。
# Spec: docs/classifier-invariants.md
# 依存: macOS 標準 Ruby と sandbox-exec。network は使わない。memory と時間の上限は、呼ぶ側が personal-safe-run で付ける。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/probe_classifier_invariants.rb" "$@"
