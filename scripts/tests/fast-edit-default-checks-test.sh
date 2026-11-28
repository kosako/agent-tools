#!/bin/sh
# personal-fast-edit-check の既定の check (#814) の self-test。宣言の無い repo でも、file を実行しない構文チェック
# (`.rb` に ruby -c、`.sh` に /bin/sh -n) が走ること、宣言と止める設定が既定より優先すること、repo の中の file・
# 設定・PATH が既定の command と interpreter を変えないことを確かめる。changed-scope-qa が新しい key で変わらない
# ことも見る。case の ID は Issue #814 の期待値の表 (E01〜E30) と、決めたことの追加 (X01〜X04)。
# 配備と同じ layout (hook と safe-run を同じ dir) を tmp に作る。safe-run は、起動の引数を log に書いてから本物を
# exec する wrapper にする (既定が走ったか、process を増やしていないかを見るため)。hook は PATH に依らないよう、
# 本物の Ruby で明示して起動する。設定と state は env で tmp に向け、実 HOME と実 config には触れない。
# 引数で hook の source を差し替えられる (変異での確認用): <fast-edit-check.rb>
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

edit_src=${1:-"$repo_root/shared/scripts/personal-fast-edit-check.rb"}
qa_src="$repo_root/shared/scripts/personal-changed-scope-qa.rb"
sr_src="$repo_root/shared/scripts/personal-safe-run.rb"
for f in "$edit_src" "$qa_src" "$sr_src"; do
  [ -f "$f" ] || fail "missing $f"
done
real_ruby=$(ruby -rrbconfig -e 'print RbConfig.ruby')

tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

sr_log="$tmp/safe-run.log"
: > "$sr_log"
make_deploy() { # $1=dir  $2=yes|no (safe-run を置くか)
  mkdir -p "$1"
  cp "$edit_src" "$1/personal-fast-edit-check"
  cp "$qa_src" "$1/personal-changed-scope-qa"
  chmod +x "$1/personal-fast-edit-check" "$1/personal-changed-scope-qa"
  if [ "$2" = yes ]; then
    cp "$sr_src" "$1/personal-safe-run.real"
    {
      printf '#!/bin/sh\n'
      printf 'printf %%s\\\\n "$*" >> %s\n' "$(shq "$sr_log")"
      printf 'exec %s %s "$@"\n' "$(shq "$real_ruby")" "$(shq "$1/personal-safe-run.real")"
    } > "$1/personal-safe-run"
    chmod +x "$1/personal-safe-run"
  fi
}
deploy="$tmp/deploy"
make_deploy "$deploy" yes
hook="$deploy/personal-fast-edit-check"
qa_hook="$deploy/personal-changed-scope-qa"

GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
mkdir -p "$tmp/home"

plain="$tmp/plain"
git init -q "$plain"
plain_real=$(ruby -e 'print File.realpath(ARGV[0])' "$plain")
no_config="$tmp/no-such-config.json"

printf 'puts 1\n' > "$plain/good.rb"
printf 'def broken(\n' > "$plain/bad.rb"
printf 'echo hi\n' > "$plain/good.sh"
printf 'if true; then\n' > "$plain/bad.sh"

