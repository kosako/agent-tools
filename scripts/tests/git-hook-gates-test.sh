#!/bin/sh
# personal-git-hook-dispatcher.rb / personal-public-safety-gate.rb /
# personal-ai-trailer-gate.rb の self-test。
# 純粋ロジック (scan / judge) は check_helper の Ruby unit check、git 連携 (staged diff /
# commit-msg / hooksPath 経由の dispatcher chain) は tmp repo での integration で検証する。
# 実 HOME / 実 git config には触れない (HOME / GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM を隔離)。
# secret 形の fixture は実行時に連結して作り、literal をこの file に置かない
# (この gate 自身の検査対象になるため)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

dispatcher_src="$repo_root/shared/scripts/personal-git-hook-dispatcher.rb"
pubsafe_src="$repo_root/shared/scripts/personal-public-safety-gate.rb"
trailer_src="$repo_root/shared/scripts/personal-ai-trailer-gate.rb"
for f in "$dispatcher_src" "$pubsafe_src" "$trailer_src"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- git / env の隔離 --------------------------------------------------------
# 実環境の git config・HOME を読ませない。agent marker も明示制御する (この test 自体が
# Claude / Codex セッション下で走るため、継承 env を必ず落としてから足す)。
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

# 人間 (marker なし) として実行するための env 前置。
as_human() {
  env -u CLAUDECODE -u CODEX_THREAD_ID -u CODEX_SANDBOX HOME="$tmp/home" "$@"
}
as_claude() {
  env -u CODEX_THREAD_ID -u CODEX_SANDBOX CLAUDECODE=1 HOME="$tmp/home" "$@"
}
as_codex() {
  env -u CLAUDECODE CODEX_THREAD_ID=test-thread HOME="$tmp/home" "$@"
}
mkdir -p "$tmp/home"

# secret 形 fixture (実行時連結。literal を置かない)
gh_token=$(printf 'ghp'; printf '_'; printf 'aaaaaaaaaabbbbbbbbbbccccccccccdddddd')

# ---- Ruby unit checks: 純粋ロジック ------------------------------------------
as_human ruby -r"$script_dir/lib/check_helper" - "$pubsafe_src" "$trailer_src" "$gh_token" <<'RUBY'
require "stringio"
require ARGV[0]
require ARGV[1]
gh_token = ARGV[2]

# 負例ケースの想定内診断 (warn) で test 出力を汚さない。check_helper の FAIL は
# capture の外で出るよう、判定呼び出しだけを包む。
def quiet
  orig = $stderr
  $stderr = StringIO.new
  yield
ensure
  $stderr = orig
end

# public-safety: scan_line
def hits(content, extra: [], home: nil)
  PublicSafetyGate.scan_line(content, extra, home).map { |name, _| name }
end

check("token 形を検出", hits("x = '#{gh_token}'").include?("github-token"))
check("aws key を検出", hits("key: " + "AKIA" + "IOSFODNN7EXAMPLE").include?("aws-access-key"))
check("private key block を検出",
      hits("-----BEGIN " + "RSA PRIVATE KEY-----").include?("private-key-block"))
check("平文は検出しない", hits("plain text line").empty?)
check("regex source 自身は検出しない (self-hosting)",
      hits("/\\bAKIA[0-9A-Z]{16}\\b/").empty?)
check("allow pragma で skip",
      hits("x = '#{gh_token}' # public-safety: allow").empty?)
check("home path literal を検出",
      hits("path: /Users/ghost-user/src", home: "/Users/ghost-user").include?("home-path"))
check("他人の /Users は検出しない",
      hits("path: /Users/someone-else/src", home: "/Users/ghost-user").empty?)
check("credential 代入は suspicious",
      PublicSafetyGate.scan_line("password = 'hunter2secret'", [], nil)
        .any? { |name, sev| name == "credential-assignment" && sev == :suspicious })
