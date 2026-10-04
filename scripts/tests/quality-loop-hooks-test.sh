#!/bin/sh
# personal-fast-edit-check.rb / personal-changed-scope-qa.rb の self-test。
# 設定は AGENT_TOOLS_CHECKS_CONFIG、state は AGENT_TOOLS_QA_STATE_DIR で隔離し、
# 実 HOME / 実 config には触れない。check コマンドは tmp 内の記録付き fake を使う。
# hook payload は stdin JSON fixture。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

edit_src="$repo_root/shared/scripts/personal-fast-edit-check.rb"
qa_src="$repo_root/shared/scripts/personal-changed-scope-qa.rb"
for f in "$edit_src" "$qa_src"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

repo="$tmp/repo"
git init -q "$repo"
echo base > "$repo/base.txt"
(cd "$repo" && git add base.txt && git commit -qm seed)
repo_real=$(ruby -e 'puts File.realpath(ARGV[0])' "$repo")

# 記録付き fake check: 引数を log に書き、FAKE_CHECK_RC で成否を制御
cat > "$tmp/fake-check" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> $(shq "$tmp/check-argv.log")
if [ -f $(shq "$tmp/check-fail") ]; then
  echo "lint error: something is wrong"
  exit 1
fi
exit 0
EOF
chmod +x "$tmp/fake-check"

conf="$tmp/checks.local.json"
ruby -rjson -e '
root = ARGV[0]; fake = ARGV[1]
File.write(ARGV[2], JSON.generate({
  root => {
    "edit_checks" => [{"name" => "fake-lint", "pattern" => "\\.rb$", "command" => [fake]}],
    "qa_checks" => [{"name" => "fake-suite", "command" => [fake]}],
  }
}))
' "$repo_real" "$tmp/fake-check" "$conf"

run_edit() { # $1=file_path (payload)  env: config
  printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | env AGENT_TOOLS_CHECKS_CONFIG="$conf" HOME="$tmp/home" ruby "$edit_src"
}
run_qa() { # $1=stop_hook_active  cwd 前提: repo 内
  printf '{"hook_event_name":"Stop","stop_hook_active":%s}' "$1" \
    | env AGENT_TOOLS_CHECKS_CONFIG="$conf" AGENT_TOOLS_QA_STATE_DIR="$tmp/qa-state" \
        HOME="$tmp/home" ruby "$qa_src"
}
assert_qa_warning() {
  printf '%s' "$1" | ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    abort "Stop warning must contain only a user-facing systemMessage" unless
      data.is_a?(Hash) && data.keys == ["systemMessage"] &&
      data["systemMessage"].is_a?(String) && !data["systemMessage"].empty?
  ' || fail "warning must not request continuation: $1"
}
mkdir -p "$tmp/home"

# ---- fast-edit-check ----------------------------------------------------------
echo 'puts 1' > "$repo/a.rb"

# pass: check 成功 -> 無出力・exit 0・check は実行されている
out=$(run_edit "$repo/a.rb") || fail "edit-check should exit 0 on pass"
[ -z "$out" ] || fail "pass should be silent: $out"
grep -q "a.rb" "$tmp/check-argv.log" || fail "check should have received the file"

# fail: additionalContext に要約・exit 0 (block しない)
touch "$tmp/check-fail"
out=$(run_edit "$repo/a.rb") || fail "edit-check must not block on failure"
echo "$out" | grep -q '"hookEventName":"PostToolUse"' || fail "should emit PostToolUse context: $out"
echo "$out" | grep -q "fake-lint" || fail "should name the failed check: $out"
echo "$out" | grep -q "lint error" || fail "should include check output: $out"
rm "$tmp/check-fail"

# pattern 不一致 (.txt) -> 無言 no-op
echo x > "$repo/b.txt"
out=$(run_edit "$repo/b.txt") || fail "no-match should exit 0"
[ -z "$out" ] || fail "no-match should be silent: $out"

# 宣言なし repo -> 無言 no-op
other="$tmp/other"
git init -q "$other" && echo 'puts 1' > "$other/x.rb"
out=$(run_edit "$other/x.rb") || fail "undeclared repo should exit 0"
[ -z "$out" ] || fail "undeclared repo should be silent: $out"

