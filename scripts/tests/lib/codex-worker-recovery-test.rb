# frozen_string_literal: true
require_relative "codex-worker-run-fixture"

# Recovery uses real runner, packet updates and snapshot verification.
# External programs are fixtures; no network or real worker is started.
%w[personal-ja-style-check personal-work-marker-check].each do |name|
  FileUtils.cp(File.join(SOURCE, "shared/scripts", name + ".rb"), File.join(DEPLOY, name))
  File.chmod(0755, File.join(DEPLOY, name))
end
write_exec(File.join(BIN, "pgrep"), "#!/bin/sh\nexit 1\n")
write_exec(File.join(BIN, "gh"), <<~'FAKE')
  #!/usr/bin/env ruby
  case ARGV
  when %w[repo view --json nameWithOwner] then puts '{"nameWithOwner":"owner/project"}'
  when %w[api user] then puts '{"login":"owner"}'
  when %w[api repos/owner/project] then puts '{"owner":{"type":"User","login":"owner"}}'
  else abort "unexpected gh command"
  end
FAKE
write_exec(File.join(DEPLOY, "personal-public-safety-gate"), <<~'FAKE')
  #!/usr/bin/env ruby
  warn "public-safety-gate: warning: fixture" if ENV["FAKE_WARNING"]
  exit 0
FAKE
RESULT = <<~TEXT
  ### 到達点
  実装した。
  ### 判断
  契約を確認した。
  ### 未完
  なし。
  ### 停止理由 または 質問
  なし
  ### commits
  実装の commit。
  ### 次の 1 アクション
  なし (review 待ち)
TEXT

def finish(record)
  run = record.fetch("run_dir")
  File.write(File.join(run, "done.txt"), "CODEX-WORKER-DONE-#{record.fetch('nonce')} exit=0\n")
  File.write(File.join(run, "result.md"), RESULT)
end

def invoke(cmd, rc = 0, env = {}, args = [])
  launch(rc, env, [], explicit: [cmd, "--repo", MAIN, "--issue", "7", *args])
end

def packet_update(operation, fields)
  input = { "schema" => 1, "operation" => operation, "expected_sha256" => Digest::SHA256.file(PACKET).hexdigest }.merge(fields)
  out = run_cmd(File.join(DEPLOY, "personal-packet"), "worker-update", "7", "--stdin", stdin_data: JSON.generate(input), chdir: MAIN)
  assert(JSON.parse(out)["ok"], "packet update #{operation}")
end

def row
  out = run_cmd(File.join(DEPLOY, "personal-packet"), "list", "--json", "--all", chdir: MAIN)
  JSON.parse(out).find { |r| r["issue"] == 7 }
end

def discard(run)
  packet_update("stop", "run" => run, "role" => "orchestrator/claude", "entry" => "人が不在と保存を確認し、記録の破棄を決めた。", "next" => "許可された依頼で再開する。")
  assert(row["state"] == "blocked" && row["run"] == run, "stop keeps run while blocking")
end

reset_packet
reset_herdr
initial = launch(0, {}, ["--branch", "feat/7-recovery"])
File.write(File.join(CLONE, "work.txt"), "saved implementation\n")
git(CLONE, "add", "work.txt")
git(CLONE, "commit", "-qm", "実装する\n\nCo-Authored-By: Codex <codex@example.invalid>")
head = git(CLONE, "rev-parse", "HEAD")
finish(initial)
assert(invoke("collect")["status"] == "DONE", "first collect")

# Round 1: check failure keeps open / last_run; retry reaches READY without stop.
git(MAIN, "remote", "set-url", "--push", "origin", "https://github.com/owner/project.git")
body = File.join(ROOT, "pr-body.md")
File.write(body, "Closes #7\n")
args = ["--title", "回復を確認する (#7)", "--body-file", body]
before = File.binread(PACKET)
failed = invoke("check", 1, { "FAKE_WARNING" => "1" }, args)
assert(failed.values_at("blocked_at", "reason_code") == %w[public-safety gate-warning], "warning classification")
assert(File.binread(PACKET) == before && row["state"] == "open" && row["last_run"] == initial["run_dir"], "check preserves open / last_run")
ready = invoke("check", 0, { "FAKE_WARNING" => "1" }, args + ["--accept-warnings"])
assert(ready["status"] == "READY" && ready["head_oid"] == head && File.binread(PACKET) == before, "human acceptance then check succeeds")
puts "ok: recovery check BLOCKED -> READY (open / last_run preserved)"

