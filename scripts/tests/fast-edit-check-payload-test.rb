# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

script = File.expand_path(ARGV.fetch(0))
require script

def assert(condition, message)
  raise message unless condition
end

def patch_payload(cwd, patch)
  {
    "hook_event_name" => "PostToolUse", "tool_name" => "apply_patch", "cwd" => cwd,
    "tool_input" => { "command" => patch },
    "tool_response" => "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess. Updated files.\n",
  }
end

Dir.mktmpdir("fast-edit-payload-") do |tmp|
  repo = File.join(tmp, "repo with spaces")
  other = File.join(tmp, "undeclared")
  [repo, other].each { |path| assert(system("git", "init", "-q", path), "git init failed") }
  repo = File.realpath(repo)
  FileUtils.mkdir_p(File.join(repo, "nested"))
  %w[a.rb new.rb old.rb moved.rb deleted.rb untouched.rb].each do |name|
    File.write(File.join(repo, name), "puts 1\n")
  end
  unusual_name = "名前 $(literal).rb"
  File.write(File.join(repo, unusual_name), "puts 1\n")
  File.write(File.join(other, "other.rb"), "puts 1\n")
  log = File.join(tmp, "checks.jsonl")
  checker = File.join(tmp, "check.rb")
  File.write(checker, <<~'RUBY')
    require "json"
    File.open(ENV.fetch("AGENT_TOOLS_TEST_CHECK_LOG"), "a") do |f|
      f.puts JSON.generate({ "argv" => ARGV, "cwd" => Dir.pwd })
    end
    if ENV["AGENT_TOOLS_TEST_CHECK_FAIL"] == "1"
      STDOUT.write("lint failure " + "\xff" * 2500)
      exit 1
    end
  RUBY
  config = File.join(tmp, "checks.json")
  File.write(config, JSON.generate({ repo => { "edit_checks" => [
    { "name" => "fixture-lint", "pattern" => "\\.rb$", "command" => [RbConfig.ruby, checker] },
  ] } }))

  invoke = lambda do |payload, fail_check = false|
    File.write(log, "")
    out, err, status = Open3.capture3(
      { "AGENT_TOOLS_CHECKS_CONFIG" => config, "AGENT_TOOLS_TEST_CHECK_LOG" => log,
        "AGENT_TOOLS_TEST_CHECK_FAIL" => fail_check ? "1" : "0" },
      RbConfig.ruby, script, stdin_data: JSON.generate(payload), chdir: other
    )
    assert(status.success?, "hook must fail open: #{err}")
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    [out, calls]
  end

  patch = <<~PATCH
    *** Begin Patch
    *** Update File: a.rb
    @@
    -puts 0
    +puts 1
    @@ second chunk
     unchanged
    +added
    *** End of File
    *** Add File: new.rb
    +*** Update File: untouched.rb
    +literal file content, not another patch header
    *** Update File: old.rb
    *** Move to: moved.rb
    @@
    -old
    +new
    *** Delete File: deleted.rb
    *** Update File: ./a.rb
    @@
    -puts 0
    +puts 1
    *** Update File: #{unusual_name}
    @@
    -old
    +new
    *** End Patch
  PATCH
  payload = patch_payload(repo, patch)
  out, calls = invoke.call(payload)
  expected = ["a.rb", "new.rb", "moved.rb", unusual_name].map { |name| File.join(repo, name) }
  assert(out.empty?, "passing checks must be silent")
  assert(calls.map { |call| call["argv"] } == expected.map { |path| [path] },
         "check each existing destination once, preserve a path as one argument")
  assert(calls.all? { |call| call["cwd"] == repo }, "checks must run from each declared repo root")

  blank_context = <<~PATCH
    *** Begin Patch
    *** Update File: a.rb
    @@
    -puts 0
    +puts 1

     unchanged
    *** End Patch
  PATCH
  out, calls = invoke.call(patch_payload(repo, blank_context))
  assert(out.empty? && calls.map { |call| call["argv"] } == [[expected.first]],
         "Codex accepts an empty context line without the space prefix")

  out, calls = invoke.call(payload, true)
  context = JSON.parse(out).fetch("hookSpecificOutput")
  assert(context["hookEventName"] == "PostToolUse", "feedback must reach PostToolUse additionalContext")
  message = context.fetch("additionalContext")
  assert(message.include?("fixture-lint") && message.include?("lint failure"), "failed check must be identified")
  assert(message.valid_encoding? && message.length <= FastEditCheck::OUTPUT_CAP + 20,
         "multi-file failures must share the existing total output cap and UTF-8 scrub")
  assert(calls.length == expected.length, "output cap must not skip later checks")
  assert(!JSON.parse(out).key?("decision"), "feedback must not block edits")

  relative = patch_payload(File.join(repo, "nested"), <<~PATCH)
    *** Begin Patch
    *** Update File: ../a.rb
    @@
    -old
    +new
    *** Update File: #{File.join(repo, "new.rb")}
    @@
    -old
    +new
    *** Update File: ../missing.rb
    @@
    -old
    +new
    *** Update File: #{File.join(other, "other.rb")}
    @@
    -old
    +new
    *** End Patch
  PATCH
  out, calls = invoke.call(relative)
  assert(out.empty?, "passing relative-path checks must be silent")
  assert(calls.map { |call| call["argv"] } == expected.first(2).map { |path| [path] },
         "resolve paths against payload cwd, skip absent files and undeclared repos")

  # Claude Code keeps its existing file_path contract, without Codex response metadata.
  %w[Write Edit].each do |tool|
    out, calls = invoke.call({ "tool_name" => tool, "tool_input" => { "file_path" => expected.first } })
    assert(out.empty? && calls.map { |call| call["argv"] } == [[expected.first]], "Claude #{tool} regressed")
  end

  invalid_payloads = [nil, [], {}, payload.merge("tool_input" => []),
                      payload.merge("hook_event_name" => "PreToolUse"),
                      payload.merge("cwd" => nil), payload.merge("cwd" => "relative"),
                      payload.merge("cwd" => File.join(tmp, "absent"))]
  [nil, true, { "success" => true }, "Success", "Exit code: 1\nExit code: 0\n",
   "Exit code: 01\n", "patch rejected by user"].each do |response|
    invalid_payloads << payload.merge("tool_response" => response)
  end
  invalid_patches = [nil, [], "", "not a patch", patch.sub("*** End Patch", ""),
                     patch + "unexpected trailer\n", patch.sub("*** Begin Patch", "*** Begin Patch\n*** Environment ID: remote"),
                     "*** Begin Patch\n*** Add File: a.rb\nnot added content\n*** End Patch",
                     "*** Begin Patch\n*** Delete File: a.rb\n+content\n*** End Patch",
                     "*** Begin Patch\n*** Update File: a.rb\n*** Move to: new.rb\n*** End Patch",
                     "*** Begin Patch\n*** Update File: a.rb\n@@\n*** End Patch",
                     "*** Begin Patch\n*** Update File: a.rb\n@@\n+new\n@@\n*** End Patch",
                     "*** Begin Patch\n*** Update File: a.rb\n*** End of File\n+new\n*** End Patch",
                     "*** Begin Patch\n*** Add File: a.rb\n+new\n*** Unexpected\n*** End Patch"]
  invalid_patches.each { |command| invalid_payloads << payload.merge("tool_input" => { "command" => command }) }
  invalid_payloads.each_with_index do |bad, i|
    out, calls = invoke.call(bad)
    assert(out.empty? && calls.empty?, "invalid/failed payload #{i} must silently skip all checks")
  end
end

puts "ok: fast-edit-check payload adapter"
