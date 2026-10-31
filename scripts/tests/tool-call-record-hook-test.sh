#!/bin/sh
# personal-tool-call-record-hook.rb の self-test。出力先は AGENT_TOOLS_TOOL_CALL_RECORD_DIR /
# XDG_STATE_HOME / HOME を tmp に向けて隔離し、実 HOME / 実 state には触れない。hook payload は
# stdin JSON fixture。版の取得は tmp の fake `claude` で代替する。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-tool-call-record-hook.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/records" "$tmp/bin"
records="$tmp/records"

# $1=client の目印の代入 (CLAUDECODE=1 / CODEX_THREAD_ID=1 / NONE=)  $2=payload
# 目印は毎回空にしてから $1 で立てる。stdout は呼び出し側が受け、stderr は $tmp/err に残す。
run_hook() {
  printf '%s' "$2" | env CLAUDECODE= CODEX_THREAD_ID= CODEX_SANDBOX= "$1" \
    HOME="$tmp/home" XDG_STATE_HOME= PATH="$tmp/bin:$PATH" \
    AGENT_TOOLS_TOOL_CALL_RECORD_DIR="${RECORD_DIR:-$records}" ruby "$src" 2> "$tmp/err"
}
# 記録 file の n 行目 (0 始まり) の key の値を JSON 表記で出す (key が無ければ __absent__)。
# inspect は Ruby の版で Hash の表記が変わるので使わない。
field() { # $1=file $2=index $3=key
  ruby -rjson -e 'rows = File.readlines(ARGV[0]).map { |l| JSON.parse(l) }
                  row = rows[ARGV[1].to_i]
                  puts(row.key?(ARGV[2]) ? JSON.generate(row[ARGV[2]]) : "__absent__")' "$1" "$2" "$3"
}
lines() { # $1=file
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0
}
claude_log="$records/claude-code.jsonl"

# ---- PreToolUse: 1 行できる・値は入らない ------------------------------------------
canary_cwd="$tmp/CANARY_CWD"
payload=$(printf '{"hook_event_name":"PreToolUse","session_id":"s1","permission_mode":"auto","agent_type":"Explore",
  "tool_name":"mcp__plugin_Notion_notion__notion-update-page","tool_use_id":"tu1",
  "tool_input":{"page_id":"p1","command":"insert_content","content":"CANARY_VALUE_8731"},
  "mcp_server":{"name":"notion","source":"plugin"},"cwd":"%s","transcript_path":"%s/CANARY_TRANSCRIPT.jsonl"}' \
  "$canary_cwd" "$tmp")
out=$(run_hook CLAUDECODE=1 "$payload") || fail "PreToolUse should exit 0"
[ -z "$out" ] || fail "hook must not write to stdout: $out"
[ ! -s "$tmp/err" ] || fail "PreToolUse should be silent on stderr: $(cat "$tmp/err")"
[ "$(lines "$claude_log")" = 1 ] || fail "expected 1 record line"
[ "$(field "$claude_log" 0 event)" = '"PreToolUse"' ] || fail "event"
[ "$(field "$claude_log" 0 client)" = '"claude-code"' ] || fail "client"
[ "$(field "$claude_log" 0 session_id)" = '"s1"' ] || fail "session_id"
[ "$(field "$claude_log" 0 agent_type)" = '"Explore"' ] || fail "agent_type"
[ "$(field "$claude_log" 0 permission_mode)" = '"auto"' ] || fail "permission_mode"
[ "$(field "$claude_log" 0 tool)" = '"mcp__plugin_Notion_notion__notion-update-page"' ] || fail "tool"
[ "$(field "$claude_log" 0 tool_use_id)" = '"tu1"' ] || fail "tool_use_id"
[ "$(field "$claude_log" 0 arg_keys)" = '["command","content","page_id"]' ] || fail "arg_keys sorted"
[ "$(field "$claude_log" 0 op)" = '"append"' ] || fail "notion op append"
[ "$(field "$claude_log" 0 mcp_server)" = '{"name":"notion","source":"plugin"}' ] || fail "mcp_server"
[ "$(field "$claude_log" 0 result)" = '__absent__' ] || fail "Pre has no result"
[ "$(field "$claude_log" 0 cwd)" = '__absent__' ] || fail "cwd must not be recorded"
[ "$(field "$claude_log" 0 transcript_path)" = '__absent__' ] || fail "transcript_path must not be recorded"
grep -q 'CANARY_VALUE_8731' "$claude_log" && fail "argument value leaked into record"
grep -q 'CANARY_CWD' "$claude_log" && fail "cwd leaked into record"
grep -q 'CANARY_TRANSCRIPT' "$claude_log" && fail "transcript_path leaked into record"
grep -qF -- "$tmp" "$claude_log" && fail "absolute path leaked into record"
ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))["ts"] =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/ or exit 1' \
  "$claude_log" || fail "ts should be ISO 8601 with offset"

