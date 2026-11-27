# frozen_string_literal: true

# 配った asset を 1 つだけ止めて戻す手順 (#723。docs/install-and-usage.md の「配った asset を止める (取り消し)」) の
# self-test。scripts/tests/revoke-test.sh から呼ぶ。一時 directory に fixture の repo と偽の HOME を作り、既定の配置先
# (~/.codex・~/.claude・~/.config/opencode) に setup.sh --apply で配備してから、docs の手順の段を走らせる。隔離の command は
# docs の sh の block から読み出して、そのまま走らせる。実際の tool home には触れない。network access なし。
# 期待値の表 (#723 のコメント) の ID を case の名前に添える。

require "digest"
require "fileutils"
require "json"
require "open3"

SCRIPTS = File.expand_path("../..", __dir__)
ROOT = File.expand_path("..", SCRIPTS)
require File.join(SCRIPTS, "lib", "build")
require File.join(__dir__, "markdown_units")

TMP = File.realpath(ARGV.fetch(0))
REPO = File.join(TMP, "repo")
HOME = File.join(TMP, "home")
CODEX = File.join(HOME, ".codex")
CLAUDE = File.join(HOME, ".claude")
OPENCODE = File.join(HOME, ".config", "opencode")
AGENTS = File.join(HOME, ".agents")
XDG = File.join(HOME, ".config")
BIN = File.join(TMP, "bin")
BACKUP = File.join(TMP, "backup")
STAMP = "20261127-000000"
QROOT = File.join(HOME, ".local/share/agent-tools/quarantine")
# 既定の配置先を偽の HOME の下に作る。flag でも同じ場所を渡し、HOME の上書きが効かなくても実物の home に書かない。
HOMES = ["--codex-home", CODEX, "--claude-home", CLAUDE, "--opencode-home", OPENCODE].freeze
SECTION = "### 配った asset を止める (取り消し)"

$checks = 0

def fail!(message)
  warn "FAIL: #{message}"
  exit 1
end

def check(cond, message)
  $checks += 1
  fail!(message) unless cond
end

