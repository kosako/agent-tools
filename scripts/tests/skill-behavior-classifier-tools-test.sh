#!/bin/sh
# scripts/lib/skill_behavior_classifier.rb の self-test (#755・#756・#757・#767・#773)。
# 引数の語の組を列挙し、分類器が read と区分した組を、実物の uniq・sed・git で走らせる。file も ref もできないことを見る。
# $? と構文の語と for の loop の形は、command の全文の組を、実物の sh・bash・zsh で走らせる (shell の展開を通す)。
# 期待値は分類器から作らない。できた file を数えるだけで、実物の引数の読み方をここに写さない。
# - 組の数と、走らせた数の下限を固定する (組が減ったり、全部が read でなくなったりして、何も確かめない形にしない)。
# - 実物は argv で起動する (shell の展開を通さない)。書き込みは一時 dir の中だけ。network と実 ~/.gitconfig には触れない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/scripts/lib/skill_behavior_classifier.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" -ropen3 -rfileutils - "$src" "$tmp" <<'RUBY'
load ARGV[0]
TMP = ARGV[1]
P = SkillBehaviorClassifier

def words(tokens, max)
  (1..max).flat_map { |n| tokens.repeated_permutation(n).to_a }
end

def read?(name, args)
  line = [name, *args].map { |w| "'" + w.gsub("'") { "'\\''" } + "'" }.join(" ")
  P.classify_shell(line) == "read"
end

def entries(dir)
  Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |f| f.end_with?("/.") || f == "." }.sort
end

# argv を dir の中で走らせ、できた file を返す。できた file は消して、次の組に残さない。
def made(dir, base, argv, env = {})
  Open3.capture3(env, *argv, chdir: dir, stdin_data: "")
  new = entries(dir) - base
  new.sort.reverse_each { |f| FileUtils.rm_rf(File.join(dir, f)) }
  new
end

# ---- uniq (#755) ---------------------------------------------------------------------------
dir = File.join(TMP, "uniq")
FileUtils.mkdir_p(dir)
File.write(File.join(dir, "in.txt"), "a\na\nb\n")
base = entries(dir)
all = words(%w[-c -d -f 1 --count --skip-fields --skip-fields=1 -- - in.txt], 3)
check("uniq: 組の数", all.length == 1110)
read = all.select { |a| read?("uniq", a) }
check("uniq: read の組の下限 (#{read.length})", read.length >= 100)
[%w[in.txt], %w[-c in.txt], %w[-c -- in.txt], %w[-f 1 in.txt], %w[--skip-fields=1 in.txt], %w[-c -]].each do |a|
  check("uniq: read のまま #{a.inspect}", read.include?(a))
end
wrote = read.map { |a| [a, made(dir, base, ["/usr/bin/uniq", *a])] }.reject { |_, new| new.empty? }
check("uniq: read と区分した組が書いた #{wrote.length} 件 #{wrote.first(3).inspect}", wrote.empty?)

# ---- sed (#756) ----------------------------------------------------------------------------
# 番地の部品の組。w の書き込み先 (d の中) を先に作り、書ければ必ず file ができるようにする。
dir = File.join(TMP, "sed")
FileUtils.mkdir_p(File.join(dir, "d"))
File.write(File.join(dir, "x"), "a\n[\n]\nw d\n")
base = entries(dir)
first = [[]] + words(["[", "]", "\\", ",", "a"], 2)
second = ["w d", "]w d", "[w d", "\\w d", ",w d", "w d]", "w d\\", "aw d"]
scripts = first.map(&:join).product(second).flat_map { |a, b| ["/#{a}/,/#{b}/p", "/#{a}/p;/#{b}/p"] }
check("sed: script の数", scripts.length == 496)
read = scripts.select { |s| read?("sed", ["-n", s, "x"]) }
check("sed: read の script の下限 (#{read.length})", read.length >= 200)
["/a/,/w d/p", "/a/p;/w d/p"].each { |s| check("sed: read のまま #{s}", read.include?(s)) }
wrote = read.map { |s| [s, made(dir, base, ["/usr/bin/sed", "-n", s, "x"])] }.reject { |_, new| new.empty? }
check("sed: read と区分した script が書いた #{wrote.length} 件 #{wrote.first(3).inspect}", wrote.empty?)

