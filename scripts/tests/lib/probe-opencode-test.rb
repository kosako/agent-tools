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
                                                 "part" => { "tool" => "bash", "state" => { "status" => "completed", "output" => "#{nonce}\nx" } } } }
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
                                                         "part" => { "tool" => "bash", "state" => { "status" => "error" } } } }
  m6 = write.call("m6-unreached", { "runs" => [{ "label" => "serve-throw-shell-env", "shell" => { "session_status" => 500 },
                                                  "pty" => { "status" => nil, "file_written" => false } }] },
                  [{ "run" => "throw-shell-env", "kind" => "shell.env", "t" => 1 }], [], [bash_error])["M6"]
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
  puts "ok T5"
end

# T8: 子 process の後始末 (#336 review F2 / F3)。
def pid_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

def wait_file(path, seconds)
  deadline = Time.now + seconds
  sleep 0.1 until File.file?(path) && !File.read(path).strip.empty? || Time.now > deadline
  File.file?(path) ? File.read(path).strip.to_i : nil
end

def wait_dead(pid, seconds)
  deadline = Time.now + seconds
  sleep 0.1 while pid_alive?(pid) && Time.now < deadline
  !pid_alive?(pid)
end

def t8(dir)
  env = { "PATH" => ENV.fetch("PATH") }
  # serve の親は TERM で終わるが、孫は TERM を無視する。stop は親の終了後も group に KILL を送る。
  pidfile = File.join(dir, "t8-grandchild.pid")
  script = %(sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 60' sh "$0" & echo "listening on http://127.0.0.1:1"; wait)
  srv = ProbeOpencode::Child::Serve.new(["sh", "-c", script, pidfile], env: env, chdir: dir, timeout: 10)
  check(srv.start == 1, "T8: serve stand-in did not print the listen URL")
  grandchild = wait_file(pidfile, 5)
  check(grandchild && pid_alive?(grandchild), "T8: grandchild did not start")
  srv.stop
  check(wait_dead(grandchild, 3), "T8: a TERM-ignoring grandchild survived Serve#stop")

  # 中断 (Ctrl-C 相当) された Child.run は、子の group を止めてすぐ戻る (Open3 の終了待ちで止まらない)。
  pidfile2 = File.join(dir, "t8-child.pid")
  runner = Thread.new do
    ProbeOpencode::Child.run(["sh", "-c", %(echo $$ > "$0"; exec sleep 60), pidfile2], env: env, chdir: dir, timeout: 30)
  rescue Interrupt
    :interrupted
  end
  runner.report_on_exception = false
  child = wait_file(pidfile2, 5)
  check(child && pid_alive?(child), "T8: child did not start")
  started = Time.now
  runner.raise(Interrupt)
  check(!runner.join(10).nil?, "T8: interrupted Child.run did not return within 10s")
  check(runner.value == :interrupted && Time.now - started < 10, "T8: Child.run must re-raise the interrupt")
  check(wait_dead(child, 3), "T8: the child group survived an interrupted Child.run")
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
