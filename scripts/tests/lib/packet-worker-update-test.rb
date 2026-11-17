# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"
require "time"

SOURCE = File.expand_path(ARGV.fetch(0))
ROOT = File.expand_path(ARGV.fetch(1))
require SOURCE

ENV["HOME"] = File.join(ROOT, "home")
ENV["GIT_CONFIG_GLOBAL"] = File.join(ROOT, "gitconfig")
ENV["GIT_CONFIG_SYSTEM"] = "/dev/null"
ENV["XDG_CONFIG_HOME"] = File.join(ROOT, "config")
Packet::GIT_REPO_ENV.each { |key| ENV.delete(key) }
FileUtils.mkdir_p(ENV.fetch("HOME"))
File.write(ENV.fetch("GIT_CONFIG_GLOBAL"), "[core]\n hooksPath = /dev/null\n excludesFile = /dev/null\n")
REPO = File.join(ROOT, "repo")
OUTSIDE = File.join(ROOT, "outside.md")
RUN = File.join(ROOT, "run")
FileUtils.mkdir_p(RUN)
_out, err, status = Open3.capture3("git", "init", "-q", REPO)
abort err unless status.success?
Dir.chdir(REPO)
FileUtils.mkdir_p(".agent-packets")
PATH_PACKET = File.join(REPO, ".agent-packets", "7.md")
ORIGINAL = <<~TEXT
  ---
  issue: 7
  title: "packet #7"
  state: open
  worker: codex
  updated: 2026-01-01T00:00:00+09:00
  published: 2025-12-31T00:00:00+09:00
  custom: keep
  # preserved comment
  ---
  preamble

  ## 依頼

  original request

  ## 結果

  ### 2026-01-01 worker/codex

  original result

  ## 次の入口

  original next
TEXT

$count = 0
def assert(ok, message)
  abort "FAIL: #{message}" unless ok
  $count += 1
end

def reset(text = ORIGINAL)
  File.unlink(PATH_PACKET) if File.symlink?(PATH_PACKET)
  File.write(PATH_PACKET, text)
end

def payload(operation, values = {})
  { "schema" => 1, "operation" => operation,
    "expected_sha256" => Digest::SHA256.file(PATH_PACKET).hexdigest }.merge(values)
end

def call_update(data, expected = 0, args: ["7", "--stdin"], source: SOURCE, env: {})
  before = File.binread(PATH_PACKET) if File.file?(PATH_PACKET)
  input = data.is_a?(String) ? data : JSON.generate(data)
  out, err, status = Open3.capture3(env, RbConfig.ruby, source, "worker-update", *args, stdin_data: input)
  assert(status.exitstatus == expected, "exit #{status.exitstatus}, expected #{expected}: #{err}")
  assert(out.lines.size == 1, "stdout must have one JSON line")
  result = JSON.parse(out)
  %w[PRIVATE-ENTRY PRIVATE-NEXT PRIVATE-REQUEST].each do |body|
    assert(!out.include?(body) && !err.include?(body), "body leaked")
  end
  if expected.zero?
    assert(result["ok"] == true && err.empty?, "success shape")
    assert(result.keys.sort == %w[ok issue operation state sha256 updated_changed].sort, "success keys")
    assert(result["issue"] == 7 && result["operation"] == data["operation"], "success identity")
    assert(result["sha256"] == Digest::SHA256.file(PATH_PACKET).hexdigest, "success digest")
    list, list_err, list_status = Open3.capture3(RbConfig.ruby, SOURCE, "list", "--json")
    assert(list_status.success?, "list can read written packet: #{list_err}")
    assert(JSON.parse(list).first["state"] == result["state"], "returned state")
    old_front = Packet.parse_text(before.dup.force_encoding(Encoding::UTF_8), PATH_PACKET)
    new_front = Packet.parse(PATH_PACKET)
    untouched = %i[issue title worker published]
    untouched += case data["operation"]
                 when "branch" then %i[pr state updated run tab last_run]
                 when "run-start" then %i[branch pr]
                 when "result" then %i[branch pr state]
                 when "stop", "round" then %i[branch pr run tab last_run]
                 when "review" then %i[branch run tab last_run]
                 end
    assert(untouched.all? { |key| old_front[key] == new_front[key] }, "untouched frontmatter values")
    old_secs = Packet.sections(old_front.body)
    new_secs = Packet.sections(new_front.body)
    untouched_sections = case data["operation"]
                         when "branch", "run-start", "review" then %w[依頼 結果 次の入口]
                         when "result", "stop" then %w[依頼]
                         when "round" then %w[結果]
                         end
    assert(untouched_sections.all? { |key| old_secs[key] == new_secs[key] }, "untouched sections byte-for-byte")
    assert(result["updated_changed"] == (old_front.updated != new_front.updated), "updated_changed matches actual timestamps")
  else
    assert(result["ok"] == false && result["reason_code"].is_a?(String) && result["reason"].is_a?(String), "failure shape")
    assert(err.lines.size == 1, "one stderr diagnostic")
    assert(File.binread(PATH_PACKET) == before, "failed operation changed packet") if before
  end
  assert(!File.exist?(Packet.sibling_path(PATH_PACKET)), "temporary file remains")
  result