check("local pattern を definite で検出",
      PublicSafetyGate.scan_line("see internal-tool-x", [["local-pattern:1", /internal-tool-x/]], nil)
        .any? { |name, sev| name == "local-pattern:1" && sev == :definite })

# public-safety: scan_diff (file / line の帰属)
diff = <<~DIFF
  diff --git a/a.txt b/a.txt
  index 000..111 100644
  --- a/a.txt
  +++ b/a.txt
  @@ -0,0 +1,3 @@
  +clean line
  +x = '#{gh_token}'
  +tail line
DIFF
f = PublicSafetyGate.scan_diff(diff, [], nil)
check("scan_diff が file:line を帰属", f.size == 1 && f[0].file == "a.txt" && f[0].line == 2)
check("削除行は見ない",
      PublicSafetyGate.scan_diff("--- a/a.txt\n+++ b/a.txt\n@@ -1,1 +1,1 @@\n-x = '#{gh_token}'\n+clean\n", [], nil).empty?)

# H206-01 回帰: 追加行の内容が "++ " で始まっても header と誤認せず後続を取り逃さない
tricky = <<~DIFF
  diff --git a/a.txt b/a.txt
  --- a/a.txt
  +++ b/a.txt
  @@ -0,0 +1,3 @@
  +clean line
  +++ b/looks-like-header
  +x = '#{gh_token}'
DIFF
tf = PublicSafetyGate.scan_diff(tricky, [], nil)
check("hunk 内の '+++' 行で file を失わない (H206-01)",
      tf.size == 1 && tf[0].file == "a.txt" && tf[0].line == 3)

# should 回帰: quoted path の C-style escape を復号する
quoted = "diff --git \"a/ta\\tb.txt\" \"b/ta\\tb.txt\"\n--- \"a/ta\\tb.txt\"\n+++ \"b/ta\\tb.txt\"\n@@ -0,0 +1,1 @@\n+x = '#{gh_token}'\n"
qf = PublicSafetyGate.scan_diff(quoted, [], nil)
check("quoted path を復号して帰属 (tab)", qf.size == 1 && qf[0].file == "ta\tb.txt")

# local-only file 判定
check("*.local.md を検出",
      PublicSafetyGate.staged_local_only_files(["notes/x.local.md", "ok.md"]) == ["notes/x.local.md"])
check("*.local を検出",
      PublicSafetyGate.staged_local_only_files(["conf/app.local"]) == ["conf/app.local"])

# trailer: message_lines (comment / scissors 除去)
lines = AiTrailerGate.message_lines("subject\n# comment\nCo-Authored-By: Claude X <noreply@anthropic.com>\n# ------------------------ >8 ------------------------\nCo-Authored-By: Codex <bot@no-reply.example>\n")
check("comment 行を除く", !lines.include?("# comment"))
check("scissors 以降を除く", lines.none? { |l| l.include?("Codex") })

# trailer: judge
def msg(*trailers)
  ["subject", ""] + trailers
end
claude_tr = "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
codex_tr = "Co-Authored-By: Codex <codex@no-reply.example.com>"
human_tr = "Co-Authored-By: Alice <alice@example.com>"
bad_email = "Co-Authored-By: Claude Fable 5 <claude@example.com>"

check("人間 (marker なし) は無言 pass", quiet { AiTrailerGate.judge([], msg()) } == 0)
check("claude: トレーラ欠落は fail", quiet { AiTrailerGate.judge([:claude], msg()) } == 1)
check("claude: 正しいトレーラで pass", quiet { AiTrailerGate.judge([:claude], msg(claude_tr)) } == 0)
check("claude: 非 no-reply email は fail", quiet { AiTrailerGate.judge([:claude], msg(bad_email)) } == 1)
check("claude: Codex トレーラのみは fail", quiet { AiTrailerGate.judge([:claude], msg(codex_tr)) } == 1)
check("codex: 正しいトレーラで pass", quiet { AiTrailerGate.judge([:codex], msg(codex_tr)) } == 0)
check("混在は fail-closed", quiet { AiTrailerGate.judge([:claude], msg(claude_tr, codex_tr)) } == 1)
check("nested (両 marker): どちらかで pass",
      quiet { AiTrailerGate.judge([:claude, :codex], msg(codex_tr)) } == 0)
