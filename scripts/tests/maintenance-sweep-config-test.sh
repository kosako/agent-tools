#!/bin/sh
# personal-maintenance-sweep の local の設定を読む block (BUDGET.md の「## 設定 (local)」の節。#572) の self-test。
# 節の中の sh の block (`maintenance-sweep.json` を読むもの) を切り出し、XDG_CONFIG_HOME を差し替えて当てる。
# - file の entry が無い (親の dir が無いときも) = 既定値で exit 0
# - file か、辿れる symlink の先の file = その値で exit 0 (途中の dir の symlink を辿るときも)
# - entry は在るのに指す先が無い symlink・途中の dir (XDG_CONFIG_HOME 自体を含む) が指す先の無い symlink・regular file
#   でない・JSON として読めない = exit 2 で理由を stderr に出し、stdout は空 (既定値に倒さない)
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
sweep_dir=${1:-"$script_dir/../../shared/skills/personal-maintenance-sweep"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby - "$sweep_dir/BUDGET.md" "$tmp/block.sh" <<'RUBY'
src, out = ARGV
text = File.read(src, encoding: "UTF-8")
section = text[/^## 設定 \(local\)\n(.*?)(?=^## )/m, 1]
abort "BUDGET.md に「## 設定 (local)」の節が無い" unless section
blocks = section.scan(/^```sh\n(.*?)^```/m).flatten
picked = blocks.select { |b| b.include?("maintenance-sweep.json") }
abort "設定の節に設定を読む sh の block が 1 つでない (#{picked.size} 個)" unless picked.size == 1
File.write(out, picked.first)
RUBY

# $1 = XDG_CONFIG_HOME。exit code を返し、stdout と stderr を $tmp/out と $tmp/err に残す。
run_block() {
  set +e
  XDG_CONFIG_HOME=$1 sh "$tmp/block.sh" >"$tmp/out" 2>"$tmp/err"
  rb_rc=$?
  set -e
  return "$rb_rc"
}

# $1 = label、$2 = XDG_CONFIG_HOME、$3 = 期待する fix_cap
expect_ok() {
  run_block "$2" || fail "$1: exit 0 のはず (rc=$?): $(cat "$tmp/err")"
  got=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["fix_cap"]' "$tmp/out") || fail "$1: 出力が JSON でない: $(cat "$tmp/out")"
  [ "$got" = "$3" ] || fail "$1: fix_cap は $3 のはず (got=$got)"
  [ ! -s "$tmp/err" ] || fail "$1: stderr は空のはず: $(cat "$tmp/err")"
}

# $1 = label、$2 = XDG_CONFIG_HOME、$3 = stderr に含む文言
expect_stop() {
  if run_block "$2"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 2 ] || fail "$1: exit 2 のはず (rc=$rc): $(cat "$tmp/out")"
  [ ! -s "$tmp/out" ] || fail "$1: stdout は空のはず (既定値に倒さない): $(cat "$tmp/out")"
  grep -qF "$3" "$tmp/err" || fail "$1: stderr に「$3」が無い: $(cat "$tmp/err")"
}

mkdir -p "$tmp/real/agent-tools"
printf '%s\n' '{"fix_cap":0}' > "$tmp/real/agent-tools/maintenance-sweep.json"

# entry が無い: 既定値
mkdir -p "$tmp/empty"
expect_ok "agent-tools の dir が無い" "$tmp/empty" 2
mkdir -p "$tmp/emptydir/agent-tools"
expect_ok "file が無い" "$tmp/emptydir" 2

# file と、辿れる symlink
expect_ok "file を読む" "$tmp/real" 0
mkdir -p "$tmp/filelink/agent-tools"
ln -s "$tmp/real/agent-tools/maintenance-sweep.json" "$tmp/filelink/agent-tools/maintenance-sweep.json"
expect_ok "file の symlink を辿る" "$tmp/filelink" 0
mkdir -p "$tmp/dirlink"
ln -s "$tmp/real/agent-tools" "$tmp/dirlink/agent-tools"
expect_ok "途中の dir の symlink を辿る" "$tmp/dirlink" 0

# 指す先の無い symlink: 止める (#572)
mkdir -p "$tmp/danglingfile/agent-tools"
ln -s "$tmp/no-such-file.json" "$tmp/danglingfile/agent-tools/maintenance-sweep.json"
expect_stop "file の symlink に指す先が無い" "$tmp/danglingfile" "symlink に指す先が無い"
mkdir -p "$tmp/danglingdir"
ln -s "$tmp/no-such-dir" "$tmp/danglingdir/agent-tools"
expect_stop "agent-tools の dir の symlink に指す先が無い" "$tmp/danglingdir" "場所の途中の symlink に指す先が無い"
ln -s "$tmp/no-such-home" "$tmp/danglinghome"
expect_stop "XDG_CONFIG_HOME の symlink に指す先が無い" "$tmp/danglinghome" "場所の途中の symlink に指す先が無い"

# 今までの不正も止める
mkdir -p "$tmp/notfile/agent-tools/maintenance-sweep.json"
expect_stop "regular file でない" "$tmp/notfile" "regular file でない"
mkdir -p "$tmp/badjson/agent-tools"
printf '%s\n' '{' > "$tmp/badjson/agent-tools/maintenance-sweep.json"
expect_stop "JSON として読めない" "$tmp/badjson" "JSON として読めない"

echo "ok: maintenance-sweep-config"
