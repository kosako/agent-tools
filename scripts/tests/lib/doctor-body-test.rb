# frozen_string_literal: true

# doctor の body の検査 (#722) の self-test。scripts/tests/doctor-body-test.sh から呼ぶ。
# 一時 directory に fixture の repo と fake の tool home を作り、setup.sh --apply で配備してから、配備先の body を
# marker を変えずに変え、doctor.sh の target の行を見る。実際の tool home には触れない。network access なし。
# 期待値の表 (#722 のコメント、#768 の 5 件目) の ID を case の名前に添える。

require "digest"
require "fileutils"
require "json"
require "open3"

SCRIPTS = File.expand_path("../..", __dir__)
require File.join(SCRIPTS, "lib", "body_check")
require File.join(SCRIPTS, "lib", "build")
require File.join(SCRIPTS, "lib", "sync")

TMP = File.realpath(ARGV.fetch(0))
REPO = File.join(TMP, "repo")
CODEX = File.join(TMP, "codex")
CLAUDE = File.join(TMP, "claude")
OPENCODE = File.join(TMP, "opencode")
AGENTS = File.join(TMP, "agents")
XDG = File.join(TMP, "xdg-config")
TEMP = File.join(TMP, "tmpdir")
FRAGMENT = File.join(XDG, "agent-tools", "instructions.local.md")
HOMES = ["--codex-home", CODEX, "--claude-home", CLAUDE, "--opencode-home", OPENCODE].freeze
# in-process で使う sync と local の断片の読み取りにも、手元の断片 (#689) を読ませない。
ENV["XDG_CONFIG_HOME"] = XDG

$checks = 0
$backups = 0

def fail!(message)
  warn "FAIL: #{message}"
  exit 1
end

def check(cond, message)
  $checks += 1
  fail!(message) unless cond
end

def env(extra = {})
  { "XDG_CONFIG_HOME" => XDG, "TMPDIR" => TEMP }.merge(extra)
end

def run!(label, *argv, extra_env: {}, ok: [0])
  out, status = Open3.capture2e(env(extra_env), *argv)
  fail!("#{label}: exit #{status.exitstatus}: #{out}") unless ok.include?(status.exitstatus)
  out
end

def setup_apply(label = "setup")
  run!(label, File.join(SCRIPTS, "setup.sh"), "--apply", "--quiet", "--root", REPO, *HOMES, ok: [0])
end

def sync_apply(label = "sync")
  run!(label, File.join(SCRIPTS, "sync.sh"), "--apply", "--quiet", "--root", REPO, *HOMES)
end

def build_register(label = "build")
  run!(label, File.join(SCRIPTS, "build.sh"), "--quiet", "--root", REPO)
  run!(label, File.join(SCRIPTS, "register.sh"), "--quiet", "--root", REPO, ok: [0, 3])
end

# doctor を走らせ、[出力, exit] を返す。走らせた後に、一時 directory の置き場 (TMPDIR) が空に戻ったことを見る (R1)。
def doctor(label, extra_env: {}, umask: nil)
  opts = umask ? { umask: umask } : {}
  out, status = Open3.capture2e(env(extra_env), File.join(SCRIPTS, "doctor.sh"), "--root", REPO, *HOMES,
                                "--agents-home", AGENTS, **opts)
  check(Dir.children(TEMP).empty?, "#{label}: doctor must remove its temporary directory: #{Dir.children(TEMP)}")
  # 出力に fixture の絶対 path を出さない (N5)。
  check(!out.include?(TMP), "#{label}: doctor output must not contain absolute paths: #{out}")
  [out, status.exitstatus]
end

