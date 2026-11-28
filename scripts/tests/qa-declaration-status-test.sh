#!/bin/sh
# personal-changed-scope-qa の読み取りの口 (--declaration-status、#815) の self-test。今の repo の qa_checks の宣言の
# 有無を 1 語で返すこと、stdin を読まないこと、知らない引数は stdin を読む前に exit 2 になること、設定の path と
# command を出さないこと、引数なしの Stop の入口が変わらないことを確かめる。case の ID は Issue #815 の期待値の表
# (E01〜E30) と同じ番号。設定と state は env で tmp に向け、実 HOME と実 config には触れない。
# 引数で hook の source を差し替えられる (変異での確認用): <changed-scope-qa.rb>
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

qa_src=${1:-"$repo_root/shared/scripts/personal-changed-scope-qa.rb"}
sr_src="$repo_root/shared/scripts/personal-safe-run.rb"
for f in "$qa_src" "$sr_src"; do
  [ -f "$f" ] || fail "missing $f"
done
real_ruby=$(ruby -rrbconfig -e 'print RbConfig.ruby')
safe_run=$sr_src

# canary は設定の path と command の両方に入れる (どの出力にも出てはいけない)
canary=CANARY815
tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$deploy" "$tmp/home" "$tmp/conf-$canary"
cp "$qa_src" "$deploy/personal-changed-scope-qa"
cp "$sr_src" "$deploy/personal-safe-run"
chmod +x "$deploy/personal-changed-scope-qa" "$deploy/personal-safe-run"
hook="$deploy/personal-changed-scope-qa"

GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

repo="$tmp/repo"
git init -q "$repo"
printf 'base\n' > "$repo/base.txt"
(cd "$repo" && git add base.txt && git commit -qm seed)
repo_real=$(ruby -e 'print File.realpath(ARGV[0])' -- "$repo")
mkdir -p "$repo/sub/deep"

cat > "$tmp/fake-check-$canary" <<EOF
#!/bin/sh
printf 'ran\n' >> $(shq "$tmp/check-ran.log")
echo "suite failed $canary"
exit 1
EOF
chmod +x "$tmp/fake-check-$canary"

conf="$tmp/conf-$canary/checks.local.json"
# 設定を書く。$1=Ruby の式 (ARGV[1] は repo の実 path、ARGV[2] は fake check)。$2=出力の file (省略時は $conf)
write_conf() {
  ruby -rjson -e "File.write(ARGV[0], JSON.generate(($1)))" -- "${2:-$conf}" "$repo_real" "$tmp/fake-check-$canary"
}
# 読み取りの口を起動する。$1=cwd。stdin は呼び出し元のまま。stdout と stderr を別の file に書き、exit を返す
status_in() {
  (cd "$1" && env AGENT_TOOLS_CHECKS_CONFIG="$conf" AGENT_TOOLS_QA_STATE_DIR="$tmp/qa-state" HOME="$tmp/home" \
    "$real_ruby" "$hook" --declaration-status > "$tmp/out" 2> "$tmp/err" < /dev/null)
}
expect_word() { # $1=cwd  $2=期待する語  $3=case
  rc=0
  status_in "$1" || rc=$?
  [ "$rc" -eq 0 ] || fail "$3: exit must be 0 (rc=$rc)"
  [ "$(cat "$tmp/out")" = "$2" ] || fail "$3: expected [$2], got [$(cat "$tmp/out")]"
  [ "$(grep -c '' "$tmp/out")" -eq 1 ] || fail "$3: stdout must be exactly one line"
  [ ! -s "$tmp/err" ] || fail "$3: stderr must be empty, got: $(cat "$tmp/err")"
}

# ---- 語の区分 (E05〜E21) ----------------------------------------------------------------
# E09: 設定の file が無い
expect_word "$repo" absent "E09"

# E10: entry が無い / entry に qa_checks が無い
write_conf '{ "/elsewhere" => { "qa_checks" => [] } }'
expect_word "$repo" absent "E10 no entry"
write_conf '{ ARGV[1] => { "edit_checks" => [] } }'
expect_word "$repo" absent "E10 no qa_checks"

# E11: entry が配列
write_conf '{ ARGV[1] => [] }'
expect_word "$repo" absent "E11"

# E12: qa_checks が空の配列
write_conf '{ ARGV[1] => { "qa_checks" => [] } }'
expect_word "$repo" empty "E12"

# E13: 有効な要素を含む qa_checks。command は実行しない
write_conf '{ ARGV[1] => { "qa_checks" => [{ "name" => "suite", "command" => [ARGV[2]] }] } }'
expect_word "$repo" declared "E13"
[ ! -e "$tmp/check-ran.log" ] || fail "E13: the declared command must not run"

