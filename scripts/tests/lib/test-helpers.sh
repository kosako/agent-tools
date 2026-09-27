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

# 値を POSIX shell の literal (値全体を ' で囲み、内側の ' を '\'' に置換) にして出す。
# test が生成する shim / fake command / sourced config の中へ runtime の path
# ($tmp や deploy dir) を埋めるときに使う (#272)。生成時の printf / heredoc の引用は
# 生成物が実行時に再解釈されることを防がない: 二重引用のまま埋めると、path に
# 含まれる $( ) やバッククォートは shim を実行した時点で評価される。
# 使い方: printf '... %s ...' "$(shq "$path")"  /  lit=$(shq "$path") を heredoc に展開
shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
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

# 現内容の build_id を bid で計算し、human_review: approved な単一ファイル (format: text) asset の
# manifest を現行 fixture と同形式 (review ブロックが source より前) で書く。承認は
# (approved_build_id, approved_artifact_kind = kind) の対。manifest の置き場所は
# <root>/<rel_src の拡張子を .asset.yml に替えた path> (.sh / .js の sidecar 規約)。
# 使い方: write_approved_manifest <root> <rel_src> <name> <kind> <visibility> <target>...
write_approved_manifest() {
  wapm_root=$1
  wapm_src=$2
  wapm_name=$3
  wapm_kind=$4
  wapm_visibility=$5
  shift 5
  wapm_bid=$(bid "$wapm_root" "$wapm_src" text)
  {
    printf 'schema_version: 1\n'
    printf 'name: %s\n' "$wapm_name"
    printf 'kind: %s\n' "$wapm_kind"
    printf 'visibility: %s\n' "$wapm_visibility"
    printf 'targets:\n'
    for wapm_target in "$@"; do
      printf '  - %s\n' "$wapm_target"
    done
    printf 'risk:\n'
    printf '  prompt_injection: low\n'
    printf '  privacy: low\n'
    printf 'review:\n'
    printf '  human_review: approved\n'
    printf '  approved_build_id: %s\n' "$wapm_bid"
    printf '  approved_artifact_kind: %s\n' "$wapm_kind"
    printf 'source:\n'
    printf '  path: %s\n' "$wapm_src"
    printf '  format: text\n'
  } > "$wapm_root/${wapm_src%.*}.asset.yml"
}

# write_approved_manifest の script 版 (kind: script。既存 suite の呼び出し形を保つ)。
# 使い方: write_approved_script_manifest <root> <rel_src> <name> <visibility> <target>...
write_approved_script_manifest() {
  wasm_root=$1
  wasm_src=$2
  wasm_name=$3
  wasm_visibility=$4
  shift 4
  write_approved_manifest "$wasm_root" "$wasm_src" "$wasm_name" script "$wasm_visibility" "$@"
}

# write_approved_manifest の plugin 版 (kind: plugin、target は opencode 固定: plugin の配布先は
# opencode だけ, #295)。source は shared/plugins/<name>.js。
# 使い方: write_approved_plugin_manifest <root> <name> <visibility>
write_approved_plugin_manifest() {
  write_approved_manifest "$1" "shared/plugins/$2.js" "$2" plugin "$3" opencode
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