check("nested: トレーラなしは fail", quiet { AiTrailerGate.judge([:claude, :codex], msg()) } == 1)
check("人間 co-author は AI トレーラに数えない", quiet { AiTrailerGate.judge([:claude], msg(human_tr)) } == 1)
check("人間 co-author 併記は妨げない",
      quiet { AiTrailerGate.judge([:claude], msg(claude_tr, human_tr)) } == 0)
# H206-02 回帰: 本文中 (末尾 trailer block 外) のトレーラ行は数えない
check("本文中のトレーラ行では pass しない (H206-02)",
      quiet { AiTrailerGate.judge([:claude], ["subject", "", claude_tr, "", "more prose"]) } == 1)
check("trailer_block は末尾段落のみ返す",
      AiTrailerGate.trailer_block(["subject", "", "body", "", claude_tr, human_tr]) == [claude_tr, human_tr])

# env marker の解釈
check("CLAUDECODE で claude", AiTrailerGate.agents_from_env({ "CLAUDECODE" => "1" }) == [:claude])
check("CODEX_THREAD_ID で codex",
      AiTrailerGate.agents_from_env({ "CODEX_THREAD_ID" => "t" }) == [:codex])
check("両方で nested", AiTrailerGate.agents_from_env({ "CLAUDECODE" => "1", "CODEX_SANDBOX" => "x" }) == [:claude, :codex])
check("空値は marker にしない", AiTrailerGate.agents_from_env({ "CLAUDECODE" => "" }) == [])

exit(@failed.zero? ? 0 : 1)
RUBY

# ---- integration: public-safety-gate を staged diff で -----------------------
repo="$tmp/repo1"
git init -q "$repo"

echo "hello" > "$repo/ok.txt"
(cd "$repo" && git add ok.txt)
(cd "$repo" && as_human ruby "$pubsafe_src") || fail "clean staged diff should pass (unborn HEAD)"

