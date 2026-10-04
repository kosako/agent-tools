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

# skill に解決される単一 file の source を、frontmatter つきで書く。name は file 名から .md を除いたもの
# (manifest の name と一致させる)。build は frontmatter を生成せず source をそのまま配り、Codex に配る
# skill は frontmatter (name と description) が必須のため (#376)。本文は残余引数を 1 行ずつ出力する。
# 使い方: write_skill_source <file> <body_line>...
write_skill_source() {
  wss_file=$1
  shift
  wss_name=$(basename "$wss_file" .md)
  {
    printf -- '---\nname: %s\ndescription: demo %s\n---\n\n' "$wss_name" "$wss_name"
    for wss_line in "$@"; do
      printf '%s\n' "$wss_line"
    done
  } > "$wss_file"
}

# demo 用 fixture repo を組み立てる: shared/<category>/<name>.md (body は残余引数を
# 1 行ずつ出力) + boilerplate manifest (write_asset_manifest / targets は codex + claude-code
# 固定。違う targets の fixture は write_asset_manifest を直接使う)。summary 行が要る suite は
# 直前の行で WAM_EXTRA を設定する (write_asset_manifest が消費)。fake home の mkdir は
# suite ごとに異なり root から導出できないため含めない (呼び出し側で行う)。
# skill に解決される kind (skill / workflow / prompt / template) は write_skill_source で frontmatter つきに書く (#376)。
# 使い方: make_demo_repo <root> <category> <name> <kind> <body_line>...
make_demo_repo() {
  mdr_root=$1
  mdr_category=$2
  mdr_name=$3
  mdr_kind=$4
  shift 4
  mkdir -p "$mdr_root/shared/$mdr_category"
  case $mdr_kind in
    skill|workflow|prompt|template) write_skill_source "$mdr_root/shared/$mdr_category/$mdr_name.md" "$@" ;;
    *)
      for mdr_line in "$@"; do
        printf '%s\n' "$mdr_line"
      done > "$mdr_root/shared/$mdr_category/$mdr_name.md" ;;
  esac
  write_asset_manifest "$mdr_root/shared/$mdr_category/$mdr_name.asset.yml" \
    "$mdr_name" "$mdr_kind" public "shared/$mdr_category/$mdr_name.md" markdown \
    codex claude-code
}

# dir の下の中身 (相対 path・mode・file の内容の sha256) を 1 行ずつ出す。前後で比べて、dir の中が
# 変わっていない (消えていない・書き換わっていない・mode が変わっていない) ことを確かめるのに使う。
# 使い方: tree_snapshot <dir>
tree_snapshot() {
  ruby -rdigest -e '
    root = ARGV[0]
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
      next if %w[. ..].include?(File.basename(path))
      stat = File.lstat(path)
      digest = stat.file? ? Digest::SHA256.file(path).hexdigest : "-"
      puts [path[root.length..-1], stat.mode.to_s(8), digest].join(" ")
    end
  ' "$1"
}

# 書き込み先を安全に書き換えられないとき、command (build / register) が書かずに止まることを確かめる (#386)。
# 見るのは 3 つ: 辿りうる先 (<outside>、fixture の root の外の dir) の中が変わらない、exit 1、
# 出力に理由の行 (<fail の行>、そのままの文字列) が出る。作業用の file は <outside> の隣
# (<outside>.before / .after / .out) に置く。
# 使い方: expect_output_stop <label> <outside> <fail の行> <command>...
expect_output_stop() {
  eos_label=$1
  eos_outside=$2
  eos_reason=$3
  shift 3
  tree_snapshot "$eos_outside" > "$eos_outside.before"
  eos_status=0
  "$@" > "$eos_outside.out" 2>&1 || eos_status=$?
  tree_snapshot "$eos_outside" > "$eos_outside.after"
  cmp -s "$eos_outside.before" "$eos_outside.after" \
    || fail "$eos_label: files outside generated/ must not change: $(diff "$eos_outside.before" "$eos_outside.after" || true); output: $(cat "$eos_outside.out")"
  [ "$eos_status" -eq 1 ] \
    || fail "$eos_label: must stop with exit 1, got $eos_status: $(cat "$eos_outside.out")"
  grep -qF "$eos_reason" "$eos_outside.out" \
    || fail "$eos_label: missing the reason '$eos_reason': $(cat "$eos_outside.out")"
}

# 出力の経路に symlink があるときの expect_output_stop。理由は symlink の要素と出力の path (repo 相対)。
# 使い方: expect_output_symlink_stop <label> <outside> <symlink の要素> <出力の path> <command>...
expect_output_symlink_stop() {
  eoss_label=$1
  eoss_outside=$2
  eoss_reason="fail: symlink at $3 in the output path $4; refusing to write or delete through it"
  shift 4
  expect_output_stop "$eoss_label" "$eoss_outside" "$eoss_reason" "$@"
}

# 単一 file の書き込み先が regular file でない (directory など) ときの expect_output_stop。
# 使い方: expect_output_not_file_stop <label> <outside> <出力の path> <command>...
expect_output_not_file_stop() {
  eonf_label=$1
  eonf_outside=$2
  eonf_reason="fail: output path $3 exists and is not a regular file; refusing to write through it"
  shift 3
  expect_output_stop "$eonf_label" "$eonf_outside" "$eonf_reason" "$@"
}

# Node の ESM 構文の自動判定 (型の宣言が無い .js を構文から ESM とみなす。22.7 / 20.19 から既定で on) を
# 切った NODE_OPTIONS の値 (既存の NODE_OPTIONS の後ろに flag を足したもの) を出す。判定の無い Node を
# 再現して、plugin の import がモジュール形式の明示だけで通ることを確かめるのに使う (#396)。この flag を
# NODE_OPTIONS で受け付けない Node では何も出さずに 1 を返す (呼び出し側は skip を明示する)。
# 使い方: if opts=$(node_options_without_detect_module); then NODE_OPTIONS=$opts node ...; else echo "skip: ..."; fi
node_options_without_detect_module() {
  nownd_opts="${NODE_OPTIONS:+$NODE_OPTIONS }--no-experimental-detect-module"
  NODE_OPTIONS=$nownd_opts node -e 0 >/dev/null 2>&1 || return 1
  printf '%s\n' "$nownd_opts"
}

# repo root (scripts/tests/ の 2 つ上)。実 repo を対象にする case が使う。
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
