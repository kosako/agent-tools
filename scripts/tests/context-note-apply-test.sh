#!/bin/sh
# personal-context-note-apply.rb の self-test (#677)。
# 一時 directory に git init で作った repo だけを使い、本物の repo の note には触れない。helper は Ruby の標準の pty で作った
# 端末の上で起動し (人が自分の terminal で実行した形)、子の env からは agent の session の目印と repository を選ぶ git の env を外す。
# 確かめること:
# - 引数の誤り (usage)、agent の session の目印 (4 つ)、端末でない標準入力・標準出力 (no-tty)、git の env の継承 (値が空でも)、
#   git の作業 tree でない・index を読めない (undetermined)、案の file の誤り (input) では書かない。
# - note が symlink (参照先の在る・無い)、directory や FIFO、git で tracked (同じ名前、大文字小文字だけ違う名前、
#   GIT_LITERAL_PATHSPECS の継承) のときは書かない。
# - 案が今の note と同じなら、確認を聞かずに unchanged で終わる。
# - 差分 (---・+++・@@ と変えた行) を答えを聞く前に見せ、y / yes (大文字も) のときだけ 1 回の実行で書く。新しく作る note は
#   0600、今の note は権限を保つ。-C の子 directory と、省いたときの今の directory の子からでも、root の note を書く。
# - n・空の答え・EOF・Ctrl-C では書かない。一時 file を残さない。書けない directory では write-failed で、note は前のまま。
# - 表示で隠れうる文字 (制御文字と書式の文字。NUL、行末の CR、path の中の改行を含む) を <U+XXXX> で見せ、端末へそのまま出さない。
#   書く中身はそのまま。diff が差分の形を出さないときは確認に進まない。root の名前の末尾の CR を外さない。
# - 差分を見せた後に note が変わった・symlink に替わった・tracked になったときは、確かめ直しで止める (直接呼び出し)。
# - locale が C でも書ける。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src=${1:-"$repo_root/shared/scripts/personal-context-note-apply.rb"}
[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" -rfileutils -rpty -ropen3 -rrbconfig -rstringio -rtimeout - "$src" "$tmp" <<'RUBY'
# encoding: UTF-8
src, tmp = ARGV
tmp = File.realpath(tmp)
NOTE = ".agent-context.local.md"
MARKERS = %w[CLAUDECODE CODEX_THREAD_ID CODEX_SANDBOX AGENT_TOOLS_OPENCODE].freeze
GIT_REPO_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].freeze
HOME = File.join(tmp, "home")
Dir.mkdir(HOME)

# この test process の git も、親の git の env と設定を継承しない。
(GIT_REPO_ENV + %w[GIT_LITERAL_PATHSPECS GIT_ICASE_PATHSPECS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT]).each { |k| ENV.delete(k) }
ENV["GIT_CONFIG_GLOBAL"] = "/dev/null"
ENV["GIT_CONFIG_SYSTEM"] = "/dev/null"
ENV["HOME"] = HOME

# helper の子の env。目印と git の env を外し、git の設定を隔離する。
def child_env(extra = {})
  env = {}
  (MARKERS + GIT_REPO_ENV + %w[GIT_LITERAL_PATHSPECS]).each { |k| env[k] = nil }
  env.merge("HOME" => HOME, "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null").merge(extra)
end

def git(dir, *args)
  out, err, st = Open3.capture3("git", "-c", "core.hooksPath=/dev/null", *args, chdir: dir)
  raise "git #{args.inspect} failed: #{err}" unless st.success?

  out
end

@n = 0
def new_repo
  @n += 1
  root = File.join(TMP_ROOT, "repo#{@n}")
  Dir.mkdir(root)
  git(root, "init", "-q")
  root
end
TMP_ROOT = tmp

def proposal(text, name = "proposal-#{@n}.md")
  path = File.join(TMP_ROOT, name)
  File.binwrite(path, text)
  path
end

