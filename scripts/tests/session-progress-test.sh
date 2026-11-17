#!/bin/sh
# personal-session-progress の保存・CLI・拒否時の非漏出を一時 directory だけで検査する (#682)。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby -r"$script_dir/lib/check_helper" -ropen3 -rfileutils -rjson -rtimeout -rpty - "$repo_root" "$tmp" <<'RUBY'
Encoding.default_external = Encoding::UTF_8
root, tmp = ARGV
TMP = File.realpath(tmp)
BIN = File.join(TMP, "bin")
FileUtils.mkdir_p(BIN)
%w[personal-session-progress personal-public-safety-gate].each do |name|
  FileUtils.cp(File.join(root, "shared/scripts/#{name}.rb"), File.join(BIN, name))
  File.chmod(0o755, File.join(BIN, name))
end
SCRIPT = File.join(BIN, "personal-session-progress")
GATE = File.join(BIN, "personal-public-safety-gate")
ENVIRONMENT = { "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL" => "C", "HOME" => File.join(TMP, "home"),
                "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL }.freeze
FileUtils.mkdir_p(ENVIRONMENT["HOME"])
INITIAL = { "purpose" => "調査と実装", "steps" => [{ "id" => "inspect", "title" => "規約を確かめる" }] }.freeze
DECISION = { "id" => "place", "question" => "置き場を決める", "options" => ["作業ツリー", "別の場所"], "recommended" => 0 }.freeze

# source を require した検査も副作用は一時 directory に限定する。
load SCRIPT

def call(args, input: "", env: {}, cwd: TMP)
  out, err, status = Open3.capture3(ENVIRONMENT.merge(env), SCRIPT, *args, stdin_data: input,
                                   chdir: cwd, unsetenv_others: true)
  [status.exitstatus, out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8)]
end

def update(dir, patch = INITIAL, id: "session", env: {}, cwd: TMP, client: "codex")
  args = ["update", "--client", client, "--dir", dir, "--stdin"]
  args += ["--session-id", id] if id
  call(args, input: patch.is_a?(String) ? patch : JSON.generate(patch), env: env, cwd: cwd)
end

def read(dir, client = "codex", id = "session")
  JSON.parse(File.read(File.join(dir, "#{client}-#{id}.json")))
end

def rejected(label, result, code = 1)
  s, o, e = result
  check(label, s == code && o.empty? && !e.empty?)
end

def git(dir, *args)
  out, err, status = Open3.capture3(ENVIRONMENT, "git", *args, chdir: dir, unsetenv_others: true)
  raise "fixture git failed: #{err}" unless status.success?
  out
end

def repo(name, ignored: true)
  dir = File.join(TMP, name)
  FileUtils.mkdir_p(dir)
  git(dir, "init", "-q")
  File.write(File.join(dir, ".gitignore"), ".agent-session-progress/\n") if ignored
  dir
end

s, o, e = call(["--help"])
check("help includes input and example", s == 0 && e.empty? && o.include?('"steps"') && o.include?("--watch"))
%w[update show list locate].each { |cmd| check("#{cmd} help", call([cmd, "--help"])[0] == 0) }
[
  [], ["wrong"], ["update", "--client", "codex"], ["update", "--stdin"],
  ["list", "--client", "codex"], ["show", "--latest", "--session-id", "s"],
  ["show", "--dir"], ["list", "--json", "--json"], ["locate", "--client", "other"]
].each_with_index { |args, i| rejected("usage #{i}", call(args), 2) }

dir = File.join(TMP, "state")
s, o, e = update(dir)
check("create and UTF-8 under C locale", s == 0 && e.empty? && JSON.parse(o)["revision"] == 1)
record = read(dir)
check("initial defaults and history", record["steps"][0]["state"] == "pending" && record["steps"][0]["result"] == "" &&
                                     record["history"].size == 1 && record["history"][0]["step"] == "inspect" && record["history_dropped"] == 0)
check("private directory and record", File.stat(dir).mode & 0o777 == 0o700 && File.stat(File.join(dir, "codex-session.json")).mode & 0o777 == 0o600)
check("timestamp milliseconds", record["updated_at"].match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/))
s, = update(dir, { "purpose" => "実装する", "steps" => [{ "id" => "inspect", "state" => "done", "result" => "規約を確認した" },
  { "id" => "implement", "title" => "実装する", "state" => "active" }, { "id" => "verify", "title" => "検査する", "state" => "active" }], "decisions" => [DECISION] })
