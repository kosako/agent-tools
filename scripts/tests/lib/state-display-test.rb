# frozen_string_literal: true

# status と doctor の target の表示 (#723) の self-test。scripts/tests/state-display-test.sh から呼ぶ。
# 一時 directory に fixture の repo と fake の tool home を作り、setup.sh --apply で配備してから、登録を外す・
# target の path を手書きの file や dangling な symlink に置き換える。実際の tool home には触れない。network access なし。
# 期待値の表 (#723 のコメント) の ID を case の名前に添える。

require "fileutils"
require "json"
require "open3"

SCRIPTS = File.expand_path("../..", __dir__)
ROOT = File.expand_path("..", SCRIPTS)
require File.join(SCRIPTS, "lib", "build")

TMP = File.realpath(ARGV.fetch(0))
REPO = File.join(TMP, "repo")
CODEX = File.join(TMP, "codex")
CLAUDE = File.join(TMP, "claude")
OPENCODE = File.join(TMP, "opencode")
AGENTS = File.join(TMP, "agents")
XDG = File.join(TMP, "xdg-config")
HOMES = ["--codex-home", CODEX, "--claude-home", CLAUDE, "--opencode-home", OPENCODE].freeze

# 期待する文言は code の定数を使わずに書く (定数を変えたら落ちるように)。
INACTIVE = "(not registered, so sync leaves the target path as it is; " \
           "whether it is still loaded or run is not checked)"
MANAGED_NOTE = "note:      managed = the deployed marker carries the build_id of generated/ " \
               "(instruction: same bytes as generated/ plus the local fragment); " \
               "doctor compares the body, and what clients loaded is not checked"
TOP_KEYS = %w[assets checks contract_version generated orphans register repo sync_targets].freeze
# 入れ子の object の key の集合 (docs/status-manifest-contract.md の Fields)。
NESTED_KEYS = {
  "repo" => %w[clean present],
  "assets" => %w[manifest_errors total],
  "checks" => %w[manifest_validation prompt_injection_static],
  "generated" => %w[stale total],
  "register" => %w[catalog_present human_review_required registered unsupported],
}.freeze

$checks = 0

def fail!(message)
  warn "FAIL: #{message}"
  exit 1
end

def check(cond, message)
  $checks += 1
  fail!(message) unless cond
end

def run!(label, *argv, ok: [0])
  out, status = Open3.capture2e({ "XDG_CONFIG_HOME" => XDG }, *argv)
  fail!("#{label}: exit #{status.exitstatus}: #{out}") unless ok.include?(status.exitstatus)
  [out, status.exitstatus]
end

def status_human(homes = HOMES)
  run!("status", File.join(SCRIPTS, "status.sh"), "--root", REPO, *homes).first
end

def status_json(homes = HOMES)
  JSON.parse(run!("status --json", File.join(SCRIPTS, "status.sh"), "--json", "--root", REPO, *homes).first)
end

def doctor
  run!("doctor", File.join(SCRIPTS, "doctor.sh"), "--root", REPO, *HOMES, "--agents-home", AGENTS, ok: [0, 1])
end

def register(ok: [0, 3])
  run!("register", File.join(SCRIPTS, "register.sh"), "--quiet", "--root", REPO, ok: ok).last
end

def write(path, text, mode = nil)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, text)
  File.chmod(mode, path) if mode
end

# review: nil (書かない) / :approved (今の build_id で承認) / :pending (承認の行を消して pending)。
def manifest(path, name, kind, src, format, targets, review: nil, risk: "low")
  lines = ["schema_version: 1", "name: #{name}", "kind: #{kind}", "visibility: public", "targets:"]
  targets.each { |t| lines << "  - #{t}" }
  lines += ["risk:", "  prompt_injection: #{risk}", "  privacy: low"]
  case review
  when :approved
    lines += ["review:", "  human_review: approved", "  approved_build_id: #{Build.build_id_for(REPO, src, format)}",
              "  approved_artifact_kind: #{kind}"]
  when :pending
    lines += ["review:", "  human_review: pending"]
  end
  lines += ["source:", "  path: #{src}", "  format: #{format}", "summary: demo #{name}"]
  write(path, lines.join("\n") + "\n")
end

def skill_md(name)
  "---\nname: #{name}\ndescription: demo #{name}\n---\n\nbody #{name}\n"
end

def med(review)
  manifest(File.join(REPO, "shared/skills/personal-med.asset.yml"), "personal-med", "skill",
           "shared/skills/personal-med.md", "markdown", %w[codex claude-code], review: review, risk: "medium")
end

def tool(review)
  manifest(File.join(REPO, "shared/scripts/personal-tool.asset.yml"), "personal-tool", "script",
           "shared/scripts/personal-tool.rb", "text", %w[codex claude-code], review: review)
