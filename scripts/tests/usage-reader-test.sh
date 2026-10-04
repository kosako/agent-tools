#!/bin/sh
# personal-usage-reader.rb の self-test (#385)。
# 配備と同じ layout (拡張子なしの名前で 1 つの directory に置く) に copy して CLI として実行する。HOME と
# XDG_CONFIG_HOME は一時 dir に向け、実物の ~/.config には触れない。設定の契約 (path は固定、key は argv と
# timeout_sec だけ)、exit の契約 (0 = 読めた / 3 = 設定が無い / 2 = 不正・失敗・中断、2 と 3 は stdout が空で理由が
# stderr に 1 行、理由に設定の中身と path を出さない)、起動の契約 (shell を通さない、stdin は /dev/null、cwd は
# /、子の stderr は捨てる、timeout (stdout を閉じた後の終了待ちを含む) と出力の上限と wrapper への signal で
# process group ごと止める) を固定する。repo root の note (`.agent-context.local.md`) にだけ command が書かれた
# repo を cwd にしても、その command は実行されない。
# 引数で script の source を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src=${1:-"$repo_root/shared/scripts/personal-usage-reader.rb"}
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
# 止まらなかった子 (pid は偽の reader が pids* に書く) が残っても消し、chmod 000 にした fixture も消せるように
# 権限を戻す。
cleanup() {
  for f in "$tmp"/pids*; do
    [ -f "$f" ] || continue
    for p in $(cat "$f"); do kill -9 "$p" 2>/dev/null || :; done
  done
  chmod -R u+rwx "$tmp" 2>/dev/null || :
  rm -rf "$tmp"
}
trap cleanup EXIT

deploy="$tmp/deploy"
mkdir -p "$deploy"
cp "$src" "$deploy/personal-usage-reader"
chmod +x "$deploy/personal-usage-reader"
reader="$deploy/personal-usage-reader"

fake_home="$tmp/home"
xdg="$tmp/xdg"
mkdir -p "$fake_home" "$xdg/agent-tools"
config="$xdg/agent-tools/usage-reader.json"
bin="$tmp/bin"
mkdir -p "$bin"

# ---- Ruby unit checks: 定義を固定値で pin する ---------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
U = UsageReader

check("出力の上限は 1 MiB", U::MAX_OUTPUT == 1_048_576)
check("timeout の既定は 20 秒", U::DEFAULT_TIMEOUT == 20)
check("timeout の範囲は 1〜120", U::TIMEOUT_RANGE == (1..120))
check("key は argv と timeout_sec だけ", U::KEYS == %w[argv timeout_sec])
check("exit の値", [U::EXIT_OK, U::EXIT_ERROR, U::EXIT_ABSENT] == [0, 2, 3])
check("timeout_sec を省けば既定", U.parse_config('{"argv":["/x"]}') == [["/x"], 20])
check("timeout_sec の境界 (1 と 120) は受け付ける",
      U.parse_config('{"argv":["/x"],"timeout_sec":1}')[1] == 1 &&
        U.parse_config('{"argv":["/x"],"timeout_sec":120}')[1] == 120)
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- fake の読み取り口 -----------------------------------------------------------
# 引数を 1 行ずつ出す。
cat > "$bin/echo-args" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
EOF
# 自分の cwd を出す。
cat > "$bin/print-cwd" <<'EOF'
#!/bin/sh
pwd
EOF
# stdin を読み切ってから done を出す (stdin が /dev/null でなければ中身が混ざる)。stderr にも書く。
cat > "$bin/read-stdin" <<'EOF'
#!/bin/sh
cat
echo CANARY-ERR >&2
echo done
EOF
# 出力してから非ゼロで終わる。
cat > "$bin/fail-7" <<'EOF'
#!/bin/sh
echo partial
exit 7
EOF
# 何も出さずに 0 で終わる。
cat > "$bin/silent" <<'EOF'
#!/bin/sh
exit 0
EOF
# 背景の孫 (sleep) と自分の pid を $1 に書いて待ち続ける。
cat > "$bin/hang" <<'EOF'
#!/bin/sh
sleep 30 &
printf '%s %s\n' "$$" "$!" > "$1"
echo partial
wait
EOF
# 出力してから stdout を閉じ (wrapper には EOF が届く)、背景の孫と自分の pid を $1 に書いて待ち続ける。
cat > "$bin/hang-closed" <<'EOF'
#!/bin/sh
echo partial
exec >/dev/null
sleep 30 &
printf '%s %s\n' "$$" "$!" > "$1"
wait
EOF
# 上限ちょうど (1 MiB) を出す / 1 byte 超える / 止めるまで出し続ける。
cat > "$bin/exact-cap" <<'EOF'
#!/bin/sh
head -c 1048576 /dev/zero
EOF
cat > "$bin/over-cap" <<'EOF'
#!/bin/sh
head -c 1048577 /dev/zero
EOF
cat > "$bin/flood" <<'EOF'
#!/bin/sh
exec yes CANARY-FLOOD
EOF
# 名前に shell の metacharacter を含む読み取り口 (要素が 1 つの argv で shell に渡ると `;` 以降が動く)。
odd="$bin/r;echo PWNED-SINGLE"
cat > "$odd" <<'EOF'
#!/bin/sh
echo single-ok
EOF
# 実行権限の無い file。
printf '#!/bin/sh\necho no\n' > "$bin/not-exec"
chmod +x "$bin/echo-args" "$bin/print-cwd" "$bin/read-stdin" "$bin/fail-7" "$bin/silent" "$bin/hang" \
  "$bin/hang-closed" "$bin/exact-cap" "$bin/over-cap" "$bin/flood" "$odd"
