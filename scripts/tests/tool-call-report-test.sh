#!/bin/sh
# personal-tool-call-report.rb の self-test (#461)。記録 hook の JSONL と同形の fixture を tmp に作り、process 境界で
# `ruby "$src" ...` を実行して md / json の出力と exit code を確かめる。local の日付の判定は TZ を POSIX 書式
# (UTC0 / EST5) で固定して決定的にする。HOME / XDG_STATE_HOME は tmp に向け、実 HOME / 実 state には触れない。
# network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-tool-call-report.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/records"
records="$tmp/records"
log="$records/claude-code.jsonl"

# report を実行する。TZ は既定 UTC0 (REPORT_TZ で上書き)。stdout は呼び出し側が受け、stderr は $tmp/err に残す。
run_report() {
  env TZ="${REPORT_TZ:-UTC0}" HOME="$tmp/home" XDG_STATE_HOME= ruby "$src" "$@" 2> "$tmp/err"
}
# exit code だけを受ける (set -e の下で非 0 を値にする)。
status_of() {
  if "$@" > "$tmp/out"; then echo 0; else echo $?; fi
}
# file に行がそのまま (丸ごと一致で) あること。
row() { # $1=file $2=line $3=label
  grep -qxF -- "$2" "$1" || fail "$3: missing line '$2' in: $(cat "$1")"
}
no_row() { # $1=file $2=line $3=label
  grep -qxF -- "$2" "$1" && fail "$3: unexpected line '$2'" || :
}
# 見出し $2 から次の見出し $3 までの節の中に行があること (判断と結果のように同じ label の行を持つ表を区別する)。
row_in() { # $1=file $2=節の見出し $3=次の見出し $4=line $5=label
  sed -n "/^$2\$/,/^$3\$/p" "$1" | grep -qxF -- "$4" || fail "$5: missing line '$4' in section '$2' of: $(cat "$1")"
}
# 記録の 1 行を file に足す。
rec() { printf '%s\n' "$2" >> "$1"; }

