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

    def self.read_jsonl(path)
      return [] unless File.file?(path)

      File.readlines(path).map do |l|
        JSON.parse(l)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def self.load(dir)
      facts_path = File.join(dir, "facts.json")
      {
        "facts" => File.file?(facts_path) ? JSON.parse(File.read(facts_path)) : {},
        "hooks" => read_jsonl(File.join(dir, "hooks.jsonl")),
        "mock" => read_jsonl(File.join(dir, "mock-requests.jsonl")),
        "events" => read_jsonl(File.join(dir, "run-events.jsonl")),
        "git_hooks" => read_jsonl(File.join(dir, "git-hooks.jsonl")),
      }
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
      obs = {
        "paths_under_tmp" => iso && iso["paths_all_under_tmp"],
        "only_probe_provider" => iso && iso["config_providers"] && iso["config_providers"] == ["probe"] && iso["models_providers"] == ["probe"],
        "real_state_unchanged" => mtime["before"] && mtime["after"] ? mtime["before"] == mtime["after"] : nil,
        "home_path_not_sent" => mocks.empty? ? nil : mocks.none? { |m| m["home_path_seen"] },
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
        "global_before_project" => order.include?("probe-project") ? order.index("probe-project") == order.length - 1 : nil,
        "marker_file_inits" => inits.empty? ? nil : inits.count { |h| h["label"] == "probe-global-a" },
        "each_file_once" => inits.empty? ? nil : order.uniq.length == order.length && order.length == 3,
        "pure_inits" => pure ? hooks(data, "pure", "init").length : nil,
        "throw_init_continues" => throw_run ? (throw_run["exit"] == 0 && throw_inits.include?("probe-global-a") && throw_inits.include?("probe-project")) : nil,
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

    def self.m4(data)
      after_ids = hooks(data, "tools-claude", "tool.after").map { |h| h["callID"] }
      msgs = mock(data, "tools-claude").flat_map { |m| m["tool_messages"] || [] }.uniq { |t| t["id"] }
      matched = msgs.select { |t| after_ids.include?(t["id"]) }
      nonce = data["facts"]["nonce"].to_s
      parts = tool_parts(data, "tools-claude").select { |p| p.dig("state", "status") == "completed" }
      obs = {
        "next_request_has_nonce" => matched.empty? ? nil : matched.all? { |t| t["nonce_first"] },
        "run_event_output_has_nonce" => parts.empty? || nonce.empty? ? nil : parts.all? { |p| p.dig("state", "output").to_s.start_with?(nonce) },
      }
      extra = { "callid_equals_provider_tool_call_id" => msgs.empty? || after_ids.empty? ? nil : !matched.empty? }
      item("M4", pred: obs.keys.map { |k| [k, true] }.to_h, obs: obs, extra: extra)
    end

    def self.shell_env_inputs(data)
      claude_before = hooks(data, "tools-claude", "tool.before").map { |h| h["callID"] }
      model = hooks(data, "tools-claude", "shell.env")
      serve = run_fact(data, "serve-plugin") || {}
      bang_sid = serve.dig("shell", "session_id")
      serve_env = hooks(data, "serve-plugin", "shell.env")
      serve_before = hooks(data, "serve-plugin", "tool.before").map { |h| h["callID"] }
      bang = serve_env.select { |h| bang_sid && h["sessionID"] == bang_sid }
      pty = serve_env.reject { |h| h["has_sessionID"] }
      {
        "model_bash.sessionID" => model.empty? ? nil : model.all? { |h| h["has_sessionID"] },
        "model_bash.callID" => model.empty? ? nil : model.all? { |h| h["has_callID"] },
        "model_bash.callID_matches_before" => model.empty? ? nil : model.all? { |h| claude_before.include?(h["callID"]) },
        "bang.sessionID" => bang.empty? ? nil : true,
        "bang.callID" => bang.empty? ? nil : bang.all? { |h| h["has_callID"] },
        "bang.callID_matches_before" => bang.empty? ? nil : bang.any? { |h| serve_before.include?(h["callID"]) },
        "pty.sessionID" => pty.empty? ? nil : pty.any? { |h| h["has_sessionID"] },
        "pty.callID" => pty.empty? ? nil : pty.any? { |h| h["has_callID"] },
      }
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
      obs.merge!(flatten("bang.plugin.env", presence(serve.dig("shell", "names", "env"), keys)))
      obs.merge!(flatten("bang.pure.env", presence(serve_pure.dig("shell", "names", "env"), keys)))
      obs.merge!(flatten("pty.plugin.env", presence(serve.dig("pty", "names", "env"), keys)))
      obs.merge!(flatten("pty.pure.env", presence(serve_pure.dig("pty", "names", "env"), keys)))
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

    def self.m6(data)
      part = tool_parts(data, "throw-shell-env", "bash").first
      serve = run_fact(data, "serve-throw-shell-env")
      obs = {
        "model_bash_fails" => part ? part.dig("state", "status") == "error" : nil,
        "bang_fails" => serve && serve["shell"] ? (serve.dig("shell", "status") != 200 || serve.dig("shell", "part_status") == "error") : nil,
        "pty_fails" => serve && serve["pty"] ? (serve.dig("pty", "status") != 200 || !serve.dig("pty", "file_written")) : nil,
      }
      extra = { "model_bash_executed" => (run_fact(data, "throw-shell-env") || {})["executed_marker"] }
      item("M6", pred: obs.keys.map { |k| [k, true] }.to_h, obs: obs, extra: extra)
    end

    def self.m7_run(data, run)
      fact = run_fact(data, run)
      part = tool_parts(data, run, "bash").first
      msgs = mock(data, run).flat_map { |m| m["tool_messages"] || [] }
      time = part && part.dig("state", "time")
      {
        "executed" => fact && fact["executed_marker"],
        "part_status" => part && part.dig("state", "status"),
        "model_got_ok_marker" => msgs.empty? ? nil : msgs.any? { |t| t["ok_marker"] },
        "part_ms" => time && time["start"] && time["end"] ? time["end"] - time["start"] : nil,
      }
    end

    def self.m7(data)
      before = m7_run(data, "throw-before")
      after = m7_run(data, "throw-after")
      slow = m7_run(data, "slow-after")
      obs = {
        "throw_before.executed" => before["executed"], "throw_before.part_status" => before["part_status"],
        "throw_after.executed" => after["executed"], "throw_after.part_status" => after["part_status"],
        "slow_after.executed" => slow["executed"], "slow_after.part_status" => slow["part_status"],
        "slow_after.waited" => slow["part_ms"] ? slow["part_ms"] >= 3000 : nil,
      }
      pred = { "throw_before.executed" => false, "throw_before.part_status" => "error",
               "throw_after.executed" => true, "throw_after.part_status" => "error",
               "slow_after.executed" => true, "slow_after.part_status" => "completed", "slow_after.waited" => true }
      extra = { "throw_before.model_got_ok_marker" => before["model_got_ok_marker"],
                "throw_after.model_got_ok_marker" => after["model_got_ok_marker"],
                "slow_after.part_ms" => slow["part_ms"] }
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
      task_main = main_session(data, "task")
      task_idle = idle_for(data, "task")
      sessions = hooks(data, "task", "idle.session")
      obs = {
        "idle_per_turn" => main ? idle_for(data, "tools-claude", main).length : nil,
        "idle_after_bang" => bang_sid ? !idle_for(data, "serve-plugin", bang_sid).empty? : nil,
        "idle_after_abort" => abort_sid ? !idle_for(data, "serve-plugin", abort_sid).empty? : nil,
        "idle_after_permission_reject" => run_fact(data, "ask") ? !idle_for(data, "ask").empty? : nil,
        "child_idle_delivered" => task_main ? task_idle.any? { |h| h["sessionID"] != task_main } : nil,
        "child_parent_readable" => sessions.empty? ? nil : sessions.any? { |h| h["has_parentID"] },
      }
      pred = obs.keys.map { |k| [k, true] }.to_h.merge("idle_per_turn" => 1)
      extra = { "permission_asked_events" => hooks(data, "ask", "event").count { |h| h["type"] == "permission.asked" } }
      item("M9", pred: pred, obs: obs, extra: extra)
    end

    def self.m10(data)
      main = main_session(data, "tools-claude")
      serve = run_fact(data, "serve-plugin") || {}
      prompt_sid = serve.dig("prompt", "session_id")
      obs = {
        "run_delayed_recorded" => main ? hooks(data, "tools-claude", "idle.delayed").any? { |h| h["sessionID"] == main } : nil,
        "serve_delayed_recorded" => prompt_sid ? hooks(data, "serve-plugin", "idle.delayed").any? { |h| h["sessionID"] == prompt_sid } : nil,
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
      env_sids = hooks(data, "tools-claude", "shell.env").map { |h| h["sessionID"] }
      p = params.first
      obs = {
        "providerID" => p && p["providerID"], "modelID" => p && p["modelID"], "apiID" => p && p["apiID"],
        "joinable_by_sessionID" => params.empty? || env_sids.empty? ? nil : params.any? { |h| env_sids.include?(h["sessionID"]) },
      }
      pred = { "providerID" => "probe", "modelID" => "claude-probe", "apiID" => "claude-probe", "joinable_by_sessionID" => true }
      real = hooks(data, "real", "chat.params").first
      extra = { "chat_message" => hooks(data, "tools-claude", "chat.message").first&.slice("providerID", "modelID"),
                "real_chat_params" => real&.slice("providerID", "modelID", "apiID") }
      item("M12", pred: pred, obs: obs, extra: extra)
    end

    def self.m13(data)
      s = hooks(data, "spawn", "spawn").first
      obs = { "child_killed" => s && s["child_exited"], "grandchild_killed" => s && (s["grandchild_alive"].nil? ? nil : !s["grandchild_alive"]) }
      item("M13", pred: { "child_killed" => true, "grandchild_killed" => true }, obs: obs,
                  extra: s ? s.slice("spawn_ms", "spawn_exit", "group_kill_error", "grandchild_pid_read") : {})
    end

    def self.m14(data)
      before = hooks(data, "tools-claude", "tool.before")
      after = hooks(data, "tools-claude", "tool.after")
      count = ->(list, tool) { list.count { |h| h["tool"] == tool } }
      edits_b = count.call(before, "edit")
      bash_b = count.call(before, "bash")
      obs = {
        "edit_failure_after_called" => edits_b == 2 ? count.call(after, "edit") == 2 : nil,
        "bash_nonzero_after_called" => bash_b == 2 ? count.call(after, "bash") == 2 : nil,
      }
      statuses = tool_parts(data, "tools-claude").map { |x| [x["tool"], x.dig("state", "status")] }
      item("M14", pred: { "edit_failure_after_called" => false, "bash_nonzero_after_called" => true }, obs: obs,
                  extra: { "part_statuses" => statuses })
    end

    def self.seen(data, run, key)
      reqs = mock(data, run)
      reqs.empty? ? nil : reqs.any? { |m| (m["canaries_seen"] || {})[key] }
    end

    def self.m15(data)
      obs = {
        "rules_read" => seen(data, "claude-compat", "claude_rules"),
        "skills_read" => seen(data, "claude-compat", "claude_skill"),
        "rules_read_when_disabled" => seen(data, "claude-compat-disabled", "claude_rules"),
        "skills_read_when_disabled" => seen(data, "claude-compat-disabled", "claude_skill"),
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
      obs = { "nonce_reached_model" => texts.empty? || nonce.empty? ? nil : texts.any? { |t| t.include?(nonce) } }
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
