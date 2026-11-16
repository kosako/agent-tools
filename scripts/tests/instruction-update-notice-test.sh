#!/bin/sh
# personal-instruction-update-notice.rb の self-test (#688)。節の分け方 (Sections) は require して直接、hook は一時 directory の
# 配備先の形 (<claude home>/agent-tools/scripts/ と、その隣の CLAUDE.md) に写して起動し、stdin の JSON と stdout・exit code・
# 記録の file を確かめる。network access なし。書くのは一時 directory の中だけ。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-instruction-update-notice.rb"

[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

# 親の環境の記録の場所を継承しない (継承すると、test が実際の記録を読み書きする)。
unset AGENT_TOOLS_INSTRUCTION_NOTICE_DIR

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" -rjson -ropen3 -rfileutils -rrbconfig - "$src" "$repo_root" "$tmp" <<'RUBY'
src, repo_root, tmp = ARGV
require src
require File.join(repo_root, "scripts", "lib", "local_instructions")

S = InstructionUpdateNotice::Sections
MARKER = "<!-- agent-tools:managed v=1 repo=agent-tools name=personal-operating-rules target=claude-code " \
         "artifact_kind=instruction source=shared/instructions/personal-operating-rules.md " \
         "build_id=sha256:#{"0" * 64} -->"
names = ->(text) { S.digests(text).map(&:first) }
digest_of = ->(text, name) { S.digests(text).to_h.fetch(name) }

# ---- 節の分け方 ----
base = "#{MARKER}\n# 運用ルール\n\n前書き\n\n## 言語\n\n- 日本語\n\n### 細目\n\n- 細かい話\n\n## public safety\n\n- secret を入れない\n"
check("# と ## の見出しで区切り、### は上の節の中身にする", names.call(base) == ["運用ルール", "言語", "public safety"])
check("marker の行だけが違っても、節の hash は同じ",
      S.digests(base) == S.digests(base.sub("build_id=sha256:#{"0" * 64}", "build_id=sha256:#{"1" * 64}")))
check("marker の行が無くても、同じ節に分ける", S.digests(base.sub("#{MARKER}\n", "")) == S.digests(base))
check("### の下の中身が変わると、上の節の hash が変わる",
      digest_of.call(base, "言語") != digest_of.call(base.sub("細かい話", "別の話"), "言語"))
check("ほかの節の hash は変わらない",
      digest_of.call(base, "public safety") == digest_of.call(base.sub("細かい話", "別の話"), "public safety"))
check("節の前後の空行の数は比べない",
      S.digests(base) == S.digests(base.sub("## 言語\n\n- 日本語", "## 言語\n\n\n\n- 日本語").sub("入れない\n", "入れない\n\n\n")))
check("見出しの前後の空白を除いた text が節の名前", names.call("##   言語  \n本文\n") == ["言語"])
check("# の後に空白が無い行は見出しにしない", names.call("## 言語\n#タグ\n##\n本文\n") == ["言語"])

fenced = "## 手順\n\n```sh\n# comment\n## not a heading\n```\n\n## 次\n\n本文\n"
check("``` の fence の中の # の行は見出しにしない", names.call(fenced) == %w[手順 次])
check("~~~ の fence の中の ``` の行では閉じない",
      names.call("## a\n~~~\n```\n## x\n~~~\n## b\n") == %w[a b])
check("短い記号の行では長い fence を閉じない",
      names.call("## a\n````\n```\n## x\n````\n## b\n") == %w[a b])
check("字下げした fence も fence として読む", names.call("## a\n   ```\n## x\n   ```\n## b\n") == %w[a b])
check("行の頭の ```x``` は fence でなく inline code", names.call("## a\n```x```\n## b\n") == %w[a b])
check("閉じていない fence は末尾まで", names.call("## a\n```\n## x\n## y\n") == %w[a])

check("最初の見出しより前に行があれば (preamble) の節", names.call("#{MARKER}\n前置き\n\n## 言語\n本文\n") == ["(preamble)", "言語"])
check("最初の見出しより前が空行だけなら (preamble) を作らない", names.call("#{MARKER}\n\n\n## 言語\n本文\n") == ["言語"])
merged = "## 言語\nA\n## 別\nB\n## 言語\nC\n"
check("同じ名前の節は 1 つにまとめる", names.call(merged) == %w[言語 別])
check("同じ名前の節の後ろの中身が変わると、その節の hash が変わる",
      digest_of.call(merged, "言語") != digest_of.call(merged.sub("C\n", "D\n"), "言語"))
check("同じ名前の節の前の中身が変わっても、その節の hash が変わる",
      digest_of.call(merged, "言語") != digest_of.call(merged.sub("A\n", "Z\n"), "言語"))

local = "#{base}\n#{S::LOCAL_HEADING}\n\n## 秘密の見出し\n\n- 手元だけの決まり\n\n# もう 1 つの見出し\n\n本文\n"
check("local の断片は 1 つの節で、中の見出しを区切りにしない",
      names.call(local) == ["運用ルール", "言語", "public safety", "local instructions"])
check("local の断片の中身が変わると、local instructions の hash が変わる",
      digest_of.call(local, "local instructions") != digest_of.call(local.sub("手元だけの決まり", "別の決まり"), "local instructions"))
check("local の断片の見出しは、fence の中にあっても区切りにする",
      names.call("## a\n```\n#{S::LOCAL_HEADING}\n## 秘密\n") == ["a", "local instructions"])
check("local の断片の見出しの写しは、sync が足す見出しと同じ", S::LOCAL_HEADING == LocalInstructions::HEADING)

# ---- 2 つの版の違い ----
old = [%w[a 1], %w[b 2], %w[c 3], %w[d 4]]
new = [%w[e 9], %w[a 1], %w[c 8], %w[b 7]]
check("中身が違う節・足された節は新しい版の順、消えた節は最後",
      S.diff(old, new) == [["e", :added], ["c", :changed], ["b", :changed], ["d", :removed]])
check("同じなら空", S.diff(old, old) == [])
check("順だけが違うなら空", S.diff(old, old.reverse) == [])
many = (1..12).map { |i| ["s#{i}", :changed] }
check("並べるのは 10 個までで、残りは数", S.listed(many) == [many.first(10), 2])
check("10 個ちょうどなら残りは 0", S.listed(many.first(10)) == [many.first(10), 0])
check("節の名前は 80 字で切る", S.display_name("あ" * 81) == "あ" * 80)
check("節の名前の制御文字は空白にする", S.display_name("a\e[31mb\tc") == "a [31mb c")

# ---- hook ----
HOOK_NAME = "personal-instruction-update-notice"
@seq = 0
# 配備先の形の一時 directory を作り、hook の写しと instruction を置く。
def deploy(tmp, src, instruction)
  @seq += 1
  home = File.join(tmp, "case#{@seq}")
  scripts = File.join(home, "claude", "agent-tools", "scripts")
  FileUtils.mkdir_p(scripts)
  hook = File.join(scripts, HOOK_NAME)
  FileUtils.cp(src, hook)
  File.chmod(0o755, hook)
  target = File.join(home, "claude", "agent-tools", "CLAUDE.md")
  File.write(target, instruction) unless instruction.nil?
  { home: home, hook: hook, instruction: target, state: File.join(home, "state") }
end

def call(env_dir, payload, extra_env = {}, hook: nil)
  env = { "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR" => env_dir[:state], "XDG_STATE_HOME" => nil,
          "HOME" => env_dir[:home] }.merge(extra_env)
  input = payload.is_a?(String) ? payload : JSON.generate(payload)
  # cwd は一時 directory の中にする (相対の場所を受ける退行があっても、repo の中に書かせない)。
  Open3.capture3(env, RbConfig.ruby, hook || env_dir[:hook], stdin_data: input, chdir: env_dir[:home])
end

def start(session = "s1")
  { "hook_event_name" => "SessionStart", "session_id" => session, "source" => "startup" }
end

def prompt(session = "s1")
  { "hook_event_name" => "UserPromptSubmit", "session_id" => session, "prompt" => "続けて" }
end

def state_of(env_dir, session = "s1")
  file = File.join(env_dir[:state], "#{session}.json")
  File.exist?(file) ? File.read(file) : nil
end

d = deploy(tmp, src, base)
out, err, st = call(d, start)
check("SessionStart は何も出さず exit 0", out.empty? && err.empty? && st.exitstatus == 0)
recorded = JSON.parse(state_of(d))
check("SessionStart で節ごとの hash を記録する",
      recorded["v"] == 1 && recorded["sections"] == S.digests(base) && recorded["recorded_at"].is_a?(String))
check("記録に本文を書かない", !state_of(d).include?("secret を入れない"))
check("記録の directory は 0700、file は 0600",
      (File.stat(d[:state]).mode & 0o777) == 0o700 && (File.stat(File.join(d[:state], "s1.json")).mode & 0o777) == 0o600)
check("一時 file を残さない", Dir.children(d[:state]) == ["s1.json"])

before = state_of(d)
out, err, st = call(d, prompt)
check("記録と同じなら何も出さず、記録も変えない", out.empty? && err.empty? && st.exitstatus == 0 && state_of(d) == before)

File.write(d[:instruction], base.sub("build_id=sha256:#{"0" * 64}", "build_id=sha256:#{"1" * 64}"))
out, _err, st = call(d, prompt)
check("marker の行だけが違うときは何も出さない", out.empty? && st.exitstatus == 0 && state_of(d) == before)

changed = base.sub("- 日本語", "- 日本語を既定にする").sub("## public safety\n\n- secret を入れない\n", "## 新しい節\n\n- 追加\n")
File.write(d[:instruction], changed)
out, err, st = call(d, prompt)
notice = JSON.parse(out)
expected_names = "「言語」、「新しい節」(追加)、「public safety」(削除)"
expected_context = [
  "運用 instruction の file が、この session が読み込んだ後に配備で更新されています。",
  "file: #{File.realpath(d[:instruction])}",
  "変わった節: #{expected_names}",
  "この session の context にある運用 instruction は、更新の前の版のことがあります。" \
    "作業を続ける前にこの file を読み、違うところは file の版に従ってください。",
].join("\n")
check("違えば JSON を 1 行だけ出して exit 0", out.lines.size == 1 && err.empty? && st.exitstatus == 0)
check("additionalContext は 4 行で、file の場所と変わった節を含む",
      notice["hookSpecificOutput"] == { "hookEventName" => "UserPromptSubmit", "additionalContext" => expected_context })
check("systemMessage は人に見える 1 行",
      notice["systemMessage"] == "運用 instruction が更新されています (変わった節: #{expected_names})。この session に読み直しを促しました。")
check("出力の key は 2 つだけ", notice.keys.sort == %w[hookSpecificOutput systemMessage])
check("促した後は、記録が今の内容になる", JSON.parse(state_of(d))["sections"] == S.digests(changed))
out, _err, st = call(d, prompt)
check("同じ更新では 2 回促さない", out.empty? && st.exitstatus == 0)

out, _err, st = call(d, prompt("s2"))
check("記録の無い session の最初の入力は、記録して何も出さない",
      out.empty? && st.exitstatus == 0 && JSON.parse(state_of(d, "s2"))["sections"] == S.digests(changed))
check("session ごとに別の記録", state_of(d, "s1") != nil && Dir.children(d[:state]).sort == %w[s1.json s2.json])

# compaction の後 (SessionStart の source が compact) は、その時点の内容で記録し直す。
File.write(d[:instruction], base)
out, _err, st = call(d, start.merge("source" => "compact"))
check("SessionStart は source を問わず記録し直す",
      out.empty? && st.exitstatus == 0 && JSON.parse(state_of(d))["sections"] == S.digests(base))
out, _err, _st = call(d, prompt)
check("記録し直した後の入力では促さない", out.empty?)

# 節が 10 個を超える
d = deploy(tmp, src, MARKER + "\n" + (1..12).map { |i| "## 節#{i}\n\n本文 #{i}\n" }.join("\n"))
call(d, start)
File.write(d[:instruction], MARKER + "\n" + (1..12).map { |i| "## 節#{i}\n\n新しい本文 #{i}\n" }.join("\n"))
out, _err, _st = call(d, prompt)
notice = JSON.parse(out)
listed = (1..10).map { |i| "「節#{i}」" }.join("、") + "、ほか 2 個"
check("10 個を超える節は数だけを出す (additionalContext)",
      notice["hookSpecificOutput"]["additionalContext"].lines[2].chomp == "変わった節: #{listed}")
check("10 個を超える節は数だけを出す (systemMessage)", notice["systemMessage"].include?("(変わった節: #{listed})"))

# local の断片の中の見出しを出さない
d = deploy(tmp, src, local)
call(d, start)
File.write(d[:instruction], local.sub("手元だけの決まり", "別の決まり").sub("## 秘密の見出し", "## 別の秘密の見出し"))
out, _err, _st = call(d, prompt)
check("local の断片の変化は local instructions とだけ出す",
      JSON.parse(out)["hookSpecificOutput"]["additionalContext"].lines[2].chomp == "変わった節: 「local instructions」")
check("local の断片の見出しと中身を出力に出さない", !out.include?("秘密") && !out.include?("決まり"))
check("local の断片の見出しを記録に書かない", !state_of(d).include?("秘密"))

# ---- 何も出さず、記録も変えない入力 ----
d = deploy(tmp, src, base)
call(d, start)
before = state_of(d)
File.write(d[:instruction], changed)
silent = lambda do |label, payload, session = "s1"|
  out, _err, st = call(d, payload)
  check("#{label}: 何も出さず exit 0", out.empty? && st.exitstatus == 0)
  check("#{label}: 記録を変えない", state_of(d, session) == (session == "s1" ? before : nil))
end
silent.call("JSON でない入力", "not json")
silent.call("JSON の配列", "[1, 2]")
silent.call("空の入力", "")
silent.call("1 MiB を超える入力", JSON.generate(prompt.merge("prompt" => "a" * (1024 * 1024))))
silent.call("1 MiB を超える入力 (後ろが空白で、切っても JSON として読める)", JSON.generate(prompt) + (" " * (1024 * 1024)))
silent.call("ほかの event", prompt.merge("hook_event_name" => "Stop"))
silent.call("hook_event_name が無い", { "session_id" => "s1" })
silent.call("session_id が無い", { "hook_event_name" => "UserPromptSubmit" })
silent.call("session_id が文字列でない", prompt.merge("session_id" => 1))
silent.call("session_id が空", prompt.merge("session_id" => ""))
silent.call("session_id が 128 字を超える", prompt.merge("session_id" => "a" * 129), "a" * 129)
check("session_id の形が外れるとき、記録の directory の外に書かない",
      begin
        call(d, start.merge("session_id" => "../escape"))
        call(d, start.merge("session_id" => "a/b"))
        call(d, start.merge("session_id" => "a.b"))
        Dir.children(d[:state]) == ["s1.json"] && !File.exist?(File.join(d[:home], "escape.json"))
      end)
out, _err, _st = call(d, prompt)
check("形の正しい入力なら、同じ状態から促す (上の入力が黙っていたのは形のため)", !out.empty?)

# ---- 見る file が条件を満たさない ----
unwatched = lambda do |label, &setup|
  dd = deploy(tmp, src, nil)
  setup.call(dd)
  out1, err1, st1 = call(dd, start)
  out2, err2, st2 = call(dd, prompt)
  check("#{label}: stdout にも stderr にも何も出さず exit 0",
        [out1, out2, err1, err2].all?(&:empty?) && st1.exitstatus == 0 && st2.exitstatus == 0)
  check("#{label}: 記録を作らない", !File.exist?(File.join(dd[:state], "s1.json")))
end
unwatched.call("file が無い") { |_dd| nil }
unwatched.call("directory") { |dd| Dir.mkdir(dd[:instruction]) }
unwatched.call("symlink") do |dd|
  real = File.join(dd[:home], "real.md")
  File.write(real, base)
  File.symlink(real, dd[:instruction])
end
unwatched.call("256 KiB を超える") { |dd| File.write(dd[:instruction], base + ("あ" * (256 * 1024))) }
unwatched.call("UTF-8 でない") { |dd| File.binwrite(dd[:instruction], base.b + "\xFF\xFE\n".b) }
unwatched.call("marker の行が無い") { |dd| File.write(dd[:instruction], base.sub("#{MARKER}\n", "")) }
unwatched.call("marker が先頭の行でない") { |dd| File.write(dd[:instruction], "\n" + base) }
unwatched.call("instruction でない marker") do |dd|
  File.write(dd[:instruction], base.sub("artifact_kind=instruction", "artifact_kind=skill"))
end
unwatched.call("閉じていない marker") { |dd| File.write(dd[:instruction], base.sub(" -->", "")) }

# 256 KiB ちょうどは読む (上限の境界)
d = deploy(tmp, src, nil)
File.binwrite(d[:instruction], base.b + ("a" * (256 * 1024 - base.bytesize)))
call(d, start)
check("256 KiB ちょうどの file は読む", File.size(d[:instruction]) == 256 * 1024 && !state_of(d).nil?)

# ---- 記録の場所 ----
d = deploy(tmp, src, base)
_out, _err, st = call(d, start, { "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR" => nil, "XDG_STATE_HOME" => File.join(d[:home], "xdg") })
check("env が無ければ XDG_STATE_HOME の下に記録する",
      st.exitstatus == 0 && File.exist?(File.join(d[:home], "xdg", "agent-tools", HOOK_NAME, "s1.json")))
_out, _err, st = call(d, start, { "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR" => nil })
check("XDG_STATE_HOME も無ければ HOME の .local/state の下に記録する",
      st.exitstatus == 0 && File.exist?(File.join(d[:home], ".local", "state", "agent-tools", HOOK_NAME, "s1.json")))
out, err, st = call(d, start, { "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR" => "relative/dir" })
check("相対の場所は使わず、stderr に 1 行だけ出して exit 0",
      out.empty? && err.lines.size == 1 && err.start_with?("#{HOOK_NAME}: ") && st.exitstatus == 0 &&
      !File.exist?(File.join(d[:home], "relative")))
out, err, st = call(d, start, { "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR" => nil, "HOME" => nil })
check("場所を決められなければ、stderr に 1 行だけ出して exit 0", out.empty? && err.lines.size == 1 && st.exitstatus == 0)

# ---- 記録が壊れている・書けない ----
d = deploy(tmp, src, base)
FileUtils.mkdir_p(d[:state])
File.write(File.join(d[:state], "s1.json"), "{broken")
out, _err, st = call(d, prompt)
check("壊れた記録は、記録が無いときと同じ (何も出さずに記録し直す)",
      out.empty? && st.exitstatus == 0 && JSON.parse(state_of(d))["sections"] == S.digests(base))
[
  ["版の違う記録", JSON.generate("v" => 2, "sections" => [])],
  ["sections が配列でない記録", JSON.generate("v" => 1, "sections" => "x")],
  ["組の形が外れる記録", JSON.generate("v" => 1, "sections" => [["a"]])],
  ["JSON の配列の記録", "[]"],
].each do |label, body|
  File.write(File.join(d[:state], "s1.json"), body)
  out, _err, _st = call(d, prompt)
  check("#{label}は、記録が無いときと同じ", out.empty? && JSON.parse(state_of(d))["sections"] == S.digests(base))
end

outside = File.join(d[:home], "outside.json")
File.write(outside, "keep")
File.unlink(File.join(d[:state], "s1.json"))
File.symlink(outside, File.join(d[:state], "s1.json"))
out, _err, st = call(d, prompt)
check("記録が symlink なら読まず、リンク先を書き換えない",
      out.empty? && st.exitstatus == 0 && File.read(outside) == "keep" && !File.symlink?(File.join(d[:state], "s1.json")))

d = deploy(tmp, src, base)
call(d, start)
File.write(d[:instruction], changed)
File.chmod(0o500, d[:state])
out1, err1, st1 = call(d, prompt)
out2, _err2, st2 = call(d, prompt)
File.chmod(0o700, d[:state])
check("記録を書けなくても促しは出し、exit 0 (stderr に 1 行)",
      !out1.empty? && err1.lines.size == 1 && st1.exitstatus == 0)
check("記録を書けなかったら、次の入力でもう一度促す (見逃しにしない)", out2 == out1 && st2.exitstatus == 0)
check("書けなかった一時 file を残さない", Dir.children(d[:state]) == ["s1.json"])

d = deploy(tmp, src, base)
FileUtils.mkdir_p(File.join(d[:state], "s1.json"))
File.write(File.join(d[:state], "s1.json", "keep"), "x")
out, err, st = call(d, start)
check("記録を入れ替えられなければ、stderr に 1 行だけ出して exit 0", out.empty? && err.lines.size == 1 && st.exitstatus == 0)
check("入れ替えられなかった一時 file を残さない", Dir.children(d[:state]) == ["s1.json"])

d = deploy(tmp, src, base)
File.write(d[:state], "a file, not a directory")
out, err, st = call(d, start)
check("記録の directory を作れなければ、stderr に 1 行だけ出して exit 0",
      out.empty? && err.lines.size == 1 && st.exitstatus == 0)

# ---- 想定外の例外 ----
d = deploy(tmp, src, base)
boom = "module InstructionUpdateNotice; def self.default_instruction_path; raise \"boom\"; end; end; " \
       "exit InstructionUpdateNotice.run"
out, err, st = Open3.capture3({ "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR" => d[:state] }, RbConfig.ruby, "-r", src, "-e", boom,
                              stdin_data: JSON.generate(start))
check("想定外の例外でも、stderr に 1 行だけ出して exit 0",
      out.empty? && err.lines.size == 1 && err.include?("unexpected RuntimeError") && st.exitstatus == 0)

# ---- 古い記録の掃除 ----
d = deploy(tmp, src, base)
FileUtils.mkdir_p(d[:state])
day = 24 * 60 * 60
touch = lambda do |name, age_days|
  file = File.join(d[:state], name)
  File.write(file, "{}")
  File.utime(Time.now - age_days * day, Time.now - age_days * day, file)
  file
end
old_state = touch.call("old-session.json", 31)
fresh_state = touch.call("fresh-session.json", 29)
other_file = touch.call("notes.txt", 31)
dotted = touch.call("a.b.json", 31)
link = File.join(d[:state], "linked.json")
link_target = touch.call("link-target.txt", 31)
File.symlink(link_target, link)
out, _err, st = call(d, prompt)
check("UserPromptSubmit では掃除しない", out.empty? && st.exitstatus == 0 && File.exist?(old_state))
call(d, start)
check("SessionStart で、30 日より古い記録を消す", !File.exist?(old_state))
check("30 日より新しい記録は残す", File.exist?(fresh_state))
check("記録の名前の形でない file と symlink は残す",
      File.exist?(other_file) && File.exist?(dotted) && File.symlink?(link) && File.exist?(link_target))
check("今の session の記録は残る", File.exist?(File.join(d[:state], "s1.json")))

d = deploy(tmp, src, base)
FileUtils.mkdir_p(d[:state])
205.times do |i|
  file = File.join(d[:state], "old#{i}.json")
  File.write(file, "{}")
  File.utime(Time.now - 40 * day, Time.now - 40 * day, file)
end
call(d, start)
check("1 回に消すのは 200 個まで", Dir.children(d[:state]).grep(/\Aold\d+\.json\z/).size == 5)

# ---- symlink からの起動と locale ----
d = deploy(tmp, src, base)
bin = File.join(d[:home], "bin")
Dir.mkdir(bin)
File.write(File.join(d[:home], "CLAUDE.md"), base.sub("- 日本語", "- 別の file"))
File.symlink(d[:hook], File.join(bin, HOOK_NAME))
call(d, start, {}, hook: File.join(bin, HOOK_NAME))
check("symlink から起動しても、実体の隣の file を見る", JSON.parse(state_of(d))["sections"] == S.digests(base))

File.write(d[:instruction], changed)
out, err, st = call(d, prompt, { "LC_ALL" => "C", "LANG" => "C" })
check("C locale でも、日本語の節の名前を出す",
      st.exitstatus == 0 && err.empty? && JSON.parse(out)["systemMessage"].include?("「言語」"))

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: instruction-update-notice-test"
