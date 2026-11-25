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
                         when "round" then data.key?("review_entry") ? [] : %w[結果]
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

# YAML.dump folds a long title just as pull_text does. Every operation must keep it,
# along with plain backslashes and unrelated YAML values, byte-for-byte.
long_title = "委譲した Codex の worker の起動と回収を script にする (personal-codex-worker-run と packet の更新口)"
dumped = YAML.dump({ "title" => long_title }).sub(/\A---\n/, "")
assert(dumped.lines.size > 1, "YAML.dump fixture really folds the title")
title_line = "title: \"packet #7\"\n"
[dumped, "title: regex \\d の扱い\n", "title: 'quoted # title'\ncustom: |\n  extra line\n"].each do |title|
  fixture = ORIGINAL.sub(title_line, title).sub("custom: keep\n", "")
  {
    "branch" => { "branch" => "feat/7-test" },
    "run-start" => { "run" => RUN, "tab" => "#7" },
    "result" => { "run" => RUN, "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" },
    "stop" => { "run" => RUN, "role" => "worker/codex", "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" },
    "round" => { "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT" },
    "review" => { "pr" => 9 }
  }.each do |operation, values|
    text = fixture
    text = text.sub("state: open", "state: open\nrun: #{RUN.to_json}\ntab: \"#7\"") if %w[result stop].include?(operation)
    reset(text)
    update(operation, values)
    assert(File.read(PATH_PACKET).include?(title), "#{operation} preserves untouched title bytes")
  end
end

# Changed lines preserve the exact suffix after the YAML value, including tabs,
# comments, Unicode and # inside quotes. Deleted lines lose their comments too.
suffix = " \t  # 保持する comment # hash\n"
reset(ORIGINAL.sub("state: open\n", "state: review#{suffix}")
              .sub("updated: 2026-01-01T00:00:00+09:00\n", "updated: 2026-01-01T00:00:00+09:00#{suffix}"))
update("round", "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT")
assert(File.read(PATH_PACKET).include?("state: open#{suffix}"), "round preserves state comment")
assert(File.read(PATH_PACKET).lines.grep(/^updated:/).first.end_with?(suffix), "updated preserves suffix")
reset(ORIGINAL.sub("state: open\n", "state: open#{suffix}pr: 1#{suffix}"))
update("review", "pr" => 9)
assert(File.read(PATH_PACKET).include?("state: review#{suffix}pr: 9#{suffix}"), "review preserves state and pr suffixes")
quoted_run = RUN + "/日本語 #old"
reset(ORIGINAL.sub("state: open", "state: blocked\nrun: #{quoted_run.to_json}#{suffix}tab: \"#7\"#{suffix}".chomp))
update("run-start", "run" => RUN, "tab" => "#7")
assert(File.read(PATH_PACKET).include?("run: #{RUN.to_json}#{suffix}tab: \"#7\"#{suffix}"), "run-start preserves quoted suffixes")
update("result", "run" => RUN, "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT")
assert(!File.read(PATH_PACKET).include?(suffix), "result deletes run and tab comments with lines")
reset(ORIGINAL.sub("state: open", "state: blocked\nlast_run: #{RUN.to_json}#{suffix}".chomp))
update("run-start", "run" => RUN, "tab" => "#7")
assert(!File.read(PATH_PACKET).include?(suffix), "run-start deletes last_run comment")

# Shapes of changed/deleted keys still fail, even when list can read their value.
[
  ["review", { "pr" => 9 }, ORIGINAL.sub("state: open", '"state": open')],
  ["review", { "pr" => 9 }, ORIGINAL.sub("state: open", '"st\\u0061te": open')],
  ["round", { "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT" },
   ORIGINAL.sub("updated: 2026-01-01T00:00:00+09:00", "updated: >-\n  2026-01-01T00:00:00+09:00")],
  ["round", { "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT" },
   ORIGINAL.sub("updated: 2026-01-01T00:00:00+09:00", 'updated: "2026-01-01T00:00:00\\u002b09:00"')],
  ["result", { "run" => RUN, "entry" => "PRIVATE-ENTRY", "next" => "PRIVATE-NEXT" },
   ORIGINAL.sub("state: open", "state: open\nrun: >-\n  #{RUN}")],
  ["run-start", { "run" => RUN, "tab" => "#7" },
   ORIGINAL.sub("state: open", "state: blocked\nlast_run: >-\n  #{RUN}")]
].each do |operation, values, text|
  reset(text)
  assert(%w[open blocked].include?(list_row["state"]), "changed shape fixture readable by list")
  assert(update(operation, values, 1)["reason_code"] == "invalid_packet", "changed shape rejected")
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
# next を省いた result と stop は、次の入口を保つ (#719)。空の next は、省いたことにしない。
{ "result" => {}, "stop" => { "role" => "worker/codex" } }.each do |operation, extra|
  reset(ORIGINAL.sub("state: open", "run: #{RUN.to_json}\ntab: \"#7\"\nstate: open"))
  kept = Packet.sections(current.body)["次の入口"]
  values = { "run" => RUN, "entry" => "PRIVATE-ENTRY" }.merge(extra)
  [" ", "", nil].each { |value| update(operation, values.merge("next" => value), 2) }
  update(operation, values)
  assert(Packet.sections(current.body)["次の入口"] == kept, "#{operation} without next keeps the entry")
  assert(Packet.sections(current.body)["結果"].include?("PRIVATE-ENTRY"), "#{operation} without next still appends the result")
  assert(current.state == (operation == "stop" ? "blocked" : "open"), "#{operation} without next changes the state as usual")
