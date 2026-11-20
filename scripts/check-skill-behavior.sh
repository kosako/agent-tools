#!/bin/sh
# skill の挙動の評価 (#369) の判定。probe-skill-behavior.sh が書いた results.json を case set と突き合わせ、
# run ごとに違反・評価不能・正例の達成を決める。network / CLI にはアクセスしない。
# Spec: docs/skill-behavior-eval.md
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/check_skill_behavior.rb" "$@"
