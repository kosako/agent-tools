# frozen_string_literal: true

# probe-opencode-plugin-test.sh の Ruby 側 (T3 / T4 / T5 / T8)。opencode も外部の network も使わない
# (T4 の mock は loopback だけ)。使い方: ruby probe-opencode-test.rb <t3|t4|t5|t8> <work dir>
# 失敗は "FAIL: ..." を stderr に出して exit 1。

require "json"
require "net/http"
require_relative "../../lib/probe_opencode/isolation"
require_relative "../../lib/probe_opencode/judge"
require_relative "../../lib/probe_opencode/mock_openai"
require_relative "../../lib/probe_opencode/process"

def fail!(msg)
  warn "FAIL: #{msg}"
  exit 1
end

def check(cond, msg)
  fail!(msg) unless cond
end

# T3: 生成する opencode.json の中身。
def t3(_dir)
  iso = ProbeOpencode::Isolation
  cfg = iso.opencode_config(shell: "/bin/sh", mock_url: "http://127.0.0.1:1234/v1")
  check(cfg["enabled_providers"] == ["probe"], "T3: enabled_providers must be only probe: #{cfg['enabled_providers'].inspect}")
  check(cfg["share"] == "disabled", "T3: share must be disabled")
  %w[autoupdate snapshot lsp formatter].each { |k| check(cfg[k] == false, "T3: #{k} must be false: #{cfg[k].inspect}") }
  check(cfg["shell"] == "/bin/sh", "T3: shell must be /bin/sh")
  probe = cfg.dig("provider", "probe") || {}
  check(probe.dig("options", "baseURL") == "http://127.0.0.1:1234/v1", "T3: provider baseURL must be the mock")
  check(probe["models"]&.keys&.sort == %w[claude-probe gpt-5-probe], "T3: models: #{probe['models']&.keys.inspect}")
  check(cfg["provider"].keys == ["probe"], "T3: only the probe provider")
  real = iso.opencode_config(shell: "/bin/sh", real_provider: "opencode-go")
  check(real["enabled_providers"] == ["opencode-go"], "T3: real enabled_providers")
  check(!real.key?("provider"), "T3: real must not define a provider (auth comes from --pass-env)")
  check(iso.opencode_config(shell: "/bin/sh", mock_url: "x", snapshot: true)["snapshot"] == true, "T3: snapshot stage")
  puts "ok T3"
end

def post(port, body, headers = {})
  req = Net::HTTP::Post.new("/v1/chat/completions")
  req["Content-Type"] = "application/json"
  headers.each { |k, v| req[k] = v }
  req.body = JSON.generate(body)
  Net::HTTP.start("127.0.0.1", port, read_timeout: 10) { |h| h.request(req) }
end

def sse_chunks(body)
  lines = body.split("\n\n").map { |b| b.sub(/\Adata: /, "") }
  check(lines.last == "[DONE]", "T4: SSE must end with [DONE]: #{body[-80..-1].inspect}")
  lines[0..-2].map { |l| JSON.parse(l) }
end

