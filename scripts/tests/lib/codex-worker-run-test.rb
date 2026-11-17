# frozen_string_literal: true
require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "digest"

SOURCE, ROOT = ARGV.map { |v| File.realpath(v) }
# macOS の TMPDIR は /tmp と別の実体。子の TMPDIR は fixture 内の専用 directory にする。
# Linux の /tmp の下でも境界の単体検査は実行できるが、成功の結合検査には /tmp 外の TMPDIR が必要。
$count = 0
def assert(value, message)
  abort "FAIL: #{message}" unless value
  $count += 1
end

def write_exec(path, text)
  File.write(path, text)
  File.chmod(0755, path)
end

REAL_GIT = Open3.capture3("which", "git").first.strip
ENV.keys.grep(/\A(?:GIT_|CODEX_|GH_|HERDR_|FAKE_)/).each { |k| ENV.delete(k) }
ENV["HOME"] = File.join(ROOT, "home")
ENV["XDG_CONFIG_HOME"] = File.join(ROOT, "config")
CONFIG_FILE = File.join(ENV.fetch("HOME"), ".gitconfig")
ENV["CODEX_HOME"] = File.join(ROOT, "codex-home")
ENV["TMPDIR"] = File.join(ROOT, "tmp")
ENV["XDG_STATE_HOME"] = File.join(ROOT, "state ' $(touch INJECTED) `touch BACKTICK`")
ENV["HERDR_WORKSPACE_ID"] = "ws-test"
[ENV["HOME"], ENV["CODEX_HOME"], ENV["TMPDIR"]].each { |p| FileUtils.mkdir_p(p) }
BIN = File.join(ROOT, "bin")
DEPLOY = File.join(ROOT, "deployed ' scripts")
HOOKS = File.join(ROOT, "hooks")
[BIN, DEPLOY, HOOKS].each { |p| FileUtils.mkdir_p(p) }
%w[pre-commit commit-msg].each { |name| write_exec(File.join(HOOKS, name), "#!/bin/sh\nexit 0\n") }
File.write(CONFIG_FILE, <<~CONFIG)
  [user]
    name = Test Worker
    email = worker@example.invalid
  [core]
    hooksPath = #{HOOKS}
    excludesFile = /dev/null
  [init]
    defaultBranch = main
  [protocol "file"]
    allow = always
CONFIG
File.write(File.join(ENV["CODEX_HOME"], "config.toml"), "model = \"fixture-model\"\nmodel_reasoning_effort = \"high\"\n")
%w[personal-codex-worker-run personal-codex-worker-preflight personal-packet].each do |name|
  FileUtils.cp(File.join(SOURCE, "shared", "scripts", name + ".rb"), File.join(DEPLOY, name))
  File.chmod(0755, File.join(DEPLOY, name))
end
%w[personal-git-hook-dispatcher personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate].each do |name|
  write_exec(File.join(DEPLOY, name), "#!/bin/sh\nexit 0\n")