# 端末の上で helper を起動する。answer があれば、確認 ([y/N]) が出た後に送る。
# 返す値: { out:, code:, prompt:, before: (確認より前の出力) }
def run_tty(args, env: {}, cwd: TMP_ROOT, answer: nil, ruby_args: ["-E", "UTF-8"])
  out = +""
  prompt = false
  code = nil
  PTY.spawn(child_env(env), RbConfig.ruby, *ruby_args, SRC, *args, chdir: cwd) do |r, w, pid|
    begin
      Timeout.timeout(20) do
        loop do
          begin
            out << r.readpartial(4096)
          rescue EOFError, Errno::EIO
            break
          end
          next if prompt || !out.include?("[y/N]")

          prompt = true
          w.write(answer) if answer
        end
        code = Process.wait2(pid)[1]
      end
    rescue Timeout::Error
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
      code = nil
    end
  end
  text = out.force_encoding(Encoding::UTF_8).scrub.gsub("\r\n", "\n")
  idx = text.index("[y/N]")
  { out: text, code: code&.exitstatus, prompt: prompt, before: idx ? text[0, idx] : text }
end

# 標準入力と標準出力を pipe にして起動する。
def run_pipe(args, env: {}, cwd: TMP_ROOT, stdin_data: "")
  out, st = Open3.capture2e(child_env(env), RbConfig.ruby, SRC, *args, chdir: cwd, stdin_data: stdin_data)
  { out: out.force_encoding(Encoding::UTF_8).scrub, code: st.exitstatus, prompt: out.include?("[y/N]") }
end

def last_line(res)
  res[:out].lines.map(&:chomp).reject(&:empty?).last
end

def expect(name, res, code, label)
  check("#{name}: exit #{code} (got #{res[:code].inspect})", res[:code] == code)
  check("#{name}: label #{label} (got #{last_line(res).inspect})", last_line(res) == "context-note-apply: #{label}")
end

def snap(path)
  st = File.lstat(path)
  [st.file? ? File.binread(path) : nil, st.ino, st.mode, st.mtime.to_r]
end

def leftovers(root)
  Dir.children(root).select { |c| c.start_with?(".#{NOTE}.") }
end

SRC = src

# ---- usage ----------------------------------------------------------------------------
root = new_repo
pr = proposal("new\n")
[[[], "引数なし"], [["-C"], "-C の値なし"], [["-x", pr], "知らない option"], [[pr, pr], "file が 2 つ"],
 [["-"], "stdin"], [["-C", root, "-C", root, pr], "-C が 2 回"]].each do |args, name|
  expect("usage #{name}", run_tty(args), 2, "usage")
end
check("usage: note を作らない", !File.exist?(File.join(root, NOTE)))

# ---- agent の session の目印 -----------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "old\n")
before = snap(note)
pr = proposal("new\n")
MARKERS.each do |m|
  res = run_tty(["-C", root, pr], env: { m => "1" })
  expect("agent-session #{m}", res, 1, "agent-session")
  check("agent-session #{m}: 確認を聞かない", !res[:prompt])
  check("agent-session #{m}: note は前のまま", snap(note) == before)
end
# 空の値は目印とみなさない (目印は「空でない」とき)。
res = run_tty(["-C", root, pr], env: { "CLAUDECODE" => "" }, answer: "n\n")
expect("agent-session 空の値は目印でない", res, 1, "declined")

# ---- 端末でない ------------------------------------------------------------------------
res = run_pipe(["-C", root, pr], stdin_data: "y\n")
expect("no-tty stdin と stdout が pipe", res, 1, "no-tty")
check("no-tty: note は前のまま", snap(note) == before)
# 標準入力は端末、標準出力だけ file (出力を溜める wrapper の形)。
outfile = File.join(TMP_ROOT, "stdout.txt")
PTY.spawn(child_env("OUT" => outfile), "/bin/sh", "-c", 'exec "$0" "$@" > "$OUT"', RbConfig.ruby, SRC, "-C", root, pr) do |r, _w, pid|
  begin
    loop { r.readpartial(4096) }
  rescue EOFError, Errno::EIO
    nil
  end
  @st = Process.wait2(pid)[1]
