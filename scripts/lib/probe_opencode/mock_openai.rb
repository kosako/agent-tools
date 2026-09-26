# frozen_string_literal: true

# OpenCode plugin probe (#295 PR 0) の mock provider。127.0.0.1 で OpenAI 互換の
# chat completions (SSE) を返す。実 model を使わずに、OpenCode が送る tool 名の一覧と、
# plugin が tool.execute.after で書き換えた出力が次の request に載るかを観測するため。
# Spec: docs/opencode-plugin-probe.md。
#
# 応答は prompt に埋めた `PROBE-SCENARIO:<name>` と、その後に続く assistant の tool call の数
# (= step) だけで決める (request 間で状態を持たない)。scenario に当たらない request (title や
# summary の生成など、tools を持たない request を含む) には固定の text を返す。
#
# 記録は判定に要る部分だけ: method / path / model / tool 名の一覧 / scenario と step /
# tool message の先頭の nonce の有無 / system message の model ID の有無 / 実 HOME の path と
# canary が body に現れたか (真偽値)。header と body の本文は記録しない。
#
# socket (TCPServer) だけで書く (WEBrick は Ruby 3.0 で標準から外れたため)。

require "json"
require "socket"

module ProbeOpencode
  class MockOpenAI
    SCENARIO_MARK = /PROBE-SCENARIO:([a-z][a-z0-9-]*)/.freeze
    OK_MARKER = "PROBE-BASH-OK"
    FINAL_TEXT = "PROBE-DONE"
    FALLBACK_TEXT = "ok"
    # bash に立っているかを見る env の名前。値は出さず名前だけを出す。
    ENV_NAME_RE = "OPENCODE|AGENT|OPENCODE_PID|OPENCODE_SESSION_ID|AGENT_TOOLS_PROBE_MARK|CLAUDECODE|CODEX_THREAD_ID|CODEX_SANDBOX"
    # model の bash と、その子 process (sh -c) に立っている目印の名前を出す (M5)。
    ENV_NAMES_CMD = "env | cut -d= -f1 | grep -xE '#{ENV_NAME_RE}' | sort | sed 's/^/env:/'; " \
                    "sh -c 'env | cut -d= -f1 | grep -xE \"#{ENV_NAME_RE}\" | sort | sed \"s/^/child:/\"'; " \
                    "echo #{OK_MARKER}"

    def self.bash(command)
      { "name" => "bash", "arguments" => { "command" => command } }
    end

    # scenario ごとの tool call の列。列を使い切ったら FINAL_TEXT を返す。
    SCENARIOS = {
      # M3 (claude 系の tool 名) / M4 / M5 / M14。edit の失敗と bash の exit 3 を含む。
      "tools" => [
        bash(ENV_NAMES_CMD),
        { "name" => "write", "arguments" => { "filePath" => "probe-write.txt", "content" => "one\n" } },
        { "name" => "edit", "arguments" => { "filePath" => "probe-write.txt", "oldString" => "one", "newString" => "two" } },
        { "name" => "edit", "arguments" => { "filePath" => "probe-write.txt", "oldString" => "probe-no-such-text", "newString" => "x" } },
        bash("echo #{OK_MARKER}; exit 3"),
      ],
      # M3 (gpt 系の tool 名と apply_patch の metadata.files)。
      "tools-patch" => [
        { "name" => "apply_patch", "arguments" => { "patchText" => "*** Begin Patch\n*** Add File: probe-patch.txt\n+one\n*** End Patch" } },
        { "name" => "apply_patch", "arguments" => { "patchText" => "*** Begin Patch\n*** Update File: probe-patch.txt\n@@\n-one\n+two\n*** End Patch" } },
        bash(ENV_NAMES_CMD),
      ],
      "bash-env" => [bash(ENV_NAMES_CMD)],
      # M7: tool が実行されたかを project の file で見る。
      "touch-mark" => [bash("touch probe-executed; echo #{OK_MARKER}")],
      # M9: serve で実行中に abort する。
      "slow" => [bash("sleep 5; echo #{OK_MARKER}")],
      # M9: run が permission の ask を自動で拒否する (config で `touch probe-ask*` を ask にする)。
      "ask" => [bash("touch probe-ask-file")],
      # M9: task の子 session。子の prompt は "child" scenario になる。
      "task" => [{ "name" => "task", "arguments" => { "description" => "probe child", "prompt" => "PROBE-SCENARIO:child", "subagent_type" => "general" } }],
      "child" => [],
    }.freeze

    attr_accessor :run_label
    attr_reader :port

    # log_path: 記録の JSONL。real_home: body に現れたら home_path_seen を立てる文字列 (値は記録しない)。
    # canaries: { "名前" => "文字列" }。body に現れたかを名前ごとの真偽値で記録する。
    def initialize(log_path:, nonce:, real_home:, canaries: {}, provider_id: "probe")
      @log_path = log_path
      @nonce = nonce
      @real_home = real_home
      @canaries = canaries
      @provider_id = provider_id
      @mutex = Mutex.new
      @run_label = nil
    end

    def start
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { accept_loop }
      @thread.report_on_exception = false
      @port
    end

    def stop
      @server&.close
      @thread&.join(2)
    end

    def base_url
      "http://127.0.0.1:#{@port}/v1"
    end

    # --- 判定 (request の body から) -----------------------------------------------------

    def self.text_of(content)
      case content
      when String then content
      when Array then content.map { |p| p.is_a?(Hash) && p["text"].is_a?(String) ? p["text"] : "" }.join
      else ""
      end
    end

    # 最後に marker を含む user message の位置と scenario 名。無ければ nil。
    def self.scenario_of(messages)
      idx = messages.rindex { |m| m["role"] == "user" && text_of(m["content"]).match?(SCENARIO_MARK) }
      return nil unless idx

      [idx, text_of(messages[idx]["content"])[SCENARIO_MARK, 1]]
    end

    def self.step_of(messages, from)
      messages[(from + 1)..-1].count { |m| m["role"] == "assistant" && m["tool_calls"].is_a?(Array) && !m["tool_calls"].empty? }
    end

    # 応答: [:tool, call_id, name, args] か [:text, text]。
    def self.reply_for(body)
      messages = body["messages"].is_a?(Array) ? body["messages"] : []
      tools = body["tools"].is_a?(Array) ? body["tools"] : []
      found = scenario_of(messages)
      return [[:text, FALLBACK_TEXT], nil, nil] if found.nil? || tools.empty?

      idx, name = found
      steps = SCENARIOS[name]
      return [[:text, FALLBACK_TEXT], name, nil] if steps.nil?

      step = step_of(messages, idx)
      return [[:text, FINAL_TEXT], name, step] if step >= steps.length

      call = steps[step]
      [[:tool, "call_#{name.tr('-', '_')}_#{step}", call["name"], call["arguments"]], name, step]
    end

    def summarize(body, raw, method, path)
      messages = body["messages"].is_a?(Array) ? body["messages"] : []
      tools = body["tools"].is_a?(Array) ? body["tools"] : []
      model = body["model"].is_a?(String) ? body["model"] : nil
      system = messages.select { |m| m["role"] == "system" }.map { |m| self.class.text_of(m["content"]) }.join("\n")
      tool_messages = messages.select { |m| m["role"] == "tool" }.map do |m|
        text = self.class.text_of(m["content"])
        { "id" => m["tool_call_id"].is_a?(String) ? m["tool_call_id"] : nil,
          "nonce_first" => !@nonce.empty? && text.start_with?(@nonce),
          "ok_marker" => text.include?(OK_MARKER) }
      end
      {
        "method" => method,
        "path" => path,
        "model" => model,
        "stream" => body["stream"] == true,
        "tools" => tools.map { |t| t.is_a?(Hash) ? t.dig("function", "name") : nil }.compact.sort,
        "n_messages" => messages.length,
        "tool_messages" => tool_messages,
        "system_has_provider_model" => !model.nil? && system.include?("#{@provider_id}/#{model}"),
        "system_has_model" => !model.nil? && system.include?(model),
        "home_path_seen" => !@real_home.to_s.empty? && raw.include?(@real_home),
        "canaries_seen" => @canaries.map { |k, v| [k, raw.include?(v)] }.to_h,
      }
    end

    # --- HTTP -------------------------------------------------------------------------

    private

    def accept_loop
      loop do
        sock = @server.accept
        t = Thread.new(sock) { |s| handle(s) }
        t.report_on_exception = false
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def handle(sock)
      request_line = sock.gets("\r\n")
      return if request_line.nil?

      method, target, = request_line.split(" ", 3)
      headers = {}
      while (line = sock.gets("\r\n")) && line != "\r\n"
        k, v = line.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip if v
      end
      raw = read_body(sock, headers)
      path = target.to_s.split("?", 2).first
      body = parse_json(raw)
      if method == "POST" && path.end_with?("/chat/completions")
        reply, scenario, step = self.class.reply_for(body)
        log(summarize(body, raw, method, path).merge("scenario" => scenario, "step" => step, "reply" => reply.first.to_s))
        write_completion(sock, body, reply)
      else
        log("method" => method, "path" => path, "unhandled" => true)
        write_response(sock, 404, "application/json", JSON.generate("error" => { "message" => "probe mock: not found" }))
      end
    rescue IOError, SystemCallError
      nil
    ensure
      sock.close unless sock.closed?
    end

    def read_body(sock, headers)
      if headers["transfer-encoding"].to_s.downcase.include?("chunked")
        buf = +""
        loop do
          size = sock.gets("\r\n").to_s.strip.split(";").first.to_i(16)
          break if size.zero?

          buf << sock.read(size)
          sock.read(2)
        end
        sock.gets("\r\n")
        buf
      else
        len = headers["content-length"].to_i
        len.positive? ? sock.read(len).to_s : ""
      end
    end

    def parse_json(raw)
      v = JSON.parse(raw)
      v.is_a?(Hash) ? v : {}
    rescue JSON::ParserError
      {}
    end

    def log(fields)
      line = JSON.generate({ "t" => (Time.now.to_f * 1000).to_i, "run" => @run_label }.merge(fields))
      @mutex.synchronize { File.open(@log_path, "a") { |f| f.puts(line) } }
    end

    def chunk(model, delta, finish)
      c = { "id" => "chatcmpl-probe", "object" => "chat.completion.chunk", "created" => Time.now.to_i,
            "model" => model, "choices" => [{ "index" => 0, "delta" => delta, "finish_reason" => finish }] }
      c["usage"] = { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 } if finish
      c
    end

    def write_completion(sock, body, reply)
      model = body["model"].is_a?(String) ? body["model"] : "probe"
      kind, *rest = reply
      if body["stream"] == true
        chunks = if kind == :tool
                   id, name, args = rest
                   call = { "index" => 0, "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }
                   [chunk(model, { "role" => "assistant", "tool_calls" => [call] }, nil), chunk(model, {}, "tool_calls")]
                 else
                   [chunk(model, { "role" => "assistant", "content" => rest.first }, nil), chunk(model, {}, "stop")]
                 end
        payload = chunks.map { |c| "data: #{JSON.generate(c)}\n\n" }.join + "data: [DONE]\n\n"
        write_response(sock, 200, "text/event-stream", payload)
      else
        message = if kind == :tool
                    id, name, args = rest
                    { "role" => "assistant", "content" => nil,
                      "tool_calls" => [{ "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }] }
                  else
                    { "role" => "assistant", "content" => rest.first }
                  end
        finish = kind == :tool ? "tool_calls" : "stop"
        payload = JSON.generate("id" => "chatcmpl-probe", "object" => "chat.completion", "created" => Time.now.to_i, "model" => model,
                                "choices" => [{ "index" => 0, "message" => message, "finish_reason" => finish }],
                                "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 })
        write_response(sock, 200, "application/json", payload)
      end
    end

    def write_response(sock, status, type, payload)
      reason = status == 200 ? "OK" : "Not Found"
      sock.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{payload.bytesize}\r\n" \
                 "Cache-Control: no-cache\r\nConnection: close\r\n\r\n#{payload}")
    end
  end
end