end

def plug(review)
  manifest(File.join(REPO, "shared/plugins/personal-plug.asset.yml"), "personal-plug", "plugin",
           "shared/plugins/personal-plug.js", "text", %w[opencode], review: review)
end

def lines_of(out, prefix)
  out.lines.map(&:chomp).select { |l| l.start_with?(prefix) }
end

def one_line(out, prefix)
  found = lines_of(out, prefix)
  fail!("expected one line starting with '#{prefix}': #{out}") unless found.size == 1
  found.first
end

def state_of(json, tool, name)
  row = json["sync_targets"].find { |t| t["tool"] == tool && t["name"] == name }
  fail!("no sync_targets row for [#{tool}] #{name}: #{json}") unless row
  row["state"]
end

# C1: JSON の field の集合と値の形は変えない。
def expect_contract(label, json)
  check(json.keys.sort == TOP_KEYS, "#{label}: top-level keys must stay #{TOP_KEYS}: #{json.keys.sort}")
  check(json["contract_version"] == 3, "#{label}: contract_version must stay 3")
  NESTED_KEYS.each do |key, keys|
    check(json[key].is_a?(Hash) && json[key].keys.sort == keys, "#{label}: #{key} keys must stay #{keys}: #{json[key]}")
  end
  check(json["sync_targets"].is_a?(Array) && json["orphans"].is_a?(Array), "#{label}: rows stay arrays")
  json["orphans"].each do |o|
    check(o.keys.sort == %w[kind name tool], "#{label}: orphans keys must stay tool/name/kind: #{o}")
  end
  json["sync_targets"].each do |t|
    check(t.keys.sort == %w[name state tool], "#{label}: sync_targets keys must stay tool/name/state: #{t}")
    check(%w[managed stale conflict missing deployed_but_inactive].include?(t["state"]),
          "#{label}: state must be a contract value: #{t}")
  end
end

def expect_inactive(label, tool, name, status_out, doctor_out)
  check(one_line(status_out, "target:    [#{tool}] #{name} ") ==
          "target:    [#{tool}] #{name} deployed_but_inactive #{INACTIVE}",
        "#{label}: status line for [#{tool}] #{name}: #{status_out}")
  check(one_line(doctor_out, "warn: target: [#{tool}] #{name} ") ==
          "warn: target: [#{tool}] #{name} deployed_but_inactive #{INACTIVE}",
        "#{label}: doctor line for [#{tool}] #{name}: #{doctor_out}")
end

# --- fixture ---
[CODEX, CLAUDE, OPENCODE, AGENTS, XDG].each { |dir| FileUtils.mkdir_p(dir) }
write(File.join(REPO, "shared/skills/personal-single.md"), skill_md("personal-single"))
manifest(File.join(REPO, "shared/skills/personal-single.asset.yml"), "personal-single", "skill",
         "shared/skills/personal-single.md", "markdown", %w[codex claude-code])
write(File.join(REPO, "shared/skills/personal-med.md"), skill_md("personal-med"))
med(:approved)
write(File.join(REPO, "shared/scripts/personal-tool.rb"), "#!/usr/bin/env ruby\nputs 'tool'\n")
tool(:approved)
write(File.join(REPO, "shared/plugins/personal-plug.js"), "export const Plug = async () => ({});\n")
plug(:approved)
write(File.join(REPO, "shared/instructions/personal-ops.md"), "# ops\n")
manifest(File.join(REPO, "shared/instructions/personal-ops.asset.yml"), "personal-ops", "instruction",
         "shared/instructions/personal-ops.md", "markdown", %w[codex claude-code])
run!("setup", File.join(SCRIPTS, "setup.sh"), "--apply", "--quiet", "--root", REPO, *HOMES)

# --- S6・C1: すべて managed のとき、注は最後に 1 回だけ。target の行には何も足さない ---
out = status_human
check(lines_of(out, "note:") == [MANAGED_NOTE], "S6: one managed note line: #{out}")
check(out.lines.last.chomp == MANAGED_NOTE, "S6: the managed note is the last line: #{out}")
lines_of(out, "target:").each do |line|
  check(line.match?(/\Atarget:    \[[a-z-]+\] personal-[a-z]+ managed\z/), "S6: managed rows stay bare: #{line}")
end
expect_contract("baseline", status_json)
dout, rc = doctor
check(rc.zero? && dout.lines.last.chomp == "doctor: ok", "baseline doctor: #{dout}")
check(one_line(dout, "ok: target: [codex] personal-med ") ==
        "ok: target: [codex] personal-med managed (body matches a fresh build)",
      "D2: managed rows keep the body result only: #{dout}")