end
res = { out: File.read(outfile, encoding: "UTF-8"), code: @st.exitstatus }
expect("no-tty stdout だけ file", res, 1, "no-tty")
check("no-tty stdout だけ file: note は前のまま", snap(note) == before)

# ---- git の env ------------------------------------------------------------------------
GIT_REPO_ENV.each do |k|
  res = run_tty(["-C", root, pr], env: { k => "" })
  expect("git env #{k}", res, 2, "undetermined")
  check("git env #{k}: note は前のまま", snap(note) == before)
end

# ---- 作業 tree・index ------------------------------------------------------------------
plain = File.join(TMP_ROOT, "plain")
Dir.mkdir(plain)
expect("git の作業 tree でない", run_tty(["-C", plain, pr]), 2, "undetermined")
check("git の作業 tree でない: note を作らない", !File.exist?(File.join(plain, NOTE)))
expect("-C の directory が無い", run_tty(["-C", File.join(TMP_ROOT, "nowhere"), pr]), 2, "input")
broken = new_repo
File.binwrite(File.join(broken, ".git", "index"), "garbage")
res = run_tty(["-C", broken, pr])
expect("index を読めない", res, 2, "undetermined")
check("index を読めない: note を作らない", !File.exist?(File.join(broken, NOTE)))

# ---- 案の file -------------------------------------------------------------------------
big = proposal("a" * (1024 * 1024 + 1), "big.md")
exact = proposal("a" * (1024 * 1024), "exact.md")
{ "無い" => File.join(TMP_ROOT, "missing.md"), "directory" => plain, "空" => proposal("", "empty.md"),
  "1 MiB を越える" => big, "UTF-8 でない" => proposal("\xff\xfe".b, "bin.md") }.each do |name, path|
  expect("案の file #{name}", run_tty(["-C", root, path]), 2, "input")
  check("案の file #{name}: note は前のまま", snap(note) == before)
end
res = run_tty(["-C", root, exact], answer: "n\n")
expect("案の file ちょうど 1 MiB は読む", res, 1, "declined")

# ---- note の種類 -----------------------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
target = File.join(TMP_ROOT, "target.md")
File.binwrite(target, "old\n")
File.symlink(target, note)
tsnap = snap(target)
res = run_tty(["-C", root, pr])
expect("symlink", res, 1, "symlink")
check("symlink: 確認を聞かない", !res[:prompt])
check("symlink: link は前のまま", File.symlink?(note) && File.readlink(note) == target)
check("symlink: 参照先は前のまま", snap(target) == tsnap)
File.unlink(note)
File.symlink(File.join(TMP_ROOT, "dangling.md"), note)
expect("参照先の無い symlink", run_tty(["-C", root, pr]), 1, "symlink")
check("参照先の無い symlink: 参照先を作らない", !File.exist?(File.join(TMP_ROOT, "dangling.md")))
File.unlink(note)
Dir.mkdir(note)
expect("directory", run_tty(["-C", root, pr]), 1, "not-regular")
Dir.rmdir(note)
File.mkfifo(note)
expect("FIFO", run_tty(["-C", root, pr]), 1, "not-regular")
File.unlink(note)

# ---- tracked ---------------------------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "old\n")
git(root, "add", "--", NOTE)
before = snap(note)
res = run_tty(["-C", root, pr])
expect("tracked 同じ名前", res, 1, "tracked")
check("tracked: 確認を聞かない", !res[:prompt])
check("tracked: note は前のまま", snap(note) == before)
expect("tracked GIT_LITERAL_PATHSPECS", run_tty(["-C", root, pr], env: { "GIT_LITERAL_PATHSPECS" => "1" }), 1, "tracked")
check("tracked GIT_LITERAL_PATHSPECS: note は前のまま", snap(note) == before)

