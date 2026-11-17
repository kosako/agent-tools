# frozen_string_literal: true
require_relative "codex-worker-run-fixture"
require "time"

# Collection uses the real packet, snapshot verifier and public safety gate.
FileUtils.cp(File.join(SOURCE, "shared/scripts/personal-public-safety-gate.rb"), File.join(DEPLOY, "gate-real.rb"))
write_exec(File.join(DEPLOY, "personal-public-safety-gate"), <<~'GATE')
  #!/usr/bin/env ruby
  require_relative "gate-real"
  # Temporary homes do not have the production /Users or /home prefix.
  # Inject only the home needle; use the real scanner, findings and exit codes.
  if ENV["FAKE_GATE_HOME"]
    def PublicSafetyGate.home_needle
      ENV.fetch("HOME")
    end
  end
  if ENV["FAKE_GATE_ERROR"]
    warn "PRIVATE-GATE"
    exit 2
  end
  exit PublicSafetyGate.run(ARGV)
GATE
write_exec(File.join(BIN, "pgrep"), <<~'FAKE')
  #!/usr/bin/env ruby
  exit 2 if ENV["FAKE_PGREP_FAIL"]
  puts "12345" if ENV["FAKE_PGREP_FOUND"]
  exit(ENV["FAKE_PGREP_FOUND"] ? 0 : 1)
FAKE
write_exec(File.join(BIN, "ps"), "#!/bin/sh\nprintf 'ruby\\n'\n")
RESULT = <<~TEXT.gsub(" なし。\n", " なし。 \n")
  ### 到達点
  PRIVATE-RESULT
  ### 判断
  確認済み。
  ### 未完
  なし。
  ### 停止理由 または 質問
   なし。
  ### commits
  なし。
  ### 次の 1 アクション
  なし (review 待ち)
TEXT

def invoke(subcommand, expected = 0, env = {}, extra = [])
  result = launch(expected, env, [], explicit: [subcommand, "--repo", MAIN, "--issue", "7", *extra]) do |out, err|
    %w[PRIVATE-RESULT PRIVATE-PANE PRIVATE-GATE PRIVATE-LOG].each do |secret|
      assert(!out.include?(secret) && !err.include?(secret), "collection must not disclose #{secret}")
    end
    assert(err.empty?, "collector stderr is empty")
  end
  result
end

def recorded(run)
  reset_packet("branch: feat/7-test\nrun: #{run.to_json}\ntab: \"#7\"\n")
end

def finish(run, nonce, text = RESULT, code = 0)
  recorded(run)
  File.write(File.join(run, "done.txt"), "CODEX-WORKER-DONE-#{nonce} exit=#{code}\n")
  File.write(File.join(run, "result.md"), text)
  File.write(File.join(run, "codex.log"), "PRIVATE-LOG\n")
end

def failure(subcommand, at, code, env = {}, extra = [], changed: false)
  before = File.binread(PACKET)
  result = invoke(subcommand, 1, env, extra)
  assert(result["blocked_at"] == at && result["reason_code"] == code, "failure classification #{result} at #{caller.first}")
  assert(result["packet"]["written"] == changed, "packet written contract")
  assert(File.binread(PACKET) == before, "failed collection preserves packet") unless changed
  result
end

reset_packet
reset_herdr
failure("collect", "launch-record", "no-launch-record")
failure("retry-empty", "launch-record", "not-retryable")
["0", "121", "1.5", "bad"].each { |v| invoke("collect", 2, {}, ["--wait-minutes", v]) }
invoke("collect", 2, {}, ["--run-dir", ROOT])
invoke("retry-empty", 2, {}, ["--wait-minutes", "1"])

first = launch(0, {}, ["--branch", "feat/7-test", "--round", "2"])
run, nonce = first.values_at("run_dir", "nonce")
record_path = File.join(run, "launch.json")
record = JSON.parse(File.read(record_path))
assert(record == { "schema" => 1, "issue" => 7, "branch" => "feat/7-test", "clone_root" => File.realpath(CLONE),
  "nonce" => nonce, "tab_id" => "t1", "pane_id" => "p1", "pane_label" => "worker-7", "round" => 2,
  "previous_run" => nil, "created_at" => record["created_at"] }, "launch record fields")
assert(Time.iso8601(record["created_at"]).utc?, "UTC creation time")
assert(!File.exist?(record_path + ".tmp"), "atomic launch record leaves no temp")
# Neither collector nor retry may parse this file.
File.write(File.join(run, "run.zsh"), "not a script PRIVATE-LOG\n")
File.rename(record_path, record_path + ".saved")
failure("collect", "launch-record", "no-launch-record")
File.rename(record_path + ".saved", record_path)
File.write(record_path, JSON.generate(record.merge("schema" => 2)))
failure("collect", "launch-record", "invalid-launch-record")
File.write(record_path, JSON.generate(record))