# repo 外 file -> 無言 no-op
echo 'puts 1' > "$tmp/loose.rb"
out=$(run_edit "$tmp/loose.rb") || fail "non-repo file should exit 0"
[ -z "$out" ] || fail "non-repo file should be silent: $out"

# 壊れた設定 -> 設定エラーを steer (無言で握り潰さない)・exit 0
echo '{broken' > "$tmp/broken.json"
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$repo/a.rb" \
  | env AGENT_TOOLS_CHECKS_CONFIG="$tmp/broken.json" HOME="$tmp/home" ruby "$edit_src") \
  || fail "broken config should still exit 0"
echo "$out" | grep -q "設定エラー" || fail "broken config should be surfaced: $out"

# 設定ファイル自体なし -> 無言 no-op
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$repo/a.rb" \
  | env AGENT_TOOLS_CHECKS_CONFIG="$tmp/nonexistent.json" HOME="$tmp/home" ruby "$edit_src") \
  || fail "absent config should exit 0"
[ -z "$out" ] || fail "absent config should be silent: $out"

# ---- changed-scope-qa ---------------------------------------------------------
# clean tree -> 無言 no-op (check は走らない)
: > "$tmp/check-argv.log"
(cd "$repo" && git add -A && git commit -qm wip)
out=$(cd "$repo" && run_qa false) || fail "clean tree should exit 0"
[ -z "$out" ] || fail "clean tree should be silent: $out"
[ ! -s "$tmp/check-argv.log" ] || fail "clean tree should not run checks"

# dirty + check pass -> 無言 pass・cache に pass 記録
echo change >> "$repo/base.txt"
out=$(cd "$repo" && run_qa false) || fail "dirty+pass should exit 0"
[ -z "$out" ] || fail "dirty+pass should be silent: $out"
[ -s "$tmp/check-argv.log" ] || fail "dirty tree should run checks"

# 同一 scope の再 Stop -> cache hit で check を再実行しない
: > "$tmp/check-argv.log"
out=$(cd "$repo" && run_qa false) || fail "cached pass should exit 0"
[ ! -s "$tmp/check-argv.log" ] || fail "same scope should not rerun checks (cache)"

# scope が変わり check fail -> exit 2 で block・stderr に要約
touch "$tmp/check-fail"
echo more >> "$repo/base.txt"
set +e
err=$(cd "$repo" && run_qa false 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "new dirty scope with failing check should block (rc=$rc)"
echo "$err" | grep -q "fake-suite" || fail "block message should name the check: $err"

# 同一 scope の失敗を再 block しない (非ブロッキング警告に降格)
set +e
out=$(cd "$repo" && run_qa false 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "same failing scope must not re-block (rc=$rc)"
assert_qa_warning "$out"
echo "$out" | grep -q "未解消" || fail "should warn non-blockingly on cached failure: $out"

# 継続後の Stop を繰り返しても、モデルへの追加 feedback を発行しない (#231)。
: > "$tmp/check-argv.log"
for attempt in 1 2; do
  out=$(cd "$repo" && run_qa true) || fail "continued cached failure should exit 0"
  assert_qa_warning "$out"
done
[ ! -s "$tmp/check-argv.log" ] || fail "cached failure should not rerun checks"

# stop_hook_active=true では新 scope の失敗でも block しない
echo again >> "$repo/base.txt"
set +e
out=$(cd "$repo" && run_qa true 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "stop_hook_active must never block (rc=$rc)"
assert_qa_warning "$out"
echo "$out" | grep -q "再 block しません" || fail "should report failure non-blockingly: $out"
rm "$tmp/check-fail"

# check コマンド不在 -> 警告降格・block しない・missing として再試行する
ruby -rjson -e '
File.write(ARGV[1], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "gone", "command" => [ARGV[2]]}]}}))
' "$repo_real" "$conf" "$tmp/gone-check"
echo yet >> "$repo/base.txt"
set +e
out=$(cd "$repo" && run_qa false 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "missing check tool must not block (rc=$rc)"
assert_qa_warning "$out"
echo "$out" | grep -q "実行できません" || fail "missing tool should warn: $out"
out=$(cd "$repo" && run_qa false) || fail "cached missing check should exit 0"
assert_qa_warning "$out"

# scope / 宣言を変えずに missing check を復旧すると、再試行して無言 pass へ戻る。
cat > "$tmp/gone-check" <<EOF
#!/bin/sh
printf 'ran\n' >> $(shq "$tmp/gone-argv.log")
exit 0
EOF
chmod +x "$tmp/gone-check"
out=$(cd "$repo" && run_qa false) || fail "recovered check should pass"
[ -z "$out" ] || fail "recovered check should be silent: $out"
[ -s "$tmp/gone-argv.log" ] || fail "recovered check should run on the same scope"
: > "$tmp/gone-argv.log"
out=$(cd "$repo" && run_qa false) || fail "recovered cached pass should exit 0"
[ -z "$out" ] || fail "recovered cached pass should be silent: $out"
[ ! -s "$tmp/gone-argv.log" ] || fail "recovered cached pass should not rerun checks"

# 宣言なし repo -> 無言 no-op
out=$(cd "$other" && run_qa false) || fail "undeclared repo qa should exit 0"
[ -z "$out" ] || fail "undeclared repo qa should be silent: $out"

# ---- R1 回帰: fingerprint の網羅 (untracked 内容 / check 定義) ------------------
# 状態リセット (config を fake-suite に戻し、working tree を clean に)
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "fake-suite", "command" => [ARGV[1]]}]}}))
' "$repo_real" "$tmp/fake-check" "$conf"
(cd "$repo" && git add -A && git commit -qm clean)

