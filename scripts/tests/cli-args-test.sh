#!/bin/sh
# 8 entrypoint の CLI 引数処理の characterization test (#192)。
# Cli helper への共通化 (scripts/lib/cli.rb) が守るべき現行挙動を先に固定する:
#   1. 未知 option: stderr に "unknown option: <arg>" + usage を stdout + exit 2
#   2. value flag の値欠落 (argv 枯渇): unknown 行なしで usage を stdout + exit 2
#   3. -h / --help: usage を stdout + exit 0
#   4. --help の後の token は読まない (--help --bogus でも exit 0)
# いずれも repo 状態に依存しない parse 段の挙動なので、cwd は空 tmp で走らせる。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# value flag を持つ全 entrypoint (--root は共通の value flag)。
COMMANDS="sync connect status doctor build register check-manifests check-injection"

for cmd in $COMMANDS; do
  bin="$script_dir/../$cmd.sh"

  # --- 1: 未知 option → stderr に unknown option + stdout に usage + exit 2 ---
  status=0
  (cd "$tmp" && "$bin" --bogus-flag > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 2 ] || fail "$cmd: unknown option should exit 2, got $status"
  grep -q "unknown option: --bogus-flag" "$tmp/err" \
    || fail "$cmd: missing unknown-option line on stderr: $(cat "$tmp/err")"
  grep -q "^usage:" "$tmp/out" || fail "$cmd: usage should go to stdout: $(cat "$tmp/out")"

  # --- 2: value flag の値欠落 → unknown 行なしで usage + exit 2 ---
  status=0
  (cd "$tmp" && "$bin" --root > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 2 ] || fail "$cmd: missing value should exit 2, got $status"
  grep -q "^usage:" "$tmp/out" || fail "$cmd: missing-value usage should go to stdout"
  if grep -q "unknown option" "$tmp/err"; then
    fail "$cmd: missing value must not report unknown option: $(cat "$tmp/err")"
  fi

  # --- 3: -h / --help → usage + exit 0 ---
  for flag in -h --help; do
    status=0
    (cd "$tmp" && "$bin" "$flag" > "$tmp/out" 2> "$tmp/err") || status=$?
    [ "$status" -eq 0 ] || fail "$cmd: $flag should exit 0, got $status"
    grep -q "^usage:" "$tmp/out" || fail "$cmd: $flag should print usage to stdout"
  done

  # --- 4: --help は以降の token を読まない ---
  status=0
  (cd "$tmp" && "$bin" --help --bogus-flag > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 0 ] || fail "$cmd: --help must short-circuit before --bogus-flag, got $status"
done

echo "ok: cli-args characterization test passed"
