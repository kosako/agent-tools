#!/bin/sh
# skill の挙動の評価 (#369) の probe runner (実機)。
# case ごとに fixture を新しい temp project に置き、1 回の依頼を claude / codex の headless 実行に流して、
# model が tool に求めた操作の区分と run の後の差分を results.json に書く。
# Spec: docs/skill-behavior-eval.md
# 依存: macOS 標準 Ruby + 観測対象の CLI (claude / codex) と network。CI では実行しない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/probe_skill_behavior.rb" "$@"
