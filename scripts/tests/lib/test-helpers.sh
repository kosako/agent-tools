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

# boilerplate な asset manifest (低 risk・valid 固定) を既定 layout で書く。
# summary: 等の末尾追加行が要る呼び出しは、直前の行で WAM_EXTRA を設定する
# (この関数が 1 回の呼び出しで消費して unset する。未設定/空なら何も追記しない)。
# 使い方: write_asset_manifest <file> <name> <kind> <visibility> <src_path> <src_format> <target>...
write_asset_manifest() {
  wam_file=$1
  wam_name=$2
  wam_kind=$3
  wam_visibility=$4
  wam_path=$5
  wam_format=$6
  shift 6
  {
    printf 'schema_version: 1\n'
    printf 'name: %s\n' "$wam_name"
    printf 'kind: %s\n' "$wam_kind"
    printf 'visibility: %s\n' "$wam_visibility"
    printf 'targets:\n'
    for wam_target in "$@"; do
      printf '  - %s\n' "$wam_target"
    done
    printf 'risk:\n'
    printf '  prompt_injection: low\n'
    printf '  privacy: low\n'
    printf 'source:\n'
    printf '  path: %s\n' "$wam_path"
    printf '  format: %s\n' "$wam_format"
    if [ -n "${WAM_EXTRA:-}" ]; then
      printf '%s\n' "$WAM_EXTRA"
    fi
  } > "$wam_file"
  unset WAM_EXTRA
}

# 現内容の build_id を bid で計算し、human_review: approved な script asset の manifest を
# 現行 fixture と同形式 (review ブロックが source より前) で書く。manifest の置き場所は
# <root>/<rel_src の .sh を .asset.yml に替えた path>。
# 使い方: write_approved_script_manifest <root> <rel_src> <name> <visibility> <target>...
write_approved_script_manifest() {
  wasm_root=$1
  wasm_src=$2
  wasm_name=$3
  wasm_visibility=$4
  shift 4
  wasm_bid=$(bid "$wasm_root" "$wasm_src" text)
  {
    printf 'schema_version: 1\n'
    printf 'name: %s\n' "$wasm_name"
    printf 'kind: script\n'
    printf 'visibility: %s\n' "$wasm_visibility"
    printf 'targets:\n'
    for wasm_target in "$@"; do
      printf '  - %s\n' "$wasm_target"
    done
    printf 'risk:\n'
    printf '  prompt_injection: low\n'
    printf '  privacy: low\n'
    printf 'review:\n'
    printf '  human_review: approved\n'
    printf '  approved_build_id: %s\n' "$wasm_bid"
    printf '  approved_artifact_kind: script\n'
    printf 'source:\n'
    printf '  path: %s\n' "$wasm_src"
    printf '  format: text\n'
  } > "$wasm_root/${wasm_src%.sh}.asset.yml"
}

# demo 用 fixture repo を組み立てる: shared/<category>/<name>.md (body は残余引数を
# 1 行ずつ出力) + boilerplate manifest (write_asset_manifest / targets は codex + claude-code
# 固定。違う targets の fixture は write_asset_manifest を直接使う)。summary 行が要る suite は
# 直前の行で WAM_EXTRA を設定する (write_asset_manifest が消費)。fake home の mkdir は
# suite ごとに異なり root から導出できないため含めない (呼び出し側で行う)。
# 使い方: make_demo_repo <root> <category> <name> <kind> <body_line>...
make_demo_repo() {
  mdr_root=$1
  mdr_category=$2
  mdr_name=$3
  mdr_kind=$4
  shift 4
  mkdir -p "$mdr_root/shared/$mdr_category"
  for mdr_line in "$@"; do
    printf '%s\n' "$mdr_line"
  done > "$mdr_root/shared/$mdr_category/$mdr_name.md"
  write_asset_manifest "$mdr_root/shared/$mdr_category/$mdr_name.asset.yml" \
    "$mdr_name" "$mdr_kind" public "shared/$mdr_category/$mdr_name.md" markdown \
    codex claude-code
}

# repo root (scripts/tests/ の 2 つ上)。実 repo を対象にする case が使う。
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