end
ENV["FAKE_GIT_REAL"] = REAL_GIT
ENV["FAKE_GIT_LOG"] = File.join(ROOT, "git.jsonl")
write_exec(File.join(BIN, "git"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  File.open(ENV.fetch("FAKE_GIT_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
  exec(ENV.fetch("FAKE_GIT_REAL"), *ARGV)
FAKE
ENV["FAKE_HERDR_FILE"] = File.join(ROOT, "herdr.json")
ENV["FAKE_HERDR_LOG"] = File.join(ROOT, "herdr.jsonl")
write_exec(File.join(BIN, "herdr"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  file = ENV.fetch("FAKE_HERDR_FILE")
  state = JSON.parse(File.read(file))
  File.open(ENV.fetch("FAKE_HERDR_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
  verb = ARGV.first(2).join(" ")
  if ENV["FAKE_HERDR_FAIL"] == verb
    warn "PRIVATE-REQUEST"
    exit 1
  end
  if ENV["FAKE_HERDR_BAD"] == verb
    puts "PRIVATE-REQUEST"
    exit
  end
  case verb
  when "status"
    puts(ENV["FAKE_HERDR_OFF"] ? "status: stopped" : "status: running")
    exit
  when "tab list" then result = { "tabs" => state["tabs"] }
  when "pane list" then result = { "panes" => state["panes"] }
  when "pane process-info"
    names = state.fetch("running", []).include?(ARGV.last) ? ["codex"] : ["zsh"]
    result = { "process_info" => { "foreground_processes" => names.map { |n| { "name" => n } } } }
  when "tab create"
    tab = { "tab_id" => "t1", "label" => ARGV[ARGV.index("--label") + 1] }
    pane = { "pane_id" => "p1", "tab_id" => "t1" }
    state["tabs"] << tab
    state["panes"] << pane
    result = { "tab" => tab, "root_pane" => pane }
  when "pane split"
    base = state["panes"].find { |p| p["pane_id"] == ARGV[ARGV.index("--pane") + 1] }
    pane = { "pane_id" => "p#{state['panes'].size + 1}", "tab_id" => base.fetch("tab_id") }
    state["panes"] << pane
    result = { "pane" => pane }
  when "pane rename"
    state["panes"].find { |p| p["pane_id"] == ARGV[2] }["label"] = ARGV[3]
    result = {}
  when "pane run"
    # 起動の依頼だけを記録する。実行は test 本体が zsh で行う。
    result = {}
  else abort "unexpected fake herdr command"
  end
  File.write(file, JSON.generate(state))
  puts JSON.generate("result" => result)
FAKE
ENV["FAKE_CODEX_FILE"] = File.join(ROOT, "codex.json")
write_exec(File.join(BIN, "codex"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  case ARGV
  when ["--version"] then puts "codex-cli 0.156.0"
  when ["exec", "--help"]
    exit 1 if ENV["FAKE_CODEX_NO_HELP"]
    puts '--sandbox workspace-write --config --disable --ignore-user-config --ignore-rules --output-last-message --add-dir `-`'
  when ["features", "list"]
    %w[apps computer_use browser_use].each { |n| puts "#{n}  stable  true" }
  else
    File.write(ENV.fetch("FAKE_CODEX_FILE"), JSON.generate("argv" => ARGV, "cwd" => Dir.pwd, "stdin" => STDIN.read))
    File.write(ARGV[ARGV.index("-o") + 1], "fixture result\n")
    puts "fixture stdout"
    warn "fixture stderr"
    exit ENV.fetch("FAKE_CODEX_EXIT", "0").to_i
  end
FAKE
ENV["PATH"] = BIN + File::PATH_SEPARATOR + ENV.fetch("PATH")
ENTRY = File.join(DEPLOY, "personal-codex-worker-run")

def run_cmd(*argv, **opts)
  out, err, status = Open3.capture3(*argv, **opts)
  assert(status.success?, "command failed: #{argv.first(3).inspect}: #{err}")
  out
end

def git(repo, *args)
  run_cmd(REAL_GIT, "-C", repo, *args).strip
end

ORIGIN = File.join(ROOT, "origin")
MAIN = File.join(ROOT, %q(main ' "quote" $(touch INJECTED) `touch BACKTICK`))
run_cmd(REAL_GIT, "init", "-q", ORIGIN)
File.write(File.join(ORIGIN, "base.txt"), "base\n")
git(ORIGIN, "add", ".")
git(ORIGIN, "commit", "-qm", "base")
BASE = git(ORIGIN, "rev-parse", "HEAD")
run_cmd(REAL_GIT, "clone", "-q", "--no-hardlinks", ORIGIN, MAIN)
git(MAIN, "switch", "-qc", "orchestrator")
File.write(File.join(MAIN, "local.txt"), "not origin main\n")
git(MAIN, "add", ".")
git(MAIN, "commit", "-qm", "local only")
FileUtils.mkdir_p(File.join(MAIN, ".agent-packets"))
REQUEST = "\n  PRIVATE-REQUEST\t\n\n### 内容\n文字列を保つ\n\n"
PACKET = File.join(MAIN, ".agent-packets", "7.md")
CLONE = MAIN + "-clones/7"

def reset_packet(fields = "", request = REQUEST)
  File.write(PACKET, "---\nissue: 7\ntitle: packet\nstate: open\nworker: codex\nupdated: 2026-01-01T00:00:00+09:00\n#{fields}---\n## 依頼\n#{request}## 結果\n\n## 次の入口\n\nnext\n")
end

def reset_herdr(state = { "tabs" => [], "panes" => [] })
  File.write(ENV.fetch("FAKE_HERDR_FILE"), JSON.generate(state))
  File.write(ENV.fetch("FAKE_HERDR_LOG"), "")
  File.write(ENV.fetch("FAKE_GIT_LOG"), "")
end

def events
  File.readlines(ENV.fetch("FAKE_HERDR_LOG")).map { |l| JSON.parse(l) }
end

def launch(expected = 0, env = {}, args = [], explicit: nil)
  argv = explicit || ["launch", "--repo", MAIN, "--issue", "7", *args]
  out, err, status = Open3.capture3(env, [ENTRY, ENTRY], *argv, chdir: MAIN)
  assert(status.exitstatus == expected, "launch exit #{status.exitstatus}, wanted #{expected}: #{out} #{err}")
  assert(out.lines.size == 1, "one JSON line")
  assert(!out.include?("PRIVATE-REQUEST") && !err.include?("PRIVATE-REQUEST"), "request must not leak")
  JSON.parse(out)
end

def blocked(at, code, env = {}, args = [])
  before = events.count { |e| e.first(2) == %w[pane run] }
  result = launch(1, env, args)
  assert(result["status"] == "BLOCKED" && result["blocked_at"] == at && result["reason_code"] == code, "block category: #{result}")
  assert(events.count { |e| e.first(2) == %w[pane run] } == before, "blocked must not run pane")
  result
end

reset_packet
reset_herdr
# 入力は何も作る前に拒否する。
[ ["--issue", "0"], ["--issue", "x"], ["--round", "-1"], ["--branch", "bad..ref"],
  ["--repo", "relative"], ["--repo", ORIGIN + "/.git"], ["--unknown", "x"] ].each do |args|
  base = { "--repo" => MAIN, "--issue" => "7" }.merge(Hash[*args])
  result = launch(2, {}, [], explicit: ["launch", *base.to_a.flatten])
  assert(result["phase"] == "input" && !result["packet"]["written"], "input shape")
end
assert(!File.exist?(CLONE) && !File.exist?(ENV["XDG_STATE_HOME"]), "invalid input creates nothing")
launch(2, {}, ["--issue", "7"])
launch(2, {}, [], explicit: [])
launch(2, {}, [], explicit: ["collect"])
linked = File.join(ROOT, "linked-worktree")
git(MAIN, "worktree", "add", "--detach", "-q", linked, "HEAD")
launch(2, {}, [], explicit: ["launch", "--repo", linked, "--issue", "7"])
blocked("preflight", "gh-repo", { "GH_REPO" => "different/repo" })
File.unlink(PACKET)
blocked("authorization", "packet-missing")
reset_packet("", " \n")
blocked("authorization", "request-empty")
reset_packet("branch: feat/7-test\n", REQUEST + "## sample heading\nPRIVATE-REQUEST trailing\n")
before_packet = File.binread(PACKET)
result = blocked("authorization", "request-empty")
assert(result["phase"] == "packet" && !result["packet"]["written"], "unknown heading rejected while reading")
assert(File.binread(PACKET) == before_packet && !File.exist?(CLONE), "unknown heading creates no clone or record")
reset_packet
File.write(PACKET, File.read(PACKET).sub("state: open", "state: done"))
blocked("authorization", "packet-state")
reset_packet
File.write(File.join(MAIN, ".agent-packets", "8.md"), "broken\n")
blocked("launch-record", "packet-list")
File.unlink(File.join(MAIN, ".agent-packets", "8.md"))
blocked("launch-path", "workspace", { "HERDR_WORKSPACE_ID" => "" })
blocked("launch-path", "herdr-response", { "FAKE_HERDR_BAD" => "pane list" })
blocked("authorization", "branch")
reset_packet("branch: feat/7-other\n")
blocked("authorization", "branch", {}, ["--branch", "feat/7-test"])
reset_packet

first = launch(0, {}, ["--branch", "feat/7-test"])
assert(first["status"] == "STARTED" && first["packet"] == { "written" => true, "record" => "run" }, "started shape")
assert(first["pane_label"] == "worker-7" && first["round_pane"] == false, "first pane")
run = first.fetch("run_dir")
assert(File.basename(run).match?(/\A7\.[0-9a-f]{6}\z/) && first["nonce"].match?(/\A[0-9a-f]{16}\z/), "run and nonce")
assert(File.stat(File.dirname(run)).mode & 0777 == 0700, "run base mode")
assert(git(CLONE, "rev-parse", "HEAD") == BASE, "new branch starts at origin main, not local checkout")
assert(git(CLONE, "branch", "--show-current") == "feat/7-test", "selected branch")
assert(git(CLONE, "config", "maintenance.auto") == "false" && git(CLONE, "config", "gc.auto") == "0", "maintenance config")
assert(File.binread(File.join(run, "brief.md")).include?(REQUEST.b), "request bytes preserved")
assert(File.read(PACKET).include?("run: #{run.to_json}") && File.read(PACKET).include?("tab: \"#7\""), "packet record")
assert(events.include?(["tab", "create", "--workspace", "ws-test", "--cwd", CLONE, "--label", "#7", "--no-focus"]), "tab create argv")
assert(events.include?(["pane", "rename", "p1", "worker-7"]), "pane rename argv")
assert(File.read(File.join(run, "tab-id")).strip == "t1" && File.read(File.join(run, "pane-id")).strip == "p1", "ID files")

# pane shell と run script の両方を通し、二段の literal 化を検証する。
command = events.find { |e| e.first(2) == %w[pane run] }.last
run_cmd("zsh", "-c", command)
observed = JSON.parse(File.read(ENV.fetch("FAKE_CODEX_FILE")))
pf = JSON.parse(File.read(File.join(run, "preflight.json")))
expected = pf.fetch("launch_argv").drop(1).map { |a| a == "<run dir>/result.md" ? File.join(run, "result.md") : a }
assert(observed["argv"] == expected, "argv identical to preflight element by element")
assert(observed["cwd"] == File.realpath(CLONE), "physical cwd")
assert(observed["stdin"].b == File.binread(File.join(run, "brief.md")), "stdin brief")
assert(File.read(File.join(run, "done.txt")) == "CODEX-WORKER-DONE-#{first['nonce']} exit=0\n", "nonce sentinel")
assert(File.read(File.join(run, "codex.log")).include?("fixture stderr"), "stderr tee")
assert(!File.exist?(File.join(CLONE, "INJECTED")) && !File.exist?(File.join(CLONE, "BACKTICK")), "paths not evaluated")
_out, _err, status = Open3.capture3({ "FAKE_CODEX_EXIT" => "17" }, "zsh", File.join(run, "run.zsh"))
assert(status.exitstatus == 17 && File.read(File.join(run, "done.txt")).end_with?("exit=17\n"), "codex pipeline exit preserved")
assert(blocked("launch-record", "collect-required")["run_dir"] == run, "same issue returns its recorded run")
File.unlink(File.join(run, "done.txt"))
state = JSON.parse(File.read(ENV.fetch("FAKE_HERDR_FILE")))
state["running"] = ["p1"]
reset_herdr(state)
assert(launch(3)["status"] == "RUNNING", "same issue running")
state["running"] = []
reset_herdr(state)
blocked("launch-record", "run-unconfirmed")
blocked("launch-record", "run-unconfirmed", { "FAKE_HERDR_BAD" => "pane process-info" })

# 完了の転記済み packet を fixture として用意する。collect は呼ばない。
reset_packet("branch: feat/7-test\nlast_run: #{run.to_json}\npr: 17\n")
round = launch(0, {}, ["--round", "2"])
assert(round["round_pane"] && round["pane_label"] == "worker-7-r2", "round pane naming")
assert(events.include?(["pane", "split", "--pane", "p1", "--direction", "down", "--cwd", CLONE, "--no-focus"]), "split argv")
assert(File.file?(File.join(round["run_dir"], "clone-status.txt")), "reuse status retained")
assert(File.read(File.join(round["run_dir"], "brief.md")).start_with?("この起動は修正 round 2 (PR #17)"), "round brief")
assert(!File.read(PACKET).include?("last_run:"), "run-start removes last_run")

# snapshot 不一致では clone に git を一度も実行しない。
reset_packet("branch: feat/7-test\nlast_run: #{round['run_dir'].to_json}\n")
config = File.binread(File.join(CLONE, ".git", "config"))
File.open(File.join(CLONE, ".git", "config"), "a") { |f| f.puts "# changed" }
File.write(ENV.fetch("FAKE_GIT_LOG"), "")
blocked("clone", "snapshot-mismatch")
trace = File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |l| JSON.parse(l) }
assert(trace.none? { |a| a.include?(CLONE) }, "snapshot failure never calls git in clone")
File.binwrite(File.join(CLONE, ".git", "config"), config)
reset_packet("branch: feat/7-test\n")
blocked("clone", "snapshot-untraceable")
reset_packet("branch: feat/7-test\nlast_run: #{(ROOT + '/missing-run').to_json}\n")
blocked("clone", "snapshot-untraceable")
reset_packet("branch: feat/7-test\nrun: #{(ROOT + '/missing').to_json}\ntab: \"#7\"\n")
blocked("launch-record", "run-missing")

# 他の Issue の未回収と workspace の foreground は別に検査する。
reset_packet("branch: feat/7-test\nrun: #{round['run_dir'].to_json}\ntab: \"#7\"\n")
File.write(PACKET, File.read(PACKET).sub("state: open", "state: blocked"))
other = File.join(MAIN, ".agent-packets", "8.md")
File.write(other, File.read(PACKET).sub("issue: 7", "issue: 8").sub("state: blocked", "state: open")
                              .sub(round['run_dir'].to_json, run.to_json).sub('#7', '#8'))
[true, false].each do |running|
  state["running"] = running ? ["p1"] : []
  reset_herdr(state)
  result = running ? blocked("launch-path", "worker-running") : blocked("launch-record", "run-unconfirmed")
  assert(result["phase"] == "records" && result["issue"] == 7, "other issue stops in records")
  assert(result["other_issue"] == 8 && result["other_run_dir"] == run, "identify blocking issue and run")
  assert(!result.key?("run_dir") && !result["packet"]["written"], "other issue never reports own run")
end
# blocked の他 Issue に unfinished の記録があっても起動を妨げない。
File.write(other, File.read(other).sub("state: open", "state: blocked"))
assert(!File.exist?(File.join(run, "done.txt")), "other blocked run remains unfinished")
assert(launch["status"] == "STARTED", "other blocked issue permits launch")
File.unlink(other)
reset_packet("branch: feat/7-test\nlast_run: #{round['run_dir'].to_json}\n")
state["running"] = ["p1"]
reset_herdr(state)
blocked("launch-path", "worker-running")
state["running"] = []
reset_herdr(state)
blocked("launch-path", "herdr-response", { "FAKE_HERDR_BAD" => "pane process-info" })

# preflight の実 capability failure、run directory の書込境界。
result = blocked("preflight", "preflight", { "FAKE_CODEX_NO_HELP" => "1" })
assert(result["dependency_exit"] == 1, "dependency exit preserved")
result = blocked("launch-path", "writable-run", { "XDG_STATE_HOME" => ENV.fetch("TMPDIR") })
assert(!result["packet"]["written"], "writable run not recorded")

# 成果物の保存失敗は、起動記録を残す前に止まる。
write_fault = File.join(ROOT, "artifact-write-fault.rb")
File.write(write_fault, <<~'RUBY')
  module ArtifactWriteFault
    def binwrite(path, *args)
      raise Errno::EACCES if File.basename(path) == ENV["FAIL_ARTIFACT"]
      super
    end
    def write(path, *args)
      raise Errno::EACCES if File.basename(path) == ENV["FAIL_ARTIFACT"]
      super
    end
  end
  File.singleton_class.prepend(ArtifactWriteFault)
RUBY
%w[brief.md run.zsh].each do |artifact|
  before_packet = File.binread(PACKET)
  result = blocked("launch-path", "io", { "RUBYOPT" => "-r#{write_fault}", "FAIL_ARTIFACT" => artifact })
  assert(result["phase"] == "artifacts" && !result["packet"]["written"], "artifact failure before record #{artifact}")
  assert(File.binread(PACKET) == before_packet, "artifact failure leaves packet unchanged #{artifact}")
  assert(!File.exist?(File.join(result.fetch("run_dir"), artifact)), "failed artifact absent #{artifact}")
end

# packet 更新失敗、更新成功後の読み直し失敗を CLI 境界で注入する。
packet_cli = File.join(DEPLOY, "personal-packet")
File.rename(packet_cli, packet_cli + "-real")
write_exec(packet_cli, <<~'WRAPPER')
  #!/usr/bin/env ruby
  require "json"
  require "open3"
  if ARGV.first == "worker-update" && ENV["FAKE_PACKET_FAIL"]
    warn "PRIVATE-REQUEST"
    exit 1
  end
  out, err, status = Open3.capture3(File.join(__dir__, "personal-packet-real"), *ARGV, stdin_data: STDIN.read)
  if ARGV.first == "worker-update" && status.success? && ENV["FAKE_PACKET_BAD_READ"]
    File.write(ENV.fetch("FAKE_PACKET_MARK"), "written")
  end
  if ARGV.first == "list" && ENV["FAKE_PACKET_BAD_READ"] && File.exist?(ENV.fetch("FAKE_PACKET_MARK"))
    puts '[]'
    exit
  end
  print out
  warn err unless err.empty?
  exit status.exitstatus
WRAPPER
result = blocked("launch-record", "packet-update", { "FAKE_PACKET_FAIL" => "1" })
assert(!result["packet"]["written"], "update failure has no record")
result = blocked("launch-record", "run-record", { "FAKE_PACKET_BAD_READ" => "1", "FAKE_PACKET_MARK" => File.join(ROOT, "packet-mark") })
assert(result["packet"]["written"] && File.read(PACKET).include?(result["run_dir"]), "readback failure retains record")
FileUtils.cp(packet_cli + "-real", packet_cli)

# herdr の後段失敗では起動の記録を残し、pane を閉じない。
%w[duplicate foreign no-panes wrong-label create split rename run].each do |failure|
  reset_packet("branch: feat/7-test\nlast_run: #{round['run_dir'].to_json}\n")
  s = { "tabs" => [{ "tab_id" => "t1", "label" => "#7" }],
        "panes" => [{ "tab_id" => "t1", "pane_id" => "p1", "label" => "worker-7" }] }
  env = {}
  case failure
  when "duplicate" then s["tabs"] << { "tab_id" => "t2", "label" => "#7" }
  when "foreign"
    s["tabs"][0]["tab_id"] = "foreign"
    s["panes"][0]["tab_id"] = "foreign"
  when "no-panes" then s["panes"] = []
  when "wrong-label" then s["panes"][0]["label"] = "user"
  when "create" then s = { "tabs" => [], "panes" => [] }; env["FAKE_HERDR_FAIL"] = "tab create"
  else env["FAKE_HERDR_FAIL"] = "pane #{failure}"
  end
  reset_herdr(s)
  # pane run は失敗する呼び出し自体が記録されるため blocked helper を使わない。
  result = launch(1, env)
  assert(result["blocked_at"] == "launch-path" && result["packet"]["written"], "post-record herdr failure #{failure}")
  assert(File.read(PACKET).include?(result["run_dir"]), "record retained #{failure}")
  assert(events.none? { |e| e.include?("close") }, "never close panes")
  if %w[duplicate foreign no-panes wrong-label].include?(failure)
    assert(result["reason_code"] == "tab-ownership", "ownership category #{failure}")
    assert(events.none? { |e| [%w[tab create], %w[pane split], %w[pane rename], %w[pane run]].include?(e.first(2)) }, "unowned tab never changed #{failure}")
  end
end

# blocked の run は再起動できる。pane の最大番号から次を選ぶ。
reset_packet("branch: feat/7-test\nrun: #{round['run_dir'].to_json}\ntab: \"#7\"\n")
File.write(PACKET, File.read(PACKET).sub("state: open", "state: blocked"))
reset_herdr("tabs" => [{ "tab_id" => "t1", "label" => "#7" }],
            "panes" => [{ "tab_id" => "t1", "pane_id" => "p1", "label" => "worker-7-r9" }])
restart = launch
assert(restart["pane_label"] == "worker-7-r10" && File.read(PACKET).include?("state: open"), "blocked restart")

# commit の前提をそれぞれ崩す。snapshot で止めないよう main の global 設定を使う。
reset_packet("branch: feat/7-test\nlast_run: #{restart['run_dir'].to_json}\n")
config_file = CONFIG_FILE
saved = File.read(config_file)
[ saved.sub("name = Test Worker", "name ="), saved.sub("email = worker@example.invalid", "email ="),
  saved.sub("hooksPath = #{HOOKS}", "hooksPath =") ].each do |bad|
  File.write(config_file, bad)
  blocked("clone", "commit-prerequisite")
end
File.write(config_file, saved)
File.chmod(0644, File.join(HOOKS, "commit-msg"))
blocked("clone", "commit-prerequisite")
File.chmod(0755, File.join(HOOKS, "commit-msg"))
File.chmod(0644, File.join(DEPLOY, "personal-ai-trailer-gate"))
blocked("clone", "commit-prerequisite")
File.chmod(0755, File.join(DEPLOY, "personal-ai-trailer-gate"))
other_hooks = File.join(ROOT, "other-hooks")
FileUtils.mkdir_p(other_hooks)
%w[pre-commit commit-msg].each do |name|
  write_exec(File.join(other_hooks, name), "#!/bin/sh\nexit 0\n")
end
main_config = File.binread(File.join(MAIN, ".git", "config"))
git(MAIN, "config", "core.hooksPath", other_hooks)
blocked("clone", "commit-prerequisite")
File.binwrite(File.join(MAIN, ".git", "config"), main_config)

# preflight の失敗と、成功でも契約外の argv を返した場合。
pf_cli = File.join(DEPLOY, "personal-codex-worker-preflight")
File.rename(pf_cli, pf_cli + "-real")
write_exec(pf_cli, <<~'WRAPPER')
  #!/usr/bin/env ruby
  require "json"
  require "open3"
  out, err, status = Open3.capture3(File.join(__dir__, "personal-codex-worker-preflight-real"), *ARGV)
  if ARGV.first == "--clone"
    case ENV["FAKE_PREFLIGHT"]
    when "exit2" then warn "PRIVATE-REQUEST"; exit 2
    when "bad-json" then puts "PRIVATE-REQUEST"; exit
    when "wrong-first", "wrong-last", "non-string", "not-array"
      doc = JSON.parse(out)
      case ENV["FAKE_PREFLIGHT"]
      when "wrong-first" then doc["launch_argv"][0] = "other"
      when "wrong-last" then doc["launch_argv"][-1] = "prompt"
      when "non-string" then doc["launch_argv"][2] = 7
      when "not-array" then doc["launch_argv"] = "codex exec"
      end
      out = JSON.generate(doc)
    end
  end
  print out
  warn err unless err.empty?
  exit status.exitstatus
WRAPPER
result = blocked("preflight", "preflight", { "FAKE_PREFLIGHT" => "exit2" })
assert(result["dependency_exit"] == 2, "preflight exit 2")
%w[bad-json wrong-first wrong-last non-string not-array].each do |variant|
  result = blocked("preflight", "launch-argv", { "FAKE_PREFLIGHT" => variant })
  assert(result["dependency_exit"] == 0, "invalid successful preflight retains exit")
end
FileUtils.cp(pf_cli + "-real", pf_cli)

result = blocked("launch-path", "herdr-response", { "FAKE_HERDR_OFF" => "1" })
assert(result["packet"]["written"], "unavailable herdr preserves record")
reset_packet("branch: feat/7-test\nlast_run: #{restart['run_dir'].to_json}\n")
blocked("launch-path", "run-directory", { "XDG_STATE_HOME" => "relative" })

# clone の local branch を優先し、その先端を保つ。
File.write(File.join(CLONE, "worker.txt"), "worker commit\n")
git(CLONE, "add", "worker.txt")
git(CLONE, "commit", "-qm", "worker fixture")
local_tip = git(CLONE, "rev-parse", "HEAD")
reset_herdr
local = launch
assert(git(CLONE, "rev-parse", "HEAD") == local_tip, "local branch tip preserved")

# 別の新規 clone では main の同名 branch (clone から見た origin) を使う。
File.rename(CLONE, File.join(ROOT, "previous-clone"))
git(MAIN, "branch", "feat/7-test", "orchestrator")
remote_tip = git(MAIN, "rev-parse", "refs/heads/feat/7-test")
reset_packet("branch: feat/7-test\n")
reset_herdr
remote = launch
assert(git(CLONE, "rev-parse", "HEAD") == remote_tip, "origin branch tip selected")
assert(git(CLONE, "branch", "--show-current") == "feat/7-test", "origin branch selected")

# packet check の拒否と dependency の欠損。
git(MAIN, "add", "-f", ".agent-packets/7.md")
blocked("launch-record", "packet-check")
help = run_cmd(ENTRY, "--help")
assert(help.include?("collect・retry-empty・check") && help.include?("--round"), "help scope")
puts "ok: codex-worker-run self-test (#{$count} checks)"
