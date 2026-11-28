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
  "previous_run" => nil, "created_at" => record["created_at"], "start_head" => BASE }, "launch record fields")
request_path = File.join(run, "request.sha256")
request_record = Digest::SHA256.hexdigest(REQUEST) + "\n"
assert(File.binread(request_path) == request_record, "request digest is recorded with the brief")
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

# Count from the launch HEAD even when main learns objects absent from the clone.
File.write(File.join(CLONE, "result.txt"), "implemented\n")
git(CLONE, "add", "result.txt")
git(CLONE, "commit", "-qm", "implementation")
head = git(CLONE, "rev-parse", "HEAD")
git(ORIGIN, "commit", "--allow-empty", "-qm", "advance origin")
git(MAIN, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main")
finish(run, nonce)
File.write(ENV.fetch("FAKE_GIT_LOG"), "")
result = invoke("collect")
assert(result["status"] == "DONE" && result["head_oid"] == head && result["commits_this_run"] == 1, "completed head and count")
assert(!result.key?("commits"), "old total count key is absent")
assert(result["packet"] == { "written" => true, "state" => "open", "record" => "last_run" }, "done packet shape")
assert(result["redacted"] == false && result["leftover"]["foreground"]["checked"], "result flags")
assert(result["request"] == "same" && File.read(PACKET).end_with?("## 次の入口\n\nなし (review 待ち)\n\n"), "unchanged request updates the next entry")
assert(!File.read(PACKET).include?("起動の後に依頼が変わった"), "unchanged request adds no note")
assert(File.read(PACKET).include?(RESULT) && File.read(PACKET).include?("last_run: #{run.to_json}"), "verbatim transcription and last_run")
assert(!File.read(PACKET).match?(/^run:/) && !File.read(PACKET).match?(/^tab:/), "record moved")
assert(File.read(File.join(run, "pane.log")) == "PRIVATE-PANE\n", "raw pane log retained")
assert(events.none? { |e| e.first(2) == %w[pane wait-output] }, "completed run does not wait")
trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
assert(trace.none? { |a| a.include?("fetch") }, "collection never fetches")

# The reused branch does not fetch main's newly advanced tip on a correction round.
round = launch(0, {}, ["--round", "3"])
round_run = round.fetch("run_dir")
assert(JSON.parse(File.read(File.join(round_run, "launch.json")))["start_head"] == head, "round starts at existing clone HEAD")
git(CLONE, "commit", "--allow-empty", "-qm", "correction")
finish(round_run, round.fetch("nonce"))
File.write(ENV.fetch("FAKE_GIT_LOG"), "")
result = invoke("collect")
assert(result["status"] == "DONE" && result["commits_this_run"] == 1, "correction round collected after main advanced")
trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
assert(trace.none? { |a| a.include?("fetch") }, "correction collection never fetches")
[record.reject { |k, _v| k == "start_head" }, record.merge("start_head" => "f" * 40)].each do |old_record|
  finish(run, nonce)
  File.write(record_path, JSON.generate(old_record))
  result = invoke("collect")
  assert(result["status"] == "DONE" && result.key?("commits_this_run") && result["commits_this_run"].nil?, "unknown start HEAD does not block transcription")
end
File.write(record_path, JSON.generate(record))

# The request is appended while the worker runs (#719). The result is kept and the appended entry survives.
def append_request
  packet = File.join(DEPLOY, "personal-packet")
  input = { "schema" => 1, "operation" => "round", "request" => "### 修正 round 9\nPRIVATE-REQUEST を足す", "next" => "足した依頼の入口",
            "expected_sha256" => Digest::SHA256.file(PACKET).hexdigest }
  run_cmd(packet, "worker-update", "7", "--stdin", stdin_data: JSON.generate(input), chdir: MAIN)
end
kept = "## 次の入口\n\n足した依頼の入口\n\n"
finish(run, nonce)
append_request
result = invoke("collect")
assert(result["status"] == "DONE" && result["request"] == "changed", "changed request is reported")
text = File.read(PACKET)
assert(text.end_with?(kept) && text.include?("worker/codex\n\n(orchestrator 注: 起動の後に依頼が変わった。") && text.include?(RESULT), "changed request keeps the entry and the result")
assert(text.include?("修正 round 9") && text.include?("last_run: #{run.to_json}"), "changed request keeps the request and moves the record")
finish(run, nonce, RESULT.sub(" なし。 ", "判断が必要です。"))
append_request
result = failure("collect", "executor-result", "worker-question", {}, [], changed: true)
assert(result["request"] == "changed" && File.read(PACKET).end_with?(kept), "question keeps the appended entry")
finish(run, nonce, "PRIVATE-RESULT malformed", 17)
append_request
result = failure("collect", "executor-exit", "executor-exit", {}, [], changed: true)
text = File.read(PACKET)
assert(result["request"] == "changed" && text.end_with?(kept), "stopped run keeps the appended entry")
assert(text.include?("orchestrator/claude\n\n(orchestrator 注: 起動の後に依頼が変わった。") && text.include?("\n次の手: 停止理由と退避した変更を確かめてから、再開を判断する。\n"), "fixed stop entry keeps its own next step")
finish(run, nonce)
append_request
failure("collect", "transcription", "pane-log", { "FAKE_PANE_OUTPUT" => "" })
# A run launched by an older version has no digest. It cannot be shown to match.
[nil, "", request_record.chomp, request_record.upcase].each do |recorded_request|
  finish(run, nonce)
  recorded_request ? File.write(request_path, recorded_request) : File.unlink(request_path)
  result = invoke("collect")
  text = File.read(PACKET)
  assert(result["status"] == "DONE" && result["request"] == "unrecorded" && text.end_with?("## 次の入口\n\nnext\n"), "unrecorded request keeps the entry")
  assert(text.include?("(orchestrator 注: 起動のときの依頼の記録が無く"), "unrecorded request adds its note")
end
File.write(request_path, request_record)

# A launch-path failure leaves a manual script even after creating a pane.
state = JSON.parse(File.read(ENV.fetch("FAKE_HERDR_FILE")))
[["launch", "tab create"], ["launch", "pane rename"], ["launch", "pane run"],
  ["retry-empty", "pane rename"], ["retry-empty", "pane run"]].each do |subcommand, failed_command|
  reset_herdr
  if subcommand == "retry-empty"
    initial = launch
    finish(initial.fetch("run_dir"), initial.fetch("nonce"), "")
  end
  manual = invoke(subcommand, 1, { "FAKE_HERDR_FAIL" => failed_command })
  assert(manual["blocked_at"] == "launch-path" && manual["reason_code"] == "herdr-response", "manual launch failure classification")
  assert(manual["packet"]["written"], "manual launch keeps run record")
  manual_run = manual.fetch("run_dir")
  manual_record = JSON.parse(File.read(File.join(manual_run, "launch.json")))
  assert(manual_record["pane_id"].nil?, "#{subcommand} #{failed_command} clears collection pane")
  assert(!File.exist?(File.join(manual_run, "launch.json.tmp")), "manual record replaced atomically")
  unless failed_command == "tab create"
    assert(!File.read(File.join(manual_run, "pane-id")).strip.empty?, "created pane evidence retained")
    assert(File.read(File.join(manual_run, "tab-id")).strip == manual_record["tab_id"], "created tab evidence retained")
  end
  assert(events.none? { |e| %w[close kill].include?(e[1]) }, "launch failure retains pane and tab")
  before = File.binread(PACKET)
  File.write(ENV.fetch("FAKE_HERDR_LOG"), "")
  pending = invoke("collect", 3, { "FAKE_HERDR_FAIL_ALL" => "1" })
  assert(pending["reason_code"] == "manual-completion-pending" && !pending.key?("blocked_at"), "manual completion wait is RUNNING without blocked_at")
  assert(!pending["packet"]["written"] && File.binread(PACKET) == before, "manual wait keeps packet")
  assert(events.empty? && Dir.glob(File.join(manual_run, "wip-*")).empty?, "manual wait does not inspect pane or back up active work")
  run_cmd("zsh", File.join(manual_run, "run.zsh"), chdir: ROOT)
  File.write(File.join(manual_run, "result.md"), "")
  if subcommand == "launch"
    failure("retry-empty", "launch-path", "tab-ownership")
  else
    failure("retry-empty", "launch-record", "not-retryable")
  end
  File.write(File.join(manual_run, "result.md"), RESULT)
  File.write(ENV.fetch("FAKE_HERDR_LOG"), "")
  result = invoke("collect", 0, { "FAKE_HERDR_FAIL_ALL" => "1" })
  assert(result["status"] == "DONE" && result["leftover"]["foreground"] == { "checked" => false }, "manual run collected without foreground")
  assert(!File.exist?(File.join(manual_run, "pane.log")) && events.empty?, "manual collection never reads herdr or saves pane log")
end
reset_herdr(state)

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
# 見出しの語だけの行も見出しとして受ける (#806)。#847 のように語の後ろに空白が付いても受け、転記は逐語 (packet にも
# 語だけの行がそのまま残る)。次の入口は節の中身から取る
bare = RESULT.gsub(/^### /, "").sub("判断\n", "判断  \n")
finish(run, nonce, bare)
result = invoke("collect")
assert(result["status"] == "DONE" && result["packet"]["written"], "bare headings are accepted")
assert(File.read(PACKET).include?(bare) && File.read(PACKET).end_with?("## 次の入口\n\nなし (review 待ち)\n\n"),
       "bare headings are transcribed verbatim with the next entry")
# gate の置き換えで本文の行が見出しの語だけになれば、2 回目の解析で見出しが増えて止まり、転記しない (#806)
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", "PRIVATE-RESULT\n#{CLONE}/判断"))
failure("collect", "transcription", "result-format", { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
assert(File.read(File.join(run, "result.redacted.md")).include?("\n判断\n"), "the redacted line became a bare heading word")
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", "x#{ROOT}/unchanged"))
failure("collect", "transcription", "gate", { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
# Other findings must not trigger replacement, even alongside home-path.
secret = ['-----BEGIN ', 'PRIVATE KEY-----'].join
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", "#{secret}\n#{ROOT}/elsewhere"))
failure("collect", "transcription", "gate", { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
assert(File.read(File.join(run, "gate.err")).include?("private-key-block"), "gate evidence retained")
# Both findings disappear on replacement. No redaction attempt is permitted.
local_patterns = File.join(ROOT, ".config", "agent-tools", "public-safety-patterns.local")
FileUtils.mkdir_p(File.dirname(local_patterns))
File.write(local_patterns, Regexp.escape(ROOT) + "\n")
File.unlink(File.join(run, "result.redacted.md"))
finish(run, nonce, RESULT.sub("PRIVATE-RESULT", "#{ROOT}/elsewhere"))
failure("collect", "transcription", "gate", { "HOME" => ROOT, "FAKE_GATE_HOME" => "1" })
assert(!File.exist?(File.join(run, "result.redacted.md")), "mixed findings must not create redacted result")
assert(File.read(File.join(run, "gate.err")).include?("local-pattern:1"), "mixed local finding exercised")
File.unlink(local_patterns)

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
state = JSON.parse(File.read(ENV.fetch("FAKE_HERDR_FILE")))
[[], [{ "tab_id" => "different", "label" => "#7" }]].each do |tabs|
  reset_herdr(state.merge("tabs" => tabs))
  failure("retry-empty", "launch-path", "tab-ownership")
  assert(events.none? { |e| %w[create split run].include?(e[1]) }, "bad retry tab makes no pane")
end
reset_herdr(state)
other_run = File.join(ROOT, "other-run")
FileUtils.mkdir_p(other_run)
File.write(File.join(other_run, "tab-id"), "t1\n")
other = File.join(MAIN, ".agent-packets", "8.md")
File.write(other, File.read(PACKET).sub("issue: 7", "issue: 8").sub(run.to_json, other_run.to_json).sub('#7', '#8'))
[true, false].each do |running|
  reset_herdr(state.merge("running" => running ? ["p1"] : []))
  result = failure("retry-empty", running ? "launch-path" : "launch-record", running ? "worker-running" : "run-unconfirmed")
  assert(result["phase"] == "records" && result["other_issue"] == 8 && result["other_run_dir"] == other_run, "retry shares other issue classification")
  assert(!result.key?("run_dir"), "other issue does not report retry run as the blocking run")
end
File.unlink(other)
reset_herdr(state)
File.binwrite(config_path, config + "\n# changed\n")
File.write(ENV.fetch("FAKE_GIT_LOG"), "")
failure("retry-empty", "clone", "snapshot-mismatch")
trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
assert(trace.none? { |a| a.include?(CLONE) }, "retry verifies before clone git")
File.binwrite(config_path, config)
failure("retry-empty", "preflight", "preflight", { "FAKE_CODEX_NO_HELP" => "1" })
# The request changes before the retry. The retry runs the old brief, so it keeps the old digest (#719).
append_request
retry_result = invoke("retry-empty")
retry_run = retry_result.fetch("run_dir")
assert(File.binread(File.join(retry_run, "request.sha256")) == request_record, "retry keeps the digest of the copied brief")
retry_record = JSON.parse(File.read(File.join(retry_run, "launch.json")))
assert(retry_run != run && retry_result["nonce"] != nonce && retry_result["tab_id"] == first["tab_id"], "fresh run in same tab")
assert(retry_record["retry_of"] == run && retry_record["previous_run"] == run && retry_record["round"] == 2, "retry lineage")
assert(retry_record["start_head"] == git(CLONE, "rev-parse", "HEAD"), "retry starts at current clone HEAD")
assert(File.binread(File.join(retry_run, "brief.md")) == File.binread(File.join(run, "brief.md")), "retry brief identical")
assert(File.read(PACKET).include?("run: #{retry_run.to_json}") && !File.read(PACKET).include?("last_run:"), "retry updates existing run")
assert(events.any? { |e| e.first(2) == %w[pane split] }, "retry adds pane")
run_cmd("zsh", File.join(retry_run, "run.zsh"), chdir: ROOT)
observed = JSON.parse(File.read(ENV.fetch("FAKE_CODEX_FILE")))
assert(observed["stdin"].b == File.binread(File.join(run, "brief.md")), "retry executor receives identical brief")
assert(File.read(File.join(retry_run, "done.txt")).include?(retry_result["nonce"]), "retry script uses new nonce")
finish(retry_run, retry_result["nonce"], "")
failure("retry-empty", "launch-record", "not-retryable")
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
["", "CODEX-WORKER-DONE-#{nonce} exit=0"].each do |partial|
  finish(run, nonce)
  File.write(File.join(run, "done.txt"), partial)
  assert(invoke("collect", 0, { "FAKE_WAIT_DONE" => run })["status"] == "DONE", "partial done waits for newline")
end
finish(run, nonce)
File.unlink(File.join(run, "done.txt"))
failure("collect", "executor-exit", "executor-exit", {}, [], changed: true)

# Advance fake time by actual requested sleeps, so a missing backoff cannot pass.
clock = File.join(ROOT, "clock.rb")
File.write(clock, <<~'CODE')
  module FastClock
    def clock_gettime(clock, *args)
      return super unless clock == Process::CLOCK_MONOTONIC
      @ticks ||= 0.0
      @ticks += 0.01
    end
    def advance(seconds)
      @ticks = (@ticks || 0.0) + seconds
    end
  end
  Process.singleton_class.prepend(FastClock)
  module FastSleep
    def sleep(seconds)
      Process.advance(seconds)
      if ENV["FAKE_SLEEP_DONE"]
        record = JSON.parse(File.read(File.join(ENV.fetch("FAKE_SLEEP_DONE"), "launch.json")))
        File.write(File.join(ENV.fetch("FAKE_SLEEP_DONE"), "done.txt"), "CODEX-WORKER-DONE-#{record.fetch('nonce')} exit=0\n")
      end
      File.open(ENV.fetch("FAKE_SLEEP_LOG"), "a") { |f| f.puts seconds } if ENV["FAKE_SLEEP_LOG"]
      0
    end
  end
  Object.prepend(FastSleep)
CODE
finish(run, nonce)
File.unlink(File.join(run, "done.txt"))
result = invoke("collect", 0, { "RUBYOPT" => "-r#{clock}", "FAKE_SLEEP_DONE" => run })
assert(result["status"] == "DONE", "exit observation allows done publication before stopping")
state = JSON.parse(File.read(ENV.fetch("FAKE_HERDR_FILE")))
state["running"] = ["p1"]
reset_herdr(state)
[{}, { "FAKE_HERDR_FAIL" => "pane process-info" }, { "FAKE_HERDR_BAD" => "pane process-info" },
 { "FAKE_HERDR_FAIL_ALL" => "1" }].each do |env|
  finish(run, nonce)
  File.unlink(File.join(run, "done.txt"))
  before = File.binread(PACKET)
  reset_herdr(state)
  sleep_log = File.join(ROOT, "sleep.log")
  File.write(sleep_log, "")
  result = invoke("collect", 3, { "RUBYOPT" => "-r#{clock}", "FAKE_SLEEP_LOG" => sleep_log }.merge(env), ["--wait-minutes", "1"])
  assert(result["status"] == "RUNNING" && result["elapsed_minutes"] >= 1 && result["pane_id"] == "p1", "running cap")
  assert(!result["packet"]["written"] && File.binread(PACKET) == before, "running retains packet")
  assert(!result.key?("blocked_at"), "RUNNING has no blocked_at")
  %w[wait-output process-info].each do |verb|
    calls = events.count { |e| e.first(2) == ["pane", verb] }
    assert((1..4).cover?(calls), "at most four #{verb} calls per minute even on immediate failure: #{calls}")
  end
  assert(File.readlines(sleep_log).map(&:to_f).sum > 59, "waiting uses sleep rather than spinning")
end
assert(events.none? { |e| %w[close kill].include?(e[1]) }, "never closes or kills")
# clone の状態 (#718)。collect は止まらずに転記し、clone の項目で、未 commit の数と HEAD が branch を指すかを返す。
# 各 case は新しい clone で起動し、worker の commit の後に手を加える。
clone_case = lambda do |label, expected, work|
  FileUtils.rm_rf(CLONE)
  reset_packet
  reset_herdr
  started = launch(0, {}, ["--branch", "feat/7-test"])
  git(CLONE, "commit", "--allow-empty", "-qm", "implementation")
  work.call
  finish(started.fetch("run_dir"), started.fetch("nonce"))
  result = invoke("collect")
  assert(result["status"] == "DONE" && result["clone"] == expected, "#{label}: #{result['clone'].inspect} #{result['reason_code']}")
  assert(result["head_oid"] == git(CLONE, "rev-parse", "HEAD"), "#{label}: head_oid is the clone HEAD")
  assert(File.read(File.join(started.fetch("run_dir"), "collected-head")) == result["head_oid"] + "\n", "#{label}: collect records the HEAD")
  assert(File.read(PACKET).include?(RESULT), "#{label}: the result is transcribed")
  result
end
counts = ->(on, staged, unstaged, untracked) { { "head_on_branch" => on, "staged" => staged, "unstaged" => unstaged, "untracked" => untracked } }
write = ->(name, text) { File.write(File.join(CLONE, name), text) }
rebase_conflict = lambda do
  write.call("base.txt", "worker\n")
  git(CLONE, "commit", "-qam", "worker change")
  git(CLONE, "switch", "-qc", "side", BASE)
  write.call("base.txt", "side\n")
  git(CLONE, "commit", "-qam", "side change")
  git(CLONE, "switch", "-q", "feat/7-test")
  _out, status = Open3.capture2e(REAL_GIT, "-C", CLONE, "rebase", "-q", "side")
  assert(!status.success? && File.exist?(File.join(CLONE, ".git/REBASE_HEAD")), "fixture: the last commit conflicts")
  write.call("base.txt", "resolved\n")
  git(CLONE, "add", "base.txt")
end
clone_case.call("C1 clean", counts.call(true, 0, 0, 0), -> {})
clone_case.call("C12 staged", counts.call(true, 1, 0, 0), -> { write.call("new.txt", "new\n"); git(CLONE, "add", "new.txt") })
clone_case.call("C13 unstaged", counts.call(true, 0, 1, 0), -> { write.call("base.txt", "changed\n") })
clone_case.call("C14 untracked", counts.call(true, 0, 0, 1), -> { write.call("left.txt", "left\n") })
clone_case.call("C15 three", counts.call(true, 1, 1, 1), lambda {
  write.call("new.txt", "new\n")
  git(CLONE, "add", "new.txt")
  write.call("base.txt", "changed\n")
  write.call("left.txt", "left\n")
})
clone_case.call("same file staged and unstaged", counts.call(true, 1, 1, 0), lambda {
  write.call("base.txt", "staged\n")
  git(CLONE, "add", "base.txt")
  write.call("base.txt", "unstaged\n")
})
clone_case.call("C16 ignored", counts.call(true, 0, 0, 0), lambda {
  write.call(".gitignore", "*.out\n")
  git(CLONE, "add", ".gitignore")
  git(CLONE, "commit", "-qm", "ignore")
  write.call("test.out", "generated\n")
})
clone_case.call("C17 rename", counts.call(true, 1, 0, 0), -> { git(CLONE, "mv", "base.txt", "moved.txt") })
clone_case.call("C18 staged deletion", counts.call(true, 1, 0, 0), -> { git(CLONE, "rm", "-q", "base.txt") })
clone_case.call("C19 unstaged deletion", counts.call(true, 0, 1, 0), -> { File.unlink(File.join(CLONE, "base.txt")) })
clone_case.call("C20 names", counts.call(true, 0, 0, 3), lambda {
  write.call("with space.txt", "a\n")
  write.call("with\nnewline.txt", "b\n")
  write.call("名前.txt", "c\n")
})
clone_case.call("C21 empty directory", counts.call(true, 0, 0, 0), -> { Dir.mkdir(File.join(CLONE, "empty-dir")) })
clone_case.call("C9 detached HEAD", counts.call(false, 0, 0, 0), lambda {
  git(CLONE, "switch", "-q", "--detach")
  git(CLONE, "commit", "--allow-empty", "-qm", "detached")
})
clone_case.call("C10 other branch", counts.call(false, 0, 0, 0), lambda {
  git(CLONE, "switch", "-qc", "other")
  git(CLONE, "commit", "--allow-empty", "-qm", "other")
})
clone_case.call("C11 back to the branch", counts.call(true, 0, 0, 0), lambda {
  git(CLONE, "switch", "-qc", "other")
  git(CLONE, "commit", "--allow-empty", "-qm", "other")
  git(CLONE, "switch", "-q", "feat/7-test")
})
clone_case.call("C2 finished rebase", counts.call(true, 0, 0, 0), lambda {
  rebase_conflict.call
  out, status = Open3.capture2e({ "GIT_EDITOR" => "true" }, REAL_GIT, "-C", CLONE, "rebase", "--continue")
  assert(status.success? && File.exist?(File.join(CLONE, ".git/REBASE_HEAD")), "fixture: the finished rebase leaves REBASE_HEAD: #{out}")
})
clone_case.call("C6 rebase --quit", counts.call(false, 0, 0, 0), lambda {
  rebase_conflict.call
  git(CLONE, "commit", "-qm", "half")
  git(CLONE, "rebase", "--quit")
})
puts "ok: codex-worker collect/retry self-test (#{$count} checks)"
