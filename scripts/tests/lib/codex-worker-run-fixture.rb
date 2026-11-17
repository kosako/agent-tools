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
  if ENV["FAKE_GIT_FAIL"] && ARGV.include?(ENV["FAKE_GIT_FAIL"]) && ARGV[1] == ENV["FAKE_GIT_FAIL_ROOT"]
    warn "PRIVATE-REQUEST"
    exit 1
  end
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
  when "pane read"
    print ENV.fetch("FAKE_PANE_OUTPUT", "PRIVATE-PANE\n")
    exit
  when "pane wait-output"
    if ENV["FAKE_WAIT_DONE"]
      File.write(File.join(ENV.fetch("FAKE_WAIT_DONE"), "done.txt"), "#{ARGV[ARGV.index('--match') + 1]} exit=0\n")
    end
    exit 1
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
  yield(out, err) if block_given?
  JSON.parse(out)
end

def blocked(at, code, env = {}, args = [], &block)
  before = events.count { |e| e.first(2) == %w[pane run] }
  result = launch(1, env, args, &block)
  assert(result["status"] == "BLOCKED" && result["blocked_at"] == at && result["reason_code"] == code, "block category: #{result}")
  assert(events.count { |e| e.first(2) == %w[pane run] } == before, "blocked must not run pane")
  result
end