# E05: repo の中の下位 directory からでも、repo root の実 path の entry を見る
expect_word "$repo/sub/deep" declared "E05"

# E21: cwd が symlink を経由しても、実 path の entry を見る
ln -s "$repo" "$tmp/repo-link"
expect_word "$tmp/repo-link/sub" declared "E21"

# E14: 不正な要素だけの空でない qa_checks
write_conf '{ ARGV[1] => { "qa_checks" => [{ "name" => "broken" }] } }'
expect_word "$repo" declared "E14"

# E15: qa_checks が null / 文字列
write_conf '{ ARGV[1] => { "qa_checks" => nil } }'
expect_word "$repo" unreadable "E15 null"
write_conf '{ ARGV[1] => { "qa_checks" => "suite" } }'
expect_word "$repo" unreadable "E15 string"

# E16 / E17: 壊れた JSON、top-level が配列
printf '{broken %s' "$canary" > "$conf"
expect_word "$repo" unreadable "E16"
printf '[]' > "$conf"
expect_word "$repo" unreadable "E17"

# E18: 設定の path が directory / 指す先の無い symlink
rm -f "$conf"
mkdir "$conf"
expect_word "$repo" unreadable "E18 directory"
rmdir "$conf"
ln -s "$tmp/no-such-target" "$conf"
expect_word "$repo" unreadable "E18 dangling"
rm -f "$conf"

# E19: 指す先のある symlink は先を読む
write_conf '{ ARGV[1] => { "qa_checks" => [] } }' "$tmp/conf-$canary/real.json"
ln -s "$tmp/conf-$canary/real.json" "$conf"
expect_word "$repo" empty "E19"
rm -f "$conf"

# E20: 読む権限が無い
if [ "$(id -u)" -ne 0 ]; then
  write_conf '{ ARGV[1] => { "qa_checks" => [] } }'
  chmod 000 "$conf"
  expect_word "$repo" unreadable "E20"
  chmod 600 "$conf"
  # 設定の file の親の directory に権限が無い -> absent と決めつけず unreadable (#814 の review の must と同じ形)
  chmod 000 "$tmp/conf-$canary"
  expect_word "$repo" unreadable "E20 parent"
  chmod 700 "$tmp/conf-$canary"
fi

# ---- repo root の決め方 (E06〜E08) ---------------------------------------------------------
# E06: linked worktree は別の key。main の path だけに宣言があれば absent
write_conf '{ ARGV[1] => { "qa_checks" => [{ "name" => "suite", "command" => [ARGV[2]] }] } }'
git -C "$repo" worktree add -q "$tmp/wt" 2>/dev/null
expect_word "$tmp/wt" absent "E06"

# E07: repo の外 (設定は有効)
mkdir -p "$tmp/loose"
expect_word "$tmp/loose" outside "E07"

# E07 の変形: repo の外で、設定の file も無い -> outside (repo root を先に決める)
mv "$conf" "$conf.bak"
expect_word "$tmp/loose" outside "E07 no config"
mv "$conf.bak" "$conf"

# E08: repository / index を選ぶ git の env を継いでいる (値が空でも) -> unknown
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE; do
  rc=0
  (cd "$repo" && env "$name=" AGENT_TOOLS_CHECKS_CONFIG="$conf" HOME="$tmp/home" \
    "$real_ruby" "$hook" --declaration-status > "$tmp/out" 2> "$tmp/err" < /dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = unknown ] && [ ! -s "$tmp/err" ] \
    || fail "E08 $name: expected unknown (rc=$rc, out=$(cat "$tmp/out"), err=$(cat "$tmp/err"))"
done

# E27 の変形: git が repo の外以外の理由で失敗する、git が無い -> unknown
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\necho "fatal: something else" >&2\nexit 128\n' > "$fake_bin/git"
chmod +x "$fake_bin/git"
rc=0
(cd "$repo" && env PATH="$fake_bin:$PATH" AGENT_TOOLS_CHECKS_CONFIG="$conf" HOME="$tmp/home" \
  "$real_ruby" "$hook" --declaration-status > "$tmp/out" 2> "$tmp/err" < /dev/null) || rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = unknown ] && [ ! -s "$tmp/err" ] \
  || fail "git failure: expected unknown (rc=$rc, out=$(cat "$tmp/out"))"
# git だけが無い PATH。system の Ruby は起動のときに uname を PATH から呼ぶので、uname は残す
mkdir -p "$tmp/nogit-bin"
ln -s "$(command -v uname)" "$tmp/nogit-bin/uname"
nogit_path="$tmp/nogit-bin:/bin"
if env PATH="$nogit_path" sh -c 'command -v git' >/dev/null 2>&1; then
  fail "git missing: the fixture PATH must not have git"
