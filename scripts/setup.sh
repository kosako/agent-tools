#!/bin/sh
# build → register → connect → sync を一括実行する一発 setup。
# 既定は dry-run (plan を表示するだけ・実環境に書き込まない)。
# 実環境へ反映するには --apply を付ける。初回 install と更新の両方に使える
# (connect は冪等なので毎回通して無害)。
# Spec: docs/install-and-usage.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: setup.sh [--apply] [--root DIR] [--codex-home DIR] [--claude-home DIR] [--quiet]"
  echo "  build → register → connect → sync を通しで実行する。"
  echo "  既定は dry-run (何も書き込まない)。--apply で connect/sync を実環境に反映する。"
}

apply=""
root=""
quiet=""
codex_home=""
claude_home=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --root) [ $# -ge 2 ] || { usage >&2; exit 2; }; root=$2; shift ;;
    --quiet) quiet=1 ;;
    --codex-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; codex_home=$2; shift ;;
    --claude-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; claude_home=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# 各 sub-script を、正しく quote された引数で呼ぶ。文字列連結 + 語分割は path に
# 空白 (例: "Application Support") や glob 文字が入ると壊れるため使わない。
# set -- で positional params を組み立て "$@" で渡す (POSIX sh で配列の代替)。
#   run <script> <with_homes:0|1> <with_apply:0|1>
run() {
  _script=$1
  _with_homes=$2
  _with_apply=$3
  set --
  [ -n "$root" ] && set -- "$@" --root "$root"
  [ -n "$quiet" ] && set -- "$@" --quiet
  if [ "$_with_homes" = 1 ]; then
    [ -n "$codex_home" ] && set -- "$@" --codex-home "$codex_home"
    [ -n "$claude_home" ] && set -- "$@" --claude-home "$claude_home"
  fi
  [ "$_with_apply" = 1 ] && [ -n "$apply" ] && set -- "$@" --apply
  "$script_dir/$_script" "$@"
}

echo "==> build"
run build.sh 0 0

echo "==> register"
# register は human_review 待ちがあると exit 3 を返す。これは致命ではない
# (catalog は書かれ、sync は registered のものだけ配置する) ので継続する。
# build の gate fail (1) や他の異常はそのまま伝播させる。
register_rc=0
run register.sh 0 0 || register_rc=$?
if [ "$register_rc" -ne 0 ] && [ "$register_rc" -ne 3 ]; then
  exit "$register_rc"
fi
[ "$register_rc" -eq 3 ] && echo "note: human review 待ちの asset があります (registered のものだけ配置されます)"

echo "==> connect${apply:+ (apply)}"
run connect.sh 1 1

echo "==> sync${apply:+ (apply)}"
run sync.sh 1 1

if [ -z "$apply" ]; then
  echo
  echo "dry-run のみ・実環境には書き込んでいません。反映するには --apply を付けて再実行してください。"
fi