# ---- fixture: 記録 hook が書く形の行 (期間は 2026-10-05〜09 で見る) ----------------------------------
sa='"client":"claude-code","session_id":"CANARY_SESSION_A"'
# session A: SessionStart あり (版 9.9.9)。10-06 に a1〜a4、10-07 に a5〜a9 と結合不能の行。
rec "$log" "{\"ts\":\"2026-10-06T09:00:00+00:00\",\"event\":\"SessionStart\",$sa,\"version\":\"9.9.9 (Claude Code)\"}"
# a1 / a2: allowed / output (duration 12, 20)
rec "$log" "{\"ts\":\"2026-10-06T09:01:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a1\",\"arg_keys\":[\"command\"]}"
rec "$log" "{\"ts\":\"2026-10-06T09:01:01+00:00\",\"event\":\"PostToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a1\",\"arg_keys\":[\"command\"],\"result\":\"output\",\"duration_ms\":12}"
rec "$log" "{\"ts\":\"2026-10-06T09:02:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a2\"}"
rec "$log" "{\"ts\":\"2026-10-06T09:02:01+00:00\",\"event\":\"PostToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a2\",\"result\":\"output\",\"duration_ms\":20}"
# a3: denied (reason あり。本文に canary と絶対 path)
rec "$log" "{\"ts\":\"2026-10-06T09:03:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a3\"}"
rec "$log" "$(printf '{"ts":"2026-10-06T09:03:01+00:00","event":"PermissionDenied",%s,"tool":"Bash","tool_use_id":"tu_a3","reason":"CANARY_REASON_BODY at %s/CANARY_PATH"}' "$sa" "$tmp")"
# a4: Pre だけ → unknown (拒否と書かない)
rec "$log" "{\"ts\":\"2026-10-06T09:04:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Read\",\"tool_use_id\":\"tu_a4\"}"
# a5: error (duration 3)、a6: interrupted (duration 無し)
rec "$log" "{\"ts\":\"2026-10-07T10:00:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a5\"}"
rec "$log" "{\"ts\":\"2026-10-07T10:00:01+00:00\",\"event\":\"PostToolUseFailure\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a5\",\"result\":\"error\",\"duration_ms\":3}"
rec "$log" "{\"ts\":\"2026-10-07T10:01:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a6\"}"
rec "$log" "{\"ts\":\"2026-10-07T10:01:01+00:00\",\"event\":\"PostToolUseFailure\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a6\",\"result\":\"interrupted\"}"
# a7 / a8: Notion の update-page (op append / edit、mcp_server notion、duration 50 / 7)
notion='"tool":"mcp__plugin_Notion_notion__notion-update-page","mcp_server":{"name":"notion","source":"plugin"}'
rec "$log" "{\"ts\":\"2026-10-07T10:02:00+00:00\",\"event\":\"PreToolUse\",$sa,$notion,\"tool_use_id\":\"tu_a7\",\"op\":\"append\"}"
rec "$log" "{\"ts\":\"2026-10-07T10:02:01+00:00\",\"event\":\"PostToolUse\",$sa,$notion,\"tool_use_id\":\"tu_a7\",\"op\":\"append\",\"result\":\"output\",\"duration_ms\":50}"
rec "$log" "{\"ts\":\"2026-10-07T10:03:00+00:00\",\"event\":\"PreToolUse\",$sa,$notion,\"tool_use_id\":\"tu_a8\",\"op\":\"edit\"}"
rec "$log" "{\"ts\":\"2026-10-07T10:03:01+00:00\",\"event\":\"PostToolUse\",$sa,$notion,\"tool_use_id\":\"tu_a8\",\"op\":\"edit\",\"result\":\"output\",\"duration_ms\":7}"
# tool_use_id の無い tool 行 → 結合不能
rec "$log" "{\"ts\":\"2026-10-07T10:04:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\"}"
# a9: denied (reason なし)
rec "$log" "{\"ts\":\"2026-10-07T10:05:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a9\"}"
rec "$log" "{\"ts\":\"2026-10-07T10:05:01+00:00\",\"event\":\"PermissionDenied\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a9\"}"
# a10: Post だけ (Pre が無い) → tool は Post の行から取り、allowed / output (duration 8)
rec "$log" "{\"ts\":\"2026-10-07T10:06:00+00:00\",\"event\":\"PostToolUse\",$sa,\"tool\":\"Grep\",\"tool_use_id\":\"tu_a10\",\"result\":\"output\",\"duration_ms\":8}"
# a11: denied (reason が空白だけ → 「なし」)
rec "$log" "{\"ts\":\"2026-10-07T10:07:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a11\"}"
rec "$log" "{\"ts\":\"2026-10-07T10:07:01+00:00\",\"event\":\"PermissionDenied\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a11\",\"reason\":\"   \"}"
# 知らない event (ts あり) → 結合不能
rec "$log" "{\"ts\":\"2026-10-07T10:08:00+00:00\",\"event\":\"Stop\",$sa}"
# session_id の無い tool 行 (tool_use_id は session A の tu_a1 と同じ) → 結合不能 (別 session の call と混ぜない)
rec "$log" "{\"ts\":\"2026-10-07T10:08:30+00:00\",\"event\":\"PostToolUse\",\"client\":\"claude-code\",\"tool\":\"Bash\",\"tool_use_id\":\"tu_a1\",\"result\":\"output\",\"duration_ms\":999}"
# a12: ToolSearch (deferred な tool の探索) → 集計から除外し件数だけ出す (duration 2 は 6 節に入らない)
rec "$log" "{\"ts\":\"2026-10-07T10:09:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"ToolSearch\",\"tool_use_id\":\"tu_a12\",\"arg_keys\":[\"max_results\",\"query\"]}"
rec "$log" "{\"ts\":\"2026-10-07T10:09:01+00:00\",\"event\":\"PostToolUse\",$sa,\"tool\":\"ToolSearch\",\"tool_use_id\":\"tu_a12\",\"arg_keys\":[\"max_results\",\"query\"],\"result\":\"output\",\"duration_ms\":2}"
# session B: SessionStart なし → 版 unknown。b1: allowed / output (duration 100)
sb='"client":"claude-code","session_id":"CANARY_SESSION_B"'
rec "$log" "{\"ts\":\"2026-10-08T11:00:00+00:00\",\"event\":\"PreToolUse\",$sb,\"tool\":\"Edit\",\"tool_use_id\":\"tu_b1\"}"
rec "$log" "{\"ts\":\"2026-10-08T11:00:01+00:00\",\"event\":\"PostToolUse\",$sb,\"tool\":\"Edit\",\"tool_use_id\":\"tu_b1\",\"result\":\"output\",\"duration_ms\":100}"
# session E: session A と同じ tool_use_id (tu_a1) を使う → 別の call (session_id + tool_use_id で結合)。duration 30
se='"client":"claude-code","session_id":"CANARY_SESSION_E"'
rec "$log" "{\"ts\":\"2026-10-08T13:00:00+00:00\",\"event\":\"PreToolUse\",$se,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a1\"}"
rec "$log" "{\"ts\":\"2026-10-08T13:00:01+00:00\",\"event\":\"PostToolUse\",$se,\"tool\":\"Bash\",\"tool_use_id\":\"tu_a1\",\"result\":\"output\",\"duration_ms\":30}"
# session C (codex): SessionStart は期間外 (09-30) だが版の結合には使う。c1: allowed / output (duration 40)
sc='"client":"codex","session_id":"CANARY_SESSION_C"'
rec "$log" "{\"ts\":\"2026-09-30T08:00:00+00:00\",\"event\":\"SessionStart\",$sc,\"version\":\"0.1.0\"}"
rec "$log" "{\"ts\":\"2026-10-07T12:00:00+00:00\",\"event\":\"PreToolUse\",$sc,\"tool\":\"shell\",\"tool_use_id\":\"tu_c1\"}"
rec "$log" "{\"ts\":\"2026-10-07T12:00:01+00:00\",\"event\":\"PostToolUse\",$sc,\"tool\":\"shell\",\"tool_use_id\":\"tu_c1\",\"result\":\"output\",\"duration_ms\":40}"
# 壊れた行 6 つ: JSON でない / object でない / ts が無い / 空行 / ts が ISO 8601 でない / ts が文字列でない
rec "$log" 'not json'
rec "$log" '["list"]'
rec "$log" '{"event":"PreToolUse","tool":"Bash","tool_use_id":"tu_broken"}'
rec "$log" ''
rec "$log" "{\"ts\":\"garbage\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_broken2\"}"
rec "$log" "{\"ts\":123,\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_broken3\"}"
# 期間外の call (09-01): 2 行
rec "$log" "{\"ts\":\"2026-09-01T09:00:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_old\"}"
rec "$log" "{\"ts\":\"2026-09-01T09:00:01+00:00\",\"event\":\"PostToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_old\",\"result\":\"output\",\"duration_ms\":1}"
[ "$(wc -l < "$log" | tr -d ' ')" = 41 ] || fail "fixture should have 41 lines"

