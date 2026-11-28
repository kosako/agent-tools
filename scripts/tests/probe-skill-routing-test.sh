#!/bin/sh
# scripts/lib/probe_skill_routing.rb の self-test (#372 / #384)。
# - Codex の起動の境界: probe の Codex の起動に、監査 / review と同じ境界 (user config の MCP /
#   connector と rules を外し、sandbox の外へ届く feature を disable する) が付くこと、起動の前に flag と
#   feature の在否を確かめて欠けていれば Codex を起動せずに exit 2 になることを、PATH 上の偽の codex で
#   確かめる。
# - model の選択: --model が無いときは CODEX_HOME の fixture の config.toml の top-level (最初の table
#   header より前) の model だけを使い、無ければエラーにする。
# - raw log の保存先: raw dir の外を指す case id では CLI を起動せずに exit 2 で止まり、raw dir の外に
#   何も作らない。
# - event の解析 (parse_claude / parse_codex): 固定の JSONL で、発火順と重複除去・usage の合計・探索読みの
#   閾値などを固定する。--max-turns の打ち切り (error_max_turns) の扱いは PATH 上の偽の claude で確かめる。
# - 中断の後片付け (#568): run_command を中断すると、子の process group を止めてすぐ戻る。help の --model の
#   説明が codex の model の選び方 (config の top-level、無ければエラー) と合う。
# 実 claude / codex / network / 実 ~/.codex には触れない。実際の CLI の event 形式との一致は対象外
# (実機で --smoke)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/scripts/lib/probe_skill_routing.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- Ruby unit checks: 起動の argv -------------------------------------------------
empty_home="$tmp/codex-home-empty"
mkdir -p "$empty_home"
skill_home="$tmp/codex-home-skills"
mkdir -p "$skill_home/skills/personal-a"
printf -- '---\nname: personal-a\ndescription: a\n---\n' > "$skill_home/skills/personal-a/SKILL.md"

ruby -r"$script_dir/lib/check_helper" - "$src" "$empty_home" "$skill_home" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

ENV["CODEX_HOME"] = ARGV[1]
argv = P.codex_argv({ model: "m-x" }, "/proj", ["personal-a"])
check("境界つきの argv を固定する",
      argv == ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
               "--ignore-user-config", "--ignore-rules", "-s", "read-only", "-c", 'approval_policy="never"',
               "--disable", "apps", "--disable", "computer_use", "--disable", "browser_use",
               "-C", "/proj", "-m", "m-x", "-"])
check("disable する feature の一覧", P::CODEX_DISABLE_FEATURES == %w[apps computer_use browser_use])
check("起動の前に確かめる flag の一覧", P::CODEX_HELP_MARKERS == %w[--ignore-user-config --ignore-rules --disable])

# 候補と同名の user skill の無効化 (-c skills.config) は、子の Codex home (--codex-home) を見る (#802)。境界と両立し、
# prompt (stdin の -) の前に付く。親の CODEX_HOME に同名の skill があっても、子の home に無ければ付けない
ENV["CODEX_HOME"] = ARGV[1]
argv = P.codex_argv({ model: "m-x", codex_home: ARGV[2] }, "/proj", ["personal-a"])
check("境界の flag は skills.config の override と両立する",
      argv.include?("--ignore-user-config") && argv.include?("--ignore-rules") &&
      argv[-3] == "-c" && argv[-2].start_with?("skills.config=[{path=") && argv[-1] == "-")
check("override の path は子の Codex home の下", argv[-2].include?(File.join(ARGV[2], "skills", "personal-a", "SKILL.md")))
ENV["CODEX_HOME"] = ARGV[2]
argv = P.codex_argv({ model: "m-x", codex_home: ARGV[1] }, "/proj", ["personal-a"])
check("親の Codex home にだけ同名の skill があっても override を付けない", !argv.include?("-c") || argv.none? { |a| a.start_with?("skills.config=") })
argv = P.codex_argv({ model: "m-x" }, "/proj", ["personal-a"])
check("子の Codex home が無い (dry-run で省いた) ときは override を付けない", argv.none? { |a| a.start_with?("skills.config=") })
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: config からの model の選択 ---------------------------------------
# top-level に model が無く profile の table にだけある config と、両方にある config
profile_home="$tmp/codex-home-profile-model"
mkdir -p "$profile_home"
printf '%s\n' '# top-level に model は無い' '' 'approval_policy = "never"' '' '[profiles.other]' 'model = "CANARY-PROFILE"' \
  > "$profile_home/config.toml"
top_home="$tmp/codex-home-top-model"
mkdir -p "$top_home"
printf '%s\n' '# comment' '' 'approval_policy = "never"' 'model = "m-top"' '' '[profiles.other]' 'model = "CANARY-PROFILE"' \
  > "$top_home/config.toml"

ruby -r"$script_dir/lib/check_helper" - "$src" "$profile_home" "$top_home" "$empty_home" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

# model が無い config で codex_model / codex_argv が --model is required のエラーになるか
def model_required_error?
  yield
  false
rescue ProbeSkillRouting::Error => e
  e.message.include?("--model is required")
end

ENV["CODEX_HOME"] = ARGV[1]
check("profile の table にだけある model は top-level の model として使わない (エラーにする)",
      model_required_error? { P.codex_model({}) })
check("profile の table にだけある model で Codex を起動しない",
      model_required_error? { P.codex_argv({}, "/proj", []) })

ENV["CODEX_HOME"] = ARGV[2]
check("top-level の model を使う", P.codex_model({}) == "m-top")
argv = P.codex_argv({}, "/proj", [])
check("top-level の model を -m に渡す", argv[argv.index("-m") + 1] == "m-top")
check("--model があれば config より優先する", P.codex_model({ model: "m-x" }) == "m-x")

ENV["CODEX_HOME"] = ARGV[3]
check("config.toml が無ければ --model is required のエラーにする", model_required_error? { P.codex_model({}) })

# help の --model の説明は、codex では CLI の既定に任せず、config の top-level か --model が要ることを書く (#568)
model_help = P::USAGE.lines.drop_while { |l| l !~ /\A\s+--model\s/ }.take_while { |l| l !~ /\A\s+--repeat\s/ }.join
check("help の --model は claude-code の省略を CLI の既定と書く", model_help.include?("claude-code は省略すると CLI の既定"))
check("help の --model は codex の省略を config の top-level の model とエラーと書く",
      model_help.include?("codex は省略すると") && model_help.include?("top-level") && model_help.include?("エラー"))
