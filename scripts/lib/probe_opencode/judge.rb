# frozen_string_literal: true

# OpenCode plugin probe (#295 PR 0) の判定。runner が out dir に残した記録 (facts.json /
# hooks.jsonl / mock-requests.jsonl / run-events.jsonl / git-hooks.jsonl) から、M1〜M20 の
# observed と verdict を出す。Spec: docs/opencode-plugin-probe.md。
#
# verdict:
#   confirmed = source からの予測と一致 / differs = 食い違う /
#   unknown   = data が欠けている (pass には数えない。reason を付ける) /
#   observed  = source からの予測が無い項目で、観測した値だけを載せる。
# 予測は OpenCode 1.18.30 の source を読んで立てたもの (docs の「既知の事実」)。

require "json"

module ProbeOpencode
  module Judge
    ITEMS = {
      "M1" => ["隔離", "PR 0 全体の前提"],
      "M2" => ["plugin の読込", "PR 1 の plugin の形と marker 行"],
      "M3" => ["編集系 tool の名前と args", "PR 2 の対象 tool と path の取り方"],
      "M4" => ["after の書き換えが model に届くか", "Q2 / Q3 の前提 (PR 1 / PR 2)"],
      "M5" => ["bash の子 process の env", "PR 3a の目印と絞り方"],
      "M6" => ["shell.env が throw したとき", "PR 3a の fail-open"],
      "M7" => ["tool hook の throw / slow", "PR 1 / PR 2 の fail-open と timeout"],
      "M8" => ["event hook が reject したとき", "PR 2 の fail-open"],
      "M9" => ["session.idle の出る時点", "PR 2 の直列化と子 session の除外"],
      "M10" => ["run での打ち切り", "PR 2 の docs"],
      "M11" => ["人に見える経路", "PR 2、PR 1 の docs"],
      "M12" => ["plugin から見える model の識別子", "PR 3a の regex と系列表の fixture"],
      "M13" => ["spawn の所要時間と kill", "PR 1 / PR 2 の timeout と kill の方法"],
      "M14" => ["after が呼ばれない条件", "PR 2 と docs"],
      "M15" => ["~/.claude の互換読込", "PR 1 (skill と instruction を配らない) / PR 3b"],
      "M16" => ["実 model の smoke", "PR 1 の Q2 の実効性"],
      "M17" => ["TUI の手動 checklist", "PR 2 の toast / PR 3a の目印"],
      "M18" => ["OpenCode 内部の git", "PR 3a"],
      "M19" => ["system message の model ID", "PR 3b (PR 3a の前に判断)"],
      "M20" => ["普段の起動経路での漏れ", "PR 3a の漏れ対策の記録"],
    }.freeze

    NAME_LINE = /^(env|child):([A-Z_][A-Z0-9_]*)$/.freeze
    MARK = "AGENT_TOOLS_PROBE_MARK"
    SOURCE_MARKERS = { "OPENCODE" => true, "AGENT" => true, "OPENCODE_PID" => true, "OPENCODE_SESSION_ID" => false }.freeze

    JSONL_FILES = { "hooks" => "hooks.jsonl", "mock" => "mock-requests.jsonl", "events" => "run-events.jsonl",
                    "git_hooks" => "git-hooks.jsonl" }.freeze

    # [記録, 読めなかった行数]。parse できない行と object でない行を数える (黙って捨てると、欠測が
    # 「記録なし」に化けて予測どおりに数えられる)。
    def self.read_jsonl(path)
      return [[], 0] unless File.file?(path)

      broken = 0
      recs = File.readlines(path).map do |l|
        v = JSON.parse(l)
        v.is_a?(Hash) ? v : (broken += 1
                             nil)
      rescue JSON::ParserError
        broken += 1
        nil
      end.compact
      [recs, broken]
    end

    def self.load(dir)
      facts_path = File.join(dir, "facts.json")
      data = { "facts" => File.file?(facts_path) ? JSON.parse(File.read(facts_path)) : {}, "load_errors" => {} }
      JSONL_FILES.each do |key, file|
        recs, broken = read_jsonl(File.join(dir, file))
        data[key] = recs
        data["load_errors"][file] = broken if broken.positive?
      end
      data
    end

    # 結合に使う ID (callID / sessionID) は、空でない文字列のときだけ有効 (欠けた ID 同士を一致とみなさない)。
    def self.valid_id?(v)
      v.is_a?(String) && !v.empty?
    end

    # pred: 予測の flat hash (nil なら予測なし)。obs: 観測の flat hash。
    # 予測の key のうち観測が nil のものがあれば unknown にする (欠けた data を pass に数えない)。
    def self.verdict(pred, obs)
      return "observed" if pred.nil?
      return "unknown" if pred.keys.any? { |k| obs[k].nil? }

      pred.all? { |k, v| obs[k] == v } ? "confirmed" : "differs"
    end

    def self.item(id, pred:, obs:, extra: {}, reason: nil)
      v = verdict(pred, obs)
      missing = pred ? pred.keys.select { |k| obs[k].nil? } : []
      reason ||= "data が無い: #{missing.join(', ')}" if v == "unknown"
      title, uses = ITEMS.fetch(id)
      { "id" => id, "title" => title, "uses" => uses, "prediction" => pred, "observed" => obs.merge(extra),
        "verdict" => v, "reason" => reason }
    end

    def self.manual(id, reason, extra = {})
      title, uses = ITEMS.fetch(id)
      { "id" => id, "title" => title, "uses" => uses, "prediction" => nil, "observed" => extra,
        "verdict" => "unknown", "reason" => reason }
    end

    # --- 記録の取り出し -----------------------------------------------------------------

    def self.run_fact(data, label)
      (data["facts"]["runs"] || []).find { |r| r["label"] == label }
    end

    # run が観測できる地点まで正常に進んだか (exit 0・timeout なし・event が出た)。欠けた data や
    # 起動の失敗を、予測どおりの「0 件」や「記録なし」に数えないために使う。
    def self.run_ok?(fact)
      !fact.nil? && fact["exit"] == 0 && fact["timed_out"] == false && fact["events"].to_i.positive?
    end

    # `!` (op = "shell") と PTY (op = "pty") の shell.env を、runner が記録した操作の時間帯 (POST の直前から、
    # 結果を確かめ終えるまで) で選ぶ。検査したい値 (sessionID / callID) で選ぶと判定が循環する。runner は
    # この時間帯に他の操作をしないので、余裕は取らない (取ると隣の操作の記録を拾う。実測で起きた)。
    # 時間帯が無ければ nil。
    def self.window_records(data, run, fact, op)
      t0 = fact && fact.dig(op, "t_start")
      t1 = fact && fact.dig(op, "t_end")
      return nil unless t0.is_a?(Integer) && t1.is_a?(Integer)

      hooks(data, run, "shell.env").select { |h| h["t"].is_a?(Integer) && h["t"] >= t0 && h["t"] <= t1 }
    end

    def self.hooks(data, run, kind)
      data["hooks"].select { |h| h["run"] == run && h["kind"] == kind }
    end

    def self.mock(data, run)
      data["mock"].select { |m| m["run"] == run && !m["unhandled"] }
    end

    def self.tool_parts(data, run, tool = nil)
      data["events"].select do |e|
        ev = e["event"] || {}
        part = ev["part"] || {}
        e["run"] == run && ev["type"] == "tool_use" && (tool.nil? || part["tool"] == tool)
      end.map { |e| e["event"]["part"] }
    end

    def self.names_from(text)
      out = { "env" => [], "child" => [] }
      text.to_s.each_line { |l| (m = l.strip.match(NAME_LINE)) && out[m[1]] << m[2] }
      out
    end

    # bash の出力から、env と child それぞれで目印の名前が立っているかを返す。
    def self.presence(names, keys)
      return nil if names.nil?

      keys.map { |k| [k, names.include?(k)] }.to_h
    end

    def self.env_names_of_run(data, run)
      part = tool_parts(data, run, "bash").find { |p| p.dig("state", "output").to_s.include?("PROBE-BASH-OK") && p.dig("state", "output").to_s.match?(/^env:|^child:/) }
      part && names_from(part.dig("state", "output"))
    end

    def self.flatten(prefix, hash)
      return { prefix => nil } if hash.nil?

      hash.map { |k, v| ["#{prefix}.#{k}", v] }.to_h
    end

    def self.idle_for(data, run, session_id = nil)
      hooks(data, run, "event").select { |h| h["type"] == "session.idle" && (session_id.nil? || h["sessionID"] == session_id) }
    end

    def self.main_session(data, run)
      e = data["events"].find { |x| x["run"] == run && x.dig("event", "sessionID") }
      e && e["event"]["sessionID"]
    end

    # --- 項目 ---------------------------------------------------------------------------

    def self.m1(data)
      iso = data["facts"]["isolation"]
      mtime = data["facts"]["real_mtime"] || {}
      mocks = data["mock"].reject { |m| m["unhandled"] }
      exits = (iso && iso["exits"]) || {}
      obs = {
        # debug paths / config / models が正常に終わったときだけ (途中までの出力で判定しない)。
        "paths_under_tmp" => exits["paths"] == 0 ? iso["paths_all_under_tmp"] : nil,
        "only_probe_provider" => exits["config"] == 0 && exits["models"] == 0 && iso["config_providers"] ? iso["config_providers"] == ["probe"] && iso["models_providers"] == ["probe"] : nil,
        # 実物の config dir / DB が 1 つも無ければ、比べる対象が無いので unknown にする。
        "real_state_unchanged" => mtime["before"].is_a?(Hash) && mtime["before"].values.any? && mtime["after"] ? mtime["before"] == mtime["after"] : nil,
        # どの request にも真偽値の home_path_seen があるときだけ (欠けた field を「送っていない」と数えない)。
        "home_path_not_sent" => mocks.empty? || !mocks.all? { |m| [true, false].include?(m["home_path_seen"]) } ? nil : mocks.none? { |m| m["home_path_seen"] },
      }
      extra = { "install" => data["facts"]["install"], "log_hosts" => data["facts"]["log_hosts"],
                "outside_labels" => iso && iso["outside_labels"] }
      item("M1", pred: obs.keys.map { |k| [k, true] }.to_h, obs: obs, extra: extra)
    end

    def self.m2(data)
      inits = hooks(data, "tools-claude", "init")
      pure = run_fact(data, "pure")
      throw_run = run_fact(data, "throw-init")
      throw_inits = hooks(data, "throw-init", "init").map { |h| h["label"] }
      order = inits.sort_by { |h| h["t"] }.map { |h| h["label"] }
      # 予測は source の読込順 (global の plugins dir → project の plugins dir) だけ。同じ dir の中の
      # 順は source に定めが無いので、観測値として残す。
      obs = {
        # 両方の global と project の init があるときだけ比べる。
        "global_before_project" => (%w[probe-global-a probe-global-b probe-project] - order).empty? ? order.index("probe-project") > [order.index("probe-global-a"), order.index("probe-global-b")].max : nil,
        "marker_file_inits" => inits.empty? ? nil : inits.count { |h| h["label"] == "probe-global-a" },
        "each_file_once" => inits.empty? ? nil : order.uniq.length == order.length && order.length == 3,
        "pure_inits" => run_ok?(pure) ? hooks(data, "pure", "init").length : nil,
        # throw させた plugin (global-b) は throw の直前に init を記録するので、それを throw に届いた証跡にする。
        "throw_init_continues" => throw_run && throw_inits.include?("probe-global-b") ? (run_ok?(throw_run) && throw_inits.include?("probe-global-a") && throw_inits.include?("probe-project")) : nil,
      }
      pred = { "global_before_project" => true, "marker_file_inits" => 1, "each_file_once" => true,
               "pure_inits" => 0, "throw_init_continues" => true }
      extra = { "init_order" => order, "throw_init_stderr_mentions_plugin" => throw_run && throw_run["stderr_has_plugin"],
                "throw_init_error_events" => data["events"].count { |e| e["run"] == "throw-init" && e.dig("event", "type") == "error" } }
      item("M2", pred: pred, obs: obs, extra: extra)
    end

    def self.tools_of(data, run)
      reqs = mock(data, run).select { |m| m["tools"].is_a?(Array) && !m["tools"].empty? }
      reqs.empty? ? nil : reqs.flat_map { |m| m["tools"] }.uniq.sort
    end

    def self.m3(data)
      c = tools_of(data, "tools-claude")
      g = tools_of(data, "tools-gpt")
      obs = {
        "claude_has_edit_write" => c && c.include?("edit") && c.include?("write"),
        "claude_has_apply_patch" => c && c.include?("apply_patch"),
        "gpt_has_apply_patch" => g && g.include?("apply_patch"),
        "gpt_has_edit_write" => g && (g.include?("edit") || g.include?("write")),
        "has_multiedit_or_patch" => c && g ? (c + g).any? { |t| %w[multiedit patch].include?(t) } : nil,
      }
      pred = { "claude_has_edit_write" => true, "claude_has_apply_patch" => false, "gpt_has_apply_patch" => true,
               "gpt_has_edit_write" => false, "has_multiedit_or_patch" => false }
      files = hooks(data, "tools-gpt", "tool.after").select { |h| h["tool"] == "apply_patch" }.map { |h| h["files"] }
      extra = { "claude_tools" => c, "gpt_tools" => g, "apply_patch_files" => files,
                "arg_keys" => hooks(data, "tools-claude", "tool.before").map { |h| [h["tool"], h["arg_keys"]] }.uniq }
      item("M3", pred: pred, obs: obs, extra: extra)
    end

    # after を観測した call ごとに、completed の part と、次の request の tool message の両方が揃ったときだけ
    # 判定する (一部の call だけで予測どおりと数えない)。
    def self.m4(data)
      after_ids = hooks(data, "tools-claude", "tool.after").map { |h| h["callID"] }.select { |v| valid_id?(v) }.uniq
      msgs = mock(data, "tools-claude").flat_map { |m| m["tool_messages"] || [] }.select { |t| valid_id?(t["id"]) }.uniq { |t| t["id"] }
      parts = tool_parts(data, "tools-claude").select { |p| valid_id?(p["callID"]) && p.dig("state", "status") == "completed" }
      nonce = data["facts"]["nonce"].to_s
      complete = !after_ids.empty? && !nonce.empty? &&
                 after_ids.all? { |id| msgs.any? { |t| t["id"] == id } && parts.any? { |p| p["callID"] == id } }
      obs = {
        "next_request_has_nonce" => complete ? after_ids.all? { |id| msgs.find { |t| t["id"] == id }["nonce_first"] == true } : nil,
        "run_event_output_has_nonce" => complete ? after_ids.all? { |id| parts.find { |p| p["callID"] == id }.dig("state", "output").to_s.start_with?(nonce) } : nil,
      }
      extra = { "callid_equals_provider_tool_call_id" => msgs.empty? || after_ids.empty? ? nil : after_ids.all? { |id| msgs.any? { |t| t["id"] == id } } }
      item("M4", pred: obs.keys.map { |k| [k, true] }.to_h, obs: obs, extra: extra)
    end

    def self.shell_env_inputs(data)
      claude_before = hooks(data, "tools-claude", "tool.before").map { |h| h["callID"] }.select { |v| valid_id?(v) }
      model = hooks(data, "tools-claude", "shell.env")
      serve = run_fact(data, "serve-plugin") || {}
      serve_before = hooks(data, "serve-plugin", "tool.before").map { |h| h["callID"] }.select { |v| valid_id?(v) }
      bang = window_records(data, "serve-plugin", serve, "shell") || []
      pty = window_records(data, "serve-plugin", serve, "pty") || []
      {
        "model_bash.sessionID" => model.empty? ? nil : model.all? { |h| h["has_sessionID"] },
        "model_bash.callID" => model.empty? ? nil : model.all? { |h| h["has_callID"] },
        "model_bash.callID_matches_before" => model.empty? ? nil : model.all? { |h| valid_id?(h["callID"]) && claude_before.include?(h["callID"]) },
        "bang.sessionID" => bang.empty? ? nil : bang.all? { |h| h["has_sessionID"] },
        "bang.callID" => bang.empty? ? nil : bang.all? { |h| h["has_callID"] },
        "bang.callID_matches_before" => bang.empty? ? nil : bang.any? { |h| valid_id?(h["callID"]) && serve_before.include?(h["callID"]) },
        "pty.sessionID" => pty.empty? ? nil : pty.any? { |h| h["has_sessionID"] },
        "pty.callID" => pty.empty? ? nil : pty.any? { |h| h["has_callID"] },
      }
    end

    # `!` / PTY の env の名前は、操作が成功し command が最後まで走った印 (OK_MARKER) があるときだけ使う
    # (失敗した出力から作った空の一覧を「立っていない」と数えない)。
    def self.op_names(fact, op)
      o = fact[op]
      return nil unless o.is_a?(Hash) && o["status"] == 200 && o["ok_marker"] == true

      o.dig("names", "env")
    end

    def self.m5(data)
      keys = SOURCE_MARKERS.keys + [MARK]
      plugin_pred = SOURCE_MARKERS.merge(MARK => true)
      pure_pred = SOURCE_MARKERS.merge(MARK => false)
      claude = env_names_of_run(data, "tools-claude")
      pure = env_names_of_run(data, "pure")
      serve = run_fact(data, "serve-plugin") || {}
      serve_pure = run_fact(data, "serve-pure") || {}
      obs = {}
      obs.merge!(flatten("model_bash.plugin.env", presence(claude && claude["env"], keys)))
      obs.merge!(flatten("model_bash.plugin.child", presence(claude && claude["child"], keys)))
      obs.merge!(flatten("model_bash.pure.env", presence(pure && pure["env"], keys)))
      obs.merge!(flatten("bang.plugin.env", presence(op_names(serve, "shell"), keys)))
      obs.merge!(flatten("bang.pure.env", presence(op_names(serve_pure, "shell"), keys)))
      obs.merge!(flatten("pty.plugin.env", presence(op_names(serve, "pty"), keys)))
      obs.merge!(flatten("pty.pure.env", presence(op_names(serve_pure, "pty"), keys)))
      obs.merge!(shell_env_inputs(data))
      pred = {}
      pred.merge!(flatten("model_bash.plugin.env", plugin_pred))
      pred.merge!(flatten("model_bash.plugin.child", plugin_pred))
      pred.merge!(flatten("model_bash.pure.env", pure_pred))
      pred.merge!(flatten("bang.plugin.env", plugin_pred))
      pred.merge!(flatten("bang.pure.env", pure_pred))
      pred.merge!(flatten("pty.plugin.env", plugin_pred))
      pred.merge!(flatten("pty.pure.env", pure_pred))
      pred.merge!("model_bash.sessionID" => true, "model_bash.callID" => true, "model_bash.callID_matches_before" => true,
                  "bang.sessionID" => true, "bang.callID" => true, "bang.callID_matches_before" => false,
                  "pty.sessionID" => false, "pty.callID" => false)
      extra = { "shell" => data["facts"]["shell"],
                "other_agent_markers_in_opencode_process" => hooks(data, "tools-claude", "shell.env").map { |h| h["process_markers"] }.uniq }
      item("M5", pred: pred, obs: obs, extra: extra)
    end

    # 「失敗した」と数えるのは、shell.env の hook に届いた記録があり、その経路の応答を受け取れたときだけ。
    # session の作成や通信の失敗 (status が無い) は、hook を試せていないので unknown にする。
    def self.m6(data)
      run = "throw-shell-env"
      part = tool_parts(data, run, "bash").first
      model_reached = !part.nil? && valid_id?(part["callID"]) && hooks(data, run, "shell.env").any? { |h| h["callID"] == part["callID"] }
      serve = run_fact(data, "serve-throw-shell-env")
      bang_status = serve && serve.dig("shell", "status")
      bang_reached = !(window_records(data, "serve-throw-shell-env", serve, "shell") || []).empty?
      pty_status = serve && serve.dig("pty", "status")
      pty_reached = !(window_records(data, "serve-throw-shell-env", serve, "pty") || []).empty?
      obs = {
        "model_bash_fails" => part && model_reached ? part.dig("state", "status") == "error" : nil,
        "bang_fails" => bang_reached && !bang_status.nil? ? (bang_status != 200 || serve.dig("shell", "part_status") == "error") : nil,
        "pty_fails" => pty_reached && !pty_status.nil? ? (pty_status != 200 || !serve.dig("pty", "file_written")) : nil,
      }
      extra = { "model_bash_executed" => (run_fact(data, "throw-shell-env") || {})["executed_marker"] }
      item("M6", pred: obs.keys.map { |k| [k, true] }.to_h, obs: obs, extra: extra)
    end

    # その call が hook (before か after) に届いた記録があるときだけ判定する。hook に届かずに bash が別の
    # 原因で失敗した場合や、hook を通らずに遅れた場合を、予測どおりに数えない。
    def self.m7_run(data, run, hook_kind)
      fact = run_fact(data, run)
      part = tool_parts(data, run, "bash").first
      rec = part && valid_id?(part["callID"]) && hooks(data, run, hook_kind).find { |h| h["callID"] == part["callID"] }
      return {} unless fact && rec

      msgs = mock(data, run).flat_map { |m| m["tool_messages"] || [] }
      time = part.dig("state", "time")
      {
        "executed" => fact["executed_marker"],
        "part_status" => part.dig("state", "status"),
        "model_got_ok_marker" => msgs.empty? ? nil : msgs.any? { |t| t["ok_marker"] },
        "part_ms" => time && time["start"] && time["end"] ? time["end"] - time["start"] : nil,
        "hook_ms" => rec["hook_ms"],
      }
    end

    def self.m7(data)
      before = m7_run(data, "throw-before", "tool.before")
      after = m7_run(data, "throw-after", "tool.after")
      slow = m7_run(data, "slow-after", "tool.after")
      obs = {
        "throw_before.executed" => before["executed"], "throw_before.part_status" => before["part_status"],
        "throw_after.executed" => after["executed"], "throw_after.part_status" => after["part_status"],
        "slow_after.executed" => slow["executed"], "slow_after.part_status" => slow["part_status"],
        # after の中で待った時間 (hook_ms) と、それを含む part の時間の両方で見る。
        "slow_after.waited" => slow["hook_ms"].is_a?(Integer) && slow["part_ms"] ? slow["hook_ms"] >= 3000 && slow["part_ms"] >= slow["hook_ms"] : nil,
      }
      pred = { "throw_before.executed" => false, "throw_before.part_status" => "error",
               "throw_after.executed" => true, "throw_after.part_status" => "error",
               "slow_after.executed" => true, "slow_after.part_status" => "completed", "slow_after.waited" => true }
      extra = { "throw_before.model_got_ok_marker" => before["model_got_ok_marker"],
                "throw_after.model_got_ok_marker" => after["model_got_ok_marker"],
                "slow_after.part_ms" => slow["part_ms"], "slow_after.hook_ms" => slow["hook_ms"] }
      item("M7", pred: pred, obs: obs, extra: extra)
    end

    def self.m8(data)
      run = run_fact(data, "reject-event")
      serve = run_fact(data, "serve-reject-event")
      obs = {
        "run_exit" => run && run["exit"],
        "run_reached_final_text" => run ? data["events"].any? { |e| e["run"] == "reject-event" && e.dig("event", "type") == "text" } : nil,
        "serve_alive_after" => serve && serve["alive_after"],
      }
      item("M8", pred: nil, obs: obs, extra: { "tui" => "manual (M17)" })
    end

    def self.m9(data)
      main = main_session(data, "tools-claude")
      serve = run_fact(data, "serve-plugin") || {}
      bang_sid = serve.dig("shell", "session_id")
      abort_sid = serve.dig("abort", "session_id")
      # idle の有無を見るのは、その前の操作が成り立った証跡があるときだけ。操作の失敗を「idle が出ない」と
      # 数えない。
      bang_ok = valid_id?(bang_sid) && serve.dig("shell", "status") == 200
      # abort: prompt が受け付けられ (2xx)、abort を送る前にその session で bash が始まり (before の記録)、
      # abort を送る前には idle が無く (まだ実行中)、abort が成功したこと。idle は abort の後のものだけを数える。
      t_abort = serve.dig("abort", "t_abort")
      abort_before = ->(h) { h["t"].is_a?(Integer) && t_abort.is_a?(Integer) && h["t"] < t_abort }
      abort_ok = valid_id?(abort_sid) && t_abort.is_a?(Integer) && serve.dig("abort", "prompt_async_status").to_i.between?(200, 299) &&
                 hooks(data, "serve-plugin", "tool.before").any? { |h| h["sessionID"] == abort_sid && abort_before.call(h) } &&
                 idle_for(data, "serve-plugin", abort_sid).none? { |h| abort_before.call(h) } &&
                 serve.dig("abort", "abort_status") == 200
      # permission: ask された request と同じ requestID に「reject」の返答が出て、run が正常に終わったこと。
      asks = hooks(data, "ask", "event")
      asked_ids = asks.select { |h| h["type"] == "permission.asked" && valid_id?(h["requestID"]) }.map { |h| h["requestID"] }
      rejected = asks.any? { |h| h["type"] == "permission.replied" && h["reply"] == "reject" && asked_ids.include?(h["requestID"]) } &&
                 run_ok?(run_fact(data, "ask"))
      # task: 子 session が作られた記録 (parentID の付いた session.created) があること。
      children = hooks(data, "task", "event").select { |h| h["type"] == "session.created" && valid_id?(h["parentID"]) && valid_id?(h["sessionID"]) }.map { |h| h["sessionID"] }.uniq
      child_sessions = hooks(data, "task", "idle.session").select { |h| children.include?(h["sessionID"]) }
      obs = {
        "idle_per_turn" => valid_id?(main) && run_ok?(run_fact(data, "tools-claude")) ? idle_for(data, "tools-claude", main).length : nil,
        "idle_after_bang" => bang_ok ? !idle_for(data, "serve-plugin", bang_sid).empty? : nil,
        "idle_after_abort" => abort_ok ? idle_for(data, "serve-plugin", abort_sid).any? { |h| h["t"].is_a?(Integer) && h["t"] >= t_abort } : nil,
        "idle_after_permission_reject" => rejected ? !idle_for(data, "ask").empty? : nil,
        "child_idle_delivered" => !children.empty? && run_ok?(run_fact(data, "task")) ? idle_for(data, "task").any? { |h| children.include?(h["sessionID"]) } : nil,
        "child_parent_readable" => child_sessions.empty? ? nil : child_sessions.all? { |h| h["has_parentID"] },
      }
      pred = obs.keys.map { |k| [k, true] }.to_h.merge("idle_per_turn" => 1)
      extra = { "permission_asked_events" => hooks(data, "ask", "event").count { |h| h["type"] == "permission.asked" } }
      item("M9", pred: pred, obs: obs, extra: extra)
    end

    # 遅延の記録の有無を見るのは、対象の session が idle に達した (遅延の timer が張られた) ときだけ。
    # run は正常に終わったことも前提にする (idle の前の timeout や異常終了を「打ち切り」と数えない)。
    def self.m10(data)
      main = main_session(data, "tools-claude")
      run_idle = !main.nil? && run_ok?(run_fact(data, "tools-claude")) && !idle_for(data, "tools-claude", main).empty?
      serve = run_fact(data, "serve-plugin") || {}
      prompt_sid = serve.dig("prompt", "session_id")
      serve_idle = !prompt_sid.nil? && serve.dig("prompt", "status") == 200 && !idle_for(data, "serve-plugin", prompt_sid).empty?
      delayed_ok = hooks(data, "tools-claude", "idle.delayed").all? { |h| valid_id?(h["sessionID"]) }
      obs = {
        "run_delayed_recorded" => run_idle && delayed_ok ? hooks(data, "tools-claude", "idle.delayed").any? { |h| h["sessionID"] == main } : nil,
        "serve_delayed_recorded" => serve_idle ? hooks(data, "serve-plugin", "idle.delayed").any? { |h| h["sessionID"] == prompt_sid } : nil,
      }
      item("M10", pred: { "run_delayed_recorded" => false, "serve_delayed_recorded" => true }, obs: obs)
    end

    def self.m11(data)
      toast = ->(run) { hooks(data, run, "toast").first }
      log = ->(run) { hooks(data, run, "app.log").first }
      obs = {
        "run_toast" => toast.call("tools-claude"), "serve_toast" => toast.call("serve-plugin"),
        "run_app_log" => log.call("tools-claude"), "serve_app_log" => log.call("serve-plugin"),
        "app_log_found_in" => data["facts"]["app_log_found_in"],
      }
      item("M11", pred: nil, obs: obs, extra: { "tui" => "manual (M17)" })
    end

    def self.m12(data)
      params = hooks(data, "tools-claude", "chat.params")
      # 結合するのは、両方に有効な sessionID があるときだけ (欠けた ID 同士を一致とみなさない)。
      param_sids = params.map { |h| h["sessionID"] }.select { |v| v.is_a?(String) && !v.empty? }
      env_sids = hooks(data, "tools-claude", "shell.env").map { |h| h["sessionID"] }.select { |v| v.is_a?(String) && !v.empty? }
      p = params.first
      obs = {
        "providerID" => p && p["providerID"], "modelID" => p && p["modelID"], "apiID" => p && p["apiID"],
        "joinable_by_sessionID" => param_sids.empty? || env_sids.empty? ? nil : !(param_sids & env_sids).empty?,
      }
      pred = { "providerID" => "probe", "modelID" => "claude-probe", "apiID" => "claude-probe", "joinable_by_sessionID" => true }
      real = hooks(data, "real", "chat.params").first
      extra = { "chat_message" => hooks(data, "tools-claude", "chat.message").first&.slice("providerID", "modelID"),
                "real_chat_params" => real&.slice("providerID", "modelID", "apiID") }
      item("M12", pred: pred, obs: obs, extra: extra)
    end

    def self.m13(data)
      s = hooks(data, "spawn", "spawn").first
      # kill の直前に子と孫が生きていて、group への kill 自体が成功したときだけ判定する (自然に終わった
      # 後の kill を「効いた」と数えない)。
      killed = s && s["group_kill_error"].nil? && s["child_alive_before_kill"] == true && s["grandchild_alive_before_kill"] == true
      obs = { "child_killed" => killed ? s["child_exited"] : nil,
              "grandchild_killed" => killed && [true, false].include?(s["grandchild_alive"]) ? !s["grandchild_alive"] : nil }
      item("M13", pred: { "child_killed" => true, "grandchild_killed" => true }, obs: obs,
                  extra: s ? s.slice("spawn_ms", "spawn_exit", "group_kill_error", "grandchild_pid_read", "child_alive_before_kill", "grandchild_alive_before_kill") : {})
    end

    # part (終了の結果) と hook の記録を callID で対応付ける。edit の失敗 (part の status が error) と bash の
    # 非 0 終了 (metadata.exit) を確かめ、その call が before に届いていたときだけ、after の有無を見る。
    def self.m14(data)
      parts = tool_parts(data, "tools-claude").select { |x| valid_id?(x["callID"]) }
      before_ids = hooks(data, "tools-claude", "tool.before").map { |h| h["callID"] }.select { |v| valid_id?(v) }
      after_ids = hooks(data, "tools-claude", "tool.after").map { |h| h["callID"] }.select { |v| valid_id?(v) }
      failed_edits = parts.select { |x| x["tool"] == "edit" && x.dig("state", "status") == "error" && before_ids.include?(x["callID"]) }.map { |x| x["callID"] }
      nonzero_bash = parts.select do |x|
        code = x.dig("state", "metadata", "exit")
        x["tool"] == "bash" && code.is_a?(Integer) && code != 0 && before_ids.include?(x["callID"])
      end.map { |x| x["callID"] }
      obs = {
        "edit_failure_after_called" => failed_edits.empty? ? nil : failed_edits.any? { |id| after_ids.include?(id) },
        "bash_nonzero_after_called" => nonzero_bash.empty? ? nil : nonzero_bash.all? { |id| after_ids.include?(id) },
      }
      statuses = tool_parts(data, "tools-claude").map { |x| [x["tool"], x.dig("state", "status")] }
      item("M14", pred: { "edit_failure_after_called" => false, "bash_nonzero_after_called" => true }, obs: obs,
                  extra: { "part_statuses" => statuses })
    end

    # どの request にも canaries_seen[key] の真偽値があるときだけ (欠けた field を「読んでいない」と数えない)。
    def self.seen(data, run, key)
      reqs = mock(data, run)
      return nil if reqs.empty? || !reqs.all? { |m| m["canaries_seen"].is_a?(Hash) && [true, false].include?(m["canaries_seen"][key]) }

      reqs.any? { |m| m["canaries_seen"][key] }
    end

    def self.m15(data)
      compat = run_ok?(run_fact(data, "claude-compat"))
      disabled = run_ok?(run_fact(data, "claude-compat-disabled"))
      obs = {
        "rules_read" => compat ? seen(data, "claude-compat", "claude_rules") : nil,
        "skills_read" => compat ? seen(data, "claude-compat", "claude_skill") : nil,
        "rules_read_when_disabled" => disabled ? seen(data, "claude-compat-disabled", "claude_rules") : nil,
        "skills_read_when_disabled" => disabled ? seen(data, "claude-compat-disabled", "claude_skill") : nil,
      }
      pred = { "rules_read" => true, "skills_read" => true, "rules_read_when_disabled" => false, "skills_read_when_disabled" => false }
      item("M15", pred: pred, obs: obs, extra: { "disable_env" => "OPENCODE_DISABLE_CLAUDE_CODE=1" })
    end

    def self.m16(data)
      run = run_fact(data, "real")
      return item("M16", pred: { "nonce_reached_model" => true }, obs: { "nonce_reached_model" => nil }, reason: "real stage を実行していない") unless run

      nonce = data["facts"]["nonce"].to_s
      texts = data["events"].select { |e| e["run"] == "real" && e.dig("event", "type") == "text" }.map { |e| e.dig("event", "part", "text").to_s }
      after = hooks(data, "real", "tool.after")
      annotated = after.any? { |h| h["nonce_first"] }
      obs = { "nonce_reached_model" => run_ok?(run) && annotated && !texts.empty? && !nonce.empty? ? texts.any? { |t| t.include?(nonce) } : nil }
      extra = { "model" => run["model"], "exit" => run["exit"], "after_nonce_first" => after.map { |h| h["nonce_first"] } }
      item("M16", pred: { "nonce_reached_model" => true }, obs: obs, extra: extra)
    end

    def self.m18(data)
      run = run_fact(data, "snapshot")
      return item("M18", pred: nil, obs: { "hooks_fired" => nil }, reason: "snapshot の run が無い") unless run

      snap = data["git_hooks"].select { |h| h["run"] == "snapshot" }
      fired = snap.group_by { |h| h["hook"] }.map { |k, v| [k, v.length] }.to_h
      markers = snap.map { |h| h["markers"].to_s.split }.flatten.uniq.sort
      others = data["git_hooks"].reject { |h| h["run"] == "snapshot" }.map { |h| "#{h['run']}:#{h['hook']}" }.uniq.sort
      item("M18", pred: nil, obs: { "hooks_fired" => fired, "markers_in_hook_env" => markers, "hooks_in_other_runs" => others })
    end

    def self.m19(data)
      reqs = mock(data, "tools-claude")
      obs = { "system_has_provider_model" => reqs.empty? ? nil : reqs.any? { |m| m["system_has_provider_model"] },
              "system_has_model" => reqs.empty? ? nil : reqs.any? { |m| m["system_has_model"] } }
      item("M19", pred: nil, obs: obs)
    end

    def self.judge(data)
      errors = data["load_errors"] || {}
      unless errors.empty?
        reason = "記録の読込に失敗 (" + errors.map { |f, n| "#{f}: #{n} 行" }.join(", ") + ")"
        return ITEMS.keys.map { |id| manual(id, reason) }
      end

      [
        m1(data), m2(data), m3(data), m4(data), m5(data), m6(data), m7(data), m8(data), m9(data), m10(data),
        m11(data), m12(data), m13(data), m14(data), m15(data), m16(data),
        manual("M17", "manual: tui-plan の checklist を人が確かめる", "tui_records" => hooks(data, "tui", "shell.env").length),
        m18(data), m19(data),
        manual("M20", "manual: herdr の pane と Claude の session の中の terminal から起動した OpenCode で確かめる"),
      ]
    end

    # --- 出力 ---------------------------------------------------------------------------

    def self.redact(value, replacements)
      case value
      when String then replacements.reduce(value) { |s, (from, to)| from.to_s.empty? ? s : s.gsub(from, to) }
      when Array then value.map { |v| redact(v, replacements) }
      when Hash then value.map { |k, v| [redact(k, replacements), redact(v, replacements)] }.to_h
      else value
      end
    end

    def self.diff_text(item)
      pred = item["prediction"]
      obs = item["observed"]
      return JSON.generate(obs) if pred.nil?

      diffs = pred.keys.reject { |k| obs[k] == pred[k] }.map { |k| "#{k}: #{JSON.generate(pred[k])} → #{JSON.generate(obs[k])}" }
      diffs.empty? ? "予測どおり" : diffs.join("; ")
    end

    def self.markdown(meta, items)
      lines = ["# OpenCode plugin probe summary", ""]
      meta.each { |k, v| lines << "- #{k}: #{v.is_a?(String) ? v : JSON.generate(v)}" }
      lines += ["", "| M | 項目 | 使う先 | verdict | observed / 予測との差 |", "| --- | --- | --- | --- | --- |"]
      items.each do |i|
        note = i["reason"] ? " (#{i['reason']})" : ""
        lines << "| #{i['id']} | #{i['title']} | #{i['uses']} | #{i['verdict']}#{note} | #{diff_text(i).gsub('|', '\\|')} |"
      end
      lines.join("\n") + "\n"
    end

    def self.write(dir, meta, replacements)
      items = redact(judge(load(dir)), replacements)
      meta = redact(meta, replacements)
      File.write(File.join(dir, "summary.json"), JSON.pretty_generate("meta" => meta, "items" => items) + "\n")
      File.write(File.join(dir, "summary.md"), markdown(meta, items))
      items
    end
  end
end