root = new_repo
upper = ".AGENT-CONTEXT.LOCAL.MD"
File.binwrite(File.join(root, upper), "old\n")
git(root, "add", "--", upper)
if File.exist?(File.join(root, NOTE))
  before = snap(File.join(root, NOTE))
  expect("tracked 大文字小文字だけ違う名前", run_tty(["-C", root, pr]), 1, "tracked")
  check("tracked 大文字小文字だけ違う名前: note は前のまま", snap(File.join(root, NOTE)) == before)
else
  # 大文字小文字を区別する file system では、別の file になる。tracked な名前があるので作らない。
  expect("tracked 大文字小文字だけ違う名前 (区別する fs)", run_tty(["-C", root, pr]), 1, "tracked")
  check("tracked 大文字小文字だけ違う名前 (区別する fs): note を作らない", !File.exist?(File.join(root, NOTE)))
end

# ---- unchanged -------------------------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "same\n")
before = snap(note)
res = run_tty(["-C", root, proposal("same\n")])
expect("unchanged", res, 0, "unchanged")
check("unchanged: 確認を聞かない", !res[:prompt])
check("unchanged: note は前のまま", snap(note) == before)

# ---- 新しく作る (-C を省き、子 directory から) ---------------------------------------
root = new_repo
note = File.join(root, NOTE)
sub = File.join(root, "sub", "dir")
FileUtils.mkdir_p(sub)
pr = proposal("# 参照先\n- new line\n")
res = run_tty([pr], cwd: sub, answer: "y\n")
expect("新しく作る", res, 0, "written")
check("新しく作る: 答えより前に差分", res[:before].include?("--- ") && res[:before].include?("+++ ") &&
                                     res[:before].include?("@@ ") && res[:before].include?("+- new line"))
check("新しく作る: 中身は案のとおり", File.binread(note) == File.binread(pr))
check("新しく作る: 0600", (File.stat(note).mode & 0o7777) == 0o600)
check("新しく作る: root に作る", !File.exist?(File.join(sub, NOTE)))
check("新しく作る: 一時 file を残さない", leftovers(root).empty?)

# ---- 書き換える (-C の子 directory、権限を保つ、答えの大文字) ------------------------
root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "keep\nold line\n")
File.chmod(0o640, note)
sub = File.join(root, "sub")
Dir.mkdir(sub)
pr = proposal("keep\nnew line\n")
res = run_tty(["-C", sub, pr], answer: "YES\n")
expect("書き換える", res, 0, "written")
check("書き換える: 答えより前に差分", res[:before].include?("-old line") && res[:before].include?("+new line"))
check("書き換える: 中身は案のとおり", File.binread(note) == File.binread(pr))
check("書き換える: 権限を保つ", (File.stat(note).mode & 0o7777) == 0o640)
check("書き換える: 一時 file を残さない", leftovers(root).empty?)
res = run_tty(["-C", root, proposal("keep\nthird\n")], answer: "y\n")
expect("書き換える y", res, 0, "written")
check("書き換える y: 中身", File.binread(note) == "keep\nthird\n")

# ---- 断る ------------------------------------------------------------------------------
before = snap(note)
pr = proposal("keep\nrejected\n")
{ "n" => "n\n", "空の答え" => "\n", "ほかの答え" => "ok\n", "EOF" => "\x04", "Ctrl-C" => "\x03" }.each do |name, answer|
  res = run_tty(["-C", root, pr], answer: answer)
  expect("断る #{name}", res, 1, "declined")
  check("断る #{name}: note は前のまま", snap(note) == before)
  check("断る #{name}: 一時 file を残さない", leftovers(root).empty?)
  # EOF と Ctrl-C は端末に改行を残さないので、後の出力は helper が改行してから出す (端末の echo の ^D と後退、^C は除いて見る)。
  if %w[EOF Ctrl-C].include?(name)
    after = res[:out][(res[:out].index("[y/N]: ") + 7)..-1].to_s.sub(/\A\^[CD]\x08*/, "")
    check("断る #{name}: 確認の行の後で改行する", after.start_with?("\n"))
  end
