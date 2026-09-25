# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rbconfig"

# --mutations は同じ CLI assertions を一条件ずつ壊した source に当てる。通常の CI では
# assertions だけを走らせ、変異検証は実装 round で明示実行する。
source = File.expand_path(ARGV.fetch(0))
safe_gh_source = File.expand_path(ARGV.fetch(1))
if ARGV[2] == "--mutations"
  mutations = {
    "other author" => ['if classify(c["user"], me) == "self"', 'if true'],
    "missing marker" => ['mark = COPY_MARKER_RE.match(lines.shift.to_s)',
                         'mark = COPY_MARKER_RE.match(lines.shift.to_s) || COPY_MARKER_RE.match("<!-- agent-packet issue=7 published=2026-09-22T00:00:00Z -->\n")'],
    "broken marker" => ['marker(issue, at) == mark[0].chomp', 'true'],
    "duplicate results" => ['publishable(known_entry, "結果 entry") == normalized', 'true'],
    "issue number type" => ['issue_number_matches?(data["number"], issue)', 'data["number"] == issue'],
    "envelope number" => ['issue_number_matches?(data["number"], issue)', 'true'],
    "envelope source" => ['data["source"] == source', 'true'],
    "envelope repo" => ['(repo.nil? || data["repo"].casecmp(repo).zero?)', 'true'],
    "read repo forwarding" => ['args = [reader, "issue", verb, issue.to_s]\\n    args += ["--repo", repo] if repo', 'args = [reader, "issue", verb, issue.to_s]'],
    "unpublished local" => ['updated_at = published_at + 1', 'updated_at = published_at'],
    "request overwrite" => ['request = secs["依頼"]', 'request = nil'],
    "stale next entry" => ['latest.published > local.published', 'true'],
    "remote H2" => [' || lines.any? { |l| l.start_with?("## ") }', ''],
    "issue H2" => ['line.start_with?("## ") ? "    #{line}" : line', 'line'],
    "local H2" => ['unless HEADINGS.include?(name)', 'unless HEADINGS.include?(name) || name == "injected"'],
    "launch record run" => ['data["run"] = local.run if local && local.run', ''],
    "launch record tab" => ['data["tab"] = local.tab if local && local.tab', ''],
    "last run" => ['data["last_run"] = local.last_run if local && local.last_run', ''],
    "invalid frontmatter" =>['"issue" => issue,\n      "title" => local', '"issue" => issue.to_s,\n      "title" => local']
  }
  original = File.read(source)
  Dir.mktmpdir("packet-mutations-") do |dir|
    mutations.each do |label, (from, to)|
      if label == "invalid frontmatter"
        from = from.gsub('\\n', "\n")
        to = to.gsub('\\n', "\n")
      elsif label == "read repo forwarding"
        from = from.gsub('\\n', "\n")
        to = to.gsub('\\n', "\n")
      end
      safe_mutation = label == "other author"
      mutation_source = safe_mutation ? File.read(safe_gh_source) : original
      abort "FAIL: mutation anchor missing: #{label}" unless mutation_source.include?(from)
      mutant = File.join(dir, safe_mutation ? "personal-safe-gh.rb" : "personal-packet.rb")
      File.write(mutant, mutation_source.sub(from, to))
      packet_variant = safe_mutation ? source : mutant
      reader_variant = safe_mutation ? mutant : safe_gh_source
      _out, err, status = Open3.capture3(RbConfig.ruby, __FILE__, packet_variant, reader_variant)
      abort "FAIL: mutation survived: #{label}" if status.success?
      abort "FAIL: mutation failed outside assertion: #{label}: #{err}" unless err.include?("FAIL:")
      puts "ok: mutation caught: #{label}"
    end
  end
  exit
end

require source

def assert(ok, message)
  abort "FAIL: #{message}" unless ok
end

def copy(at: "2026-09-22T00:00:00Z", date: "2026-09-22", result: "REMOTE-RESULT", following: "REMOTE-NEXT")
  <<~TEXT
    <!-- agent-packet issue=7 published=#{at} -->

    ## 📦 packet #7 — state: review / worker: codex

    **結果 (最新節)**

    ### #{date} worker/codex
    #{result}

    **次の入口**

    #{following}
  TEXT