# ---- md: 1〜7 が期待値どおり ------------------------------------------------------------------------
md="$tmp/report.md"
run_report --file "$log" --since 2026-10-05 --until 2026-10-09 > "$md" || fail "md report should exit 0: $(cat "$tmp/err")"
[ ! -s "$tmp/err" ] || fail "clean run should be silent on stderr: $(cat "$tmp/err")"
row "$md" "| 期間 | 2026-10-05 〜 2026-10-09 (local の日付) |" "1 期間"
row "$md" "| 読んだ file | claude-code.jsonl |" "1 読んだ file"
row "$md" "| 読めなかった file | 0 |" "1 読めなかった file"
row "$md" "| 行数 | 41 |" "1 行数"
row "$md" "| 壊れた行 | 6 |" "1 壊れた行"
row "$md" "| 期間外の行 | 3 |" "1 期間外の行"
row "$md" "| 結合不能の行 (session_id / tool_use_id 無し / 知らない event) | 3 |" "1 結合不能 (tool_use_id 無し / 知らない event / session_id 無し)"
row "$md" "| call 数 | 14 |" "1 call 数 (同じ tool_use_id でも session が違えば別の call。ToolSearch は数えない)"
row "$md" "| 除外した call (ToolSearch) | 1 |" "1 除外した call"
grep -q "| ToolSearch | " "$md" && fail "ToolSearch must not appear as a tool row (excluded)"
row "$md" "| session 数 | 4 |" "1 session 数"
row "$md" "| 作業日数 | 3 |" "1 作業日数"
row "$md" "| claude-code | 9.9.9 (Claude Code) | 11 |" "2 client × 版"
row "$md" "| claude-code | unknown | 2 |" "2 SessionStart の無い session は unknown"
row "$md" "| codex | 0.1.0 | 1 |" "2 期間外の SessionStart でも版は結合する"
row "$md" "## 3. tool (上位 20 / 6 種類)" "3 見出し"
row "$md" "| Bash | 8 |" "3 Bash"
row "$md" "| mcp__plugin_Notion_notion__notion-update-page | 2 |" "3 notion"
row "$md" "| Edit | 1 |" "3 Edit"
row "$md" "| Grep | 1 |" "3 Grep (Post だけの call の tool は Post の行から)"
row "$md" "| Read | 1 |" "3 Read"
row "$md" "| shell | 1 |" "3 shell"
row "$md" "| notion | 2 |" "3 MCP server"
row_in "$md" "### 判断" "### 結果" "| allowed | 10 |" "4 allowed (Post だけの call も allowed)"
row_in "$md" "### 判断" "### 結果" "| denied | 3 |" "4 denied"
row_in "$md" "### 判断" "### 結果" "| unknown | 1 |" "4 unknown (Pre だけ)"
row_in "$md" "### 判断" "### 結果" "| unknown の比率 | 7.1% |" "4 判断の unknown の比率"
row_in "$md" "### 結果" "## 5. Notion update-page の op" "| output | 8 |" "4 output"
row_in "$md" "### 結果" "## 5. Notion update-page の op" "| error | 1 |" "4 error"
row_in "$md" "### 結果" "## 5. Notion update-page の op" "| interrupted | 1 |" "4 interrupted"
row_in "$md" "### 結果" "## 5. Notion update-page の op" "| unknown | 4 |" "4 結果 unknown"
row_in "$md" "### 結果" "## 5. Notion update-page の op" "| unknown の比率 | 28.6% |" "4 結果の unknown の比率"
row "$md" "| append | 1 |" "5 append"
row "$md" "| edit | 1 |" "5 edit"
row "$md" "| replace | 0 |" "5 replace"
row "$md" "| other | 0 |" "5 other"
row "$md" "| あり (call 数) | 9 |" "6 duration あり"
row "$md" "| 中央値 | 20 |" "6 中央値"
row "$md" "| p95 | 100 |" "6 p95"
row "$md" "| reason あり | 1 |" "7 reason あり"
row "$md" "| reason なし | 2 |" "7 reason なし (無い 1 + 空白だけ 1。あり + なし = denied の call 数)"
# tool の順は件数の多い順、同数なら名前順
[ "$(grep -E '^\| (Bash|mcp__plugin_Notion_notion__notion-update-page|Edit|Grep|Read|shell) \|' "$md" | tr '\n' ' ')" = \
  "| Bash | 8 | | mcp__plugin_Notion_notion__notion-update-page | 2 | | Edit | 1 | | Grep | 1 | | Read | 1 | | shell | 1 | " ] \
  || fail "3 tools should be ranked by calls desc then name: $(cat "$md")"

