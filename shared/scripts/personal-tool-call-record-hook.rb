#!/usr/bin/env ruby
# frozen_string_literal: true

# tool-call-record-hook: Claude Code の lifecycle hook (SessionStart / PreToolUse / PostToolUse /
# PostToolUseFailure / PermissionDenied) の入力を、event ごとに 1 行の JSON として JSONL に追記する
# 記録 hook body (#454)。判断はしない (stdout に何も出さない。permissionDecision も
# additionalContext も返さない)。
#
# 正本: docs/tool-call-record-hook.md。
#
# 強度ラベル (偽らない): 記録 / fail-open。guardrail であって境界ではない。
# - 主体は client の自己申告 (env の目印で claude-code / codex を分ける) まで。認証された主体には
#   結び付かない。
# - hook も JSONL も agent と同じ OS user が書き換えられる。
# - exit code は常に 0。stdin が JSON でない・書込先に書けない・想定外の例外、のどれでも tool call を
#   止めない。失敗は stderr に 1 行 (無言で握り潰さない)。
#
# 記録するもの: 時刻、event、client、session_id、agent_type、permission_mode、tool 名、tool_use_id、
# mcp_server (name / source)、tool_input の key (sorted)、result (output / error / interrupted)、
# duration_ms、PermissionDenied の reason (REASON_CAP 文字まで)、SessionStart の版。
# 記録しないもの: tool_input の値、tool_response、error の本文、cwd、transcript_path、prompt。
# 例外が 2 つ: Notion の update-page の command (固定の enum) は append / edit / replace / other に
# 分類した結果だけを書く (値そのものは書かない)。PermissionDenied の reason は client が作る自由文で、
# 引数の値や path を含みうる (この hook が書く唯一の自由文。REASON_CAP は長さの上限であって匿名化ではない)。
#
# 出力先: $AGENT_TOOLS_TOOL_CALL_RECORD_DIR (絶対 path)。無ければ
# ${XDG_STATE_HOME:-~/.local/state}/agent-tools/personal-tool-call-record-hook/<client>.jsonl。
# どの repository にも入れない。外部 command は SessionStart の版の取得 (claude --version) だけで、
# tool call の行では subprocess を起こさない。
#
# payload 互換: field 名は Claude Code 2.1.295 の hooks docs (2026-10-09 に確認) に基づく。Codex は
# 同型の payload を受ける前提 (2026-10-04 の probe で PreToolUse の同型を実測。Codex への登録は
# #454 の scope 外)。「Pre があって Post が無い」call を拒否と断定しない (結果不明) のは集計側の約束。

require "English"
require "fileutils"
require "json"
require "time"