# payload の値は "--" の後ろに置く (先頭が "-" の path を ruby が自分の option として読まないように)
edit_payload() { # $1=file_path
  ruby -rjson -e 'print JSON.generate({"hook_event_name" => "PostToolUse", "tool_name" => "Write",
                                       "tool_input" => {"file_path" => ARGV[0]}})' -- "$1"
}
patch_payload() { # $1=cwd  $2=patch の本文  $3=tool_response
  ruby -rjson -e 'print JSON.generate({"hook_event_name" => "PostToolUse", "tool_name" => "apply_patch", "cwd" => ARGV[0],
                                       "tool_input" => {"command" => ARGV[1]}, "tool_response" => ARGV[2]})' -- "$1" "$2" "$3"
}
# stdin の payload を hook に渡す。$1=設定の path。PATH は呼び出し元のまま (E27 だけ変える)
run_hook() {
  env AGENT_TOOLS_CHECKS_CONFIG="$1" HOME="$tmp/home" "$real_ruby" "$hook"
}
run_edit() { # $1=file_path  $2=設定の path
  edit_payload "$1" | run_hook "$2"
}
sr_count() {
  grep -c '' "$sr_log" || true
}
write_json() { # $1=出力の file  $2=Ruby の式 (ARGV[1..] を使える)。JSON にして書く
  out=$1
  expr=$2
  shift 2
  ruby -rjson -e "data = ($expr); File.write(ARGV[0], JSON.generate(data))" "$out" "$@"
}
assert_silent() { # $1=出力  $2=case
  [ -z "$1" ] || fail "$2: must be silent, got: $1"
}
assert_has() { # $1=出力  $2=含むべき文字列  $3=case
  case $1 in
    *"$2"*) ;;
    *) fail "$3: output must contain [$2], got: $1" ;;
  esac
}
assert_lacks() { # $1=出力  $2=含んではいけない文字列  $3=case
  case $1 in
    *"$2"*) fail "$3: output must not contain [$2], got: $1" ;;
  esac
}

# ---- 宣言の無い repo の既定 -----------------------------------------------------------

# E01: 宣言の無い repo の正しい .rb / .sh -> 既定が 1 回ずつ走り、何も出さない
before=$(sr_count)
out=$(run_edit "$plain/good.rb" "$no_config") || fail "E01: hook must exit 0"
assert_silent "$out" "E01 rb"
out=$(run_edit "$plain/good.sh" "$no_config") || fail "E01: hook must exit 0"
assert_silent "$out" "E01 sh"
[ "$(sr_count)" -eq $((before + 2)) ] || fail "E01: the defaults must run once per file: $(cat "$sr_log")"
tail -n 2 "$sr_log" | head -n 1 | grep -F -e "-- $real_ruby --disable=all -c $plain/good.rb" >/dev/null \
  || fail "E01: ruby-syntax must run the hook's own Ruby with --disable=all -c: $(cat "$sr_log")"
tail -n 1 "$sr_log" | grep -F -e "-- /bin/sh -n $plain/good.sh" >/dev/null \
  || fail "E01: sh-syntax must run /bin/sh -n: $(cat "$sr_log")"

# E02 / E03: 構文の誤りは既定の名前つきで model に届き、exit 0 (block しない)
out=$(run_edit "$plain/bad.rb" "$no_config") || fail "E02: hook must exit 0"
assert_has "$out" '"hookEventName":"PostToolUse"' "E02"
assert_has "$out" "[ruby-syntax (既定)] exit 1" "E02"
assert_has "$out" "bad.rb への編集が check に失敗しました" "E02"
out=$(run_edit "$plain/bad.sh" "$no_config") || fail "E03: hook must exit 0"
assert_has "$out" "[sh-syntax (既定)] exit" "E03"

# E04: 拡張子は大文字小文字を区別し、途中の拡張子には当てない -> 何も起動しない
for name in X.RB X.SH x.rb.bak x.sh.orig; do
  printf 'def broken(\n' > "$plain/$name"
  before=$(sr_count)
  out=$(run_edit "$plain/$name" "$no_config") || fail "E04 $name: hook must exit 0"
  assert_silent "$out" "E04 $name"
  [ "$(sr_count)" -eq "$before" ] || fail "E04 $name: no check may start"
done

# E05: ruby -c は BEGIN を実行しない
ruby -e 'File.write(ARGV[0], "BEGIN { File.write(#{ARGV[1].dump}, %q(x)) }\nputs 1\n")' "$plain/begin.rb" "$tmp/begin-ran"
out=$(run_edit "$plain/begin.rb" "$no_config") || fail "E05: hook must exit 0"
assert_silent "$out" "E05"
[ ! -e "$tmp/begin-ran" ] || fail "E05: BEGIN must not run"