# A real commit ensures the reported count uses merge-base, not the main checkout.
File.write(File.join(CLONE, "result.txt"), "implemented\n")
git(CLONE, "add", "result.txt")
git(CLONE, "commit", "-qm", "implementation")
head = git(CLONE, "rev-parse", "HEAD")
finish(run, nonce)
File.write(ENV.fetch("FAKE_GIT_LOG"), "")
result = invoke("collect")
assert(result["status"] == "DONE" && result["head_oid"] == head && result["commits"] == 1, "completed head and count")
assert(result["packet"] == { "written" => true, "state" => "open", "record" => "last_run" }, "done packet shape")
assert(result["redacted"] == false && result["leftover"]["foreground"]["checked"], "result flags")
assert(File.read(PACKET).include?(RESULT) && File.read(PACKET).include?("last_run: #{run.to_json}"), "verbatim transcription and last_run")
assert(!File.read(PACKET).match?(/^run:/) && !File.read(PACKET).match?(/^tab:/), "record moved")
assert(File.read(File.join(run, "pane.log")) == "PRIVATE-PANE\n", "raw pane log retained")
assert(events.none? { |e| e.first(2) == %w[pane wait-output] }, "completed run does not wait")
trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
assert(trace.none? { |a| a.include?("fetch") }, "collection never fetches")

finish(run, nonce)
result = invoke("collect", 0, { "FAKE_PGREP_FAIL" => "1", "FAKE_HERDR_FAIL" => "pane process-info" })
assert(result["leftover"] == { "foreground" => { "checked" => false }, "clone_arguments" => { "checked" => false } }, "unknown leftovers do not block")
finish(run, nonce)
result = invoke("collect", 0, { "FAKE_PGREP_FOUND" => "1" })
assert(result["leftover"]["clone_arguments"]["processes"] == [{ "pid" => 12345, "name" => "ruby" }], "leftover IDs reported")
finish(run, nonce)
failure("collect", "transcription", "pane-log", { "FAKE_PANE_OUTPUT" => "" })
failure("collect", "transcription", "pane-log", { "FAKE_HERDR_FAIL" => "pane read" })