record2 = read(dir)
check("merge and parallel active", s == 0 && record2["revision"] == 2 && record2["created_at"] == record["created_at"] &&
  record2["steps"].map { |v| v["id"] } == %w[inspect implement verify] && record2["steps"][0]["title"] == "規約を確かめる" && record2["history"].size == 4)
s, = update(dir, { "steps" => [{ "id" => "inspect", "state" => "done" }], "decisions" => [] })
check("no-op step has no history and decisions replaced", s == 0 && read(dir)["history"].size == 4 && read(dir)["decisions"].empty? && read(dir)["revision"] == 3)
s, = update(dir, { "steps" => [{ "id" => "verify", "state" => "skipped", "result" => "別途確かめる" }], "decisions" => [DECISION] })
s, o, = call(["show", "--dir", dir, "--client", "codex", "--session-id", "session"])
check("plain show counts skip and recommendation", s == 0 && o.include?("自己申告 / codex / session") && o.include?("1 / 2 段") &&
  o.include?("[done]") && o.include?("規約を確認した") && o.include?("推奨: 作業ツリー"))
s, o, = call(["show", "--dir", dir, "--client", "codex", "--session-id", "session", "--json"])
check("show JSON stored shape", s == 0 && JSON.parse(o) == read(dir))

# 入力を拒否した場合、前の file と file 一覧を保ち、本文・値を診断へ出さない。
secret = ["ghp_", "X" * 36].join
warning = ["token", "=", '"SESSION_TEST_ONLY"'].join(" ")
allow = ["public-safety", ": allow"].join
bad_patches = [
  nil, [], true, 1, { "unknown" => "DO_NOT_ECHO" }, { "purpose" => nil }, { "purpose" => "" },
  { "purpose" => "あ" * 241 }, { "purpose" => "a\nb" }, { "purpose" => "a\tb" }, { "purpose" => "a\u202eb" },
  { "purpose" => "a\u0085b" }, { "purpose" => "a\u061cb" }, { "purpose" => "a\u2066b" },
  { "steps" => {} }, { "steps" => [nil] }, { "steps" => [{ "id" => "Bad" }] },
  { "steps" => [{ "id" => "a" * 33 }] }, { "steps" => [{ "id" => "new" }] },
  { "steps" => [{ "id" => "new", "title" => "" }] }, { "steps" => [{ "id" => "new", "title" => "あ" * 81 }] },
  { "steps" => [{ "id" => "inspect", "state" => "invalid" }] }, { "steps" => [{ "id" => "inspect", "state" => 1 }] },
  { "steps" => [{ "id" => "inspect", "result" => "あ" * 241 }] },
  { "steps" => [{ "id" => "inspect", "state" => "done", "result" => "" }] },
  { "steps" => [{ "id" => "inspect", "state" => "skipped", "result" => "" }] },
  { "steps" => [{ "id" => "inspect", "other" => true }] }, { "steps" => [{ "id" => "inspect" }, { "id" => "inspect" }] },
  { "decisions" => nil }, { "decisions" => [DECISION, DECISION] }, { "decisions" => [DECISION.merge("other" => 1)] },
  { "decisions" => [DECISION.reject { |k, _| k == "recommended" }] },
  { "decisions" => [DECISION.merge("recommended" => 2)] }, { "decisions" => [DECISION.merge("recommended" => -1)] },
  { "decisions" => [DECISION.merge("recommended" => 0.0)] }, { "decisions" => [DECISION.merge("question" => "あ" * 241)] },
  { "decisions" => [DECISION.merge("options" => [""])] }, { "decisions" => [DECISION.merge("options" => ["あ" * 121])] },
  { "decisions" => [DECISION.merge("options" => ["a"] * 5)] }, { "decisions" => [DECISION.merge("options" => [], "recommended" => 0)] },
  { "decisions" => 9.times.map { |i| DECISION.merge("id" => "d#{i}") } },
  { "revision" => 0 }, { "schema_version" => 2 }, { "history" => [] }, { "created_at" => "anything" },
  { "purpose" => secret }, { "purpose" => warning }, { "purpose" => allow },
  { "purpose" => File.join("/Users", "session-progress-test", "private") },
  '{"purpose":"first","purpose":"DO_NOT_ECHO"}', '{"steps":[{"id":"a","id":"b"}]}',
  '{"purpose":"a","\u0070urpose":"b"}', "{\"purpose\":\"\xff\"}".b, "{", " " * (32 * 1024 + 1)
]
before = File.binread(File.join(dir, "codex-session.json"))
files_before = Dir.children(dir).sort
bad_patches.each_with_index do |patch, index|
  input = patch.is_a?(String) ? patch : JSON.generate(patch)
  result = update(dir, input, env: { "HOME" => File.join("/Users", "session-progress-test") })
  rejected("bad input #{index}", result)
  check("bad input #{index} preserves record and files", File.binread(File.join(dir, "codex-session.json")) == before && Dir.children(dir).sort == files_before)
  check("bad input #{index} does not echo", !result[1..2].join.include?("DO_NOT_ECHO") && !result[1..2].join.include?(secret) && !result[1..2].join.include?("SESSION_TEST_ONLY"))