ln -s "$bin/echo-args" "$bin/linked-reader"

# write_argv <file> <argv...>: {"argv": [...]} を JSON で書く (値は argv で渡し、JSON の quote は Ruby に任せる)。
write_argv() {
  ruby -rjson -e 'File.write(ARGV[0], JSON.generate("argv" => ARGV[1..-1]))' "$@"
}

# run_reader [env...]: 一時 dir の HOME / XDG_CONFIG_HOME で wrapper を引数なしで起動し、rc / out / err に入れる。
# cwd は $run_cwd (既定は $tmp)、stdin は $run_stdin (既定は /dev/null)。追加の引数は wrapper に渡す。
run_cwd=$tmp
run_stdin=/dev/null
run_reader() {
  set +e
  (cd "$run_cwd" && env HOME="$fake_home" XDG_CONFIG_HOME="$xdg" "$reader" "$@" <"$run_stdin" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  out=$(cat "$tmp/out")
  err=$(cat "$tmp/err")
}

# exit 2 で、理由文に $2 を含み、1 行で、stdout は空。usage に落ちず、設定の中身 (CANARY) と path を出さない。
expect_error() {
  [ "$rc" -eq 2 ] || fail "$1 should exit 2 (rc=$rc): out=$out err=$err"
  case "$err" in *"$2"*) : ;; *) fail "$1 should say '$2': $err" ;; esac
  [ ! -s "$tmp/out" ] || fail "$1 must not print anything on stdout: $(head -c 200 "$tmp/out" | od -c | head -5)"
  [ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ] || fail "$1 should give exactly one reason line: $err"
  case "$err" in *"usage:"*) fail "$1 must fail on its own check, not usage: $err" ;; esac
  case "$err" in *CANARY*) fail "$1 must not echo the config content: $err" ;; esac
  case "$err" in *"$tmp"*) fail "$1 must not echo the path: $err" ;; esac
}

# exit 0 で、stdout が $2 の file と byte 単位で一致し、stderr は空 (子の stderr を捨てる)。
expect_output() {
  [ "$rc" -eq 0 ] || fail "$1 should exit 0 (rc=$rc): $err"
  cmp -s "$tmp/out" "$2" || fail "$1: stdout differs: $(head -c 200 "$tmp/out" | od -c | head -5)"
  [ ! -s "$tmp/err" ] || fail "$1 must not print on stderr (child stderr is discarded): $err"
}