check("help の --model は codex を CLI の既定に任せると書かない", model_help.include?("CLI の既定には任せない"))
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: 中断の後片付け (#568) ---------------------------------------------
# run_command を中断 (Ctrl-C 相当) すると、専用の process group で起動した子を止めてすぐ戻る (Open3 の終了待ちで
# 止まらず、子を残さない)。子は別の process group なので端末の SIGINT は届かない。
ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

def alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

pidfile = File.join(ARGV[1], "interrupt-child.pid")
runner = Thread.new do
  P.run_command(["sh", "-c", %(echo $$ > "$0"; exec sleep 60), pidfile], chdir: ARGV[1], stdin: "prompt", timeout: 30)
  :completed
rescue Interrupt
  :interrupted
end
runner.report_on_exception = false
deadline = Time.now + 5
sleep 0.05 until (File.file?(pidfile) && !File.read(pidfile).strip.empty?) || Time.now > deadline
child = File.file?(pidfile) ? File.read(pidfile).to_i : 0
check("中断の test の子が起動した", child.positive? && alive?(child))
started = Time.now
runner.raise(Interrupt)
returned = !runner.join(10).nil?
check("中断した run_command は 10 秒の中で戻る", returned)
check("中断までの時間が timeout (30 秒) より短い", Time.now - started < 10)
if returned
  check("中断した run_command は Interrupt を送り直す", runner.value == :interrupted)
  gone_by = Time.now + 3
  sleep 0.05 while child.positive? && alive?(child) && Time.now < gone_by
  check("中断した run_command は子の process group を残さない", child.positive? && !alive?(child))
elsif child.positive?
  # 後片付けが外れて戻らないときも test を止めない。子の group (pgid == 子の pid) を test が止めてから、
  # runner を期限つきで回収する (runner.value は期限なしで待つので読まない)。
  begin
    Process.kill("KILL", -child)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  runner.join(10)
end
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: raw log の保存先 -------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

raw = File.join("out", "results.json.raw")
check("raw log は raw dir の直下に <case id>-<n>.<ext> で保存する",
      P.raw_log_path(raw, "a-primary", 1, "jsonl") == File.join(raw, "a-primary-1.jsonl") &&
      P.raw_log_path(raw, "a.b_c-2", 3, "stderr") == File.join(raw, "a.b_c-2-3.stderr"))
# sub/../escaped と sub/../../results.json.raw/escaped は字面の正規化では raw dir の直下に戻るが、
# 書き込みは raw dir の中の symlink を経て外に届きうる
["../escaped", "../../escaped", "sub/escaped", "sub/../escaped", "sub/../../results.json.raw/escaped"].each do |id|
  stopped = begin
    P.raw_log_path(raw, id, 1, "jsonl")
    false
  rescue P::Error => e
    e.message.include?("outside")
  end
  check("raw dir の外を指す case id (#{id}) は保存の前に止める", stopped)
end
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: description の文字数 (#417) -------------------------------------------
fm_dir="$tmp/fm-length"
mkdir -p "$fm_dir"
ruby -r"$script_dir/lib/check_helper" - "$src" "$fm_dir" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting
dir = ARGV[1]

def skill(dir, name, content)
  path = File.join(dir, "#{name}.md")
  File.write(path, content)
  path
end

# frontmatter を YAML として読んだ値を数える。行の字面を数えると、YAML のコメントで切れた description を
# 全文の長さで数える
plain = skill(dir, "plain", "---\nname: a\ndescription: 委譲する「packet #N を」です\n---\n\n# A\n")
check("YAML のコメントで切れた description は、切れた後の長さ (委譲する「packet) で数える",
      P.description_length(plain) == "委譲する「packet".length)
quoted = skill(dir, "quoted", "---\nname: a\ndescription: \"委譲する「packet #N を」です\"\n---\n\n# A\n")
check("引用符で囲んだ description は全文の長さで数える",
      P.description_length(quoted) == "委譲する「packet #N を」です".length)
folded = skill(dir, "folded", "---\nname: a\ndescription: >\n  first\n  second\n---\n\n# A\n")
check("block scalar は YAML が読む値 (折り返しを空白にし、末尾の改行を含む) で数える",
      P.description_length(folded) == "first second\n".length)
crlf = skill(dir, "crlf", "---\r\nname: a\r\ndescription: crlf value\r\n---\r\n\r\n# A\r\n")
check("CRLF の frontmatter も読む", P.description_length(crlf) == "crlf value".length)
check("frontmatter が無い skill は 0", P.description_length(skill(dir, "none", "# A\n")) == 0)
check("description が文字列でない skill は 0",
      P.description_length(skill(dir, "list", "---\nname: a\ndescription: [x]\n---\n")) == 0)
broken = skill(dir, "broken", "---\nname: [\n---\n")
stopped = begin
  P.description_length(broken)
  false
rescue P::Error => e
  e.message.include?("YAML")
end
check("YAML として読めない frontmatter は数えずに止める", stopped)
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: event の解析 (固定の JSONL。CLI は起動しない) -------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

def jsonl(*events)
  events.map { |e| e.is_a?(String) ? e : JSON.generate(e) }.join("\n") + "\n"
end

def skill_use(input)
  { "type" => "tool_use", "name" => "Skill", "input" => input }
end

def command_item(command, output = nil)
  item = { "type" => "command_execution", "command" => command }
  item["aggregated_output"] = output if output
  { "type" => "item.completed", "item" => item }
end

# claude-code (stream-json)
claude = jsonl(
  { "type" => "system", "subtype" => "init", "model" => "m-claude" },
  { "type" => "assistant", "message" => {
    "usage" => { "input_tokens" => 10, "cache_creation_input_tokens" => 20, "cache_read_input_tokens" => 30,
                 "output_tokens" => 1 },
    "content" => [skill_use("skill" => "skill-b"), { "type" => "text", "text" => "x" }],
  } },
  { "type" => "assistant", "message" => {
    "usage" => { "input_tokens" => 1000 },
    "content" => [skill_use("skill" => "skill-a"), skill_use("skill" => "skill-b"), skill_use("name" => "skill-c"),
                  { "type" => "tool_use", "name" => "Read", "input" => { "skill" => "skill-d" } }],
  } },
  { "type" => "result", "subtype" => "error_max_turns",
    "usage" => { "input_tokens" => 100, "cache_creation_input_tokens" => 200, "cache_read_input_tokens" => 300,
                 "output_tokens" => 7 } }
)
r = P.parse_claude(claude)
check("claude: Skill の起動を発火順に重複を除いて拾い、input.skill が無ければ input.name を使う",
      r[:observed] == %w[skill-b skill-a skill-c])
check("claude: first_prompt_tokens は最初の assistant の usage の 3 key の合計", r[:first_prompt_tokens] == 60)
check("claude: prompt_tokens は result の usage の 3 key の合計", r[:prompt_tokens] == 600)
check("claude: output_tokens は result の usage の値", r[:output_tokens] == 7)
check("claude: result の subtype を拾う", r[:subtype] == "error_max_turns")
check("claude: system の model を拾う", r[:model] == "m-claude")
# init ごとの、自動の memory の状態 (#770)。init でない system の event は数えない
init = { "type" => "system", "subtype" => "init", "model" => "m" }
listed = init.merge("memory_paths" => { "auto" => "/x" })
{ [] => [], [init] => %w[not-listed], [listed, init] => %w[listed not-listed], [listed.merge("subtype" => "status")] => [] }.each do |events, want|
  got = P.parse_claude(jsonl(*events))[:memory_states]
  check("claude: init ごとの自動の memory の状態は #{want.inspect} (#{got.inspect})", got == want)
end

broken = "{\"type\":\"result\"\nnot json\n[1, 2]\n" +
         jsonl({ "type" => "result", "subtype" => "success", "usage" => { "input_tokens" => 3, "output_tokens" => 1 } })
r = (P.parse_claude(broken) rescue nil)
check("claude: 不正な JSON の行と object でない行を飛ばして、後続の event を読む",
      !r.nil? && r[:prompt_tokens] == 3 && r[:subtype] == "success")

# codex (exec --json)
names = %w[skill-a skill-b skill-c skill-d skill-e skill-f skill-g]
codex = jsonl(
  { "type" => "thread.started" },
  command_item("ls .agents/skills ~/.codex/skills",
               "/p/.agents/skills/skill-c/SKILL.md\n/home/u/.codex/skills/skill-d/SKILL.md\n"),
  command_item("cat .agents/skills/skill-b/SKILL.md"),
  command_item("sed -n 1,80p /home/u/.codex/skills/skill-a/SKILL.md && cat .agents/skills/skill-b/SKILL.md"),
  { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => "done" } },
  { "type" => "turn.completed", "usage" => { "input_tokens" => 500, "cached_input_tokens" => 400, "output_tokens" => 9 } }
)
r = P.parse_codex(codex, names)
check("codex: command に現れた SKILL.md の読み取りを、scope を問わず読んだ順に重複を除いて拾う",
      r[:observed] == %w[skill-b skill-a])
check("codex: command の出力 (aggregated_output) に出た path は数えない", (r[:observed] & %w[skill-c skill-d]).empty?)
check("codex: prompt_tokens / output_tokens は turn.completed の usage の値", r[:prompt_tokens] == 500 && r[:output_tokens] == 9)
check("codex: first_prompt_tokens は取らない", r[:first_prompt_tokens].nil?)
check("codex: 探索読みでない run には note を付けない", r[:note].nil?)

# 探索読みの閾値の境界: 5 本は全部を採り、6 本は最初の 1 本だけを採る
reads = lambda do |n|
  jsonl(*names.first(n).map { |s| command_item("cat .agents/skills/#{s}/SKILL.md") },
        { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } })
end
r = P.parse_codex(reads.call(5), names)
check("codex: 5 本の読み取りは探索読みにしない (全部を observed に残す)", r[:observed] == names.first(5) && r[:note].nil?)
r = P.parse_codex(reads.call(6), names)
check("codex: 6 本の読み取りは探索読みとして最初の 1 本だけを採り、note に残す",
      r[:observed] == ["skill-a"] && r[:note].to_s.start_with?("survey: read 6 skills"))

