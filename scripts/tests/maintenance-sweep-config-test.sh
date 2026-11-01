#!/bin/sh
# personal-maintenance-sweep の local の設定を読む block (BUDGET.md の「## 設定 (local)」の節。#572) の self-test。
# 節の中の sh の block (`maintenance-sweep.json` を読むもの) を切り出し、XDG_CONFIG_HOME を差し替えて当てる。
# - file の entry が無い (親の dir が無いときも) = 既定値で exit 0
# - file か、辿れる symlink の先の file = その値で exit 0 (途中の dir の symlink を辿るときも)
# - entry は在るのに指す先が無い symlink・途中の dir (XDG_CONFIG_HOME 自体を含む) が指す先の無い symlink・regular file
#   でない・JSON として読めない・在ると確かめた後に読む間に消えた = exit 2 で理由を stderr に出し、stdout は空 (既定値に
#   倒さない)。読む間に消えた競合は、File.read だけを ENOENT にする stub を RUBYOPT で読み込ませて作る (#609 の review)
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
sweep_dir=${1:-"$script_dir/../../shared/skills/personal-maintenance-sweep"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# RUBYOPT は空白で区切られるので、空白を含む path は渡せない。
case $tmp in
  *[[:space:]]*) fail "一時 directory の path に空白がある: $tmp" ;;
esac

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

mkdir "$tmp/lib"
cat > "$tmp/lib/read_enoent.rb" <<'RUBY'
# FAKE_READ_ENOENT の path の File.read だけを ENOENT にする (lstat と stat の後に file が消えた競合の代わり)。
if ENV["FAKE_READ_ENOENT"].to_s != ""
  class << File
    alias_method :__fake_orig_read, :read
    def read(*args)
      raise Errno::ENOENT, "fake" if args.first.to_s == ENV["FAKE_READ_ENOENT"]

      __fake_orig_read(*args)
    end
  end
end
RUBY

# $1 = XDG_CONFIG_HOME。exit code を返し、stdout と stderr を $tmp/out と $tmp/err に残す。RB_OPT / RB_ENOENT を
# RUBYOPT / FAKE_READ_ENOENT に渡す (空なら stub は効かない)。
run_block() {
  set +e
  XDG_CONFIG_HOME=$1 RUBYOPT="${RB_OPT-}" FAKE_READ_ENOENT="${RB_ENOENT-}" sh "$tmp/block.sh" >"$tmp/out" 2>"$tmp/err"
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

# 在ると確かめた後に読む間に消えた: 設定なしにせず止める (#609 の review)
RB_OPT="-r$tmp/lib/read_enoent.rb"
RB_ENOENT="$tmp/real/agent-tools/maintenance-sweep.json"
expect_stop "読む間に消えた" "$tmp/real" "読む間に消えた"
RB_ENOENT="$tmp/filelink/agent-tools/maintenance-sweep.json"
expect_stop "symlink の先を読む間に消えた" "$tmp/filelink" "読む間に消えた"
# stub は対象の path の外では効かない (stub 自体の確かめ)
RB_ENOENT="$tmp/no-such-target"
expect_ok "stub は対象の外では読む" "$tmp/real" 0
RB_OPT=
RB_ENOENT=

echo "ok: maintenance-sweep-config"
