#!/bin/sh
# personal-safe-gh-hook.rb の self-test。
# PreToolUse hook の純粋ロジック (command 文字列 -> steer 有無) と出力契約を fixture で検証する。
# 実 hook 配線 (settings.json) は CI 外 (実機検証。docs/runtime-injection-defense.md「検証境界」)。
# network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
src="$repo_root/shared/scripts/personal-safe-gh-hook.rb"

[ -f "$src" ] || { echo "FAIL: missing $src" >&2; exit 1; }

ruby - "$src" <<'RUBY'
require "json"
require "stringio"
require ARGV[0]

@failed = 0
def check(name, cond)
  return if cond

  warn "FAIL: #{name}"
  @failed += 1
end

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
check("before pipe", reason("gh pr view 2 | cat") == SafeGhHook::REASON_VIEW)
check("command substitution", reason("x=$(gh issue view 9)") == SafeGhHook::REASON_VIEW)
# api の path を flag 値と取り違えない
check("api -X GET path 走査", reason("gh api -X GET repos/o/r/issues/1") == SafeGhHook::REASON_API)

# ---- untrusted_gh_read_reason: 検出しない (negative) ----
check("issue view --json safe fields", reason("gh pr view 5 --json state,mergeable -q .state").nil?)
check("plain issue list (title のみ)", reason("gh issue list").nil?)
check("api user (untrusted でない)", reason("gh api user").nil?)
check("gh repo view は対象外", reason("gh repo view o/r").nil?)
check("gh as argument (echo)", reason("echo gh issue view 1").nil?)
check("non-gh command", reason("git status").nil?)
check("empty", reason("").nil?)

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