# ---- 設定が無い → exit 3、stdout は空 --------------------------------------------
run_reader
[ "$rc" -eq 3 ] || fail "absent config should exit 3 (rc=$rc): $out $err"
[ ! -s "$tmp/out" ] || fail "absent config must not print on stdout: $out"
case "$err" in *"設定 file がありません"*) : ;; *) fail "absent config should say so: $err" ;; esac
case "$err" in *"$tmp"*) fail "absent config must not echo the path: $err" ;; esac

# ---- shell を通さない: metacharacter を含む要素は literal のまま渡り、canary は作られない ----
write_argv "$config" "$bin/echo-args" ";touch $tmp/pwned" "\$(touch $tmp/pwned2)" "\`touch $tmp/pwned3\`" "| touch $tmp/pwned4"
run_reader
for c in pwned pwned2 pwned3 pwned4; do
  [ ! -e "$tmp/$c" ] || fail "argv element was evaluated by a shell (canary $c created)"
done
printf '%s\n' ";touch $tmp/pwned" "\$(touch $tmp/pwned2)" "\`touch $tmp/pwned3\`" "| touch $tmp/pwned4" > "$tmp/expect"
expect_output "shell metacharacters stay literal" "$tmp/expect"
# 要素が 1 つ (引数なし) でも shell に渡らない: 名前に `;` を含む実行ファイルをそのまま起動する
write_argv "$config" "$odd"
run_reader
printf 'single-ok\n' > "$tmp/expect"
expect_output "single-element argv is not passed to a shell" "$tmp/expect"

# ---- 正常: 引数をそのまま渡し、stdout をそのまま出す --------------------------------
write_argv "$config" "$bin/echo-args" "a b" "" "--flag=1"
run_reader
printf 'a b\n\n--flag=1\n' > "$tmp/expect"
expect_output "args passed as-is" "$tmp/expect"

# timeout_sec を書いても読める
ruby -rjson -e 'File.write(ARGV[0], JSON.generate("argv" => [ARGV[1], "x"], "timeout_sec" => 5))' "$config" "$bin/echo-args"
run_reader
printf 'x\n' > "$tmp/expect"
expect_output "with timeout_sec" "$tmp/expect"

# symlink の設定 file と symlink の実行ファイル (指す先は regular file) は使う
write_argv "$tmp/real-config.json" "$bin/linked-reader" "linked"
rm -f "$config"
ln -s "$tmp/real-config.json" "$config"
run_reader
printf 'linked\n' > "$tmp/expect"
expect_output "symlinked config and executable" "$tmp/expect"
rm "$config"

# XDG_CONFIG_HOME が空なら HOME/.config の下
mkdir -p "$fake_home/.config/agent-tools"
write_argv "$fake_home/.config/agent-tools/usage-reader.json" "$bin/echo-args" "from-home"
set +e
(cd "$tmp" && env HOME="$fake_home" XDG_CONFIG_HOME="" "$reader" </dev/null >"$tmp/out" 2>"$tmp/err")
rc=$?
set -e
printf 'from-home\n' > "$tmp/expect"
expect_output "empty XDG_CONFIG_HOME falls back to HOME/.config" "$tmp/expect"
rm "$fake_home/.config/agent-tools/usage-reader.json"

# ---- 起動の環境: cwd は /、stdin は /dev/null、子の stderr は捨てる ----------------------
write_argv "$config" "$bin/print-cwd"
run_cwd="$tmp/bin"
run_reader
run_cwd=$tmp
printf '/\n' > "$tmp/expect"
expect_output "child cwd is /" "$tmp/expect"

printf 'CANARY-STDIN\n' > "$tmp/stdin"
write_argv "$config" "$bin/read-stdin"
run_stdin="$tmp/stdin"
run_reader
run_stdin=/dev/null
printf 'done\n' > "$tmp/expect"
expect_output "child stdin is /dev/null and child stderr is discarded" "$tmp/expect"

