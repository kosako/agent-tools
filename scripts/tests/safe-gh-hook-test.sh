#!/bin/sh
# personal-safe-gh-hook.rb の self-test。
# PreToolUse hook の純粋ロジック (command 文字列 -> steer 有無) と出力契約を fixture で検証する。
# 実 hook 配線 (settings.json) は CI 外 (実機検証。docs/runtime-injection-defense.md「検証境界」)。
# network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-safe-gh-hook.rb"

[ -f "$src" ] || { echo "FAIL: missing $src" >&2; exit 1; }

# check / @failed は lib/check_helper.rb を -r で読み込んで共有する。
ruby -r"$script_dir/lib/check_helper" - "$src" "$repo_root/shared/skills/personal-review-request/SKILL.md" <<'RUBY'
require "json"
require "stringio"
require ARGV[0]

# ---- untrusted_gh_read_reason: 検出する (positive) ----
def reason(cmd)
  SafeGhHook.untrusted_gh_read_reason(cmd)
end

check("bare issue view -> view (human 出力に本文)", reason("gh issue view 12") == SafeGhHook::REASON_VIEW)
check("bare pr view -> view", reason("gh pr view 3") == SafeGhHook::REASON_VIEW)
check("pr view --comments -> comments", reason("gh pr view 3 --comments") == SafeGhHook::REASON_COMMENTS)
check("issue view --json body -> view", reason("gh issue view 5 --json body,title") == SafeGhHook::REASON_VIEW)
check("issue view --json=comments -> view", reason("gh issue view 5 --json=comments") == SafeGhHook::REASON_VIEW)
check("issue list --json body -> list", reason("gh issue list --json number,body") == SafeGhHook::REASON_LIST)
check("api issues -> api", reason("gh api repos/o/r/issues/1") == SafeGhHook::REASON_API)
check("api comments -> api", reason("gh api repos/o/r/issues/1/comments") == SafeGhHook::REASON_API)
check("api pulls -> api", reason("gh api repos/o/r/pulls/9") == SafeGhHook::REASON_API)
# env 前置・segment・subshell・pipe を跨いでも検出する
check("env prefix", reason("GH_PAGER=cat gh issue view 1") == SafeGhHook::REASON_VIEW)
check("after &&", reason("ls && gh pr view 2 --comments") == SafeGhHook::REASON_COMMENTS)
# --json の reviews / latestReviews / commits も他人の本文を返す (#429)
%w[reviews latestReviews commits].each do |f|
  check("pr view --json #{f} -> view (#429)", reason("gh pr view 12 --json #{f}") == SafeGhHook::REASON_VIEW)
end
check("pr list --json number,reviews -> list (#429)", reason("gh pr list --json number,reviews") == SafeGhHook::REASON_LIST)
check("before pipe", reason("gh pr view 2 | cat") == SafeGhHook::REASON_VIEW)
check("command substitution", reason("x=$(gh issue view 9)") == SafeGhHook::REASON_VIEW)
# api の path を flag 値と取り違えない
check("api -X GET path 走査", reason("gh api -X GET repos/o/r/issues/1") == SafeGhHook::REASON_API)
# global flag (-R/--repo) が noun の前に来ても見つける (safe-gh 自身が使う形)
check("global -R before noun", reason("gh -R o/r issue view 1") == SafeGhHook::REASON_VIEW)
check("global --repo before noun", reason("gh --repo o/r pr view 2 --comments") == SafeGhHook::REASON_COMMENTS)
# env コマンド前置
check("env command prefix", reason("env GH_PAGER=cat gh issue view 1") == SafeGhHook::REASON_VIEW)
# command 文字列に残る quote 付き --json 値
check("quoted --json body", reason('gh issue view 1 --json "body,comments"') == SafeGhHook::REASON_VIEW)
check("single-quoted --json body", reason("gh issue view 1 --json 'body'") == SafeGhHook::REASON_VIEW)

# ---- untrusted_gh_read_reason: 検出しない (negative) ----
check("issue view --json safe fields", reason("gh pr view 5 --json state,mergeable -q .state").nil?)
check("plain issue list (title のみ)", reason("gh issue list").nil?)
check("api user (untrusted でない)", reason("gh api user").nil?)
# gh api の write (非 GET / field 書き込み) は read でないので steer しない
check("api -X POST write not steered", reason("gh api -X POST repos/o/r/issues/1/comments -f body=hi").nil?)
check("api field-write not steered", reason("gh api repos/o/r/issues/1/comments -f body=hi").nil?)
check("gh repo view は対象外", reason("gh repo view o/r").nil?)
check("gh as argument (echo)", reason("echo gh issue view 1").nil?)
check("non-gh command", reason("git status").nil?)
check("empty", reason("").nil?)

# ---- `\` で継続した複数行の command (#438) ----
# つないだ形で、継続行に折った読み取りを検出する
check("継続行の --json body -> list (#438)", reason("gh issue list \\\n  --json number,body") == SafeGhHook::REASON_LIST)
check("継続行の api comments path -> api (#438)",
      reason("gh api --paginate \\\n  repos/o/r/issues/1/comments") == SafeGhHook::REASON_API)
check("継続行の noun と --comments -> comments (#438)",
      reason("gh -R o/r \\\n  pr view 2 \\\n  --comments") == SafeGhHook::REASON_COMMENTS)