# T4: mock server。T7 用に header の canary も送る (記録に出ないことを sh 側で確かめる)。
def t4(dir)
  log = File.join(dir, "mock-requests.jsonl")
  canary = File.read(File.join(dir, "canary")).strip
  nonce = "PROBE-NONCE-test"
  mock = ProbeOpencode::MockOpenAI.new(log_path: log, nonce: nonce, real_home: "/nonexistent-home", canaries: { "c" => "CANARY-C" })
  port = mock.start
  check(port.is_a?(Integer) && port.positive?, "T4: port")
  tools = %w[bash edit write].map { |n| { "type" => "function", "function" => { "name" => n, "parameters" => {} } } }
  base = { "model" => "claude-probe", "stream" => true, "tools" => tools }

  res = post(port, base.merge("messages" => [{ "role" => "user", "content" => "PROBE-SCENARIO:tools go" }]),
             "Authorization" => "Bearer #{canary}", "X-Probe-Canary" => canary)
  check(res.code == "200" && res["Content-Type"] == "text/event-stream", "T4: SSE response: #{res.code} #{res['Content-Type']}")
  call = sse_chunks(res.body).flat_map { |c| c.dig("choices", 0, "delta", "tool_calls") || [] }.first
  check(call && call.dig("function", "name") == "bash", "T4: first step is a bash tool call: #{call.inspect}")
  args = JSON.parse(call.dig("function", "arguments"))
  check(args["command"].is_a?(String), "T4: tool_calls arguments must be parseable JSON")

  second = base.merge("messages" => [
                        { "role" => "user", "content" => [{ "type" => "text", "text" => "PROBE-SCENARIO:tools go" }] },
                        { "role" => "assistant", "content" => nil, "tool_calls" => [call] },
                        { "role" => "tool", "tool_call_id" => call["id"], "content" => "#{nonce}\nenv:OPENCODE\nPROBE-BASH-OK" },
                      ])
  call2 = sse_chunks(post(port, second).body).flat_map { |c| c.dig("choices", 0, "delta", "tool_calls") || [] }.first
  check(call2 && call2.dig("function", "name") == "write", "T4: step 2 is write: #{call2.inspect}")

  plain = post(port, { "model" => "claude-probe", "stream" => true, "messages" => [{ "role" => "user", "content" => "title please CANARY-C" }] })
  text = sse_chunks(plain.body).map { |c| c.dig("choices", 0, "delta", "content") }.compact.join
  check(text == ProbeOpencode::MockOpenAI::FALLBACK_TEXT, "T4: unmatched request gets the fallback text: #{text.inspect}")

  nonstream = post(port, { "model" => "claude-probe", "messages" => [{ "role" => "user", "content" => "hi" }] })
  check(JSON.parse(nonstream.body).dig("choices", 0, "message", "content") == "ok", "T4: non-stream JSON response")
  mock.stop

  recs = File.readlines(log).map { |l| JSON.parse(l) }
  check(recs.length == 4, "T4: 4 records: #{recs.length}")
  check(recs.none? { |r| r.keys.any? { |k| k.downcase.include?("header") } }, "T4: records must not have headers")
  check(recs[0]["scenario"] == "tools" && recs[0]["step"] == 0 && recs[0]["tools"] == %w[bash edit write], "T4: record 1: #{recs[0].inspect}")
  check(recs[1]["tool_messages"] == [{ "id" => call["id"], "nonce_first" => true, "ok_marker" => true }], "T4: tool message: #{recs[1]['tool_messages'].inspect}")
  check(recs[2]["canaries_seen"] == { "c" => true } && recs[0]["canaries_seen"] == { "c" => false }, "T4: canaries_seen")
  check(recs.none? { |r| r["home_path_seen"] }, "T4: home_path_seen false")
  puts "ok T4"
end