# ---- reads (#720): 圧縮の前の読み取りの痕跡の全部と、copy の区別。行の ID は #720 の期待値の表 ----
r = P.parse_codex(reads.call(5), names)
check("P01: 5 本の reads は 5 件で、observed も 5 本", r[:reads].map { |e| e["skill"] } == names.first(5) && r[:observed] == names.first(5))
r = P.parse_codex(reads.call(6), names)
check("P04: 6 本の reads は 6 件で、observed は最初の 1 本のまま", r[:reads].map { |e| e["skill"] } == names.first(6) && r[:observed] == ["skill-a"])
check("reads は via command で、proj が無ければ copy は unknown", r[:reads].all? { |e| e["via"] == "command" && e["copy"] == "unknown" && e["sha256"].nil? })
six_same = jsonl(*6.times.map { command_item("cat .agents/skills/skill-a/SKILL.md") },
                 { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } })
r = P.parse_codex(six_same, names)
check("N01: 同じ skill を 6 回読んでも、reads は 6 件で探索読みにしない", r[:reads].length == 6 && r[:observed] == ["skill-a"] && r[:note].nil?)
# P15: cd の後の相対の読み取りは、名前を決められない読み取りとして残る
cd_read = jsonl(command_item("cat .agents/skills/skill-a/SKILL.md"), command_item("cd .agents/skills/skill-b && cat SKILL.md"),
                { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } })
r = P.parse_codex(cd_read, names)
check("P15: cd の後の cat SKILL.md は skill nil の reads になる", r[:reads].map { |e| e["skill"] } == ["skill-a", nil] && r[:observed] == ["skill-a"])
# P16: 出力にだけ現れた path は reads に足さない
r = P.parse_codex(jsonl(command_item("ls .agents/skills", "/p/.agents/skills/skill-b/SKILL.md\n"),
                        { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }), names)
check("P16: 出力 (aggregated_output) の path は reads に入らない", r[:reads].empty?)
# claude: Skill は listing、Read の file_path と Bash の command の SKILL.md も reads (P09〜P14)
claude_reads = jsonl({ "type" => "assistant", "message" => { "content" => [
  skill_use("skill" => "skill-a"),
  { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/x/.claude/skills/skill-b/SKILL.md" } },
  { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "cat .claude/skills/skill-c/SKILL.md && cat SKILL.md" } },
  { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/x/notes.md" } },
] } }, { "type" => "result", "subtype" => "success", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } })
r = P.parse_claude(claude_reads, names: names)
check("P14: claude は Skill・Read・Bash の SKILL.md を reads に残し、observed は Skill だけ",
      r[:observed] == ["skill-a"] && r[:reads].map { |e| [e["skill"], e["via"]] } ==
        [["skill-a", "skill"], ["skill-b", "read"], ["skill-c", "command"], [nil, "command"]])
check("claude の Skill の reads は copy listing", r[:reads].first["copy"] == "listing" && r[:reads].first["path"].nil?)
check("claude の reads は SKILL.md 以外の Read を入れない", r[:reads].none? { |e| e["path"].to_s.end_with?("notes.md") })
check("names が無ければ claude の Read の reads は skill nil", P.parse_claude(claude_reads)[:reads][1]["skill"].nil?)
# C01〜C08: copy の区別。proj の候補、home の同じ中身・違う中身、外を指す symlink、解決できない path
cdir = File.join(Dir.mktmpdir, "copy")
proj = File.join(cdir, "proj")
home = File.join(cdir, "home")
cand = File.join(proj, ".agents", "skills", "skill-a")
FileUtils.mkdir_p(cand)
File.write(File.join(cand, "SKILL.md"), "candidate body\n")
FileUtils.mkdir_p(File.join(home, ".codex", "skills", "skill-a"))
File.write(File.join(home, ".codex", "skills", "skill-a", "SKILL.md"), "old body\n")
FileUtils.mkdir_p(File.join(home, "same", "skill-a"))
File.write(File.join(home, "same", "skill-a", "SKILL.md"), "candidate body\n")
FileUtils.mkdir_p(File.join(proj, ".agents", "skills", "skill-b"))
FileUtils.mkdir_p(File.join(home, "outside", "skill-b"))
File.write(File.join(home, "outside", "skill-b", "SKILL.md"), "outside body\n")
File.symlink(File.join(home, "outside", "skill-b", "SKILL.md"), File.join(proj, ".agents", "skills", "skill-b", "SKILL.md"))
copy = ->(name, path) { P.classify_copy(name, path, proj: proj, home: home, tool: "codex") }
cand_sha = Digest::SHA256.hexdigest("candidate body\n")
check("C01: 候補を指す絶対 path は candidate", copy.call("skill-a", File.join(cand, "SKILL.md")) == ["candidate", cand_sha])
check("C02: cwd からの相対の path は candidate", copy.call("skill-a", ".agents/skills/skill-a/SKILL.md") == ["candidate", cand_sha])
FileUtils.mkdir_p(File.join(proj, ".agents", "skills", "x"))
check("C07: .. を含む path も、中間の dir が在れば実体で candidate", copy.call("skill-a", ".agents/skills/x/../skill-a/SKILL.md") == ["candidate", cand_sha])
# shell と同じく .. は実体の上で解く: 存在しない中間の dir を通る path は解決できない (字面で消さない。#801 の review)
check("C07: 存在しない中間の dir を通る .. は unknown", copy.call("skill-a", ".agents/skills/nope/../skill-a/SKILL.md") == ["unknown", nil])
# symlink の dir の後の .. は、link の指す先の親に上がる (字面では候補の置き場に見えても、実体は外)
File.symlink(File.join(home, "outside"), File.join(proj, ".agents", "skills", "link"))
FileUtils.mkdir_p(File.join(home, "skill-a"))
File.write(File.join(home, "skill-a", "SKILL.md"), "physical body\n")
check("C07: symlink の dir の後の .. は実体の親に上がる (字面の候補にしない)",
      copy.call("skill-a", ".agents/skills/link/../skill-a/SKILL.md") == ["other", Digest::SHA256.hexdigest("physical body\n")])
check("C03: home の中身の違う copy は other", copy.call("skill-a", "~/.codex/skills/skill-a/SKILL.md") == ["other", Digest::SHA256.hexdigest("old body\n")])
check("C05: $HOME と ${HOME} も home で展開する", copy.call("skill-a", "$HOME/.codex/skills/skill-a/SKILL.md").first == "other" &&
      copy.call("skill-a", "${HOME}/.codex/skills/skill-a/SKILL.md").first == "other")
check("C04: 別の置き場で中身が同じなら same-content", copy.call("skill-a", "~/same/skill-a/SKILL.md") == ["same-content", cand_sha])
# C08: 字面ではなく実体で比べる。候補の置き場が symlink なら、候補は指す先の file で、同じ実体を読めば candidate
outside_sha = Digest::SHA256.hexdigest("outside body\n")
check("C08: 候補の置き場の symlink は実体で比べる (候補の実体と同じ file なら candidate、hash は実体の中身)",
      copy.call("skill-b", ".agents/skills/skill-b/SKILL.md") == ["candidate", outside_sha] &&
      copy.call("skill-b", "~/outside/skill-b/SKILL.md") == ["candidate", outside_sha])
check("C08: 候補の置き場を字面で指しても、実体が違えば candidate にしない",
      copy.call("skill-a", ".agents/skills/skill-a/../skill-b/SKILL.md") == ["other", outside_sha])
# 字面に /.agents/skills/ を含む絶対 path でも、実体が候補でなければ candidate にしない (別の project の置き場など)
other_proj = File.join(cdir, "other-proj", ".agents", "skills", "skill-a")
FileUtils.mkdir_p(other_proj)
File.write(File.join(other_proj, "SKILL.md"), "another project body\n")
check("C01: 別の project の .agents/skills の copy は other",
      copy.call("skill-a", File.join(other_proj, "SKILL.md")) == ["other", Digest::SHA256.hexdigest("another project body\n")])