def target_line(out, tool, name)
  lines = out.lines.map(&:chomp).select { |l| l.match?(/\A\w+: target: \[#{Regexp.escape(tool)}\] #{Regexp.escape(name)} /) }
  fail!("expected one target line for [#{tool}] #{name}: #{out}") unless lines.size == 1
  lines.first
end

MATCH = "managed (body matches a fresh build)"

def expect_line(label, out, tool, name, expected)
  line = target_line(out, tool, name)
  check(line == "#{expected.split(' ', 2).first} target: [#{tool}] #{name} #{expected.split(' ', 2).last}",
        "#{label}: [#{tool}] #{name}: expected '#{expected}', got '#{line}'")
end

def expect_match(label, out, tool, name)
  expect_line(label, out, tool, name, "ok: #{MATCH}")
end

def expect_differs(label, out, tool, name, detail)
  expect_line(label, out, tool, name, "warn: managed but the body differs from a fresh build (#{detail})")
end

def expect_unverified(label, out, tool, name, reason)
  expect_line(label, out, tool, name, "info: managed (body not verified: #{reason})")
end

TARGETS = [
  %w[codex personal-single], %w[claude-code personal-single],
  %w[codex personal-dir], %w[claude-code personal-dir],
  %w[codex personal-tool], %w[claude-code personal-tool],
  %w[opencode personal-plug],
  %w[codex personal-ops], %w[claude-code personal-ops],
].freeze

def expect_all_match(label, out, except: [])
  (TARGETS - except).each { |tool, name| expect_match(label, out, tool, name) }
end

# repo と tool home の entry ごとの inode・mode・時刻・byte (R1。cksum だけでは同じ byte の書き直しを見逃す)。
def snapshot
  [REPO, CODEX, CLAUDE, OPENCODE, AGENTS].flat_map do |root|
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
      next if %w[. ..].include?(File.basename(path))

      st = File.lstat(path)
      body = st.file? ? Digest::SHA256.file(path).hexdigest : (st.symlink? ? File.readlink(path) : "-")
      [path, st.ino, st.mode, st.mtime.to_r, st.ctime.to_r, st.size, body]
    end.compact
  end
end

# 一時の変更を当て、block の後に file を元に戻す (cp で控えて戻す)。控えは repo と tool home の外に置く
# (shared/ の中に置くと manifest の検査が落ちる)。
def with_backup(*paths)
  saved = paths.map do |path|
    $backups += 1
    copy = File.join(TMP, "backups", $backups.to_s)
    FileUtils.mkdir_p(File.dirname(copy))
    FileUtils.cp_r(path, copy, preserve: true) if File.exist?(path)
    [path, copy]
  end
  yield
ensure
  saved.each do |path, copy|
    FileUtils.rm_rf(path)
    FileUtils.mv(copy, path) if File.exist?(copy)
  end
end

def write(path, text, mode = nil)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, text)
  File.chmod(mode, path) if mode
end

def manifest(path, name, kind, src, format, targets, approved: nil)
  lines = ["schema_version: 1", "name: #{name}", "kind: #{kind}", "visibility: public", "targets:"]
  targets.each { |t| lines << "  - #{t}" }
  lines += ["risk:", "  prompt_injection: low", "  privacy: low"]
  if approved
    lines += ["review:", "  human_review: approved", "  approved_build_id: #{Build.build_id_for(REPO, src, format)}",
              "  approved_artifact_kind: #{approved}"]
  end
  lines += ["source:", "  path: #{src}", "  format: #{format}", "summary: demo #{name}"]
  write(path, lines.join("\n") + "\n")
end

def skill_md(name, body)
  "---\nname: #{name}\ndescription: demo #{name}\n---\n\n#{body}\n"
end

# --- fixture ---
[CODEX, CLAUDE, OPENCODE, AGENTS, XDG].each { |dir| FileUtils.mkdir_p(dir) }
FileUtils.mkdir_p(TEMP, mode: 0o700)
write(File.join(REPO, "shared/skills/personal-single.md"), skill_md("personal-single", "single body"))
manifest(File.join(REPO, "shared/skills/personal-single.asset.yml"), "personal-single", "skill",
         "shared/skills/personal-single.md", "markdown", %w[codex claude-code])
write(File.join(REPO, "shared/skills/personal-dir/SKILL.md"), skill_md("personal-dir", "dir body"))
write(File.join(REPO, "shared/skills/personal-dir/refs/guide.md"), "guide\n")
write(File.join(REPO, "shared/skills/personal-dir/evals/case.txt"), "not deployed\n")
manifest(File.join(REPO, "shared/skills/personal-dir/asset.yml"), "personal-dir", "skill",
         "shared/skills/personal-dir", "directory", %w[codex claude-code])
write(File.join(REPO, "shared/scripts/personal-tool.rb"), "#!/usr/bin/env ruby\nputs 'tool'\n")
manifest(File.join(REPO, "shared/scripts/personal-tool.asset.yml"), "personal-tool", "script",
         "shared/scripts/personal-tool.rb", "text", %w[codex claude-code], approved: "script")
write(File.join(REPO, "shared/plugins/personal-plug.js"), "export const Plug = async () => ({});\n")
manifest(File.join(REPO, "shared/plugins/personal-plug.asset.yml"), "personal-plug", "plugin",
         "shared/plugins/personal-plug.js", "text", %w[opencode], approved: "plugin")
write(File.join(REPO, "shared/instructions/personal-ops.md"), "# ops\n\n## rules\n\n- one\n")
manifest(File.join(REPO, "shared/instructions/personal-ops.asset.yml"), "personal-ops", "instruction",
         "shared/instructions/personal-ops.md", "markdown", %w[codex claude-code])
setup_apply("fixture setup")

single = File.join(CODEX, "skills/personal-single/SKILL.md")
dir = File.join(CODEX, "skills/personal-dir")
guide = File.join(dir, "refs/guide.md")
tool = File.join(CODEX, "agent-tools/scripts/personal-tool")
sidecar = "#{tool}.agent-tools-managed.yml"
plug = File.join(OPENCODE, "plugins/personal-plug.js")
agents_md = File.join(CODEX, "AGENTS.md")

# --- M1〜M4・I1: 正しく配備した target は、すべて一致。evals は配らないので、無いことをずれに数えない (M2) ---
out, rc = doctor("baseline")
check(rc.zero? && out.include?("doctor: ok"), "baseline should pass: #{out}")
expect_all_match("baseline", out)
check(!File.exist?(File.join(dir, "evals")), "fixture: evals is not deployed")
status_before = run!("status", File.join(SCRIPTS, "status.sh"), "--json", "--root", REPO, *HOMES)
sync_before = run!("sync dry-run", File.join(SCRIPTS, "sync.sh"), "--root", REPO, *HOMES)

# --- R1: doctor は repo・generated/・tool home を変えない (inode・mode・時刻・byte) ---
before = snapshot
doctor("read-only")
check(snapshot == before, "doctor must not change the repo or the tool homes")

# --- R1: 書けないようにした repo と tool home でも、判定は変わらない ---
roots = [REPO, CODEX, CLAUDE, OPENCODE, AGENTS]
begin
  roots.each { |root| system("chmod", "-R", "a-w", root) || fail!("chmod a-w") }
  out, rc = doctor("read-only homes")
  check(rc.zero?, "read-only homes should pass: #{out}")
  expect_all_match("read-only homes", out)
ensure
  roots.each { |root| system("chmod", "-R", "u+w", root) }
end

# --- umask: 配備と doctor の umask が違っても、正しい配備は一致 (比べるのは所有者の実行 bit だけ) ---
out, = doctor("umask 077", umask: 0o077)
expect_all_match("umask 077", out)
out, = doctor("umask 000", umask: 0o000)
expect_all_match("umask 000", out)

# --- D1・N1・N2・N4: marker を変えずに SKILL.md を 1 byte 変える ---
with_backup(single) do
  File.binwrite(single, File.binread(single).sub("single body", "single bodY"))
  out, rc = doctor("D1")
  expect_differs("D1", out, "codex", "personal-single", "SKILL.md: content")
  expect_all_match("D1", out, except: [%w[codex personal-single]])
  check(rc.zero? && out.include?("doctor: ok"), "D1: a body difference alone keeps exit 0: #{out}")
  check(run!("status", File.join(SCRIPTS, "status.sh"), "--json", "--root", REPO, *HOMES) == status_before,
        "N1: status --json must not change for a body difference")
  check(run!("sync dry-run", File.join(SCRIPTS, "sync.sh"), "--root", REPO, *HOMES) == sync_before,
        "N2: the sync plan must not change for a body difference")
end

# --- D2: directory の skill の入れ子の file ---
with_backup(guide) do
  File.binwrite(guide, "guidE\n")
  out, = doctor("D2")
  expect_differs("D2", out, "codex", "personal-dir", "refs/guide.md: content")
end

# --- D3・D4・D5: script の本体、実行 bit、sidecar ---
with_backup(tool, sidecar) do
  File.binwrite(tool, File.binread(tool).sub("tool", "tooL"))
  out, = doctor("D3")
  expect_differs("D3", out, "codex", "personal-tool", "personal-tool: content")
end
with_backup(tool) do
  File.chmod(0o644, tool)
  out, = doctor("D4")
  expect_differs("D4", out, "codex", "personal-tool", "personal-tool: exec bit")
end
with_backup(sidecar) do
  File.binwrite(sidecar, File.binread(sidecar).sub("source: shared/scripts/personal-tool.rb", "source: shared/scripts/other.rb"))
  out, = doctor("D5")
  check(target_line(out, "codex", "personal-tool").include?("managed"), "D5 fixture: still managed: #{out}")
  expect_differs("D5", out, "codex", "personal-tool", "personal-tool.agent-tools-managed.yml: content")
end

# --- D6・D7: plugin の本文と実行 bit ---
with_backup(plug) do
  File.binwrite(plug, File.binread(plug).sub("Plug", "PluG"))
  out, = doctor("D6")
  expect_differs("D6", out, "opencode", "personal-plug", "personal-plug.js: content")
end
with_backup(plug) do
  File.chmod(0o755, plug)
  out, = doctor("D7")
  expect_differs("D7", out, "opencode", "personal-plug", "personal-plug.js: exec bit")
end

# --- D8〜D12: file を消す、余分な file と directory、種類の置き換え ---
with_backup(dir) do
  File.unlink(File.join(dir, "SKILL.md"))
  out, = doctor("D8")
  expect_differs("D8", out, "codex", "personal-dir", "SKILL.md: missing")
end
with_backup(dir) do
  write(File.join(dir, ".DS_Store"), "x")
  out, = doctor("D9")
  expect_differs("D9", out, "codex", "personal-dir", ".DS_Store: extra")
end
with_backup(dir) do
  FileUtils.mkdir(File.join(dir, "extra-dir"))
  out, = doctor("D10")
  expect_differs("D10", out, "codex", "personal-dir", "extra-dir: extra")
end
with_backup(dir) do
  write(File.join(dir, "line\nbreak"), "x")
  out, = doctor("display")
  expect_differs("display", out, "codex", "personal-dir", "\"line\\nbreak\": extra")
end
with_backup(dir) do
  File.unlink(guide)
  FileUtils.mkdir(guide)
  out, = doctor("D11")
  expect_differs("D11", out, "codex", "personal-dir", "refs/guide.md: type")
end
with_backup(dir) do
  copy = File.join(TMP, "guide-copy.md")
  FileUtils.cp(guide, copy)
  File.unlink(guide)
  File.symlink(copy, guide)
  out, = doctor("D12")
  expect_differs("D12", out, "codex", "personal-dir", "refs/guide.md: type")
end
# symlink の行き先の文字列も比べる (D12 の続き)。source に symlink を置く形は fixture で作りにくいので部品で見る。
check(BodyCheck.diff({ "a" => [:link, "x"] }, { "a" => [:link, "y"] }).detail == "a: link target",
      "D12: a retargeted symlink differs")
check(BodyCheck.diff({ "a" => [:link, "x"] }, { "a" => [:link, "x"] }).state == :match, "D12: the same symlink matches")

# --- U1: 配備の後に source を変えた (build の前) は未検査。古い配備を新しい source と比べてずれとしない ---
src_single = File.join(REPO, "shared/skills/personal-single.md")
sources = %w[skills/personal-single.md skills/personal-dir/refs/guide.md scripts/personal-tool.rb plugins/personal-plug.js
             instructions/personal-ops.md].map { |rel| File.join(REPO, "shared", rel) }
with_backup(*sources) do
  sources.each { |path| File.binwrite(path, File.binread(path) + "\n// changed\n") }
  out, rc = doctor("U1")
  TARGETS.each { |t, n| expect_unverified("U1", out, t, n, BodyCheck::SOURCE_CHANGED) }
  check(rc.zero?, "U1: unverified alone keeps exit 0: #{out}")
end

# --- U4: 配備先の file を読めない ---
begin
  File.chmod(0o000, guide)
  out, = doctor("U4")
  expect_unverified("U4", out, "codex", "personal-dir", "could not read (Errno::EACCES)")
ensure
  File.chmod(0o644, guide)
end

# --- U3・V2: script の本体を消し、sidecar を残す。missing に body の判定は付けず、sync で置き直る ---
with_backup(tool) do
  File.unlink(tool)
  out, = doctor("U3")
  check(target_line(out, "codex", "personal-tool") == "info: target: [codex] personal-tool missing", "U3: #{out}")
  sync_apply("V2")
  out, = doctor("V2")
  expect_match("V2", out, "codex", "personal-tool")
end

# --- I2・I6: local の断片は正当な違い。所有 file の実行 bit は比べない ---
write(FRAGMENT, "- local rule\n")
sync_apply("I2")
out, = doctor("I2")
expect_all_match("I2", out)
File.chmod(0o755, agents_md)
out, = doctor("I6")
expect_match("I6", out, "codex", "personal-ops")
File.chmod(0o644, agents_md)

# --- I5: instruction の所有 file の body は、今までどおり stale (body の判定は付けない) ---
with_backup(agents_md) do
  File.binwrite(agents_md, File.binread(agents_md).sub("- one", "- onE"))
  out, = doctor("I5")
  check(target_line(out, "codex", "personal-ops") == "warn: target: [codex] personal-ops stale", "I5: #{out}")
end

# --- I3: 断片を変えると instruction は stale ---
write(FRAGMENT, "- other rule\n")
out, = doctor("I3")
check(target_line(out, "claude-code", "personal-ops") == "warn: target: [claude-code] personal-ops stale", "I3: #{out}")
File.unlink(FRAGMENT)
sync_apply("I3 restore")

# --- D15・V1・V4: generated/ を変えてから配備した形。doctor は generated/ を作り直さず、回復は setup ---
gen_single = File.join(REPO, "generated/codex/skills/personal-single/SKILL.md")
File.binwrite(gen_single, File.binread(gen_single).sub("single body", "tampered body"))
FileUtils.rm_rf(File.join(CODEX, "skills/personal-single"))
sync_apply("D15 deploy")
out, = doctor("D15")
expect_differs("D15", out, "codex", "personal-single", "SKILL.md: content")
check(File.binread(gen_single).include?("tampered body"), "D15: doctor must not rebuild generated/")
setup_apply("V1 setup without removal")
out, = doctor("V1 before removal")
expect_differs("V1", out, "codex", "personal-single", "SKILL.md: content")
FileUtils.rm_rf(File.join(CODEX, "skills/personal-single"))
setup_apply("V1")
out, = doctor("V1")
expect_match("V1", out, "codex", "personal-single")

gen_agents = File.join(REPO, "generated/codex/instructions/AGENTS.md")
File.binwrite(gen_agents, File.binread(gen_agents).sub("- one", "- tampered"))
sync_apply("V4 deploy")
out, = doctor("V4 tampered")
expect_differs("V4", out, "codex", "personal-ops", "AGENTS.md: content")
setup_apply("V4")
out, = doctor("V4")
expect_match("V4", out, "codex", "personal-ops")

# --- V3: plugin は file を消して setup ---
File.binwrite(plug, File.binread(plug).sub("Plug", "PluG"))
out, = doctor("V3 before")
expect_differs("V3", out, "opencode", "personal-plug", "personal-plug.js: content")
File.unlink(plug)
setup_apply("V3")
out, = doctor("V3")
expect_match("V3", out, "opencode", "personal-plug")

# --- D13: manifest の source.path だけを変える。build_id は同じで、marker の source だけが違うのでずれ ---
FileUtils.mkdir_p(File.join(REPO, "shared/workflows"))
FileUtils.mv(src_single, File.join(REPO, "shared/workflows/personal-single.md"))
FileUtils.mv(File.join(REPO, "shared/skills/personal-single.asset.yml"), File.join(REPO, "shared/workflows/personal-single.asset.yml"))
yml = File.join(REPO, "shared/workflows/personal-single.asset.yml")
File.write(yml, File.read(yml).sub("shared/skills/personal-single.md", "shared/workflows/personal-single.md"))
setup_apply("D13")
out, = doctor("D13")
expect_differs("D13", out, "codex", "personal-single", ".agent-tools-managed.yml: content")
FileUtils.rm_rf(File.join(CODEX, "skills/personal-single"))
setup_apply("D13 recovery")
out, = doctor("D13 recovery")
expect_match("D13 recovery", out, "codex", "personal-single")

# --- U2: source を変えて build と register をした (配備の前) は stale。body の判定は付けない ---
moved = File.join(REPO, "shared/workflows/personal-single.md")
File.binwrite(moved, skill_md("personal-single", "new body"))
build_register("U2")
out, = doctor("U2")
check(target_line(out, "codex", "personal-single") == "warn: target: [codex] personal-single stale", "U2: #{out}")
setup_apply("U2 restore")

# --- R2・R3: TMPDIR が書けない、repo の内側を指すときは、そこに書かず別の置き場で検査する ---
begin
  File.chmod(0o500, TEMP)
  out, = doctor("R2")
  expect_all_match("R2", out)
ensure
  File.chmod(0o700, TEMP)
end
inner = File.join(REPO, "inner-tmp")
FileUtils.mkdir_p(inner, mode: 0o700)
# 作って消すと、空に戻っても inner-tmp の時刻が変わる。前後の snapshot (repo の中の entry の時刻を含む) で見る。
File.utime(Time.at(0), Time.at(0), inner)
before = snapshot
out, = doctor("R3", extra_env: { "TMPDIR" => inner })
expect_all_match("R3", out)
check(snapshot == before, "R3: doctor must not create its temporary directory under the repo")
FileUtils.rmdir(inner)

# --- R3 の続き: 置き場がどこにも無ければ、何も書かずに未検査 ---
check(BodyCheck.temp_base(["/"], { "TMPDIR" => TEMP }).nil?, "R3: no base outside the avoided directories")
plans = [Struct.new(:tool, :name, :kind, :target).new("codex", "personal-single", "skill", "x")]
results, leftover = BodyCheck.run(REPO, plans, avoid: ["/"], fragment: nil, env: { "TMPDIR" => TEMP })
check(results.map(&:to_a) == [[:unverified, "no usable temporary directory"]] && !leftover, "R3: #{results.inspect}")
check(BodyCheck.temp_base([REPO], { "TMPDIR" => File.join(REPO, "shared") }) != File.join(REPO, "shared"),
      "R3: a TMPDIR inside the repo is skipped")

# --- U5: 作り直しが途中で失敗すると、managed の target をすべて未検査にし (ほかを一致と言わない)、一時 directory を
# 消す。source を読めなくする fixture では status の検査が先に止まるので、作り直しの部品を失敗させて見る ---
sync_plans = Sync::Runner.new(REPO, { "codex" => CODEX, "claude-code" => CLAUDE, "opencode" => OPENCODE })
                         .plan.select { |p| p.code == :up_to_date }
check(sync_plans.size == TARGETS.size, "U5 fixture: all targets are up-to-date: #{sync_plans.map(&:name)}")
Build::Runner.class_eval do
  alias_method :run_without_failure, :run
  define_method(:run) do
    singleton_class.send(:define_method, :build_skill) { |*| raise Errno::EACCES, "boom" }
    run_without_failure
  end
end
results, leftover = BodyCheck.run(REPO, sync_plans, avoid: [REPO, CODEX, CLAUDE, OPENCODE, AGENTS], fragment: nil,
                                                    env: { "TMPDIR" => TEMP })
check(results.map(&:to_a).uniq == [[:unverified, "could not rebuild (Errno::EACCES)"]], "U5: #{results.inspect}")
check(!leftover && Dir.children(TEMP).empty?, "U5: the temporary directory is removed after a failed rebuild")
Build::Runner.class_eval do
  alias_method :run, :run_without_failure
end

# --- D12 の続き: symlink の行き先を、辿らずに読んで比べる (木の読み取りの部品を実物の file system で見る) ---
links = File.join(TMP, "links")
%w[a b].each { |side| FileUtils.mkdir_p(File.join(links, side)) }
File.symlink("x.md", File.join(links, "a", "l"))
File.symlink("y.md", File.join(links, "b", "l"))
check(BodyCheck.diff(BodyCheck.tree(File.join(links, "a")), BodyCheck.tree(File.join(links, "b"))).detail == "l: link target",
      "D12: a retargeted symlink in the tree differs")

# --- 一時 directory を消しきれなかったら、doctor は path を出さずに warn を 1 行出す ---
require File.join(SCRIPTS, "lib", "doctor")
homes = { "codex" => CODEX, "claude-code" => CLAUDE, "opencode" => OPENCODE }
ENV["TMPDIR"] = TEMP
FileUtils.singleton_class.class_eval do
  alias_method :rm_rf_for_real, :rm_rf
  define_method(:rm_rf) { |path, **opts| File.basename(path.to_s).start_with?("agent-tools-doctor-") ? nil : rm_rf_for_real(path, **opts) }
end
lines = Doctor::Runner.new(REPO, homes, AGENTS, xdg_opencode_mismatch: false).run.map(&:to_s)
FileUtils.singleton_class.class_eval { alias_method :rm_rf, :rm_rf_for_real }
check(lines.count("warn: body: could not remove the temporary directory of the fresh build") == 1,
      "the leftover temporary directory is reported once: #{lines}")
check(lines.none? { |line| line.include?(TMP) }, "the leftover report has no path: #{lines}")
Dir.children(TEMP).each { |child| FileUtils.rm_rf(File.join(TEMP, child)) }

puts "ok: doctor-body-test (#{$checks} checks)"