end

# ---- 表示で隠れうる文字 ----------------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "a\n")
hidden = "x\e[2Ky‮z\tt\r\n"
pr = proposal("a\n#{hidden}")
res = run_tty(["-C", root, pr], answer: "y\n")
expect("隠れうる文字", res, 0, "written")
check("隠れうる文字: ESC を <U+001B> で見せる", res[:before].include?("<U+001B>[2K"))
check("隠れうる文字: U+202E を見せる", res[:before].include?("<U+202E>"))
check("隠れうる文字: CR を見せる", res[:before].include?("<U+000D>"))
check("隠れうる文字: 端末に ESC と U+202E を出さない", !res[:out].include?("\e") && !res[:out].include?("‮"))
check("隠れうる文字: tab はそのまま", res[:before].include?("z\tt"))
check("隠れうる文字: 中身はそのまま書く", File.binread(note) == "a\n#{hidden}".b)

# NUL を含む案と note も、binary とみなさずに中身の差分を見せる。
File.binwrite(note, "p\0q\nkeep\n")
pr = proposal("keep\nx\0y\n")
res = run_tty(["-C", root, pr], answer: "y\n")
expect("NUL", res, 0, "written")
check("NUL: 案の行を <U+0000> で見せる", res[:before].include?("+x<U+0000>y"))
check("NUL: note の行を <U+0000> で見せる", res[:before].include?("-p<U+0000>q"))
check("NUL: binary の扱いにしない", !res[:out].include?("Binary"))
check("NUL: 中身はそのまま書く", File.binread(note) == "keep\nx\0y\n".b)

# diff が差分の形を出さない (binary の扱いで中身を省く実装など) ときは、確認に進まない。
fakebin = File.join(TMP_ROOT, "fakebin")
Dir.mkdir(fakebin)
File.write(File.join(fakebin, "diff"), "#!/bin/sh\necho 'Binary files a and b differ'\nexit 1\n")
File.chmod(0o755, File.join(fakebin, "diff"))
before = snap(note)
res = run_tty(["-C", root, proposal("other\n")], env: { "PATH" => "#{fakebin}:#{ENV.fetch("PATH")}" }, answer: "y\n")
expect("差分の形でない diff の出力", res, 2, "undetermined")
check("差分の形でない diff の出力: 確認を聞かない", !res[:prompt])
check("差分の形でない diff の出力: note は前のまま", snap(note) == before)

# path の中の改行は <U+000A> で見せ、偽の差分の行を作れない。
forged = File.join(TMP_ROOT, "lf\n+++ forged\n@@ -1 +1 @@")
Dir.mkdir(forged)
git(forged, "init", "-q")
File.binwrite(File.join(forged, NOTE), "old\n")
res = run_tty(["-C", forged, proposal("new\n")], answer: "n\n")
expect("path の改行", res, 1, "declined")
check("path の改行: <U+000A> で見せる", res[:before].include?("lf<U+000A>+++ forged<U+000A>@@ -1 +1 @@"))
check("path の改行: 偽の行を出さない", res[:out].lines.none? { |l| l.chomp == "+++ forged" })

# root の名前の末尾の CR を外さない (外すと、隣の別の repo の note を書く)。
cr_root = File.join(TMP_ROOT, "crrepo\r")
sibling = File.join(TMP_ROOT, "crrepo")
[cr_root, sibling].each do |d|
  Dir.mkdir(d)
  git(d, "init", "-q")
  File.binwrite(File.join(d, NOTE), "old\n")
end
sibling_before = snap(File.join(sibling, NOTE))
res = run_tty(["-C", cr_root, proposal("new\n")], answer: "y\n")
expect("root の末尾の CR", res, 0, "written")
check("root の末尾の CR: その repo の note を書く", File.binread(File.join(cr_root, NOTE)) == "new\n")
check("root の末尾の CR: 隣の repo の note は前のまま", snap(File.join(sibling, NOTE)) == sibling_before)
check("root の末尾の CR: path の CR を見せる", res[:before].include?("crrepo<U+000D>/#{NOTE}"))

