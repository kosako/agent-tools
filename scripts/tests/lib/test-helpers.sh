#!/bin/sh
# scripts/tests/*.sh が共有する test helpers。suite 側が script_dir を定義してから
#   . "$script_dir/lib/test-helpers.sh"
# で source する契約 (bid / repo_root は source 時・呼び出し時の $script_dir に依存する)。
# tests/lib/ 配下に置くのは、CI の `for t in scripts/tests/*.sh` (非再帰 glob) に
# helper 自身が test として拾われないようにするため。関数定義と repo_root の導出のみで、
# set オプションや trap は変更しない (POSIX sh)。

# テストを失敗させる。診断は stderr へ。
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# JSON file から dig で値を取り出して inspect 表記で出す (assert 用)。
# 使い方: jget <file> <key|index>...
jget() {
  ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig(*ARGV[1..-1].map { |k| k =~ /\A\d+\z/ ? k.to_i : k }).inspect' "$@"
}

# 実装と同じ計算で build_id を得る (approved_build_id 等の fixture 用)。
# 使い方: bid <root> <source_rel> <format>
bid() {
  ruby -r"$script_dir/../lib/build" -e 'puts Build.build_id_for(ARGV[0], ARGV[1], ARGV[2])' "$@"
}

# repo root (scripts/tests/ の 2 つ上)。実 repo を対象にする case が使う。
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