# ---- canary: session_id / reason の本文 / 絶対 path / tool_use_id が出ない ----------------------------
for needle in CANARY_SESSION CANARY_REASON CANARY_PATH tu_a tu_b tu_c; do
  grep -qF -- "$needle" "$md" && fail "md leaked $needle" || :
done
grep -qF -- "$tmp" "$md" && fail "md leaked an absolute path" || :

# ---- json: valid で md と同じ数字 -----------------------------------------------------------------
json="$tmp/report.json"
run_report --file "$log" --since 2026-10-05 --until 2026-10-09 --format json > "$json" || fail "json report should exit 0"
ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$json" || fail "json output should be valid JSON"
for needle in CANARY_SESSION CANARY_REASON CANARY_PATH tu_a tu_b tu_c; do
  grep -qF -- "$needle" "$json" && fail "json leaked $needle" || :
done
grep -qF -- "$tmp" "$json" && fail "json leaked an absolute path" || :
jv() { # $1=expected (inspect 表記) $2=label $3...=dig の key
  jv_expected=$1
  jv_label=$2
  shift 2
  jv_actual=$(jget "$json" "$@")
  [ "$jv_actual" = "$jv_expected" ] || fail "json $jv_label: expected $jv_expected, got $jv_actual"
}
jv '1' schema_version schema_version
jv '"2026-10-05"' period.since period since
jv '"2026-10-09"' period.until period until
jv 'nil' period.days period days
jv '["claude-code.jsonl"]' files.read files read
jv '0' files.unreadable files unreadable
jv '41' lines.total lines total
jv '6' lines.broken lines broken
jv '3' lines.out_of_period lines out_of_period
jv '3' lines.unjoinable lines unjoinable
jv '14' calls calls
jv '["ToolSearch"]' excluded_calls.tools excluded_calls tools
jv '1' excluded_calls.count excluded_calls count
jv '4' sessions sessions
jv '3' active_days active_days
jv '"claude-code"' by_client_version.0.client by_client_version 0 client
jv '"9.9.9 (Claude Code)"' by_client_version.0.version by_client_version 0 version
jv '11' by_client_version.0.calls by_client_version 0 calls
jv '"unknown"' by_client_version.1.version by_client_version 1 version
jv '2' by_client_version.1.calls by_client_version 1 calls
jv '"codex"' by_client_version.2.client by_client_version 2 client
jv '"0.1.0"' by_client_version.2.version by_client_version 2 version
jv '20' tools.top tools top
jv '6' tools.distinct tools distinct
jv '"Bash"' tools.rows.0.tool tools rows 0 tool
jv '8' tools.rows.0.calls tools rows 0 calls
jv '"mcp__plugin_Notion_notion__notion-update-page"' tools.rows.1.tool tools rows 1 tool
jv '"Edit"' tools.rows.2.tool tools rows 2 tool
jv '"Grep"' tools.rows.3.tool tools rows 3 tool
jv '"Read"' tools.rows.4.tool tools rows 4 tool
jv '"shell"' tools.rows.5.tool tools rows 5 tool
jv '"notion"' mcp_servers.0.name mcp_servers 0 name
jv '2' mcp_servers.0.calls mcp_servers 0 calls
jv '10' decisions.allowed decisions allowed
jv '3' decisions.denied decisions denied
jv '1' decisions.unknown decisions unknown
jv '7.1' decisions.unknown_percent decisions unknown_percent
jv '8' results.output results output
jv '1' results.error results error
jv '1' results.interrupted results interrupted
jv '4' results.unknown results unknown
jv '28.6' results.unknown_percent results unknown_percent
jv '1' ops.append ops append
jv '1' ops.edit ops edit
jv '0' ops.replace ops replace
jv '0' ops.other ops other
jv '9' duration_ms.count duration_ms count
jv '20' duration_ms.median duration_ms median
jv '100' duration_ms.p95 duration_ms p95
jv '1' denied_reasons.with_reason denied_reasons with_reason
jv '2' denied_reasons.without_reason denied_reasons without_reason