end

# 最大の件数・文字数を受理し、一つ超えた段の追加を拒否する。
boundary = File.join(TMP, "boundary")
large = { "purpose" => "あ" * 240, "steps" => 32.times.map { |i| { "id" => "s#{i}", "title" => "あ" * 80, "result" => "あ" * 240 } },
  "decisions" => 8.times.map { |i| DECISION.merge("id" => "d#{i}", "question" => "あ" * 240, "options" => ["あ" * 120] * 4, "recommended" => 3) } }
# 大きい record は、入力上限を守って分割して作る。
check("maximum purpose", update(boundary, { "purpose" => large["purpose"], "steps" => [large["steps"][0]] })[0] == 0)
large["steps"].drop(1).each_slice(8) { |steps| check("maximum step fields", update(boundary, { "steps" => steps })[0] == 0) }
check("maximum decisions", update(boundary, { "decisions" => large["decisions"] })[0] == 0)
check("all 32 steps", read(boundary)["steps"].size == 32)
rejected("33rd step", update(boundary, { "steps" => [{ "id" => "s33", "title" => "追加" }] }))
check("zero options and null recommendation", update(boundary, { "decisions" => [DECISION.merge("options" => [], "recommended" => nil)] })[0] == 0)
check("max step id", update(File.join(TMP, "id-boundary"), { "purpose" => "目的", "steps" => [{ "id" => "a" * 32, "title" => "段" }] })[0] == 0)
padded = JSON.generate("purpose" => "境界の確認")
check("exact input byte bound", update(dir, padded + " " * (32 * 1024 - padded.bytesize))[0] == 0)
rejected("input byte bound plus one", update(dir, padded + " " * (32 * 1024 - padded.bytesize + 1)))

# 履歴をまとめて更新し、古いものを捨てた件数と順を確かめる。
7.times do |round|
  check("history round #{round}", update(boundary, { "steps" => 32.times.map { |i| { "id" => "s#{i}", "result" => "結果 #{round}" } } })[0] == 0)
end
hist = read(boundary)
check("history truncation and order", hist["history"].size == 200 && hist["history_dropped"] == 56 &&
  hist["history"][0]["step"] == "s24" && hist["history"][0]["result"] == "結果 0" && hist["history"][-1]["result"] == "結果 6")

# 壊れた既存 record は新規扱いにしない。読み取りも同じ検査で止める。
corrupt = File.join(TMP, "corrupt")
check("corrupt fixture", update(corrupt)[0] == 0)
path = File.join(corrupt, "codex-session.json")
valid = File.read(path)
mutations = ["{", "\xff".b, valid.sub('"schema_version":1', '"schema_version":2'),
  valid.sub('"revision":1', '"revision":0'), valid.sub('"schema_version":1', '"schema_version":1.0'),
  valid.sub('"session_id":"session"', '"session_id":"other"'),
  valid.sub('"client":"codex"', '"client":"claude-code"'), valid.sub('"history_dropped":0', '"history_dropped":-1'),
  valid.sub('"schema_version":1', '"schema_version":1,"schema_version":1'),
  valid.sub('"steps":', '"unknown":0,"steps":'), valid.sub(/\d{4}-\d\d-\d\dT/, '2026-02-31T'),
  valid + " " * (512 * 1024)]
mutations.each_with_index do |body, i|
  File.binwrite(path, body)
  rejected("corrupt update #{i}", update(corrupt))
  rejected("corrupt show #{i}", call(["show", "--latest", "--dir", corrupt, "--json"]))
  check("corrupt file unchanged #{i}", File.binread(path) == body.b)
