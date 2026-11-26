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
    # 検査の途中 (公開先の確認の間) に packet が変わる形 (#719)
    File.write(ENV.fetch("FAKE_PACKET_PATH"), File.read(ENV["FAKE_GH_VIEW_PACKET"])) if ENV["FAKE_GH_VIEW_PACKET"]
    # 検査の途中に clone が変わる形 (#718)。file を作る、または同じ OID の別の branch に切り替える。
    File.write(ENV["FAKE_GH_VIEW_TOUCH"], "left\n") if ENV["FAKE_GH_VIEW_TOUCH"]
    if (target = ENV["FAKE_GH_VIEW_SWITCH"])
      clone, branch = target.split("\n", 2)
      system(ENV.fetch("FAKE_GIT_REAL"), "-C", clone, "switch", "-qc", branch) || exit(1)
    end
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
  # 取り込みの直前に clone の branch を進める形 (#718。状態を読んだ後に branch が動く)。
  if (moved = ENV["FAKE_CHECK_MOVE_CLONE"]) && ARGV[2] == "fetch" && ARGV.include?(moved)
    system(ENV.fetch("FAKE_GIT_REAL"), "-C", moved, "commit", "--allow-empty", "-qm", "moved\n\nCo-Authored-By: Codex <codex@example.invalid>") || exit(1)
  end
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
        exit(ENV["FAKE_GATE_FAIL"] ? 1 : 0)
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
# check only uses last_run, the preflight snapshot and request.sha256, not launch.json or done.txt.
File.unlink(File.join(RUN, "launch.json"))
REQUEST_RECORD = File.join(RUN, "request.sha256")
assert(File.binread(REQUEST_RECORD) == Digest::SHA256.hexdigest(REQUEST) + "\n", "launch records the request digest")
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

# collect が照合して転記した HEAD の記録 (#718)。この fixture は collect を通さないので、check の直前の HEAD で書く。
# 記録と食い違う形を見る case は、これを通さずに launch を呼ぶ。
def collected!
  File.write(File.join(RUN, "collected-head"), git(CLONE, "rev-parse", "HEAD") + "\n")
end

def check_events
  File.readlines(ENV.fetch("FAKE_CHECK_LOG")).map { |line| JSON.parse(line) }
end

def git_events
  File.readlines(ENV.fetch("FAKE_GIT_LOG")).map { |line| JSON.parse(line) }
end