check("C01: 候補の置き場の字面で、.. で外へ出る絶対 path は other",
      copy.call("skill-a", File.join(proj, ".agents", "skills", "skill-a", "..", "skill-b", "SKILL.md")) == ["other", outside_sha])
check("C06: 解決できない path は unknown", copy.call("skill-a", "/nope/skill-a/SKILL.md") == ["unknown", nil] &&
      copy.call("skill-a", "$X/skill-a/SKILL.md") == ["unknown", nil] && copy.call(nil, ".agents/skills/skill-a/SKILL.md") == ["unknown", nil])
r = P.parse_codex(jsonl(command_item("cat .agents/skills/skill-a/SKILL.md ~/.codex/skills/skill-a/SKILL.md"),
                        { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }),
                  names, proj: proj, home: home)
check("parse_codex は proj と home で copy を決める", r[:reads].map { |e| e["copy"] } == %w[candidate other])

broken = "{\"type\":\"turn.completed\"\nnot json\n[1]\n" +
         jsonl(command_item("cat .agents/skills/skill-a/SKILL.md"),
               { "type" => "turn.completed", "usage" => { "input_tokens" => 3, "output_tokens" => 1 } })
r = (P.parse_codex(broken, names) rescue nil)
check("codex: 不正な JSON の行と object でない行を飛ばして、後続の event を読む",
      !r.nil? && r[:observed] == ["skill-a"] && r[:prompt_tokens] == 3)

# routing の判断が終わった印 (#302): 候補の SKILL.md を読んだ後に、SKILL.md を読まない tool の item が 2 つ続く
read_a = command_item("cat .agents/skills/skill-a/SKILL.md")
work = command_item("git status")
message = { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => "x" } }
tool_item = ->(type) { { "type" => "item.completed", "item" => { "type" => type } } }
done = ->(*events) { P.parse_codex(jsonl(*events), names)[:routing_done] }
check("codex: 読み取りの後に作業の item が 2 つ続けば印が立つ", done.call(read_a, work, work) == true)
check("codex: 読み取りの後に作業の item が 1 つだけなら立たない", done.call(read_a, work) == false)
check("codex: 読み取りが無ければ、作業の item が続いても立たない", done.call(work, work, work) == false)
check("codex: 読み取りの前の作業の item は数えない", done.call(work, work, read_a, work) == false)
check("codex: 間の読み取りで数を 0 に戻す", done.call(read_a, work, read_a, work) == false)
check("codex: 候補でない SKILL.md の読み取りでも数を 0 に戻す",
      done.call(read_a, work, command_item("cat ~/.codex/skills/.system/other/SKILL.md"), work) == false)
check("codex: 前に / の無い SKILL.md の読み取り (cd の後の cat) でも数を 0 に戻す",
      done.call(read_a, work, command_item("cd .agents/skills/skill-b && cat SKILL.md"), work) == false)
check("codex: agent_message は数にも数え直しにも入れない", done.call(read_a, work, message, work) == true)
check("codex: file_change / mcp_tool_call / web_search も作業の item に数える",
      done.call(read_a, tool_item.call("file_change"), tool_item.call("mcp_tool_call")) == true &&
      done.call(read_a, tool_item.call("web_search"), work) == true)
check("codex: 知らない type の item は数えない", done.call(read_a, tool_item.call("todo_list"), work) == false)
check("codex: item.started は数えない",
      done.call(read_a, { "type" => "item.started", "item" => { "type" => "command_execution", "command" => "ls" } }, work) == false)
check("codex: 一度立った印は、後の読み取りで戻さない",
      done.call(read_a, work, work, command_item("cat .agents/skills/skill-b/SKILL.md"), work) == true)
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: run の終わり方 (completion。#302) ---------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

ok_status = Process.wait2(Process.spawn("true"))[1]
ng_status = Process.wait2(Process.spawn("false"))[1]
result = lambda do |completed:, drained: true, status: nil|
  ProbeChild::Result.new(out: "", err: "", status: status, completed: completed, drained: drained)
end
usage = { prompt_tokens: 1, output_tokens: 1 }
no_usage = { prompt_tokens: nil, output_tokens: nil }
c = ->(tool, r, parsed) { P.completion(tool, r, parsed) }

check("exit 0 で usage があれば exited", c.call("codex", result.call(completed: true, status: ok_status), usage) == "exited")
check("exit 0 でも usage が無ければ failed", c.call("codex", result.call(completed: true, status: ok_status), no_usage) == "failed")
check("非ゼロ終了は、routing の印が立っていても failed",
      c.call("codex", result.call(completed: true, status: ng_status), usage.merge(routing_done: true)) == "failed")
check("claude の error_max_turns の非ゼロ終了は max-turns",
      c.call("claude-code", result.call(completed: true, status: ng_status), usage.merge(subtype: "error_max_turns")) == "max-turns")
check("codex の打ち切りで印が立ち、読み切れていれば observed-stop",
      c.call("codex", result.call(completed: false), no_usage.merge(routing_done: true)) == "observed-stop")
check("codex の打ち切りで印が無ければ timeout",
      c.call("codex", result.call(completed: false), usage.merge(routing_done: false)) == "timeout")
check("codex の打ち切りで読み切れなければ、印が立っていても timeout",
      c.call("codex", result.call(completed: false, drained: false), no_usage.merge(routing_done: true)) == "timeout")
check("claude の打ち切りは、印があっても timeout",
      c.call("claude-code", result.call(completed: false), usage.merge(routing_done: true, subtype: "error_max_turns")) == "timeout")
check("終わっても読み切れなければ failed",
      c.call("codex", result.call(completed: true, drained: false, status: ok_status), usage) == "failed")
check("ok に数える終わり方は exited / max-turns / observed-stop", P::OK_COMPLETIONS == %w[exited max-turns observed-stop])
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- integration: 偽の codex で preflight と起動を確かめる -----------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
log="$tmp/codex-calls.log"
cat > "$fakebin/codex" <<'EOF'
#!/bin/sh
# 偽の codex。呼ばれた argv を 1 行ずつ log に残し、help / features list / exec を模倣する。
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
printf 'auto-memory: %s\n' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-unset}" >> "$FAKE_CODEX_LOG"
printf 'env: home=%s codex_home=%s home_entries=%s\n' "$HOME" "${CODEX_HOME-unset}" "$(ls -A "$HOME" 2>/dev/null | wc -l | tr -d ' ')" >> "$FAKE_CODEX_LOG"
# FAKE_CODEX_TAMPER があれば、exec の間に子の CODEX_HOME に AGENTS.md を足す (run の間の差し替えの確かめ。#802)
case "$1" in exec) [ "${2-}" = "--help" ] || { [ -z "${FAKE_CODEX_TAMPER:-}" ] || : > "$CODEX_HOME/AGENTS.md"; } ;; esac
case "$1 $2" in
  "exec --help")
    help='Options:
  -c, --config <key=value>
      --ignore-user-config
      --ignore-rules
      --disable <FEATURE>
  -s, --sandbox <SANDBOX_MODE>'
    [ -n "${FAKE_HELP_DROP:-}" ] && help=$(printf '%s\n' "$help" | grep -v -- "$FAKE_HELP_DROP")
    printf '%s\n' "$help"
    exit "${FAKE_RC_HELP:-0}" ;;
  "features list")
    printf '%s\n' "${FAKE_FEATURES:-apps  stable  true
computer_use  beta  false
browser_use  beta  false}"
    exit "${FAKE_RC_FEATURES:-0}" ;;
  exec*)
    cat > /dev/null
    # FAKE_CODEX_EVENTS があれば、その file の event を出し、孫の process (pid を FAKE_CODEX_CHILD_PID に書く) を
    # 残して FAKE_CODEX_SLEEP 秒待ち、FAKE_CODEX_RC で終わる (#302 の打ち切りの確かめ)。
    if [ -n "${FAKE_CODEX_EVENTS:-}" ]; then
      cat "$FAKE_CODEX_EVENTS"
      if [ -n "${FAKE_CODEX_CHILD_PID:-}" ]; then
        sleep 60 &
        echo $! > "$FAKE_CODEX_CHILD_PID"
      fi
      [ -z "${FAKE_CODEX_SLEEP:-}" ] || sleep "$FAKE_CODEX_SLEEP"
      exit "${FAKE_CODEX_RC:-0}"
    fi
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"personal-a"}}'
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
    exit 0 ;;