# ---- PostToolUse / PostToolUseFailure: result の印だけ、本文は書かない ---------------
run_hook CLAUDECODE=1 '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_use_id":"tu2",
  "tool_input":{"command":"CANARY_CMD_1"},"tool_response":{"stdout":"CANARY_STDOUT"},"duration_ms":12}' > /dev/null \
  || fail "PostToolUse should exit 0"
[ "$(field "$claude_log" 1 result)" = '"output"' ] || fail "PostToolUse result"
[ "$(field "$claude_log" 1 duration_ms)" = '12' ] || fail "duration_ms"
[ "$(field "$claude_log" 1 arg_keys)" = '["command"]' ] || fail "Bash arg_keys"
[ "$(field "$claude_log" 1 op)" = '__absent__' ] || fail "op only for notion update-page"
grep -q 'CANARY_CMD_1' "$claude_log" && fail "Bash command leaked"
grep -q 'CANARY_STDOUT' "$claude_log" && fail "tool_response leaked"

run_hook CLAUDECODE=1 '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_use_id":"tu3",
  "tool_input":{"command":"x"},"error":"CANARY_ERROR_BODY","duration_ms":3}' > /dev/null \
  || fail "PostToolUseFailure should exit 0"
[ "$(field "$claude_log" 2 result)" = '"error"' ] || fail "failure result"
grep -q 'CANARY_ERROR_BODY' "$claude_log" && fail "error body leaked"

run_hook CLAUDECODE=1 '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tu4",
  "tool_input":{},"error":"stopped","is_interrupt":true}' > /dev/null || fail "interrupt should exit 0"
[ "$(field "$claude_log" 3 result)" = '"interrupted"' ] || fail "interrupted result"

# ---- PermissionDenied: reason は残すが 200 字で切る --------------------------------
long_reason=$(ruby -e 'print "r" * 300')
run_hook CLAUDECODE=1 "{\"hook_event_name\":\"PermissionDenied\",\"tool_name\":\"Bash\",\"tool_use_id\":\"tu5\",
  \"tool_input\":{\"command\":\"x\"},\"reason\":\"$long_reason\"}" > /dev/null || fail "PermissionDenied should exit 0"
[ "$(field "$claude_log" 4 event)" = '"PermissionDenied"' ] || fail "denied event"
[ "$(field "$claude_log" 4 reason)" = "\"$(ruby -e 'print "r" * 200')\"" ] || fail "reason capped at 200"

# ---- Notion の command の分類 ---------------------------------------------------------
for pair in 'update_content:"edit"' 'replace_content:"replace"' 'something_else:"other"'; do
  command=${pair%%:*}
  expected=${pair#*:}
  run_hook CLAUDECODE=1 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"mcp__plugin_Notion_notion__notion-update-page\",
    \"tool_use_id\":\"tu6\",\"tool_input\":{\"page_id\":\"p\",\"command\":\"$command\"}}" > /dev/null || fail "notion $command"
  last=$(($(lines "$claude_log") - 1))
  [ "$(field "$claude_log" "$last" op)" = "$expected" ] || fail "notion op for $command: $(field "$claude_log" "$last" op)"
  grep -q "something_else" "$claude_log" && fail "unknown command value leaked"
done
run_hook CLAUDECODE=1 '{"hook_event_name":"PreToolUse","tool_name":"mcp__plugin_Notion_notion__notion-update-page",
  "tool_use_id":"tu7","tool_input":{"page_id":"p"}}' > /dev/null || fail "notion without command"
last=$(($(lines "$claude_log") - 1))
[ "$(field "$claude_log" "$last" op)" = '__absent__' ] || fail "no command -> no op"

# ---- 対象外の event・不正な stdin: 無言 no-op / stderr 1 行、file は変わらない ------------
before=$(lines "$claude_log")
out=$(run_hook CLAUDECODE=1 '{"hook_event_name":"Stop","stop_hook_active":false}') || fail "Stop should exit 0"
[ -z "$out" ] && [ ! -s "$tmp/err" ] || fail "unknown event should be silent"
[ "$(lines "$claude_log")" = "$before" ] || fail "unknown event must not record"

out=$(run_hook CLAUDECODE=1 'not json') || fail "non-JSON should exit 0"
[ -z "$out" ] || fail "non-JSON must not write stdout"
[ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ] || fail "non-JSON should leave 1 stderr line: $(cat "$tmp/err")"
out=$(run_hook CLAUDECODE=1 '') || fail "empty stdin should exit 0"
[ -z "$out" ] || fail "empty stdin must not write stdout"
out=$(run_hook CLAUDECODE=1 '["list"]') || fail "non-object JSON should exit 0"
[ "$(lines "$claude_log")" = "$before" ] || fail "invalid stdin must not record"

# ---- 書込先に書けない / 相対 path: exit 0・stdout 無し・stderr 1 行 ----------------------
: > "$tmp/blocker"
out=$(RECORD_DIR="$tmp/blocker/sub" run_hook CLAUDECODE=1 '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"tu8","tool_input":{}}') \
  || fail "unwritable location must not block (exit 0)"
[ -z "$out" ] || fail "unwritable location must not write stdout"
[ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ] || fail "unwritable location should leave 1 stderr line: $(cat "$tmp/err")"
out=$(RECORD_DIR="relative/dir" run_hook CLAUDECODE=1 '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"tu9","tool_input":{}}') \
  || fail "relative dir must exit 0"