# ---- 子の失敗 → exit 2 (子が出した分も stdout に出さない) ----------------------------
write_argv "$config" "$bin/fail-7"
run_reader
expect_error "child exits non-zero" "読み取り口が exit 7 で終わりました"

write_argv "$config" "$bin/silent"
run_reader
expect_error "empty output" "読み取り口の出力が空です"

# expect_group_stopped <label> <pids file>: 偽の reader が書いた子と孫の pid が、どれも残っていない。kill された
# 孫は init に回収されるまで zombie で残りうるので、少し待って確かめる。
expect_group_stopped() {
  [ -s "$2" ] || fail "$1: the reader did not record its pids"
  egs_alive=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    egs_alive=""
    for p in $(cat "$2"); do
      if kill -0 "$p" 2>/dev/null; then egs_alive="$egs_alive $p"; fi
    done
    [ -n "$egs_alive" ] || break
    sleep 0.1
  done
  [ -z "$egs_alive" ] || fail "$1 must stop the child and its process group (still alive:$egs_alive)"
}

# write_hang_config <reader> <pids file> <timeout_sec>: 偽の reader に pid の書き先を渡す設定を書く。
write_hang_config() {
  ruby -rjson -e 'File.write(ARGV[0], JSON.generate("argv" => [ARGV[1], ARGV[2]], "timeout_sec" => ARGV[3].to_i))' \
    "$config" "$1" "$2" "$3"
}

# timeout: 子と孫 (同じ process group) を止めて戻る。止めずに待つ実装は 30 秒かかる (上限の case より先に置き、
# 止めない実装が出し続ける子を待って詰まる前にここで落とす)。
write_hang_config "$bin/hang" "$tmp/pids" 1
started=$(date +%s)
run_reader
elapsed=$(($(date +%s) - started))
expect_error "timeout" "読み取り口が timeout_sec の時間内に終わらなかったので止めました"
[ "$elapsed" -lt 10 ] || fail "timeout should return promptly (took ${elapsed}s)"
expect_group_stopped "timeout" "$tmp/pids"

# timeout は stdout を閉じた後の終了待ちにも効く (EOF の後も止まらない子を timeout_sec で止める)
write_hang_config "$bin/hang-closed" "$tmp/pids-closed" 1
started=$(date +%s)
run_reader
elapsed=$(($(date +%s) - started))
expect_error "timeout after stdout is closed" "読み取り口が timeout_sec の時間内に終わらなかったので止めました"
[ "$elapsed" -lt 10 ] || fail "timeout after stdout is closed should return promptly (took ${elapsed}s)"
expect_group_stopped "timeout after stdout is closed" "$tmp/pids-closed"

# wrapper への signal (SIGTERM / SIGINT): 子と孫を止めて回収し、exit 2 で理由を 1 行 (stdout は空)。timeout は
# 長くして、timeout ではなく signal で止まることを見る。SIGINT は非対話の sh が背景の job で無視にするので、
# 既定の扱いに戻した Ruby から起動して送る。
for sig in TERM INT; do
  write_hang_config "$bin/hang" "$tmp/pids-$sig" 60
  set +e
  status=$(env HOME="$fake_home" XDG_CONFIG_HOME="$xdg" ruby - "$sig" "$reader" "$tmp/pids-$sig" "$tmp/out" "$tmp/err" <<'RUBY'
sig, reader, pids, out, err = ARGV
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
trap("INT", "SYSTEM_DEFAULT")
pid = Process.spawn([reader, reader], in: File::NULL, out: out, err: err, chdir: File.dirname(out))
deadline = clock.call + 10
sleep 0.05 until File.size?(pids) || clock.call > deadline
sleep 0.2
Process.kill(sig, pid)
deadline = clock.call + 10
st = nil
until (st = Process.waitpid2(pid, Process::WNOHANG)) || clock.call > deadline
  sleep 0.05
end
if st.nil?
  Process.kill("KILL", pid)
  Process.wait(pid)
  puts "hung"
else
  puts st[1].exited? ? "exit #{st[1].exitstatus}" : "signal #{st[1].termsig}"
end
RUBY
)
  set -e
  out=$(cat "$tmp/out")
  err=$(cat "$tmp/err")
  [ "$status" = "exit 2" ] || fail "SIG$sig to the wrapper should end it with exit 2 ($status): $err"
  rc=2
  expect_error "SIG$sig to the wrapper" "signal (SIG$sig) で中断しました"
  expect_group_stopped "SIG$sig to the wrapper" "$tmp/pids-$sig"