end
File.binwrite(path, valid + " " * (512 * 1024 - valid.bytesize))
check("file byte exact boundary", call(["show", "--latest", "--dir", corrupt, "--json"])[0] == 0)
File.binwrite(path, valid + " " * (512 * 1024 - valid.bytesize + 1))
rejected("file byte boundary plus one", call(["show", "--latest", "--dir", corrupt]))
File.write(path, valid)

# 既存の文字列と履歴も gate を通す。入力だけの検査では通ってしまうケース。
%w[purpose history].each do |field|
  bad = JSON.parse(valid)
  field == "purpose" ? bad["purpose"] = secret : bad["history"][0]["result"] = secret
  File.write(path, JSON.generate(bad))
  previous = File.binread(path)
  rejected("gate sees existing #{field}", update(corrupt, "{}"))
  check("existing secret preserved without new writes", File.binread(path) == previous)
end
File.write(path, valid)

# gate の stdout/stderr をこちらの診断に転記しない。警告は exit 0 でも拒否する。
gate_copy = File.join(TMP, "gate.backup")
FileUtils.cp(GATE, gate_copy)
begin
  ["echo DO_NOT_ECHO >&2\nexit 0", "echo DO_NOT_ECHO\nexit 1", "exit 2"].each do |body|
    File.write(GATE, "#!/bin/sh\n#{body}\n")
    result = update(corrupt, { "purpose" => "変える" })
    rejected("gate failure #{body.lines.last.strip}", result)
    check("gate output not echoed", !result[1..2].join.include?("DO_NOT_ECHO") && File.read(path) == valid)
  end
  File.chmod(0o644, GATE)
  rejected("gate not executable", update(corrupt))
  File.unlink(GATE)
  rejected("missing gate", update(corrupt))
ensure
  FileUtils.cp(gate_copy, GATE)
  File.chmod(0o755, GATE)
end

# rename より前の実 I/O 失敗を注入し、旧版と一時 file の片付けを確かめる。
original_fsync = File.instance_method(:fsync)
File.send(:define_method, :fsync) { raise IOError, "DO_NOT_ECHO" }
begin
  begin
    SessionProgress.write_record(path, "new")
    check("fsync failure raised", false)
  rescue IOError
    check("fsync failure retains old revision", File.read(path) == valid && Dir.children(corrupt).sort == [".lock", "codex-session.json"])
  end
ensure
  File.send(:define_method, :fsync, original_fsync)
end

# session の識別。両方の env があっても明示 client の env だけを使う。
ids = File.join(TMP, "ids")
both = { "CODEX_THREAD_ID" => "codex-env", "CLAUDE_CODE_SESSION_ID" => "claude-env" }
rejected("missing session id", update(ids, id: nil))
check("codex env", update(ids, id: nil, env: both)[0] == 0 && File.file?(File.join(ids, "codex-codex-env.json")))
check("claude env", update(ids, id: nil, client: "claude-code", env: both)[0] == 0 && File.file?(File.join(ids, "claude-code-claude-env.json")))
check("explicit overrides env", update(ids, id: "explicit", env: both)[0] == 0 && read(ids, "codex", "explicit")["session_id"] == "explicit")
check("maximum session id", update(ids, id: "A" * 128)[0] == 0)
["A" * 129, "../escape", "", "a.b", "日本語"].each { |id| rejected("invalid id", update(ids, id: id)) }
s, o, = call(["locate", "--client", "codex", "--dir", ids], env: both)
check("locate env", s == 0 && o.strip == File.join(ids, "codex-codex-env.json"))
absent = File.join(TMP, "not-created")
s, o, = call(["locate", "--client", "codex", "--session-id", "x", "--dir", absent])
check("locate does not create", s == 0 && !File.exist?(absent) && o.strip == File.join(absent, "codex-x.json"))
rejected("show missing", call(["show", "--latest", "--dir", absent]), 4)
s, o, e = call(["list", "--dir", absent, "--json"])
check("empty list", s == 0 && o.strip == "[]" && e.empty? && !File.exist?(absent))
rejected("outside git requires override", call(["locate", "--client", "codex", "--session-id", "s"]))
rejected("absolute override required", call(["locate", "--client", "codex", "--session-id", "s", "--dir", "relative"]))
s, o, = call(["locate", "--client", "codex", "--session-id", "s"], env: { "AGENT_TOOLS_SESSION_PROGRESS_DIR" => absent })
check("dir env", s == 0 && o.strip == File.join(absent, "codex-s.json"))
s, o, = call(["locate", "--client", "codex", "--session-id", "s", "--dir", ids], env: { "AGENT_TOOLS_SESSION_PROGRESS_DIR" => absent })
check("dir flag wins", s == 0 && o.strip == File.join(ids, "codex-s.json"))