# ---- git branch / git tag (#757) -----------------------------------------------------------
# ref の置き方は git の版で変わりうるので、.git の中に何かができたことだけを見る。
dir = File.join(TMP, "git")
FileUtils.mkdir_p(dir)
env = ENV.keys.grep(/\AGIT_/).map { |k| [k, nil] }.to_h.merge(
  "HOME" => TMP, "XDG_CONFIG_HOME" => TMP, "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_PAGER" => "cat",
  "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.invalid",
  "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.invalid"
)
git = ["git", "-c", "core.hooksPath=/dev/null"]
[%w[init -q --template=], %w[commit -q --allow-empty -m x]].each do |a|
  _out, err, st = Open3.capture3(env, *git, *a, chdir: dir, stdin_data: "")
  abort "FAIL: git #{a.first}: #{err}" unless st.success?
end
base = entries(dir)
check("git: 対照。branch を作ると、できたものに出る", made(dir, base, [*git, "branch", "x"], env).any? { |f| f.start_with?(".git/") })
all = words(%w[--list -l --format --sort -v x], 3)
check("git: 組の数", all.length == 258)
%w[branch tag].each do |sub|
  read = all.select { |a| read?("git", [sub, *a]) }
  check("git #{sub}: read の組の下限 (#{read.length})", read.length >= 40)
  [%w[--list], %w[--list x], %w[-l x], %w[--sort x --list]].each do |a|
    check("git #{sub}: read のまま #{a.inspect}", read.include?(a))
  end
  wrote = read.map { |a| [a, made(dir, base, [*git, sub, *a], env)] }.reject { |_, new| new.empty? }
  check("git #{sub}: read と区分した組が書いた #{wrote.length} 件 #{wrote.first(3).inspect}", wrote.empty?)
end

# ---- echo の $? (#767) ---------------------------------------------------------------------
# command の頭・前置き・引用・直後の字・後ろの組。read か exec と区分した command を、実物の shell で走らせる。
dir = File.join(TMP, "status")
FileUtils.mkdir_p(dir)
File.write(File.join(dir, "in.txt"), "a\na\nb\n")
base = entries(dir)
shells = [%w[/bin/sh -c], %w[/bin/bash -c], %w[/bin/zsh -f -c]]
heads = ["echo", "echo -n", "cat", "ls", "uniq in.txt", "sort -o", "sort in.txt -o", "tee", "touch", "env echo", "X=1 echo",
         "false; echo", "cat in.txt | echo", "cat in.txt\necho"]
pre = ["", "a", "a=", "a:", "a.", "a/", "a b=", "=", "-", "~", "*"]
post = ["", "x", "[1]", ":h", "?", "*", " ", "}"]
tails = ["", " >out", " 2>&1", " $?", "; touch out", "; cat in.txt", " | cat", " && cat in.txt"]
all = heads.product(pre, ["", '"'], post, tails).map { |h, a, q, b, t| "#{h} #{q}#{a}$?#{b}#{q}#{t}" }
check("status: 組の数", all.length == 19_712 && all.uniq.length == all.length)
ran = all.select { |c| %w[read exec].include?(P.classify_shell(c)) }
# 頭 4 (前に付く語と option の無い echo)、後ろ 4 (書く command と redirect と 2 つ目の引数のほか)、引数 14 (引用なしは前置き 3 と、
# その後ろの空白の 3。二重引用は、許す字だけの前置き 8)
check("status: 走らせる組の数 (#{ran.length})", ran.length == 4 * 4 * (3 + 3 + 8))
check("status: 観測した形は read", ran.include?('echo "a=$?"') && ran.include?('false; echo "a=$?"'))
check("status: 対照。書く command は、できたものに出る",
      made(dir, base, ["/bin/sh", "-c", "false; uniq in.txt $?"]) == ["1"])
wrote = ran.flat_map { |c| shells.map { |sh| [sh[0], c, made(dir, base, [*sh, c])] } }.reject { |_, _, new| new.empty? }
check("status: read と区分した command が書いた #{wrote.length} 件 #{wrote.first(3).inspect}", wrote.empty?)
out = shells.map { |sh| Open3.capture3(*sh, 'false; echo "a=$?"', chdir: dir)[0] }
check("status: $? は整数に展開される #{out.inspect}", out == ["a=1\n"] * 3)

# ---- 構文の語 (#773) -----------------------------------------------------------------------
# 構文の語の名前の program を PATH の先頭に置き、read か exec と区分した command が、どの shell でもそれを起動しないことを見る。
# program は、起動されると、今いる dir に ran という file を作る。
dir = File.join(TMP, "words")
bin = File.join(TMP, "words-bin")
[dir, bin].each { |d| FileUtils.mkdir_p(d) }
File.write(File.join(dir, "in.txt"), "a\n")
base = entries(dir)
keywords = P::KEYWORD_WORDS + P::CLOSER_WORDS
keywords.each do |w|
  File.write(File.join(bin, w), "#!/bin/sh\n: > ran\n")
  File.chmod(0o755, File.join(bin, w))