end
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
    assert(update(operation, values, 1)["reason_code"] == "precondition", "state precondition code")
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
 "### 2026-01-01 worker/codex", "### 2026-01-01 reviewer/human\t",
 "**次の入口**", "PRIVATE-ENTRY\n**結果 (最新節)**\ntext"].each do |value|
  update("result", { "run" => RUN, "entry" => value, "next" => "PRIVATE-NEXT" }, 2)
  update("round", { "request" => value, "next" => "PRIVATE-NEXT" }, 2)
  update("round", { "request" => "PRIVATE-REQUEST", "next" => value }, 2)
end
# publish の strip で予約行になる端も拒否する。
[" **次の入口** ", "\t**結果 (最新節)**\t", "  ## extra "].each do |edge|
  [edge, "text\n#{edge}", "#{edge}\ntext"].each do |value|
    update("round", { "request" => "PRIVATE-REQUEST", "next" => value }, 2)
  end
  update("result", { "run" => RUN, "entry" => "text\n#{edge}", "next" => "PRIVATE-NEXT" }, 2)
end
# Only standalone exact labels are reserved, matching published_copy.
[" **次の入口**", "**次の入口** ", "text **結果 (最新節)**"].each do |value|
  update("round", "request" => value, "next" => "PRIVATE-NEXT")
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

# Existing malformed data is rejected without rewriting; duplicate keys are global.
[
  ORIGINAL.sub("state: open", "state: invalid"),
  ORIGINAL.sub("issue: 7", "issue: 8"),
  ORIGINAL.sub("state: open", "state: open\nstate: open"),
  ORIGINAL.sub("custom: keep", "custom: keep\ncustom: other"),
  ORIGINAL.sub("custom: keep", "custom: keep\n\"custom\": other"),
  ORIGINAL.sub("custom: keep", "custom: !!str keep"),
  ORIGINAL.sub("## 結果", "## 未知"),
  ORIGINAL.sub("## 結果", "## 依頼"),
  ORIGINAL.sub("## 結果", "### 結果"),
  ORIGINAL.sub("original result", "<!--unclosed"),
  ORIGINAL.sub("preamble", "<!--unclosed"),
  ORIGINAL.sub("preamble", "unopened-->"),
  ORIGINAL.sub("original result", "\xff".b.force_encoding("UTF-8"))
].each do |broken|
  reset(broken)
  assert(update("branch", { "branch" => "feat/7-test" }, 1)["reason_code"] == "invalid_packet", "parse/shape failure code")
end

reset
File.write(OUTSIDE, ORIGINAL)
File.unlink(PATH_PACKET)
File.symlink(OUTSIDE, PATH_PACKET)
assert(update("branch", { "branch" => "feat/7-test" }, 1)["reason_code"] == "check_rejected", "symlink check rejection")
assert(File.read(OUTSIDE) == ORIGINAL, "symlink target untouched")
reset
_out, _err, status = Open3.capture3("git", "add", "-f", ".agent-packets/7.md")
assert(status.success?, "stage fixture")
assert(update("branch", { "branch" => "feat/7-test" }, 1)["reason_code"] == "check_rejected", "tracked check rejection")
Open3.capture3("git", "rm", "--cached", "-q", ".agent-packets/7.md")
File.unlink(PATH_PACKET)
assert(call_update(base, 1)["reason_code"] == "missing_packet", "missing packet code")
assert(!File.exist?(PATH_PACKET), "missing packet not created")
reset
assert(call_update(base, 2, env: { "GIT_INDEX_FILE" => File.join(ROOT, "alternate-index") })["reason_code"] == "check_error", "check indeterminate")