def invoke_check(expected = 0, env = {}, title: "検査を追加する (#7)", body: BODY, args: [])
  before = File.binread(PACKET)
  main_head = git(MAIN, "rev-parse", "HEAD")
  # Check must never write into the clone's .git, including refs and FETCH_HEAD.
  snapshot = lambda do
    Dir.glob(File.join(CLONE, ".git/**/*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sort.map do |p|
      [p, File.stat(p).mode, Digest::SHA256.file(p).hexdigest]
    end
  end
  collected!
  clone_before = snapshot.call
  File.write(ENV.fetch("FAKE_GIT_LOG"), "")
  File.write(ENV.fetch("FAKE_CHECK_LOG"), "")
  result = launch(expected, env, [], explicit: ["check", "--repo", MAIN, "--issue", "7", "--title", title, "--body-file", body, *args]) do |out, err|
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
# 起動のときの依頼と今の依頼が同じと確かめられなければ、公開に進めない (#719)。
[saved_packet.sub(REQUEST, REQUEST + "足した依頼\n"), saved_packet.sub(REQUEST, REQUEST + "\n"), saved_packet.sub(REQUEST, "書き直した依頼\n")].each do |text|
  File.write(PACKET, text)
  failure("launch-record", "request-changed")
  no_fetch
end
[saved_packet.sub(REQUEST, " \n"), saved_packet.sub(REQUEST, REQUEST + "## 知らない節\n"), saved_packet.sub(REQUEST, REQUEST + "## 依頼\nもう 1 つ\n")].each do |text|
  File.write(PACKET, text)
  failure("launch-record", "check-record")
  no_fetch
end
File.write(PACKET, saved_packet)
digest = Digest::SHA256.hexdigest(REQUEST)
[nil, "", "\n", digest, digest + "\n\n", digest + " \n", digest.upcase + "\n", digest[0, 63] + "\n", "x\n" + digest + "\n"].each do |text|
  text ? File.write(REQUEST_RECORD, text) : File.unlink(REQUEST_RECORD)
  failure("launch-record", "request-unrecorded")
  no_fetch
end
File.write(REQUEST_RECORD, digest + "\n")
# 検査の途中に依頼が変わる、または回収した run が変わると、READY を返さない (#719)。返す直前に packet を読み直す。
# 別の run は依頼の記録が同じなので、run の比較だけが止める。
other_run = RUN + "-other"
FileUtils.mkdir_p(other_run)
FileUtils.cp(REQUEST_RECORD, other_run)
[[saved_packet.sub(REQUEST, REQUEST + "足した依頼\n"), "request-changed"],
 [saved_packet.sub(/^last_run:.*\n/, "last_run: #{JSON.generate(other_run)}\n"), "check-record"]].each do |text, code|
  swap = File.join(ROOT, "packet-swap")
  File.write(swap, text)
  result = launch(1, { "FAKE_GH_VIEW_PACKET" => swap, "FAKE_PACKET_PATH" => PACKET }, [],
                  explicit: ["check", "--repo", MAIN, "--issue", "7", "--title", "検査を追加する (#7)", "--body-file", BODY])
  assert(result.values_at("status", "phase", "blocked_at", "reason_code") == ["BLOCKED", "packet-again", "launch-record", code],
         "a packet changed during check blocks before READY: #{result}")
  assert(File.read(PACKET) == text, "check keeps the packet written during it")
  File.write(PACKET, saved_packet)
end
FileUtils.rm_rf(other_run)
assert(invoke_check["status"] == "READY", "the unchanged packet still reaches READY")

# clone の状態 (#718)。HEAD が branch を指さない、または未 commit の変更が残ると、fetch の前に止まる。
# 両方なら clone-head を先に返す。gitignore された file と空の directory は数えない。変更は消さない。
clean_up = lambda do |name|
  current, = Open3.capture2(REAL_GIT, "-C", CLONE, "symbolic-ref", "-q", "--short", "HEAD")
  git(CLONE, "switch", "-q", name) unless current.strip == name
  git(CLONE, "add", "-A")
  git(CLONE, "commit", "--allow-empty", "-qm", "cleanup\n\n#{TRAILER}")
end
[["K2 branch から外れた HEAD", "clone-head", lambda { git(CLONE, "switch", "-q", "--detach"); commit }],
 ["K2 別の branch", "clone-head", lambda { git(CLONE, "switch", "-qc", "other-#{$branch_number}"); commit }],
 ["K3 untracked", "clone-dirty", lambda { File.write(File.join(CLONE, "left.txt"), "left\n") }],
 ["K3 staged", "clone-dirty", lambda { File.write(File.join(CLONE, "work.txt"), "staged\n"); git(CLONE, "add", "work.txt") }],
 ["K3 unstaged", "clone-dirty", lambda { File.write(File.join(CLONE, "work.txt"), "unstaged\n") }],
 ["K3 unstaged の削除", "clone-dirty", lambda { File.unlink(File.join(CLONE, "work.txt")) }],
 ["K4 両方", "clone-head", lambda { git(CLONE, "switch", "-q", "--detach"); File.write(File.join(CLONE, "left.txt"), "left\n") }]].each do |label, code, setup|
  name = branch
  commit
  setup.call
  before = Dir.glob(File.join(CLONE, "**/*"), File::FNM_DOTMATCH).reject { |p| p.include?("/.git/") }.sort
  failure("fetch", code)
  no_fetch
  after = Dir.glob(File.join(CLONE, "**/*"), File::FNM_DOTMATCH).reject { |p| p.include?("/.git/") }.sort
  assert(after == before, "#{label}: check keeps the clone's files")
  clean_up.call(name)
end
# clone の状態は index を書かずに読む。stat の古い file があると、ふつうの status は index を書き直す (#718)。
name = branch
commit
past = Time.now - 600
File.utime(past, past, File.join(CLONE, "work.txt"))
assert(invoke_check["status"] == "READY", "a stale index stat does not block, and check does not rewrite the index")
# gitignore された file と空の directory だけなら通る (C16、C21)。
name = branch
File.write(File.join(CLONE, ".gitignore"), "*.out\n")
git(CLONE, "add", ".gitignore")
commit
File.write(File.join(CLONE, "test.out"), "generated\n")
Dir.mkdir(File.join(CLONE, "empty-dir"))
assert(invoke_check["status"] == "READY", "ignored files and empty directories do not block")
FileUtils.rm_rf(File.join(CLONE, "empty-dir"))
File.unlink(File.join(CLONE, "test.out"))
# 依頼の照合が先 (K5)。依頼が変わっていれば、clone が汚れていても request-changed。
File.write(File.join(CLONE, "left.txt"), "left\n")
File.write(PACKET, File.read(PACKET).sub(REQUEST, REQUEST + "足した依頼\n"))
failure("launch-record", "request-changed")
no_fetch
File.unlink(File.join(CLONE, "left.txt"))
# 状態を読んだ後に clone の branch が動くと、取り込んだ先端が worker のいた commit と違う (#718)。
check_argv = ["check", "--repo", MAIN, "--issue", "7", "--title", "検査を追加する (#7)", "--body-file", BODY]
name = branch
head = commit
collected!
result = launch(1, { "FAKE_CHECK_MOVE_CLONE" => CLONE }, [], explicit: check_argv)
assert(result.values_at("status", "phase", "blocked_at", "reason_code") == ["BLOCKED", "fetched-head", "fetch", "clone-head"],
       "a branch moved after the clone state blocks: #{result}")
assert(git(CLONE, "rev-parse", "HEAD") != head, "fixture: the clone branch moved")
# collect の記録が無い run (古い版で回収した) は、比べる相手が無いので止まる (#718)。
name = branch
commit
File.unlink(File.join(RUN, "collected-head"))
result = launch(1, {}, [], explicit: check_argv)
assert(result.values_at("blocked_at", "reason_code") == %w[launch-record check-record], "a run without the collect record blocks: #{result}")
# collect の後に人が branch を前の commit に戻すと、公開する先端は worker の最後の commit と違う (#718 の review)。
name = branch
first = commit
commit
collected!
git(CLONE, "switch", "-q", "-C", name, first)
result = launch(1, {}, [], explicit: check_argv)
assert(result.values_at("phase", "blocked_at", "reason_code") == %w[clone-state fetch clone-head], "a branch reset after collect blocks: #{result}")
# 検査の途中に clone が変わる (file が増える、同じ OID の別の branch に切り替える) と、返す直前の照合で止まる。
name = branch
commit
collected!
touched = File.join(CLONE, "late.txt")
result = launch(1, { "FAKE_GH_VIEW_TOUCH" => touched }, [], explicit: check_argv)
assert(result.values_at("phase", "blocked_at", "reason_code") == %w[clone-again fetch clone-dirty], "a file left during check blocks: #{result}")
assert(File.read(touched) == "left\n", "check keeps the late file")
File.unlink(touched)
name = branch
commit
collected!
result = launch(1, { "FAKE_GH_VIEW_SWITCH" => "#{CLONE}\nsame-oid-#{$branch_number}" }, [], explicit: check_argv)
assert(result.values_at("phase", "blocked_at", "reason_code") == %w[clone-again fetch clone-head], "a branch switch during check blocks: #{result}")
git(CLONE, "switch", "-q", name)

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

name = branch
head = commit
failure("public-safety", "publish-gate", { "FAKE_GATE_FAIL" => "1" })
assert(File.read(File.join(RUN, "gate-publish.err")).include?("PRIVATE-BODY"), "gate stderr saved only in run")
failure("public-safety", "gate-warning", { "FAKE_GATE_WARNING" => "1" })
assert(check_events.none? { |a| a.first == "gh" }, "gate warning prevents gh")
assert(git(MAIN, "rev-parse", "refs/heads/#{name}") == head, "warning stop already imported branch")
result = invoke_check(0, { "FAKE_GATE_WARNING" => "1" }, args: ["--accept-warnings"])
assert(result["status"] == "READY" && result["accepted_warnings"] == true && result["head_oid"] == head,
       "accepted warning retries the same imported head")
assert(check_events.map(&:first) == %w[personal-ja-style-check personal-public-safety-gate gh gh gh personal-work-marker-check],
       "accepted warning still checks destination and marker")
assert(File.read(File.join(RUN, "gate-publish.err")).include?("public-safety-gate: warning:"), "accepted warning retained")
failure("public-safety", "gate-warning", { "FAKE_GATE_WARNING" => "1" })
result = invoke_check(0, {}, args: ["--accept-warnings"])
assert(!result.key?("accepted_warnings"), "no warning was accepted when gate is clean")
failure("public-safety", "publish-gate", { "FAKE_GATE_FAIL" => "1" }, args: ["--accept-warnings"])
failure("public-safety", "publish-gate", { "FAKE_GATE_WARNING" => "1", "FAKE_GATE_FAIL" => "1" })
assert(File.read(File.join(RUN, "gate-publish.err")).include?("public-safety-gate: warning:"), "failed gate warning retained")
assert(check_events.none? { |a| a.first == "gh" }, "failed gate with warning prevents gh")
failure("public-safety", "publish-gate", { "FAKE_GATE_WARNING" => "1", "FAKE_GATE_FAIL" => "1" }, args: ["--accept-warnings"])
assert(check_events.none? { |a| a.first == "gh" }, "accepting warnings cannot bypass a failed gate")
failure("public-safety", "destination", { "FAKE_GATE_WARNING" => "1", "FAKE_GH_VIEW_FAIL" => "1" }, args: ["--accept-warnings"])
failure("public-safety", "marker", { "FAKE_GATE_WARNING" => "1" }, title: "wrong issue (#8)", args: ["--accept-warnings"])
result = invoke_check(2, {}, args: ["--accept-warnings", "--accept-warnings"])
assert(result["reason_code"] == "input", "duplicate accept-warnings rejected")
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