esac
echo "fake codex: unexpected args: $*" >&2
exit 64
EOF
chmod +x "$fakebin/codex"

source_dir="$tmp/source"
mkdir -p "$source_dir/personal-a"
printf -- '---\nname: personal-a\ndescription: a\n---\n' > "$source_dir/personal-a/SKILL.md"

# 評価用の Codex home (#802): auth.json だけを持つ。ふだんの Codex home (親の CODEX_HOME = $empty_home) とは別の dir
eval_home="$tmp/eval-home"
mkdir -p "$eval_home"
printf '{}\n' > "$eval_home/auth.json"

# run_probe <args...>: 偽の codex を PATH に置き、実 ~/.codex の代わりに空の CODEX_HOME で probe を回す。
# 子には評価用の Codex home を渡す (--codex-home)。渡さない形は run_probe_bare で回す
run_probe() {
  run_probe_bare --codex-home "$eval_home" "$@"
}
run_probe_bare() {
  : > "$log"
  set +e
  out=$(env FAKE_CODEX_LOG="$log" CODEX_HOME="$empty_home" PATH="$fakebin:$PATH" \
    ruby "$src" --tool codex --model m-x --source "$source_dir" "$@" 2>&1)
  rc=$?
  set -e
}

# 正常: preflight (help と features list) を通ってから、境界つきの argv で exec が起動する
run_probe --smoke
[ "$rc" -eq 0 ] || fail "smoke with a capable codex should exit 0 (rc=$rc): $out"
grep -q '^exec --help$' "$log" || fail "preflight should read exec --help: $(cat "$log")"
grep -q '^features list$' "$log" || fail "preflight should read features list: $(cat "$log")"
grep -q -- '^exec --json .*--ignore-user-config --ignore-rules -s read-only .*--disable apps --disable computer_use --disable browser_use ' "$log" \
  || fail "exec must be launched with the boundary flags: $(cat "$log")"

# 欠けたら Codex を起動せず exit 2 (存在しない flag を試さない)。理由に欠けたものを出す
for flag in --ignore-user-config --ignore-rules --disable; do
  FAKE_HELP_DROP="$flag"
  export FAKE_HELP_DROP
  run_probe --smoke
  unset FAKE_HELP_DROP
  [ "$rc" -eq 2 ] || fail "missing $flag must exit 2 (rc=$rc): $out"
  case "$out" in *"$flag"*) : ;; *) fail "missing $flag should be named: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "codex must not be launched without $flag: $(cat "$log")"; fi
done

for feature in apps computer_use browser_use; do
  FAKE_FEATURES=$(printf 'apps  stable  true\ncomputer_use  beta  false\nbrowser_use  beta  false\n' | grep -v "^$feature ")
  export FAKE_FEATURES
  run_probe --smoke
  unset FAKE_FEATURES
  [ "$rc" -eq 2 ] || fail "missing feature $feature must exit 2 (rc=$rc): $out"
  case "$out" in *"$feature"*) : ;; *) fail "missing feature $feature should be named: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "codex must not be launched without feature $feature: $(cat "$log")"; fi
done

# help / features list が非ゼロなら、出力が正常でも信じない
for pair in "FAKE_RC_HELP|exec --help" "FAKE_RC_FEATURES|features list"; do
  var=${pair%%|*}
  what=${pair#*|}
  run_probe_env() {
    : > "$log"
    set +e
    out=$(env "$var=3" FAKE_CODEX_LOG="$log" CODEX_HOME="$empty_home" PATH="$fakebin:$PATH" \
      ruby "$src" --tool codex --model m-x --source "$source_dir" --codex-home "$eval_home" --smoke 2>&1)
    rc=$?
    set -e
  }
  run_probe_env
  [ "$rc" -eq 2 ] || fail "non-zero $what must exit 2 (rc=$rc): $out"
  case "$out" in *"$what"*) : ;; *) fail "non-zero $what should be named: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "codex must not be launched when $what fails: $(cat "$log")"; fi
done

# dry-run は CLI を起動しない (preflight もしない) が、表示する argv に境界が載る
run_probe --dry-run
[ "$rc" -eq 0 ] || fail "dry-run should exit 0 (rc=$rc): $out"
[ ! -s "$log" ] || fail "dry-run must not call codex: $(cat "$log")"
case "$out" in *'"--ignore-user-config" "--ignore-rules"'*'"--disable" "browser_use"'*) : ;; *) fail "dry-run argv should show the boundary: $out" ;; esac

# ---- integration: 評価用の Codex home と空の HOME (#802) ------------------------------------
eval_real=$(cd "$eval_home" && pwd -P)
# env_lines: log の env の行 (確かめの 2 回と exec の 1 回ずつ)
env_lines() { grep '^env: ' "$log"; }

# E08・E09: 確かめ (help・features list) も exec も、子の CODEX_HOME は評価用の home、HOME は中身の無い dir
run_probe --smoke
[ "$rc" -eq 0 ] || fail "smoke with --codex-home should exit 0 (rc=$rc): $out"
[ "$(env_lines | wc -l | tr -d ' ')" -eq 3 ] || fail "expected env lines for help, features list and exec: $(cat "$log")"
env_lines | grep -v -q "codex_home=$eval_real home_entries=0\$" && fail "every child must get the eval CODEX_HOME and an empty HOME: $(env_lines)"
env_lines | grep -q "home=$HOME " && fail "no child may get the parent's HOME: $(env_lines)"
for h in $(env_lines | sed 's/^env: home=\([^ ]*\) .*/\1/'); do
  [ ! -e "$h" ] || fail "the empty HOME must be removed after use: $h"
done
# 確かめの HOME と exec の HOME は別の dir
[ "$(env_lines | sed 's/^env: home=\([^ ]*\) .*/\1/' | sort -u | wc -l | tr -d ' ')" -ge 2 ] \
  || fail "the preflight and the run must not share a HOME: $(env_lines)"

# E13: run ごとに別の空の HOME (同じ case の 2 回目も新しい dir)
cat > "$tmp/home-cases.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["personal-a"],
  "cases": [
    { "id": "home", "cluster": "x", "prompt": "do a", "primary": "personal-a", "must_not": [] }
  ]
}
EOF
printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution","command":"cat .agents/skills/personal-a/SKILL.md"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}' > "$tmp/ev-home-ok"
FAKE_CODEX_EVENTS="$tmp/ev-home-ok"
export FAKE_CODEX_EVENTS
run_probe --cases "$tmp/home-cases.json" --repeat 2 --out "$tmp/home/results.json"
unset FAKE_CODEX_EVENTS
[ "$rc" -eq 0 ] || fail "two runs with --codex-home should exit 0 (rc=$rc): $out"
exec_homes=$(grep -A2 '^exec --json' "$log" | sed -n 's/^env: home=\([^ ]*\) .*/\1/p')
[ "$(printf '%s\n' "$exec_homes" | sort -u | wc -l | tr -d ' ')" -eq 2 ] || fail "each run needs its own HOME: $exec_homes"
# results.json は隔離の条件を残し、judge はそのまま読める
ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); exit(d["codex_isolation"] == { "home" => "empty", "codex_home" => "eval" } ? 0 : 1)' \
  "$tmp/home/results.json" || fail "results.json must record codex_isolation: $(cat "$tmp/home/results.json")"
set +e
judge_out=$(sh "$repo_root/scripts/check-skill-routing.sh" --cases "$tmp/home-cases.json" --results "$tmp/home/results.json" 2>&1)
judge_rc=$?
set -e
[ "$judge_rc" -eq 0 ] || fail "the judge should accept a result with codex_isolation (rc=$judge_rc): $judge_out"
# E27: #802 より前の形 (codex_isolation が無い) の結果とは比べない
ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); d.delete("codex_isolation"); File.write(ARGV[1], JSON.generate(d))' \
  "$tmp/home/results.json" "$tmp/home/old.json"