module ToolCallRecordHook
  VERSION = "1"
  NAME = "personal-tool-call-record-hook"
  DIR_ENV = "AGENT_TOOLS_TOOL_CALL_RECORD_DIR"

  EVENTS = %w[SessionStart PreToolUse PostToolUse PostToolUseFailure PermissionDenied].freeze
  # env の目印 → client 名 (personal-ai-trailer-gate と同じ目印)。先に一致した方。
  CLIENT_MARKERS = [
    ["claude-code", %w[CLAUDECODE]],
    ["codex", %w[CODEX_THREAD_ID CODEX_SANDBOX]],
  ].freeze
  # 版を取る command。codex の登録は #454 の scope 外なので、codex / unknown は "unknown" になる。
  VERSION_COMMANDS = { "claude-code" => %w[claude --version] }.freeze
  NOTION_UPDATE_PAGE_RE = /notion-update-page\z/.freeze
  NOTION_OPS = {
    "insert_content" => "append",
    "update_content" => "edit",
    "replace_content" => "replace",
  }.freeze
  REASON_CAP = 200

  module_function

  # entrypoint。stdin の読み取りも保護範囲に入れる (読めなければ何も記録せず exit 0)。
  def run(stdin: $stdin, err: $stderr)
    main(stdin.read, err: err)
  rescue SystemCallError, IOError => e
    report(err, "could not read stdin (#{e.class}); nothing recorded")
    0
  end

  # 戻り値は exit code (常に 0)。env / err / now は test の差し替え口。
  def main(stdin_text, env: ENV, err: $stderr, now: Time.now)
    payload = parse(stdin_text)
    if payload.nil?
      report(err, "stdin is not a JSON object; nothing recorded")
      return 0
    end
    event = payload["hook_event_name"]
    return 0 unless EVENTS.include?(event)

    client = detect_client(env)
    path = record_path(env, client)
    if path.nil?
      report(err, "no absolute record location (set #{DIR_ENV}, XDG_STATE_HOME or HOME); nothing recorded")
      return 0
    end
    append(path, build_record(payload, event, client, now))
    0
  rescue SystemCallError, IOError => e
    report(err, "could not write record (#{e.class}); nothing recorded")
    0
  rescue StandardError => e
    report(err, "unexpected #{e.class}; nothing recorded")
    0
  end

  # 診断の 1 行。stderr が閉じていても exit 0 を保つ (診断の失敗で tool call を止めない)。
  def report(err, message)
    err.puts "#{NAME}: #{message}"
  rescue SystemCallError, IOError
    nil
  end

  def parse(text)
    data = JSON.parse(text.to_s)
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  def detect_client(env)
    CLIENT_MARKERS.each do |name, keys|
      return name if keys.any? { |k| !env[k].to_s.empty? }
    end
    "unknown"
  end

  # 書込先は入口で 1 回だけ解決する。相対 path は cwd 依存になるので受け付けない (nil)。
  def record_path(env, client)
    dir = env[DIR_ENV].to_s
    if dir.empty?
      state = env["XDG_STATE_HOME"].to_s
      if state.empty?
        home = env["HOME"].to_s
        return nil if home.empty?

        state = File.join(home, ".local", "state")
      end
      dir = File.join(state, "agent-tools", NAME)
    end
    return nil unless dir.start_with?("/")

    File.join(dir, "#{client}.jsonl")
  end

  def build_record(payload, event, client, now)
    record = {
      "ts" => now.iso8601,
      "event" => event,
      "client" => client,
      "session_id" => string_or_nil(payload["session_id"]),
      "agent_type" => string_or_nil(payload["agent_type"]),
      "permission_mode" => string_or_nil(payload["permission_mode"]),
    }
    if event == "SessionStart"
      record["version"] = client_version(client)
    else
      record.merge!(tool_fields(payload, event))
    end
    record.compact
  end

  def tool_fields(payload, event)
    tool = string_or_nil(payload["tool_name"])
    input = payload["tool_input"]
    duration = payload["duration_ms"]
    {
      "tool" => tool,
      "tool_use_id" => string_or_nil(payload["tool_use_id"]),
      "mcp_server" => mcp_server(payload["mcp_server"]),
      "arg_keys" => input.is_a?(Hash) ? input.keys.map(&:to_s).sort : nil,
      "op" => notion_op(tool, input),
      "result" => result_of(event, payload),
      "duration_ms" => duration.is_a?(Numeric) ? duration : nil,
      "reason" => event == "PermissionDenied" ? truncate(string_or_nil(payload["reason"])) : nil,
    }
  end

  def mcp_server(value)
    return nil unless value.is_a?(Hash)

    { "name" => string_or_nil(value["name"]), "source" => string_or_nil(value["source"]) }.compact
  end

  # Notion の update-page だけ、command の enum を分類した結果を書く (値は書かない)。
  def notion_op(tool, input)
    return nil unless tool && tool.match?(NOTION_UPDATE_PAGE_RE) && input.is_a?(Hash) && input.key?("command")

    command = input["command"]
    command.is_a?(String) ? NOTION_OPS.fetch(command, "other") : "other"
  end

  def result_of(event, payload)
    case event
    when "PostToolUse" then "output"
    when "PostToolUseFailure" then payload["is_interrupt"] == true ? "interrupted" : "error"
    end
  end

  # 版は SessionStart でだけ取る。取れなければ "unknown" (D1-5 の「取れないとき」の約束)。
  def client_version(client)
    command = VERSION_COMMANDS[client]
    return "unknown" if command.nil?

    # stderr は捨てる (警告が版として残り、警告中の path が記録に入るのを防ぐ)。
    output = IO.popen(command, err: File::NULL, &:read)
    return "unknown" unless $CHILD_STATUS&.success?

    line = output.to_s.lines.first.to_s.strip
    line.empty? ? "unknown" : line.scrub
  rescue SystemCallError
    "unknown"
  end

  def append(path, record)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |f| f.write(JSON.generate(record) + "\n") }
  end

  def string_or_nil(value)
    value.is_a?(String) ? value.scrub : nil
  end

  def truncate(text)
    return nil if text.nil?

    text.length > REASON_CAP ? text[0, REASON_CAP] : text
  end
end

exit ToolCallRecordHook.run if $PROGRAM_NAME == __FILE__