# ---- --top / --since だけ / --until だけ / 複数 file -------------------------------------------------
run_report --file "$log" --since 2026-10-05 --until 2026-10-09 --top 2 > "$md" || fail "--top 2 should exit 0"
row "$md" "## 3. tool (上位 2 / 6 種類)" "--top 2 見出し"
row "$md" "| Bash | 8 |" "--top 2 keeps Bash"
no_row "$md" "| Edit | 1 |" "--top 2 drops Edit"
run_report --file "$log" --since 2026-10-08 > "$md" || fail "--since only should exit 0"
row "$md" "| 期間 | 2026-10-08 〜 (上限なし) (local の日付) |" "--since only 期間"
row "$md" "| call 数 | 2 |" "--since only call 数 (b1 と session E)"
run_report --file "$log" --until 2026-10-06 > "$md" || fail "--until only should exit 0"
row "$md" "| 期間 | (下限なし) 〜 2026-10-06 (local の日付) |" "--until only 期間"
row "$md" "| call 数 | 5 |" "--until only call 数 (a1〜a4 と、下限が無いので 09-01 の call)"
sd='"client":"codex","session_id":"CANARY_SESSION_D"'
rec "$records/codex.jsonl" "{\"ts\":\"2026-10-08T12:00:00+00:00\",\"event\":\"PreToolUse\",$sd,\"tool\":\"shell\",\"tool_use_id\":\"tu_d1\"}"
rec "$records/codex.jsonl" "{\"ts\":\"2026-10-08T12:00:01+00:00\",\"event\":\"PostToolUse\",$sd,\"tool\":\"shell\",\"tool_use_id\":\"tu_d1\",\"result\":\"output\",\"duration_ms\":60}"
run_report --file "$log" --file "$records/codex.jsonl" --since 2026-10-05 --until 2026-10-09 > "$md" || fail "two files should exit 0"
row "$md" "| 読んだ file | claude-code.jsonl, codex.jsonl |" "複数 file 読んだ file"
row "$md" "| 行数 | 43 |" "複数 file 行数"
row "$md" "| call 数 | 15 |" "複数 file call 数"
row "$md" "| session 数 | 5 |" "複数 file session 数"
row "$md" "| codex | unknown | 1 |" "複数 file codex の版"

# ---- 期間は ts の offset を尊重した local の日付 (20:00-05:00 は UTC では翌日、EST5 では当日) ------------
tz="$records/tz.jsonl"
st='"client":"claude-code","session_id":"CANARY_SESSION_T"'
rec "$tz" "{\"ts\":\"2026-10-05T20:00:00-05:00\",\"event\":\"PreToolUse\",$st,\"tool\":\"Bash\",\"tool_use_id\":\"tu_t1\"}"
rec "$tz" "{\"ts\":\"2026-10-05T20:00:30-05:00\",\"event\":\"PostToolUse\",$st,\"tool\":\"Bash\",\"tool_use_id\":\"tu_t1\",\"result\":\"output\"}"
run_report --file "$tz" --since 2026-10-06 --until 2026-10-06 > "$md" || fail "tz UTC0 should exit 0"
row "$md" "| call 数 | 1 |" "UTC0 では 10-06"
# REPORT_TZ は subshell の中だけで立てる。/bin/sh (macOS の bash 3.2) では、関数の呼び出しの前に置いた代入が
# 呼び出しの後も残り、後続の run_report がすべて EST5 で走る (UTC 0〜5 時に既定の 7 日の case が落ちた。#473)。
(REPORT_TZ=EST5 run_report --file "$tz" --since 2026-10-06 --until 2026-10-06 > "$md") || fail "tz EST5 should exit 0"
row "$md" "| call 数 | 0 |" "EST5 では 10-05 (期間外)"
row "$md" "| 期間外の行 | 2 |" "EST5 期間外の行"
(REPORT_TZ=EST5 run_report --file "$tz" --since 2026-10-05 --until 2026-10-05 > "$md") || fail "tz EST5 10-05 should exit 0"
row "$md" "| call 数 | 1 |" "EST5 では 10-05 に入る"
# 後続の case が既定の UTC0 で走ることを、時刻によらず確かめる (残ると UTC 0〜5 時にだけ落ちる)。
[ -z "${REPORT_TZ-}" ] || fail "REPORT_TZ must not leak past the EST5 cases (#473): $REPORT_TZ"