# T5: fixture の JSONL から出す verdict。data が欠けたら unknown で、pass に数えない。
def t5(dir)
  j = ProbeOpencode::Judge
  nonce = "PROBE-NONCE-x"
  write = lambda do |sub, facts, hooks, mock, events|
    d = File.join(dir, sub)
    Dir.mkdir(d)
    File.write(File.join(d, "facts.json"), JSON.generate(facts))
    { "hooks.jsonl" => hooks, "mock-requests.jsonl" => mock, "run-events.jsonl" => events }.each do |f, recs|
      File.write(File.join(d, f), recs.map { |r| JSON.generate(r) + "\n" }.join)
    end
    j.judge(j.load(d)).map { |i| [i["id"], i] }.to_h
  end
  after = { "run" => "tools-claude", "kind" => "tool.after", "tool" => "bash", "callID" => "c1" }
  msg = ->(first) { { "run" => "tools-claude", "tool_messages" => [{ "id" => "c1", "nonce_first" => first, "ok_marker" => true }] } }
  event = { "run" => "tools-claude", "event" => { "type" => "tool_use", "sessionID" => "s1",
                                                 "part" => { "tool" => "bash", "callID" => "c1", "state" => { "status" => "completed", "output" => "#{nonce}\nx" } } } }
  facts = { "nonce" => nonce }

  ok = write.call("confirmed", facts, [after], [msg.call(true)], [event])
  check(ok["M4"]["verdict"] == "confirmed", "T5: M4 confirmed: #{ok['M4'].inspect}")
  bad = write.call("differs", facts, [after], [msg.call(false)], [event])
  check(bad["M4"]["verdict"] == "differs", "T5: M4 differs: #{bad['M4'].inspect}")
  empty = write.call("empty", {}, [], [], [])
  check(empty["M4"]["verdict"] == "unknown" && empty["M4"]["reason"].to_s.include?("data"), "T5: M4 unknown when data is missing")
  counted = empty.values.count { |i| i["verdict"] == "confirmed" }
  check(counted.zero?, "T5: missing data must not count as confirmed: #{empty.values.select { |i| i['verdict'] == 'confirmed' }.map { |i| i['id'] }}")
  check(%w[M8 M11 M18 M19].all? { |id| %w[observed unknown].include?(empty[id]["verdict"]) }, "T5: items without a prediction are observed/unknown")
  check(j.verdict({ "a" => true }, { "a" => nil }) == "unknown", "T5: nil observation is unknown")
  check(j.verdict(nil, { "a" => 1 }) == "observed", "T5: no prediction is observed")
  check(empty.keys == (1..20).map { |n| "M#{n}" }, "T5: all of M1..M20 are present: #{empty.keys}")

  # 回帰 (#336 review F4〜F6): 経路に届かなかった / run が失敗した / idle に達しなかった data を
  # confirmed に数えない。
  ok_run = ->(label) { { "label" => label, "exit" => 0, "timed_out" => false, "events" => 5 } }
  bash_error = { "run" => "throw-shell-env", "event" => { "type" => "tool_use", "sessionID" => "s1",
                                                         "part" => { "tool" => "bash", "callID" => "c1", "state" => { "status" => "error" } } } }
  m6 = write.call("m6-unreached", { "runs" => [{ "label" => "serve-throw-shell-env", "shell" => { "session_status" => 500 },
                                                  "pty" => { "status" => nil, "file_written" => false } }] },
                  [{ "run" => "throw-shell-env", "kind" => "shell.env", "t" => 1, "callID" => "c1" }], [], [bash_error])["M6"]
  check(m6["verdict"] == "unknown" && m6["observed"]["model_bash_fails"] == true && m6["observed"]["bang_fails"].nil? && m6["observed"]["pty_fails"].nil?,
        "T5: M6 must not count unreached `!` / PTY as failed: #{m6.inspect}")
  inits = %w[probe-global-b probe-global-a probe-project].each_with_index.map { |l, i| { "run" => "tools-claude", "kind" => "init", "label" => l, "t" => i } }
  throw_inits = %w[probe-global-a probe-project].map { |l| { "run" => "throw-init", "kind" => "init", "label" => l, "t" => 9 } }
  m2 = write.call("m2-pure-failed", { "runs" => [{ "label" => "pure", "exit" => 1, "timed_out" => false, "events" => 0 }, ok_run.call("throw-init")] },
                  inits + throw_inits, [], [])["M2"]
  check(m2["verdict"] == "unknown" && m2["observed"]["pure_inits"].nil?, "T5: M2 must not count a failed --pure run as 0 inits: #{m2.inspect}")
  m10 = write.call("m10-no-idle", { "runs" => [ok_run.call("tools-claude"), { "label" => "serve-plugin", "prompt" => { "session_id" => "p1", "status" => 200 } }] },
                   [{ "run" => "serve-plugin", "kind" => "event", "type" => "session.idle", "sessionID" => "p1" },
                    { "run" => "serve-plugin", "kind" => "idle.delayed", "sessionID" => "p1" }],
                   [], [{ "run" => "tools-claude", "event" => { "type" => "step_start", "sessionID" => "s1" } }])["M10"]
  check(m10["verdict"] == "unknown" && m10["observed"]["run_delayed_recorded"].nil?, "T5: M10 needs the run session to reach idle: #{m10.inspect}")
  # PTY の記録は起動の時間帯で選ぶ (sessionID の有無で選ぶと、PTY に sessionID が付いた場合を検出できない)。
  pty = write.call("pty-window", { "runs" => [{ "label" => "serve-plugin", "pty" => { "t_start" => 100, "t_end" => 200 } }] },
                   [{ "run" => "serve-plugin", "kind" => "shell.env", "t" => 150, "has_sessionID" => true, "has_callID" => false },
                    { "run" => "serve-plugin", "kind" => "shell.env", "t" => 5000, "has_sessionID" => false, "has_callID" => false }], [], [])["M5"]
  check(pty["observed"]["pty.sessionID"] == true, "T5: a PTY record with a sessionID must be detected: #{pty['observed'].select { |k, _| k.start_with?('pty.s') }}")
  # 時間帯の外 (直前の `!` / 直後の prompt) の記録は、sessionID を持っていても PTY に数えない。
  near = write.call("pty-neighbors", { "runs" => [{ "label" => "serve-plugin", "pty" => { "t_start" => 1000, "t_end" => 1800 } }] },
                    [{ "run" => "serve-plugin", "kind" => "shell.env", "t" => 980, "has_sessionID" => true, "has_callID" => true },
                     { "run" => "serve-plugin", "kind" => "shell.env", "t" => 1002, "has_sessionID" => false, "has_callID" => false },
                     { "run" => "serve-plugin", "kind" => "shell.env", "t" => 1900, "has_sessionID" => true, "has_callID" => true }], [], [])["M5"]
  check(near["observed"]["pty.sessionID"] == false && near["observed"]["pty.callID"] == false,
        "T5: records outside the PTY window must not count: #{near['observed'].select { |k, _| k.start_with?('pty.') }}")

  # 回帰 (#336 review round 2): 前提の操作が成り立った証跡が無ければ confirmed / 予測どおりに数えない。
  unknown = lambda do |name, id, key, facts, hooks, mock, events|
    it = write.call(name, facts, hooks, mock, events)[id]
    check(it["observed"][key].nil?, "T5 #{name}: #{id}.#{key} must be unknown without evidence: #{it['observed'][key].inspect}")
  end
  # F8: throw させた plugin (global-b) の init の記録が無い
  unknown.call("f8", "M2", "throw_init_continues", { "runs" => [ok_run.call("throw-init")] },
               %w[probe-global-a probe-project].map { |l| { "run" => "throw-init", "kind" => "init", "label" => l, "t" => 1 } }, [], [])
  # F9: bash は error だが before の記録が無い / 遅いが after の記録が無い
  err_part = ->(run, status, ms) { { "run" => run, "event" => { "type" => "tool_use", "sessionID" => "s1", "part" => { "tool" => "bash", "callID" => "c1", "state" => { "status" => status, "time" => { "start" => 0, "end" => ms } } } } } }
  unknown.call("f9-before", "M7", "throw_before.part_status", { "runs" => [ok_run.call("throw-before").merge("executed_marker" => false)] }, [], [], [err_part.call("throw-before", "error", 5)])
  unknown.call("f9-slow", "M7", "slow_after.waited", { "runs" => [ok_run.call("slow-after").merge("executed_marker" => true)] }, [], [], [err_part.call("slow-after", "completed", 4000)])
  # F10: permission は ask だけで返答が無い / abort の前にその session で実行が始まっていない
  unknown.call("f10-ask", "M9", "idle_after_permission_reject", { "runs" => [ok_run.call("ask")] },
               [{ "run" => "ask", "kind" => "event", "type" => "permission.asked", "sessionID" => "s1" }], [], [])
  unknown.call("f10-abort", "M9", "idle_after_abort", { "runs" => [{ "label" => "serve-plugin", "abort" => { "session_id" => "a1", "prompt_async_status" => 500, "abort_status" => 200 } }] },
               [{ "run" => "serve-plugin", "kind" => "event", "type" => "session.idle", "sessionID" => "a1" }], [], [])
  # F11: chat.params と shell.env の sessionID が両方とも欠けている
  unknown.call("f11", "M12", "joinable_by_sessionID", {},
               [{ "run" => "tools-claude", "kind" => "chat.params", "sessionID" => nil, "providerID" => "probe", "modelID" => "claude-probe", "apiID" => "claude-probe" },
                { "run" => "tools-claude", "kind" => "shell.env", "sessionID" => nil }], [], [])
  # F12: hook の件数は予測どおりだが、失敗の証跡 (part の error / 非 0 終了) が無い
  counts = [%w[tool.before edit c1], %w[tool.before edit c2], %w[tool.after edit c1], %w[tool.before bash c3], %w[tool.before bash c4], %w[tool.after bash c3], %w[tool.after bash c4]]
  # part は edit も bash も成功 (失敗の証跡が無い)。hook の件数だけでは判定しない。
  ok_parts = [%w[edit c1], %w[edit c2], %w[bash c3], %w[bash c4]].map do |t, c|
    { "run" => "tools-claude", "event" => { "type" => "tool_use", "sessionID" => "s1", "part" => { "tool" => t, "callID" => c, "state" => { "status" => "completed", "metadata" => { "exit" => 0 } } } } }
  end
  f12 = write.call("f12", {}, counts.map { |k, t, c| { "run" => "tools-claude", "kind" => k, "tool" => t, "callID" => c } }, [], ok_parts)["M14"]
  check(f12["observed"]["edit_failure_after_called"].nil? && f12["observed"]["bash_nonzero_after_called"].nil?,
        "T5 f12: M14 needs failure evidence (edit error / non-zero exit): #{f12["observed"].slice("edit_failure_after_called", "bash_nonzero_after_called")}")
  # F13: `!` の時間帯の中の記録に sessionID が無ければ、そのとおり false として検出する (値で選ばない)
  bang = write.call("f13", { "runs" => [{ "label" => "serve-plugin", "shell" => { "session_id" => "b1", "status" => 200, "t_start" => 100, "t_end" => 200 } }] },
                    [{ "run" => "serve-plugin", "kind" => "shell.env", "t" => 150, "has_sessionID" => false, "sessionID" => nil, "has_callID" => true }], [], [])["M5"]
  check(bang["observed"]["bang.sessionID"] == false, "T5 f13: a `!` record without a sessionID must be detected: #{bang['observed']['bang.sessionID'].inspect}")
  # M10: idle はあるが run が失敗している
  unknown.call("m10-run-failed", "M10", "run_delayed_recorded", { "runs" => [{ "label" => "tools-claude", "exit" => 1, "timed_out" => false, "events" => 5 }] },
               [{ "run" => "tools-claude", "kind" => "event", "type" => "session.idle", "sessionID" => "s1" }], [],
               [{ "run" => "tools-claude", "event" => { "type" => "step_start", "sessionID" => "s1" } }])
  # M1: 実物の config dir / DB が 1 つも無い (比べる対象が無い)
  unknown.call("m1-vacuous", "M1", "real_state_unchanged", { "real_mtime" => { "before" => { "a" => nil }, "after" => { "a" => nil } } }, [], [], [])

  # 回帰 (#336 review round 3)
  ev = ->(run, type, extra = {}) { { "run" => run, "kind" => "event", "type" => type }.merge(extra) }
  # F10 permission: 返答が reject でない / requestID が ask と合わない
  asked = ev.call("ask", "permission.asked", "requestID" => "r1", "sessionID" => "s1")
  idle_ask = ev.call("ask", "session.idle", "sessionID" => "s1")
  unknown.call("f10-once", "M9", "idle_after_permission_reject", { "runs" => [ok_run.call("ask")] },
               [asked, ev.call("ask", "permission.replied", "requestID" => "r1", "reply" => "once"), idle_ask], [], [])
  unknown.call("f10-other-request", "M9", "idle_after_permission_reject", { "runs" => [ok_run.call("ask")] },
               [asked, ev.call("ask", "permission.replied", "requestID" => "r2", "reply" => "reject"), idle_ask], [], [])
  # F10 abort: 条件を 1 つずつ外す (対照は成り立つ)
  abort_fact = ->(prompt) { { "runs" => [{ "label" => "serve-plugin", "abort" => { "session_id" => "a1", "prompt_async_status" => prompt, "abort_status" => 200, "t_abort" => 1000 } }] } }
  before_at = ->(t) { { "run" => "serve-plugin", "kind" => "tool.before", "tool" => "bash", "sessionID" => "a1", "callID" => "c9", "t" => t } }
  idle_at = ->(t) { ev.call("serve-plugin", "session.idle", "sessionID" => "a1", "t" => t) }
  control = write.call("f10-abort-control", abort_fact.call(204), [before_at.call(900), idle_at.call(1200)], [], [])["M9"]
  check(control["observed"]["idle_after_abort"] == true, "T5 f10-abort-control: #{control['observed']['idle_after_abort'].inspect}")
  unknown.call("f10-abort-late-before", "M9", "idle_after_abort", abort_fact.call(204), [before_at.call(1100), idle_at.call(1200)], [], [])
  unknown.call("f10-abort-done-before", "M9", "idle_after_abort", abort_fact.call(204), [before_at.call(900), idle_at.call(950), idle_at.call(1200)], [], [])
  unknown.call("f10-abort-prompt-failed", "M9", "idle_after_abort", abort_fact.call(500), [before_at.call(900), idle_at.call(1200)], [], [])
  # F15: 欠けた callID 同士を結合しない
  nil_part = { "run" => "throw-before", "event" => { "type" => "tool_use", "sessionID" => "s1", "part" => { "tool" => "bash", "callID" => nil, "state" => { "status" => "error" } } } }
  unknown.call("f15-m7", "M7", "throw_before.part_status", { "runs" => [ok_run.call("throw-before").merge("executed_marker" => false)] },
               [{ "run" => "throw-before", "kind" => "tool.before", "tool" => "bash", "callID" => nil }], [], [nil_part])
  other_call = { "run" => "throw-shell-env", "event" => { "type" => "tool_use", "sessionID" => "s1", "part" => { "tool" => "bash", "callID" => "c1", "state" => { "status" => "error" } } } }
  unknown.call("f15-m6", "M6", "model_bash_fails", {}, [{ "run" => "throw-shell-env", "kind" => "shell.env", "t" => 1, "callID" => "c2" }], [], [other_call])
  # F16: after は a / b、次の request の tool message は a だけ
  m4_part = ->(id) { { "run" => "tools-claude", "event" => { "type" => "tool_use", "sessionID" => "s1", "part" => { "tool" => "bash", "callID" => id, "state" => { "status" => "completed", "output" => "#{nonce}\nx" } } } } }
  unknown.call("f16", "M4", "next_request_has_nonce", facts,
               %w[a b].map { |id| { "run" => "tools-claude", "kind" => "tool.after", "tool" => "bash", "callID" => id } },
               [{ "run" => "tools-claude", "tool_messages" => [{ "id" => "a", "nonce_first" => true, "ok_marker" => true }] }], [m4_part.call("a"), m4_part.call("b")])
  # F17: group への kill が失敗 / kill の前に子が終わっていた
  spawn_rec = ->(extra) { { "run" => "spawn", "kind" => "spawn", "child_exited" => true, "grandchild_alive" => false, "group_kill_error" => nil,
                           "child_alive_before_kill" => true, "grandchild_alive_before_kill" => true }.merge(extra) }
  unknown.call("f17-kill-error", "M13", "child_killed", {}, [spawn_rec.call("group_kill_error" => "ESRCH")], [], [])
  unknown.call("f17-already-exited", "M13", "grandchild_killed", {}, [spawn_rec.call("child_alive_before_kill" => false)], [], [])
  # F18: debug paths が異常終了した
  unknown.call("f18", "M1", "paths_under_tmp", { "isolation" => { "paths_all_under_tmp" => true, "exits" => { "paths" => 1, "config" => 0, "models" => 0 } } }, [], [], [])
  # F19: 壊れた行があれば全項目を unknown / 判定に使う field の欠落
  broken = File.join(dir, "f19-broken")
  Dir.mkdir(broken)
  File.write(File.join(broken, "hooks.jsonl"), "{\"run\":\"tools-claude\",\"kind\":\"init\"}\nnot json\n")
  all = j.judge(j.load(broken))
  check(all.all? { |i| i["verdict"] == "unknown" && i["reason"].to_s.include?("hooks.jsonl") }, "T5 f19: a broken line must make every item unknown: #{all.map { |i| i['verdict'] }.uniq}")
  unknown.call("f19-home-field", "M1", "home_path_not_sent", {}, [], [{ "run" => "tools-claude", "method" => "POST" }], [])
  unknown.call("f19-canary-field", "M15", "rules_read", { "runs" => [ok_run.call("claude-compat")] }, [], [{ "run" => "claude-compat", "canaries_seen" => {} }], [])
  unknown.call("f19-delayed-field", "M10", "run_delayed_recorded", { "runs" => [ok_run.call("tools-claude")] },
               [ev.call("tools-claude", "session.idle", "sessionID" => "s1"), { "run" => "tools-claude", "kind" => "idle.delayed" }], [],
               [{ "run" => "tools-claude", "event" => { "type" => "step_start", "sessionID" => "s1" } }])
  # F20: project の init だけ
  unknown.call("f20", "M2", "global_before_project", {}, [{ "run" => "tools-claude", "kind" => "init", "label" => "probe-project", "t" => 1 }], [], [])
  # F21: `!` が最後まで走った印が無い (names は空でも「立っていない」と数えない)
  f21 = write.call("f21", { "runs" => [{ "label" => "serve-plugin", "shell" => { "status" => 200, "ok_marker" => false, "names" => { "env" => [] } } }] }, [], [], [])["M5"]
  check(f21["observed"]["bang.plugin.env.OPENCODE_SESSION_ID"].nil?, "T5 f21: `!` names without the OK marker must be unknown: #{f21['observed']['bang.plugin.env.OPENCODE_SESSION_ID'].inspect}")
  # F23: M15 / M16 の前提、M7 の hook_ms、M9 の子の作成
  unknown.call("f23-m15-run-failed", "M15", "rules_read", { "runs" => [{ "label" => "claude-compat", "exit" => 1, "timed_out" => false, "events" => 0 }] }, [],
               [{ "run" => "claude-compat", "canaries_seen" => { "claude_rules" => true, "claude_skill" => true } }], [])
  real_text = { "run" => "real", "event" => { "type" => "text", "sessionID" => "s1", "part" => { "text" => "#{nonce} echoed" } } }
  unknown.call("f23-m16-not-annotated", "M16", "nonce_reached_model", facts.merge("runs" => [ok_run.call("real")]),
               [{ "run" => "real", "kind" => "tool.after", "nonce_first" => false }], [], [real_text])
  unknown.call("f23-m16-run-failed", "M16", "nonce_reached_model", facts.merge("runs" => [{ "label" => "real", "exit" => 1, "timed_out" => false, "events" => 1 }]),
               [{ "run" => "real", "kind" => "tool.after", "nonce_first" => true }], [], [real_text])
  slow_part = { "run" => "slow-after", "event" => { "type" => "tool_use", "sessionID" => "s1", "part" => { "tool" => "bash", "callID" => "c1", "state" => { "status" => "completed", "time" => { "start" => 0, "end" => 4000 } } } } }
  unknown.call("f23-m7-hook-ms", "M7", "slow_after.waited", { "runs" => [ok_run.call("slow-after").merge("executed_marker" => true)] },
               [{ "run" => "slow-after", "kind" => "tool.after", "tool" => "bash", "callID" => "c1" }], [], [slow_part])
  unknown.call("f23-m9-child", "M9", "child_idle_delivered", { "runs" => [ok_run.call("task")] },
               [ev.call("task", "session.idle", "sessionID" => "child1")], [], [{ "run" => "task", "event" => { "type" => "step_start", "sessionID" => "main1" } }])
  puts "ok T5"