# C locale still accepts UTF-8 and never emits the supplied text.
call_update(payload("round", "request" => "日本語の追記", "next" => "PRIVATE-NEXT"), env: { "LC_ALL" => "C" })

# Simulate a concurrent edit after the sibling is complete, and a rename failure.
# Only the child process overrides the filesystem seam; actual CLI and git checks still run.
variant = File.join(ROOT, "variant.rb")
["race", "rename", "write"].each do |kind|
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
         elsif kind == "rename"
           <<~CODE
             class << File
               def rename(*args)
                 raise Errno::EACCES
               end
             end
           CODE
         else
           <<~CODE
             class << File
               alias original_open open
               def open(path, *args, &block)
                 raise Errno::EACCES if path.end_with?(".md.tmp")
                 original_open(path, *args, &block)
               end
             end
           CODE
         end
  File.write(variant, "require #{SOURCE.inspect}\n#{hook}\nexit Packet.main(ARGV)\n")
  before = File.read(PATH_PACKET)
  out, err, status = Open3.capture3(RbConfig.ruby, variant, "worker-update", "7", "--stdin",
                                  stdin_data: JSON.generate(payload("round", "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT")))
  assert(status.exitstatus == 1 && JSON.parse(out)["ok"] == false && err.lines.size == 1, "#{kind} refused")
  assert(JSON.parse(out)["reason_code"] == (kind == "race" ? "digest_mismatch" : "write_failed"), "#{kind} reason code")
  assert(!out.include?("PRIVATE-") && !err.include?("PRIVATE-"), "#{kind} failure does not leak body")
  expected = kind == "race" ? before + "concurrent edit\n" : before
  assert(File.read(PATH_PACKET) == expected, "#{kind} preserved current bytes")
  assert(!File.exist?(Packet.sibling_path(PATH_PACKET)), "#{kind} sibling cleaned")
end

reset
sibling = Packet.sibling_path(PATH_PACKET)
File.write(sibling, "previous temporary file")
out, err, status = Open3.capture3(RbConfig.ruby, SOURCE, "worker-update", "7", "--stdin",
                                stdin_data: JSON.generate(payload("round", "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT")))
assert(status.exitstatus == 1 && !JSON.parse(out)["ok"], "existing sibling refused")
assert(JSON.parse(out)["reason_code"] == "stale_temp", "stale sibling code")
assert(!out.include?("PRIVATE-") && !err.include?("PRIVATE-"), "stale sibling does not leak body")
assert(File.read(sibling) == "previous temporary file" && File.read(PATH_PACKET) == ORIGINAL, "existing sibling preserved")
File.unlink(sibling)
%w[--help -h].each do |flag|
  out, _err, status = Open3.capture3(RbConfig.ruby, SOURCE, "worker-update", flag)
  assert(status.success? && out.include?("worker-update <issue> --stdin"), "worker help")
end
# optional keys retain the old preconditions unless explicitly supplied.
reset
update("run-start", "run" => RUN, "tab" => "#7")
assert(update("run-start", { "run" => RUN + "-new", "tab" => "#7" }, 1)["reason_code"] == "precondition", "existing run needs expected_run")
assert(update("run-start", { "run" => RUN + "-new", "tab" => "#7", "expected_run" => RUN + "-wrong" }, 1)["reason_code"] == "precondition", "expected_run mismatch")
result = update("run-start", "run" => RUN + "-new", "tab" => "#7", "expected_run" => RUN)
assert(current.run == RUN + "-new" && !result["updated_changed"], "retry replaces run without timestamp change")
reset
update("run-start", { "run" => RUN, "tab" => "#7", "expected_run" => RUN }, 1)
reset(ORIGINAL.sub("state: open", "state: blocked"))
update("run-start", { "run" => RUN, "tab" => "#7", "expected_run" => RUN }, 1)
reset
update("round", "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT", "review_entry" => "PRIVATE-ENTRY")
assert(current.body.include?("### #{Time.now.strftime('%Y-%m-%d')} reviewer/claude\n\nPRIVATE-ENTRY"), "reviewer entry appended")
["", "## injected", "<!-- comment -->", "### 2026-01-01 worker/codex", "ok\n  **次の入口**  "].each do |entry|
  update("round", { "request" => "PRIVATE-REQUEST", "next" => "PRIVATE-NEXT", "review_entry" => entry }, 2)
end
puts "ok: packet worker-update (#{$count} assertions)"