done

# 出力の上限: ちょうど 1 MiB は通し、超えたら止める (出し続ける子も止まる)
write_argv "$config" "$bin/exact-cap"
run_reader
[ "$rc" -eq 0 ] || fail "output of exactly 1 MiB should pass (rc=$rc): $err"
[ "$(wc -c < "$tmp/out" | tr -d ' ')" = 1048576 ] || fail "output of exactly 1 MiB should be passed through whole"
write_argv "$config" "$bin/over-cap"
run_reader
expect_error "output 1 byte over the cap" "読み取り口の出力が上限 (1048576 byte) を超えました"
write_argv "$config" "$bin/flood"
run_reader
expect_error "output over the cap" "読み取り口の出力が上限 (1048576 byte) を超えました"

# ---- 設定が不正 → exit 2、stdout は空、理由あり ----------------------------------------
# bad_config <name> <json> <理由>: 設定 file に json を書いて起動する。
bad_config() {
  printf '%s' "$2" > "$config"
  run_reader
  expect_error "$1" "$3"
}
bad_config "not JSON" '{"argv": ["CANARY"' "設定 file が JSON として読めません"
bad_config "top-level array" '["CANARY"]' "設定 file の top-level が object ではありません"
bad_config "unknown key" "{\"argv\":[\"$bin/echo-args\",\"x\"],\"CANARYKEY\":1}" "設定 file に知らない key があります"
bad_config "argv missing" '{"timeout_sec": 5}' "設定 file の argv が空でない文字列の配列ではありません"
bad_config "argv empty" '{"argv": []}' "設定 file の argv が空でない文字列の配列ではありません"
bad_config "argv not array" '{"argv": "CANARY"}' "設定 file の argv が空でない文字列の配列ではありません"
bad_config "argv non-string element" "{\"argv\":[\"$bin/echo-args\",1]}" "設定 file の argv が空でない文字列の配列ではありません"
bad_config "control character" "{\"argv\":[\"$bin/echo-args\",\"CANARY\\nx\"]}" "設定 file の argv の要素に制御文字か UTF-8 として読めない文字があります"
bad_config "NUL" "{\"argv\":[\"$bin/echo-args\",\"CANARY\\u0000x\"]}" "設定 file の argv の要素に制御文字か UTF-8 として読めない文字があります"
bad_config "relative path" '{"argv": ["CANARY-reader"]}' "設定 file の argv[0] が絶対 path ではありません"
bad_config "relative path (dot)" '{"argv": ["./CANARY-reader"]}' "設定 file の argv[0] が絶対 path ではありません"
for t in 0 121 -1 '"20"' 1.5 true null; do
  bad_config "timeout_sec $t" "{\"argv\":[\"$bin/echo-args\"],\"timeout_sec\":$t}" "設定 file の timeout_sec が 1〜120 の整数ではありません"
done
printf '{"argv": ["/CANARY\377"]}' > "$config"
run_reader
expect_error "invalid UTF-8" "設定 file が UTF-8 として読めません"

# 実行ファイルの検査
write_argv "$config" "$bin/not-exec"
run_reader
expect_error "not executable" "読み取り口の実行ファイルを実行できません"
write_argv "$config" "$tmp/no-such-CANARY"
run_reader
expect_error "missing executable" "読み取り口の実行ファイルが在りません"
write_argv "$config" "$bin"
run_reader
expect_error "executable is a directory" "読み取り口の実行ファイルが regular file ではありません"
ln -s "$tmp/no-such-target" "$bin/dangling"
write_argv "$config" "$bin/dangling"
run_reader
expect_error "dangling symlink executable" "読み取り口の実行ファイルが在りません"

