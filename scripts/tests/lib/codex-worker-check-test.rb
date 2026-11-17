# frozen_string_literal: true
require_relative "codex-worker-run-fixture"

# Only the three permitted, read-only gh commands exist in this fixture.
ENV["FAKE_CHECK_LOG"] = File.join(ROOT, "check.jsonl")
write_exec(File.join(BIN, "gh"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  File.open(ENV.fetch("FAKE_CHECK_LOG"), "a") { |f| f.puts JSON.generate(["gh", *ARGV]) }
  case ARGV
  when %w[repo view --json nameWithOwner]
    exit 1 if ENV["FAKE_GH_VIEW_FAIL"]
    puts JSON.generate("nameWithOwner" => ENV.fetch("FAKE_GH_SLUG", "owner/project"))
  when %w[api user]
    exit 1 if ENV["FAKE_OWNER_FAIL"]
    print ENV.fetch("FAKE_USER_JSON", '{"login":"owner"}')
  when %w[api repos/owner/project]
    print ENV.fetch("FAKE_OWNER_JSON", '{"owner":{"type":"User","login":"owner"}}')
  else
    abort "unexpected gh command"
  end
FAKE
# Select late git failures without breaking packet reads or the earlier trailer scan.
git_wrapper = File.read(File.join(BIN, "git"))
write_exec(File.join(BIN, "git"), git_wrapper.sub('exec(ENV.fetch("FAKE_GIT_REAL"), *ARGV)', <<~'FAKE'))
  step = ENV["FAKE_CHECK_GIT_STEP"]
  fail_here = case step
              when "origin-fetch" then ARGV[2, 2] == %w[fetch origin]
              when "head" then ARGV[2, 2] == %w[rev-parse --verify] && ARGV.last.start_with?("refs/heads/")
              when "base" then ARGV[2, 3] == %w[rev-parse --verify --end-of-options]
              when "messages" then ARGV.include?("--format=%B")
              when "patches" then ARGV.include?("-p")
              else false
              end
  if fail_here
    warn "PRIVATE-BODY"
    exit 1
  end
  exec(ENV.fetch("FAKE_GIT_REAL"), *ARGV)
FAKE
%w[personal-ja-style-check personal-work-marker-check personal-public-safety-gate].each do |name|
  FileUtils.cp(File.join(SOURCE, "shared/scripts", name + ".rb"), File.join(DEPLOY, name + "-real"))
  File.chmod(0755, File.join(DEPLOY, name + "-real"))
  write_exec(File.join(DEPLOY, name), <<~'WRAPPER')
    #!/usr/bin/env ruby
    require "json"
    name = File.basename(__FILE__)
    File.open(ENV.fetch("FAKE_CHECK_LOG"), "a") { |f| f.puts JSON.generate([name, *ARGV]) }
    if name == "personal-public-safety-gate"
      if ENV["FAKE_GATE_WARNING"]
        warn "public-safety-gate: warning: PRIVATE-BODY"
        exit 0
      end
      if ENV["FAKE_GATE_FAIL"]
        warn "PRIVATE-BODY"
        exit 2
      end
    end
    exec(File.join(File.dirname(__FILE__), name + "-real"), *ARGV)
  WRAPPER
end
# Local patterns make each public material independently detectable, without real secrets.
FileUtils.mkdir_p(File.join(ENV.fetch("HOME"), ".config/agent-tools"))
File.write(File.join(ENV.fetch("HOME"), ".config/agent-tools/public-safety-patterns.local"), "publish-denied-value\n")
BODY = File.join(ROOT, "body ' $(touch BODY-INJECTED).md")
File.write(BODY, "PRIVATE-BODY\nCloses #7\n")
TRAILER = "Co-Authored-By: Codex <codex@example.invalid>"

reset_packet
reset_herdr
started = launch(0, {}, ["--branch", "feat/7-initial"])
RUN = started.fetch("run_dir")
# check only uses last_run and the preflight snapshot, not launch.json or done.txt.
File.unlink(File.join(RUN, "launch.json"))
git(MAIN, "remote", "set-url", "--push", "origin", "https://github.com/owner/project.git")

$branch_number = 0
def branch
  $branch_number += 1
  name = "feat/7-check-#{$branch_number}"
  git(CLONE, "switch", "-qc", name, BASE)
  reset_packet("branch: #{name}\nlast_run: #{RUN.to_json}\n")
  name
end

def commit(message = "implementation\n\n#{TRAILER}", content = "safe\n")
  File.write(File.join(CLONE, "work.txt"), content)
  git(CLONE, "add", "work.txt")
  git(CLONE, "commit", "--allow-empty", "-qm", message)
  git(CLONE, "rev-parse", "HEAD")
end

def check_events
  File.readlines(ENV.fetch("FAKE_CHECK_LOG")).map { |line| JSON.parse(line) }
end

def git_events
  File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
end

def invoke_check(expected = 0, env = {}, title: "検査を追加する (#7)", body: BODY)
  before = File.binread(PACKET)
  main_head = git(MAIN, "rev-parse", "HEAD")
  # Check must never write into the clone's .git, including refs and FETCH_HEAD.
  snapshot = lambda do
    Dir.glob(File.join(CLONE, ".git/**/*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sort.map do |p|
      [p, File.stat(p).mode, Digest::SHA256.file(p).hexdigest]
    end
  end
  clone_before = snapshot.call
  File.write(ENV.fetch("FAKE_GIT_LOG"), "")
  File.write(ENV.fetch("FAKE_CHECK_LOG"), "")
  result = launch(expected, env, [], explicit: ["check", "--repo", MAIN, "--issue", "7", "--title", title, "--body-file", body]) do |out, err|
    assert(err.empty?, "check stderr stays empty")
    %w[PRIVATE-BODY publish-denied-value].each do |value|
      assert(!out.include?(value) && !err.include?(value), "private material does not leak")
    end
  end
  assert(File.binread(PACKET) == before, "check never changes packet")
  assert(git(MAIN, "rev-parse", "HEAD") == main_head, "main checkout remains unchanged")
  assert(snapshot.call == clone_before, "clone git is read-only")
  assert(git_events.none? { |a| a.include?("push") || a.include?("checkout") || a.include?("switch") }, "no push or checkout")
  allowed = [%w[gh repo view --json nameWithOwner], %w[gh api user], %w[gh api repos/owner/project]]
  assert(check_events.select { |a| a.first == "gh" }.all? { |a| allowed.include?(a) }, "gh is limited to the permitted reads")
  result
end

def failure(at, code, env = {}, **opts)
  result = invoke_check(1, env, **opts)
  assert(result["status"] == "BLOCKED" && result["blocked_at"] == at && result["reason_code"] == code,
         "classification #{result} at #{caller.first}")
  assert(result["packet"] == { "written" => false }, "blocked check records no update")
  result
end

def no_fetch
  assert(git_events.none? { |a| a.include?("fetch") }, "no fetch after earlier failure")
  assert(check_events.empty?, "no gates or gh after earlier failure")
end

name = branch
head = commit
result = invoke_check
assert(result == { "status" => "READY", "issue" => 7, "branch" => name, "base_oid" => BASE,
  "head_oid" => head, "commits" => 1, "slug" => "owner/project", "style_findings" => 0,
  "marker" => "ok", "run_dir" => RUN }, "READY fields")
assert(git(MAIN, "rev-parse", "refs/heads/#{name}") == head, "branch imported into main")
assert(git_events.include?(["-C", MAIN, "fetch", "--no-tags", "--", CLONE, "refs/heads/#{name}:refs/heads/#{name}"]), "fetch uses explicit unforced refspec")
assert(check_events.map(&:first) == %w[personal-ja-style-check personal-public-safety-gate gh gh gh personal-work-marker-check], "gate and destination order")
assert(File.file?(File.join(RUN, "snapshot-verify.txt")), "snapshot diagnostic retained")
# Review state and several NUL-delimited records, including multiple coauthors.
head = commit("二つ目\n\nCo-Authored-By: Human <human@example.invalid>\n#{TRAILER}")
head = commit("three\n\n#{TRAILER}\nCo-Authored-By: Codex Extra <extra@example.invalid>")
File.write(PACKET, File.read(PACKET).sub("state: open", "state: review"))
result = invoke_check
assert(result["commits"] == 3 && result["head_oid"] == head, "all NUL-delimited commits parsed")
raw = run_cmd(REAL_GIT, "-C", MAIN, "log", "-z", "--format=%H%x00%(trailers:key=Co-Authored-By,valueonly)", "#{BASE}..#{head}")
assert(raw.count("\0") == 6, "fixture contains NUL delimiters")
# The base follows a newly fetched origin/main, even when the local main is stale.
parent = git(CLONE, "rev-parse", "HEAD^")
git(ORIGIN, "fetch", "--no-tags", CLONE, "refs/heads/#{name}:refs/heads/check-base")
git(ORIGIN, "update-ref", "refs/heads/main", parent, BASE)
result = invoke_check
assert(result["base_oid"] == parent && result["commits"] == 1, "base uses refreshed origin/main")
git(ORIGIN, "update-ref", "refs/heads/main", BASE, parent)

failure("preflight", "gh-repo", { "GH_REPO" => "owner/other" })
no_fetch
saved_packet = File.read(PACKET)
["state: blocked", "state: closed"].each do |state|
  File.write(PACKET, saved_packet.sub("state: review", state))
  result = invoke_check(1)
  assert(result["blocked_at"] == "launch-record", "invalid state blocks at launch-record")
  no_fetch
end
File.write(PACKET, saved_packet.sub(/^last_run:.*\n/, ""))
failure("launch-record", "check-record")
no_fetch
File.write(PACKET, saved_packet.sub("last_run:", "run:").sub("state: review", "state: open").sub("---\n## 依頼", "tab: \"#7\"\n---\n## 依頼"))
failure("launch-record", "check-record")
no_fetch
File.write(PACKET, saved_packet)

["", "\xff".b, " \n"].each do |text|
  invalid = File.join(ROOT, "invalid-body")
  File.binwrite(invalid, text)
  invoke_check(2, {}, body: invalid)
  no_fetch
end
[ROOT, File.join(ROOT, "missing"), File.join(MAIN, "base.txt"), File.join(CLONE, "work.txt")].each do |path|
  invoke_check(2, {}, body: path)
  no_fetch
end
File.symlink(BODY, File.join(ROOT, "body-link"))
invoke_check(2, {}, body: File.join(ROOT, "body-link"))
no_fetch
invoke_check(2, {}, title: "")
no_fetch

# Config mismatch must stop before git is run against the clone or used to fetch.
config = File.join(CLONE, ".git/config")
saved_config = File.join(ROOT, "saved-config")
FileUtils.cp(config, saved_config)
File.open(config, "a") { |f| f.puts "# changed" }
failure("fetch", "snapshot-mismatch")
no_fetch
assert(git_events.none? { |a| a.include?(CLONE) }, "unverified clone never passed to git")
assert(!File.read(File.join(RUN, "snapshot-verify.txt")).empty?, "snapshot failure stderr retained")
FileUtils.cp(saved_config, config)

# Non-fast-forward main branch is preserved. No origin fetch or later inspection.
name = branch
commit
other = git(MAIN, "rev-parse", "HEAD")
git(MAIN, "update-ref", "refs/heads/#{name}", other)
failure("fetch", "fetch")
assert(git(MAIN, "rev-parse", "refs/heads/#{name}") == other, "non-fast-forward branch preserved")
assert(git_events.count { |a| a.include?("fetch") } == 1 && check_events.empty?, "fetch failure stops subsequent stages")

["missing", "#{TRAILER}\nCo-Authored-By: Claude Extra <claude@example.invalid>",
 "#{TRAILER}\nCo-Authored-By: OpenCode (anthropic/model) <oc@example.invalid>"].each do |trailers|
  branch
  commit("invalid\n\n#{trailers}")
  failure("trailer", "trailer")
  assert(check_events.empty?, "trailer stops all publication checks")
end
branch
failure("trailer", "trailer")
branch
commit("first without trailer")
commit
failure("trailer", "trailer")
branch
commit
commit("last without trailer")
failure("trailer", "trailer")

name = branch
commit
side = name + "-side"
git(CLONE, "switch", "-qc", side, BASE)
File.write(File.join(CLONE, "side.txt"), "side\n")
git(CLONE, "add", "side.txt")
git(CLONE, "commit", "-qm", "side\n\n#{TRAILER}")
git(CLONE, "switch", "-q", name)
git(CLONE, "merge", "--no-ff", "-qm", "merge\n\n#{TRAILER}", side)
failure("public-safety", "merge-commit")
assert(check_events.empty?, "merge stops style and gate")
assert(File.read(File.join(RUN, "gate-publish.err")).include?(git(CLONE, "rev-parse", "HEAD")), "merge oid diagnostic retained")

branch
commit
failure("public-safety", "publish-gate", { "FAKE_GATE_FAIL" => "1" })
assert(File.read(File.join(RUN, "gate-publish.err")).include?("PRIVATE-BODY"), "gate stderr saved only in run")
failure("public-safety", "gate-warning", { "FAKE_GATE_WARNING" => "1" })
assert(check_events.none? { |a| a.first == "gh" }, "gate warning prevents gh")
result = invoke_check(0, {}, title: "実装する—検査する (#7)")
assert(result["style_findings"] > 0, "style findings counted without blocking")

# Each public material is checked, even when the cumulative diff is empty.
branch
commit("implementation\n\n#{TRAILER}", "publish-denied-value\n")
failure("public-safety", "publish-gate")
File.unlink(File.join(CLONE, "work.txt"))
git(CLONE, "add", "work.txt")
git(CLONE, "commit", "-qm", "remove\n\n#{TRAILER}")
assert(git(CLONE, "diff", BASE, "HEAD").empty?, "cumulative diff contains no denied value")
failure("public-safety", "publish-gate")
branch
commit("binary\n\n#{TRAILER}", "binary\0publish-denied-value\n")
failure("public-safety", "publish-gate")
branch
commit("publish-denied-value\n\n#{TRAILER}")
failure("public-safety", "publish-gate")
branch
commit
failure("public-safety", "publish-gate", {}, title: "publish-denied-value (#7)")
File.write(BODY, "PRIVATE-BODY publish-denied-value\nCloses #7\n")
failure("public-safety", "publish-gate")
File.write(BODY, "PRIVATE-BODY\nCloses #7\n")
name = "feat/7-publish-denied-value"
git(CLONE, "switch", "-qc", name, BASE)
reset_packet("branch: #{name}\nlast_run: #{RUN.to_json}\n")
commit
failure("public-safety", "publish-gate")

branch
commit
failure("public-safety", "destination", { "FAKE_GH_VIEW_FAIL" => "1" })
failure("public-safety", "destination", { "FAKE_GH_SLUG" => "bad slug" })
["https://github.com/other/project.git", "https://github.com/owner/project.git/", "https://example.invalid/owner/project"].each do |url|
  git(MAIN, "remote", "set-url", "--push", "origin", url)
  failure("public-safety", "destination")
  assert(check_events.none? { |a| a.first(2) == %w[gh api] }, "unverified destination prevents API reads")
end
["https://github.com/owner/project", "git@github.com:owner/project", "ssh://git@github.com/owner/project"].each do |url|
  [url, url + ".git"].each do |accepted|
    git(MAIN, "remote", "set-url", "--push", "origin", accepted)
    assert(invoke_check["status"] == "READY", "all six push URL forms accepted")
  end
end
failure("public-safety", "marker", {}, title: "wrong issue (#8)")
[{ "FAKE_OWNER_JSON" => '{"owner":{"type":"Organization","login":"owner"}}' },
 { "FAKE_OWNER_JSON" => '{"owner":{"type":"User","login":"other"}}' },
 { "FAKE_OWNER_FAIL" => "1" }, { "FAKE_OWNER_JSON" => 'bad json' },
 { "FAKE_USER_JSON" => '{"login":""}' }].each do |env|
  result = invoke_check(0, env, title: "wrong issue (#8)")
  assert(result["marker"] == "skipped", "unknown or non-personal repo skips marker")
  assert(check_events.none? { |a| a.first == "personal-work-marker-check" }, "marker not executed")
end

# Material-producing git failures cannot turn into a successful partial scan.
%w[fetch merge-base rev-parse log diff rev-list].each do |verb|
  result = invoke_check(verb == "rev-parse" ? 2 : 1, { "FAKE_GIT_FAIL" => verb, "FAKE_GIT_FAIL_ROOT" => MAIN })
  next if verb == "rev-parse"
  at = { "fetch" => "fetch", "merge-base" => "trailer", "log" => "trailer", "diff" => "public-safety", "rev-list" => "public-safety" }.fetch(verb)
  assert(result["blocked_at"] == at, "git failure classified")
  assert(check_events.none? { |a| a.first == "personal-public-safety-gate" || a.first == "gh" }, "git failure prevents publication gate and destination")
end
%w[origin-fetch head base messages patches].each do |step|
  at = %w[messages patches].include?(step) ? "public-safety" : "trailer"
  code = at == "trailer" ? "trailer" : "publish-material"
  failure(at, code, { "FAKE_CHECK_GIT_STEP" => step })
  assert(check_events.none? { |a| a.first == "personal-public-safety-gate" || a.first == "gh" }, "late git failure prevents gate and destination")
end
assert(!File.exist?(File.join(MAIN, "INJECTED")) && !File.exist?(File.join(MAIN, "BACKTICK")) &&
  !File.exist?(File.join(MAIN, "BODY-INJECTED")), "path values never execute")
puts "codex-worker-check: #{$count} assertions passed"