[ -z "$out" ] && [ -s "$tmp/err" ] || fail "relative dir should be refused with a stderr line"
[ ! -e "relative/dir" ] || fail "relative dir must not be created"

# ---- client の判定と既定の出力先 -----------------------------------------------------
run_hook CODEX_THREAD_ID=1 '{"hook_event_name":"PreToolUse","tool_name":"shell","tool_use_id":"c1","tool_input":{}}' > /dev/null \
  || fail "codex should exit 0"
[ "$(field "$records/codex.jsonl" 0 client)" = '"codex"' ] || fail "codex client"
run_hook NONE= '{"hook_event_name":"PreToolUse","tool_name":"x","tool_use_id":"u1","tool_input":{}}' > /dev/null \
  || fail "unknown client should exit 0"
[ "$(field "$records/unknown.jsonl" 0 client)" = '"unknown"' ] || fail "unknown client"

printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"x1","tool_input":{}}' \
  | env CLAUDECODE=1 HOME="$tmp/home" XDG_STATE_HOME="$tmp/xdg" AGENT_TOOLS_TOOL_CALL_RECORD_DIR= ruby "$src" 2> "$tmp/err" \
  || fail "XDG default should exit 0"
[ -f "$tmp/xdg/agent-tools/personal-tool-call-record-hook/claude-code.jsonl" ] || fail "XDG_STATE_HOME default path"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"x2","tool_input":{}}' \
  | env CLAUDECODE=1 HOME="$tmp/home" XDG_STATE_HOME= AGENT_TOOLS_TOOL_CALL_RECORD_DIR= ruby "$src" 2> "$tmp/err" \
  || fail "HOME default should exit 0"
[ -f "$tmp/home/.local/state/agent-tools/personal-tool-call-record-hook/claude-code.jsonl" ] || fail "HOME default path"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"x3","tool_input":{}}' \
  | env CLAUDECODE=1 HOME= XDG_STATE_HOME= AGENT_TOOLS_TOOL_CALL_RECORD_DIR= ruby "$src" 2> "$tmp/err" \
  || fail "no HOME should exit 0"
[ -s "$tmp/err" ] || fail "no HOME should leave a stderr line"

# ---- SessionStart: 版は fake claude の stdout から。stderr は捨てる。失敗したら unknown ------
cat > "$tmp/bin/claude" <<'EOF'
#!/bin/sh
echo "warning: CANARY_WARNING_LINE" >&2
echo "9.9.9 (Claude Code)"
EOF
chmod +x "$tmp/bin/claude"
run_hook CLAUDECODE=1 '{"hook_event_name":"SessionStart","session_id":"s2","source":"startup"}' > /dev/null \
  || fail "SessionStart should exit 0"
last=$(($(lines "$claude_log") - 1))
[ "$(field "$claude_log" "$last" version)" = '"9.9.9 (Claude Code)"' ] || fail "version from claude --version stdout"
[ "$(field "$claude_log" "$last" tool)" = '__absent__' ] || fail "SessionStart has no tool"
grep -q 'CANARY_WARNING_LINE' "$claude_log" && fail "claude --version stderr leaked into version"
cat > "$tmp/bin/claude" <<'EOF'
#!/bin/sh
echo "boom" >&2
exit 1
EOF
run_hook CLAUDECODE=1 '{"hook_event_name":"SessionStart","session_id":"s3"}' > /dev/null || fail "failing claude must exit 0"
last=$(($(lines "$claude_log") - 1))
[ "$(field "$claude_log" "$last" version)" = '"unknown"' ] || fail "failing claude -> unknown"
[ ! -s "$tmp/err" ] || fail "version failure should not be reported as an error: $(cat "$tmp/err")"
run_hook NONE= '{"hook_event_name":"SessionStart","session_id":"s4"}' > /dev/null || fail "unknown client SessionStart"
[ "$(field "$records/unknown.jsonl" 1 version)" = '"unknown"' ] || fail "unknown client has no version command"

# ---- 保護範囲 (unit): stdin の読み取りと stderr への診断が失敗しても exit 0 -----------------
# process 境界では ruby が閉じた std fd を /dev/null に開き直すので、IO の失敗は object の差し替えで起こす。
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
require ARGV[0]
require "stringio"
class FailingIO
  def read
    raise IOError, "closed stream"
  end

  def puts(*)
    raise Errno::EBADF, "stderr"
  end
end
err = StringIO.new
check("run returns 0 when stdin read raises", ToolCallRecordHook.run(stdin: FailingIO.new, err: err) == 0)
check("stdin failure is reported in one line", err.string.lines.length == 1)
check("main returns 0 when stderr write raises", ToolCallRecordHook.main("not json", err: FailingIO.new) == 0)
check("run returns 0 when stdin and stderr both fail", ToolCallRecordHook.run(stdin: FailingIO.new, err: FailingIO.new) == 0)
exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: tool-call-record-hook self-test passed"