# E06: sh -n は command も here document の中の command substitution も実行しない
{
  printf 'touch %s\n' "$(shq "$tmp/sh-ran")"
  printf 'cat <<EOF\n$(touch %s)\nEOF\n' "$(shq "$tmp/heredoc-ran")"
} > "$plain/heredoc.sh"
out=$(run_edit "$plain/heredoc.sh" "$no_config") || fail "E06: hook must exit 0"
assert_silent "$out" "E06"
[ ! -e "$tmp/sh-ran" ] || fail "E06: a command must not run"
[ ! -e "$tmp/heredoc-ran" ] || fail "E06: a command substitution in a here document must not run"

# E07: __END__ の後ろは Ruby として読まない
printf 'puts 1\n__END__\ndef (((\n' > "$plain/data.rb"
out=$(run_edit "$plain/data.rb" "$no_config") || fail "E07: hook must exit 0"
assert_silent "$out" "E07"

# E08: git の repo の外の file には既定を走らせない
mkdir -p "$tmp/loose"
printf 'def broken(\n' > "$tmp/loose/bad.rb"
before=$(sr_count)
out=$(run_edit "$tmp/loose/bad.rb" "$no_config") || fail "E08: hook must exit 0"
assert_silent "$out" "E08"
[ "$(sr_count)" -eq "$before" ] || fail "E08: no check may start outside a repo"

# E09: repo の外を指す symlink には既定を走らせない。repo の中を指す symlink には走らせる
ln -s "$tmp/loose/bad.rb" "$plain/out-link.rb"
before=$(sr_count)
out=$(run_edit "$plain/out-link.rb" "$no_config") || fail "E09: hook must exit 0"
assert_silent "$out" "E09 outside"
[ "$(sr_count)" -eq "$before" ] || fail "E09: a link to outside the repo must not be checked"
mkdir -p "$plain/sub"
printf 'def broken(\n' > "$plain/sub/target.rb"
ln -s "$plain/sub/target.rb" "$plain/in-link.rb"
out=$(run_edit "$plain/in-link.rb" "$no_config") || fail "E09: hook must exit 0"
assert_has "$out" "[ruby-syntax (既定)]" "E09 inside"

# E10: 相対 path (先頭が "-" の名前を含む) には既定を当てない
printf 'def broken(\n' > "$plain/-x.rb"
for rel in bad.rb -x.rb; do
  edit_payload "$rel" | ruby -rjson -e 'exit(JSON.parse(STDIN.read).dig("tool_input", "file_path") == ARGV[0] ? 0 : 1)' -- "$rel" \
    || fail "E10 $rel: the payload must carry the relative path as is (fixture assumption)"
  before=$(sr_count)
  out=$(cd "$plain" && run_edit "$rel" "$no_config") || fail "E10 $rel: hook must exit 0"
  assert_silent "$out" "E10 $rel"
  [ "$(sr_count)" -eq "$before" ] || fail "E10 $rel: a relative path must not be checked"
done

# E11: 成功した apply_patch の Add -> 追加した file を既定で見る
printf 'def broken(\n' > "$plain/added.rb"
patch=$(printf '*** Begin Patch\n*** Add File: added.rb\n+def broken(\n*** End Patch\n')
out=$(patch_payload "$plain" "$patch" "$(printf 'Exit code: 0\nOutput:\nSuccess.')" | run_hook "$no_config") \
  || fail "E11: hook must exit 0"
assert_has "$out" "added.rb への編集が check に失敗しました" "E11"
assert_has "$out" "[ruby-syntax (既定)]" "E11"

# E12: apply_patch の Move -> 移動先だけを見る
printf 'if true; then\n' > "$plain/moved.sh"
patch=$(printf '*** Begin Patch\n*** Update File: old.sh\n*** Move to: moved.sh\n@@\n-echo hi\n+if true; then\n*** End Patch\n')
before=$(sr_count)
out=$(patch_payload "$plain" "$patch" "$(printf 'Exit code: 0\nOutput:\nSuccess.')" | run_hook "$no_config") \
  || fail "E12: hook must exit 0"