# 子の process の env。date は固定の値を返す stub にする (隔離の置き場の名前を決め、同じ名前の衝突を作れるように)。
def env(home = HOME)
  { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"), "PATH" => "#{BIN}:#{ENV.fetch('PATH')}" }
end

def run(*argv, home: HOME)
  out, status = Open3.capture2e(env(home), *argv)
  [out, status.exitstatus]
end

def run!(label, *argv, ok: [0], home: HOME)
  out, rc = run(*argv, home: home)
  fail!("#{label}: exit #{rc}: #{out}") unless ok.include?(rc)
  [out, rc]
end

def script(name, *args, ok: [0], root: REPO, home: HOME)
  run!(name, File.join(SCRIPTS, name), "--root", root, *args, ok: ok, home: home)
end

def setup_apply
  script("setup.sh", "--apply", "--quiet", *HOMES)
end

def register(ok: [0, 3])
  script("register.sh", "--quiet", ok: ok).last
end

def build_register
  script("build.sh", "--prune", "--quiet")
  register
end

def status_json
  JSON.parse(script("status.sh", "--json", *HOMES).first)
end

def doctor
  run!("doctor", File.join(SCRIPTS, "doctor.sh"), "--root", REPO, *HOMES, "--agents-home", AGENTS, ok: [0, 1])
end

# 戻す手順の 5: doctor が、戻した target を source から作り直した artifact と一致と出す。
def expect_body_match(label, targets, root: REPO, home: HOME, homes: HOMES)
  out, rc = run!("doctor", File.join(SCRIPTS, "doctor.sh"), "--root", root, *homes, "--agents-home", File.join(home, ".agents"),
                 ok: [0, 1], home: home)
  check(rc.zero?, "#{label}: doctor passes: #{out}")
  targets.each do |tool, name|
    check(out.lines.map(&:chomp).include?("ok: target: [#{tool}] #{name} managed (body matches a fresh build)"),
          "#{label}: [#{tool}] #{name} matches a fresh build: #{out}")
  end
end

def catalog
  JSON.parse(File.read(File.join(REPO, "generated/catalog.json")))["assets"]
end

def entry(tool, name)
  catalog.find { |a| a["target"] == tool && a["name"] == name }
end

def rows(json)
  json["sync_targets"].map { |t| [t["tool"], t["name"], t["state"]] }
end

def state_of(json, tool, name)
  row = json["sync_targets"].find { |t| t["tool"] == tool && t["name"] == name }
  row && row["state"]
end

# 戻す手順の 2 と 3: build --prune と register をかけ、sync の dry-run の plan のうち skip でない行を返す。path は fixture の
# 場所を外して見る。
def restore_plan
  build_register
  # conflict があると dry-run も exit 1 で終わる (何も適用しない)。plan の行は sync の action の語で始まる。
  out, = script("sync.sh", *HOMES, ok: [0, 1])
  plan = out.lines.map(&:chomp).select { |l| l.match?(/\A[a-z-]+: \[/) }
  # note: は update に添える説明の行 (instruction の節の変化) で、plan の action ではない。
  unknown = plan.reject { |l| l.match?(/\A(skip|create|update|delete|conflict|note): /) }
  fail!("restore_plan: unknown plan lines: #{unknown}") unless unknown.empty?
  plan.reject { |l| l.match?(/\A(skip|note): /) }.map { |l| l.gsub(HOME, "~") }
end

# 戻す手順の 4。
def sync_apply(ok: [0])
  script("sync.sh", "--apply", "--quiet", *HOMES, ok: ok)
end

def write(path, text, mode = nil)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, text)
  File.chmod(mode, path) if mode
end

# review: nil (書かない) / :approved (今の build_id で承認) / :pending (承認の行を消して pending) /
# :pending_keep_ids (pending にしたが承認の行を残した誤り。R2)。
def manifest(name, kind, src, format, targets, review: nil, risk: "low")
  path = File.join(REPO, src.sub(/\.[a-z]+\z/, ".asset.yml"))
  lines = ["schema_version: 1", "name: #{name}", "kind: #{kind}", "visibility: public", "targets:"]
  targets.each { |t| lines << "  - #{t}" }
  lines += ["risk:", "  prompt_injection: #{risk}", "  privacy: low"]
  ids = ["  approved_build_id: #{Build.build_id_for(REPO, src, format)}", "  approved_artifact_kind: #{kind}"]
  case review
  when :approved then lines += ["review:", "  human_review: approved", *ids]
  when :pending then lines += ["review:", "  human_review: pending"]
  when :pending_keep_ids then lines += ["review:", "  human_review: pending", *ids]
  end
  lines += ["source:", "  path: #{src}", "  format: #{format}", "summary: demo #{name}"]
  write(path, lines.join("\n") + "\n")
end

def single(targets = %w[codex claude-code], review: nil)
  manifest("personal-single", "skill", "shared/skills/personal-single.md", "markdown", targets, review: review)
end

def tool(review)
  manifest("personal-tool", "script", "shared/scripts/personal-tool.rb", "text", %w[codex claude-code], review: review)
end

def keep(review)
  manifest("personal-keep", "script", "shared/scripts/personal-keep.rb", "text", %w[codex claude-code], review: review)
end

def plug(review)
  manifest("personal-plug", "plugin", "shared/plugins/personal-plug.js", "text", %w[opencode], review: review)
end

# 止める手順の 3 (承認を外す): `review` を `human_review: pending` の 1 行にし、承認の 2 行を消す。消した 2 行を返す (控え)。
APPROVAL_LINE = /\A  approved_(build_id|artifact_kind): /.freeze

def withdraw(manifest_path)
  lines = File.read(manifest_path).lines
  saved = lines.select { |l| l.match?(APPROVAL_LINE) }
  fail!("withdraw: two approval lines in #{manifest_path}: #{saved}") unless saved.size == 2
  rest = lines.reject { |l| l.match?(APPROVAL_LINE) }.map { |l| l == "  human_review: approved\n" ? "  human_review: pending\n" : l }
  File.write(manifest_path, rest.join)
  saved
end

# 戻す手順の 1 (承認を戻す): `human_review: pending` を `human_review: approved` に戻し、その下に 2 行を書く。
def reapprove(manifest_path, approval_lines)
  text = File.read(manifest_path)
  fail!("reapprove: pending line in #{manifest_path}") unless text.scan("  human_review: pending\n").size == 1
  File.write(manifest_path, text.sub("  human_review: pending\n") { "  human_review: approved\n#{approval_lines.join}" })
end

def ops
  manifest("personal-ops", "instruction", "shared/instructions/personal-ops.md", "markdown", %w[codex claude-code])
end

def skill_md(name)
  "---\nname: #{name}\ndescription: demo #{name}\n---\n\nbody #{name}\n"
end

# 配置先の path (本体と、script の sidecar)。
def paths_of(tool, name, kind)
  home = { "codex" => CODEX, "claude-code" => CLAUDE, "opencode" => OPENCODE }.fetch(tool)
  case kind
  when "skill" then [File.join(home, "skills", name)]
  when "script"
    body = File.join(home, "agent-tools/scripts", name)
    [body, "#{body}.agent-tools-managed.yml"]
  when "plugin" then [File.join(home, "plugins", "#{name}.js")]
  end
end

# tool home (人の CLAUDE.md を含む) の entry ごとの inode・mode・時刻・byte。except の path (とその下) は外す。
def snapshot(except = [])
  [CODEX, CLAUDE, OPENCODE].flat_map do |root|
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
      next if %w[. ..].include?(File.basename(path))
      next if except.any? { |e| path == e || path.start_with?("#{e}/") }

      st = File.lstat(path)
      # directory は中の entry を動かすと時刻が変わるので、inode と mode だけを比べる (中の entry は別に並ぶ)。
      next [path, st.ino, st.mode] if st.directory?

      body = st.file? ? Digest::SHA256.file(path).hexdigest : (st.symlink? ? File.readlink(path) : "-")
      [path, st.ino, st.mode, st.mtime.to_r, st.ctime.to_r, st.size, body]
    end.compact
  end
end

# --- docs の手順の隔離の command ---
DOC = File.read(File.join(ROOT, "docs/install-and-usage.md"))
SECTION_TEXT = MarkdownUnits.section(DOC, SECTION)
fail!("docs/install-and-usage.md must have the section '#{SECTION}'") unless SECTION_TEXT
SH = MarkdownUnits.sh_blocks(SECTION_TEXT)
check(SH.size == 2, "the section has two sh blocks (make the quarantine, then move): #{SH.size}")
MAKE, MOVE = SH.map { |b| b.lines.map(&:strip).reject(&:empty?) }
check(MAKE.size == 2, "the first block has 2 commands: #{MAKE}")
check(MOVE.size == 3, "the second block has 3 commands: #{MOVE}")
Q_LINE, MKDIR_LINE = MAKE
check(Q_LINE.start_with?("q=~/.local/share/agent-tools/quarantine/$(date +%Y%m%d-%H%M%S)-personal-x"),
      "the first command names the quarantine: #{Q_LINE}")
check(MKDIR_LINE.include?('mkdir "$q" &&'), "the second command stops when the quarantine exists: #{MKDIR_LINE}")
check(MKDIR_LINE.end_with?(' && (cd "$q" && pwd -P)'),
      "the second command prints where the quarantine really is, only when every mkdir succeeded: #{MKDIR_LINE}")
MV = { "skill" => "# skill", "script" => "# script", "plugin" => "# plugin" }.map do |kind, tag|
  line = MOVE.find { |c| c.end_with?(tag) || c.include?("#{tag} ") }
  fail!("the sh block has the #{kind} command: #{MOVE}") unless line
  [kind, line]
end.to_h

# docs の command を、止める asset の名前と tool に置き換えて走らせる (codex は ~/.codex の下の同じ場所。docs の説明のとおり)。
def mv_line(kind, tool, name)
  line = MV.fetch(kind).gsub("personal-x", name)
  return line if tool == "claude-code" || kind == "plugin"

  line.gsub("~/.claude/", "~/.codex/").gsub('"$q/claude-code/"', '"$q/codex/"')
end

def quarantine(name, moves, home: HOME)
  lines = MAKE.map { |l| l.gsub("personal-x", name) } + moves.map { |kind, tool| mv_line(kind, tool, name) }
  run("sh", "-c", "set -e\n#{lines.join("\n")}\n", home: home)
end

def qdir(name)
  File.join(QROOT, "#{STAMP}-#{name}")
end

# --- fixture ---
[CODEX, CLAUDE, OPENCODE, AGENTS, BIN].each { |dir| FileUtils.mkdir_p(dir) }
write(File.join(BIN, "date"), "#!/bin/sh\necho #{STAMP}\n", 0o755)
write(File.join(CLAUDE, "CLAUDE.md"), "# mine\n")
write(File.join(REPO, "shared/skills/personal-single.md"), skill_md("personal-single"))
single
write(File.join(REPO, "shared/skills/personal-med.md"), skill_md("personal-med"))
manifest("personal-med", "skill", "shared/skills/personal-med.md", "markdown", %w[codex claude-code],
         review: :approved, risk: "medium")
write(File.join(REPO, "shared/scripts/personal-tool.rb"), "#!/usr/bin/env ruby\nputs 'tool'\n")
tool(:approved)
write(File.join(REPO, "shared/scripts/personal-keep.rb"), "#!/usr/bin/env ruby\nputs 'keep'\n")
keep(:approved)
write(File.join(REPO, "shared/plugins/personal-plug.js"), "export const Plug = async () => ({});\n")
plug(:approved)
write(File.join(REPO, "shared/instructions/personal-ops.md"), "# ops\n")
ops
setup_apply
check(status_json["sync_targets"].all? { |t| t["state"] == "managed" }, "fixture: everything managed")
human = File.binread(File.join(CLAUDE, "CLAUDE.md"))
check(human.include?("@agent-tools/CLAUDE.md"), "fixture: connect added the import to the human CLAUDE.md")

# ===== 承認を外す道 (script の personal-tool) =====
tool_paths = %w[codex claude-code].flat_map { |t| paths_of(t, "personal-tool", "script") }
control = status_json
others = snapshot(tool_paths)
old_bodies = tool_paths.map { |p| File.binread(p) }

# --- R2: pending にして承認の行を残すと、register は catalog を更新しない。status は stale と出す (手順の 3 の止まる条件) ---
tool(:pending_keep_ids)
check(register(ok: [1]) == 1, "R2: register fails when the approval lines are left")
check(entry("codex", "personal-tool")["registration"] == "registered", "R2: the catalog is not updated")
check(state_of(status_json, "codex", "personal-tool") == "stale", "R2: status shows stale, not deployed_but_inactive")

# --- R1: 承認の行を消して pending にすると、register は exit 3 で、両 tool が deployed_but_inactive。旧い本体は残る ---
tool(:approved)
tool_manifest = File.join(REPO, "shared/scripts/personal-tool.asset.yml")
withdraw(tool_manifest)
check(File.read(tool_manifest).include?("  human_review: pending\n"), "R1: the manifest says pending")
check(register == 3, "R1: register exits 3")
%w[codex claude-code].each do |t|
  check(entry(t, "personal-tool")["registration"] == "human_review_required", "R1: [#{t}] human_review_required")
  check(state_of(status_json, t, "personal-tool") == "deployed_but_inactive", "R1: [#{t}] deployed_but_inactive")
end
check(tool_paths.map { |p| File.binread(p) } == old_bodies, "R1: the old body and sidecar stay")

# --- R7・S4: docs の command で、本体と sidecar を両 tool とも隔離の置き場へ動かす ---
out, rc = quarantine("personal-tool", [%w[script claude-code], %w[script codex]])
check(rc.zero?, "R7: the documented quarantine commands succeed: #{out}")
check(out.lines.map(&:chomp) == [File.realpath(qdir("personal-tool"))], "R7: the first block prints the real place: #{out}")
check(tool_paths.none? { |p| File.exist?(p) || File.symlink?(p) }, "R7: body and sidecar are gone from both homes")
%w[codex claude-code].each do |t|
  moved = Dir.children(File.join(qdir("personal-tool"), t)).sort
  check(moved == %w[personal-tool personal-tool.agent-tools-managed.yml], "R7: [#{t}] both files are quarantined: #{moved}")
end
json = status_json
%w[codex claude-code].each { |t| check(state_of(json, t, "personal-tool") == "missing", "S4: [#{t}] missing") }
check(rows(json).reject { |r| r[1] == "personal-tool" } == rows(control).reject { |r| r[1] == "personal-tool" },
      "N1: other rows match the saved status: #{rows(json)} vs #{rows(control)}")
check(json["orphans"].empty?, "S4: no orphan")
check(snapshot(tool_paths) == others, "N1・N2: other targets, owned files and the human CLAUDE.md are unchanged")
dout, rc = doctor
check(rc.zero? && dout.lines.none? { |l| l.start_with?("warn:") && l.include?("personal-tool") },
      "S4: doctor has no warn for the stopped asset: #{dout}")

# --- N3: 同じ名前の隔離の置き場が在ると、docs の mkdir で止まり、中を変えない ---
before = Dir.glob(File.join(qdir("personal-tool"), "**", "*")).sort
out, rc = quarantine("personal-tool", [])
check(!rc.zero?, "N3: the documented mkdir stops when the quarantine exists")
check(out.lines.none? { |l| l.start_with?("/") }, "N3: no place is printed when the mkdir stops: #{out}")
check(Dir.glob(File.join(qdir("personal-tool"), "**", "*")).sort == before, "N3: the existing quarantine is unchanged")

# --- B1: 止めている間に source を変えてから戻す。catalog の build_id は止めたときのままなので、pending のまま build と
# register をかけ直してから読む (register の警告は pending では build_id を出さない)。dry-run の plan が対象の create
# だけと見てから sync --apply。managed と body の一致に戻る ---
tool_src = File.join(REPO, "shared/scripts/personal-tool.rb")
File.binwrite(tool_src, "#!/usr/bin/env ruby\nputs 'tool v2'\n")
current = Build.build_id_for(REPO, "shared/scripts/personal-tool.rb", "text")
check(entry("codex", "personal-tool")["build_id"] != current, "B1: the catalog keeps the stopped build_id until register")
build_register
%w[codex claude-code].each do |t|
  check(entry(t, "personal-tool")["build_id"] == current, "B1: [#{t}] after register, the catalog holds the current build_id")
end
check(MarkdownUnits.squash(SECTION_TEXT).include?(MarkdownUnits.squash("pending のまま `./scripts/build.sh --prune` と `./scripts/register.sh` をかけ")),
      "B1: the docs re-run build and register while pending before reading the build_id")
check(MarkdownUnits.squash(SECTION_TEXT).include?(MarkdownUnits.squash("`human_review: pending` を `human_review: approved` に戻し")),
      "B1: the docs turn the review back to approved")
reapprove(tool_manifest, ["  approved_build_id: #{entry('codex', 'personal-tool')['build_id']}\n",
                          "  approved_artifact_kind: script\n"])
plan = restore_plan
check(plan.sort == ["create: [claude-code] ~/.claude/agent-tools/scripts/personal-tool",
                    "create: [codex] ~/.codex/agent-tools/scripts/personal-tool"],
      "B1: the dry-run plan creates only the restored asset: #{plan}")
sync_apply
json = status_json
%w[codex claude-code].each { |t| check(state_of(json, t, "personal-tool") == "managed", "B1: [#{t}] managed") }
check(tool_paths.all? { |p| File.file?(p) }, "B1: body and sidecar are created again")
dout, rc = doctor
%w[codex claude-code].each do |t|
  check(dout.lines.map(&:chomp).include?("ok: target: [#{t}] personal-tool managed (body matches a fresh build)"),
        "B1: [#{t}] the body matches a fresh build: #{dout}")
end
check(rc.zero?, "B1: doctor passes")
check(snapshot(tool_paths) == others, "N1・B1: restoring does not touch other targets")

# ===== 承認を外す道で、source を変えずに戻す (human review の要る skill の personal-med。控えた 2 行をそのまま戻す) =====
med_manifest = File.join(REPO, "shared/skills/personal-med.asset.yml")
med_paths = %w[codex claude-code].flat_map { |t| paths_of(t, "personal-med", "skill") }
others = snapshot(med_paths)
saved = withdraw(med_manifest)
check(register == 3, "R1: register exits 3 for the skill")
%w[codex claude-code].each do |t|
  check(state_of(status_json, t, "personal-med") == "deployed_but_inactive", "R1: [#{t}] personal-med deployed_but_inactive")
end
out, rc = quarantine("personal-med", [%w[skill claude-code], %w[skill codex]])
check(rc.zero? && med_paths.none? { |p| File.exist?(p) }, "R7: the documented skill commands move both copies: #{out}")
reapprove(med_manifest, saved)
plan = restore_plan
check(plan.sort == ["create: [claude-code] ~/.claude/skills/personal-med", "create: [codex] ~/.codex/skills/personal-med"],
      "B1: with the saved lines, the plan creates only the skill: #{plan}")
sync_apply
%w[codex claude-code].each do |t|
  check(state_of(status_json, t, "personal-med") == "managed", "B1: [#{t}] personal-med managed with the saved lines")
end
check(snapshot(med_paths) == others, "N1: restoring the skill does not touch other targets")
expect_body_match("B1", [%w[codex personal-med], %w[claude-code personal-med]])

# ===== targets から外す道 (危険度の低い skill の personal-single を codex だけ) =====
# --- R3: 危険度の低い skill に pending を書いても登録は外れない (道を分ける根拠) ---
single(review: :pending)
check(register.zero?, "R3: register exits 0")
%w[codex claude-code].each do |t|
  check(entry(t, "personal-single")["registration"] == "registered", "R3: [#{t}] stays registered")
end
single
register

# 人が CLAUDE.md の import を外していても、戻す手順は人の file を変えない (setup.sh の connect は足しうる)。
human_md = File.join(CLAUDE, "CLAUDE.md")
File.binwrite(human_md, "# mine\n")
check(script("setup.sh", *HOMES).first.lines.any? { |l| l.start_with?("add-import: ") },
      "N2: setup.sh would add the import back (the reason the restore does not use it)")

codex_single = paths_of("codex", "personal-single", "skill")
claude_entry = entry("claude-code", "personal-single").values_at("registration", "build_id", "artifact_kind")
control = status_json
others = snapshot(codex_single)

# --- R4・S5: codex を targets から外す。codex の行が消えて orphan に出る。claude-code の entry と配置は変わらない ---
single(%w[claude-code])
build_register
json = status_json
check(state_of(json, "codex", "personal-single").nil?, "S5: the codex row is gone")
check(state_of(json, "claude-code", "personal-single") == "managed", "S5: the claude-code row stays managed")
check(json["orphans"] == [{ "tool" => "codex", "name" => "personal-single", "kind" => "skill" }], "S5: orphan: #{json}")
check(entry("codex", "personal-single").nil?, "R4: the codex entry is gone")
check(entry("claude-code", "personal-single").values_at("registration", "build_id", "artifact_kind") == claude_entry,
      "R4: the claude-code entry keeps registration, build_id and artifact_kind")

# --- 隔離: docs の skill の command を codex だけに当てる ---
_, rc = quarantine("personal-single", [%w[skill codex]])
check(rc.zero?, "the documented skill command succeeds for codex")
check(!File.exist?(codex_single.first), "the codex skill dir is gone")
check(Dir.children(File.join(qdir("personal-single"), "codex")) == ["personal-single"], "the skill dir is quarantined")
json = status_json
check(json["orphans"].empty?, "S5: the orphan row is gone")
check(rows(json) == rows(control).reject { |r| r[0] == "codex" && r[1] == "personal-single" },
      "N1: other rows match the saved status: #{rows(json)} vs #{rows(control)}")
check(snapshot(codex_single) == others, "N1: the claude-code copy and other targets are unchanged")

# --- N4: 戻す前にほかの asset が古いと、dry-run の plan にその行が出る (戻す手順の 2 が止める形) ---
single(%w[codex claude-code])
ops_src = File.join(REPO, "shared/instructions/personal-ops.md")
File.binwrite(ops_src, "# ops v2\n")
plan = restore_plan
check(plan.any? { |l| l.start_with?("update: ") && l.include?("AGENTS.md") }, "N4: the plan shows the other update: #{plan}")
File.binwrite(ops_src, "# ops\n")

# --- B2: plan が対象の create だけになったら sync --apply。codex に作り直し、claude-code の写しと人の file はそのまま ---
plan = restore_plan
check(plan == ["create: [codex] ~/.codex/skills/personal-single"], "B2: the plan creates only the codex skill: #{plan}")
sync_apply
json = status_json
check(state_of(json, "codex", "personal-single") == "managed", "B2: codex managed again")
expect_body_match("B2", [%w[codex personal-single], %w[claude-code personal-single]])
check(snapshot(codex_single) == others, "B2: restoring does not touch the claude-code copy or other targets")
check(File.binread(human_md) == "# mine\n", "N2・B2: restoring does not add the import back to the human CLAUDE.md")

# ===== asset を消す道 (target が 1 つの plugin の personal-plug) =====
plug_paths = paths_of("opencode", "personal-plug", "plugin")
plug_files = %w[shared/plugins/personal-plug.js shared/plugins/personal-plug.asset.yml]
FileUtils.mkdir_p(BACKUP)
plug_files.each { |f| FileUtils.cp(File.join(REPO, f), File.join(BACKUP, File.basename(f))) }
others = snapshot(plug_paths)
plug_files.each { |f| File.delete(File.join(REPO, f)) }
build_register
check(status_json["orphans"] == [{ "tool" => "opencode", "name" => "personal-plug", "kind" => "plugin" }],
      "R5: the deleted plugin is an orphan")
_, rc = quarantine("personal-plug", [%w[plugin opencode]])
check(rc.zero? && !File.exist?(plug_paths.first), "R5: the documented plugin command moves the plugin")
check(status_json["orphans"].empty?, "R5: no orphan after the quarantine")
check(snapshot(plug_paths) == others, "N1: other targets are unchanged")

# --- B3: 戻す先に手書きの同名 file があると、sync は conflict で止まり、上書きしない ---
plug_files.each { |f| FileUtils.cp(File.join(BACKUP, File.basename(f)), File.join(REPO, f)) }
plug(:approved)
write(plug_paths.first, "export const Hand = async () => ({});\n")
hand = File.binread(plug_paths.first)
plan = restore_plan
check(plan.size == 1 && plan.first.start_with?("conflict: [opencode] ~/.config/opencode/plugins/personal-plug.js"),
      "B3: the plan shows the conflict, so the restore stops before --apply: #{plan}")
sync_apply(ok: [0, 1])
check(File.binread(plug_paths.first) == hand, "B3: the hand-written file is not overwritten even by --apply")
check(state_of(status_json, "opencode", "personal-plug") == "conflict", "B3: status shows conflict")
File.delete(plug_paths.first)
plan = restore_plan
check(plan == ["create: [opencode] ~/.config/opencode/plugins/personal-plug.js"], "B3: the plan creates only the plugin: #{plan}")
sync_apply
check(state_of(status_json, "opencode", "personal-plug") == "managed", "B3: managed after the hand file is gone")
expect_body_match("B3", [%w[opencode personal-plug]])

# ===== R9: script の本体だけを動かすと、sidecar が残り、catalog から消えても orphan に出ない (両方を動かす理由) =====
keep_paths = %w[codex claude-code].flat_map { |t| paths_of(t, "personal-keep", "script") }
keep_files = %w[shared/scripts/personal-keep.rb shared/scripts/personal-keep.asset.yml]
keep_files.each { |f| FileUtils.cp(File.join(REPO, f), File.join(BACKUP, File.basename(f))) }
keep_files.each { |f| File.delete(File.join(REPO, f)) }
build_register
check(status_json["orphans"].map { |o| o["name"] }.uniq == ["personal-keep"], "R9: the deleted script is an orphan")
keep_paths.each_slice(2) { |body, _sidecar| File.delete(body) }
check(status_json["orphans"].empty?, "R9: a sidecar alone is not listed as an orphan")
check(keep_paths.each_slice(2).all? { |_body, sidecar| File.exist?(sidecar) }, "R9: the sidecars are left behind")

# ===== R6: repo の最後の asset を消すと catalog が空になり、status は orphan を出さない。marker を見て docs の command で動かす =====
repo2 = File.join(TMP, "repo-last")
home2 = File.join(TMP, "home-last")
homes2 = ["--codex-home", File.join(home2, ".codex"), "--claude-home", File.join(home2, ".claude"),
          "--opencode-home", File.join(home2, ".config/opencode")]
FileUtils.mkdir_p(File.join(repo2, "shared/skills"))
FileUtils.cp(File.join(REPO, "shared/skills/personal-single.md"), File.join(repo2, "shared/skills/"))
FileUtils.cp(File.join(REPO, "shared/skills/personal-single.asset.yml"), File.join(repo2, "shared/skills/"))
[".codex", ".claude", ".config/opencode"].each { |d| FileUtils.mkdir_p(File.join(home2, d)) }
script("setup.sh", "--apply", "--quiet", *homes2, root: repo2, home: home2)
last = [File.join(home2, ".codex/skills/personal-single"), File.join(home2, ".claude/skills/personal-single")]
check(last.all? { |d| File.directory?(d) }, "R6: the only asset is deployed to both tools")
last_files = %w[personal-single.md personal-single.asset.yml]
last_files.each { |f| FileUtils.cp(File.join(repo2, "shared/skills", f), File.join(BACKUP, "last-#{f}")) }
last_files.each { |f| File.delete(File.join(repo2, "shared/skills", f)) }
script("build.sh", "--prune", "--quiet", root: repo2, home: home2)
script("register.sh", "--quiet", root: repo2, home: home2)
json = JSON.parse(script("status.sh", "--json", *homes2, root: repo2, home: home2).first)
check(json["orphans"].empty? && json["sync_targets"].empty?, "R6: an empty catalog shows no orphan row: #{json}")
last.each do |d|
  check(File.read(File.join(d, ".agent-tools-managed.yml")).include?("personal-single"), "R6: the marker can be checked: #{d}")
end
out, rc = quarantine("personal-single", [%w[skill codex], %w[skill claude-code]], home: home2)
check(rc.zero? && last.none? { |d| File.exist?(d) }, "R6: the documented skill commands move both copies: #{out}")
# 戻す: asset を戻し (git で戻す代わりに控えを戻す)、build・register・sync の dry-run が両 tool の create だけと見て apply
last_files.each { |f| FileUtils.cp(File.join(BACKUP, "last-#{f}"), File.join(repo2, "shared/skills", f)) }
script("build.sh", "--prune", "--quiet", root: repo2, home: home2)
script("register.sh", "--quiet", root: repo2, home: home2)
out, = script("sync.sh", *homes2, root: repo2, home: home2)
plan = out.lines.map(&:chomp).select { |l| l.match?(/\A(create|update|delete|conflict): /) }.map { |l| l.gsub(home2, "~") }
check(plan.sort == ["create: [claude-code] ~/.claude/skills/personal-single", "create: [codex] ~/.codex/skills/personal-single"],
      "R6: the restore plan creates only the two copies: #{plan}")
script("sync.sh", "--apply", "--quiet", *homes2, root: repo2, home: home2)
expect_body_match("R6", [%w[codex personal-single], %w[claude-code personal-single]], root: repo2, home: home2, homes: homes2)

# ===== N3: 置き場の親が symlink で tool home の内側を指すと、1 つ目の block が出す場所でそれと分かる =====
trap = File.join(CLAUDE, "trap")
FileUtils.mkdir_p(trap)
FileUtils.mv(QROOT, "#{QROOT}.real")
File.symlink(trap, QROOT)
out, rc = quarantine("personal-z", [])
check(rc.zero? && out.lines.map(&:chomp) == [File.join(File.realpath(trap), "#{STAMP}-personal-z")],
      "N3: the printed place shows the quarantine is inside the tool home: #{out}")
File.delete(QROOT)
FileUtils.mv("#{QROOT}.real", QROOT)
FileUtils.rm_rf(trap)

# ===== O1・O2: hook の登録は、外すときは本体より先、戻すときは本体の後 =====
# 節の番号つきの段 (行の頭の `<数>. ` と、字下げした続きの行) を、手順と戻す手順の 2 つの列に分けて読む。
def numbered_runs(text)
  runs = []
  current = nil
  MarkdownUnits.prose(text).each_line do |line|
    if (m = line.match(/\A(\d+)\. (.*)/))
      runs << [] if m[1] == "1"
      current = [m[1].to_i, +m[2]]
      runs.last << current
    elsif current && line.match?(/\A[ \t]+\S/)
      current[1] << line.strip
    elsif !line.strip.empty?
      current = nil
    end
  end
  runs
end

def step(run, phrase)
  found = run.select { |_, body| MarkdownUnits.squash(body).include?(MarkdownUnits.squash(phrase)) }
  fail!("one step has '#{phrase}': #{found}") unless found.size == 1
  found.first
end

stop_steps, back_steps = numbered_runs(SECTION_TEXT)
check(stop_steps && back_steps, "the section has the stop steps and the restore steps")
unhook = step(stop_steps, "hook の登録を外します")
move = step(stop_steps, "隔離の置き場へ動かします")
check(unhook[0] < move[0], "O1: the hook is unregistered in an earlier step than the move: #{unhook[0]} / #{move[0]}")
check(MarkdownUnits.squash(unhook[1]).include?(MarkdownUnits.squash("本体を動かす前に済ませます")),
      "O1: the hook step says it comes before the move")
restore = step(back_steps, "`./scripts/sync.sh --apply` をかけます")
rehook = step(back_steps, "hook の登録を戻します")
check(restore[0] < rehook[0], "O2: the hook is registered again after the body is back: #{restore[0]} / #{rehook[0]}")
check(MarkdownUnits.squash(rehook[1]).include?(MarkdownUnits.squash("本体が先、登録が後")),
      "O2: the hook step says the body comes first")

puts "revoke-test: ok (#{$checks} checks)"
