#!/bin/sh
# 参照先 note (.agent-context.local.md) を読む前の条件の検査の command を、一時 repo で実際に走らせて確かめる (#390)。
# - personal-resume-project の SKILL.md の「### 1. 参照先を確認する」の節にある sh の code block (1 つ) を
#   切り出し、sh と zsh で走らせる。
# - note が無い → absent / untracked な regular file → ok / 同じ名前で tracked → reject /
#   大文字小文字だけ違う名前で tracked → reject / symlink → reject / git 管理外の directory → reject /
#   index を読めない → reject / 環境に GIT_LITERAL_PATHSPECS があっても tracked なら reject。
# - 大文字小文字だけ違う名前の case は、大文字小文字を区別しない file system (違う大文字小文字の名前で同じ
#   file を開ける) のときだけ意味があるので、そうでなければ skip を明示する。
# 引数で skill の directory か SKILL.md を差し替えられる (変異での確認用)。
# 実 HOME / 実 git config には触れない (HOME / XDG_CONFIG_HOME を一時 dir に向け、git は GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を隔離する)。commit はしない (tracked は index に載せるだけ)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

target=${1:-"$repo_root/shared/skills/personal-resume-project"}
if [ -d "$target" ]; then
  skill_md="$target/SKILL.md"
else
  skill_md=$target
fi
[ -f "$skill_md" ] || fail "missing $skill_md"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# git は repo の探索で実 path を使うので、GIT_CEILING_DIRECTORIES と揃えるために symlink を解決しておく。
tmp=$(CDPATH= cd -- "$tmp" && pwd -P)

# ---- 検査の command の切り出し ---------------------------------------------------
ruby - "$skill_md" "$tmp/check-block.sh" <<'RUBY'
skill_md, out = ARGV.fetch(0), ARGV.fetch(1)
heading = "### 1. 参照先を確認する"

