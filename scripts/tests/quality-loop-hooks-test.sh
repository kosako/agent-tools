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
printf '%s\n' "\$*" >> "$tmp/check-argv.log"
if [ -f "$tmp/check-fail" ]; then
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
echo "$out" | grep -q "未解消" || fail "should warn non-blockingly on cached failure: $out"

# stop_hook_active=true では新 scope の失敗でも block しない
echo again >> "$repo/base.txt"
set +e
out=$(cd "$repo" && run_qa true 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "stop_hook_active must never block (rc=$rc)"
echo "$out" | grep -q "再 block しません" || fail "should report failure non-blockingly: $out"
rm "$tmp/check-fail"

# check コマンド不在 -> 警告降格・block しない・cache しない
ruby -rjson -e '
File.write(ARGV[1], JSON.generate({ARGV[0] => {"qa_checks" => [{"name" => "gone", "command" => ["/nonexistent/check"]}]}}))
' "$repo_real" "$conf"
echo yet >> "$repo/base.txt"
set +e
out=$(cd "$repo" && run_qa false 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "missing check tool must not block (rc=$rc)"
echo "$out" | grep -q "実行できません" || fail "missing tool should warn: $out"

# 宣言なし repo -> 無言 no-op
out=$(cd "$other" && run_qa false) || fail "undeclared repo qa should exit 0"
[ -z "$out" ] || fail "undeclared repo qa should be silent: $out"

echo "ok: quality-loop-hooks self-test"
