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
common=""   # build/register/connect/sync 共通 (--root, --quiet)
homes=""    # connect/sync 専用 (--codex-home, --claude-home)

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply="--apply" ;;
    --root) [ $# -ge 2 ] || { usage >&2; exit 2; }; common="$common --root $2"; shift ;;
    --quiet) common="$common --quiet" ;;
    --codex-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; homes="$homes --codex-home $2"; shift ;;
    --claude-home) [ $# -ge 2 ] || { usage >&2; exit 2; }; homes="$homes --claude-home $2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# sub-script へ語分割で引数を渡すため、$common / $homes / $apply は意図的に unquoted。
# shellcheck disable=SC2086

echo "==> build"
"$script_dir/build.sh" $common

echo "==> register"
# register は human_review 待ちがあると exit 3 を返す。これは致命ではない
# (catalog は書かれ、sync は registered のものだけ配置する) ので継続する。
# build の gate fail (1) や他の異常はそのまま伝播させる。
register_rc=0
"$script_dir/register.sh" $common || register_rc=$?
if [ "$register_rc" -ne 0 ] && [ "$register_rc" -ne 3 ]; then
  exit "$register_rc"
fi
[ "$register_rc" -eq 3 ] && echo "note: human review 待ちの asset があります (registered のものだけ配置されます)"

echo "==> connect${apply:+ (apply)}"
"$script_dir/connect.sh" $common $homes $apply

echo "==> sync${apply:+ (apply)}"
"$script_dir/sync.sh" $common $homes $apply

if [ -z "$apply" ]; then
  echo
  echo "dry-run のみ・実環境には書き込んでいません。反映するには --apply を付けて再実行してください。"
fi