assert_has "$out" "moved.sh への編集が check に失敗しました" "E12"
[ "$(sr_count)" -eq $((before + 1)) ] || fail "E12: only the move target may be checked: $(cat "$sr_log")"
tail -n 1 "$sr_log" | grep -F -e "$plain/moved.sh" >/dev/null || fail "E12: the move target must be checked"

# E13: 失敗した apply_patch には check を起動しない
before=$(sr_count)
out=$(patch_payload "$plain" "$patch" "$(printf 'Exit code: 1\nOutput:\nfailed')" | run_hook "$no_config") \
  || fail "E13: hook must exit 0"
assert_silent "$out" "E13"
[ "$(sr_count)" -eq "$before" ] || fail "E13: a failed patch must not start a check"

# E15: 設定が無く、既定に当たらない file -> 何も起動しない
printf 'x\n' > "$plain/note.txt"
before=$(sr_count)
out=$(run_edit "$plain/note.txt" "$no_config") || fail "E15: hook must exit 0"
assert_silent "$out" "E15"
[ "$(sr_count)" -eq "$before" ] || fail "E15: a non-target file must not start a check"

# X01: .git の中の file は対象外 (git が work tree の外として扱う)
printf 'if true; then\n' > "$plain/.git/hooks/bad.sh"
before=$(sr_count)
out=$(run_edit "$plain/.git/hooks/bad.sh" "$no_config") || fail "X01: hook must exit 0"
assert_silent "$out" "X01"
[ "$(sr_count)" -eq "$before" ] || fail "X01: a file inside .git must not be checked"

# X02: linked worktree (.git が "gitdir: " の file) と、深い directory でも repo root を見つける。label は repo 相対
(cd "$plain" && git add good.rb && git commit -qm seed)
git -C "$plain" worktree add -q "$tmp/wt" 2>/dev/null
mkdir -p "$tmp/wt/deep/er"
printf 'def broken(\n' > "$tmp/wt/deep/er/bad.rb"
out=$(run_edit "$tmp/wt/deep/er/bad.rb" "$no_config") || fail "X02: hook must exit 0"
assert_has "$out" "fast-edit-check: deep/er/bad.rb への編集" "X02"

# X03: .git が "gitdir: " で始まらない file なら repo とみなさない
mkdir -p "$tmp/fake-repo"
printf 'not a gitdir\n' > "$tmp/fake-repo/.git"
printf 'def broken(\n' > "$tmp/fake-repo/bad.rb"
before=$(sr_count)
out=$(run_edit "$tmp/fake-repo/bad.rb" "$no_config") || fail "X03: hook must exit 0"
assert_silent "$out" "X03"
[ "$(sr_count)" -eq "$before" ] || fail "X03: a plain .git file must not make a repo"

# ---- default_edit_checks の組 (E16〜E20。top-level と entry の 4 値 × 4 値) -----------------
for top in none true false bad; do
  for ent in none true false bad; do
    conf="$tmp/flags-$top-$ent.json"
    write_json "$conf" '
      top, ent, root = ARGV[1], ARGV[2], ARGV[3]
      val = { "true" => true, "false" => false, "bad" => "no" }
      h = {}
      h["default_edit_checks"] = val[top] unless top == "none"
      h[root] = { "default_edit_checks" => val[ent] } unless ent == "none"
      h' "$top" "$ent" "$plain_real"
    out=$(run_edit "$plain/bad.rb" "$conf") || fail "flags $top/$ent: hook must exit 0"
    expect_run=yes
    case $top in false | bad) expect_run=no ;; esac
    case $ent in false | bad) expect_run=no ;; esac
    if [ "$expect_run" = yes ]; then
      assert_has "$out" "[ruby-syntax (既定)]" "flags $top/$ent"
    else
      assert_lacks "$out" "[ruby-syntax (既定)]" "flags $top/$ent"
    fi
    if [ "$top" = bad ]; then
      assert_has "$out" "top-level の default_edit_checks は true か false にしてください" "flags $top/$ent"
    else
      assert_lacks "$out" "top-level の default_edit_checks" "flags $top/$ent"
    fi
    if [ "$ent" = bad ]; then
      assert_has "$out" "$plain_real の default_edit_checks は true か false にしてください" "flags $top/$ent"
    else
      assert_lacks "$out" "$plain_real の default_edit_checks" "flags $top/$ent"
    fi
  done