set +e
judge_out=$(sh "$repo_root/scripts/check-skill-routing.sh" --cases "$tmp/home-cases.json" --results "$tmp/home/results.json" --baseline "$tmp/home/old.json" 2>&1)
judge_rc=$?
set -e
[ "$judge_rc" -eq 2 ] || fail "comparing with a result without codex_isolation must be a structural error (rc=$judge_rc): $judge_out"
case "$judge_out" in *'comparison: codex isolation differs'*) : ;; *) fail "the comparison must name codex isolation: $judge_out" ;; esac

# E01・E03: codex の run に --codex-home が無ければ、確かめも起動もせずに exit 2 (smoke・--only も同じ)
for mode in --smoke "--only home --cases $tmp/home-cases.json --out $tmp/home/only.json"; do
  # shellcheck disable=SC2086
  run_probe_bare $mode
  [ "$rc" -eq 2 ] || fail "codex without --codex-home must exit 2 ($mode, rc=$rc): $out"
  case "$out" in *'--codex-home is required for --tool codex'*) : ;; *) fail "the error should name --codex-home ($mode): $out" ;; esac
  [ ! -s "$log" ] || fail "codex must not be called without --codex-home ($mode): $(cat "$log")"
done
# E02: dry-run は省ける (CLI を起動しない)。表示は home が無いことを書く
run_probe_bare --dry-run
[ "$rc" -eq 0 ] || fail "dry-run without --codex-home should exit 0 (rc=$rc): $out"
case "$out" in *'codex home: not set (required for runs)'*) : ;; *) fail "dry-run should say the codex home is not set: $out" ;; esac
run_probe --dry-run
case "$out" in *"codex home: $eval_real (CODEX_HOME for the child; HOME is an empty dir per run)"*) : ;;
  *) fail "dry-run should show the eval codex home: $out" ;; esac
# E04: claude-code に --codex-home は入力の誤り
set +e
out=$(ruby "$src" --tool claude-code --source "$source_dir" --codex-home "$eval_home" --dry-run 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "claude-code with --codex-home must exit 2 (rc=$rc): $out"
case "$out" in *'--codex-home is only for --tool codex'*) : ;; *) fail "the error should say --codex-home is codex only: $out" ;; esac

# E05・E06: 評価用の home に当てはまらない dir では、確かめも起動もしない (規則は挙動の評価と共有。#731)
bad_noauth="$tmp/bad-noauth"; mkdir -p "$bad_noauth"
bad_agents="$tmp/bad-agents"; mkdir -p "$bad_agents"; printf '{}\n' > "$bad_agents/auth.json"; : > "$bad_agents/Agents.md"
bad_skill="$tmp/bad-skill"; mkdir -p "$bad_skill/skills/personal-a"; printf '{}\n' > "$bad_skill/auth.json"
ln -s "$eval_home" "$tmp/bad-link"
for pair in "relative|eval-home|absolute path" "usual|$empty_home|usual Codex home" "link|$tmp/bad-link|symlink" \
            "noauth|$bad_noauth|auth.json" "agents|$bad_agents|must not have Agents.md" "skill|$bad_skill|user skills"; do
  name=${pair%%|*}; rest=${pair#*|}; dir=${rest%%|*}; want=${rest#*|}
  run_probe_bare --codex-home "$dir" --smoke
  [ "$rc" -eq 2 ] || fail "a bad codex home ($name) must exit 2 (rc=$rc): $out"
  case "$out" in *"$want"*) : ;; *) fail "the bad codex home ($name) should be named: $out" ;; esac
  [ ! -s "$log" ] || fail "codex must not be called with a bad codex home ($name): $(cat "$log")"
done

# E07: run の間に評価用の home が変われば、次の run を起動せずに止める
FAKE_CODEX_TAMPER=1
export FAKE_CODEX_TAMPER
run_probe --cases "$tmp/home-cases.json" --repeat 2 --out "$tmp/home/tamper.json"
unset FAKE_CODEX_TAMPER
rm -f "$eval_home/AGENTS.md"
[ "$rc" -eq 2 ] || fail "a codex home changed between runs must stop the probe (rc=$rc): $out"
case "$out" in *'--codex-home must not have AGENTS.md'*) : ;; *) fail "the change should be named: $out" ;; esac
[ "$(grep -c '^exec --json' "$log")" -eq 1 ] || fail "the second run must not be launched: $(cat "$log")"

# E10: --model が無ければ、model は親のふだんの Codex home の top-level から取る (評価用の home の config.toml は読まない)
eval_model_home="$tmp/eval-home-model"
mkdir -p "$eval_model_home"
printf '{}\n' > "$eval_model_home/auth.json"
printf 'model = "m-eval"\n' > "$eval_model_home/config.toml"
: > "$log"
set +e
out=$(env FAKE_CODEX_LOG="$log" CODEX_HOME="$top_home" PATH="$fakebin:$PATH" \
  ruby "$src" --tool codex --source "$source_dir" --codex-home "$eval_model_home" --smoke 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "smoke without --model should exit 0 (rc=$rc): $out"
grep -q '^exec --json .* -m m-top -$' "$log" || fail "the model must come from the usual Codex home: $(grep '^exec' "$log")"
if grep -q 'm-eval' "$log"; then fail "the eval home's config.toml must not choose the model: $(grep '^exec' "$log")"; fi

# E12: copy の判定の ~ は子の HOME で展開する (親の HOME に同名の file があっても、子の空の HOME には無い)
parent_home="$tmp/parent-home"
mkdir -p "$parent_home/.codex/skills/personal-a"
printf 'old\n' > "$parent_home/.codex/skills/personal-a/SKILL.md"
printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution","command":"cat ~/.codex/skills/personal-a/SKILL.md"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}' > "$tmp/ev-home-read"
: > "$log"
set +e
out=$(env HOME="$parent_home" FAKE_CODEX_LOG="$log" FAKE_CODEX_EVENTS="$tmp/ev-home-read" CODEX_HOME="$empty_home" PATH="$fakebin:$PATH" \
  ruby "$src" --tool codex --model m-x --source "$source_dir" --codex-home "$eval_home" \
  --cases "$tmp/home-cases.json" --out "$tmp/home/tilde.json" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "the ~ read run should exit 0 (rc=$rc): $out"
ruby -rjson -e 'r = JSON.parse(File.read(ARGV[0]))["runs"][0]; e = (r["reads"] || [])[0] || {}; exit(e["skill"] == "personal-a" && e["copy"] == "unknown" ? 0 : 1)' \
  "$tmp/home/tilde.json" || fail "~ must expand to the child's empty HOME (copy unknown): $(cat "$tmp/home/tilde.json")"

# case id は raw log の file 名に使う。raw dir の外を指す id では Codex を起動せずに exit 2 で止まり、
# raw dir の外 (ここでは --out の directory) に何も作らない
cat > "$tmp/escape-cases.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["personal-a"],
  "cases": [
    { "id": "../escaped", "cluster": "x", "prompt": "do a", "primary": "personal-a", "must_not": [] }
  ]
}
EOF
mkdir -p "$tmp/escape"
run_probe --cases "$tmp/escape-cases.json" --out "$tmp/escape/out/results.json"
[ "$rc" -eq 2 ] || fail "case id outside the raw dir must exit 2 (rc=$rc): $out"
case "$out" in *error:*) : ;; *) fail "case id outside the raw dir should be reported as an error: $out" ;; esac
if grep -q '^exec --json' "$log"; then fail "codex must not be launched for a case id outside the raw dir: $(cat "$log")"; fi
find "$tmp/escape" -type f > "$tmp/escape-files"
[ ! -s "$tmp/escape-files" ] || fail "nothing may be written for a case id outside the raw dir: $(cat "$tmp/escape-files")"

# ---- integration: 偽の codex を --timeout で打ち切る (#302) ---------------------------------
# skill を読んでから作業に入った印が立っていれば observed-stop (ok、token は null)、無ければ timeout (error)。
# 非ゼロで終わった run は、印があっても failed (error)。打ち切った run の孫の process は残らない。
ev_read='{"type":"item.completed","item":{"type":"command_execution","command":"cat .agents/skills/personal-a/SKILL.md"}}'
ev_work='{"type":"item.completed","item":{"type":"command_execution","command":"git status"}}'
ev_turn='{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
printf '%s\n' "$ev_read" "$ev_work" "$ev_work" > "$tmp/ev-done"
printf '%s\n' "$ev_read" "$ev_work" > "$tmp/ev-one"
printf '%s\n' "$ev_work" "$ev_work" "$ev_work" > "$tmp/ev-none"
printf '%s\n' "$ev_read" "$ev_work" "$ev_work" "$ev_turn" > "$tmp/ev-done-turn"