end

# T8: 子 process の後始末 (#336 review F2 / F3)。
# kill(0) は zombie にも成功するので、ps の状態 (Z でない) と command (PID の再利用でない) も見る。
def pid_alive?(pid, command)
  out = IO.popen(["ps", "-o", "stat=,command=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
  !out.empty? && !out.start_with?("Z") && out.include?(command)
end

def wait_file(path, seconds)
  deadline = Time.now + seconds
  sleep 0.1 until File.file?(path) && !File.read(path).strip.empty? || Time.now > deadline
  File.file?(path) ? File.read(path).strip.to_i : nil
end

def wait_dead(pid, command, seconds)
  deadline = Time.now + seconds
  sleep 0.1 while pid_alive?(pid, command) && Time.now < deadline
  !pid_alive?(pid, command)
end

def t8(dir)
  env = { "PATH" => ENV.fetch("PATH") }
  # serve の親は TERM で終わるが、孫は TERM を無視する。stop は親の終了後も group に KILL を送る。
  pidfile = File.join(dir, "t8-grandchild.pid")
  script = %(sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 60' sh "$0" & echo "listening on http://127.0.0.1:1"; wait)
  srv = ProbeOpencode::Child::Serve.new(["sh", "-c", script, pidfile], env: env, chdir: dir, timeout: 10)
  check(srv.start == 1, "T8: serve stand-in did not print the listen URL")
  grandchild = wait_file(pidfile, 5)
  check(grandchild && pid_alive?(grandchild, "sleep"), "T8: grandchild did not start")
  srv.stop
  check(wait_dead(grandchild, "sleep", 3), "T8: a TERM-ignoring grandchild survived Serve#stop")

  # Serve#stop が TERM の猶予の途中で中断されても、KILL を飛ばさない (親自身が TERM を無視する)。
  # 親は TERM を受けたら file に書くだけで終わらない (TERM の猶予の待ちに入ったことを file で同期する)。
  pidfile3 = File.join(dir, "t8-serve-parent.pid")
  termfile = File.join(dir, "t8-serve-parent.term")
  script3 = %(trap 'echo term > "$1"' TERM; echo $$ > "$0"; echo "listening on http://127.0.0.1:1"; while :; do sleep 0.1; done)
  srv3 = ProbeOpencode::Child::Serve.new(["sh", "-c", script3, pidfile3, termfile], env: env, chdir: dir, timeout: 10)
  check(srv3.start == 1, "T8: serve stand-in 2 did not print the listen URL")
  parent = wait_file(pidfile3, 5)
  check(parent && pid_alive?(parent, "sh"), "T8: serve stand-in 2 did not start")
  stopper = Thread.new do
    srv3.stop
    :completed
  rescue Interrupt
    :interrupted
  end
  stopper.report_on_exception = false
  deadline = Time.now + 5
  sleep 0.05 until File.file?(termfile) || Time.now > deadline
  check(File.file?(termfile), "T8: Serve#stop did not send TERM")
  stopper.raise(Interrupt)
  check(!stopper.join(10).nil?, "T8: interrupted Serve#stop did not return within 10s")
  check(stopper.value == :interrupted, "T8: the interrupt must land in the TERM grace: #{stopper.value.inspect}")
  check(wait_dead(parent, "sh", 3), "T8: an interrupted Serve#stop left the TERM-ignoring parent alive")

  # 中断 (Ctrl-C 相当) された Child.run は、子の group を止めてすぐ戻る (Open3 の終了待ちで止まらない)。
  pidfile2 = File.join(dir, "t8-child.pid")
  runner = Thread.new do
    ProbeOpencode::Child.run(["sh", "-c", %(echo $$ > "$0"; exec sleep 60), pidfile2], env: env, chdir: dir, timeout: 30)
  rescue Interrupt
    :interrupted
  end
  runner.report_on_exception = false
  child = wait_file(pidfile2, 5)
  check(child && pid_alive?(child, "sleep"), "T8: child did not start")
  started = Time.now
  runner.raise(Interrupt)
  check(!runner.join(10).nil?, "T8: interrupted Child.run did not return within 10s")
  check(runner.value == :interrupted && Time.now - started < 10, "T8: Child.run must re-raise the interrupt")
  check(wait_dead(child, "sleep", 3), "T8: the child group survived an interrupted Child.run")
  puts "ok T8"
end

cmd, dir = ARGV
case cmd
when "t3" then t3(dir)
when "t4" then t4(dir)
when "t5" then t5(dir)
when "t8" then t8(dir)
else fail!("usage: probe-opencode-test.rb <t3|t4|t5|t8> <dir>")
end
