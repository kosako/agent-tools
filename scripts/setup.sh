#!/bin/sh
# build → register → connect → sync を一括実行する一発 setup。
# 既定は dry-run (connect/sync は plan 表示のみ・tool home に書き込まない。
# build/register は dry-run でも generated/ と catalog を更新する)。
# 実環境へ反映するには --apply を付ける。初回 install と更新の両方に使える
# (connect は冪等なので毎回通して無害)。
# Spec: docs/install-and-usage.md
# 依存: macOS 標準 Ruby のみ。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: setup.sh [--apply] [--root DIR] [--codex-home DIR] [--claude-home DIR] [--opencode-home DIR] [--quiet]"
  echo "  build → register → connect → sync を通しで実行する。"
  echo "  既定は dry-run (tool home には書き込まない。generated/ と catalog は毎回更新する)。"
  echo "  --apply で connect/sync を実環境 (tool home) に反映する。"
}

apply=""
root=""
quiet=""
codex_home=""
claude_home=""
opencode_home=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --root) [ $# -ge 2 ] || { usage >&2; exit 2; }; root=$2; shift ;;
    --quiet) quiet=1 ;;
    --codex-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; codex_home=$2; shift ;;
    --claude-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; claude_home=$2; shift ;;
    --opencode-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; opencode_home=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# 各 sub-script を、正しく quote された引数で呼ぶ。文字列連結 + 語分割は path に
# 空白 (例: "Application Support") や glob 文字が入ると壊れるため使わない。
# set -- で positional params を組み立て "$@" で渡す (POSIX sh で配列の代替)。
# with_opencode_home は sync だけ 1 にする: connect は instruction を配らない opencode の home を
# 受け取らない (--opencode-home を渡すと unknown option で exit 2, #295)。
#   run <script> <with_homes:0|1> <with_opencode_home:0|1> <with_apply:0|1>
run() {
  _script=$1
  _with_homes=$2
  _with_opencode_home=$3
  _with_apply=$4
  set --
  [ -n "$root" ] && set -- "$@" --root "$root"
  [ -n "$quiet" ] && set -- "$@" --quiet
  if [ "$_with_homes" = 1 ]; then
    [ -n "$codex_home" ] && set -- "$@" --codex-home "$codex_home"
    [ -n "$claude_home" ] && set -- "$@" --claude-home "$claude_home"
  fi
  [ "$_with_opencode_home" = 1 ] && [ -n "$opencode_home" ] && set -- "$@" --opencode-home "$opencode_home"
  [ "$_with_apply" = 1 ] && [ -n "$apply" ] && set -- "$@" --apply
  "$script_dir/$_script" "$@"
}

echo "==> build"
run build.sh 0 0 0

echo "==> register"
# register は human_review 待ちがあると exit 3 を返す。これは致命ではない
# (catalog は書かれ、sync は registered のものだけ配置する) ので継続する。
# build の gate fail (1) や他の異常はそのまま伝播させる。
register_rc=0
run register.sh 0 0 0 || register_rc=$?
if [ "$register_rc" -ne 0 ] && [ "$register_rc" -ne 3 ]; then
  exit "$register_rc"
fi
[ "$register_rc" -eq 3 ] && echo "note: human review 待ちの asset があります (registered のものだけ配置されます)"

echo "==> connect${apply:+ (apply)}"
run connect.sh 1 0 1

echo "==> sync${apply:+ (apply)}"
run sync.sh 1 1 1

if [ -z "$apply" ]; then
  echo
  echo "dry-run のみ・実環境には書き込んでいません。反映するには --apply を付けて再実行してください。"
fi