# ---- --days: 既定は今日を含む直近 7 日 (境界の日は使わず、日付が変わっても結果が同じ行だけ置く) -----------
days="$records/days.jsonl"
d0=$(TZ=UTC0 ruby -rdate -e 'puts Date.today.to_s')
d3=$(TZ=UTC0 ruby -rdate -e 'puts (Date.today - 3).to_s')
d10=$(TZ=UTC0 ruby -rdate -e 'puts (Date.today - 10).to_s')
d20=$(TZ=UTC0 ruby -rdate -e 'puts (Date.today - 20).to_s')
i=0
for day in "$d0" "$d3" "$d10" "$d20"; do
  i=$((i + 1))
  rec "$days" "{\"ts\":\"${day}T12:00:00+00:00\",\"event\":\"PreToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_day$i\"}"
  rec "$days" "{\"ts\":\"${day}T12:00:01+00:00\",\"event\":\"PostToolUse\",$sa,\"tool\":\"Bash\",\"tool_use_id\":\"tu_day$i\",\"result\":\"output\"}"
done
run_report --file "$days" > "$md" || fail "default --days should exit 0"
row "$md" "| call 数 | 2 |" "既定の 7 日: 今日と 3 日前"
row "$md" "| 期間外の行 | 4 |" "既定の 7 日: 10 日前と 20 日前は期間外"
grep -qE '^\| 期間 \| [0-9]{4}-[0-9]{2}-[0-9]{2} 〜 [0-9]{4}-[0-9]{2}-[0-9]{2} \(local の日付、今日を含む直近 7 日\) \|$' "$md" \
  || fail "既定の期間の行: $(cat "$md")"
run_report --file "$days" --format json > "$json" || fail "default --days json should exit 0"
ruby -rjson -rdate -e 'p = JSON.parse(File.read(ARGV[0]))["period"]
  exit 1 unless p["days"] == 7 && Date.parse(p["until"]) - Date.parse(p["since"]) == 6' "$json" \
  || fail "json period should span 7 days ending today"
run_report --file "$days" --days 15 > "$md" || fail "--days 15 should exit 0"
row "$md" "| call 数 | 3 |" "--days 15: 10 日前も入る"
grep -qE '^\| 期間 \| [0-9]{4}-[0-9]{2}-[0-9]{2} 〜 [0-9]{4}-[0-9]{2}-[0-9]{2} \(local の日付、今日を含む直近 15 日\) \|$' "$md" \
  || fail "--days 15 の期間の行: $(cat "$md")"
run_report --file "$days" --days 15 --format json > "$json" || fail "--days 15 json should exit 0"
ruby -rjson -rdate -e 'p = JSON.parse(File.read(ARGV[0]))["period"]
  exit 1 unless p["days"] == 15 && Date.parse(p["until"]) - Date.parse(p["since"]) == 14' "$json" \
  || fail "json period should span 15 days ending today"

# ---- 空の file: exit 0、比率は n/a / null --------------------------------------------------------------
: > "$records/empty.jsonl"
run_report --file "$records/empty.jsonl" > "$md" || fail "empty file should exit 0"
row "$md" "| 行数 | 0 |" "空 file 行数"
row "$md" "| call 数 | 0 |" "空 file call 数"
row "$md" "| unknown の比率 | n/a |" "空 file 比率"
row "$md" "| 中央値 | n/a |" "空 file 中央値"
run_report --file "$records/empty.jsonl" --format json > "$json" || fail "empty json should exit 0"
[ "$(jget "$json" decisions unknown_percent)" = nil ] || fail "empty json unknown_percent should be null"
[ "$(jget "$json" duration_ms median)" = nil ] || fail "empty json median should be null"

# ---- 既定の入力先 (HOME / XDG_STATE_HOME)。決められなければ exit 1 ------------------------------------
mkdir -p "$tmp/home/.local/state/agent-tools/personal-tool-call-record-hook" "$tmp/xdg/agent-tools/personal-tool-call-record-hook"
cp "$log" "$tmp/home/.local/state/agent-tools/personal-tool-call-record-hook/claude-code.jsonl"
run_report --since 2026-10-05 --until 2026-10-09 > "$md" || fail "HOME default should exit 0: $(cat "$tmp/err")"
row "$md" "| call 数 | 14 |" "HOME 既定の入力先"
cp "$records/codex.jsonl" "$tmp/xdg/agent-tools/personal-tool-call-record-hook/claude-code.jsonl"
env TZ=UTC0 HOME="$tmp/home" XDG_STATE_HOME="$tmp/xdg" ruby "$src" --since 2026-10-05 --until 2026-10-09 > "$md" 2> "$tmp/err" \
  || fail "XDG default should exit 0: $(cat "$tmp/err")"