end

def update(operation, values = {}, expected = 0)
  call_update(payload(operation, values), expected)
end

def current
  Packet.parse(PATH_PACKET)
end

def list_row
  out, err, status = Open3.capture3(RbConfig.ruby, SOURCE, "list", "--json")
  assert(status.success?, "list failed: #{err}")
  JSON.parse(out).first
end

reset
result = update("branch", "branch" => "feat/7-test")
assert(current.branch == "feat/7-test" && !result["updated_changed"], "branch added without time change")
assert(current.body == Packet.parse_text(ORIGINAL, PATH_PACKET).body, "branch preserved body")
update("branch", { "branch" => "feat/7-other" }, 1)
reset(ORIGINAL.sub("state: open", "branch: null\nstate: open"))
update("branch", { "branch" => "feat/7-other" }, 1)

# Branch names containing YAML punctuation remain literal strings.
["feat/7-quote\"", "feat/7-apostrophe'", "true", "123"].each do |branch|
  reset
  update("branch", "branch" => branch)
  assert(current.branch == branch, "literal branch")
end
reset(ORIGINAL.sub("state: open", "state: blocked\nlast_run: #{RUN.to_json}"))
result = update("run-start", "run" => RUN, "tab" => "#7")
assert(result["updated_changed"] && current.state == "open" && current.last_run.nil?, "blocked run-start timestamp")