end

def self_comment(body)
  { "author" => "fixture-self", "author_trust" => "self", "body" => body }
end

LOCAL = <<~TEXT
  ---
  issue: 7
  title: "LOCAL-TITLE #7"
  branch: feat/7-test
  pr: 8
  state: blocked
  worker: claude
  updated: 2026-09-21T12:00:00Z
  published: 2026-09-21T00:00:00Z
  run: /tmp/agent-packet-run-7
  tab: "#7"
  ---

  ## 依頼

  <!-- local scope -->
  LOCAL-REQUEST

  ## 結果

  <!-- append only -->
  ### 2026-09-20 worker/claude
  LOCAL-RESULT

  ### 2026-09-21 worker/codex
  LOCAL-DUPLICATE

  ### 2026-09-21 worker/codex
  LOCAL-SECOND-SAME-HEADING

  ## 次の入口

  LOCAL-NEXT
TEXT

Dir.mktmpdir("packet-pull-") do |tmp|
  # path / 本文が shell として再解釈されないことも検証する。
  repo = File.join(tmp, "repo space ' $(touch SHELL-PATH) `touch SHELL-BACKTICK`")
  deploy = File.join(tmp, "deploy space ' $(touch SHELL-DEPLOY)")
  FileUtils.mkdir_p([repo, deploy])
  env = { "GIT_CONFIG_SYSTEM" => "/dev/null", "GIT_CONFIG_GLOBAL" => "/dev/null",
          "GIT_AUTHOR_NAME" => "test", "GIT_AUTHOR_EMAIL" => "test@example.com",
          "GIT_COMMITTER_NAME" => "test", "GIT_COMMITTER_EMAIL" => "test@example.com" }
  _out, err, status = Open3.capture3(env, "git", "init", "-q", repo)
  assert(status.success?, "fixture git init: #{err}")
  packet = File.join(deploy, "personal-packet")
  FileUtils.cp(source, packet)
  File.chmod(0o755, packet)
  reader = File.join(deploy, "personal-safe-gh")
  FileUtils.cp(safe_gh_source, reader)
  File.chmod(0o755, reader)
  trust_file = File.join(deploy, "trust.json")
  File.write(trust_file, JSON.generate("login" => "fixture-self", "id" => 4242))
  gh = File.join(deploy, "gh")
  File.write(gh, <<~'RUBY')
    #!/usr/bin/env ruby
    require "json"
    dir = File.dirname(__FILE__)
    File.open(File.join(dir, "gh-calls.jsonl"), "a") { |f| f.puts JSON.generate(ARGV) }
    exit 1 if File.exist?(File.join(dir, "fail"))
    if ARGV[0] == "repo" && ARGV[1..2] == %w[view --json]
      puts "fixture/repo"
      exit 0
    end
    abort "unexpected gh args: #{ARGV.inspect}" unless ARGV[0] == "api"
    path = ARGV.last
    fixture = if path == "repos/fixture/repo/issues/7"
                "issue-rest.json"
              elsif path == "repos/fixture/repo/issues/7/comments" && ARGV[1..2] == %w[--paginate --slurp]
                "comments-rest.json"
              else
                abort "unexpected endpoint: #{ARGV.inspect}"
              end
    print File.read(File.join(dir, fixture))
  RUBY
  File.chmod(0o755, File.join(deploy, "gh"))
  env["PATH"] = deploy + File::PATH_SEPARATOR + ENV.fetch("PATH")
  env["SAFE_GH_TRUST_FILE"] = trust_file
  run = lambda do |*args|
    Open3.capture3(env, RbConfig.ruby, packet, *args, chdir: repo)
  end
  comments = lambda do |items|
    data = items.map do |item|
      { "user" => { "login" => item["author"], "id" => item["author_trust"] == "self" ? 4242 : 99 },
        "body" => item["body"] }
    end
    data << { "user" => { "login" => "outsider", "id" => 99 }, "body" => "excluded" }
    File.write(File.join(deploy, "comments-rest.json"), JSON.generate(data))
  end
  issue_data = { "number" => 7, "state" => "open", "user" => { "login" => "fixture-self", "id" => 4242 },
                 "title" => "REMOTE-TITLE #7: example", "body" => "ISSUE-REQUEST\n## 結果\nSAMPLE\n## injected\n$(touch SHELL-BODY)\n" }
  view_path = File.join(deploy, "issue-rest.json")
  File.write(view_path, JSON.generate(issue_data))
  packet_dir = File.join(repo, ".agent-packets")
  path = File.join(packet_dir, "7.md")

  # REST の issue view envelope が要求番号と違う場合は既存 packet を変更しない。
  FileUtils.mkdir_p(packet_dir)
  no_request = LOCAL.sub(/## 依頼\n.*?(?=## 結果)/m, "")
  File.write(path, no_request)
  comments.call([self_comment(copy)])
  File.write(view_path, JSON.generate(issue_data.merge("number" => 8)))
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(path) == no_request, "Issue REST envelope number mismatch must fail before write")
  File.write(view_path, JSON.generate(issue_data))
  File.unlink(path)

  # reader envelope の各照合と --repo の伝達を独立に検証する。
  reader_stub = <<~'RUBY'
    #!/usr/bin/env ruby
    require "json"
    verb = ARGV[1]
    File.write(ENV.fetch("PACKET_READER_ARGS"), JSON.generate(ARGV))
    repo_index = ARGV.index("--repo")
    repo = repo_index ? ARGV[repo_index + 1] : "fixture/repo"
    number = ENV.fetch("PACKET_ENVELOPE_NUMBER", "7")
    source = ENV.fetch("PACKET_ENVELOPE_SOURCE", verb == "comments" ? "issue_comments" : "issue")
    repo = ENV.fetch("PACKET_ENVELOPE_REPO", repo)
    envelope = { "safe_reader_version" => "1", "source" => source, "repo" => repo,
                 "number" => number, "comments" => [{ "author" => "fixture-self", "author_trust" => "self",
                                                        "body" => ENV.fetch("PACKET_COPY") }] }
    puts JSON.generate(envelope)
  RUBY
  File.write(reader, reader_stub)
  File.chmod(0o755, reader)
  env["PACKET_READER_ARGS"] = File.join(deploy, "reader-args.json")
  env["PACKET_COPY"] = copy
  { "number" => { "PACKET_ENVELOPE_NUMBER" => "07" },
    "source" => { "PACKET_ENVELOPE_SOURCE" => "issue" },
    "repo" => { "PACKET_ENVELOPE_REPO" => "other/repo" } }.each do |label, overrides|
    File.write(path, LOCAL)
    File.unlink(env.fetch("PACKET_READER_ARGS")) if File.exist?(env.fetch("PACKET_READER_ARGS"))
    overrides.each { |key, value| env[key] = value }
    _out, _err, status = run.call("pull", "7", "--repo", "fixture/repo")
    assert(status.exitstatus == 2 && File.read(path) == LOCAL, "#{label} envelope mismatch must fail before write")
    reader_args = JSON.parse(File.read(env.fetch("PACKET_READER_ARGS")))
    assert(reader_args[-2..-1] == ["--repo", "fixture/repo"], "--repo must reach reader")
    overrides.each_key { |key| env.delete(key) }
  end
  File.unlink(path)
  FileUtils.remove_entry(packet_dir)
  FileUtils.cp(safe_gh_source, reader)
  File.chmod(0o755, reader)
  env.delete("PACKET_READER_ARGS")
  env.delete("PACKET_COPY")

  # 新規 / dry-run / 既存 publisher との round trip / list --json。
  comments.call([self_comment(copy)])
  out, err, status = run.call("pull", "7", "--dry-run", "--repo", "fixture/repo")
  assert(status.success?, "new dry-run: #{err}")
  assert(!File.exist?(packet_dir), "dry-run must not create packet dir")
  front = Packet.parse_text(out, path)
  assert(front.issue == 7 && front.title == issue_data["title"], "new frontmatter issue/title")
  assert(front.state == "review" && front.worker == "codex", "new frontmatter state/worker")
  assert(front.updated == Time.iso8601("2026-09-22T00:00:00Z") && front.updated == front.published, "new timestamps")
  assert(front.body.lines.grep(/^## /).map(&:strip) == %w[依頼 結果 次の入口].map { |n| "## #{n}" }, "reserved H2 in reconstructed packet")
  assert(front.body.include?("    ## injected") && front.body.include?("    ## 結果"), "Issue H2 must be indented")
  assert(Packet.compose(front, front.published) == copy, "publish/pull round trip")
  expected = out
  out, err, status = run.call("pull", "7")
  assert(status.success? && out == "pulled: issue #7\n", "new pull: #{err}")
  assert(File.read(path) == expected, "dry-run and apply must produce same packet")
  out, err, status = run.call("list", "--json")
  listed = JSON.parse(out)
  assert(status.success? && listed.size == 1 && listed[0]["issue"] == 7 && !listed[0]["unpublished"], "list --json after pull: #{err}")
  _out, err, status = run.call("pull", "7")
  assert(status.success? && File.read(path) == expected, "repeated pull must be byte-idempotent: #{err}")

  # publish の片節省略・timezone も既存の出力契約どおりに受理する。
  [copy.sub(/\*\*結果 \(最新節\)\*\*.*?(?=\*\*次の入口\*\*)/m, ""),
   copy.sub(/\n\n\*\*次の入口\*\*.*\z/m, "\n"),
   copy(at: "2026-09-22T12:00:00+09:00")].each do |body|
    File.unlink(path)
    comments.call([self_comment(body)])
    _out, err, status = run.call("pull", "7")
    assert(status.success?, "single section / timezone copy: #{err}")
    restored = Packet.parse(path)
    assert(Packet.compose(restored, restored.published) == body, "single section / timezone round trip")
  end

  # 履歴のない新規 packet にも採用した全 entry が published の順で戻る。
  File.unlink(path)
  comments.call([self_comment(copy), self_comment(copy(at: "2026-09-20T00:00:00Z", date: "2026-09-20", result: "FIRST-RESULT"))])
  _out, err, status = run.call("pull", "7")
  assert(status.success?, "restore all published entries: #{err}")
  results = Packet.sections(Packet.parse(path).body)["結果"]
  assert(results.include?("FIRST-RESULT") && results.index("FIRST-RESULT") < results.index("REMOTE-RESULT"), "restore results chronologically")

  # local 依頼 / title / optional fields と同名 entry を保持。コメント順は published 順と異なる。
  older = copy(at: "2026-09-21T00:00:00Z", date: "2026-09-21", result: "REMOTE-DUPLICATE", following: "OLD-NEXT")
  comments.call([self_comment(copy), self_comment(older), self_comment(copy)])
  File.write(path, LOCAL)
  File.write(view_path, "not JSON: local request means no Issue fetch")
  out, err, status = run.call("pull", "7", "--dry-run")
  assert(status.success? && File.read(path) == LOCAL, "existing dry-run: #{err}")
  front = Packet.parse_text(out, path)
  secs = Packet.sections(front.body)
  assert(secs["依頼"] == Packet.sections(Packet.parse_text(LOCAL, path).body)["依頼"], "local request must be preserved verbatim")
  assert(front.title == "LOCAL-TITLE #7" && front.branch == "feat/7-test" && front.pr == 8, "local metadata preservation")
  assert(front.run == "/tmp/agent-packet-run-7" && front.tab == "#7", "local launch record (run / tab) must survive pull (#315)")
  assert(secs["結果"].include?("LOCAL-RESULT") && secs["結果"].include?("LOCAL-DUPLICATE"), "local results retained")
  assert(secs["結果"].include?("REMOTE-DUPLICATE") && secs["結果"].scan("REMOTE-RESULT").size == 1, "same heading with distinct body must append")
  assert(secs["結果"].include?("LOCAL-SECOND-SAME-HEADING"), "local duplicate headings with distinct bodies must be retained")
  assert(secs["結果"].index("LOCAL-RESULT") < secs["結果"].index("REMOTE-RESULT"), "new result must append")
  assert(secs["次の入口"].strip == "REMOTE-NEXT", "newest published wins independent of comment order")
  _out, err, status = run.call("pull", "7")
  assert(status.success? && File.read(path) == out, "merge apply matches dry-run: #{err}")

  # 最後の run dir (last_run) も local だけの情報として保持する (#325)。run とは同時に置かない。
  File.write(path, LOCAL.sub(/^run:.*\n/, "last_run: /tmp/agent-packet-run-6\n").sub(/^tab:.*\n/, ""))
  out, err, status = run.call("pull", "7", "--dry-run")
  front = Packet.parse_text(out, path)
  assert(status.success? && front.last_run == "/tmp/agent-packet-run-6" && front.run.nil?, "local last_run must survive pull (#325): #{err}")

  # 空の依頼節は既存 local として保持。published 無しなら写しを採用する。
  unpublished = LOCAL.sub(/^published:.*\n/, "").sub("LOCAL-REQUEST", "")
  File.write(path, unpublished)
  _out, err, status = run.call("pull", "7")
  assert(status.success?, "unpublished local with existing request: #{err}")
  front = Packet.parse(path)
  assert(Packet.sections(front.body)["次の入口"].strip == "REMOTE-NEXT", "unpublished local accepts copy")
  assert(front.unpublished? && front.updated > front.published, "unpublished local must remain unpublished after pull")

  # 同時刻 / 古い写しは次の入口と state/worker を巻き戻さない。未 publish の updated も保持。
  newer_local = LOCAL.sub("published: 2026-09-21", "published: 2026-09-23").sub("updated: 2026-09-21", "updated: 2026-09-24")
  [newer_local, newer_local.sub("published: 2026-09-23", "published: 2026-09-22")].each do |local|
    File.write(path, local)
    out, err, status = run.call("pull", "7")
    assert(status.success?, "stale/equal pull: #{err}")
    front = Packet.parse(path)
    assert(Packet.sections(front.body)["次の入口"].strip == "LOCAL-NEXT", "stale/equal next entry must not overwrite")
    assert(front.state == "blocked" && front.worker == "claude" && front.unpublished?, "local state and unpublished updates must survive")
    assert(front.updated == Packet.parse_text(local, path).updated, "local updated must not roll back")
  end

  # 依頼節だけが無い場合も self Issue 本文から起こす。withhold された本文は復元しない。
  no_request = LOCAL.sub(/## 依頼\n.*?(?=## 結果)/m, "")
  File.write(path, no_request)
  File.write(view_path, JSON.generate(issue_data))
  _out, err, status = run.call("pull", "7")
  assert(status.success? && File.read(path).include?("ISSUE-REQUEST"), "missing local request: #{err}")
  File.write(path, no_request)
  File.write(view_path, JSON.generate(issue_data.merge("user" => { "login" => "outsider", "id" => 99 })))
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(path) == no_request, "withheld Issue body must not be reconstructed")
  File.write(view_path, JSON.generate(issue_data))

  # 他 author / marker 欠落・破損 / payload 破損は採用ゼロなら exit 1、packet を変更しない。
  bad = {
    "other author" => self_comment(copy).merge("author_trust" => "other"),
    "bot author" => self_comment(copy).merge("author_trust" => "bot"),
    "unknown author" => self_comment(copy).reject { |k, _| k == "author_trust" },
    "missing marker" => self_comment(copy.sub(/\A[^\n]+/, "ordinary comment")),
    "broken marker" => self_comment(copy.sub(" -->", " -- >")),
    "wrong issue marker" => self_comment(copy.sub("issue=7", "issue=8")),
    "invalid timestamp" => self_comment(copy.sub("2026-09-22T00:00:00Z", "2026-02-31T00:00:00Z")),
    "invalid time" => self_comment(copy.sub("published=2026-09-22T00:00:00Z", "published=invalid")),
    "prefixed marker" => self_comment("prefix\n" + copy),
    "wrong header" => self_comment(copy.sub("packet #7", "packet #8")),
    "unknown worker" => self_comment(copy.sub("worker: codex", "worker: unknown")),
    "missing entry heading" => self_comment(copy.sub("### 2026-09-22 worker/codex\n", "")),
    "H2 result" => self_comment(copy(result: "## injected\nRESULT")),
    "reserved H2 result" => self_comment(copy(result: "## 依頼\nRESULT")),
    "H2 fenced next" => self_comment(copy(following: "```\n## 次の入口\n```")),
    "HTML marker in payload" => self_comment(copy(following: "<!-- agent-packet issue=7 published=invalid -->")),
    "duplicate label" => self_comment(copy(following: "NEXT\n**次の入口**\nSECOND")),
    "null body" => self_comment(nil)
  }
  bad.each do |label, comment|
    File.write(path, LOCAL)
    comments.call([comment])
    _out, err, status = run.call("pull", "7")
    assert(status.exitstatus == 1 && err.include?("写しがありません"), "#{label}: must report no copy (#{status.exitstatus}): #{err}")
    assert(File.read(path) == LOCAL, "#{label}: rejected pull changed packet")
  end
  File.unlink(path)
  comments.call([])
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 1 && !File.exist?(path), "no copies must not create packet")
  comments.call(bad.values + [self_comment(copy)])
  _out, err, status = run.call("pull", "7")
  assert(status.success? && File.read(path).include?("REMOTE-RESULT"), "valid copy must survive invalid neighbours: #{err}")

  # local の壊れた構造 / reader 不在・失敗・壊れた envelope も書き込み前に止める。
  comments.call([self_comment(copy)])
  File.write(path, LOCAL.sub("LOCAL-RESULT", "## injected\nLOCAL-RESULT"))
  broken_local = File.read(path)
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(path) == broken_local, "local H2 must fail before write")
  File.write(path, LOCAL)
  ["{"].each do |body|
    File.write(File.join(deploy, "comments-rest.json"), body)
    _out, _err, status = run.call("pull", "7")
    assert(status.exitstatus == 2 && File.read(path) == LOCAL, "invalid envelope must fail before write")
  end
  comments.call([self_comment(copy)])
  File.write(File.join(deploy, "fail"), "")
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(path) == LOCAL, "reader failure must fail before write")
  File.unlink(File.join(deploy, "fail"))
  File.rename(reader, reader + ".disabled")
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(path) == LOCAL, "missing reader must fail before write")
  File.rename(reader + ".disabled", reader)
  File.write(Packet.sibling_path(path), "recovery")
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(path) == LOCAL && File.read(Packet.sibling_path(path)) == "recovery", "existing temporary file must survive")
  File.unlink(Packet.sibling_path(path))
  File.unlink(path)
  target = File.join(repo, "symlink-target.md")
  File.write(target, LOCAL)
  File.symlink(target, path)
  _out, _err, status = run.call("pull", "7")
  assert(status.exitstatus == 2 && File.read(target) == LOCAL, "symlink packet must not be followed")
  File.unlink(path)

  # 引数の負例と argv の形。実行文字列への inline 展開があれば shell sentinel が作られる。
  calls_path = File.join(deploy, "gh-calls.jsonl")
  calls = File.readlines(calls_path)
  [["pull"], ["pull", "0"], ["pull", "seven"], ["pull", "7", "8"],
   ["pull", "7", "--repo", "-x/y"], ["pull", "7", "--repo"],
   ["pull", "7; touch SHELL-ISSUE"], ["pull", "7", "--repo", "x/$(touch SHELL-REPO)"],
   ["pull", "7", "--bogus"]].each do |args|
    _out, _err, status = run.call(*args)
    assert(status.exitstatus == 2, "invalid pull args must return exit 2")
  end
  assert(File.readlines(calls_path) == calls, "argument failures must not call reader")
  assert(calls.map { |l| JSON.parse(l) }.include?(%w[api --paginate --slurp repos/fixture/repo/issues/7/comments]), "real safe-gh REST argv contract")
  assert(Dir.glob(File.join(repo, "SHELL-*")).empty?, "runtime data must not execute as shell")
end
puts "ok: packet pull self-test"