# untracked の「内容変更」で cache が無効化される (status 上は同じ ?? path)
echo v1 > "$repo/u.txt"
(cd "$repo" && run_qa false >/dev/null) || fail "untracked v1 should pass"
: > "$tmp/check-argv.log"
(cd "$repo" && run_qa false >/dev/null) || fail "cache hit should pass"
[ ! -s "$tmp/check-argv.log" ] || fail "same untracked content should hit cache"
echo v2 > "$repo/u.txt"
(cd "$repo" && run_qa false >/dev/null) || fail "untracked v2 should pass"
[ -s "$tmp/check-argv.log" ] || fail "untracked content change must invalidate cache (R1)"

# untracked symlink の向き先変更で cache が無効化される (dangling でも。R2 回帰)
ln -s missing-a "$repo/lnk"
(cd "$repo" && run_qa false >/dev/null) || fail "dangling symlink v1 should pass"
: > "$tmp/check-argv.log"
ln -sf missing-b "$repo/lnk"
(cd "$repo" && run_qa false >/dev/null) || fail "dangling symlink v2 should pass"
[ -s "$tmp/check-argv.log" ] || fail "symlink retarget must invalidate cache (R2)"
rm "$repo/lnk"

# check 定義の変更で cache が無効化される
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "fake-suite-2", "command" => [ARGV[1]]}]}}))
' "$repo_real" "$tmp/fake-check" "$conf"
: > "$tmp/check-argv.log"
(cd "$repo" && run_qa false >/dev/null) || fail "renamed check should pass"
[ -s "$tmp/check-argv.log" ] || fail "check definition change must invalidate cache (R1)"