# ---- 書けない directory ----------------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "old\n")
before = snap(note)
File.chmod(0o555, root)
begin
  res = run_tty(["-C", root, proposal("new\n")], answer: "y\n")
ensure
  File.chmod(0o755, root)
end
expect("書けない directory", res, 2, "write-failed")
check("書けない directory: note は前のまま", snap(note) == before)

# ---- locale が C -----------------------------------------------------------------------
root = new_repo
note = File.join(root, NOTE)
pr = proposal("# 日本語の参照先\n")
res = run_tty(["-C", root, pr], env: { "LC_ALL" => "C", "LANG" => "C" }, answer: "y\n", ruby_args: [])
expect("locale が C", res, 0, "written")
check("locale が C: 中身は案のとおり", File.binread(note) == File.binread(pr))

# ---- 確かめ直し (直接呼び出し) ---------------------------------------------------------
load SRC

# 端末に見える入出力。入力は、gets の時に hook を呼んでから答えを返し、端末のように答えを出力へ echo する。
class FakeTTY < StringIO
  attr_accessor :hook, :echo

  def tty?
    true
  end

  def gets(*args)
    hook&.call
    line = super
    echo&.write(line) if line
    line
  end
end

def direct(root, pr, &hook)
  out = FakeTTY.new
  err = StringIO.new
  input = FakeTTY.new("y\n")
  input.hook = hook
  input.echo = out
  code = ContextNoteApply.run(["-C", root, pr], env: {}, stdin: input, stdout: out, stderr: err)
  { out: out.string, code: code, err: err.string }
end

root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "old\n")
pr = proposal("new\n")
res = direct(root, pr) { File.binwrite(note, "edited by hand\n") }
expect("確かめ直し 中身が変わった", res, 1, "changed")
check("確かめ直し 中身が変わった: 人の変更を残す", File.binread(note) == "edited by hand\n")

res = direct(root, pr) do
  File.unlink(note)
  File.symlink(target, note)
end
expect("確かめ直し symlink に替わった", res, 1, "symlink")
check("確かめ直し symlink に替わった: 参照先は前のまま", snap(target) == tsnap)
File.unlink(note)

File.binwrite(note, "old\n")
res = direct(root, pr) { git(root, "add", "--", NOTE) }
expect("確かめ直し tracked になった", res, 1, "tracked")
check("確かめ直し tracked になった: note は前のまま", File.binread(note) == "old\n")

root = new_repo
note = File.join(root, NOTE)
res = direct(root, pr) { File.binwrite(note, "created meanwhile\n") }
expect("確かめ直し 無かった note ができた", res, 1, "changed")
check("確かめ直し 無かった note ができた: 前のまま", File.binread(note) == "created meanwhile\n")

root = new_repo
note = File.join(root, NOTE)
File.binwrite(note, "old\n")
File.chmod(0o644, note)
res = direct(root, pr) { File.chmod(0o600, note) }
expect("確かめ直し 権限が変わった", res, 1, "changed")

res = direct(root, pr) { nil }
expect("直接呼び出し 書く", res, 0, "written")
check("直接呼び出し 書く: 中身", File.binread(note) == "new\n")

# 一時 file を書いた後に rename が失敗したら、一時 file を消し、note は前のまま。
File.binwrite(note, "old\n")
class << File
  alias_method :orig_rename, :rename
  def rename(*)
    raise Errno::EACCES, "injected"
  end
end
begin
  res = direct(root, pr) { nil }
ensure
  class << File
    alias_method :rename, :orig_rename
  end
end
expect("rename の失敗", res, 2, "write-failed")
check("rename の失敗: note は前のまま", File.binread(note) == "old\n")
check("rename の失敗: 一時 file を残さない", leftovers(root).empty?)

exit(@failed.zero? ? 0 : 1)
RUBY
echo "ok: context-note-apply-test"