reset
result = update("run-start", "run" => RUN, "tab" => "#7")
assert(current.run == RUN && current.tab == "#7" && !result["updated_changed"], "open run-start")
assert(File.read(PATH_PACKET).include?("run: #{RUN.to_json}\n") && File.read(PATH_PACKET).include?('tab: "#7"'), "quoted launch fields")
assert(list_row["run_status"] == "unfinished", "unfinished run")
File.write(File.join(RUN, "done.txt"), "0\n")
assert(list_row["run_status"] == "finished", "finished run")
update("run-start", { "run" => RUN, "tab" => "#7" }, 1)
update("result", { "run" => RUN + "-wrong", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, 1)
result = update("result", "run" => RUN, "entry" => "PRIVATE-ENTRY\n\tline two", "next" => "PRIVATE-NEXT")
assert(result["updated_changed"] && current.state == "open", "result time/state")
assert(current.last_run == RUN && current.run.nil? && current.tab.nil?, "result moves launch record")
assert(File.read(PATH_PACKET).include?("last_run: #{RUN.to_json}\n"), "quoted last_run")
assert(list_row.values_at("run", "run_status", "tab", "last_run") == [nil, nil, nil, RUN], "list completed run")
assert(Packet.sections(current.body)["結果"].include?("### #{Time.now.strftime('%Y-%m-%d')} worker/codex\n\nPRIVATE-ENTRY"), "dated result")
assert(Packet.sections(current.body)["結果"].include?("original result"), "result appends")
assert(Packet.sections(current.body)["次の入口"].strip == "PRIVATE-NEXT", "next overwritten")
update("stop", { "run" => RUN + "-wrong", "role" => "orchestrator/claude", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, 1)
update("stop", "run" => RUN, "role" => "orchestrator/claude", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT")
assert(current.state == "blocked" && current.last_run == RUN && current.run.nil?, "stop with last_run")
assert(Packet.sections(current.body)["結果"].include?(" orchestrator/claude\n"), "stop role")
result = update("run-start", "run" => RUN + "-missing", "tab" => "#7")
assert(current.state == "open" && current.last_run.nil?, "blocked restart clears last_run")
assert(list_row["run_status"] == "missing", "missing run")
# All timestamps have second precision; compare the actual before/after value, not an assumed tick.
assert([true, false].include?(result["updated_changed"]), "updated_changed boolean")
update("stop", "run" => RUN + "-missing", "role" => "worker/codex", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT")
assert(current.state == "blocked" && current.run == RUN + "-missing" && current.tab == "#7", "stop preserves active record")
result = update("run-start", "run" => RUN, "tab" => "#7")
assert(current.state == "open" && current.run == RUN, "blocked replaces run")

%w[open review blocked].each do |state|
  reset(ORIGINAL.sub("state: open", "state: #{state}"))
  result = update("round", "request" => "PRIVATE-REQUEST\nmore", "next" => "PRIVATE-NEXT")
  assert(current.state == (state == "review" ? "open" : state), "round state #{state}")
  assert(result["updated_changed"], "round time")
  secs = Packet.sections(current.body)
  assert(secs["依頼"].include?("original request") && secs["依頼"].include?("PRIVATE-REQUEST"), "round appends")
  assert(secs["次の入口"].strip == "PRIVATE-NEXT", "round next")
end
reset(ORIGINAL.sub("state: open", "last_run: #{RUN.to_json}\nstate: open"))
update("review", "pr" => 12)
assert(current.last_run == RUN, "review preserves last_run")
reset(ORIGINAL.sub("state: open", "run: #{RUN.to_json}\ntab: \"#7\"\nstate: open"))
update("round", "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT")
assert(current.run == RUN && current.tab == "#7", "round preserves active run")
reset
result = update("review", "pr" => 123)
assert(current.pr == 123 && current.state == "review" && result["updated_changed"], "review")
assert(File.read(PATH_PACKET).match?(/^updated: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/), "local timestamp with offset")
assert(File.read(PATH_PACKET).include?("custom: keep\n# preserved comment\n"), "unknown key and comment preserved")

# State guards for every restricted operation.
{
  "run-start" => [{ "run" => RUN, "tab" => "#7" }, %w[review done]],
  "result" => [{ "run" => RUN, "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, %w[review blocked done]],
  "stop" => [{ "run" => RUN, "role" => "worker/codex", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, %w[review blocked done]],
  "round" => [{ "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT" }, %w[done]],
  "review" => [{ "pr" => 123 }, %w[review blocked done]]
}.each do |operation, (values, states)|
  states.each do |state|
    reset(ORIGINAL.sub("state: open", "state: #{state}\nrun: #{RUN.to_json}\ntab: \"#7\""))
    update(operation, values, 1)
  end
end
reset
update("result", { "run" => RUN, "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, 1)
update("stop", { "run" => RUN, "role" => "worker/codex", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, 1)
update("run-start", "run" => RUN, "tab" => "#7")
update("review", { "pr" => 123 }, 1)

# Input validation is exit 2 and must preserve bytes.
reset
base = payload("branch", "branch" => "feat/7-valid")
[
  base.merge("schema" => 2), base.merge("schema" => 1.0), base.merge("schema" => true),
  base.merge("operation" => "unknown"), base.merge("extra" => "PRIVATE-ENTRY"),
  base.reject { |key, _| key == "branch" }, base.merge("expected_sha256" => "A" * 64),
  base.merge("expected_sha256" => "0" * 63), base.merge("expected_sha256" => 7),
  base.merge("branch" => nil), base.merge("operation" => []),
  "[]", "null", "{}", "{PRIVATE-ENTRY", JSON.generate(base) + "{}", "\xff".b,
  JSON.generate(base).sub('"schema":1', '"schema":1,"schema":1')
].each { |data| call_update(data, 2) }
%w[branch run-start result stop round review].each do |operation|
  keys = Packet::WORKER_INPUT_KEYS.fetch(operation)
  data = payload(operation, keys.each_with_object({}) { |key, values| values[key] = [] })
  call_update(data, 2)
end
["", "bad branch", "bad\tbranch", "bad\u007fbranch", "bad..branch", "-option", "@{-1}"].each do |value|
  update("branch", { "branch" => value }, 2)
end
["relative", "", "/run\nline", "/run\u007fline", '/run"quote', '/run\\escape'].each do |value|
  update("run-start", { "run" => value, "tab" => "#7" }, 2)
end
update("run-start", { "run" => RUN, "tab" => "#8" }, 2)
[0, -1, 1.0, "123", true].each { |pr| update("review", { "pr" => pr }, 2) }
update("stop", { "run" => RUN, "role" => "reviewer/codex", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" }, 2)
["", " \n\t", "PRIVATE-ENTRY\r", "PRIVATE-ENTRY\u0085", "PRIVATE-ENTRY\n## extra", "x<!--x", "x-->x",
 "### 2026-01-01 worker/codex", "### 2026-01-01 reviewer/human\t"].each do |value|
  update("result", { "run" => RUN, "entry" => value, "next" => "PRIVATE-NEXT" }, 2)
  update("round", { "request" => value, "next" => "PRIVATE-NEXT" }, 2)
  update("round", { "request" => "PRIVATE-REQUEST", "next" => value }, 2)
end
[[], ["0", "--stdin"], ["7"], ["7", "--stdin", "extra"], ["7", "--wrong"]].each do |args|
  call_update(base, 2, args: args)
end
call_update(base.merge("expected_sha256" => "0" * 64), 1)

# Exactly 64 KiB is accepted, the next byte is rejected.
large = payload("round", "request" => "x", "next" => "PRIVATE-NEXT")
large["request"] += "x" * (65_536 - JSON.generate(large).bytesize)
call_update(large)
large["expected_sha256"] = Digest::SHA256.file(PATH_PACKET).hexdigest
large["request"] += "x"
call_update(large, 2)

# Existing malformed data is rejected without rewriting, including fields unrelated to the operation.
[
  ORIGINAL.sub("state: open", "state: invalid"),
  ORIGINAL.sub("issue: 7", "issue: 8"),
  ORIGINAL.sub("state: open", "state: open\nstate: open"),
  ORIGINAL.sub("state: open", '"state": open'),
  ORIGINAL.sub("state: open", '"st\\u0061te": open'),
  ORIGINAL.sub("custom: keep", "custom: !!str keep"),
  ORIGINAL.sub("custom: keep", "custom: {nested: value}"),
  ORIGINAL.sub("custom: keep", "custom: &alias keep"),
  ORIGINAL.sub("custom: keep", "custom: |\n  multiline"),
  ORIGINAL.sub("custom: keep", 'custom: "escaped\\nvalue"'),
  ORIGINAL.sub("## 結果", "## 未知"),
  ORIGINAL.sub("## 結果", "## 依頼"),
  ORIGINAL.sub("## 結果", "### 結果"),
  ORIGINAL.sub("original result", "<!--unclosed"),
  ORIGINAL.sub("original result", "\xff".b.force_encoding("UTF-8"))
].each do |broken|
  reset(broken)
  update("branch", { "branch" => "feat/7-test" }, 1)
end

reset
File.write(OUTSIDE, ORIGINAL)
File.unlink(PATH_PACKET)
File.symlink(OUTSIDE, PATH_PACKET)
update("branch", { "branch" => "feat/7-test" }, 1)
assert(File.read(OUTSIDE) == ORIGINAL, "symlink target untouched")
reset
_out, _err, status = Open3.capture3("git", "add", "-f", ".agent-packets/7.md")
assert(status.success?, "stage fixture")
update("branch", { "branch" => "feat/7-test" }, 1)
Open3.capture3("git", "rm", "--cached", "-q", ".agent-packets/7.md")
File.unlink(PATH_PACKET)
call_update(base, 1)
assert(!File.exist?(PATH_PACKET), "missing packet not created")
reset
call_update(base, 1, env: { "GIT_INDEX_FILE" => File.join(ROOT, "alternate-index") })

# C locale still accepts UTF-8 and never emits the supplied text.
call_update(payload("round", "request" => "日本語の追記", "next" => "PRIVATE-NEXT"), env: { "LC_ALL" => "C" })

# Simulate a concurrent edit after the sibling is complete, and a rename failure.
# Only the child process overrides the filesystem seam; actual CLI and git checks still run.
variant = File.join(ROOT, "variant.rb")
["race", "rename"].each do |kind|
  reset
  hook = if kind == "race"
           <<~CODE
             module Packet
               class << self
                 alias original_write_sibling write_sibling
                 def write_sibling(path, content)
                   tmp = original_write_sibling(path, content)
                   File.write(path, File.read(path) + "concurrent edit\\n")
                   tmp
                 end
               end
             end
           CODE
         else
           <<~CODE
             class << File
               def rename(*args)
                 raise Errno::EACCES
               end
             end
           CODE
         end
  File.write(variant, "require #{SOURCE.inspect}\n#{hook}\nexit Packet.main(ARGV)\n")
  before = File.read(PATH_PACKET)
  out, err, status = Open3.capture3(RbConfig.ruby, variant, "worker-update", "7", "--stdin",
                                  stdin_data: JSON.generate(payload("branch", "branch" => "feat/7-test")))
  assert(status.exitstatus == 1 && JSON.parse(out)["ok"] == false && err.lines.size == 1, "#{kind} refused")
  expected = kind == "race" ? before + "concurrent edit\n" : before
  assert(File.read(PATH_PACKET) == expected, "#{kind} preserved current bytes")
  assert(!File.exist?(Packet.sibling_path(PATH_PACKET)), "#{kind} sibling cleaned")
end

reset
sibling = Packet.sibling_path(PATH_PACKET)
File.write(sibling, "previous temporary file")
out, _err, status = Open3.capture3(RbConfig.ruby, SOURCE, "worker-update", "7", "--stdin",
                                 stdin_data: JSON.generate(payload("branch", "branch" => "feat/7-test")))
assert(status.exitstatus == 1 && !JSON.parse(out)["ok"], "existing sibling refused")
assert(File.read(sibling) == "previous temporary file" && File.read(PATH_PACKET) == ORIGINAL, "existing sibling preserved")
File.unlink(sibling)
%w[--help -h].each do |flag|
  out, _err, status = Open3.capture3(RbConfig.ruby, SOURCE, "worker-update", flag)
  assert(status.success? && out.include?("worker-update <issue> --stdin"), "worker help")
end
puts "ok: packet worker-update (#{$count} assertions)"
