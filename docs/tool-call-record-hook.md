# Tool Call Record Hook(tool-call-record-hook)

Claude Code の tool 呼び出しを、後から「いつ・どの client が・どの tool を・どうなったか」の形で
復元できるように、lifecycle hook の入力を event ごとに 1 行の JSON として JSONL に追記する hook body
の契約 (#454)。判断はしない (block も steering もしない)。実体は
`shared/scripts/personal-tool-call-record-hook.rb`、配線は dotfiles 所有
([boundary-with-dotfiles](boundary-with-dotfiles.md))。

## 強度ラベル(偽らない)

- **記録 / fail-open**。guardrail であって境界ではない。
- **主体は client の自己申告まで**。env の目印 (`CLAUDECODE` / `CODEX_THREAD_ID` / `CODEX_SANDBOX`。
  [personal-ai-trailer-gate](git-hook-gates.md) と同じ) で `claude-code` / `codex` / `unknown` を分ける
  だけで、認証された主体には結び付かない。同じ OS user の別 process が目印を真似れば区別できない。
- **hook も JSONL も agent と同じ OS user が書き換えられる**。改竄耐性は無い。
- **exit code は常に 0**。stdin が JSON でない・書込先に書けない・想定外の例外、のどれでも tool call を
  止めない。失敗は stderr に 1 行 (無言で握り潰さない)。
- 登録が済むまで不活性。登録は dotfiles の `settings.json` (下記)。

## 何を記録するか

event ごとに 1 行。無い field は省く (`null` を書かない)。

| field | 取得元 | 備考 |
| --- | --- | --- |
| `ts` | hook が付ける時刻 (ISO 8601、offset つき) | — |
| `event` | `hook_event_name` | `SessionStart` / `PreToolUse` / `PostToolUse` / `PostToolUseFailure` / `PermissionDenied` だけ。他は無言 no-op |
| `client` | env の目印 | `claude-code` / `codex` / `unknown` |
| `session_id` / `agent_type` / `permission_mode` | 入力の同名 field | 文字列のときだけ |
| `version` | `SessionStart` でだけ `claude --version` の先頭行 | 失敗したとき、および `codex` / `unknown` client は `unknown` (Codex の版の取得は登録と一緒に足す。#454 の scope 外)。call の行には付けない (集計で `session_id` 結合) |
| `tool` / `tool_use_id` | `tool_name` / `tool_use_id` | `tool_use_id` で Pre と Post 系を結合する |
| `mcp_server` | `mcp_server.name` / `.source` | MCP tool のときだけ |
| `arg_keys` | `tool_input` の key (sorted) | **値は書かない** |
| `op` | Notion の `update-page` の `command` (固定 enum) を分類 | `append` / `edit` / `replace` / `other`。他の tool には無い |
| `result` | event から | `PostToolUse` → `output`、`PostToolUseFailure` → `error` (`is_interrupt` なら `interrupted`)。「成功」とは書かない |
| `duration_ms` | Post 系の任意 field | 数値のときだけ |
| `reason` | `PermissionDenied` の `reason` | client が作る自由文。**引数の値や path を含みうる** (この hook が書く唯一の自由文)。200 文字で切るのは長さの上限であって匿名化ではない |

**書かないもの**: `tool_input` の値、`tool_response`、error の本文、`cwd`、`transcript_path`、prompt。
self-test は canary 値でこれらが file に出ないことを確かめる。例外は上の `reason` だけで、値を書かない保証は
`reason` には及ばない (受け入れ条件として残すことを選んだ。要らなければ登録側で `PermissionDenied` を
外せば行ごと出なくなる)。

## 出力先

```text
$AGENT_TOOLS_TOOL_CALL_RECORD_DIR/<client>.jsonl                                  (絶対 path。test / OpenCode 用の上書き)
${XDG_STATE_HOME:-~/.local/state}/agent-tools/personal-tool-call-record-hook/<client>.jsonl   (既定)
```

- directory は無ければ作る。作れない・書けないときは stderr 1 行で exit 0。相対 path の上書きは
  cwd 依存になるので受け付けない (stderr 1 行で exit 0)。
- cache ではなく state に置く (記録は消えてよい派生物ではない)。どの repository にも入れない
  (`session_id`・tool 名・引数の key を含む private な runtime state)。保持期間と掃除は利用者の運用。

## 集計側の約束

- **「Pre があって Post が無い」call は拒否ではなく結果不明**。`PermissionDenied` が出るのは auto mode の
  自動拒否だけで、人が dialog で断った場合・`permissions.deny` の一致・別の PreToolUse hook の deny では
  Post 系も `PermissionDenied` も出ない (下記の時点依存)。集計がこれらを「拒否」と書くことはできない。
- hook は event をそのまま 1 行ずつ書く。判断 (許可 / 拒否 / 不明) と結果の列を導くのは集計側で、
  この repo の scope 外 (#454。集計 script は #461)。
- 集計の規則 (2026-10-09 の実測から。#463):
  1. `tool` が `ToolSearch` の行は除外する。deferred な MCP tool では model が先に `ToolSearch` を呼ぶので、
     その Pre / Post 行が call の前に混ざる。
  2. 版は `session_id` で `SessionStart` 行と結合する。無ければ `unknown` (hook が書けなかった session は
     `SessionStart` 行も残らない)。
  3. `result: error` を「未実行」と読まない。MCP tool の `isError: true` も Bash の非 0 終了も同じ `error`
     で、どちらも「実行されて失敗を返した」。`result` だけでは両者を区別できず (tool の種類は `tool` と
     `mcp_server` で分かる)、`isError` の本文や終了 code などの失敗の詳細は記録しない。
  4. 同一 `tool_use_id` の Pre / Post の順序は `ts` ではなく追記順で見る (`ts` は秒精度で、同じ call の
     Pre と Post が同じ `ts` になる)。

## 登録(dotfiles 側)

Claude Code の `settings.json` に、tool 系の 4 event を matcher `*` で、`SessionStart` を 1 本、
いずれも `async: true` で登録する (async の hook は block できないので、記録の失敗や遅延が tool call に
届かない)。概形:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "~/.claude/agent-tools/scripts/personal-tool-call-record-hook", "async": true, "timeout": 10}]}],
    "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.claude/agent-tools/scripts/personal-tool-call-record-hook", "async": true, "timeout": 10}]}],
    "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.claude/agent-tools/scripts/personal-tool-call-record-hook", "async": true, "timeout": 10}]}],
    "PostToolUseFailure": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.claude/agent-tools/scripts/personal-tool-call-record-hook", "async": true, "timeout": 10}]}],
    "PermissionDenied": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.claude/agent-tools/scripts/personal-tool-call-record-hook", "async": true, "timeout": 10}]}]
  }
}
```

Codex への登録 (`~/.codex/hooks.json`、`features.hooks`、hook の trust) と OpenCode plugin からの
呼び出しは #454 の scope 外。

## 時点依存の記述

[tool-compatibility](tool-compatibility.md) の規則に従い、根拠を書き分ける。

- **公式 docs の確認 (2026-10-09、Claude Code 2.1.295)**: event 名と入力 field (`session_id` /
  `hook_event_name` / `tool_name` / `tool_input` / `tool_use_id` / `tool_response` / `duration_ms` /
  `mcp_server` / `agent_type` / `permission_mode` / `error` / `is_interrupt` / `reason`)、`tool_use_id` が
  PreToolUse・PostToolUse・PostToolUseFailure・PermissionDenied に共通で `PermissionRequest` には無いこと、
  `PermissionDenied` が auto mode の自動拒否でだけ発火すること、hook の timeout と exit 2 以外の非 0 が
  call を止めないこと、`async: true` の hook が block できないこと、版を渡す env や field が無いこと。
- **実測 (2026-10-04、Claude Code 2.1.289 / Codex 0.159.x)**: 同型の記録 script が Claude Code と Codex の
  PreToolUse / PostToolUse で無修正で動き、headless で拒否された call は PreToolUse だけが残った
  (当時の版では `PermissionDenied` が発火しなかった)。
- **実測 (2026-10-09、Claude Code 2.1.295、headless `-p`、偽の MCP server、`--settings` で rule を渡した
  11 session。#463)**:
  - `permissions.deny` の pattern (`Bash(echo *)`、dontAsk) に一致した call は PreToolUse だけが出て、
    `PermissionDenied` も Post 系も出ない (集計では `unknown`)。MCP tool を名前で deny すると tool 一覧から
    消えて call 自体が起きず、行は 1 つも残らない。
  - MCP tool が `isError: true` を返すと `PostToolUseFailure` (`result: error`) が出て `PostToolUse` は
    出ない。Bash の非 0 終了も同じ `error`。
  - `PermissionDenied` が出たのは auto mode の classifier の拒否だけ (`reason` は category label のみ)。
    ask rule に一致して headless で自動拒否された call は PreToolUse だけ。
  - `duration_ms` は tool の実行時間だけで、permission 判定の待ち (数秒になることがある) を含まない。
    拒否された call には無い。
  - 書込先に書けないとき call は止まらず (fail-open)、その session の行は `SessionStart` を含めて残らない。
    Claude Code は stderr 付きでも hook を success と扱う。
  - `settings.json` の hooks の変更は、動いている session にも再起動なしで反映された (観測)。
- **未確認 (2026-10-09 時点)**: auto mode で deny rule に一致したとき、人が dialog で断ったとき、
  `is_interrupt` (`interrupted`)、subagent 以外の文脈での `agent_type`、Codex の `SessionStart` の有無。

## Test

`scripts/tests/tool-call-record-hook-test.sh`。出力先・HOME・XDG_STATE_HOME を tmp に向け、版の取得は tmp の
fake `claude` で代替する。1 行できる / 値 (引数・tool_response・error 本文・cwd・transcript_path・絶対 path)
が出ない / Post 系の `result` / `PermissionDenied` の `reason` の上限 / Notion の `command` の分類 /
対象外 event と不正な stdin の no-op / 書込先に書けないときと相対 path の fail-open / client の判定と既定の
出力先 / `SessionStart` の版 (stdout だけ。stderr の警告は捨てる) と失敗時の `unknown` / stdin の読み取りと
stderr への診断が失敗しても exit 0 (unit)、を確かめる。