printf 'token = "%s"\n' "$gh_token" > "$repo/leak.txt"
(cd "$repo" && git add leak.txt)
set +e
out=$(cd "$repo" && as_human ruby "$pubsafe_src" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "staged token should block (rc=$rc)"
echo "$out" | grep -q "leak.txt:1" || fail "finding should name file:line: $out"
echo "$out" | grep -q "github-token" || fail "finding should name pattern: $out"
echo "$out" | grep -q "$gh_token" && fail "finding must not echo the secret value"
(cd "$repo" && git rm -q --cached leak.txt && rm leak.txt)

# local-only file の forced add
echo "private note" > "$repo/x.local.md"
(cd "$repo" && git add -f x.local.md)
set +e
(cd "$repo" && as_human ruby "$pubsafe_src" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "*.local.md staged add should block (rc=$rc)"
(cd "$repo" && git rm -q --cached x.local.md && rm x.local.md)

# H206-06 回帰: 既存 tracked file の rename でも local-only 検査にかかる
(cd "$repo" && as_human git commit -qm "seed for rename")
(cd "$repo" && git mv ok.txt renamed.local && git add -A)
set +e
(cd "$repo" && as_human ruby "$pubsafe_src" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "rename onto *.local should block (rc=$rc, H206-06)"
(cd "$repo" && git mv renamed.local ok.txt)

# local pattern file (HOME 配下) / invalid regex は exit 2
mkdir -p "$tmp/home/.config/agent-tools"
echo "secret-project-zeta" > "$tmp/home/.config/agent-tools/public-safety-patterns.local"
echo "mentions secret-project-zeta here" > "$repo/doc.md"
(cd "$repo" && git add doc.md)
set +e
(cd "$repo" && as_human ruby "$pubsafe_src" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "local pattern should block (rc=$rc)"
echo "([" > "$tmp/home/.config/agent-tools/public-safety-patterns.local"
set +e
out=$(cd "$repo" && as_human ruby "$pubsafe_src" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid local pattern regex should be a loud config error (rc=$rc)"
# H206-03 回帰: 診断に regex 本文を含めない (private パターン置き場のため)
case "$out" in
  *"(["*) fail "invalid-regex diagnostic must not echo the pattern body: $out" ;;
esac
echo "$out" | grep -q "public-safety-patterns.local:1" || fail "diagnostic should carry file:line: $out"
rm "$tmp/home/.config/agent-tools/public-safety-patterns.local"
(cd "$repo" && git rm -q --cached doc.md && rm doc.md)

# suspicious は警告のみで pass
printf 'password = "hunter2secret"\n' > "$repo/warn.txt"
(cd "$repo" && git add warn.txt)
set +e
out=$(cd "$repo" && as_human ruby "$pubsafe_src" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "suspicious finding should not block (rc=$rc)"
echo "$out" | grep -q "credential-assignment" || fail "suspicious finding should warn: $out"

# ---- integration: dispatcher (配備形) + core.hooksPath 経由の git commit ------
deploy="$tmp/deploy"
mkdir -p "$deploy"
for pair in "personal-git-hook-dispatcher:$dispatcher_src" \
            "personal-public-safety-gate:$pubsafe_src" \
            "personal-ai-trailer-gate:$trailer_src"; do
  name=${pair%%:*}
  src=${pair#*:}
  cp "$src" "$deploy/$name"
  chmod +x "$deploy/$name"
done

hooksdir="$tmp/hooks"
mkdir -p "$hooksdir"
for stage in pre-commit commit-msg; do
  printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$deploy/personal-git-hook-dispatcher" "$stage" > "$hooksdir/$stage"
  chmod +x "$hooksdir/$stage"
done

repo2="$tmp/repo2"
git init -q "$repo2"
(cd "$repo2" && git config core.hooksPath "$hooksdir")

# 人間: clean commit が通る
echo one > "$repo2/f.txt"
(cd "$repo2" && git add f.txt && as_human git commit -qm "human commit") \
  || fail "human clean commit should pass through dispatcher"

# 人間: secret は pre-commit stage で block される
printf 'x = "%s"\n' "$gh_token" > "$repo2/leak.txt"
(cd "$repo2" && git add leak.txt)
set +e
(cd "$repo2" && as_human git commit -qm "leak" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "secret commit should be blocked via hooksPath dispatcher"
(cd "$repo2" && git rm -q --cached leak.txt && rm leak.txt)

# claude: trailer なしは commit-msg stage で block、trailer ありは通る
echo two > "$repo2/g.txt"
(cd "$repo2" && git add g.txt)
set +e
(cd "$repo2" && as_claude git commit -qm "agent commit without trailer" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "claude commit without trailer should be blocked"
(cd "$repo2" && as_claude git commit -qm "agent commit

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>") \
  || fail "claude commit with trailer should pass"

# codex marker + Codex trailer
echo three > "$repo2/h.txt"
(cd "$repo2" && git add h.txt)
(cd "$repo2" && as_codex git commit -qm "codex commit

Co-Authored-By: Codex <codex@no-reply.example.com>") \
  || fail "codex commit with trailer should pass"

# merge commit (MERGE_HEAD) は trailer 対象外
(cd "$repo2" && git checkout -q -b feature && echo m > m.txt && git add m.txt \
  && as_claude git commit -qm "feature work

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" \
  && git checkout -q main)
(cd "$repo2" && echo base > base.txt && git add base.txt \
  && as_claude git commit -qm "base work

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>")
(cd "$repo2" && as_claude git merge --no-ff -q -m "merge feature (no trailer)" feature) \
  || fail "merge commit without trailer should pass (MERGE_HEAD exemption)"

# repo 自身の hook への chain: 実行される + 失敗が伝播する
repo3="$tmp/repo3"
git init -q "$repo3"
(cd "$repo3" && git config core.hooksPath "$hooksdir")
mkdir -p "$repo3/.git/hooks"
printf '#!/bin/sh\ntouch "%s/chained"\nexit 0\n' "$tmp" > "$repo3/.git/hooks/pre-commit"
chmod +x "$repo3/.git/hooks/pre-commit"
echo c > "$repo3/c.txt"
(cd "$repo3" && git add c.txt && as_human git commit -qm "chain ok") \
  || fail "commit with passing chained hook should succeed"
[ -f "$tmp/chained" ] || fail "repo's own pre-commit hook should be chained after gates"

printf '#!/bin/sh\nexit 7\n' > "$repo3/.git/hooks/pre-commit"
echo d > "$repo3/d.txt"
(cd "$repo3" && git add d.txt)
set +e
(cd "$repo3" && as_human git commit -qm "chain fail" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "failing chained hook should block the commit"

# chain 先の exit code が等値で伝播する (dispatcher 直接呼び出しで pin)
set +e
(cd "$repo3" && as_human "$deploy/personal-git-hook-dispatcher" pre-commit >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 7 ] || fail "chained hook exit code should propagate verbatim (rc=$rc, want 7)"

# chain 先が dispatcher 自身 (誤設定) なら skip して成功する
ln -sf "$deploy/personal-git-hook-dispatcher" "$repo3/.git/hooks/pre-commit"
set +e
out=$(cd "$repo3" && as_human git commit -qm "self chain" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "self-referential chain should be skipped, not looped (rc=$rc): $out"

# H206-04 回帰: chain 先が shim (間接的に dispatcher へ戻る) でも再入 sentinel で loop しない。
# 回帰時は無限再帰になるため timeout で保護する。
# 直前の test が残した symlink を必ず消してから書く (redirect は symlink を辿り、
# deploy の dispatcher 本体を上書きしてしまう)。
rm -f "$repo3/.git/hooks/pre-commit"
printf '#!/bin/sh\nexec "%s" pre-commit "$@"\n' "$deploy/personal-git-hook-dispatcher" \
  > "$repo3/.git/hooks/pre-commit"
chmod +x "$repo3/.git/hooks/pre-commit"
echo e > "$repo3/e.txt"
(cd "$repo3" && git add e.txt)
set +e
out=$(cd "$repo3" && as_human ruby -rtimeout -e \
  'Timeout.timeout(30) { ok = system(*ARGV); exit(ok ? 0 : (($?.exitstatus || 1))) }' \
  -- git commit -qm "shim loop" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "shim-indirect chain should be loop-guarded (rc=$rc, H206-04): $out"
echo "$out" | grep -q "re-entrant" || fail "loop guard should be visible in output: $out"

# ---- dispatcher の usage / fail-closed ---------------------------------------
set +e
as_human ruby "$dispatcher_src" unknown-stage >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown stage should exit 2 (rc=$rc)"

sparse="$tmp/sparse"
mkdir -p "$sparse"
cp "$dispatcher_src" "$sparse/personal-git-hook-dispatcher"
chmod +x "$sparse/personal-git-hook-dispatcher"
set +e
out=$(cd "$repo2" && as_human "$sparse/personal-git-hook-dispatcher" pre-commit 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing gate should fail closed with exit 2 (rc=$rc)"
echo "$out" | grep -q "fail-closed" || fail "missing gate message should say fail-closed: $out"

# 再入 sentinel の単体挙動: guard env が立っていれば gate 解決前に即 0 で返る
# (sparse dir = gate 欠損でも 0 になることで、guard が先に効くと分かる)
set +e
(cd "$repo2" && as_human env AGENT_TOOLS_GIT_HOOK_ACTIVE_PRE_COMMIT=1 \
  "$sparse/personal-git-hook-dispatcher" pre-commit >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "guard env should short-circuit before gate resolution (rc=$rc)"

echo "ok: git-hook-gates self-test"