finish(run, nonce)
failure("collect", "transcription", "gate", { "FAKE_GATE_ERROR" => "1" })
assert(File.read(File.join(run, "gate.err")) == "PRIVATE-GATE\n", "gate failure stderr retained without disclosure")
# Real scanner sees the injected fixture home needle for clone, run and other paths.
text = RESULT.sub("PRIVATE-RESULT", "PRIVATE-RESULT\n#{CLONE}/src/file.rb\n#{CLONE}\n#{run}\n#{ROOT}/elsewhere")
finish(run, nonce, text)
result = invoke("collect", 0, { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
redacted = File.read(File.join(run, "result.redacted.md"))
assert(result["redacted"] && redacted.include?("src/file.rb\n<clone>\n<run dir>\n<home>/elsewhere"), "home paths replaced in order")
assert(File.read(File.join(run, "result.md")) == text, "original result retained")
assert(File.read(PACKET).include?("orchestrator 注:") && File.read(PACKET).include?(redacted), "redaction note and text")
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", "x#{ROOT}/unchanged"))
failure("collect", "transcription", "gate", { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
# Other findings must not trigger replacement, even alongside home-path.
secret = ['-----BEGIN ', 'PRIVATE KEY-----'].join
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", "#{secret}\n#{ROOT}/elsewhere"))
failure("collect", "transcription", "gate", { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
assert(File.read(File.join(run, "gate.err")).include?("private-key-block"), "gate evidence retained")

invalid = [RESULT.sub("### 判断", "### 未完"), RESULT.sub("### 判断", "## 判断"),
  RESULT + "<!-- hidden -->", RESULT + "-->", RESULT + "### 2026-01-01 worker/codex\n",
  RESULT.sub("### 到達点", "### 判断"), RESULT.sub("なし (review 待ち)", ""),
  RESULT + "\n  **次の入口**  ", RESULT.sub("### 判断\n", "### 判断\n### 到達点\n")]
invalid.each do |text|
  finish(run, nonce, text)
  failure("collect", "transcription", "result-format")
end
finish(run, nonce, RESULT.sub(" なし。 ", "判断が必要です。"))
result = failure("collect", "executor-result", "worker-question", {}, [], changed: true)
assert(result["retryable"] == false && File.read(PACKET).include?("state: blocked"), "worker question stops")
assert(File.read(PACKET).include?("worker/codex") && File.read(PACKET).include?("run: #{run.to_json}"), "question retains run")

# Snapshot failure must precede every git invocation in the clone.
config_path = File.join(CLONE, ".git", "config")
config = File.binread(config_path)
[0, 17].each do |code|
  finish(run, nonce, RESULT, code)
  File.binwrite(config_path, config + "\n# changed\n")
  File.write(ENV.fetch("FAKE_GIT_LOG"), "")
  failure("collect", "clone", "snapshot-mismatch")
  trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
  assert(trace.none? { |a| a.include?(CLONE) }, "no clone git after mismatched snapshot")
  assert(!File.zero?(File.join(run, "snapshot-verify.txt")), "snapshot stderr saved")
  File.binwrite(config_path, config)
end

# Distinct staged, unstaged and untracked changes survive a stopped run.
File.write(File.join(CLONE, "base.txt"), "staged\n")
git(CLONE, "add", "base.txt")
File.write(File.join(CLONE, "base.txt"), "unstaged\n")
File.binwrite(File.join(CLONE, "untracked ' file"), "raw\0bytes")
[
  ["ERROR: You've hit your usage limit\nPRIVATE-LOG", "limit"],
  ["prefix ERROR: You've hit your usage limit\nPRIVATE-LOG", "executor-exit"]
].each do |log, category|
  finish(run, nonce, RESULT, 17)
  File.write(File.join(run, "codex.log"), log)
  failure("collect", category, category, {}, [], changed: true)
  assert(File.read(PACKET).include?("state: blocked") && File.read(PACKET).include?("worker/codex"), "stopped valid result copied")
  assert(File.read(File.join(run, "wip-status.txt")).include?("MM base.txt"), "status preserved")
  assert(File.read(File.join(run, "wip-staged.patch")).include?("+staged"), "staged patch preserved")
  assert(File.read(File.join(run, "wip-unstaged.patch")).include?("+unstaged"), "unstaged patch preserved")
  restored = File.join(ROOT, "restored")
  FileUtils.mkdir_p(restored)
  run_cmd("tar", "-C", restored, "-xf", File.join(run, "wip-untracked.tar"))
  assert(File.binread(File.join(restored, "untracked ' file")) == "raw\0bytes", "untracked restored byte for byte")
end
finish(run, nonce, RESULT)
File.write(File.join(run, "codex.log"), "ERROR: You've hit your usage limit\n")
assert(invoke("collect")["status"] == "DONE", "exit zero is not limit")
finish(run, "different-nonce", RESULT)
failure("collect", "executor-exit", "nonce-mismatch", {}, [], changed: true)
finish(run, nonce, "PRIVATE-RESULT malformed", 17)
failure("collect", "executor-exit", "executor-exit", {}, [], changed: true)
assert(File.read(PACKET).include?("orchestrator/claude") && !File.read(PACKET).include?("PRIVATE-RESULT"), "fixed stop entry for bad format")
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", secret), 17)
failure("collect", "executor-exit", "executor-exit", {}, [], changed: true)
assert(!File.read(PACKET).include?(secret), "gate rejected stop result uses fixed entry")
%w[status --cached --no-ext-diff ls-files].each do |arg|
  finish(run, nonce, RESULT, 17)
  result = failure("collect", "clone", "backup", { "FAKE_GIT_FAIL" => arg, "FAKE_GIT_FAIL_ROOT" => CLONE })
  assert(result["backup_step"], "backup failure reports step")
end
# Fail just unstaged diff and the tar process independently.
fault = File.join(ROOT, "backup-fault.rb")
File.write(fault, <<~'CODE')
  require "open3"
  module BackupFault
    def capture3(*args, **opts)
      argv = args.flatten
      if (ENV["FAKE_BACKUP_FAIL"] == "unstaged" && argv.include?("diff") && !argv.include?("--cached")) ||
         (ENV["FAKE_BACKUP_FAIL"] == "tar" && argv.first == "tar")
        return ["PRIVATE-RESULT", "PRIVATE-GATE", Struct.new(:exitstatus).new(1)]
      end
      super
    end
  end
  Open3.singleton_class.prepend(BackupFault)
CODE
%w[unstaged tar].each do |step|
  finish(run, nonce, RESULT, 17)
  result = failure("collect", "clone", "backup", { "RUBYOPT" => "-r#{fault}", "FAKE_BACKUP_FAIL" => step })
  assert(result["backup_step"] == (step == "tar" ? "untracked" : step), "specific backup step")
end

# Empty first result leaves all bytes of the launch record and packet unchanged.
finish(run, nonce, "")
first_record = File.binread(record_path)
result = failure("collect", "executor-result", "empty-result")
assert(result["retryable"] && File.binread(record_path) == first_record, "first empty is retryable without mutation")
File.unlink(File.join(run, "result.md"))
assert(failure("collect", "executor-result", "empty-result")["retryable"], "missing result is empty")
# retry rejects changed snapshot, then restarts only the eligible first run.
File.binwrite(config_path, config + "\n# changed\n")
File.write(ENV.fetch("FAKE_GIT_LOG"), "")
failure("retry-empty", "clone", "snapshot-mismatch")
trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
assert(trace.none? { |a| a.include?(CLONE) }, "retry verifies before clone git")
File.binwrite(config_path, config)
failure("retry-empty", "preflight", "preflight", { "FAKE_CODEX_NO_HELP" => "1" })
retry_result = invoke("retry-empty")
retry_run = retry_result.fetch("run_dir")
retry_record = JSON.parse(File.read(File.join(retry_run, "launch.json")))
assert(retry_run != run && retry_result["nonce"] != nonce && retry_result["tab_id"] == first["tab_id"], "fresh run in same tab")
assert(retry_record["retry_of"] == run && retry_record["previous_run"] == run && retry_record["round"] == 2, "retry lineage")
assert(File.binread(File.join(retry_run, "brief.md")) == File.binread(File.join(run, "brief.md")), "retry brief identical")
assert(File.read(PACKET).include?("run: #{retry_run.to_json}") && !File.read(PACKET).include?("last_run:"), "retry updates existing run")
assert(events.any? { |e| e.first(2) == %w[pane split] }, "retry adds pane")
run_cmd("zsh", File.join(retry_run, "run.zsh"), chdir: ROOT)
observed = JSON.parse(File.read(ENV.fetch("FAKE_CODEX_FILE")))
assert(observed["stdin"].b == File.binread(File.join(run, "brief.md")), "retry executor receives identical brief")
assert(File.read(File.join(retry_run, "done.txt")).include?(retry_result["nonce"]), "retry script uses new nonce")
finish(retry_run, retry_result["nonce"], "")
result = failure("collect", "executor-result", "empty-result", {}, [], changed: true)
assert(!result["retryable"] && File.read(PACKET).include?("state: blocked"), "second empty blocks")
failure("retry-empty", "launch-record", "not-retryable")
finish(run, nonce, RESULT)
failure("retry-empty", "launch-record", "not-retryable")
finish(run, nonce, "", 17)
failure("retry-empty", "launch-record", "not-retryable")
finish(run, "wrong", "")
failure("retry-empty", "launch-record", "not-retryable")

# Wait wake-up rechecks done, while definite exit without done records a stop.
finish(run, nonce)
File.unlink(File.join(run, "done.txt"))
assert(invoke("collect", 0, { "FAKE_WAIT_DONE" => run })["status"] == "DONE", "wait wake-up reads done")
wait_event = events.reverse.find { |e| e.first(2) == %w[pane wait-output] }
assert(wait_event == ["pane", "wait-output", "p1", "--match", "CODEX-WORKER-DONE-#{nonce}", "--timeout", "300000"], "wait argv")
finish(run, nonce)
File.unlink(File.join(run, "done.txt"))
failure("collect", "executor-exit", "executor-exit", {}, [], changed: true)

# Accelerate the monotonic clock only in this test process tree; production has no test clock option.
clock = File.join(ROOT, "clock.rb")
File.write(clock, <<~'CODE')
  module FastClock
    def clock_gettime(clock, *args)
      return super unless clock == Process::CLOCK_MONOTONIC
      @ticks ||= -20
      @ticks += 20
    end
  end
  Process.singleton_class.prepend(FastClock)
CODE
state = JSON.parse(File.read(ENV.fetch("FAKE_HERDR_FILE")))
state["running"] = ["p1"]
reset_herdr(state)
[{}, { "FAKE_HERDR_FAIL" => "pane process-info" }, { "FAKE_HERDR_BAD" => "pane process-info" }].each do |env|
  finish(run, nonce)
  File.unlink(File.join(run, "done.txt"))
  before = File.binread(PACKET)
  result = invoke("collect", 3, { "RUBYOPT" => "-r#{clock}" }.merge(env), ["--wait-minutes", "1"])
  assert(result["status"] == "RUNNING" && result["elapsed_minutes"] >= 1 && result["pane_id"] == "p1", "running cap")
  assert(!result["packet"]["written"] && File.binread(PACKET) == before, "running retains packet")
end
assert(events.none? { |e| %w[close kill].include?(e[1]) }, "never closes or kills")
puts "ok: codex-worker collect/retry self-test (#{$count} checks)"
