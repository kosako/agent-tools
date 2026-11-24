#!/bin/sh
# scripts/lib/skill_behavior_classifier.rb の self-test (#755・#756・#757・#767)。
# 引数の語の組を列挙し、分類器が read と区分した組を、実物の uniq・sed・git で走らせる。file も ref もできないことを見る。
# $? の形は、command の全文の組を、実物の sh・bash・zsh で走らせる (shell の展開を通す)。
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
exit(@failed.zero? ? 0 : 1)
RUBY

echo "skill-behavior-classifier-tools-test: ok"