end
path = { "PATH" => "#{bin}:/usr/bin:/bin" }
fronts = ["", "env ", "command ", "exec ", "nohup ", "nice ", "time ", "builtin ", "env command ", "then ", "do ", "do env ", "X=1 ",
          "2>/dev/null ", ">/dev/null ", "2>&1 ", "do 2>/dev/null ", "env 2>/dev/null ", "cat in.txt; ", "cat in.txt | ", "cat in.txt && env "]
forms = [->(w) { w }, ->(w) { "\"#{w}\"" }, ->(w) { "'#{w}'" }, ->(w) { "\"\"#{w}" }, ->(w) { "#{w[0]}'#{w[1..]}'" }]
backs = ["", " cat in.txt", " 2>/dev/null", "; cat in.txt"]
all = fronts.product(forms, keywords, backs).map { |a, f, w, b| "#{a}#{f.call(w)}#{b}" }
check("構文の語: 組の数", all.length == 21 * 5 * 8 * 4)
ran = all.select { |c| %w[read exec].include?(P.classify_shell(c)) }.uniq
check("構文の語: 走らせる組に、引用した語が無い", ran.none? { |c| c.match?(/['"]/) })
# 裸の語だけ。先頭・; の後・| の後に 5 語 (! と { と } は門が止める)、then と do の後に 3 語 (then・do・else)、後ろ 4
check("構文の語: 走らせる組の数 (#{ran.length})", ran.length == (3 * 5 + 2 * 3) * 4)
[%q{"fi"}, "env done", %q{"do" cat in.txt}, "nice then"].each do |c|
  got = shells.map { |sh| made(dir, base, [*sh, c], path) }
  check("構文の語: 対照。#{c} は program を起動する #{got.inspect}", got == [["ran"]] * 3)
end
got = shells.map { |sh| made(dir, base, [*sh, "2>/dev/null then"], path) }
check("構文の語: 対照。redirect の後の語は、sh と bash で program を起動する #{got.inspect}", got == [["ran"], ["ran"], []])
started = ran.flat_map { |c| shells.map { |sh| [sh[0], c, made(dir, base, [*sh, c], path)] } }.reject { |_, _, new| new.empty? }
check("構文の語: read と区分した command が program を起動した #{started.length} 件 #{started.first(3).inspect}", started.empty?)

# ---- for の loop (#767) --------------------------------------------------------------------
# loop の値に、option・置き換え・区切り・空白・glob の字を持つ名前を入れる。頭・command・引数・後ろ・終わりの組を区分し、read の
# 数を手で出した式と照合する。走らせるのは、頭・command・引数の全部の組 (後ろは無し) と、後ろと終わりの全部の組 (1 つの loop)。
dir = File.join(TMP, "loop")
FileUtils.mkdir_p(File.join(dir, "v"))
odd = ["-o", "-n", "a b", "$(touch pwn)", ";touch pwn", "`touch pwn`", "*", "in.txt"]
odd.each { |n| File.write(File.join(dir, "v", n), "x\n") }
File.write(File.join(dir, "-o"), "x\n")
File.write(File.join(dir, "in.txt"), "a\na\nb\n")
File.write(File.join(dir, "names"), odd.join("\n") + "\nout\n")
base = entries(dir)
heads = ["for x in in.txt names", "for x in v/*", "for x in ./*", "for x in $(cat names)", "for x in $(ls)",
         "for x in *", "for x in {in.txt,names}", "for path in in.txt"]
cmds = ["cat", "echo", "head", "tail", "wc", "nl", "ls", "sort", "uniq in.txt", "tee", "touch", "sed -n p", "sort in.txt",
        "env cat", "grep a", "xargs", "sh"]
args = ["$x", '"$x"', '"== $x"', "$x out", "-o $x", "${x}", "$x.rb", '"$x"b']
tails = ["", " 2>/dev/null", " | cat", " >out", " | tee out", "; touch out"]
ends = ["; done", "; done | cat", "; cat $x; done", "; done >out", "; done; cat $x", ""]
all = heads.product(cmds, args, tails, ends)
text = ->((h, c, a, t, e)) { "#{h}; do #{c} #{a}#{t}#{e}" }
check("loop: 組の数", all.length == 39_168)
read = all.select { |x| P.classify_shell(text.call(x)) == "read" }
# 頭 5 (先頭が * の語・brace・特別な変数のほか)、command 7、引数 5 (名前の直後に字が続く形と ${x} のほか)、後ろ 3、終わり 3
check("loop: read の組の数 (#{read.length})", read.length == 5 * 7 * 5 * 3 * 3)
check("loop: exec の組は無い", all.none? { |x| P.classify_shell(text.call(x)) == "exec" })
ran = read.select do |h, c, a, t, e|
  (t.empty? && e == "; done") || (h == heads[3] && c == "cat" && a == "$x")
end
check("loop: 走らせる組の数 (#{ran.length})", ran.length == 5 * 7 * 5 + 3 * 3 - 1)
{ 'for x in $(cat names); do sort $x out in.txt; done' => %w[out], 'for x in v/*; do sh -c "$x"; done' => %w[pwn] }.each do |cmd, want|
  got = made(dir, base, ["/bin/sh", "-c", cmd])
  check("loop: 対照。値で書く loop は、できたものに出る #{cmd} #{got.inspect}", got == want)
  check("loop: 対照の loop は read でない", P.classify_shell(cmd) == "unknown")
end
wrote = ran.flat_map { |x| shells.map { |sh| [sh[0], text.call(x), made(dir, base, [*sh, text.call(x)])] } }
           .reject { |_, _, new| new.empty? }
check("loop: read と区分した loop が書いた #{wrote.length} 件 #{wrote.first(3).inspect}", wrote.empty?)
out = shells.map { |sh| Open3.capture3(*sh, 'for x in $(cat names); do echo "== $x"; done', chdir: dir)[0] }
check("loop: 値は、そのまま出る", out.all? { |o| o.include?("== -o\n") && o.include?("== $(touch\n") && o.include?("== out\n") })

# 区切りの並び。read と区分した並びは、どの shell でも構文が通る (-n。走らせない)。
seps = [" ", ";", "\n", "|", "&&", "&", ";;", "; ;", ";\n", "\n;", "|\n", "| |"]
all = seps.repeated_permutation(4).map { |a, b, c, d| "for x in a#{a}do#{b}cat $x#{c}cat b#{d}done" }
check("loop の区切り: 組の数", all.length == 20_736 && all.uniq.length == all.length)
read = all.select { |c| %w[read exec].include?(P.classify_shell(c)) }
# 頭と do の間 3 (; と改行と ;改行)、do の後 2 (空白と改行)、本体の間 7 (空白 ; 改行 | && ;改行 |改行。空白なら 1 つの command)、
# done の前 3
check("loop の区切り: read の組の数 (#{read.length})", read.length == 3 * 2 * 7 * 3)
syntax = ->(c) { [%w[/bin/sh -n -c], %w[/bin/bash -n -c], %w[/bin/zsh -f -n -c]].map { |sh| Open3.capture3(*sh, c, chdir: dir)[2].success? } }
check("loop の区切り: 対照。崩れた並びは構文が通らない", syntax.call("for x in a; do cat $x | done") == [false] * 3)
broken = read.reject { |c| syntax.call(c).all? }
check("loop の区切り: 構文の通らない並びを read にした #{broken.length} 件 #{broken.first(3).inspect}", broken.empty?)
# loop の外。先頭、前の部分との間、後ろの部分との間、終わりの組 (間の " " は、前や後ろの部分が無い形にする)
ends = ["", "\n", ";", "|", "&&", ";;", "||"]
outer = [" ", ";", "\n", "|", "&&", ";;", "\n;", "|\n"]
around = ends.product(outer, outer, ends).map do |a, b, c, d|
  "#{a}#{"cat y#{b}" unless b == " "}for x in a; do cat $x; done#{"#{c}cat z" unless c == " "}#{d}"
end
check("loop の外の区切り: 組の数", around.length == 3_136)
read = around.select { |c| %w[read exec].include?(P.classify_shell(c)) }
# 先頭 2 (無しと改行)、前の部分 1 + 5 (無し、; 改行 | && |改行)、後ろの部分 1 + 5、終わり 3 (無し ; 改行)
check("loop の外の区切り: read の組の数 (#{read.length})", read.length == 2 * 6 * 6 * 3)
check("loop の外の区切り: 対照", syntax.call("for x in a; do cat $x; done |") == [false] * 3 && syntax.call("| for x in a; do cat $x; done") == [false] * 3)
broken = read.uniq.reject { |c| syntax.call(c).all? }
check("loop の外の区切り: 構文の通らない並びを read にした #{broken.length} 件 #{broken.first(3).inspect}", broken.empty?)

# 予約語。どの位置でも、read になるのは、ふつうの command の語だけ。read の全部が、どの shell でも構文が通る。
# builtin は入れない (zsh の -n は、在るかどうかの検査で「builtin cat」を落とす。構文の検査ではない)。
plain = %w[cat command env exec nice nohup true]
extra = %w(break continue eval exit export integer local noglob readonly return set shift trap typeset : . - [)
words = P::RESERVED_WORDS + plain + extra
places = ["for x in a; do W; cat $x; done", "for x in a; do W cat b; done", "for x in a; do cat $x; W; done",
          "for x in a; do cat $x; W cat b; done", "for x in a; do cat $x | W cat b; done", "for x in a; do cat $x && W cat b; done",
          "for x in a; do cat $x; 2>/dev/null W; done", "for x in a; do 2>/dev/null W cat b; done",
          "for x in a\ndo\nW cat b\ncat $x\ndone", "for x in a; do cat $x; done; W", "for x in a; do cat $x; done; W cat b",
          "for x in a; do cat $x; done | W cat b", "for x in a; do cat $x; done; 2>/dev/null W cat b", "W; for x in a; do cat $x; done",
          "W cat b; for x in a; do cat $x; done", "2>/dev/null W cat b; for x in a; do cat $x; done"]
check("loop の予約語: 語と位置の数", words.uniq.length == 52 && places.length == 16)
places.each do |place|
  got = words.select { |w| %w[read exec].include?(P.classify_shell(place.gsub("W") { w })) }
  check("loop の予約語: read の語 #{place.inspect} #{got.inspect}", got.sort == plain)
end
misplaced = ["for x in a; W do cat $x; done", "for x in a; do cat $x; done W", "W for x in a; do cat $x; done", "for x in a; do W cat $x; done"]
misplaced.each do |place|
  got = words.select { |w| %w[read exec].include?(P.classify_shell(place.gsub("W") { w })) }
  check("loop の予約語: 置けない位置 #{place.inspect} #{got.inspect}", got == (place.include?("do W cat $x") ? %w[cat] : []))
end
read = places.product(plain).map { |pl, w| pl.gsub("W") { w } }
check("loop の予約語: 対照", syntax.call("for x in a; do cat $x; done; done") == [false] * 3)
broken = read.reject { |c| syntax.call(c).all? }
check("loop の予約語: 構文の通らない形を read にした #{broken.length} 件 #{broken.first(3).inspect}", broken.empty?)

# 構文として働かない位置の構文の語 (引用・前に付く command・redirect の後)。どの位置でも read にしない (#773)。
hidden = keywords.flat_map { |w| ["\"#{w}\"", "'#{w}'", "''#{w}", "env #{w}", "command #{w}", "env \"#{w}\"", "2>/dev/null #{w}"] }
got = places.product(hidden).map { |pl, w| pl.gsub("W") { w } }.select { |c| %w[read exec].include?(P.classify_shell(c)) }
check("loop の隠れた構文の語: 組の数", places.length * hidden.length == 16 * 8 * 7)
check("loop の隠れた構文の語: read にした #{got.length} 件 #{got.first(3).inspect}", got.empty?)

# redirect の位置。read になる位置と、ならない位置。read の全部が、どの shell でも構文が通る。
redirects = ["2>/dev/null", "2>&1", ">/dev/null", "&>/dev/null"]
open_at = ["for x in a; do cat $x R; done", "for x in a; do R cat b; done", "for x in a; do cat $x; done R", "for x in a; do cat $x; done; R",
           "R; for x in a; do cat $x; done", "for x in a; do cat $x; R; done", "for x in a; do R; done", "for x in a; do cat $x; done R; cat b"]
shut_at = ["R for x in a; do cat $x; done", "for R x in a; do cat $x; done", "for x R in a; do cat $x; done", "for x in R a; do cat $x; done",
           "for x in a R; do cat $x; done", "for x in a; R do cat $x; done", "for x in a; do R cat $x; done", "for x in a; do cat $x; R done",
           "for x in a; do cat $x; done R b", "for x in a; do cat $x; done; R done", "for x in a; do cat $x; R done; done"]
at = ->(list) { list.product(redirects).map { |pl, r| pl.gsub("R") { r } } }
opened = at.call(open_at)
check("loop の redirect: read になる位置 #{opened.reject { |c| P.classify_shell(c) == "read" }.inspect}", opened.all? { |c| P.classify_shell(c) == "read" })
got = at.call(shut_at).select { |c| %w[read exec].include?(P.classify_shell(c)) }
check("loop の redirect: read にならない位置 #{got.inspect}", got.empty?)
broken = opened.reject { |c| syntax.call(c).all? }
check("loop の redirect: 構文の通らない形を read にした #{broken.length} 件 #{broken.first(3).inspect}", broken.empty?)
exit(@failed.zero? ? 0 : 1)
RUBY

echo "skill-behavior-classifier-tools-test: ok"