# git の場所の検査。global config を読まず、一時 repo だけを変更する。
repo_dir = repo("repo")
state_dir = File.join(repo_dir, ".agent-session-progress")
FileUtils.mkdir_p(File.join(repo_dir, "sub"))
s, = call(["update", "--client", "codex", "--session-id", "s", "--stdin"], input: JSON.generate(INITIAL), cwd: File.join(repo_dir, "sub"))
check("default root from subdirectory", s == 0 && File.file?(File.join(state_dir, "codex-s.json")))
noignore = repo("noignore", ignored: false)
rejected("missing ignore", update(File.join(noignore, ".agent-session-progress"), cwd: noignore))
check("missing ignore creates nothing", !File.exist?(File.join(noignore, ".agent-session-progress")))
tracked = repo("tracked")
tracked_state = File.join(tracked, ".agent-session-progress")
FileUtils.mkdir_p(tracked_state)
File.write(File.join(tracked_state, "OTHER.json"), "not a record")
git(tracked, "add", "-f", "--", ".agent-session-progress/OTHER.json")
rejected("tracked sibling", update(tracked_state, cwd: tracked))
rejected("literal env cannot bypass tracked", update(tracked_state, cwd: tracked, env: { "GIT_LITERAL_PATHSPECS" => "1" }))
case_repo = repo("case-tracked")
FileUtils.mkdir_p(File.join(case_repo, ".AGENT-SESSION-PROGRESS"))
File.write(File.join(case_repo, ".AGENT-SESSION-PROGRESS", "other"), "x")
git(case_repo, "add", "-f", "--", ".AGENT-SESSION-PROGRESS/other")
rejected("case insensitive tracked directory", update(File.join(case_repo, ".agent-session-progress"), cwd: case_repo))
%w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].each do |key|
  rejected("git env #{key}", update(state_dir, cwd: repo_dir, env: { key => "" }))
end
nested = File.join(state_dir, "nested")
git(state_dir, "init", "-q", nested)
rejected("override repository root", update(nested, cwd: repo_dir))
# override の記号を pathspec の glob にしない。
weird = File.join(repo_dir, "state[1]")
File.write(File.join(repo_dir, ".gitignore"), ".agent-session-progress/\nstate*/\n")
check("literal override path", update(weird, cwd: repo_dir)[0] == 0)

# directory / record / lock の symlink、FIFO、directory を拒否し、リンク先に触れない。
external = File.join(TMP, "external")
FileUtils.mkdir_p(external)
linked = File.join(TMP, "linked")
File.symlink(external, linked)
rejected("directory symlink", update(linked))
check("directory link target unchanged", Dir.empty?(external))
%w[record lock].each do |kind|
  %w[symlink directory fifo].each do |type|
    base = File.join(TMP, "#{kind}-#{type}")
    FileUtils.mkdir_p(base)
    leaf = File.join(base, kind == "lock" ? ".lock" : "codex-session.json")
    case type
    when "symlink" then File.symlink(File.join(external, "untouched"), leaf)
    when "directory" then Dir.mkdir(leaf)
    when "fifo"
      _o, _e, status = Open3.capture3("mkfifo", leaf)
      raise "mkfifo failed" unless status.success?
    end
    rejected("#{kind} #{type}", update(base))
    check("symlink target not created", !File.exist?(File.join(external, "untouched")))
  end
end
# 所有者の違いは権限を変えず、stat の値だけを代用する。
original_lstat = SessionProgress.method(:lstat)
SessionProgress.define_singleton_method(:lstat) { |_path| Struct.new(:directory?, :uid).new(true, Process.uid + 1) }
begin
  begin
    SessionProgress.check_directory(dir)
    check("foreign owner refused", false)
  rescue SessionProgress::Refused
    check("foreign owner refused", true)
  end
ensure
  SessionProgress.define_singleton_method(:lstat, original_lstat)
end