row "$md" "| call 数 | 1 |" "XDG_STATE_HOME 既定の入力先"
status=$(status_of env TZ=UTC0 HOME= XDG_STATE_HOME= ruby "$src" 2> "$tmp/err")
[ "$status" = 1 ] || fail "no HOME / XDG should exit 1, got $status"
[ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ] || fail "no HOME should leave 1 stderr line: $(cat "$tmp/err")"
status=$(status_of env TZ=UTC0 HOME= XDG_STATE_HOME=relative/state ruby "$src" 2> "$tmp/err")
[ "$status" = 1 ] || fail "relative XDG_STATE_HOME should exit 1, got $status"
# 記録 hook と同じく AGENT_TOOLS_TOOL_CALL_RECORD_DIR が最優先 (HOME / XDG より先)。相対 path は exit 1
mkdir -p "$tmp/override"
cp "$records/codex.jsonl" "$tmp/override/claude-code.jsonl"
env TZ=UTC0 HOME="$tmp/home" XDG_STATE_HOME="$tmp/xdg" AGENT_TOOLS_TOOL_CALL_RECORD_DIR="$tmp/override" \
  ruby "$src" --since 2026-10-05 --until 2026-10-09 > "$md" 2> "$tmp/err" || fail "record dir override should exit 0: $(cat "$tmp/err")"
row "$md" "| call 数 | 1 |" "AGENT_TOOLS_TOOL_CALL_RECORD_DIR 既定の入力先 (HOME / XDG より優先)"
status=$(status_of env TZ=UTC0 HOME="$tmp/home" AGENT_TOOLS_TOOL_CALL_RECORD_DIR=relative/dir ruby "$src" 2> "$tmp/err")
[ "$status" = 1 ] || fail "relative AGENT_TOOLS_TOOL_CALL_RECORD_DIR should exit 1, got $status"

# ---- 読めない file: warn して続け、1 つも読めなければ exit 1 ------------------------------------------
status=$(status_of run_report --file "$tmp/none.jsonl")
[ "$status" = 1 ] || fail "missing file should exit 1, got $status"
[ ! -s "$tmp/out" ] || fail "exit 1 should leave stdout empty"
grep -q "cannot read" "$tmp/err" || fail "missing file should be reported on stderr: $(cat "$tmp/err")"
status=$(status_of run_report --file "$records")
[ "$status" = 1 ] || fail "directory should exit 1, got $status"
run_report --file "$tmp/none.jsonl" --file "$log" --since 2026-10-05 --until 2026-10-09 > "$md" || fail "one readable file should exit 0"
[ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ] || fail "unreadable file should leave 1 stderr line: $(cat "$tmp/err")"
grep -qF -- "$tmp" "$tmp/err" && fail "stderr must not carry the absolute path of the unreadable file: $(cat "$tmp/err")" || :
grep -q "none.jsonl" "$tmp/err" || fail "stderr should name the unreadable file by basename: $(cat "$tmp/err")"
row "$md" "| 読んだ file | claude-code.jsonl |" "読めない file は読んだ file に入らない"
row "$md" "| 読めなかった file | 1 |" "読めなかった file の数"
row "$md" "| call 数 | 14 |" "読める file だけで集計"
# 読めない file の警告 (stderr) は path の制御文字 (端末の escape) を空白にして出す
esc=$(printf '\033')
status=$(status_of run_report --file "$tmp/no${esc}[31mne.jsonl")
[ "$status" = 1 ] || fail "missing file with a control character should exit 1, got $status"
grep -q "cannot read" "$tmp/err" || fail "control-character path should still be reported: $(cat "$tmp/err")"
grep -qF -- "$esc" "$tmp/err" && fail "stderr should not carry control characters from the path" || :

# ---- 引数の誤り: usage を stderr に出して exit 2。--help は stdout に出して exit 0 -------------------------
for bad in "--bogus" "--days 0" "--days x" "--days -1" "--top 0" "--format xml" "--since 2026-13-01" "--since 2026-02-30" \
  "--since 20261001" "--since" "--file" "--since 2026-10-09 --until 2026-10-01" "--days 3 --since 2026-10-01" \
  "--days 3 --until 2026-10-01" "extra"; do
  # shellcheck disable=SC2086
  status=$(status_of run_report --file "$log" $bad)
  [ "$status" = 2 ] || fail "'$bad' should exit 2, got $status"
  [ ! -s "$tmp/out" ] || fail "'$bad' should leave stdout empty"
  grep -q "^usage: personal-tool-call-report" "$tmp/err" || fail "'$bad' should print usage on stderr: $(cat "$tmp/err")"
  [ "$(wc -l < "$tmp/err" | tr -d ' ')" = 2 ] || fail "'$bad' should leave a reason and the usage: $(cat "$tmp/err")"