# run_codex_events <events> <sleep> <rc> <args...>: 偽の codex に event を出させて probe を回す。sleep が 0 でない
# (打ち切る) run だけ孫の process を残させる (正常に終わる run で孫が pipe を握ると、読み切れない run になるため)
run_codex_events() {
  rce_events=$1; rce_sleep=$2; rce_rc=$3; shift 3
  rm -f "$tmp/grandchild.pid"
  FAKE_CODEX_EVENTS=$rce_events FAKE_CODEX_SLEEP=$rce_sleep FAKE_CODEX_RC=$rce_rc
  export FAKE_CODEX_EVENTS FAKE_CODEX_SLEEP FAKE_CODEX_RC
  if [ "$rce_sleep" != 0 ]; then
    FAKE_CODEX_CHILD_PID="$tmp/grandchild.pid"
    export FAKE_CODEX_CHILD_PID
  fi
  run_probe "$@"
  unset FAKE_CODEX_EVENTS FAKE_CODEX_SLEEP FAKE_CODEX_RC FAKE_CODEX_CHILD_PID
}

# grandchild_gone: 偽の codex が残した孫の process が居ない (3 秒まで待つ)
grandchild_gone() {
  [ -s "$tmp/grandchild.pid" ] || return 1
  gc_pid=$(cat "$tmp/grandchild.pid")
  gc_n=0
  while kill -0 "$gc_pid" 2>/dev/null; do
    gc_n=$((gc_n + 1))
    [ "$gc_n" -le 30 ] || { kill -KILL "$gc_pid" 2>/dev/null || :; return 1; }
    sleep 0.1
  done
  return 0
}

run_codex_events "$tmp/ev-done" 30 0 --smoke --timeout 1
[ "$rc" -eq 0 ] || fail "a timed-out run with the routing mark should be ok (rc=$rc): $out"
case "$out" in *'status=ok exit=nil '*'prompt_tokens=nil output_tokens=nil completion=observed-stop'*) : ;;
  *) fail "a timed-out run with the routing mark should be observed-stop without tokens: $out" ;; esac
grandchild_gone || fail "the grandchild of a timed-out run must not survive"

# usage を出した後に止まった run も、打ち切りの token は信用しないので null
run_codex_events "$tmp/ev-done-turn" 30 0 --smoke --timeout 1
case "$out" in *'status=ok exit=nil '*'prompt_tokens=nil output_tokens=nil completion=observed-stop'*) : ;;
  *) fail "a timed-out run must drop the tokens even after turn.completed: $out" ;; esac
grandchild_gone || fail "the grandchild of a timed-out run (after turn.completed) must not survive"

run_codex_events "$tmp/ev-one" 30 0 --smoke --timeout 1
[ "$rc" -eq 2 ] || fail "a timed-out run with one work item after the read must be an error run (rc=$rc): $out"
case "$out" in *'status=error exit=nil '*'completion=timeout'*) : ;; *) fail "one work item should be timeout: $out" ;; esac
grandchild_gone || fail "the grandchild of a timed-out run (one work item) must not survive"

run_codex_events "$tmp/ev-none" 30 0 --smoke --timeout 1
[ "$rc" -eq 2 ] || fail "a timed-out run without a read must be an error run (rc=$rc): $out"
case "$out" in *'status=error exit=nil '*'observed=[]'*) : ;; *) fail "no read should be an error run: $out" ;; esac
case "$out" in *'completion=timeout'*) : ;; *) fail "no read should be timeout: $out" ;; esac

run_codex_events "$tmp/ev-done-turn" 0 1 --smoke --timeout 5
[ "$rc" -eq 2 ] || fail "a non-zero exit with the routing mark must be an error run (rc=$rc): $out"
case "$out" in *'status=error exit=1 '*'completion=failed'*) : ;; *) fail "a non-zero exit should be failed: $out" ;; esac

run_codex_events "$tmp/ev-done-turn" 0 0 --smoke --timeout 5
[ "$rc" -eq 0 ] || fail "a normal exit should be ok (rc=$rc): $out"
case "$out" in *'status=ok exit=0 '*'prompt_tokens=10 output_tokens=2 completion=exited'*) : ;;
  *) fail "a normal exit should keep tokens and be exited: $out" ;; esac

# results.json: schema 2 で completion を書き、observed-stop の token は null。judge はそのまま読める
cat > "$tmp/stop-cases.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["personal-a"],
  "cases": [
    { "id": "stop", "cluster": "x", "prompt": "do a", "primary": "personal-a", "must_not": [] }
  ]
}
EOF
run_codex_events "$tmp/ev-done" 30 0 --cases "$tmp/stop-cases.json" --out "$tmp/stop/results.json" --timeout 1
[ "$rc" -eq 0 ] || fail "probe with an observed-stop run should exit 0 (rc=$rc): $out"
ruby -rjson -e '
d = JSON.parse(File.read(ARGV[0]))
r = d["runs"][0]
abort "schema_version should be 2: #{d["schema_version"]}" unless d["schema_version"] == 2
abort "run should be ok / observed-stop: #{r}" unless r["status"] == "ok" && r["completion"] == "observed-stop"
abort "tokens should be null: #{r}" unless r.key?("prompt_tokens") && r["prompt_tokens"].nil? && r.key?("output_tokens") && r["output_tokens"].nil?
abort "observed should be the read skill: #{r}" unless r["observed"] == ["personal-a"]
' "$tmp/stop/results.json" || fail "unexpected results.json for an observed-stop run: $(cat "$tmp/stop/results.json")"
grandchild_gone || fail "the grandchild of a timed-out case run must not survive"
set +e
judge_out=$(sh "$repo_root/scripts/check-skill-routing.sh" --cases "$tmp/stop-cases.json" --results "$tmp/stop/results.json" 2>&1)
judge_rc=$?
set -e
[ "$judge_rc" -eq 0 ] || fail "the judge should accept the runner's observed-stop result (rc=$judge_rc): $judge_out"
case "$judge_out" in *'runs_without_tokens=1'*) : ;; *) fail "the judge should count the run without tokens: $judge_out" ;; esac

# ---- integration: 偽の claude で --max-turns の打ち切りの扱いを確かめる ----------------------
cat > "$fakebin/claude" <<'EOF'
#!/bin/sh
# 偽の claude。stream-json の event を出して FAKE_CLAUDE_RC で終わる。FAKE_CLAUDE_SUBTYPE が空でなければ
# result に subtype を付ける。FAKE_CLAUDE_USAGE は result の usage (JSON。none なら usage を付けない。空なら既定)、
# FAKE_CLAUDE_SLEEP は result を出した後に待つ秒数 (--timeout で kill させる)。FAKE_CLAUDE_INIT は init に足す欄 (none なら
# init を出さない)、FAKE_CLAUDE_LOG は環境を残す file。
[ -z "${FAKE_CLAUDE_LOG:-}" ] || printf 'auto-memory: %s\n' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-unset}" >> "$FAKE_CLAUDE_LOG"
[ "${FAKE_CLAUDE_INIT:-}" = none ] || printf '{"type":"system","subtype":"init","model":"m-fake-claude"%s}\n' "${FAKE_CLAUDE_INIT:-}"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":5},"content":[{"type":"text","text":"personal-a"}]}}'
case ${FAKE_CLAUDE_USAGE:-} in
  none) usage= ;;
  '') usage=',"usage":{"input_tokens":10,"output_tokens":2}' ;;
  *) usage=",\"usage\":$FAKE_CLAUDE_USAGE" ;;
esac
if [ -n "${FAKE_CLAUDE_SUBTYPE:-}" ]; then
  printf '{"type":"result","subtype":"%s"%s}\n' "$FAKE_CLAUDE_SUBTYPE" "$usage"
else
  printf '{"type":"result"%s}\n' "$usage"
fi
[ -z "${FAKE_CLAUDE_SLEEP:-}" ] || sleep "$FAKE_CLAUDE_SLEEP"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
chmod +x "$fakebin/claude"