# 見出しの行から、同じか上の level の次の見出しまで (code block の中の行は見出しとみなさない)。
lines = File.read(skill_md, encoding: "UTF-8").lines
start = lines.index { |l| l.chomp == heading }
abort "FAIL: context-note-check: #{skill_md} に「#{heading}」の節が無い" unless start
level = heading[/\A#+/].size
fence = false
body = []
lines[(start + 1)..-1].each do |l|
  fence = !fence if l =~ /\A\s*```/
  break if !fence && l =~ /\A(#+) / && $1.size <= level
  body << l
end

blocks = []
cur = nil
body.each do |l|
  if cur.nil? && l =~ /\A```sh\s*\z/
    cur = []
  elsif cur && l =~ /\A```\s*\z/
    blocks << cur.join
    cur = nil
  elsif cur
    cur << l
  end
end
unless blocks.size == 1
  abort "FAIL: context-note-check: 「#{heading}」の節に sh の code block が 1 つでない (#{blocks.size} 個)"
end
unless blocks.first.include?(".agent-context.local.md")
  abort "FAIL: context-note-check: 検査の command が .agent-context.local.md を見ていない"
end
File.write(out, blocks.first)
RUBY

# ---- 環境の隔離 ---------------------------------------------------------------
HOME="$tmp/home"
XDG_CONFIG_HOME="$HOME/.config"
export HOME XDG_CONFIG_HOME
mkdir -p "$XDG_CONFIG_HOME"
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
# repository や pathspec の解釈を変える環境変数が継承されていると、temp repo の結果にならない。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
# git 管理外の directory の case で、$tmp より上の repo を見つけないようにする。
GIT_CEILING_DIRECTORIES=$tmp
export GIT_CEILING_DIRECTORIES

note=.agent-context.local.md
variant=.AGENT-context.local.md

# 大文字小文字を区別しない file system か (違う大文字小文字の名前で同じ file を開けるか)。
mkdir "$tmp/fs-probe"
printf 'probe\n' > "$tmp/fs-probe/$variant"
if [ -f "$tmp/fs-probe/$note" ]; then
  icase_fs=1
else
  icase_fs=0
fi

# 新しい空の repo を作り、path を repo に入れる。
n=0
new_repo() {
  n=$((n + 1))
  repo="$tmp/repo$n"
  git init -q "$repo"
}

# 切り出した command を $shell_argv で $1 の directory から走らせ、exit code を rc に、stdout を $tmp/out に
# 入れる。残りの引数は env に渡す追加の環境変数 (NAME=value)。
run_check() {
  rc_dir=$1
  shift
  rc=0
  # shell_argv は下の case で決めた定数 (sh / zsh -f) なので、分割して渡す。
  # shellcheck disable=SC2086
  (cd "$rc_dir" && env -u BASH_ENV -u ENV "$@" $shell_argv "$tmp/check-block.sh") \
    > "$tmp/out" 2> "$tmp/err" || rc=$?
}

# 直前の run_check の結果が、exit 0 で 1 行の $1 であることを確かめる。$2 = case の説明。
expect() {
  [ "$rc" -eq 0 ] || fail "[$shell] $2: 検査の command が exit 0 でない (rc=$rc): $(cat "$tmp/err")"
  got=$(cat "$tmp/out")
  [ "$got" = "$1" ] || fail "[$shell] $2: 出力が $1 でない (出力: $got)"
}

ran=0
for shell in sh zsh; do
  command -v "$shell" > /dev/null 2>&1 || continue
  case $shell in
    zsh) shell_argv='zsh -f' ;;
    *) shell_argv=sh ;;
  esac
  ran=$((ran + 1))

  # (a) note が無い。
  new_repo
  run_check "$repo"
  expect absent "note が無い"

  # (b) untracked な regular file。
  new_repo
  printf 'note\n' > "$repo/$note"
  run_check "$repo"
  expect ok "untracked な regular file"

  # (c) 同じ名前で tracked (index に載せるだけ)。
  git -C "$repo" add -- "$note"
  run_check "$repo"
  expect reject "同じ名前で tracked"

  # (d) 大文字小文字だけ違う名前で tracked (大文字小文字を区別しない file system のときだけ)。
  if [ "$icase_fs" -eq 1 ]; then
    new_repo
    printf 'variant\n' > "$repo/$variant"
    git -C "$repo" add -- "$variant"
    [ -f "$repo/$note" ] || fail "[$shell] 大文字小文字だけ違う名前の file を $note として開けない (前提が崩れた)"
    run_check "$repo"
    expect reject "大文字小文字だけ違う名前で tracked (照合が大文字小文字を区別している)"
  fi

  # (e) symlink (先は repo の外の regular file)。
  new_repo
  printf 'target\n' > "$tmp/link-target.md"
  ln -s "$tmp/link-target.md" "$repo/$note"
  run_check "$repo"
  expect reject "symlink"

  # (f) git 管理外の directory (note の regular file はある)。
  mkdir -p "$tmp/nogit"
  printf 'note\n' > "$tmp/nogit/$note"
  run_check "$tmp/nogit"
  expect reject "git 管理外の directory"

  # (g) index を読めない (git ls-files が exit 128)。
  new_repo
  printf 'note\n' > "$repo/$note"
  printf 'broken' > "$repo/.git/index"
  run_check "$repo"
  expect reject "index を読めない"

  # (h) 環境に GIT_LITERAL_PATHSPECS があっても、tracked なら reject (pathspec の指定が無効にならない)。
  new_repo
  printf 'note\n' > "$repo/$note"
  git -C "$repo" add -- "$note"
  run_check "$repo" GIT_LITERAL_PATHSPECS=1
  expect reject "環境に GIT_LITERAL_PATHSPECS=1 があるときの同じ名前で tracked"
done
[ "$ran" -gt 0 ] || fail "検査の command を走らせる shell (sh / zsh) が無い"

if [ "$icase_fs" -ne 1 ]; then
  echo "skip: 大文字小文字だけ違う名前で tracked の case (file system が大文字小文字を区別する)"
fi
echo "ok: context-note-check"