fi
rc=0
(cd "$repo" && env PATH="$nogit_path" AGENT_TOOLS_CHECKS_CONFIG="$conf" HOME="$tmp/home" \
  "$real_ruby" "$hook" --declaration-status > "$tmp/out" 2> "$tmp/err" < /dev/null) || rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = unknown ] \
  || fail "git missing: expected unknown (rc=$rc, out=$(cat "$tmp/out"), err=$(head -c 400 "$tmp/err"))"

# ---- 入口 (E01〜E04、E29) ----------------------------------------------------------------
# E01: stdin を開いたまま (書き込み側を持ったままの FIFO) でも、待たずに 1 語を出す。読めば safe-run の上限で止まる
fifo="$tmp/stdin.fifo"
mkfifo "$fifo"
exec 3<>"$fifo"
rc=0
(cd "$repo" && env AGENT_TOOLS_CHECKS_CONFIG="$conf" HOME="$tmp/home" \
  "$real_ruby" "$safe_run" --max-footprint-mb 1024 --max-seconds 10 -- "$real_ruby" "$hook" --declaration-status \
  > "$tmp/out" 2> "$tmp/err" < "$fifo") || rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = declared ] || fail "E01: must not wait for stdin (rc=$rc, out=$(cat "$tmp/out"))"

# E03: 知らない引数・余分な引数は stdin を読む前に exit 2。stdout は空
for args in "--bogus" "--declaration-status --extra" "--declaration-status --declaration-status"; do
  rc=0
  # shellcheck disable=SC2086 # args は空白で分けて渡す
  (cd "$repo" && env AGENT_TOOLS_CHECKS_CONFIG="$conf" HOME="$tmp/home" \
    "$real_ruby" "$safe_run" --max-footprint-mb 1024 --max-seconds 10 -- "$real_ruby" "$hook" $args \
    > "$tmp/out" 2> "$tmp/err" < "$fifo") || rc=$?
  [ "$rc" -eq 2 ] || fail "E03 [$args]: expected exit 2 without reading stdin (rc=$rc)"
  [ ! -s "$tmp/out" ] || fail "E03 [$args]: stdout must be empty"
done
exec 3>&-

# E02: Stop の JSON が stdin にあっても、宣言の状態だけを返し、check も state も触らない
printf 'dirty\n' > "$repo/new.txt"
rc=0
(cd "$repo" && printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
  | env AGENT_TOOLS_CHECKS_CONFIG="$conf" AGENT_TOOLS_QA_STATE_DIR="$tmp/qa-state" HOME="$tmp/home" \
      "$real_ruby" "$hook" --declaration-status > "$tmp/out" 2> "$tmp/err") || rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = declared ] || fail "E02: must return the word only (rc=$rc)"
[ ! -e "$tmp/check-ran.log" ] || fail "E02: no check may run"
[ ! -e "$tmp/qa-state" ] || fail "E02: no state may be written"

# E04 / E29: 引数なしは今の Stop の入口。dirty な scope で失敗する check -> exit 2 で止め、state を書く
rc=0
err=$(cd "$repo" && printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
  | env AGENT_TOOLS_CHECKS_CONFIG="$conf" AGENT_TOOLS_QA_STATE_DIR="$tmp/qa-state" HOME="$tmp/home" \
      "$real_ruby" "$hook" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 2 ] || fail "E04: the Stop entry must still block a failing scope (rc=$rc): $err"
[ -s "$tmp/check-ran.log" ] || fail "E04: the Stop entry must run the declared check"
[ -n "$(ls "$tmp/qa-state")" ] || fail "E04: the Stop entry must write its state"
rm -f "$repo/new.txt"

# ---- E22: どの語の出力にも、設定の path と command の canary が出ない ------------------------
# (上の case の stdout と stderr は、毎回 $tmp/out と $tmp/err に書いた。全部の区分を、もう一度 canary で見る)
for conf_expr in 'nil' '{ ARGV[1] => { "qa_checks" => [] } }' '{ ARGV[1] => { "qa_checks" => [{ "command" => [ARGV[2]] }] } }' \
  '{ ARGV[1] => { "qa_checks" => "x" } }'; do
  if [ "$conf_expr" = nil ]; then
    rm -f "$conf"
  else
    write_conf "$conf_expr"
  fi
  for dir in "$repo" "$tmp/loose"; do
    status_in "$dir" || true
    if grep -F -e "$canary" "$tmp/out" "$tmp/err" >/dev/null; then
      fail "E22: the canary must not appear (config: $conf_expr, cwd: $dir)"
    fi
  done
done
printf '{broken %s' "$canary" > "$conf"
status_in "$repo" || true
if grep -F -e "$canary" "$tmp/out" "$tmp/err" >/dev/null; then
  fail "E22: the canary must not appear for a broken config"
fi

echo "ok: qa-declaration-status self-test"