# run_claude_smoke <subtype> <exit> [usage] [sleep]: 偽の claude を PATH に置いて --tool claude-code --smoke を回す。
# sleep を渡したときは --timeout 1 を付ける。
run_claude_smoke() {
  set +e
  if [ -n "${4:-}" ]; then
    out=$(env FAKE_CLAUDE_SUBTYPE="$1" FAKE_CLAUDE_RC="$2" FAKE_CLAUDE_USAGE="${3:-}" FAKE_CLAUDE_SLEEP="$4" \
      PATH="$fakebin:$PATH" ruby "$src" --tool claude-code --source "$source_dir" --smoke --timeout 1 2>&1)
  else
    out=$(env FAKE_CLAUDE_SUBTYPE="$1" FAKE_CLAUDE_RC="$2" FAKE_CLAUDE_USAGE="${3:-}" PATH="$fakebin:$PATH" \
      ruby "$src" --tool claude-code --source "$source_dir" --smoke 2>&1)
  fi
  rc=$?
  set -e
}

# 正常終了は観測完了 (対照)
run_claude_smoke success 0
[ "$rc" -eq 0 ] || fail "claude smoke with exit 0 should exit 0 (rc=$rc): $out"
case "$out" in *'status=ok exit=0 subtype="success" model="m-fake-claude"'*) : ;; *) fail "claude smoke should report ok: $out" ;; esac
# error_max_turns の打ち切りは、CLI が非ゼロで終わっても観測完了
run_claude_smoke error_max_turns 1
[ "$rc" -eq 0 ] || fail "error_max_turns with a non-zero exit must count as a completed observation (rc=$rc): $out"
case "$out" in *'status=ok exit=1 subtype="error_max_turns"'*) : ;; *) fail "the max-turns cut should be reported as ok: $out" ;; esac
# それ以外の非ゼロ終了は観測不能 (error run)
run_claude_smoke '' 1
[ "$rc" -eq 2 ] || fail "a non-zero exit without a subtype must be an error run (rc=$rc): $out"
case "$out" in *'status=error exit=1'*) : ;; *) fail "a non-zero exit without a subtype should be reported as error: $out" ;; esac
run_claude_smoke error_during_execution 1
[ "$rc" -eq 2 ] || fail "a non-zero exit with another subtype must be an error run (rc=$rc): $out"
# usage が取れない result は、正常終了でも観測不能 (error run)。正当な 0 token は観測完了 (#516)
for usage in none '{}' '{"input_tokens":10}' '{"output_tokens":2}' '{"input_tokens":10,"output_tokens":"2"}'; do
  run_claude_smoke success 0 "$usage"
  [ "$rc" -eq 2 ] || fail "a result without usable usage ($usage) must be an error run (rc=$rc): $out"
  case "$out" in *'status=error exit=0'*) : ;; *) fail "a result without usable usage ($usage) should be reported as error: $out" ;; esac
done
run_claude_smoke success 0 '{"input_tokens":0,"output_tokens":0}'
[ "$rc" -eq 0 ] || fail "a result with zero tokens must count as a completed observation (rc=$rc): $out"
case "$out" in *'status=ok exit=0'*'prompt_tokens=0 output_tokens=0'*) : ;; *) fail "zero tokens should be reported as ok: $out" ;; esac
# 打ち切りの result を出した後に --timeout で kill した run は、終了の状態が取れないので error run (#516)
run_claude_smoke error_max_turns 1 '' 5
[ "$rc" -eq 2 ] || fail "a run killed by --timeout must be an error run even with error_max_turns (rc=$rc): $out"
case "$out" in *'status=error exit=nil subtype="error_max_turns"'*) : ;; *) fail "the killed run should be reported as error: $out" ;; esac
case "$out" in *'completion=timeout'*) : ;; *) fail "the killed claude run should be timeout: $out" ;; esac

# claude-code の終わり方 (#302): 正常終了は exited、打ち切りは max-turns、それ以外の非ゼロ終了は failed
run_claude_smoke success 0
case "$out" in *'completion=exited'*) : ;; *) fail "a normal claude exit should be exited: $out" ;; esac
run_claude_smoke error_max_turns 1
case "$out" in *'completion=max-turns'*) : ;; *) fail "the claude max-turns cut should be max-turns: $out" ;; esac
run_claude_smoke '' 1
case "$out" in *'completion=failed'*) : ;; *) fail "a claude non-zero exit should be failed: $out" ;; esac

# ---- 自動の memory を止める環境と、その記録 (#770) --------------------------------------------
# run_claude_memory <init に足す欄> <出力> [--smoke]: 偽の claude で 2 回の run を回す
claude_log="$tmp/claude-env.log"
run_claude_memory() {
  : > "$claude_log"
  rcm_init=$1
  rcm_out=$2
  shift 2
  [ $# -gt 0 ] || set -- --cases "$tmp/stop-cases.json" --repeat 2 --out "$rcm_out"
  set +e
  out=$(env FAKE_CLAUDE_INIT="$rcm_init" FAKE_CLAUDE_LOG="$claude_log" FAKE_CLAUDE_SUBTYPE=success \
    PATH="$fakebin:$PATH" ruby "$src" --tool claude-code --source "$source_dir" "$@" 2>&1)
  rc=$?
  set -e
}
for parent in unset 0 '' 1 true; do
  if [ "$parent" = unset ]; then unset CLAUDE_CODE_DISABLE_AUTO_MEMORY; else
    CLAUDE_CODE_DISABLE_AUTO_MEMORY=$parent
    export CLAUDE_CODE_DISABLE_AUTO_MEMORY
  fi
  run_claude_memory '' "$tmp/mem.json"
  [ "$rc" -eq 0 ] || fail "claude runs should exit 0 (rc=$rc): $out"
  [ "$(cat "$claude_log")" = 'auto-memory: 1
auto-memory: 1' ] || fail "each claude run should get the variable set to 1 (parent: $parent): $(cat "$claude_log")"
  run_claude_memory '' '' --smoke
  [ "$(cat "$claude_log")" = 'auto-memory: 1' ] || fail "the claude smoke should get the variable set to 1 (parent: $parent): $(cat "$claude_log")"
  # codex の子 process には足さず、親の値も変えない
  run_probe --smoke
  [ "$(grep '^auto-memory: ' "$log" | sort -u)" = "auto-memory: $parent" ] || fail "codex calls should keep the parent's value ($parent): $(cat "$log")"
done
unset CLAUDE_CODE_DISABLE_AUTO_MEMORY
# memory_value <results.json>: auto_memory を 1 行で出す (無ければ none)
memory_value() {
  ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); puts d.key?("auto_memory") ? JSON.generate(d["auto_memory"]) : "none"' "$1"
}
[ "$(memory_value "$tmp/mem.json")" = '{"requested":"off","init":"not-listed"}' ] || fail "not-listed should be recorded: $(cat "$tmp/mem.json")"
run_claude_memory ',"memory_paths":{"auto":"/x/CANARY-MEM"}' "$tmp/mem-listed.json"
[ "$(memory_value "$tmp/mem-listed.json")" = '{"requested":"off","init":"listed"}' ] || fail "listed should be recorded: $(cat "$tmp/mem-listed.json")"
if grep -q CANARY-MEM "$tmp/mem-listed.json"; then fail "results.json must not contain the memory path"; fi
run_claude_memory none "$tmp/mem-none.json"
[ "$(memory_value "$tmp/mem-none.json")" = '{"requested":"off","init":"unknown"}' ] || fail "unknown should be recorded: $(cat "$tmp/mem-none.json")"
[ "$(memory_value "$tmp/stop/results.json")" = none ] || fail "codex results must not record auto_memory: $(cat "$tmp/stop/results.json")"
# judge は listed を緑にしない
set +e
judge_out=$(sh "$repo_root/scripts/check-skill-routing.sh" --cases "$tmp/stop-cases.json" --results "$tmp/mem-listed.json" 2>&1)
judge_rc=$?
set -e
[ "$judge_rc" -eq 2 ] || fail "the judge should not accept listed (rc=$judge_rc): $judge_out"
case "$judge_out" in *'auto memory was not off in every run'*) : ;; *) fail "the judge should name the memory condition: $judge_out" ;; esac

echo "probe-skill-routing-test: ok"