done

# ---- 壊れた・読めない設定 (E21 と決めたこと) -------------------------------------------
printf '{broken' > "$tmp/broken.json"
printf '[]' > "$tmp/array.json"
mkdir -p "$tmp/dir.json"
ln -s "$tmp/no-such-target.json" "$tmp/dangling.json"
for conf in broken array dir dangling; do
  before=$(sr_count)
  out=$(run_edit "$plain/bad.rb" "$tmp/$conf.json") || fail "E21 $conf: hook must exit 0"
  assert_has "$out" "設定エラー" "E21 $conf"
  assert_lacks "$out" "ruby-syntax" "E21 $conf"
  [ "$(sr_count)" -eq "$before" ] || fail "E21 $conf: no check may start with an unreadable config"
done
if [ "$(id -u)" -ne 0 ]; then
  printf '{}' > "$tmp/noread.json"
  chmod 000 "$tmp/noread.json"
  out=$(run_edit "$plain/bad.rb" "$tmp/noread.json") || fail "E21 noread: hook must exit 0"
  assert_has "$out" "設定エラー: checks.local.json を読めません" "E21 noread"
  assert_lacks "$out" "ruby-syntax" "E21 noread"
  chmod 600 "$tmp/noread.json"
fi

# ---- 宣言との重ね方 (E22〜E26) ---------------------------------------------------------
cat > "$tmp/pass-check" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/pass-check"
decl() { # $1=出力の file  $2=edit_checks の JSON
  write_json "$1" '{ ARGV[1] => { "edit_checks" => JSON.parse(ARGV[2]) } }' "$plain_real" "$2"
}

# E22: file に一致する有効な宣言があれば、宣言だけが走る (既定は走らない)
decl "$tmp/d22.json" "[{\"name\":\"pass\",\"pattern\":\"\\\\.rb\$\",\"command\":[\"$tmp/pass-check\"]}]"
before=$(sr_count)
out=$(run_edit "$plain/bad.rb" "$tmp/d22.json") || fail "E22: hook must exit 0"
assert_silent "$out" "E22"
[ "$(sr_count)" -eq $((before + 1)) ] || fail "E22: exactly one check (the declared one) must run"
tail -n 1 "$sr_log" | grep -F -e "-- $tmp/pass-check $plain/bad.rb" >/dev/null || fail "E22: the declared check must run: $(tail -n 1 "$sr_log")"

# E23: repo に宣言があっても、その file に一致しなければ既定が走る
decl "$tmp/d23.json" "[{\"name\":\"txt\",\"pattern\":\"\\\\.txt\$\",\"command\":[\"$tmp/pass-check\"]}]"
out=$(run_edit "$plain/bad.rb" "$tmp/d23.json") || fail "E23: hook must exit 0"
assert_has "$out" "[ruby-syntax (既定)]" "E23"

# E24〜E26: 不正な宣言 (command が無い・壊れた regex・不正な上限) は警告して、既定は走る
decl "$tmp/d24.json" '[{"name":"nocmd","pattern":"\\.rb$"}]'
decl "$tmp/d25.json" "[{\"name\":\"re\",\"pattern\":\"(\",\"command\":[\"$tmp/pass-check\"]}]"
decl "$tmp/d26.json" "[{\"name\":\"limit\",\"pattern\":\"\\\\.rb\$\",\"command\":[\"$tmp/pass-check\"],\"max_seconds\":0}]"
for d in d24 d25 d26; do
  out=$(run_edit "$plain/bad.rb" "$tmp/$d.json") || fail "$d: hook must exit 0"
  assert_has "$out" "不正な check 宣言を無視しました" "$d"
  assert_has "$out" "[ruby-syntax (既定)]" "$d"
done