check("CRLF の継続 -> list (#438)", reason("gh issue list \\\r\n  --json body") == SafeGhHook::REASON_LIST)
# 和: 元の形 (改行で割る) で検出していた入力を、つないだ形の判定で取りこぼさない (#437 の review で見つかった形)
check("comment の行末の \\ の次の行の gh (#438)", reason("ls # note \\\ngh issue view 1") == SafeGhHook::REASON_VIEW)
check("制御演算子の後の comment の次の行の gh (#438)",
      reason("ls && # note \\\ngh pr view 2 --comments") == SafeGhHook::REASON_COMMENTS)
check("escape した backslash の次の行の gh (#438)", reason("echo a\\\\\ngh issue view 1") == SafeGhHook::REASON_VIEW)
check("つないだ comment の中の -X POST で消さない (#438)",
      reason("gh api repos/o/r/issues/1 \\\n# -X POST") == SafeGhHook::REASON_API)
check("つないだ comment の中の --json state で消さない (#438)",
      reason("gh pr view 2 \\\n# --json state") == SafeGhHook::REASON_VIEW)
# 1 行目だけで本文を含む view に見える複数行の metadata 読み取りは steer される (docs の honest-label)
check("1 行目が gh pr view N の複数行の metadata 読み取り -> view (#438)",
      reason("gh pr view 2 \\\n  --json state") == SafeGhHook::REASON_VIEW)
# 元の形を先に見るので、元の形で検出していた入力の理由 key は変わらない
check("元の形の理由 key を返す (#438)", reason("gh pr view 2 \\\n  --comments") == SafeGhHook::REASON_VIEW)
# `\` の無い改行はつながない
check("継続でない改行はつながない (#438)", reason("gh issue list\n--json body").nil?)
# review-request の手順の metadata だけの読み取りは 1 行で書き、steer されない
review_cmd = File.read(ARGV[1], encoding: "UTF-8").lines.map(&:chomp).find { |l| l.start_with?('gh pr view "$pr"') }
check("review-request の metadata の読み取りがある (#438)", !review_cmd.nil?)
check("review-request の metadata の読み取りは 1 行 (#438)", review_cmd && !review_cmd.end_with?("\\"))
check("review-request の metadata の読み取りに steer しない (#438)", review_cmd && reason(review_cmd).nil?)

# ---- extract_command: hook payload から command を取り出す ----
def extract(json)
  SafeGhHook.extract_command(json)
end

check("extract Bash command", extract('{"tool_name":"Bash","tool_input":{"command":"gh issue view 1"}}') == "gh issue view 1")
# tool_name 省略でも tool_input.command があれば取り出す (防御的)
check("extract without tool_name", extract('{"tool_input":{"command":"ls"}}') == "ls")
check("non-Bash tool -> nil", extract('{"tool_name":"Read","tool_input":{"command":"x"}}').nil?)
check("missing tool_input -> nil", extract('{"tool_name":"Bash"}').nil?)
check("command not string -> nil", extract('{"tool_name":"Bash","tool_input":{"command":123}}').nil?)
check("non-JSON -> nil", extract("not json").nil?)
check("JSON array -> nil", extract("[1,2,3]").nil?)

# ---- json_flag_value / json_untrusted_fields ----
check("--json space value", SafeGhHook.json_flag_value(%w[--json body,title]) == "body,title")
check("--json= value", SafeGhHook.json_flag_value(["--json=body"]) == "body")
check("no --json -> nil", SafeGhHook.json_flag_value(%w[--state open]).nil?)
check("untrusted field body", SafeGhHook.json_untrusted_fields?("title,body"))
check("untrusted field comments", SafeGhHook.json_untrusted_fields?("comments"))
check("safe fields only", !SafeGhHook.json_untrusted_fields?("state,number,title"))

# ---- main: 出力契約 + 常に exit 0 (fail-open) ----
def run_main(json)
  out = StringIO.new
  code = SafeGhHook.main(json, out: out)
  [code, out.string]
end

code, body = run_main('{"tool_name":"Bash","tool_input":{"command":"gh issue view 1"}}')
check("match -> exit 0", code == 0)
payload = (JSON.parse(body) rescue nil)
hso = payload && payload["hookSpecificOutput"]
check("match -> hookSpecificOutput present", hso.is_a?(Hash))
check("match -> hookEventName PreToolUse", hso && hso["hookEventName"] == "PreToolUse")
check("match -> additionalContext present", hso && hso["additionalContext"].is_a?(String))
# permissionDecision は付けない (許可フローを上書きしない = approve でない)
check("match -> no permissionDecision", hso && !hso.key?("permissionDecision"))
ctx = hso ? hso["additionalContext"].to_s : ""
check("steer mentions personal-safe-gh", ctx.include?("personal-safe-gh"))
# PATH launcher は無いので、名前だけでなく実行可能な配置 path を tool 別に案内する (#190)
check("steer mentions claude deployed path",
      ctx.include?("~/.claude/agent-tools/scripts/personal-safe-gh"))
check("steer mentions codex deployed path",
      ctx.include?("~/.codex/agent-tools/scripts/personal-safe-gh"))
check("steer は steering と明言", ctx.include?("steering"))
# 出力に絶対パス / 攻撃由来文字列を混ぜない
check("steer leaks no absolute path", !ctx.include?("/Users"))

code, body = run_main('{"tool_name":"Bash","tool_input":{"command":"git status"}}')
check("no match -> exit 0", code == 0)
check("no match -> no stdout", body.strip.empty?)

code, body = run_main("not even json")
check("malformed -> exit 0 (fail-open)", code == 0)
check("malformed -> no stdout", body.strip.empty?)

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: safe-gh-hook self-test passed"