# 設定 file が在るのに regular file でない・読めない → 無いことにせず exit 2
rm "$config"
mkdir "$config"
run_reader
expect_error "config is a directory" "設定 file が regular file ではありません"
rmdir "$config"
if [ "$(id -u)" -ne 0 ]; then
  write_argv "$config" "$bin/echo-args" "CANARY"
  chmod 000 "$config"
  run_reader
  expect_error "unreadable config" "設定 file を確かめられないか読めません (Errno::EACCES)"
  chmod 644 "$config"
  chmod 000 "$xdg/agent-tools"
  run_reader
  expect_error "unsearchable config dir" "設定 file を確かめられないか読めません (Errno::EACCES)"
  chmod 755 "$xdg/agent-tools"
  rm "$config"
fi

# ---- note にだけ command がある repo を cwd にしても実行しない ---------------------------
# 設定は無く、repo root の note に読み取り口の command (canary を作る) を書き、repo の中に相対の
# XDG_CONFIG_HOME / HOME から見える設定も置く。wrapper は note を読まず、相対の path を cwd から解決しない。
repo="$tmp/repo"
mkdir -p "$repo/.config/agent-tools" "$repo/relhome/.config/agent-tools"
cat > "$repo/.agent-context.local.md" <<EOF
# context
- 残量の読み取り口: \`touch $tmp/note-pwned\`
EOF
write_argv "$repo/.config/agent-tools/usage-reader.json" /usr/bin/touch "$tmp/repo-config-pwned"
write_argv "$repo/relhome/.config/agent-tools/usage-reader.json" /usr/bin/touch "$tmp/repo-home-pwned"
set +e
(cd "$repo" && env HOME="$fake_home" XDG_CONFIG_HOME=".config" "$reader" </dev/null >"$tmp/out" 2>"$tmp/err")
rc=$?
set -e
err=$(cat "$tmp/err")
[ ! -e "$tmp/note-pwned" ] || fail "the note command must not be executed (canary note-pwned created)"
[ ! -e "$tmp/repo-config-pwned" ] || fail "a relative XDG_CONFIG_HOME must not be resolved from the cwd (canary created)"
[ "$rc" -eq 3 ] || fail "repo with only a note command should exit 3 (rc=$rc): $err"
[ ! -s "$tmp/out" ] || fail "repo with only a note command must not print on stdout"
# HOME が相対 path なら設定の場所を決めず exit 2 (cwd の repo の中の設定を読まない)
set +e
(cd "$repo" && env HOME="relhome" XDG_CONFIG_HOME="" "$reader" </dev/null >"$tmp/out" 2>"$tmp/err")
rc=$?
set -e
err=$(cat "$tmp/err")
[ ! -e "$tmp/repo-home-pwned" ] || fail "a relative HOME must not be resolved from the cwd (canary created)"
[ "$rc" -eq 2 ] || fail "a relative HOME should exit 2 (rc=$rc): $err"
[ ! -s "$tmp/out" ] || fail "a relative HOME must not print on stdout"

# ---- 引数: --help だけ受け付け、それ以外は usage error -----------------------------------
run_reader --help
[ "$rc" -eq 0 ] || fail "--help should exit 0 (rc=$rc): $err"
case "$out" in *"usage: personal-usage-reader"*) : ;; *) fail "--help should print usage: $out" ;; esac
for args in "--config $tmp/x" "extra" "--help extra" "-h"; do
  # 引数の分割は意図どおり (値に空白を含めない fixture)
  # shellcheck disable=SC2086
  run_reader $args
  [ "$rc" -eq 2 ] || fail "usage error should exit 2 for '$args' (rc=$rc): $out"
  case "$err" in *"usage: personal-usage-reader"*) : ;; *) fail "should print usage for '$args': $err" ;; esac
  [ ! -s "$tmp/out" ] || fail "usage error must not print anything on stdout for '$args'"
done

echo "usage-reader-test: ok"