# ---- R1 回帰: missing と実 failure の混在 (missing の分離保持と再試行) ----------
cat > "$tmp/later-tool" <<EOF
#!/bin/sh
printf 'ran\n' >> $(shq "$tmp/later-argv.log")
exit 0
EOF
# (まだ +x を付けない = EACCES の spawn 失敗)
ruby -rjson -e '
File.write(ARGV[3], JSON.generate({ARGV[0] => {"qa_checks" => [
  {"name" => "failing", "command" => [ARGV[1]]},
  {"name" => "later", "command" => [ARGV[2]]}
]}}))
' "$repo_real" "$tmp/fake-check" "$tmp/later-tool" "$conf"
touch "$tmp/check-fail"
echo mix >> "$repo/u.txt"
set +e
err=$(cd "$repo" && run_qa false 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "real failure should still block despite missing check (rc=$rc)"
echo "$err" | grep -q "未実行の check: later" || fail "block message should list missing: $err"

# 環境が直る (実行可能になる) と、同一 scope の cache-hit でも missing だけ再試行される
chmod +x "$tmp/later-tool"
set +e
out=$(cd "$repo" && run_qa false 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "cache-hit must not re-block (rc=$rc)"
assert_qa_warning "$out"
[ -s "$tmp/later-argv.log" ] || fail "missing check must be retried on cache hit (R1)"
echo "$out" | grep -q "未解消" || fail "unresolved failure should still be warned: $out"
rm "$tmp/check-fail"

# ---- R1 回帰: EACCES (実行権限なし) も spawn 失敗として警告降格 -----------------
: > "$tmp/noexec"
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "noexec", "command" => [ARGV[1]]}]}}))
' "$repo_real" "$tmp/noexec" "$conf"
echo eaccess >> "$repo/u.txt"
set +e
out=$(cd "$repo" && run_qa false 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "EACCES must not block (rc=$rc)"
assert_qa_warning "$out"
echo "$out" | grep -q "実行できません" || fail "EACCES should warn as missing (R1): $out"

# 不正な check 宣言しかない場合も、構成エラーはユーザー警告に留める。
ruby -rjson -e '
File.write(ARGV[1], JSON.generate({ARGV[0] => {"qa_checks" => [{"command" => "not-an-array"}]}}))
' "$repo_real" "$conf"
out=$(cd "$repo" && run_qa false) || fail "invalid check declaration should exit 0"
assert_qa_warning "$out"
echo "$out" | grep -q "設定エラー" || fail "invalid declaration should warn: $out"

# ---- #373: signal で終わった check は起動失敗ではなく実 failure (block 1 回、診断に signal 名) ----
# (hook の timeout や中断では hook 自身も止まるので、ここに来るのは check だけが落ちたとき)
cat > "$tmp/sig-check" <<'EOF'
#!/bin/sh
kill -TERM $$
EOF
chmod +x "$tmp/sig-check"
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "sig", "command" => [ARGV[1]]}]}}))
' "$repo_real" "$tmp/sig-check" "$conf"
echo signaled >> "$repo/u.txt"
set +e
err=$(cd "$repo" && run_qa false 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "signaled check must block as a failure (rc=$rc): $err"
echo "$err" | grep -q "SIGTERM" || fail "block message should name the signal: $err"
# 同じ scope では failure として cache され、未実行 (missing) として扱われない
set +e
out=$(cd "$repo" && run_qa false 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "cached signaled failure must not re-block (rc=$rc)"
echo "$out" | grep -q "未解消" || fail "cached signaled failure should warn as unresolved: $out"
if echo "$out" | grep -q "実行できません"; then fail "signaled check must not be reported as missing: $out"; fi
# 出力が要約の打ち切り (2000 文字) より長くても、signal 名は要約に残る (#381 review CSQA-02)
cat > "$tmp/sig-long-check" <<'EOF'
#!/bin/sh
awk 'BEGIN { for (i = 0; i < 80; i++) printf "%s\n", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
kill -TERM $$
EOF
chmod +x "$tmp/sig-long-check"
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "sig-long", "command" => [ARGV[1]]}]}}))
' "$repo_real" "$tmp/sig-long-check" "$conf"
echo signaled-long >> "$repo/u.txt"
set +e
err=$(cd "$repo" && run_qa false 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "signaled check with long output must block (rc=$rc)"
echo "$err" | grep -q "truncated" || fail "long output should be truncated in the summary: $err"
echo "$err" | grep -q "SIGTERM" || fail "signal name must survive truncation of a long output"

# ---- #373: 初回 commit 前 (HEAD が無い) の repo でも、stage 済み / 未 stage の内容の変化で再検査する ----
unborn="$tmp/unborn"
git init -q "$unborn"
unborn_real=$(ruby -e 'puts File.realpath(ARGV[0])' "$unborn")
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "fake-suite", "command" => [ARGV[1]]}]}}))
' "$unborn_real" "$tmp/fake-check" "$conf"
echo v1 > "$unborn/f.txt"
(cd "$unborn" && git add f.txt)
: > "$tmp/check-argv.log"
(cd "$unborn" && run_qa false >/dev/null) || fail "unborn staged v1 should pass"
[ -s "$tmp/check-argv.log" ] || fail "unborn repo should run checks"
: > "$tmp/check-argv.log"
(cd "$unborn" && run_qa false >/dev/null) || fail "unborn cache hit should pass"
[ ! -s "$tmp/check-argv.log" ] || fail "unborn same scope should hit the cache"
# 内容を変えて再 stage しても status は "A " のまま。stage 済みの内容が指紋に入っていないと cache に当たる
echo v2 > "$unborn/f.txt"
(cd "$unborn" && git add f.txt)
(cd "$unborn" && run_qa false >/dev/null) || fail "unborn staged v2 should pass"
[ -s "$tmp/check-argv.log" ] || fail "re-staged content change must rerun checks in an unborn repo"
# 未 stage の内容だけを変えても status は "AM" のまま。未 stage の差分も指紋に入る
echo v3 > "$unborn/f.txt"
(cd "$unborn" && run_qa false >/dev/null) || fail "unborn unstaged v3 should pass"
: > "$tmp/check-argv.log"
echo v4 > "$unborn/f.txt"
(cd "$unborn" && run_qa false >/dev/null) || fail "unborn unstaged v4 should pass"
[ -s "$tmp/check-argv.log" ] || fail "unstaged content change must rerun checks in an unborn repo"