# lock は別 process でも共有される。競合した更新は排他の中で読み直して両方残す。
parallel = File.join(TMP, "parallel")
check("parallel fixture", update(parallel)[0] == 0)
lock_path = File.join(parallel, ".lock")
File.open(lock_path, "r+") do |lock|
  lock.flock(File::LOCK_EX)
  one = Thread.new { update(parallel, { "steps" => [{ "id" => "one", "title" => "一つ目" }] }) }
  two = Thread.new { update(parallel, { "steps" => [{ "id" => "two", "title" => "二つ目" }] }) }
  sleep 0.2
  check("updates wait for lock", one.alive? && two.alive? && read(parallel)["revision"] == 1)
  lock.flock(File::LOCK_UN)
  check("parallel updates complete", one.value[0] == 0 && two.value[0] == 0)
end
check("parallel updates both retained", read(parallel)["revision"] == 3 && read(parallel)["steps"].map { |v| v["id"] }.sort == %w[inspect one two])
File.open(lock_path, "r+") do |lock|
  lock.flock(File::LOCK_EX)
  rejected("lock timeout", update(parallel, "{}"), 3)
end

# latest/list は updated_at の順。client の絞り込み、env と明示 ID、曖昧さを確かめる。
show_dir = File.join(TMP, "show")
check("show old", update(show_dir, id: "old")[0] == 0)
check("show new", update(show_dir, id: "new", client: "claude-code")[0] == 0)
s, o, = call(["show", "--latest", "--dir", show_dir, "--json"])
check("latest across clients", s == 0 && JSON.parse(o)["session_id"] == "new")
s, o, = call(["show", "--latest", "--client", "codex", "--dir", show_dir, "--json"])
check("latest client filter", s == 0 && JSON.parse(o)["session_id"] == "old")
s, o, = call(["show", "--session-id", "old", "--dir", show_dir, "--json"])
check("show explicit id without client", s == 0 && JSON.parse(o)["client"] == "codex")
s, o, = call(["show", "--dir", show_dir, "--json"], env: { "CODEX_THREAD_ID" => "old" })
check("show single env", s == 0 && JSON.parse(o)["session_id"] == "old")
rejected("show ambiguous env", call(["show", "--dir", show_dir], env: both), 2)
check("same id different client fixture", update(show_dir, id: "old", client: "claude-code")[0] == 0)
rejected("ambiguous explicit id", call(["show", "--session-id", "old", "--dir", show_dir]), 2)
s, o, = call(["list", "--dir", show_dir, "--json"])
check("list JSON newest first", s == 0 && JSON.parse(o).map { |v| [v["client"], v["session_id"]] } == [["claude-code", "old"], ["claude-code", "new"], ["codex", "old"]])
s, o, = call(["list", "--dir", show_dir])
check("list plain one line each", s == 0 && o.lines.size == 3 && o.lines.first.include?("claude-code / old") && o.include?("調査と実装"))

%w[0 61 1.5 -1 bad 2].each do |seconds|
  rejected("watch invalid or non-TTY #{seconds}", call(["show", "--dir", dir, "--latest", "--watch", seconds]), 2)
end
# PTY で前面の watch を起動し、更新後の再読込と INT による停止を観測する。
watch_output = +""
watch_status = nil
PTY.spawn(ENVIRONMENT, SCRIPT, "show", "--dir", parallel, "--latest", "--watch", "1", unsetenv_others: true, chdir: TMP) do |reader, writer, pid|
  begin
    Timeout.timeout(8) do
      watch_output << reader.readpartial(4096).force_encoding(Encoding::UTF_8) until watch_output.include?("revision 3")
      check("update while watching", update(parallel, { "purpose" => "再読込を確認" })[0] == 0)
      watch_output << reader.readpartial(4096).force_encoding(Encoding::UTF_8) until watch_output.include?("再読込を確認")
    end
    Process.kill("INT", pid)
    Timeout.timeout(5) { _, watch_status = Process.wait2(pid) }
  ensure
    begin
      Process.kill("TERM", pid) unless watch_status
      Process.wait(pid) unless watch_status
    rescue Errno::ESRCH, Errno::ECHILD
      # 既に回収済み。
    end
    reader.close
    writer.close
  end
end
check("watch rereads and stops", watch_output.include?("revision 4") && watch_status && watch_status.success?)

puts "session-progress tests: #{@failed} failure(s)"
exit(@failed.zero? ? 0 : 1)
RUBY