# --- S6: managed が 1 つも無いとき (配備の前の空の home)、注を出さない ---
empty = %w[codex claude opencode].map { |t| File.join(TMP, "empty-#{t}") }
empty.each { |dir| FileUtils.mkdir_p(dir) }
empty_homes = ["--codex-home", empty[0], "--claude-home", empty[1], "--opencode-home", empty[2]]
out = status_human(empty_homes)
check(lines_of(out, "note:").empty?, "S6: no managed note without managed rows: #{out}")
check(lines_of(out, "target:").all? { |l| l.end_with?(" missing") }, "missing rows stay bare: #{out}")
expect_contract("empty homes", status_json(empty_homes))

# --- S1・D1: human review の要る skill と script の承認を外す。旧い body は残り、表示は止まったと言わない ---
med_skill = File.join(CODEX, "skills/personal-med/SKILL.md")
tool_body = File.join(CODEX, "agent-tools/scripts/personal-tool")
before = [File.binread(med_skill), File.binread(tool_body)]
med(:pending)
tool(:pending)
check(register == 3, "S1: register exits 3 when an approval is withdrawn")
json = status_json
expect_contract("withdrawn", json)
%w[codex claude-code].each do |t|
  check(state_of(json, t, "personal-med") == "deployed_but_inactive", "S1: [#{t}] personal-med state: #{json}")
  check(state_of(json, t, "personal-tool") == "deployed_but_inactive", "S1: [#{t}] personal-tool state: #{json}")
end
sout = status_human
dout, rc = doctor
%w[codex claude-code].each do |t|
  expect_inactive("S1", t, "personal-med", sout, dout)
  expect_inactive("S1", t, "personal-tool", sout, dout)
end
check(rc.zero? && dout.lines.last.chomp == "doctor: ok", "D1: deployed_but_inactive keeps exit 0: #{dout}")
check([File.binread(med_skill), File.binread(tool_body)] == before, "S1: the old bodies stay as they were")
# S6: managed が残っていれば、注は 1 回だけ
check(lines_of(sout, "note:") == [MANAGED_NOTE], "S6: one managed note with mixed states: #{sout}")

# --- S2: 未登録の plugin の target が、marker の無い手書きの file。写しが残るとは言わず、同じ注 ---
plug(:pending)
register
plug_target = File.join(OPENCODE, "plugins/personal-plug.js")
File.binwrite(plug_target, "export const Hand = async () => ({});\n")
json = status_json
check(state_of(json, "opencode", "personal-plug") == "deployed_but_inactive", "S2: hand-written file state: #{json}")
sout = status_human
dout, = doctor
expect_inactive("S2", "opencode", "personal-plug", sout, dout)

# --- S3: 未登録の skill の target が dangling な symlink。同じ注 (読み込める・実行できるとは言わない) ---
dangling = File.join(CODEX, "skills/personal-med")
FileUtils.rm_rf(dangling)
File.symlink(File.join(TMP, "nowhere"), dangling)
json = status_json
check(state_of(json, "codex", "personal-med") == "deployed_but_inactive", "S3: dangling symlink state: #{json}")
sout = status_human
dout, = doctor
expect_inactive("S3", "codex", "personal-med", sout, dout)

# --- C1: orphan の行がある JSON でも、key の集合は変わらない ---
manifest(File.join(REPO, "shared/skills/personal-single.asset.yml"), "personal-single", "skill",
         "shared/skills/personal-single.md", "markdown", %w[codex])
register
json = status_json
check(json["orphans"] == [{ "tool" => "claude-code", "name" => "personal-single", "kind" => "skill" }],
      "C1: the removed target is an orphan: #{json['orphans']}")
expect_contract("orphan", json)

# --- S6: instruction は、local の断片を足した内容で配っても managed のまま (注の「plus the local fragment」) ---
write(File.join(XDG, "agent-tools", "instructions.local.md"), "local rule\n")
run!("setup with a fragment", File.join(SCRIPTS, "setup.sh"), "--apply", "--quiet", "--root", REPO, *HOMES)
json = status_json
%w[codex claude-code].each do |t|
  check(state_of(json, t, "personal-ops") == "managed", "S6: [#{t}] instruction with a fragment stays managed: #{json}")
end
check(File.binread(File.join(CODEX, "AGENTS.md")).include?("local rule"), "S6: the fragment is deployed")
check(lines_of(status_human, "note:") == [MANAGED_NOTE], "S6: one managed note with a fragment")

# --- docs が載せる注の文言は、表示と同じ ---
usage = File.read(File.join(ROOT, "docs/install-and-usage.md"))
check(usage.include?("`#{INACTIVE}`"), "docs/install-and-usage.md must quote the deployed_but_inactive note")

puts "state-display-test: ok (#{$checks} checks)"