# Round 2: a hand-off with no tab-id loses ownership of the old round's tab.
packet_update("round", "request" => "### 修正 round 1\n回復を確認する。", "next" => "修正 round 1 を実装する。")
manual = invoke("launch", 1, { "FAKE_HERDR_FAIL" => "tab list" }, ["--round", "1"])
assert(manual["reason_code"] == "herdr-response" && !File.exist?(File.join(manual["run_dir"], "tab-id")), "manual run has no tab evidence")
assert(invoke("collect", 3)["reason_code"] == "manual-completion-pending", "unstarted manual run")
discard(manual["run_dir"])
unowned = invoke("launch", 1, {}, ["--round", "1"])
assert(unowned.values_at("blocked_at", "reason_code") == %w[launch-path tab-ownership], "old tab blocks new run")
assert(row["state"] == "open" && row["run"] == unowned["run_dir"], "failed launch already wrote new run")
reset_herdr # Human verified and closed the unused fixture tab.
discard(unowned["run_dir"])
restarted = invoke("launch", 0, {}, ["--round", "1"])
assert(restarted["status"] == "STARTED" && row["state"] == "open", "stop then launch recovers after closing tab")
assert(git(CLONE, "rev-parse", "HEAD") == head, "round recovery preserves commits")
puts "ok: recovery old tab -> stop -> tab-ownership -> human close -> stop -> STARTED"

# Round 3: snapshot mismatch after completion retains open / run.
# The archive preserves commits, dirty files and the changed git metadata.
File.write(File.join(CLONE, "work.txt"), "uncommitted change\n")
File.binwrite(File.join(CLONE, "untracked.bin"), "kept\0bytes")
config = File.join(CLONE, ".git/config")
FileUtils.cp(config, File.join(ROOT, "config-before-mutation"))
File.open(config, "a") { |f| f.puts "# fixture snapshot mismatch" }
finish(restarted)
before = File.binread(PACKET)
failed = invoke("collect", 1)
assert(failed.values_at("blocked_at", "reason_code") == %w[clone snapshot-mismatch], "finished snapshot mismatch")
assert(File.binread(PACKET) == before && row["state"] == "open" && row["run"] == restarted["run_dir"], "snapshot failure preserves open / run")
assert(invoke("launch", 1)["reason_code"] == "collect-required", "launch alone cannot recover")
archive = File.join(ROOT, "saved-clone")
File.rename(CLONE, archive) # Human preservation and quarantine; no git reads of unverified metadata.
discard(restarted["run_dir"])
new_run = invoke("launch")
assert(new_run["status"] == "STARTED" && row["state"] == "open" && row["run"] == new_run["run_dir"], "snapshot recovery reaches fresh run")
assert(File.read(File.join(archive, "work.txt")) == "uncommitted change\n" && File.binread(File.join(archive, "untracked.bin")) == "kept\0bytes", "archive preserves dirty and untracked work")
assert(File.directory?(File.join(archive, ".git/objects")), "archive keeps commit objects")
assert(File.read(File.join(archive, ".git/refs/heads/feat/7-recovery")).strip == head, "archive preserves the committed head without invoking git")
# Restore only the fixture mutation from its copy, without discarding any work.
FileUtils.cp(File.join(ROOT, "config-before-mutation"), File.join(archive, ".git/config"))
finish(new_run)
assert(invoke("collect")["status"] == "DONE", "fresh run is collectable")
puts "ok: recovery snapshot -> preserve clone -> stop -> STARTED -> DONE"
puts "codex-worker-recovery: #{$count} assertions passed"