# ---- P1: PATH の git と ruby (E27) ------------------------------------------------------
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
{
  printf '#!/bin/sh\n'
  printf 'printf %%s\\\\n "$*" >> %s\n' "$(shq "$tmp/fake-git.log")"
  printf 'exit 1\n'
} > "$fake_bin/git"
{
  printf '#!/bin/sh\n'
  printf 'printf %%s\\\\n "$*" >> %s\n' "$(shq "$tmp/fake-ruby.log")"
  printf 'exec %s "$@"\n' "$(shq "$real_ruby")"
} > "$fake_bin/ruby"
chmod +x "$fake_bin/git" "$fake_bin/ruby"
out=$(edit_payload "$plain/bad.rb" | env PATH="$fake_bin:$PATH" AGENT_TOOLS_CHECKS_CONFIG="$tmp/d23.json" HOME="$tmp/home" \
  "$real_ruby" "$hook") || fail "E27: hook must exit 0"
assert_has "$out" "[ruby-syntax (既定)] exit 1" "E27"
[ ! -s "$tmp/fake-git.log" ] || fail "E27: the hook must not run git from PATH: $(cat "$tmp/fake-git.log")"
if [ -f "$tmp/fake-ruby.log" ] && grep -F -e "--disable=all" "$tmp/fake-ruby.log" >/dev/null; then
  fail "E27: the default check must not run ruby from PATH: $(cat "$tmp/fake-ruby.log")"
fi

# E28: safe-run を使えなければ、既定も起動せず「実行できません」を知らせる (exit 0)
make_deploy "$tmp/deploy-nosr" no
out=$(edit_payload "$plain/bad.rb" | env AGENT_TOOLS_CHECKS_CONFIG="$no_config" HOME="$tmp/home" \
  "$real_ruby" "$tmp/deploy-nosr/personal-fast-edit-check") || fail "E28: hook must exit 0"
assert_has "$out" "[ruby-syntax (既定)] check を実行できません (safe-run を使えません" "E28"

# ---- E30: changed-scope-qa は新しい key で変わらない ------------------------------------
qa_repo="$tmp/qa"
git init -q "$qa_repo"
printf 'base\n' > "$qa_repo/base.txt"
(cd "$qa_repo" && git add base.txt && git commit -qm seed)
qa_real=$(ruby -e 'print File.realpath(ARGV[0])' "$qa_repo")
cat > "$tmp/qa-fail" <<'EOF'
#!/bin/sh
echo "suite failed"
exit 1
EOF
chmod +x "$tmp/qa-fail"
write_json "$tmp/qa.json" '{ "default_edit_checks" => false,
  ARGV[1] => { "default_edit_checks" => false, "qa_checks" => [{ "name" => "suite", "command" => [ARGV[2]] }] } }' \
  "$qa_real" "$tmp/qa-fail"
printf 'dirty\n' > "$qa_repo/new.txt"
set +e
err=$(cd "$qa_repo" && printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
  | env AGENT_TOOLS_CHECKS_CONFIG="$tmp/qa.json" AGENT_TOOLS_QA_STATE_DIR="$tmp/qa-state" HOME="$tmp/home" \
      "$real_ruby" "$qa_hook" 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "E30: changed-scope-qa must still block a failing scope (rc=$rc): $err"
assert_has "$err" "suite failed" "E30"
[ -n "$(ls "$tmp/qa-state")" ] || fail "E30: changed-scope-qa must still write its state"

# X04: 設定はあるが、どの repo の entry にも当たらない .txt -> 何も起動しない (repo root の探索は process を使わない)
write_json "$tmp/other.json" '{ ARGV[1] => { "edit_checks" => [{ "name" => "any", "pattern" => ".", "command" => [ARGV[2]] }] } }' \
  "$tmp/elsewhere" "$tmp/pass-check"
before=$(sr_count)
out=$(run_edit "$plain/note.txt" "$tmp/other.json") || fail "X04: hook must exit 0"
assert_silent "$out" "X04"
[ "$(sr_count)" -eq "$before" ] || fail "X04: a non-target file must not start a check"

echo "ok: fast-edit-default-checks self-test"