done
run_report --help > "$tmp/out" || fail "--help should exit 0"
grep -q "^usage: personal-tool-call-report" "$tmp/out" || fail "--help should print usage on stdout"
grep -q -- "--help|-h" "$tmp/out" || fail "usage should name -h as well as --help"
[ ! -s "$tmp/err" ] || fail "--help should be silent on stderr"
run_report -h > "$tmp/out" || fail "-h should exit 0"
grep -q "^usage: personal-tool-call-report" "$tmp/out" || fail "-h should print usage on stdout"
# 不正な option は入力を読む前に止まる (file が無くても exit 2)
status=$(status_of run_report --file "$tmp/none.jsonl" --days x)
[ "$status" = 2 ] || fail "option errors win over missing files, got $status"
# 余分な位置引数は値 (path かもしれない) を stderr に出さない。未知の option は名前だけ出す
status=$(status_of run_report --file "$log" "$tmp/CANARY_POSITIONAL")
[ "$status" = 2 ] || fail "positional argument should exit 2, got $status"
grep -qF -- "$tmp" "$tmp/err" && fail "stderr must not echo a positional value: $(cat "$tmp/err")" || :
grep -q "CANARY_POSITIONAL" "$tmp/err" && fail "stderr must not echo a positional value (canary): $(cat "$tmp/err")" || :
status=$(status_of run_report --file "$log" --bogus-option)
[ "$status" = 2 ] || fail "unknown option should exit 2, got $status"
grep -q "unknown option: --bogus-option" "$tmp/err" || fail "unknown option should be named: $(cat "$tmp/err")"

# ---- unit: 中央値と p95 (nearest-rank)、call の結合の規則 --------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
require ARGV[0]
R = ToolCallReport
# Post 系が勝つ call (記録 hook の今の意味では起きない形) の PermissionDenied 行は denied にも reason にも数えない
pre = { "event" => "PreToolUse", "client" => "claude-code", "tool" => "Bash" }
denied = { "event" => "PermissionDenied", "tool" => "Bash", "reason" => "x" }
post = { "event" => "PostToolUse", "tool" => "Bash", "result" => "output" }
c = R.build_call("s", [pre, denied, post], {})
check("Post wins over PermissionDenied", c[:decision] == "allowed" && c[:result] == "output" && c[:reason] == false)
c = R.build_call("s", [pre, denied], {})
check("PermissionDenied with a reason", c[:decision] == "denied" && c[:result] == "unknown" && c[:reason] == true)
c = R.build_call("s", [pre, denied.merge("reason" => " \t ")], {})
check("whitespace-only reason counts as no reason", c[:decision] == "denied" && c[:reason] == false)
c = R.build_call("s", [pre, denied.merge("reason" => 7)], {})
check("non-string reason counts as no reason", c[:decision] == "denied" && c[:reason] == false)
c = R.build_call("s", [post.merge("client" => "codex")], {})
check("Post-only call takes its columns from the Post row", c[:client] == "codex" && c[:tool] == "Bash" && c[:decision] == "allowed")
check("blank? accepts nil / empty / whitespace / non-string", R.blank?(nil) && R.blank?("") && R.blank?("  ") && R.blank?(1) && !R.blank?("a"))
check("plain scrubs control characters", R.plain("a\e[31mb\tc") == "a [31mb c")
check("median of odd count", R.median([3, 1, 2].sort) == 2)
check("median of even count averages the middle two", R.median([1, 2, 3, 4]) == 2.5)
check("median of whole average is an integer", R.median([2, 4]) == 3 && R.median([2, 4]).is_a?(Integer))
check("median of empty is nil", R.median([]).nil?)
check("median keeps a fractional value (no rounding)", R.median([1.25]) == 1.25 && R.median([1.2, 1.3]) == 1.25)
check("p95 keeps a fractional value (no rounding)", R.p95([0.75]) == 0.75)
check("p95 of 1..100 is 95 (nearest-rank)", R.p95((1..100).to_a) == 95)
check("p95 of 1..20 is 19", R.p95((1..20).to_a) == 19)
check("p95 of 1..21 is 20", R.p95((1..21).to_a) == 20)
check("p95 of a single value is that value", R.p95([5]) == 5)
check("p95 of empty is nil", R.p95([]).nil?)
check("default days is 7 and top is 20", R::DEFAULT_DAYS == 7 && R::DEFAULT_TOP == 20)
exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: tool-call-report self-test passed"