# ---- #373: 指紋の材料の git が失敗したら判定不能として gate しない (check を走らせず、cache もしない) ----
realgit=$(command -v git)
mkdir -p "$tmp/failgit"
cat > "$tmp/failgit/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = diff ] && exit 128; done
exec $(shq "$realgit") "\$@"
EOF
chmod +x "$tmp/failgit/git"
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "fake-suite", "command" => [ARGV[1]]}]}}))
' "$repo_real" "$tmp/fake-check" "$conf"
touch "$tmp/check-fail"
echo diff-fails >> "$repo/u.txt"
: > "$tmp/check-argv.log"
set +e
out=$(cd "$repo" && PATH="$tmp/failgit:$PATH" && export PATH && run_qa false 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "failed git diff must not gate (rc=$rc): $out"
[ ! -s "$tmp/check-argv.log" ] || fail "failed git diff must not run checks"
# 同じ scope を git が使える状態で回すと、cache に当たらず検査して block する
set +e
err=$(cd "$repo" && run_qa false 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "after git recovers the scope must be checked (rc=$rc): $err"
# HEAD の検出が unborn (exit 1) 以外で失敗したら (128 など)、unborn とみなさず判定不能にする (#381 review CSQA-01)
cat > "$tmp/failgit/git" <<EOF
#!/bin/sh
# repo root の検出 (rev-parse --show-toplevel) は通し、HEAD の検出 (rev-parse --verify) だけを失敗させる
for a in "\$@"; do [ "\$a" = --verify ] && exit 128; done
exec $(shq "$realgit") "\$@"
EOF
chmod +x "$tmp/failgit/git"
echo head-fails >> "$repo/u.txt"
: > "$tmp/check-argv.log"
set +e
out=$(cd "$repo" && PATH="$tmp/failgit:$PATH" && export PATH && run_qa false 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "failed HEAD lookup must not gate (rc=$rc): $out"
[ ! -s "$tmp/check-argv.log" ] || fail "failed HEAD lookup must not be treated as unborn (checks ran)"
rm "$tmp/check-fail"

# ---- R1 回帰: fast-edit-check の不正 entry 可視化と総量 truncate ---------------
ruby -rjson -e '
File.write(ARGV[2], JSON.generate({ARGV[0] => {"edit_checks" => [
  {"name" => "bad-entry", "pattern" => "\\.rb$", "command" => "not-an-array"},
  {"name" => "broken-re", "pattern" => "([", "command" => [ARGV[1]]},
  {"name" => "big1", "pattern" => "\\.rb$", "command" => [ARGV[1]]},
  {"name" => "big2", "pattern" => "\\.rb$", "command" => [ARGV[1]]}
]}}))
' "$repo_real" "$tmp/big-fail" "$conf"
cat > "$tmp/big-fail" <<'EOF'
#!/bin/sh
awk 'BEGIN { for (i = 0; i < 60; i++) printf "%s\n", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
exit 1
EOF
chmod +x "$tmp/big-fail"
out=$(run_edit "$repo/a.rb") || fail "edit-check with invalid entries should exit 0"
echo "$out" | grep -q "設定エラー" || fail "invalid entries should be surfaced (R1): $out"
echo "$out" | grep -q "bad-entry\|edit_checks\[0\]" || fail "invalid entry should be named: $out"
echo "$out" | grep -q "broken-re" || fail "broken regex entry should be named: $out"
[ "${#out}" -lt 3500 ] || fail "total output should be capped (R1): length=${#out}"
echo "$out" | grep -q "truncated" || fail "total cap should be visible: $out"

ruby "$script_dir/fast-edit-check-payload-test.rb" "$edit_src"

echo "ok: quality-loop-hooks self-test"
