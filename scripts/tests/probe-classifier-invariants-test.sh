#!/bin/sh
# 分類器の不変条件の試行 (#754) の self-test。隔離、判定、入口、生成器と変異の表を見る。
# 対象は scripts/lib/probe_classifier/ の isolation.rb、judge.rb、generator.rb、mutations.rb と、
# scripts/probe-classifier-invariants.sh。
# - T1: 隔離の、sandbox の要らない部分。profile の文字列の形、閉じた環境の表、変種・canary・道具の表、guard が
#   通す形と拒む形、出力の path の置き換え、group の空の確かめ、隔離を組めないときの理由、preflight の結論の組み方。
# - T2: 隔離の、sandbox の要る部分。否定の検査は、どれも対照 (相手を許した profile で同じ probe が通る) と組にする。
#   否定の検査は 7 つ。一時 dir の外への書き込み、HOME の代役の読み取り、127.0.0.1 への接続、allowlist の外の起動、
#   外の process への signal、親の環境の引き継ぎ、終わらない command。
#   拒否を 1 つ緩めた profile で、その検査が通らないことも見る。
#   ほかに、sandbox を外した profile での書き込みの閉じ方、表の道具と canary の動き、変種ごとの shell の設定、
#   command ごとの新しい一時 dir、検査した profile のまま command が走ることを見る。
# - T3: 判定の、sandbox の要らない部分。手で変えた tree の差分の種類、終わり方の区分、拒まれた起動の拾い方、
#   違反と人に出すものの分け方、確かめ直し (走らせる部分を差し替えて見る)。
# - T4: 判定の、sandbox の要る部分 (witness)。書き込む形が I1、canary を走らせる形が I2、書かない形が差分なしに
#   なること、表に無い program の起動が人に出ること、書き込みの後に終わらない形でも I1 が出ること。
#   scene の glob が展開して出来る書き込みと、guard の表の置き換えの形 (zsh だけで走る) も見る。
# - T5: 入口の、sandbox の要らない部分。引数の誤り、出力先の検査、guard の拒否、read でない command、
#   preflight が通らないときと想定外の失敗のときの exit 2。
#   生成の入口は、dry-run の 2 つの file (同じ引数なら corpus.jsonl が byte まで同じ)、走らせる対象の選び方
#   (調べる版で read、比べる相手で read でない)、変異の当て方、対照の結果の決め方、exit code を見る。
#   走らせる所 (Judge.observe) と preflight を差し替え、同じ process の中から入口を呼ぶ (何も走らせない)。
# - T6: 入口の、sandbox の要る部分。--preflight と、read の command を走らせた結果の file。
#   入口を process として呼ぶのは 3 回 (--preflight、書き込む command、変異つきの生成の run)。preflight は 1 回に
#   3 秒ほどかかる。残りの終わり方は、preflight を「通った」結果に差し替え、同じ process の中から入口を呼んで見る。
# - T7: 生成器と変異の表 (sandbox の要らない部分)。同じ seed と件数で同じ列になること (digest の固定値は、
#   CI の 2 つの Ruby で同じ値になることを見る)、cell の回り方、生成した全件が guard を通ること、
#   門の外の形が閉じた表から出ること、変異の当て方 (小さな代役の source で見る) と表の形。
#   生成した command は走らせない。分類器も読まない (read が何件出るかは、手元の試行で測る)。
#   変異の表が repo の今の分類器に当たるかは見ない (分類器を直す PR が、表の保守を負わないようにする)。
# sandbox を適用できない環境 (入れ子の sandbox の中など) では T2・T4・T6 を skip して 1 行出す。CI
# (GITHUB_ACTIONS=true) では skip せず失敗にする。skip の判断は T2 の中の 1 か所で行う。
# 走らせる command は、この test の一時 dir の中で、相対 path だけを使う。否定の検査の probe だけは、同じ一時 dir に
# 作った代役 (外の dir、HOME の代役、偽の CLI) と /bin/date を絶対 path で指す。network は test が自分で開いた
# 127.0.0.1 の port だけ。本物の codex・claude・gh・opencode・herdr は起動しない (PATH の canary に当たる)。rg は使わない。
# 入口の test は、分類器の代役 (何でも read と答える小さな file と、先頭の語で決める小さな file) を渡す。
# repo の分類器の今の穴に結び付けないため。変異も、置き換える文字列を 1 回だけ持つ代役に当てる。
# 生成した command を本物の隔離の中で走らせるのは、T6 の 1 回の 2 件だけ (多数を走らせる検査は、手元の試行に回す)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

isolation="$repo_root/scripts/lib/probe_classifier/isolation.rb"
judge="$repo_root/scripts/lib/probe_classifier/judge.rb"
generator="$repo_root/scripts/lib/probe_classifier/generator.rb"
mutations="$repo_root/scripts/lib/probe_classifier/mutations.rb"
probe="$repo_root/scripts/probe-classifier-invariants.sh"
entry="$repo_root/scripts/lib/probe_classifier_invariants.rb"
docs="$repo_root/docs/classifier-invariants.md"
[ -f "$isolation" ] || fail "missing $isolation"
[ -f "$judge" ] || fail "missing $judge"
[ -f "$generator" ] || fail "missing $generator"
[ -f "$mutations" ] || fail "missing $mutations"
[ -x "$probe" ] || fail "missing or not executable: $probe"
[ -f "$entry" ] || fail "missing $entry"
[ -f "$docs" ] || fail "missing $docs"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- T1: 隔離 (sandbox の要らない部分) ---------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$isolation" "$tmp" <<'RUBY'
require ARGV[0]
tmp = File.realpath(ARGV[1])
I = ProbeClassifier::Isolation

# profile の文字列の形。行の並びをそのまま固定する (1 行が消えたら落ちる)。
base = "/t/pci-x"
profile = I.profile(base: base, deny_read: ["/home/real", "/home/alias"], exec_literals: ["/bin/sh", "/bin/cat"],
                    exec_subpaths: ["/dev-dir", "#{base}/shim"])
check "profile: the rule lines", profile.lines.map(&:chomp) == [
  "(version 1)", "(allow default)", "(deny network*)", '(deny file-write* (subpath "/"))',
  '(allow file-write* (subpath "/t/pci-x") (literal "/dev/null"))',
  '(deny file-read* (subpath "/home/real") (subpath "/home/alias"))',
  "(deny process-exec*)",
  '(allow process-exec* (literal "/bin/sh") (literal "/bin/cat") (subpath "/dev-dir") (subpath "/t/pci-x/shim"))',
  "(deny signal)", "(allow signal (target same-sandbox))",
]
args = { base: base, deny_read: ["/home/real"], exec_literals: ["/bin/sh"], exec_subpaths: [] }
relaxed = I.profile(**args.merge(network: true, allow_write: ["/outside"]))
check "profile: the network control drops only the network rule", !relaxed.include?("network") && relaxed.include?("(deny process-exec*)")
check "profile: the signal control drops only the signal rules",
      I.profile(**args.merge(signals: true)).lines.map(&:chomp) == I.profile(**args).lines.map(&:chomp) - ["(deny signal)", "(allow signal (target same-sandbox))"]
check "profile: the write control adds one subpath", relaxed.include?('(allow file-write* (subpath "/t/pci-x") (subpath "/outside") (literal "/dev/null"))')
raised = lambda do |&blk|
  begin
    blk.call
    false
  rescue ArgumentError
    true
  end
end
check "profile: an empty HOME list is refused", raised.call { I.profile(**args.merge(deny_read: [])) }
check "profile: a path with a quote is refused", raised.call { I.profile(**args.merge(base: "/t/a\"b")) }
check "profile: a relative path is refused", raised.call { I.profile(**args.merge(exec_literals: ["bin/sh"])) }
check "profile: the open profile is allow default only", I::OPEN_PROFILE == "(version 1)(allow default)"

# session の profile。exec を許すのは、道具の実 path、shim の下、fixture の canary の file、developer dir だけ。
Dir.mkdir(File.join(tmp, "t1"))
session = I::Session.open(root: File.join(tmp, "t1"))
check "session: no setup problems: #{session.problems.inspect}", session.problems.empty?
layout = session.new_layout("pci-")
check "layout: the zones", I::ZONES == %w[fx home tmp shim tools marks] && I::ZONES.all? { |z| File.directory?(File.join(layout.base, z)) }
check "layout: under the given root, outside HOME", File.dirname(layout.base) == File.join(tmp, "t1") && session.deny_read.none? { |h| I.inside?(layout.base, h) }
lines = session.profile_for(layout).lines.map(&:chomp)
exec_line = lines.find { |l| l.start_with?("(allow process-exec*") }.to_s
write_line = lines.find { |l| l.start_with?("(allow file-write*") }.to_s
read_line = lines.find { |l| l.start_with?("(deny file-read*") }.to_s
check "session profile: every tool's real path is allowed", session.toolset.tools.all? { |t| exec_line.include?("(literal \"#{t.real}\")") }
check "session profile: the shim dir and the developer dir are allowed",
      exec_line.include?("(subpath \"#{layout.shim}\")") && exec_line.include?("(subpath \"#{session.toolset.developer_dir}\")")
check "session profile: the fixture canary files are allowed by name",
      exec_line.include?("(literal \"#{layout.fx}/cat\")") && exec_line.include?("(literal \"#{layout.fx}/bin/grep\")")
check "session profile: the temp dir as a whole is not exec-allowed",
      !exec_line.include?("(subpath \"#{layout.base}\")") && !exec_line.include?("(subpath \"#{layout.fx}\")") &&
      !exec_line.include?("canary_begin") && !exec_line.include?("#{layout.tools}")
check "session profile: writes go to the temp dir and /dev/null only",
      write_line == "(allow file-write* (subpath \"#{layout.base}\") (literal \"/dev/null\"))"
check "session profile: the real HOME is read-denied", !session.deny_read.empty? && session.deny_read.all? { |h| read_line.include?("(subpath \"#{h}\")") }
check "session profile: the deny rules are all present",
      ["(deny network*)", '(deny file-write* (subpath "/"))', "(deny process-exec*)", "(deny signal)"].all? { |l| lines.include?(l) }
with_standin = session.profile_for(layout, deny_read_extra: ["/standin"]).lines.find { |l| l.start_with?("(deny file-read*") }.to_s
check "session profile: a stand-in is added to the HOME list, not swapped in",
      with_standin.include?('(subpath "/standin")') && session.deny_read.all? { |h| with_standin.include?("(subpath \"#{h}\")") }

# 閉じた環境の表。
env = I.child_env(layout)
I.with_parent_env("RIPGREP_CONFIG_PATH" => "/nonexistent", "GIT_DIR" => "/nonexistent") do
  check "env: the table does not depend on the parent env", I.child_env(layout) == env
end
check "with_parent_env restores the parent env", ENV["RIPGREP_CONFIG_PATH"].nil? || ENV["RIPGREP_CONFIG_PATH"] != "/nonexistent"
check "env: exactly the closed table", env.keys.sort == %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_OPTIONAL_LOCKS HOME LC_ALL PATH TMPDIR] && env.keys.sort == I::ENV_KEYS.sort
check "env: values", env == { "HOME" => layout.home, "PATH" => "#{layout.shim}:#{layout.tools}", "TMPDIR" => layout.tmp,
                              "LC_ALL" => "C", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
                              "GIT_OPTIONAL_LOCKS" => "0" }

# 変種の表。
check "variants: names", I::VARIANTS.map(&:name) == %w[zsh bash sh zsh-extendedglob zsh-nullglob bash-nullglob]
check "variants: defaults", I::VARIANTS.select(&:default).map(&:name) == %w[zsh bash sh] && I::DEFAULT_VARIANT == "zsh"
check "variants: the default variant of the same shell",
      I::VARIANTS.map { |v| [v.name, v.base] }.to_h == { "zsh" => "zsh", "bash" => "bash", "sh" => "sh", "zsh-extendedglob" => "zsh",
                                                         "zsh-nullglob" => "zsh", "bash-nullglob" => "bash" }
check "variants: argv", I.variant("zsh").argv == %w[/bin/zsh -f -c] && I.variant("bash").argv == %w[/bin/bash -c] &&
                        I.variant("sh").argv == %w[/bin/sh -c] && I.variant("zsh-extendedglob").argv == %w[/bin/zsh -f -o extendedglob -c] &&
                        I.variant("zsh-nullglob").argv == %w[/bin/zsh -f -o nullglob -c] && I.variant("bash-nullglob").argv == %w[/bin/bash -O nullglob -c]
check "variants: an unknown name", I.variant("dash").nil?

# canary の表と中身。
ids = I::CANARIES.map(&:id)
check "canaries: unique ids", ids.uniq == ids
shim = I::CANARIES.select { |c| c.zone == "shim" }
check "canaries: the PATH canary and the CLI names", shim.select { |c| %i[path cli].include?(c.kind) }.map(&:rel) == %w[canary codex claude gh opencode herdr]
check "canaries: the reserved words", shim.select { |c| c.kind == :reserved }.map(&:rel).sort == %w[! do done else fi then { }]
check "canaries: the fixture files", I::CANARIES.select { |c| c.zone == "fx" }.map(&:rel) == %w[cat bin/grep canary_begin.rb]
I.install_canaries(layout)
sh_bodies = I::CANARIES.select { |c| c.lang == :sh }.map { |c| [c, File.read(c.path_in(layout))] }
check "canaries: sh bodies write the mark with builtins only",
      sh_bodies.all? { |c, body| body == "#!/bin/sh\n: > '#{layout.marks}/#{c.id}.'$$\n" && File.executable?(c.path_in(layout)) }
begin_rb = File.join(layout.fx, "canary_begin.rb")
check "canaries: the Ruby file writes the mark in BEGIN and is not executable",
      File.read(begin_rb).start_with?("BEGIN { File.open(\"#{layout.marks}/fx.canary-begin.") && !File.executable?(begin_rb)
%w[cli.gh.123 cli.gh.456 word.done.9 fx.cat.1 note.txt shim.canary].each { |n| File.write(File.join(layout.marks, n), "") }
Dir.mkdir(File.join(layout.marks, "cli.codex.5"))
marks = I.read_marks(layout)
check "marks: hits by canary id", marks.hits == { "cli.gh" => 2, "word.done" => 1, "fx.cat" => 1 }
check "marks: entries that are not marks are reported", marks.stray == %w[cli.codex.5 note.txt shim.canary]

# 道具の表。
names = I::REQUIRED_TOOLS.keys + I::OPTIONAL_TOOLS.keys
check "tools: required", %w[sh bash zsh git ruby uname].all? { |n| I::REQUIRED_TOOLS.key?(n) } && I::OPTIONAL_TOOLS.key?("rg")
check "tools: no write tools and no other interpreters",
      (names & %w[rm rmdir mv cp mkdir touch tee ln chmod chown dd install truncate mktemp patch perl python python3 node]).empty?
check "tools: resolved to real paths", session.toolset.tools.all? { |t| t.real == File.realpath(t.path) } && session.toolset.missing_required.empty?
# git は developer dir の中の実体を直接指す。/usr/bin/git の入口は、道具にも exec の allowlist にも入れない。
check "tools: git is the binary inside the developer dir, not the /usr/bin/git entry",
      session.toolset["git"].path == File.join(session.toolset.developer_dir, "usr", "bin", "git") &&
      !session.toolset.exec_literals.include?("/usr/bin/git") && I::REQUIRED_TOOLS.fetch("git").empty?
I.link_tools(layout, session.toolset)
check "tools: symlinks by name", Dir.children(layout.tools).sort == session.toolset.names.sort &&
                                 session.toolset.tools.all? { |t| File.readlink(File.join(layout.tools, t.name)) == t.path }
script = lambda do |name, shebang|
  path = File.join(tmp, name)
  File.write(path, "#{shebang}\n")
  File.chmod(0o755, path)
  path
end
check "tools: a script with an interpreter outside the table is not added",
      I.resolve_candidate(script.call("perl-tool", "#!/usr/bin/perl"), []) == [nil, "interpreter-not-allowed"]
sh_tool = script.call("sh-tool", "#!/bin/sh")
check "tools: a /bin/sh script is accepted", I.resolve_candidate(sh_tool, []) == [sh_tool, nil]
check "tools: a tool under HOME is not added", I.resolve_candidate(sh_tool, [tmp]) == [nil, "under-home"]
check "tools: a missing candidate", I.resolve_candidate(File.join(tmp, "absent"), []) == [nil, "not-found"]

# fixture の file の mtime は、過去の決まった時刻 (git の結果が、template を作ってからの時間に依らないように)。
Dir.mkdir(File.join(tmp, "t1-files"))
I.write_files(File.join(tmp, "t1-files"), "a.txt" => "a\n", "sub/b.txt" => "b\n")
check "fixture: files are written with the fixed mtime in the past",
      I::FIXTURE_MTIME == Time.utc(2026, 1, 1) && %w[a.txt sub/b.txt].all? { |f| File.mtime(File.join(tmp, "t1-files", f)) == I::FIXTURE_MTIME }
# 狙いごとの dir (scene)。基本の file とは名前が重ならない。- で始まる名前は、この表から一時 dir に書く。
check "fixture: the scene files", I::FIXTURE_SCENES.keys == %w[pair/a.txt pair/b.txt sortopt/-oplanted.txt sortopt/in.txt pre/--pre=canary
                                                               pre/a.txt plain/-n plain/a.txt]
check "fixture: the scenes do not touch the base files", (I::FIXTURE_SCENES.keys & (I::FIXTURE_FIRST.keys + I::FIXTURE_SECOND.keys)).empty? &&
                                                        I::FIXTURE_FIRST.keys == %w[README.md in.txt x lib/median.rb]

# guard が通す形。手書きの受け入れの command (K1 から K4 を含む) と、生成器が出す門の外の形。
accept = [
  "uniq in.txt -c", %q(sed -n '/a\/,/w lib/p' x), "git branch --format --list x", "sort -o out.txt in.txt",
  "./cat x", "git status", "env done rm x", "'fi' rm x", "cat in.txt 2>/dev/null", "cat x 2>&1 | wc -l",
  "cat in.txt >&2", "cat in.txt &>/dev/null", "cd lib && cat median.rb", "ruby -c lib/median.rb", "bin/grep a in.txt",
  "sort $'-o' out.txt in.txt", %q(sort "${zz:--o}" out.txt in.txt), "zsh -lc 'cat in.txt'", "sh -c 'cat in.txt'",
  "find . -name x -exec cat {} +", "find . -name '*.rb'", "echo in.txt | xargs -n 1 cat", "echo in.txt | xargs grep -o a",
  "tail -n 2 in.txt | cut -f1", "tail +2 in.txt", "grep -F a in.txt | tail -n 1", "cat lib/*.rb", "cat x/{a,b}.md", "sort {-o,out.txt} in.txt",
  "git -C . status", "git log --format=%H", "cat {in,x}.txt", "echo in.txt | xargs -I{} cat {}", "uniq - -c", "cat in.txt; cat x", "echo ^in.txt",
  # ruby は、code を走らせない形と、file を渡す形だけを受ける。for は、並べた語の数だけ回る。
  "ruby -v", "ruby --version", "ruby canary_begin.rb", "env ruby -c lib/median.rb", "ls | xargs ruby -c", "grep ruby in.txt",
  "find . -name x -exec ruby -c {} +", "for f in in.txt x; do cat in.txt; done",
  # awk は、pipe の無い program を受ける。zz の名前が無ければ、変数を読む形も受ける。
  "awk 'BEGIN { print 1 }'", "awk '{ print }' in.txt", %q(sort "${zz:--o}" out.txt in.txt; cat x),
  # 入れ子の shell の、command の文字列より後ろの option は、shell の option ではない。\; は find の終わりの印。
  "sh -c 'cat -n in.txt'", "bash -c 'uniq -c in.txt' && cat x", "zsh -lc 'tail -n 1 in.txt' 2>&1", "find . -name x -exec cat {} \\;",
  "cd lib", "pushd lib && cat median.rb", "cat x 2>/dev/null && cat x >&2",
  "sh -c cat -n in.txt", "sh -c 'cat x 2>&1 | wc -l'", "sh -c 'cat x' 2>&1",
  # 置き換えの中の書き込み (表の 3 つ目の形)。代入の語の全体が表の形と一致するときだけ受ける。
  %q(RANDOM='a[$(sort -o out.txt in.txt)1]'), %q(a=1; RANDOM='a[$(sort -o out.txt in.txt)1]'),
  %q(cat x; RANDOM='a[$(sort -o out.txt in.txt)1]' && cat x),
  # 番地の範囲を表示するだけの sed の script (表の 2 つ目)。
  "sed -n '/apple/,/banana/p' in.txt", %q(sh -c "sed -n '/apple/,/banana/p' in.txt"),
]
accept.each { |c| check "guard accepts #{c.inspect}: #{I.guard(c).inspect}", I.guard(c).nil? }

# guard が拒む形と理由。
reject = {
  # 設計と反証の形。
  "cd ./../marks && uniq - -c" => "dotdot", "cat a/../b" => "dotdot", "cat ../x" => "dotdot", "cat .." => "dotdot",
  "cat /etc/hosts" => "abs-path", "cat ~/x" => "tilde", "cat ~" => "tilde", "cat a~b" => "tilde", "cat $HOME/x" => "dollar",
  "tail -F x" => "tail-follow", "tail -f x" => "tail-follow", "tail -nF x" => "tail-follow", "tail -5f x" => "tail-follow",
  "tail --follow x" => "tail-follow", "tail +2f x" => "tail-follow", "xargs -p cat" => "xargs-tty", "xargs -o cat" => "xargs-tty",
  "find . -ok cat {} ;" => "find-ok", "find . -okdir cat {} ;" => "find-ok",
  "gh pr list" => "gh", "git remote" => "git-remote", "git remote -v" => "git-remote",
  # 引用と \ で字をつなぐ形 (原文には .. も tail も gh も無い)。
  "cd '.'./marks && uniq - -c" => "dotdot", "cat a/'.'./b" => "dotdot", "cd lib/'..'" => "dotdot", "cat .\\./x" => "dotdot",
  "ta''il -F x" => "tail-follow", "g''h pr list" => "gh", "cat a.\\\n." => "line-continuation",
  # / の前が名前の字でない形。
  "cat x >/x" => "abs-path", "cat </x" => "abs-path", "cat ''/etc" => "abs-path", "cat {x,}/etc" => "abs-path",
  "cat {a,b}/x" => "abs-path", "cat \"/etc/hosts\"" => "abs-path", "cat '/etc/hosts'" => "abs-path", "cat x\t/etc/hosts" => "abs-path",
  "cat a:/b" => "abs-path", "cat \\/etc/hosts" => "abs-path", "sort --output=/abs in.txt" => "abs-path",
  "x=/abs cat" => "abs-path", "cat x > /dev/null" => "abs-path", "cat x >/dev/nullx" => "abs-path", "cat x 2>/dev/null/x" => "abs-path",
  "sort $'-o'/abs in.txt" => "option-path",
  # 走るときに文字列を作る形 (backtick と括弧)。位置に依らない。括弧は、zsh の glob の修飾子 (親の dir を指せる) を含む。
  "cat `pwd`/x" => "backtick", "cd .`echo .` && cd .`echo .` && pwd && uniq - -c" => "backtick", "cat `echo x`" => "backtick",
  "cd x(:A:h:h:h) && pwd && uniq - -c" => "paren", "(cd lib; cat median.rb)" => "paren", "cat <(cat x)" => "paren",
  "cat '(x)'" => "paren", "cat x\\(:A:h\\)" => "paren",
  # && のほかの & (後ろで走らせる形、|&、表に無い fd への複製)。
  "cat in.txt &" => "ampersand", "uniq in.txt -c >/dev/null 2>&1 &" => "ampersand", "cat x & cat x" => "ampersand",
  "cat x |& cat" => "ampersand", "cat x >&3" => "ampersand", "cat x &&& cat x" => "ampersand", "coproc cat in.txt" => "background",
  # 安全な redirect は、後ろが空白か区切りのときだけ外す。引用の終わりに付いた形は外さない
  # (>/dev/null'x' は /dev/nullx を指すので、引用の字を区切りに数えない)。
  "sh -c 'cat x 2>&1'" => "ampersand", "sh -c 'cat x 2>/dev/null'" => "abs-path", "cat x >/dev/null'x'" => "abs-path",
  # 短い option に付いた path、zsh の =name、brace と glob が作る ..。
  "git -C/x status" => "option-path", "sort -o/abs in.txt" => "option-path", "cat =ls" => "equals-word",
  "echo ={cat,ruby}" => "equals-word", "uniq ={cat,canary}" => "equals-word", "cat ''=ls" => "equals-word", "cat x = y" => "equals-word",
  "cat .{.,a}" => "brace-dot", "cat {.,x}./y" => "brace-dot", "cat {a,}." => "brace-dot", "cat x/{..,y}" => "dotdot",
  "cat .{./x,y}" => "brace-dot", "cat {x/.,y}./z" => "brace-dot", "cat .{,a}." => "brace-dot", "cat .{a,,b}." => "brace-dot",
  "tail -{f,F} x" => "brace-glued", "xargs -{p,t} cat" => "brace-glued", "{ta,x}il -f x" => "brace-glued",
  "ta{il,x} -f x" => "brace-glued", "{g,x}{h,y} api" => "brace-glued", "tail '-'{f,F} x" => "brace-glued",
  "tail -{f,{F,x}} x" => "brace-glued",
  "cd .?/marks && uniq - -c" => "glob-dot", "cat .*" => "glob-dot", "cat ./.*/x" => "glob-dot", "cat '.'*" => "glob-dot",
  "cat .[.]/x" => "glob-dot",
  # 語の位置に依らない形 (前置き、xargs、find -exec、brace、入れ子の shell)。
  "xargs tail -f" => "tail-follow", "find . -exec tail -F {} +" => "tail-follow", "env tail -f x" => "tail-follow",
  "{tail,-f} x" => "tail-follow", "sh -c 'tail -f x'" => "tail-follow", "sh -c \"sh -c 'tail -f x'\"" => "tail-follow",
  "zsh -lc \"gh api x\"" => "gh", "git -C . remote show x" => "git-remote", "xargs -0p cat" => "xargs-tty",
  "xargs -n 1 -p cat" => "xargs-tty", "xargs -E eof -o cat" => "xargs-tty", "xargs -I {} -p cat {}" => "xargs-tty",
  "cd fx tools" => "cd-args", "builtin cd fx tools" => "cd-args", "pushd fx tools && pwd" => "cd-args",
  "chdir fx tools && pwd" => "cd-args", "popd fx tools" => "cd-args",
  # 引用の断片や \ をつないで出来る、入れ子の command (断片ごとに見ると漏れる)。
  "sh -c 'tail '\"-f x\"" => "tail-follow", "sh -c tail\\ -f\\ x" => "tail-follow", "sh -c 'g'\"h api x\"" => "gh",
  # shell の設定を変える形。job control を立てると、子が process group を抜ける。入れ子の shell の option は -c と -lc だけ。
  "set -m; cat x" => "shell-option", "set -o monitor; cat x" => "shell-option", "setopt monitor; cat x" => "shell-option",
  "cat x; set +m" => "shell-option", "shopt -s nullglob; cat x" => "shell-option", "emulate sh; cat x" => "shell-option",
  "unsetopt nomatch; cat x" => "shell-option", "dash -m x" => "shell-option", "ksh -i" => "shell-option",
  "sh -mc 'cat x'" => "shell-option", "bash -ic 'cat x'" => "shell-option", "sh -o monitor -c 'cat x'" => "shell-option",
  "sh -c -m 'cat x'" => "shell-option", "zsh +m -c 'cat x'" => "shell-option", "env bash -i" => "shell-option",
  "sh -c 'set -m; cat x'" => "shell-option", "sh -c set\\ -m" => "shell-option", "eval 'se''t -m'" => "shell-option",
  "s''et -m" => "shell-option", "find . -exec sh -c 'cat x' \\; -exec sh -m x \\;" => "shell-option",
  "SHELLOPTS=monitor sh -c 'cat x'" => "shell-option", "env SHELL''OPTS=monitor sh -c 'cat x'" => "shell-option",
  "export BASHOPTS; cat x" => "shell-option",
  # 外の process への signal。
  "kill -9 -1" => "signal", "echo 1 | xargs kill" => "signal", "sh -c 'kill -0 1'" => "signal", "killall zsh" => "signal",
  "pkill -f x" => "signal",
  # ruby に code を渡す形 (code は、止める対象の process group から抜けられる)。前に = や ! が付いた名前も ruby として見る。
  %q(ruby -e 'Process.setsid; sleep 999'; :) => "ruby-form", %q(ruby -e 'puts [1, 2].sum') => "ruby-form", "ruby" => "ruby-form",
  "cat x | ruby" => "ruby-form", "ruby -v -e 1" => "ruby-form", "ruby -rsocket lib/median.rb" => "ruby-form", "ruby -c -e 1" => "ruby-form",
  "env ruby -e 1" => "ruby-form", %q(sh -c "ruby -e 1") => "ruby-form", "find . -name x -exec ruby -e 1 {} +" => "ruby-form",
  %q(git -c alias.x='!ruby -e 1' x) => "ruby-form", "X=ruby -e 1" => "ruby-form", "ruby -W0 lib/median.rb" => "ruby-form",
  # 終わりを条件に任せる loop (文字列で見える、終わらない形)。
  "while :; do :; done" => "loop", "until false; do :; done" => "loop", "cat x; while true; do cat x; done" => "loop",
  "sh -c 'while :; do :; done'" => "loop", "wh''ile :; do :; done" => "loop",
  # 受けた $ の形が読む変数の名前が、command のほかの所に出る形 (設定されると、展開の後の語が変わる)。
  %q(zz=-f; tail "${zz:--o}" in.txt) => "dollar-variable", %q(export zz=-f; tail "${zz:--o}" in.txt) => "dollar-variable",
  %q(read zz; sort "${zz:--o}" out.txt in.txt) => "dollar-variable", %q(z''z=-f; tail "${zz:--o}" in.txt) => "dollar-variable",
  %q(for zz in -f; do tail "${zz:--o}" in.txt; done) => "dollar-variable",
  %q(env zz=-f sh -c 'tail "${zz:--o}" in.txt') => "dollar-variable", %q(sort "${zz:--o}" out.txt zz) => "dollar-variable",
  # awk の program の中の pipe (command を起動する。文字列は program の中でつないで作れる)。
  %q(awk 'BEGIN { "ru" "by -e 1" | getline x; print x }') => "awk-pipe", %q(awk 'BEGIN { print 1 | "cat" }') => "awk-pipe",
  %q(env awk '{ print | "cat" }' in.txt) => "awk-pipe", %q(X=awk 'BEGIN { "x" | getline }') => "awk-pipe",
  # 例外の $ の形は、展開した後の語として、ほかの規則に掛かる。
  %q(xargs "${zz:--o}" cat) => "xargs-tty", "xargs $'-o' cat" => "xargs-tty", %q(sh -c 'xargs "${zz:--o}" cat') => "xargs-tty",
  # 置き換えの中の書き込みの形と 1 字でも違う形は、表に無い $ として拒む (中の command、変数の名前、引用の種類、位置)。
  %q(RANDOM='a[$(sort -o lib/p in.txt)1]') => "dollar", %q(RANDOM='a[$(uniq in.txt out.txt)1]') => "dollar",
  %q(COLUMNS='a[$(sort -o out.txt in.txt)1]') => "dollar", %q(RANDOM="a[$(sort -o out.txt in.txt)1]") => "dollar",
  %q(RANDOM='b[$(sort -o out.txt in.txt)1]') => "dollar", %q(RANDOM='a[$(sort -o out.txt in.txt)]') => "dollar",
  %q(cat "$(sort -o out.txt in.txt)") => "dollar", %q(echo 'a[$(sort -o out.txt in.txt)1]') => "dollar",
  # 受けた形の外は、ほかの規則がそのまま見る。
  %q(cat ../x; RANDOM='a[$(sort -o out.txt in.txt)1]') => "dotdot", %q(RANDOM='a[$(sort -o out.txt in.txt)1]' cat /etc/hosts) => "abs-path",
  # 表に無い $ と、読めない形。
  "echo $(touch x)" => "dollar", "sort $'-O' out.txt in.txt" => "dollar", "sort \"${zz:-/x}\" in.txt" => "dollar",
  "" => "empty", "  " => "empty", "cat 'x" => "unbalanced-quote", "cat \u3042" => "non-ascii-or-control", "cat a\u0001b" => "non-ascii-or-control",
}
reject.each { |c, why| check "guard rejects #{c.inspect} as #{why}: #{I.guard(c).inspect}", I.guard(c) == why }
check "guard rejects a non-string", I.guard(nil) == "not-a-string"
check "guard: the safe redirects are the seven of the classifier gate",
      I::SAFE_REDIRECTS.sort == ["&>/dev/null", "1>&2", "1>/dev/null", "2>&1", "2>/dev/null", ">&2", ">/dev/null"]
# sed と awk の script の表は、単一引用の語の完全一致だけを外す。
check "guard: a script outside the table is rejected", I.guard("sed -n '/x/p' in.txt") == "abs-path"
check "guard: a script in the table is accepted", I.guard("sed -n '/x/p' in.txt", scripts: ["/x/p"]).nil?
# 表の script に続きを足した語と、引用の外の同じ字は、外さない (続きの側に絶対 path の無い形で見る)。
check "guard: the table matches the whole quoted word", I.guard("sed -n '/x/p;w out' in.txt", scripts: ["/x/p"]) == "abs-path"
check "guard: the table does not match outside the quotes", I.guard("sed -n /x/p in.txt", scripts: ["/x/p"]) == "abs-path"
check "guard: the rest of the command is still checked", I.guard("sed -n '/x/p' ../in.txt", scripts: ["/x/p"]) == "dotdot"
check "guard: the dollar table is closed", I.guard("sort $'-o' out.txt in.txt", dollar_forms: {}) == "dollar"
# 表は、形から「展開した後の語」。3 つ目だけは語に展開されないので、中で走る command を値に持つ。
substitution = %q(RANDOM='a[$(sort -o out.txt in.txt)1]')
check "guard: the dollar table maps each form to the word it expands to, or to the command it runs",
      I::DOLLAR_FORMS == { "$'-o'" => "-o", '"${zz:--o}"' => "-o", substitution => "sort -o out.txt in.txt" }
check "guard: the substitution form is accepted through the table only", I.guard(substitution, dollar_forms: {}) == "dollar"
# 値の command に、ほかの規則が当たる (値が外を指す形なら、受けた形ごと拒む)。
check "guard: the command a form runs is checked by the other rules",
      I.guard(substitution, dollar_forms: { substitution => "sort -o ../out.txt in.txt" }) == "dotdot" &&
      I.guard(substitution, dollar_forms: { substitution => "tail -f in.txt" }) == "tail-follow"
check "guard: the script table is the two checked scripts", I::SCRIPT_TABLE == ['/a\/,/w lib/p', "/apple/,/banana/p"]
check "guard: a script of the table with more after it is rejected", I.guard("sed -n '/apple/,/banana/p;w out' in.txt") == "abs-path"

# run_command は、guard が拒んだ command を走らせず、一時 dir も作らない。
before = Dir.children(session.root).sort
rejected = begin
  session.run_command("cat /etc/hosts")
  nil
rescue I::Rejected => e
  e.reason
end
check "run_command raises Rejected with the reason", rejected == "abs-path"
check "run_command creates nothing for a rejected command", Dir.children(session.root).sort == before
check "run_command refuses an unknown variant", raised.call { session.run_command("cat in.txt", variant: "dash") }

# 出力の path の置き換え。
home = session.deny_read.first
text = "a #{layout.base}/fx b #{layout.alias_base}/fx c #{session.root} d #{home}/z e \xff".b
check "redact: temp dir and HOME paths are replaced", session.redact(text, layout) == "a <T>/fx b <T>/fx c <R> d <HOME>/z e ?"

# preflight の結論。通らない検査が 1 つでもあれば ok は false で、理由に検査の名前が出る (path は置き換える)。
passing = I::Check.new(name: "write-outside", ok: true, negative: {}, control: {})
failing = I::Check.new(name: "network", ok: false, negative: { connected: true, at: "#{layout.base}/fx" }, control: { connected: true })
concluded = I.conclude(session, [passing, failing], layout)
check "conclude: one failed check fails the preflight: #{concluded.ok.inspect}",
      concluded.ok == false && concluded.unavailable == false && concluded.checks == [passing, failing]
check "conclude: the reason names the check and carries no temp dir path: #{concluded.reasons.inspect}",
      concluded.reasons.length == 1 && concluded.reasons[0].start_with?("network: negative=") &&
      concluded.reasons[0].include?("<T>/fx") && !concluded.reasons[0].include?(layout.base)
all_passing = I.conclude(session, [passing])
check "conclude: every check passing is ok", all_passing.ok == true && all_passing.reasons.empty? && all_passing.unavailable == false

# group の空の確かめ。生きている group は「空でない」、終わった group は「空」。
group = I.live_group_control
check "group_empty?: a live group is not reported empty", group[:live_reported_empty] == false
check "group_empty?: an exited group is reported empty", group[:exited_reported_empty] == true
check "group_empty?: an unknown pid is not confirmed", I.group_empty?(nil) == false && I.group_empty?(1) == false

# sandbox を適用できない回だけを skip の対象にする。profile の誤りは失敗にする。
failed_run = ->(err) { I::Run.new(err: err, sandbox_error: true, exit_code: 71) }
check "sandbox_unavailable?: a refused sandbox_apply", I.sandbox_unavailable?(failed_run.call("sandbox-exec: sandbox_apply: Operation not permitted\n"))
check "sandbox_unavailable?: a profile error is not a skip", !I.sandbox_unavailable?(failed_run.call("sandbox-exec: syntax error\n"))

# cleanup は、session が作った一時 dir だけを消す。
session.cleanup(I::Layout.new(root: tmp, base: tmp, alias_base: tmp))
check "cleanup ignores a dir the session did not create", File.directory?(tmp)
session.cleanup(layout)
check "cleanup removes the layout", !File.exist?(layout.base)
session.close
check "close leaves a given root in place and empty", Dir.children(File.join(tmp, "t1")).empty?

# root を省くと、session が一時 dir の置き場を自分で作り、close で消す。
own_tmp = File.join(tmp, "own")
Dir.mkdir(own_tmp)
I.with_parent_env("TMPDIR" => own_tmp) do
  own = I::Session.open
  check "session without a root: makes its own under TMPDIR: #{own.problems.inspect}",
        own.problems.empty? && File.dirname(own.root) == own_tmp && File.directory?(own.root)
  own.new_layout("pci-")
  own.close
  check "session without a root: close removes it", Dir.children(own_tmp).empty?
end

# 隔離を組めないとき (一時 dir が HOME の下) は、理由を返し、何も走らせない。
fake_home = File.join(tmp, "fake-home")
Dir.mkdir(fake_home)
Dir.mkdir(File.join(fake_home, "under"))
I.with_parent_env("HOME" => fake_home) do
  under = I::Session.open(root: File.join(fake_home, "under"))
  check "setup: a temp root under HOME is a problem", under.problems.include?("the temp root is under the real HOME")
  # HOME を別の所に向けても、passwd の HOME (本物) は読み取りを拒む一覧に残る。
  check "setup: the passwd HOME stays read-denied when HOME points elsewhere: #{under.deny_read.length}",
        under.deny_read.include?(File.realpath(Etc.getpwuid(Process.uid).dir)) && under.deny_read.include?(File.realpath(fake_home))
  pre = I.preflight(under)
  check "preflight: setup problems fail without launching", pre.ok == false && pre.unavailable == false && pre.checks.empty? &&
                                                            pre.reasons == under.problems && Dir.children(File.join(fake_home, "under")).empty?
end

exit(@failed.zero? ? 0 : 1)
RUBY
echo "ok T1 (isolation: profile, env, tables, guard)"

# --- T2: 隔離 (sandbox の要る部分) -----------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$isolation" "$tmp" <<'RUBY'
require ARGV[0]
tmp = File.realpath(ARGV[1])
I = ProbeClassifier::Isolation

Dir.mkdir(File.join(tmp, "t2"))
session = I::Session.open(root: File.join(tmp, "t2"))
pre = I.preflight(session)
if pre.unavailable
  if ENV["GITHUB_ACTIONS"] == "true"
    warn "FAIL: T2: sandbox-exec must be usable on CI: #{pre.reasons.join('; ')}"
    exit 1
  end
  # sandbox の要る部分 (T2・T4・T6) を skip する印。後ろの部分は、この印だけを見る (自分で判断し直さない)。
  File.write(File.join(tmp, "sandbox-unavailable"), "")
  puts "skip T2, T4, T6: #{pre.reasons.join('; ')}"
  exit 0
end

# preflight の検査を、検査が見た生の事実で確かめる (ok の自己申告だけに頼らない)。
check "preflight passes: #{pre.reasons.inspect}", pre.ok
# 検査まで届かなかった回 (template を作れない、など) は、ここで止める。
exit 1 if pre.checks.empty?
by = pre.checks.map { |c| [c.name, c] }.to_h
check "preflight runs every check", by.keys == %w[write-outside read-home network exec-outside exec-fixture exec-unlisted
                                                  signal-outside env-closed timeout-group guard-only-write tools-work]
c = by.fetch("write-outside")
check "write outside the temp dir is denied", c.negative[:written] == false && c.negative[:exit] != 0
check "write outside: the control writes", c.control[:written] == true && c.control[:exit] == 0
c = by.fetch("read-home")
check "reading the HOME stand-in is denied", c.negative[:read] == false && c.negative[:exit] != 0
check "read HOME: the control reads", c.control[:read] == true && c.control[:exit] == 0
c = by.fetch("network")
check "connecting to 127.0.0.1 is denied", c.negative[:connected] == false && c.negative[:exit] != 0
check "network: the control connects", c.control[:connected] == true && c.control[:exit] == 0
c = by.fetch("exec-outside")
check "a fake CLI outside the allowlist does not run (absolute path and PATH)",
      c.negative[:ran] == false && c.negative[:abs][:exit] == 126 && c.negative[:path][:exit] == 126 &&
      [c.negative[:abs][:err], c.negative[:path][:err]].all? { |e| e.match?(/operation not permitted/i) }
check "exec outside: the control runs", c.control[:ran] == true && c.control[:exit] == 0
c = by.fetch("exec-fixture")
check "an executable in the fixture that is not a canary does not run",
      c.negative[:ran] == false && c.negative[:exit] == 127 && c.negative[:err].match?(/operation not permitted/)
check "exec fixture: the control runs", c.control[:ran] == true && c.control[:exit] == 0
c = by.fetch("exec-unlisted")
check "an unlisted program is denied in sh, bash and zsh, with a distinguishable ending",
      c.negative.keys == %w[zsh bash sh] && c.negative["zsh"][:exit] == 127 && c.negative["bash"][:exit] == 126 &&
      c.negative["sh"][:exit] == 126 && c.negative.values.all? { |f| f[:err].match?(/operation not permitted/i) }
check "exec unlisted: the control runs in each shell", c.control.keys == %w[zsh bash sh] && c.control.values.all? { |f| f[:exit] == 0 }
c = by.fetch("signal-outside")
check "a signal to a process outside the sandbox is denied", c.negative[:exit] == 1 && c.negative[:err].match?(/operation not permitted/i)
check "signal: the control reaches the runner", c.control[:exit] == 0
c = by.fetch("env-closed")
check "the parent env does not reach the child", c.negative[:extra] == [] && c.negative[:exit] == 0
check "env: the control inherits", c.control[:leaked] == true
c = by.fetch("timeout-group")
check "a command that does not end is stopped and leaves no group member",
      c.negative[:timed_out] == true && c.negative[:group_empty] == true && c.negative[:exit].nil? && c.negative[:in_time] == true
check "timeout: the control ends in time, and a live group is not reported empty",
      c.control[:timed_out] == false && c.control[:exit] == 0 && c.control[:group_empty] == true &&
      c.control[:live_reported_empty] == false && c.control[:exited_reported_empty] == true
c = by.fetch("guard-only-write")
check "without the sandbox, a write in the vocabulary stays in the temp dir",
      c.negative[:guard].nil? && c.negative[:inside] == true && c.negative[:outside_changed] == false && c.negative[:exit] == 0
c = by.fetch("tools-work")
check "the listed tools run in isolation", c.negative.keys == ["cat in.txt", "git status --short", "ruby -c lib/median.rb",
                                                              "zsh -lc 'cat in.txt'", "canary"] &&
                                           c.negative.values.all? { |f| f[:exit] == 0 } &&
                                           c.negative["git status --short"][:out].start_with?(" M README.md\n") &&
                                           c.negative["ruby -c lib/median.rb"][:out] == "Syntax OK\n" &&
                                           c.negative["zsh -lc 'cat in.txt'"][:out] == c.negative["cat in.txt"][:out] &&
                                           c.negative["canary"][:hits] == ["shim.canary"]
home = session.deny_read.first
check "preflight results carry no temp dir or HOME path", [pre.checks.inspect, pre.reasons.inspect].none? { |s| s.include?(session.root) || s.include?(home) }
check "preflight cleans up its temp dirs", Dir.children(session.root).all? { |n| n.start_with?("pci-template-") }

# 道具が拒否の字面を stderr に出す回は、0 で終わっていても通さない (その道具を使う read の command が、毎回
# 「拒まれた起動」として人に出るため)。git の起動にだけ、拒否の字面を 1 行足して見る。対照は、足さない同じ検査。
quiet_layout = session.prepare
quiet = I.check_tools_work(session, quiet_layout)
session.cleanup(quiet_layout)
noisy_layout = session.prepare
session.define_singleton_method(:launch) do |l, command, **opts|
  run = super(l, command, **opts)
  run.err = "#{run.err}git: error: could not write a cache file (errno=Operation not permitted)\n" if command.start_with?("git ")
  run
end
begin
  noisy = I.check_tools_work(session, noisy_layout)
ensure
  session.singleton_class.send(:remove_method, :launch)
  session.cleanup(noisy_layout)
end
check "a listed tool that prints a denial fails the tools-work check: #{quiet.ok.inspect} #{noisy.ok.inspect}",
      quiet.ok == true && noisy.name == "tools-work" && noisy.ok == false &&
      noisy.negative["git status --short"][:exit] == 0 && noisy.negative["git status --short"][:out] == quiet.negative["git status --short"][:out]

# 検査は、拒否が効いていない profile を見逃さない。session の profile を 1 か所ずつ緩め、その検査が通らないことを見る
# (検査が ok を自己申告だけで true にしていないことの確かめ)。緩めるのは、この test の一時 dir の中の代役に対してだけ。
weak_outside = File.realpath(Dir.mktmpdir("pci-outside-", session.root))
weak_layout = session.prepare
weakened = lambda do |change, &probe|
  session.define_singleton_method(:profile_for) { |l, **kw| super(l, **change.call(kw)) }
  begin
    probe.call
  ensure
    session.singleton_class.send(:remove_method, :profile_for)
  end
end
{
  "write-outside" => [->(kw) { kw.merge(allow_write: [weak_outside]) }, -> { I.check_write_outside(session, weak_layout, weak_outside) }],
  "read-home" => [->(kw) { kw.merge(deny_read_extra: []) }, -> { I.check_read_home(session, weak_layout, weak_outside) }],
  "network" => [->(kw) { kw.merge(network: true) }, -> { I.check_network(session, weak_layout) }],
  "exec-outside" => [->(kw) { kw.merge(exec_extra: [File.join(weak_outside, "fakecli")]) },
                     -> { I.check_exec_outside(session, weak_layout, weak_outside) }],
  "exec-fixture" => [->(kw) { kw.merge(exec_extra: [File.join(weak_layout.fx, "notcanary")]) }, -> { I.check_exec_fixture(session, weak_layout) }],
  "exec-unlisted" => [->(kw) { kw.merge(exec_extra: [I::UNLISTED_PROGRAM]) }, -> { I.check_exec_unlisted(session, weak_layout) }],
  "signal-outside" => [->(kw) { kw.merge(signals: true) }, -> { I.check_signal_outside(session, weak_layout) }],
}.each do |name, (change, probe)|
  weak = weakened.call(change, &probe)
  check "a profile that does not deny fails the #{name} check: #{weak.ok.inspect}", weak.name == name && weak.ok == false
end
check "the weakened profile is gone after the checks", session.profile_for(weak_layout).include?("(deny network*)")
session.cleanup(weak_layout)
FileUtils.rm_rf(weak_outside)

# 1 件の command を走らせる入口。block には走らせる前の layout が渡り、command ごとに新しい一時 dir になる。
# run_command は、検査した profile と閉じた環境のまま走らせる (起動に profile や環境の上書きを渡さない)。
launch_opts = []
session.define_singleton_method(:launch) do |l, command, **opts|
  launch_opts << opts
  super(l, command, **opts)
end
seen_before = nil
first = session.run_command("sort -o out.txt in.txt") { |l| seen_before = File.exist?(File.join(l.fx, "out.txt")) }
session.singleton_class.send(:remove_method, :launch)
check "run_command passes no profile or env override to the launch: #{launch_opts.map(&:keys).inspect}",
      launch_opts.map { |o| o.keys.sort } == [%i[timeout variant]]
check "run_command yields the layout before the launch", seen_before == false && File.file?(File.join(first.layout.fx, "out.txt"))
check "run_command returns how the command ended",
      first.exit_code == 0 && first.signal.nil? && first.timed_out == false && first.group_empty == true &&
      first.sandbox_error == false && first.variant == "zsh" && first.command == "sort -o out.txt in.txt"
second = session.run_command("ls; pwd; env; git log --oneline | wc -l; uniq -c in.txt; cat x")
check "each command gets a new temp dir", second.layout.base != first.layout.base && !second.out.lines.include?("out.txt\n")
out = second.out.lines.map(&:chomp)
check "the fixture: files and canaries", (%w[README.md in.txt x lib cat bin canary_begin.rb] - out).empty?
check "the fixture: the scene dirs", (%w[pair plain pre sortopt] - out).empty?
check "the fixture: two commits, repeated lines in in.txt, the sed subject in x",
      out.any? { |l| l.strip == "2" } && out.any? { |l| l.match?(/\A\s*2 apple\z/) } && out.include?("a/,")
check "the child env points into the temp dir, with paths replaced in the output",
      out.include?("<T>/fx") && out.include?("HOME=<T>/home") && out.include?("TMPDIR=<T>/tmp") &&
      out.include?("PATH=<T>/shim:<T>/tools") && !second.out.include?(session.root) && !second.out.include?(home)

# fixture の git は、user の global と system の設定を読まない。親の GIT_DIR なども渡らない。
leaked = nil
I.with_parent_env("RIPGREP_CONFIG_PATH" => "/nonexistent/rg.conf", "GIT_DIR" => "/nonexistent/git-dir",
                  "GIT_CONFIG_GLOBAL" => "/nonexistent/gitconfig", "PAGER" => "false") do
  Dir.mkdir(File.join(tmp, "t2-env"))
  other = I::Session.open(root: File.join(tmp, "t2-env"))
  leaked = other.run_command("env; git status --short; git config --list --show-scope")
  other.close
end
keys = leaked.out.lines.map { |l| l.split("=", 2).first }
check "variables set in the parent do not reach the child", (keys & %w[RIPGREP_CONFIG_PATH GIT_DIR PAGER]).empty? &&
                                                           leaked.out.include?("GIT_CONFIG_GLOBAL=/dev/null\n")
check "git works under a hostile parent env (template and command)", leaked.exit_code == 0 && leaked.out.include?(" M README.md\n")
# scene の file は最初の commit に入っている (追跡していない file として出るのは、canary だけ)。
check "the scene files are tracked: #{leaked.out.lines.grep(/\A\?\? /).inspect}",
      leaked.out.lines.grep(/\A\?\? /).map(&:chomp) == ["?? bin/", "?? canary_begin.rb", "?? cat"]
scopes = leaked.out.lines.select { |l| l.match?(/\A[a-z]+\t/) }.map { |l| l.split("\t").first }.uniq
check "git reads only the repository's own config: #{scopes.inspect}", scopes == ["local"]

# 変種ごとの shell の設定。
variants = {
  "zsh" => ["echo nomatch*zz", ->(r) { r.exit_code == 1 && r.err.include?("no matches found") }],
  "zsh-nullglob" => ["echo nomatch*zz", ->(r) { r.exit_code == 0 && r.out == "\n" }],
  "bash" => ["echo nomatch*zz", ->(r) { r.exit_code == 0 && r.out == "nomatch*zz\n" }],
  "bash-nullglob" => ["echo nomatch*zz", ->(r) { r.exit_code == 0 && r.out == "\n" }],
  "sh" => ["echo nomatch*zz", ->(r) { r.exit_code == 0 && r.out == "nomatch*zz\n" }],
  "zsh-extendedglob" => ["echo ^in.txt", ->(r) { r.exit_code == 0 && r.out.include?("README.md") && !r.out.include?("in.txt") }],
}
layout = session.prepare
# scene の file は、表の中身のまま、command ごとの一時 dir にある (- で始まる名前を含む)。
check "the scene files are in each command's temp dir, with the fixed mtime",
      I::FIXTURE_SCENES.all? { |rel, body| File.read(File.join(layout.fx, rel)) == body && File.mtime(File.join(layout.fx, rel)) == I::FIXTURE_MTIME }
# fixture の中の実行できる file は canary だけ (git init が置く hook の見本を残さない)。
executables = Dir.glob(File.join(layout.fx, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) && File.executable?(p) }
check "the fixture has no executable file other than the canaries: #{executables.length}",
      executables.map { |p| p.sub("#{layout.fx}/", "") }.sort == %w[bin/grep cat]
check "the fixture files keep the fixed mtime in each command's temp dir",
      %w[README.md in.txt x lib/median.rb].all? { |f| File.mtime(File.join(layout.fx, f)) == I::FIXTURE_MTIME }
variants.each do |name, (command, want)|
  run = session.launch(layout, command, variant: name)
  check "variant #{name}: #{run.exit_code.inspect} #{run.out.inspect} #{run.err.inspect}", want.call(run) && run.variant == name
end
plain = session.launch(layout, "echo ^in.txt")
check "variant zsh: ^ is literal without extendedglob", plain.out == "^in.txt\n"
# 子の stdin は /dev/null (pipe ではない)。
stdin = session.launch(layout, "[ -c /dev/stdin ] && echo chardev; [ -p /dev/stdin ] && echo pipe; cat", variant: "sh")
check "the child's stdin is /dev/null: #{stdin.out.inspect}", stdin.out == "chardev\n" && stdin.exit_code == 0

# canary。走ると印が書かれ、どの canary かが印から分かる。予約語の名前の canary は、後ろの語を走らせない。
# 新しい script の初めての起動は遅い (1 つ 0.3 秒ほど。混んだ machine では数倍)。6 つ続けるので、期限を長く取る。
canaries = session.run_command("./cat x; bin/grep a in.txt; ruby canary_begin.rb; env done rm x; 'fi' rm x; codex exec hi", timeout: 30)
marks = I.read_marks(canaries.layout)
check "canaries write marks by id: #{marks.inspect} #{canaries.err.inspect}",
      marks.hits == { "fx.cat" => 1, "fx.bin-grep" => 1, "fx.canary-begin" => 1, "word.done" => 1, "word.fi" => 1, "cli.codex" => 1 } &&
      marks.stray.empty?
check "a reserved-word canary runs instead of the words after it", File.file?(File.join(canaries.layout.fx, "x"))

# login の shell が PATH を組み直しても、表に無い program は起動できない。見つからない名前とは終わり方で見分けられる。
denied = session.launch(layout, "zsh -lc 'date'")
missing = session.launch(layout, "date")
check "an unlisted program found through a login shell's PATH is denied", I.denied_exec?(denied) && denied.out.empty?
check "a name that is not on PATH ends as not found, not as denied", missing.exit_code == 127 && !I.denied_exec?(missing) &&
                                                                     missing.err.include?("command not found")

[first, second, canaries].each { |r| session.cleanup(r.layout) }
session.cleanup(layout)
check "cleanup removes each command's temp dir", [first, second, canaries].none? { |r| File.exist?(r.layout.base) }
session.close
check "close removes the template", Dir.children(File.join(tmp, "t2")).empty?

exit 1 unless @failed.zero?
puts "ok T2 (isolation: sandbox)"
RUBY

sandbox=yes
[ ! -f "$tmp/sandbox-unavailable" ] || sandbox=no

# --- T3: 判定 (sandbox の要らない部分) ---------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$judge" "$tmp" <<'RUBY'
require "digest"
require "fileutils"
require ARGV[0]
tmp = File.realpath(ARGV[1])
I = ProbeClassifier::Isolation
J = ProbeClassifier::Judge

# 1 つの tree を手で変え、差分が種類ごとに出ることを見る。前の時刻を固定し、変えた所だけが別の時刻になるようにする。
base = File.join(tmp, "t3")
outside = File.join(tmp, "t3-outside")
old = Time.at(1_700_000_000)
put = lambda do |rel, body|
  path = File.join(base, rel)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
  path
end
I::ZONES.each { |z| FileUtils.mkdir_p(File.join(base, z)) }
%w[keep.txt content.txt same-size.txt mode.txt touched.txt replaced.txt gone.txt type secret.txt sub/keep.txt
   quiet/keep.txt moded/keep.txt churn/keep.txt].each { |rel| put.call("fx/#{rel}", "body of #{File.basename(rel)}\n") }
fx = File.join(base, "fx")
Dir.mkdir(File.join(fx, "redone"))
File.chmod(0o644, File.join(fx, "mode.txt"), File.join(fx, "secret.txt"))
File.chmod(0o755, File.join(fx, "moded"))
File.symlink("keep.txt", File.join(fx, "link"))
File.mkfifo(File.join(fx, "fifo"))
FileUtils.mkdir_p(outside)
File.write(File.join(outside, "secret"), "outside\n")
File.symlink(outside, File.join(fx, "outlink"))
put.call("shim/canary", "#!/bin/sh\n")
File.symlink("/bin/cat", File.join(base, "tools/cat"))
Dir.glob(File.join(base, "**", "*")).each { |p| File.symlink?(p) ? File.lutime(old, old, p) : File.utime(old, old, p) }
# . で始まる名前 (.git の中など) も snapshot に入る。
put.call("fx/.git/index", "index 1\n")
put.call("fx/.git/refs/heads/main", "ref\n")

before = J.snapshot(base)
keep = before["fx/keep.txt"]
check "snapshot: a regular file has its type, size, mtime and content hash",
      keep.type == "file" && keep.size == 17 && keep.mtime == [old.to_i, 0] && keep.ino.is_a?(Integer) &&
      keep.sha256 == Digest::SHA256.hexdigest("body of keep.txt\n") && keep.target.nil?
check "snapshot: mode bits", before["fx/mode.txt"].mode == 0o644 && before["fx/moded"].mode == 0o755
check "snapshot: directories are entries too, zone roots included", before["fx"].type == "dir" && before["marks"].type == "dir" && before["fx/sub"].type == "dir"
check "snapshot: a symlink is recorded by its target and not read", before["fx/link"].type == "symlink" && before["fx/link"].target == "keep.txt" &&
                                                                   before["fx/link"].sha256.nil? && before["tools/cat"].target == "/bin/cat"
check "snapshot: a symlink to a directory is not followed", before["fx/outlink"].type == "symlink" && before.keys.none? { |k| k.start_with?("fx/outlink/") }
check "snapshot: a FIFO is recorded without being opened", before["fx/fifo"].type == "other" && before["fx/fifo"].sha256.nil?
check "snapshot: paths are relative to the temp dir", before.keys.none? { |k| k.start_with?("/") } && before.key?("shim/canary")
check "snapshot: names that start with a dot are included", before["fx/.git"].type == "dir" && before["fx/.git/index"].type == "file"
check "diff: an unchanged tree has no changes", J.diff(before, J.snapshot(base)).empty?

File.write(File.join(fx, "content.txt"), "a longer body than before\n")
same = File.join(fx, "same-size.txt")
File.write(same, File.read(same).tr("b", "B"))
File.utime(old, old, same)
File.chmod(0o600, File.join(fx, "mode.txt"))
# 秒より細かい所だけが違う時刻 (mtime はナノ秒まで比べる)。
half = Time.at(old.to_i, 500_000)
File.utime(half, half, File.join(fx, "touched.txt"))
replaced = File.join(fx, "replaced.txt")
File.write("#{replaced}.new", File.read(replaced))
File.utime(old, old, "#{replaced}.new")
File.rename("#{replaced}.new", replaced)
File.delete(File.join(fx, "gone.txt"))
put.call("fx/new.txt", "new\n")
put.call("fx/-c", "")
File.delete(File.join(fx, "type"))
Dir.mkdir(File.join(fx, "type"))
# dir を消して、同じ名前、同じ時刻で作り直す (種類も mtime も同じで、実体だけが別)。
Dir.rmdir(File.join(fx, "redone"))
Dir.mkdir(File.join(fx, "redone"))
File.utime(old, old, File.join(fx, "redone"))
# 先の名前の長さは同じ (size では見分けられない)。
File.delete(File.join(fx, "link"))
File.symlink("mode.txt", File.join(fx, "link"))
File.write(File.join(fx, ".git/index"), "index 2\n")
put.call("fx/.git/refs/heads/x", "ref\n")
File.chmod(0o000, File.join(fx, "secret.txt"))
put.call("fx/sub/new.txt", "x")
File.utime(old + 60, old + 60, File.join(fx, "quiet"))
File.chmod(0o700, File.join(fx, "moded"))
File.delete(put.call("fx/churn/t", ""))
put.call("marks/fx.cat.123", "")
put.call("marks/word.done.7", "")
put.call("marks/note.txt", "x")
Dir.mkdir(File.join(base, "marks/cli.codex.5"))
put.call("home/.cache/x", "x")
File.delete(put.call("tmp/sort.tmp", ""))
put.call("stray.txt", "x")
File.delete(File.join(base, "tools/cat"))
File.symlink("/bin/ls", File.join(base, "tools/cat"))

after = J.snapshot(base)
changes = J.diff(before, after)
# root で走ると mode 000 の file も読めるので、中身の違いは出ない。
secret = Process.uid.zero? ? ["mode"] : %w[content mode]
expected = {
  "fx" => ["dir-mtime"], "fx/-c" => ["created"], "fx/.git/index" => ["content"], "fx/.git/refs/heads" => ["dir-mtime"],
  "fx/.git/refs/heads/x" => ["created"], "fx/churn" => ["dir-mtime"], "fx/content.txt" => ["content"],
  "fx/gone.txt" => ["deleted"], "fx/link" => ["content"], "fx/mode.txt" => ["mode"], "fx/moded" => ["mode"],
  "fx/new.txt" => ["created"], "fx/quiet" => ["dir-mtime"], "fx/redone" => ["rewrite"], "fx/replaced.txt" => ["rewrite"],
  "fx/same-size.txt" => ["content"], "fx/secret.txt" => secret, "fx/sub" => ["dir-mtime"], "fx/sub/new.txt" => ["created"],
  "fx/touched.txt" => ["rewrite"], "fx/type" => ["type"], "home" => ["dir-mtime"], "home/.cache" => ["created"],
  "home/.cache/x" => ["created"], "marks" => ["dir-mtime"], "marks/cli.codex.5" => ["created"],
  "marks/fx.cat.123" => ["created"], "marks/note.txt" => ["created"], "marks/word.done.7" => ["created"],
  "stray.txt" => ["created"], "tmp" => ["dir-mtime"], "tools" => ["dir-mtime"], "tools/cat" => ["content"]
}
got = changes.map { |c| [c.path, c.kinds] }.to_h
expected.each { |path, kinds| check "diff: #{path} is #{kinds.inspect}: #{got[path].inspect}", got[path] == kinds }
check "diff: nothing else changed: #{(got.keys - expected.keys).inspect}", (got.keys - expected.keys).empty?
check "diff: changes come sorted by path", changes.map(&:path) == expected.keys.sort
check "diff: the kinds are the closed list", J::KINDS == %w[created deleted type content mode rewrite dir-mtime]
zones = changes.map { |c| [c.path, c.zone] }.to_h
check "diff: zones", zones["fx"] == "fx" && zones["fx/-c"] == "fx" && zones["home/.cache/x"] == "home" && zones["marks/note.txt"] == "marks" &&
                     zones["tmp"] == "tmp" && zones["tools/cat"] == "tools" && zones["stray.txt"] == "base"
check "diff: a dir mtime with no created, deleted or replaced child is unexplained",
      J.unexplained_dir_mtimes(changes).map(&:path) == %w[fx/churn fx/quiet tmp]

fake = lambda do |**kw|
  I::Run.new(**{ variant: "zsh", command: "x", exit_code: 0, timed_out: false, out: "", err: "", group_empty: true, drained: true,
                 sandbox_error: false }.merge(kw))
end
verdict = J.judge(before: before, after: after, run: fake.call)
fx_paths = expected.select { |path, kinds| path.start_with?("fx/") && kinds != ["dir-mtime"] }.keys.sort
check "judge: the fixture changes are one I1 with every changed entry: #{verdict.violations[0].inspect}",
      verdict.violations[0] == { "invariant" => "I1", "kinds" => %w[created deleted type content mode rewrite], "paths" => fx_paths }
check "judge: a canary mark is I2, named by where the canary is: #{verdict.violations[1].inspect}",
      verdict.violations[1] == { "invariant" => "I2", "kinds" => ["fixture"], "paths" => ["fx/cat"], "canaries" => ["fx.cat"] } &&
      verdict.violations.length == 2
check "judge: the rest goes to a human, by reason: #{verdict.human.inspect}",
      verdict.human == [
        { "reason" => "reserved-canary", "paths" => ["shim/done"], "canaries" => ["word.done"] },
        { "reason" => "zone", "zone" => "home", "kinds" => ["created"], "paths" => ["home/.cache", "home/.cache/x"] },
        { "reason" => "zone", "zone" => "tools", "kinds" => ["content"], "paths" => ["tools/cat"] },
        { "reason" => "zone", "zone" => "marks", "kinds" => ["created"], "paths" => ["marks/cli.codex.5", "marks/note.txt"] },
        { "reason" => "zone", "zone" => "base", "kinds" => ["created"], "paths" => ["stray.txt"] },
        { "reason" => "dir-mtime", "paths" => %w[fx/churn fx/quiet tmp] },
      ]
File.chmod(0o644, File.join(fx, "secret.txt"))

# 終わり方の区分 (集計のための近似)。
endings = {
  "ok" => fake.call,
  "nonzero" => fake.call(exit_code: 1, err: "cat: nofile: No such file or directory\n"),
  "usage" => fake.call(exit_code: 1, err: "uniq: invalid option -- Z\nusage: uniq [-cdiu] [input [output]]\n"),
  "127" => fake.call(exit_code: 127, err: "zsh:1: command not found: date\n"),
  "126" => fake.call(exit_code: 126, err: "/bin/sh: /bin/date: Operation not permitted\n"),
  "nomatch" => fake.call(exit_code: 1, err: "zsh:1: no matches found: nofile*\n"),
  "syntax" => fake.call(exit_code: 2, err: "/bin/sh: -c: line 0: syntax error near unexpected token `then'\n"),
  "timeout" => fake.call(exit_code: nil, timed_out: true),
  "unknown" => fake.call(exit_code: nil, signal: 9),
}
endings.each { |want, run| check "ending: #{want}: #{J.ending(run).inspect}", J.ending(run) == want }
check "ending: the closed list", J::ENDINGS == endings.keys && J::EFFECTIVE_ENDINGS == %w[ok nonzero]
check "ending: a zsh parse error is a syntax ending", J.ending(fake.call(exit_code: 1, err: "zsh:1: parse error near `then'\n")) == "syntax"
check "ending: a timeout wins over the stderr text", J.ending(fake.call(exit_code: nil, timed_out: true, err: "zsh:1: no matches found: x\n")) == "timeout"
check "ending: exit 0 is ok whatever stderr says", J.ending(fake.call(err: "usage: x\n")) == "ok"

# 拒まれた起動。字面は、隔離の中で 3 つの shell から実測したもの。
names = J.table_tool_names
denied = ->(err, code) { J.denied_items(fake.call(exit_code: code, err: err), names) }
{
  ["zsh:1: operation not permitted: /bin/date\n", 127] => ["/bin/date"],
  ["/bin/bash: /bin/date: Operation not permitted\n", 126] => ["/bin/date"],
  ["sh: /bin/date: Operation not permitted\n", 126] => ["/bin/date"],
  ["/bin/sh: ./notcanary: /bin/sh: bad interpreter: Operation not permitted\n", 126] => ["./notcanary"],
  ["xargs: /bin/date: Operation not permitted\n", 126] => ["/bin/date"],
  ["find: /bin/date: Operation not permitted\n", 1] => ["/bin/date"],
  ["zsh:1: command not found: date\n", 127] => ["date"],
  ["/bin/sh: date: command not found\n", 127] => ["date"],
  ["env: date: No such file or directory\n", 127] => ["date"],
  ["/bin/sh: line 0: exec: nosuch: not found\n", 127] => ["nosuch"],
  # path の形の名前 (/ を含む) を、shell が起動できなかった行。実行できない file と、無い file。
  ["zsh:1: permission denied: ./x\n", 126] => ["./x"], ["/bin/sh: ./x: Permission denied\n", 126] => ["./x"],
  ["sh: ./x: Permission denied\n", 126] => ["./x"], ["zsh:1: no such file or directory: ./nosuch\n", 127] => ["./nosuch"],
  ["/bin/bash: lib/nosuch: No such file or directory\n", 127] => ["lib/nosuch"], ["bash: ./nosuch: No such file or directory\n", 127] => ["./nosuch"],
  ["/bin/sh: line 3: ./nosuch: No such file or directory\n", 127] => ["./nosuch"],
  ["xargs: ./x: Permission denied\n", 126] => ["./x"], ["nohup: ./x: Permission denied\n", 126] => ["./x"],
  # 名前の basename が表の道具でも、path の形なら fixture の中の file を指す。表の道具とは数えない。
  ["env: ./sort: No such file or directory\n", 127] => ["./sort"], ["env: lib/cat: No such file or directory\n", 127] => ["lib/cat"],
  # git が、alias などの先の program を起動できなかった行。
  ["error: cannot run date: No such file or directory\nfatal: while expanding alias 'x': 'date': No such file or directory\n", 128] => ["date"],
  # 最後の終了 code が 0 でも、stderr の行から拾う (/bin/date; echo x)。
  ["/bin/bash: /bin/date: Operation not permitted\n", 0] => ["/bin/date"],
  ["zsh:1: permission denied: ./x\n", 0] => ["./x"], ["/bin/sh: ./nosuch: No such file or directory\n", 0] => ["./nosuch"],
  ["cat: x\nzsh:1: command not found: date\nzsh:1: operation not permitted: /bin/date\nzsh:1: command not found: date\n", 127] => ["/bin/date", "date"],
  # stderr を捨てた起動 (date 2>/dev/null) は、終了 code だけで拾う。名前は分からない。
  ["", 127] => [], ["", 126] => [],
  # 名前に出せない字があれば、stderr の中身を写さない。
  ["zsh:1: command not found: a b\"c\n", 127] => ["?"],
}.each do |(err, code), want|
  check "denied-exec: #{err.inspect} exit #{code}: #{denied.call(err, code).inspect}",
        denied.call(err, code) == [{ "reason" => "denied-exec", "names" => want, "exit_code" => code }]
end
[
  # 表の道具が、この machine に無いだけの回 (rg など) は、拒まれた起動に数えない。
  ["zsh:1: command not found: rg\n", 127], ["/bin/sh: jq: command not found\n", 127],
  ["cat: nofile: No such file or directory\n", 1], ["/bin/bash: line 0: type: nosuch: not found\n", 1], ["", 0], ["", 1],
  # 道具が出す行と、/ の無い名前の redirect の失敗は、起動の失敗ではない。
  ["cat: lib/nofile: No such file or directory\n", 1], ["cat: ./secret.txt: Permission denied\n", 1],
  ["zsh:1: no such file or directory: nofile\n", 1], ["/bin/sh: nofile: No such file or directory\n", 1],
  ["zsh:1: permission denied: out.txt\n", 1], ["env: rg: No such file or directory\n", 127],
].each { |err, code| check "denied-exec: not reported for #{err.inspect} exit #{code}", denied.call(err, code) == [] }
# 2>&1 を付けた起動は、字面が stdout に回る。stdout の行からも拾う。
{
  "zsh:1: command not found: date\n" => ["date"], "/bin/sh: /bin/date: Operation not permitted\n" => ["/bin/date"],
  "apple\nzsh:1: permission denied: ./x\n" => ["./x"],
}.each do |out, want|
  got = J.denied_items(fake.call(out: out), names)
  check "denied-exec: read from stdout too: #{out.inspect}: #{got.inspect}", got == [{ "reason" => "denied-exec", "names" => want, "exit_code" => 0 }]
end
both = J.denied_items(fake.call(err: "zsh:1: permission denied: ./x\n", out: "zsh:1: command not found: date\n"), names)
check "denied-exec: stderr and stdout are one finding: #{both.inspect}", both == [{ "reason" => "denied-exec", "names" => ["./x", "date"], "exit_code" => 0 }]
check "denied-exec: ordinary output is not a finding", J.denied_items(fake.call(out: "apple\napple\nbanana\n"), names) == []
check "denied-exec: a failed sandbox-exec is not read as a denied launch",
      J.denied_items(fake.call(sandbox_error: true, exit_code: 71, err: "sandbox-exec: sandbox_apply: Operation not permitted\n"), names) == []
check "denied-exec: the table is every tool name, usable here or not", %w[cat git rg jq shasum].all? { |n| names.include?(n) } && !names.include?("date")

# 判定。小さな snapshot を手で組み、分け方を 1 つずつ見る。
ent = ->(type, **kw) { J::Entry.new(**{ type: type, mode: 0o644, size: 1, mtime: [1, 0], ino: 1, sha256: "a" }.merge(kw)) }
dir = ->(**kw) { ent.call("dir", **{ sha256: nil }.merge(kw)) }
still = { "fx" => dir.call, "fx/x" => ent.call("file"), "marks" => dir.call, "tmp" => dir.call }
wrote = still.merge("fx" => dir.call(mtime: [2, 0]), "fx/-c" => ent.call("file", ino: 2))
i1 = { "invariant" => "I1", "kinds" => ["created"], "paths" => ["fx/-c"] }
v = J.judge(before: still, after: still, run: fake.call)
check "judge: no diff and a normal ending is clean", v.clean? && v.ending == "ok" && v.changes.empty? && v.variant == "zsh"
v = J.judge(before: still, after: wrote, run: fake.call)
check "judge: a write in fx is I1, with the parent dir's mtime absorbed", v.violations == [i1] && v.human.empty? && v.unmeasured.nil? && !v.clean?
v = J.judge(before: still, after: wrote, run: fake.call(exit_code: nil, timed_out: true))
check "judge: a timed-out run still reports the violation, with the timeout beside it",
      v.violations == [i1] && v.ending == "timeout" && v.timed_out == true && v.unmeasured.nil? && v.human == [{ "reason" => "timeout" }]
# 期限で止めた回は、見たのが期限までの変化だけ。違反が無くても、人に出す (exit 0 にしない)。
v = J.judge(before: still, after: still, run: fake.call(exit_code: nil, timed_out: true))
check "judge: a timed-out run without a diff goes to a human: #{v.human.inspect}", v.violations.empty? && v.human == [{ "reason" => "timeout" }] && !v.clean?
timed_out = J.examine(I.variant("zsh"), ->(_name) { v })
check "examine: a timed-out run without a violation ends as exit 3, in one run",
      timed_out.violations.empty? && timed_out.human == [{ "reason" => "timeout" }] && timed_out.runs.length == 1 && J.exit_code(timed_out) == 3
v = J.judge(before: still, after: wrote, run: fake.call(exit_code: 1, err: "uniq: x\n"))
check "judge: a failed ending does not drop the violation", v.violations == [i1] && v.ending == "nonzero"
v = J.judge(before: still, after: wrote, run: fake.call(group_empty: false))
check "judge: a run whose group is not confirmed empty is unmeasured, and keeps what was seen", v.unmeasured == "group-not-empty" && v.violations == [i1]
v = J.judge(before: still, after: still, run: fake.call(group_empty: false))
check "judge: an unmeasured run without a diff is not clean", v.unmeasured == "group-not-empty" && v.violations.empty? && !v.clean?
# 止めた後も出力の pipe が開いたままの回は、group を抜けた子が残っているかもしれないので、未測定にする。
v = J.judge(before: still, after: still, run: fake.call(drained: false))
check "judge: a run whose output was still held open is unmeasured: #{v.unmeasured.inspect}", v.unmeasured == "output-open" && v.violations.empty? && !v.clean?
v = J.judge(before: still, after: wrote, run: fake.call(drained: false))
check "judge: and it keeps what was seen", v.unmeasured == "output-open" && v.violations == [i1]
v = J.judge(before: still, after: still, run: fake.call(sandbox_error: true, exit_code: 71, err: "sandbox-exec: sandbox_apply: Operation not permitted\n"))
check "judge: a run that sandbox-exec could not start is unmeasured", v.unmeasured == "sandbox-error" && v.human.empty? && !v.clean?
v = J.judge(before: still, after: still.merge("fx" => dir.call(mtime: [2, 0])), run: fake.call)
check "judge: a dir mtime alone goes to a human, not to I1", v.violations.empty? && v.human == [{ "reason" => "dir-mtime", "paths" => ["fx"] }]
v = J.judge(before: still, after: still.merge("tmp" => dir.call(mtime: [2, 0]), "tmp/t" => ent.call("file", ino: 3)), run: fake.call)
check "judge: a change outside fx goes to a human, not to I1",
      v.violations.empty? && v.human == [{ "reason" => "zone", "zone" => "tmp", "kinds" => ["created"], "paths" => ["tmp/t"] }]
marked = ->(*marks) { still.merge("marks" => dir.call(mtime: [2, 0])).merge(marks.map { |n| ["marks/#{n}", ent.call("file", ino: 9, size: 0)] }.to_h) }
v = J.judge(before: still, after: marked.call("word.fi.42"), run: fake.call)
check "judge: a reserved-word canary alone goes to a human",
      v.violations.empty? && v.human == [{ "reason" => "reserved-canary", "paths" => ["shim/fi"], "canaries" => ["word.fi"] }]
v = J.judge(before: still, after: marked.call("word.fi.42", "cli.gh.7", "cli.gh.8", "shim.canary.3"), run: fake.call)
check "judge: counted canaries are one I2, once per canary; reserved ones stay with a human: #{v.violations.inspect}",
      v.violations == [{ "invariant" => "I2", "kinds" => %w[cli path], "paths" => %w[shim/canary shim/gh], "canaries" => %w[cli.gh shim.canary] }] &&
      v.human == [{ "reason" => "reserved-canary", "paths" => ["shim/fi"], "canaries" => ["word.fi"] }]
v = J.judge(before: still, after: marked.call("nope.x.1"), run: fake.call)
check "judge: a mark-shaped name of an unknown canary is a zone change",
      v.violations.empty? && v.human == [{ "reason" => "zone", "zone" => "marks", "kinds" => ["created"], "paths" => ["marks/nope.x.1"] }]
v = J.judge(before: still, after: still, run: fake.call(exit_code: 127, err: "zsh:1: operation not permitted: /bin/date\n"))
check "judge: a denied launch goes to a human", v.violations.empty? && v.ending == "127" &&
                                                 v.human == [{ "reason" => "denied-exec", "names" => ["/bin/date"], "exit_code" => 127 }]

# 確かめ直し。走らせる部分を差し替え、何回・どの変種で走らせたかも見る。
verdict_of = lambda do |violations, human: [], unmeasured: nil|
  J::Verdict.new(variant: "v", ending: "ok", exit_code: 0, timed_out: false, unmeasured: unmeasured, violations: violations,
                 human: human, changes: [])
end
other_path = i1.merge("paths" => ["fx/tmp.123"])
content = { "invariant" => "I1", "kinds" => ["content"], "paths" => ["fx/x"] }
i2 = { "invariant" => "I2", "kinds" => ["cli"], "paths" => ["shim/gh"], "canaries" => ["cli.gh"] }
# plan は、変種の名前から、回ごとの Verdict の並び。
examine = lambda do |variant, plan|
  calls = []
  queue = plan.map { |name, list| [name, list.dup] }.to_h
  outcome = J.examine(I.variant(variant), lambda do |name|
    calls << name
    queue.fetch(name).shift || raise("no more verdicts planned for #{name}")
  end)
  [outcome, calls]
end
o, calls = examine.call("zsh", "zsh" => [verdict_of.call([])])
check "examine: no candidate, no rerun", o.violations.empty? && o.human.empty? && calls == ["zsh"] && J.exit_code(o) == 0 && o.unmeasured == false
o, calls = examine.call("zsh", "zsh" => [verdict_of.call([i1])] * 3)
check "examine: the same kind three times is a counterexample", o.violations == [i1] && o.human.empty? && calls == %w[zsh zsh zsh] &&
                                                                J.exit_code(o) == 1 && o.runs.length == 3
o, = examine.call("zsh", "zsh" => [verdict_of.call([i1]), verdict_of.call([other_path]), verdict_of.call([i1])])
check "examine: the paths may differ between runs; the first run's are kept", o.violations == [i1] && o.human.empty?
o, calls = examine.call("zsh", "zsh" => [verdict_of.call([i1]), verdict_of.call([]), verdict_of.call([i1])])
check "examine: a candidate missing from one rerun is flaky, not a counterexample: #{o.human.inspect}",
      o.violations.empty? && o.human == [{ "reason" => "flaky" }.merge(i1)] && calls.length == 3 && J.exit_code(o) == 3
o, = examine.call("zsh", "zsh" => [verdict_of.call([i1]), verdict_of.call([content]), verdict_of.call([i1])])
check "examine: a different kind in a rerun makes both flaky", o.violations.empty? && o.human.map { |h| [h["reason"], h["kinds"]] } == [["flaky", ["created"]], ["flaky", ["content"]]]
o, = examine.call("zsh", "zsh" => [verdict_of.call([i1, i2]), verdict_of.call([i1]), verdict_of.call([i1, i2])])
check "examine: each violation is settled on its own", o.violations == [i1] && o.human == [{ "reason" => "flaky" }.merge(i2)] && J.exit_code(o) == 1
denied_item = { "reason" => "denied-exec", "names" => ["date"], "exit_code" => 127 }
o, calls = examine.call("zsh", "zsh" => [verdict_of.call([], human: [denied_item])])
check "examine: human-only findings exit 3 without a rerun", o.human == [denied_item] && calls == ["zsh"] && J.exit_code(o) == 3
o, = examine.call("zsh", "zsh" => [verdict_of.call([i1], human: [denied_item])] * 3)
check "examine: a counterexample wins over human findings in the exit code", o.violations == [i1] && o.human == [denied_item] && J.exit_code(o) == 1
o, = examine.call("zsh", "zsh" => [verdict_of.call([], unmeasured: "group-not-empty")])
check "examine: an unmeasured run is never a clean result: #{o.human.inspect}",
      o.unmeasured == true && o.human == [{ "reason" => "unmeasured", "why" => ["group-not-empty"] }] && J.exit_code(o) == 3
# 既定でない変種の反例は、同じ shell の既定の変種でも確かめる。
o, calls = examine.call("zsh-nullglob", "zsh-nullglob" => [verdict_of.call([i1])] * 3, "zsh" => [verdict_of.call([])])
check "examine: a counterexample only in a non-default variant goes to a human: #{o.human.inspect}",
      o.violations.empty? && o.human == [{ "reason" => "non-default-variant" }.merge(i1)] &&
      calls == %w[zsh-nullglob zsh-nullglob zsh-nullglob zsh] && J.exit_code(o) == 3
o, calls = examine.call("bash-nullglob", "bash-nullglob" => [verdict_of.call([i1])] * 3, "bash" => [verdict_of.call([i1])] * 3)
check "examine: confirmed in the default variant of the same shell too, it is a counterexample",
      o.violations == [i1] && o.human.empty? && calls == %w[bash-nullglob] * 3 + %w[bash] * 3 && J.exit_code(o) == 1 && o.runs.length == 6
# 既定の変種の回で見たものは、変種の名前を付けて結果に残す (照合に使わなかった分を落とさない)。
in_zsh = ->(item) { item.merge("variant" => "zsh") }
o, = examine.call("zsh-extendedglob", "zsh-extendedglob" => [verdict_of.call([i1])] * 3,
                                      "zsh" => [verdict_of.call([i1]), verdict_of.call([]), verdict_of.call([i1])])
check "examine: flaky in the default variant is not a confirmation there, and is reported as flaky: #{o.human.inspect}",
      o.violations.empty? && o.human == [{ "reason" => "non-default-variant" }.merge(i1), in_zsh.call({ "reason" => "flaky" }.merge(i1))] &&
      J.exit_code(o) == 3
o, calls = examine.call("zsh-nullglob", "zsh-nullglob" => [verdict_of.call([content])] * 3, "zsh" => [verdict_of.call([i1])] * 3)
check "examine: a different kind confirmed in the default variant is a counterexample there: #{o.violations.inspect} #{o.human.inspect}",
      o.violations == [in_zsh.call(i1)] && o.human == [{ "reason" => "non-default-variant" }.merge(content)] &&
      calls == %w[zsh-nullglob] * 3 + %w[zsh] * 3 && J.exit_code(o) == 1
o, = examine.call("zsh-nullglob", "zsh-nullglob" => [verdict_of.call([i1, i2])] * 3,
                                  "zsh" => [verdict_of.call([i1, content], human: [denied_item])] * 3)
check "examine: shared, only-here and only-in-the-default findings are kept apart: #{o.violations.inspect} #{o.human.inspect}",
      o.violations == [i1, in_zsh.call(content)] &&
      o.human == [{ "reason" => "non-default-variant" }.merge(i2), in_zsh.call(denied_item)] && J.exit_code(o) == 1
o, calls = examine.call("zsh-nullglob", "zsh-nullglob" => [verdict_of.call([i1]), verdict_of.call([]), verdict_of.call([])])
check "examine: a flaky candidate is not taken to the default variant", o.human == [{ "reason" => "flaky" }.merge(i1)] && calls == %w[zsh-nullglob] * 3

exit(@failed.zero? ? 0 : 1)
RUBY
echo "ok T3 (judge: snapshot, diff, endings, verdicts, reruns)"

# --- T4: 判定 (sandbox の要る部分。witness) ------------------------------------------------------
if [ "$sandbox" = yes ]; then
  ruby -r"$script_dir/lib/check_helper" - "$judge" "$tmp" <<'RUBY'
require ARGV[0]
tmp = File.realpath(ARGV[1])
I = ProbeClassifier::Isolation
J = ProbeClassifier::Judge

Dir.mkdir(File.join(tmp, "t4"))
session = I::Session.open(root: File.join(tmp, "t4"))
defaults = I::VARIANTS.select(&:default).map(&:name)

# template を作った直後の最初の command。fixture の file の mtime を過去に揃えてあるので、git が index を書き直さない
# (揃えないと、template と同じ秒に走った回だけ、fx/.git/index の書き直しが I1 に出た)。
# lock の跡 (fx/.git の mtime) は git の版で変わりうるので、I1 でないことだけを見る。
fresh = J.observe(session, "git describe --always --dirty")
check "witness: git describe --dirty right after the template is built does not rewrite the index: #{fresh.violations.inspect}",
      fresh.violations.empty? && fresh.unmeasured.nil? && fresh.ending == "ok"

# 書き込む形は I1。分類は通さず、隔離と判定だけを見る (分類器が read と言うかどうかに依らない)。
writes = {
  "sort -o out.txt lib/median.rb" => ["fx/out.txt"], "uniq in.txt out.txt" => ["fx/out.txt"],
  # K1 (#755) と K2 (#756)。
  "uniq in.txt -c" => ["fx/-c"], %q(sed -n '/a\/,/w lib/p' x) => ["fx/lib/p"],
}
writes.each do |command, paths|
  defaults.each do |variant|
    v = J.observe(session, command, variant: variant)
    check "witness (#{variant}): #{command.inspect} is I1 at #{paths.inspect}: #{v.violations.inspect} #{v.human.inspect}",
          v.violations == [{ "invariant" => "I1", "kinds" => ["created"], "paths" => paths }] && v.human.empty? &&
          v.unmeasured.nil? && v.ending == "ok" && v.variant == variant
  end
end
# K3 (#757)。ref の置き方は git の版で変わりうるので、.git の中に何かが出来たことだけを見る。
k3 = J.observe(session, "git branch --format --list x")
check "witness: git branch --format --list x is I1 inside .git: #{k3.violations.inspect}",
      k3.violations.length == 1 && k3.violations[0]["invariant"] == "I1" && k3.violations[0]["kinds"].include?("created") &&
      k3.violations[0]["paths"].all? { |p| p.start_with?("fx/.git/") } && k3.unmeasured.nil?
# canary を走らせる形は I2。
ran = J.observe(session, "./cat lib/median.rb")
check "witness: ./cat is I2 for the fixture canary: #{ran.violations.inspect} #{ran.human.inspect}",
      ran.violations == [{ "invariant" => "I2", "kinds" => ["fixture"], "paths" => ["fx/cat"], "canaries" => ["fx.cat"] }] && ran.human.empty?
word = J.observe(session, "env done rm x")
check "witness: a reserved-word canary goes to a human, and nothing after it runs: #{word.violations.inspect} #{word.human.inspect}",
      word.violations.empty? && word.human == [{ "reason" => "reserved-canary", "paths" => ["shim/done"], "canaries" => ["word.done"] }]

# scene と、guard の表の 3 つ目の形。glob が展開して出来る書き込みと、zsh が代入の中の置き換えを走らせる形。
# 値は [変種, 差分の種類, 変わる path]。path が nil の行は、その変種では何も変わらないことを見る (対照)。
substitution = %q(RANDOM='a[$(sort -o out.txt in.txt)1]')
scenes = [
  ["uniq pair/*", "zsh", "content", "fx/pair/b.txt"],
  ["cd sortopt && sort *", "zsh", "created", "fx/sortopt/planted.txt"],
  ["cd pair && uniq ^x", "zsh-extendedglob", "content", "fx/pair/b.txt"],
  ["cd pair && uniq ^x", "zsh", nil, nil],
  ["a=1; #{substitution}", "zsh", "created", "fx/out.txt"],
  # a が無ければ、zsh でも走らない。bash は、同じ代入で置き換えを走らせない。
  [substitution, "zsh", nil, nil],
  ["a=1; #{substitution}", "bash", nil, nil],
]
scenes.each do |command, variant, kind, path|
  v = J.observe(session, command, variant: variant)
  want = kind ? [{ "invariant" => "I1", "kinds" => [kind], "paths" => [path] }] : []
  check "witness (#{variant}): #{command.inspect} gives #{want.inspect}: #{v.violations.inspect} #{v.human.inspect}",
        v.violations == want && v.human.empty? && v.unmeasured.nil?
end

# 書かない形は、差分も人に出すものも無い。git diff は、fixture の index を揃えてあるので書き直さない。
["git status", "git diff", "cat README.md", "ruby -c lib/median.rb"].each do |command|
  defaults.each do |variant|
    v = J.observe(session, command, variant: variant)
    check "witness (#{variant}): #{command.inspect} leaves no diff: #{v.changes.map { |c| [c.path, c.kinds] }.inspect} #{v.human.inspect}",
          v.clean? && v.changes.empty? && v.ending == "ok"
  end
end

# 表に無い program の起動は、どの変種でも人に出る (違反にはしない)。絶対 path の形は guard が拒むので、通さずに走らせる。
I::VARIANTS.each do |variant|
  v = J.observe(session, "/bin/date", variant: variant.name, guarded: false)
  code = variant.base == "zsh" ? 127 : 126
  check "witness (#{variant.name}): an unlisted program is a denied launch: #{v.human.inspect}",
        v.violations.empty? && v.human == [{ "reason" => "denied-exec", "names" => ["/bin/date"], "exit_code" => code }] && v.changes.empty?
end
defaults.each do |variant|
  v = J.observe(session, "date", variant: variant)
  check "witness (#{variant}): a name that is not a listed tool is reported the same way: #{v.human.inspect}",
        v.violations.empty? && v.human == [{ "reason" => "denied-exec", "names" => ["date"], "exit_code" => 127 }]
  v = J.observe(session, "zsh -lc date 2>/dev/null", variant: variant)
  check "witness (#{variant}): a denied launch with stderr thrown away is still reported: #{v.human.inspect}",
        v.violations.empty? && v.human == [{ "reason" => "denied-exec", "names" => [], "exit_code" => 127 }]
end

# 途中の位置の起動の失敗と、2>&1 で stdout に回った字面も拾う (最後の終了 code は 0)。./x は実行できない file。
defaults.each do |variant|
  v = J.observe(session, "date 2>&1 | cat; ./x; cat in.txt", variant: variant)
  check "witness (#{variant}): failed launches in the middle of a command are reported: #{v.human.inspect}",
        v.violations.empty? && v.human == [{ "reason" => "denied-exec", "names" => ["./x", "date"], "exit_code" => 0 }]
end
# 名前の basename が表の道具でも、path の形の名前は表の道具に数えない。
v = J.observe(session, "env ./sort in.txt")
check "witness: a launcher's missing path-shaped name is reported: #{v.human.inspect}",
      v.human == [{ "reason" => "denied-exec", "names" => ["./sort"], "exit_code" => 127 }]

# stderr の「sandbox-exec: 」の行は、0 で終わった回では command の出力として読む (未測定にしない)。
v = J.observe(session, "echo 'sandbox-exec: x' >&2")
check "witness: a command that prints a sandbox-exec line and exits 0 is measured: #{v.unmeasured.inspect}", v.unmeasured.nil? && v.clean?
v = J.observe(session, "echo 'sandbox-exec: x' >&2; false")
check "witness: the same line with a failed ending stays unmeasured: #{v.unmeasured.inspect}", v.unmeasured == "sandbox-error" && !v.clean?

# group が空と確かめられなかった回は、起動の結果から判定まで「未測定」として届く。
group_empty = I.method(:group_empty?)
I.define_singleton_method(:group_empty?) { |*_args, **_opts| false }
begin
  v = J.observe(session, "cat in.txt")
ensure
  I.define_singleton_method(:group_empty?, group_empty)
end
check "witness: a run whose group is not confirmed empty is unmeasured end to end: #{v.unmeasured.inspect}",
      v.unmeasured == "group-not-empty" && v.violations.empty? && !v.clean?
check "group_empty? is restored", I.group_empty?(nil) == false && I.live_group_control[:exited_reported_empty] == true

# process group を抜けた子 (setsid) が、出力を開いたまま残る回。shell は 0 で終わるが、未測定になる。
# guard はこの形を拒むので、通さずに走らせる。子は 8 秒で自分で終わる (読み切りの待ちより長く生きる)。
escaped = J.observe(session, %q(ruby -e 'fork { Process.setsid; sleep 8 }'), variant: "sh", guarded: false)
check "witness: a child that left the process group and holds the output makes the run unmeasured: #{escaped.unmeasured.inspect} #{escaped.exit_code.inspect}",
      escaped.unmeasured == "output-open" && escaped.exit_code == 0 && escaped.timed_out == false && escaped.violations.empty? && !escaped.clean?
check "witness: the guard rejects that form", I.guard(%q(ruby -e 'fork { Process.setsid; sleep 8 }')) == "ruby-form"

# 書き込みの後に終わらない形。期限で止めても、差分から I1 が出て、timeout が併記される。
hang = J.observe(session, "uniq in.txt -c; tail -f in.txt", variant: "sh", timeout: 1, guarded: false)
check "witness: a write followed by a command that does not end is still I1, with the timeout: #{hang.violations.inspect} #{hang.ending}",
      hang.violations == [{ "invariant" => "I1", "kinds" => ["created"], "paths" => ["fx/-c"] }] && hang.timed_out == true &&
      hang.ending == "timeout" && hang.exit_code.nil? && hang.unmeasured.nil?

# guard が拒む形は、走らせる前に止まる。
rejected = begin
  J.observe(session, "cd ./../marks && uniq - -c")
  nil
rescue I::Rejected => e
  e.reason
end
check "witness: the guard stops a command before it runs", rejected == "dotdot"

# 確かめ直しを、本物の起動で通す。
runner = ->(command) { ->(name) { J.observe(session, command, variant: name) } }
confirmed = J.examine(I.variant("zsh"), runner.call("uniq in.txt -c"))
check "examine (real runs): a write is confirmed in three runs: #{confirmed.violations.inspect}",
      confirmed.violations == [{ "invariant" => "I1", "kinds" => ["created"], "paths" => ["fx/-c"] }] && confirmed.human.empty? &&
      confirmed.runs.map { |r| r["variant"] } == %w[zsh zsh zsh] && J.exit_code(confirmed) == 1
clean = J.examine(I.variant("zsh"), runner.call("cat README.md"))
check "examine (real runs): a read runs once and is clean", clean.violations.empty? && clean.human.empty? && clean.runs.length == 1 && J.exit_code(clean) == 0
# nullglob では、合わない glob が消えて -o が次の語を取り、in.txt を空にする。既定の zsh では、合わない glob で止まる。
only_nullglob = J.examine(I.variant("zsh-nullglob"), runner.call("sort -o nomatch* in.txt"))
found = only_nullglob.human.first || {}
check "examine (real runs): a write only under a non-default variant goes to a human: #{only_nullglob.violations.inspect} #{only_nullglob.human.inspect}",
      only_nullglob.violations.empty? && J.exit_code(only_nullglob) == 3 && only_nullglob.human.length == 1 &&
      found["reason"] == "non-default-variant" && found["invariant"] == "I1" && found["kinds"].include?("content") &&
      found["paths"] == ["fx/in.txt"] &&
      only_nullglob.runs.map { |r| [r["variant"], r["ending"]] } == [%w[zsh-nullglob ok]] * 3 + [%w[zsh nomatch]]

check "observe cleans up each command's temp dir", Dir.children(session.root).all? { |n| n.start_with?("pci-template-") }
session.close
check "close removes the template", Dir.children(File.join(tmp, "t4")).empty?

exit 1 unless @failed.zero?
puts "ok T4 (judge: witnesses in isolation)"
RUBY
fi

# --- T5: 入口 (sandbox の要らない部分) ---------------------------------------------------------
# 分類器の代役。何でも read と答え、「: 」で始まる command だけ file-write と答える
# (: は何もしない語。走らないことを見る command を、走っても何も起きない形にしておく)。
stub="$tmp/stub-classifier.rb"
cat > "$stub" <<'RUBY'
module SkillBehaviorClassifier
  VERSION = 754
  def self.classify_shell(command, _depth = 0, **_opts)
    command.start_with?(": ") ? "file-write" : "read"
  end
end
RUBY
printf 'def boom\n  raise "this classifier does not load"\nend\nboom\n' > "$tmp/broken-classifier.rb"
printf 'module SkillBehaviorClassifier\n  VERSION = 1\n  def self.classify_shell(*)\n    "banana"\n  end\nend\n' > "$tmp/odd-classifier.rb"
tmp_real=$(CDPATH= cd -- "$tmp" && pwd -P)
# 入口が作る一時 dir の置き場。test の一時 dir の中に向け、走らせた後に空であることを見る。
cli_tmp="$tmp/cli-tmp"
mkdir "$cli_tmp"

# 入口を走らせ、exit code を確かめる。出力は cli.out と cli.err に残す。
# 使い方: run_cli <期待する exit code> <label> <引数>...
run_cli() {
  rc_want=$1
  rc_label=$2
  shift 2
  rc_status=0
  TMPDIR="$cli_tmp" "$probe" "$@" > "$tmp/cli.out" 2> "$tmp/cli.err" || rc_status=$?
  [ "$rc_status" -eq "$rc_want" ] \
    || fail "$rc_label: expected exit $rc_want, got $rc_status: $(cat "$tmp/cli.out" "$tmp/cli.err")"
  [ -z "$(ls -A "$cli_tmp")" ] || fail "$rc_label: the entry left a temp dir behind: $(ls -A "$cli_tmp")"
}
# file に、test の一時 dir と HOME の絶対 path が無いことを確かめる。
# 使い方: no_abs_paths <label> <file>...
no_abs_paths() {
  nap_label=$1
  shift
  for nap_file in "$@"; do
    for nap_needle in "$tmp" "$tmp_real" "$HOME"; do
      if grep -qF -- "$nap_needle" "$nap_file"; then fail "$nap_label: $(basename "$nap_file") carries an absolute path"; fi
    done
  done
}

# 引数の誤りは exit 2。
run_cli 2 "no arguments"
grep -q '^error: --out is required (or --preflight)$' "$tmp/cli.err" || fail "no arguments: missing the reason: $(cat "$tmp/cli.err")"
run_cli 2 "unknown argument" --out "$tmp/o-x" --command 'cat README.md' --nope
run_cli 2 "preflight with a command" --preflight --command 'cat README.md'
run_cli 2 "command without --out" --command 'cat README.md' --classifier "$stub"
run_cli 2 "unknown variant" --out "$tmp/o-x" --command 'cat README.md' --classifier "$stub" --variant dash
run_cli 2 "missing value" --out "$tmp/o-x" --command
run_cli 0 "help" --help
grep -q '^usage: probe-classifier-invariants.sh --preflight' "$tmp/cli.out" || fail "help: usage missing"

# 出力先は、git の worktree の外で、無いか空の dir。本物の repo ではなく、.git を置いた代役の dir で見る。
mkdir -p "$tmp/wt/.git" "$tmp/wt/sub" "$tmp/nonempty"
: > "$tmp/nonempty/x"
ln -s "$tmp/wt/sub" "$tmp/wt-link"
for out in "$tmp/wt/out" "$tmp/wt/sub/deep/out" "$tmp/wt/.git/out" "$tmp/wt-link/out" "$tmp/nonempty" "$tmp/nonempty/x"; do
  run_cli 2 "--out $out" --out "$out" --command 'cat README.md' --classifier "$stub"
  grep -q '^error: --out ' "$tmp/cli.err" || fail "--out $out: missing the reason: $(cat "$tmp/cli.err")"
  no_abs_paths "--out $out" "$tmp/cli.err"
done
run_cli 2 "--preflight with --out in a worktree" --preflight --out "$tmp/wt/out"
[ ! -e "$tmp/wt/out" ] && [ ! -e "$tmp/wt/sub/deep" ] && [ ! -e "$tmp/wt/.git/out" ] || fail "--out inside a worktree must not be created"

# 居ない user の ~name は、使い方の誤り (exit 2)。Ruby の既定の終了 (exit 1 と backtrace) にはしない。
# exit 1 は「反例あり」の意味で、backtrace は repo の絶対 path を含む。
run_cli 2 "--out with an unknown ~user" --out '~nosuchuser-zz/x' --command 'cat README.md' --classifier "$stub"
grep -q '^error: --out is not a usable path$' "$tmp/cli.err" || fail "--out with an unknown ~user: missing the reason: $(cat "$tmp/cli.err")"
no_abs_paths "--out with an unknown ~user" "$tmp/cli.err"
run_cli 2 "--classifier with an unknown ~user" --out "$tmp/o-tilde" --command 'cat README.md' --classifier '~nosuchuser-zz/c.rb'
grep -q '^error: --classifier is not a usable path$' "$tmp/cli.err" \
  || fail "--classifier with an unknown ~user: missing the reason: $(cat "$tmp/cli.err")"
no_abs_paths "--classifier with an unknown ~user" "$tmp/cli.err"
[ ! -e "$tmp/o-tilde" ] || fail "--classifier with an unknown ~user: --out must not be created"

# guard が拒む command は、走らせずに exit 2。結果の file は書かない。
run_cli 2 "guard: absolute path" --out "$tmp/o-g1" --command 'cat /etc/hosts' --classifier "$stub"
grep -q 'guard rejected the command (abs-path); it was not run' "$tmp/cli.err" || fail "guard: absolute path: missing the reason: $(cat "$tmp/cli.err")"
run_cli 2 "guard: dotdot" --out "$tmp/o-g2" --command 'cd ./../marks && uniq - -c' --classifier "$stub"
grep -q 'guard rejected the command (dotdot); it was not run' "$tmp/cli.err" || fail "guard: dotdot: missing the reason: $(cat "$tmp/cli.err")"
[ ! -e "$tmp/o-g1" ] && [ ! -e "$tmp/o-g2" ] || fail "guard: a rejected command must not write results"

# read でない command は、走らせずに exit 0。HOME の path は置き換えて書く。
run_cli 0 "not read" --out "$tmp/o-w" --command ": $HOME/probe-classifier-no-such-entry" --classifier "$stub"
no_abs_paths "not read" "$tmp/o-w/results.json" "$tmp/cli.out" "$tmp/cli.err"
grep -q '^command: class=file-write (not read; not run)$' "$tmp/cli.out" || fail "not read: missing the line: $(cat "$tmp/cli.out")"
# 分類器を省くと、repo の分類器を使う。
run_cli 0 "default classifier" --out "$tmp/o-d" --command 'rm -rf x'
ruby -r"$script_dir/lib/check_helper" -rjson -rdigest - "$tmp/o-w/results.json" "$tmp/o-d/results.json" "$stub" \
  "$repo_root/scripts/lib/skill_behavior_classifier.rb" <<'RUBY'
w = JSON.parse(File.read(ARGV[0]))
d = JSON.parse(File.read(ARGV[1]))
check "not read: mode, variant and the classifier's version and hash",
      w["mode"] == "command" && w["variant"] == "zsh" && w["classifier"] == { "version" => 754, "sha256" => Digest::SHA256.file(ARGV[2]).hexdigest }
check "not read: counted by class and not executed: #{w['counts'].inspect}",
      w["counts"] == { "generated" => 1, "by_class" => { "file-write" => 1 }, "executed" => 0, "unmeasured" => 0 }
check "not read: no violations, no human findings", w["violations"] == [] && w["human"] == [] && w["runs"] == []
check "not read: the HOME path in the command is replaced", w["command"] == ": <HOME>/probe-classifier-no-such-entry"
check "default classifier: the repo's file, by hash: #{d['classifier'].inspect}",
      d["classifier"]["sha256"] == Digest::SHA256.file(ARGV[3]).hexdigest && d["classifier"]["version"].is_a?(Integer) &&
      d["counts"]["executed"] == 0 && d["counts"]["by_class"].keys != ["read"]
exit(@failed.zero? ? 0 : 1)
RUBY

# 分類できなかった command を「read でない」と数えない (exit 2)。
run_cli 2 "classifier that does not load" --out "$tmp/o-b" --command 'cat README.md' --classifier "$tmp/broken-classifier.rb"
grep -q 'the classifier could not be run.*<classifier>.*this classifier does not load' "$tmp/cli.err" \
  || fail "broken classifier: missing the reason: $(cat "$tmp/cli.err")"
no_abs_paths "broken classifier" "$tmp/cli.err"
# 分類器が同じ dir の file を読めずに落ちた回は、文言に分類器の dir が出る。そこも置き換える。
printf 'require_relative "nope-missing"\n' > "$tmp/rel-classifier.rb"
run_cli 2 "classifier with a failing require_relative" --out "$tmp/o-b" --command 'cat README.md' --classifier "$tmp/rel-classifier.rb"
grep -q 'the classifier could not be run.*<classifier-dir>/nope-missing' "$tmp/cli.err" \
  || fail "classifier with a failing require_relative: missing the reason: $(cat "$tmp/cli.err")"
no_abs_paths "classifier with a failing require_relative" "$tmp/cli.err"
run_cli 2 "classifier with an unknown class" --out "$tmp/o-b" --command 'cat README.md' --classifier "$tmp/odd-classifier.rb"
run_cli 2 "classifier file missing" --out "$tmp/o-b" --command 'cat README.md' --classifier "$tmp/absent.rb"
[ ! -e "$tmp/o-b" ] || fail "a failed classification must not write results"

# 隔離を組めないとき (一時 dir の path に、profile に埋め込めない字がある) は、何も走らせずに exit 2 で、理由を 1 行出す。
mkdir "$tmp/has space"
status=0
TMPDIR="$tmp/has space" "$probe" --preflight > "$tmp/cli.out" 2> "$tmp/cli.err" || status=$?
[ "$status" -eq 2 ] || fail "preflight that cannot be set up: expected exit 2, got $status: $(cat "$tmp/cli.out" "$tmp/cli.err")"
[ "$(wc -l < "$tmp/cli.err" | tr -d ' ')" -eq 1 ] || fail "preflight that cannot be set up: the reason must be one line: $(cat "$tmp/cli.err")"
grep -q '^error: the isolation preflight failed: the temp root has characters that cannot be embedded safely$' "$tmp/cli.err" \
  || fail "preflight that cannot be set up: missing the reason: $(cat "$tmp/cli.err")"
[ -z "$(ls -A "$tmp/has space")" ] || fail "preflight that cannot be set up: a temp dir was left behind"
# --command も、preflight が通らなければ走らせず、結果の file を書かない。
status=0
TMPDIR="$tmp/has space" "$probe" --out "$tmp/o-nopre" --command 'cat README.md' --classifier "$stub" > "$tmp/cli.out" 2> "$tmp/cli.err" || status=$?
[ "$status" -eq 2 ] || fail "command without a passing preflight: expected exit 2, got $status: $(cat "$tmp/cli.out" "$tmp/cli.err")"
grep -q '^error: the isolation preflight failed: ' "$tmp/cli.err" || fail "command without a passing preflight: missing the reason: $(cat "$tmp/cli.err")"
[ ! -e "$tmp/o-nopre" ] && [ -z "$(ls -A "$tmp/has space")" ] || fail "command without a passing preflight: it must write nothing"

# 未測定の回は、結果の file の件数と、人に出す行の両方に出る (隔離の中では起こしにくいので、組み立てる所を直接呼ぶ)。
ruby -r"$script_dir/lib/check_helper" - "$repo_root/scripts/lib/probe_classifier_invariants.rb" <<'RUBY'
require ARGV[0]
P = ProbeClassifierInvariants
outcome = P::Judge::Outcome.new(
  violations: [], human: [{ "reason" => "unmeasured", "why" => ["group-not-empty"] }], unmeasured: true,
  runs: [{ "variant" => "sh", "ending" => "timeout", "exit_code" => nil, "timed_out" => true, "unmeasured" => "group-not-empty" }]
)
data = P.outcome_data({ command: "cat x", variant: "sh" }, { "version" => 7, "class" => "read", "sha256" => "abc" }, outcome)
check "results: an unmeasured run is counted: #{data['counts'].inspect}",
      data["counts"] == { "generated" => 1, "by_class" => { "read" => 1 }, "executed" => 1, "unmeasured" => 1 }
check "results: and listed for a human, with the command and the variant: #{data['human'].inspect}",
      data["human"] == [{ "reason" => "unmeasured", "command" => "cat x", "variant" => "sh", "why" => ["group-not-empty"] }] &&
      data["violations"] == [] && data["runs"] == outcome.runs && P::Judge.exit_code(outcome) == 3
check "results: the classifier is recorded by version and hash only", data["classifier"] == { "version" => 7, "sha256" => "abc" }
exit(@failed.zero? ? 0 : 1)
RUBY

# preflight の検査が 1 つでも通らなければ、入口は command を走らせず exit 2 にする。想定していない失敗も exit 2 で、
# 1 行だけ出す (exit 1 は「反例あり」の意味)。preflight と、走らせる所を差し替えて、同じ process の中から入口を呼ぶ
# (何も走らせない)。
TMPDIR="$cli_tmp" ruby -r"$script_dir/lib/check_helper" - "$repo_root/scripts/lib/probe_classifier_invariants.rb" "$stub" "$tmp" <<'RUBY'
require "stringio"
require ARGV[0]
stub = ARGV[1]
tmp = File.realpath(ARGV[2])
P = ProbeClassifierInvariants
I = P::Isolation
J = P::Judge

# 入口を呼び、[exit code, stdout, stderr] を返す。
call = lambda do |*argv|
  saved = [$stdout, $stderr]
  $stdout = StringIO.new
  $stderr = StringIO.new
  begin
    code = P.main(argv)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = saved
  end
end
observed = 0
J.define_singleton_method(:observe) do |*_args, **_opts|
  observed += 1
  raise "the command must not be run"
end
asked = []
failed = I::Preflight.new(ok: false, unavailable: false, reasons: ["network: stubbed"],
                          checks: [I::Check.new(name: "network", ok: false, negative: {}, control: {})])
I.define_singleton_method(:preflight) do |session, **_opts|
  asked << session.root
  failed
end
out_dir = File.join(tmp, "o-gate")
code, out, err = call.call("--out", out_dir, "--command", "cat README.md", "--classifier", stub)
check "gate: a failed preflight check stops --command with exit 2: #{code.inspect} #{err.inspect}",
      code == 2 && out.empty? && err == "error: the isolation preflight failed: network: stubbed\n"
check "gate: nothing is run and no results are written", observed.zero? && !File.exist?(out_dir) && asked.length == 1
code, out, err = call.call("--preflight")
check "gate: a failed preflight check makes --preflight exit 2: #{code.inspect} #{err.inspect}",
      code == 2 && out.empty? && err == "error: the isolation preflight failed: network: stubbed\n" && asked.length == 2

# 想定していない例外。session が在る間の失敗は、一時 dir と HOME の path を置き換えて 1 行にする。
I.define_singleton_method(:preflight) { |session, **_opts| raise "boom at #{session.root}/x and #{ENV.fetch('HOME')}/y\nsecond line" }
code, out, err = call.call("--preflight")
check "unexpected failure in a session: exit 2, one line, paths replaced: #{code.inspect} #{err.inspect}",
      code == 2 && out.empty? && err == "error: RuntimeError: boom at <R>/x and <HOME>/y second line\n"
code, = call.call("--out", out_dir, "--command", "cat README.md", "--classifier", stub)
check "unexpected failure before a command: exit 2, nothing run, no results", code == 2 && observed.zero? && !File.exist?(out_dir)
# session の外の失敗 (引数を読む所に注入する)。
P.define_singleton_method(:parse_argv) { |_argv| raise TypeError, "boom in #{ENV.fetch('HOME')}/z" }
code, out, err = call.call("--preflight")
check "unexpected failure outside a session: exit 2, one line: #{code.inspect} #{err.inspect}",
      code == 2 && out.empty? && err == "error: unexpected failure: TypeError: boom in <HOME>/z\n"
check "the entry left no temp dir behind", Dir.children(ENV.fetch("TMPDIR")).empty?

# 報告の行。path は command が作った名前を含むので、制御の字を置き換えて 1 行に保つ。
data = { "variant" => "zsh", "runs" => [{}],
         "violations" => [{ "invariant" => "I1", "kinds" => ["created"], "paths" => ["fx/a\n  I2 fixture shim/canary\ncommand: class=read"] }],
         "human" => [{ "reason" => "zone", "paths" => ["tmp/b\rc", "tmp/d\e[2K"] }] }
saved = $stdout
$stdout = StringIO.new
begin
  P.report(data, nil)
  lines = $stdout.string.lines
ensure
  $stdout = saved
end
check "report: a path with control characters stays on its own line: #{lines.inspect}",
      lines == ["command: class=read variant=zsh runs=1 violations=1 human=1\n",
                "  I1 created fx/a?  I2 fixture shim/canary?command: class=read\n", "  human zone tmp/b?c tmp/d?[2K\n"]
exit(@failed.zero? ? 0 : 1)
RUBY

# --- T5 の続き: 生成の入口 (sandbox の要らない部分) ------------------------------------------------
# 分類器の代役。先頭の語が表にあれば read、無ければ unknown と答える。
# standin は、変異 plain-read-sort が置き換える文字列 (md5sum].freeze) を 1 回だけ持つ。当てると、sort が read になる。
# side-a と side-b は、read の組が 4 通り (a だけ、b だけ、両方、どちらでもない) に分かれる 2 つの版。
# read でない command だけが通る行を 1 つ持つ (行の coverage の「read だけ」を見るため)。
# 使い方: write_standin <file> <版> <read にする語の並び>
write_standin() {
  cat > "$1" <<RUBY
module SkillBehaviorClassifier
  VERSION = $2
  READS = %w[$3].freeze
  def self.classify_shell(command, _depth = 0, **_opts)
    return "read" if READS.include?(command.split.first)

    String.new("unknown")
  end
end
RUBY
}
write_standin "$tmp/standin.rb" 3 "diff git md5sum"
write_standin "$tmp/side-a.rb" 11 "sort diff git"
write_standin "$tmp/side-b.rb" 12 "diff git uniq"

# 使い方の誤りは exit 2。出力先を作らず、一時 dir も残さない (残っていれば run_cli が落とす)。
run_cli 2 "generate: --out inside a worktree" --out "$tmp/wt/out" --count 5 --classifier "$stub"
grep -q '^error: --out must be outside a git worktree$' "$tmp/cli.err" \
  || fail "generate: --out inside a worktree: missing the reason: $(cat "$tmp/cli.err")"
[ ! -e "$tmp/wt/out" ] || fail "generate: --out inside a worktree must not be created"
run_cli 2 "generate: --baseline with --mutation" --out "$tmp/o-u" --classifier "$tmp/standin.rb" --baseline "$stub" --mutation plain-read-sort
grep -q '^error: --baseline and --mutation cannot be combined$' "$tmp/cli.err" \
  || fail "generate: --baseline with --mutation: missing the reason: $(cat "$tmp/cli.err")"
run_cli 2 "generate: unknown mutation" --out "$tmp/o-u" --classifier "$tmp/standin.rb" --mutation no-such-mutation-zz
grep -q '^error: unknown mutation (known: plain-read-sort, ' "$tmp/cli.err" || fail "generate: unknown mutation: missing the reason: $(cat "$tmp/cli.err")"
if grep -q 'no-such-mutation-zz' "$tmp/cli.err"; then fail "generate: unknown mutation: the given name must not be echoed"; fi
# 当たらない変異 (置き換える文字列が、渡した分類器の source に無い)。分類器は省かずに代役を渡す
# (この test を、変異の表が repo の分類器に当たるかどうかに結び付けない)。
run_cli 2 "generate: a mutation that does not apply" --out "$tmp/o-u" --classifier "$stub" --mutation find-delete
grep -q '^error: mutation find-delete does not apply: the text to replace occurs 0 times (expected 1)$' "$tmp/cli.err" \
  || fail "generate: a mutation that does not apply: missing the reason: $(cat "$tmp/cli.err")"
run_cli 2 "generate: --count that is not a number" --out "$tmp/o-u" --classifier "$stub" --count many
grep -q '^error: --count must be an integer from 1 to 5000$' "$tmp/cli.err" \
  || fail "generate: --count that is not a number: missing the reason: $(cat "$tmp/cli.err")"
run_cli 2 "command with --count" --out "$tmp/o-u" --command 'cat README.md' --classifier "$stub" --count 3
grep -q '^error: --command cannot be combined with --count$' "$tmp/cli.err" || fail "command with --count: missing the reason: $(cat "$tmp/cli.err")"
[ ! -e "$tmp/o-u" ] || fail "a usage error must not create --out"

# dry-run。生成して分類し、2 つの file を書く。何も走らせない (sandbox も要らない)。
# 同じ引数で 2 回走らせると、corpus.jsonl も報告も、byte まで同じになる。
run_cli 0 "dry-run" --out "$tmp/o-dry1" --seed 754 --count 12 --classifier "$stub"
[ ! -s "$tmp/cli.err" ] || fail "dry-run: nothing is expected on stderr: $(cat "$tmp/cli.err")"
grep -q '^generated: mode=dry-run seed=754 count=12 variant=zsh$' "$tmp/cli.out" || fail "dry-run: missing the first line: $(cat "$tmp/cli.out")"
grep -q '^selected=12 guard-rejected=0 executed=0 unmeasured=0 violations=0 human=0$' "$tmp/cli.out" \
  || fail "dry-run: missing the counts: $(cat "$tmp/cli.out")"
[ "$(ls "$tmp/o-dry1" | tr '\n' ' ')" = "corpus.jsonl results.json " ] || fail "dry-run: expected the two files: $(ls "$tmp/o-dry1")"
no_abs_paths "dry-run" "$tmp/o-dry1/results.json" "$tmp/o-dry1/corpus.jsonl" "$tmp/cli.out" "$tmp/cli.err"
cp "$tmp/cli.out" "$tmp/dry1.out"
run_cli 0 "dry-run again" --out "$tmp/o-dry2" --seed 754 --count 12 --classifier "$stub"
cmp -s "$tmp/o-dry1/corpus.jsonl" "$tmp/o-dry2/corpus.jsonl" || fail "dry-run: the same arguments must give the same corpus.jsonl, byte for byte"
cmp -s "$tmp/dry1.out" "$tmp/cli.out" || fail "dry-run: the same arguments must give the same report"
# 比べる相手つきと、変異つき。対照の結果は、走らせていないので出さない (差分の組の件数だけ)。
run_cli 0 "dry-run with a baseline" --out "$tmp/o-base" --seed 754 --count 30 --classifier "$tmp/side-a.rb" --baseline "$tmp/side-b.rb"
grep -q '^control: pairs=2 result=not-run confirmed=0 variant-only=0$' "$tmp/cli.out" || fail "dry-run with a baseline: missing the control line: $(cat "$tmp/cli.out")"
no_abs_paths "dry-run with a baseline" "$tmp/o-base/results.json" "$tmp/o-base/corpus.jsonl" "$tmp/cli.out" "$tmp/cli.err"
run_cli 0 "dry-run with a mutation" --out "$tmp/o-mut" --seed 754 --count 22 --classifier "$tmp/standin.rb" --mutation plain-read-sort
grep -q '^control: pairs=2 result=not-run confirmed=0 variant-only=0$' "$tmp/cli.out" || fail "dry-run with a mutation: missing the control line: $(cat "$tmp/cli.out")"
no_abs_paths "dry-run with a mutation" "$tmp/o-mut/results.json" "$tmp/o-mut/corpus.jsonl" "$tmp/cli.out" "$tmp/cli.err"
# 変異した版を書く一時 dir が git の worktree の中なら、exit 2 で、何も残さない (変異した分類器を、tracked に
# なりうる所に置かない)。.git を置いた代役の dir を TMPDIR にして見る。
status=0
TMPDIR="$tmp/wt/sub" "$probe" --out "$tmp/o-mwt" --seed 754 --count 22 --classifier "$tmp/standin.rb" --mutation plain-read-sort \
  > "$tmp/cli.out" 2> "$tmp/cli.err" || status=$?
[ "$status" -eq 2 ] || fail "mutation with a temp dir inside a worktree: expected exit 2, got $status: $(cat "$tmp/cli.out" "$tmp/cli.err")"
grep -q '^error: the temp dir for the mutated classifier is inside a git worktree$' "$tmp/cli.err" \
  || fail "mutation with a temp dir inside a worktree: missing the reason: $(cat "$tmp/cli.err")"
[ -z "$(ls -A "$tmp/wt/sub")" ] && [ ! -e "$tmp/o-mwt" ] || fail "mutation with a temp dir inside a worktree: it must leave nothing behind"

ruby -r"$script_dir/lib/check_helper" -rjson -rdigest - "$generator" "$mutations" "$tmp" "$stub" "$docs" <<'RUBY'
require ARGV[0]
require ARGV[1]
G = ProbeClassifier::Generator
M = ProbeClassifier::Mutations
tmp = ARGV[2]
stub = ARGV[3]
docs = File.read(ARGV[4])
# [results.json の中身, corpus.jsonl の行の並び]。results.json は、読み直した中身で比べる (書式は Ruby の版で違う)。
load_out = lambda do |name|
  [JSON.parse(File.read(File.join(tmp, name, "results.json"))),
   File.readlines(File.join(tmp, name, "corpus.jsonl")).map { |line| JSON.parse(line) }]
end
sha = ->(name) { Digest::SHA256.file(File.join(tmp, name)).hexdigest }
first = ->(row) { row.command.split.first }
classes = ->(rows, reads) { rows.map { |row| reads.include?(first.call(row)) ? "read" : "unknown" } }
corpus_keys = %w[index command cell class]

dry, corpus = load_out.call("o-dry1")
rows = G.generate(754, 12)
check "dry-run: mode, variant, seed, count, digest of the rows, timeout",
      dry.values_at("mode", "variant", "seed", "count", "digest", "timeout") == ["dry-run", "zsh", 754, 12, G.digest(rows), 5]
check "dry-run: the classifier by version and hash: #{dry['classifier'].inspect}",
      dry["classifier"] == { "version" => 754, "sha256" => Digest::SHA256.file(stub).hexdigest }
check "dry-run: counts: #{dry['counts'].inspect}",
      dry["counts"] == { "generated" => 12, "by_class" => { "read" => 12 }, "selected" => 12, "guard_rejected" => 0, "executed" => 0, "unmeasured" => 0 }
check "dry-run: nothing was run", %w[violations human violation_groups human_groups runs].all? { |key| dry[key] == [] }
check "dry-run: the keys of results.json: #{dry.keys.inspect}",
      dry.keys.sort == %w[cells classifier count counts coverage digest human human_groups mode runs seed timeout variant violation_groups violations]
cells = dry["cells"]
reached = ->(name) { { "cell" => name, "generated" => 1, "read" => 1, "selected" => 1, "executed" => 0, "effective" => 0, "endings" => {}, "violations" => 0, "human" => 0 } }
check "dry-run: the table has a row for every cell, and the rows reached so far",
      cells.map { |c| c["cell"] } == G.cell_names && cells.first(12) == G.cell_names.first(12).map(&reached) &&
      cells.drop(12).all? { |c| c.values_at("generated", "read", "selected", "executed") == [0, 0, 0, 0] }
# 行の数は Ruby の版で違いうるので、形と大小だけを見る。
cov = dry["coverage"]
check "dry-run: line coverage of the classifier (all rows, and the rows classified read): #{cov.inspect}",
      cov.is_a?(Hash) && cov.keys.sort == %w[all lines load read] && cov.values.all? { |n| n.is_a?(Integer) } &&
      cov["read"] >= 1 && cov["all"] >= cov["read"] && cov["lines"] >= cov["all"] && cov["load"] >= 1 && cov["lines"] >= cov["load"]
check "dry-run: corpus.jsonl is one row per line, with the four keys in order",
      corpus == rows.map { |row| row.record.merge("class" => "read") } && corpus.all? { |row| row.keys == corpus_keys }

# 走らせる対象は、調べる版で read、比べる相手で read でない件。小さい列に、4 通りの組が全部あることを先に見る
# (片方だけだと、向きを逆にした選び方でも通る)。
a = %w[sort diff git]
b = %w[diff git uniq]
rows = G.generate(754, 30)
split = rows.group_by { |row| [a.include?(first.call(row)), b.include?(first.call(row))] }
indexes = ->(key) { split.fetch(key, []).map(&:index) }
check "pairs: the 30 rows have all four combinations: #{split.map { |k, v| [k, v.length] }.inspect}",
      indexes.call([true, false]) == [11, 21] && indexes.call([false, true]) == [12, 22] &&
      indexes.call([true, true]) == [3, 9, 13, 19, 23] && indexes.call([false, false]).length == 21
base, corpus = load_out.call("o-base")
check "baseline dry-run: the classifier and the baseline, each by version and hash",
      base["classifier"] == { "version" => 11, "sha256" => sha.call("side-a.rb") } &&
      base["baseline"] == { "version" => 12, "sha256" => sha.call("side-b.rb") } && !base.key?("mutation") && !base.key?("mutated_sha256")
check "baseline dry-run: only the rows that are read here and not read there are selected: #{base['counts'].inspect} #{base['control'].inspect}",
      base["counts"] == { "generated" => 30, "by_class" => { "read" => 7, "unknown" => 23 }, "selected" => 2, "guard_rejected" => 0, "executed" => 0, "unmeasured" => 0 } &&
      base["control"] == { "pairs" => 2, "result" => nil, "confirmed" => 0, "variant_only" => 0, "indexes" => [11, 21] }
check "baseline dry-run: corpus.jsonl carries the class of the examined classifier, with the same four keys",
      corpus.map { |row| row["class"] } == classes.call(rows, a) && corpus.all? { |row| row.keys == corpus_keys }
# 代役は、read でない command だけが通る行を 1 つ持つ。その 1 行の分だけ、「read だけ」の数が少ない
# (行の数そのものは Ruby の版で違いうるので、差で見る)。何でも read と答える代役では、2 つの数が同じになる。
check "baseline dry-run: the lines reached by the read rows are counted apart from the lines reached by all rows: #{base['coverage'].inspect}",
      base["coverage"]["all"] == base["coverage"]["read"] + 1 && dry["coverage"]["all"] == dry["coverage"]["read"]
cell = ->(data, name) { data["cells"].find { |c| c["cell"] == name }.values_at("generated", "read", "selected") }
check "baseline dry-run: the table counts read and selected apart",
      cell.call(base, "sort/dashdash") == [1, 1, 1] && cell.call(base, "uniq/dashdash") == [1, 0, 0] && cell.call(base, "diff/opt-after") == [1, 1, 0]

# 変異。調べるのは変異を当てた版で、比べる相手は当てる前の版。classifier の hash は、当てる前の file を指す。
mut, corpus = load_out.call("o-mut")
rows = G.generate(754, 22)
mutated = M.apply(File.read(File.join(tmp, "standin.rb")), "plain-read-sort")
check "mutation dry-run: the given file by hash, the mutation by name, and the hash of the mutated source",
      mut["classifier"] == { "version" => 3, "sha256" => sha.call("standin.rb") } && mut["mutation"] == "plain-read-sort" &&
      mut["mutated_sha256"] == Digest::SHA256.hexdigest(mutated) && mut["mutated_sha256"] != mut["classifier"]["sha256"] && !mut.key?("baseline")
check "mutation dry-run: the pairs are the rows the mutation turned into read: #{mut['counts'].inspect} #{mut['control'].inspect}",
      mut["counts"] == { "generated" => 22, "by_class" => { "read" => 6, "unknown" => 16 }, "selected" => 2, "guard_rejected" => 0, "executed" => 0, "unmeasured" => 0 } &&
      mut["control"] == { "pairs" => 2, "result" => nil, "confirmed" => 0, "variant_only" => 0, "indexes" => [11, 21],
                          "expected" => { "invariant" => "I1", "variant" => "zsh", "expect" => "violation", "needs" => [] } }
check "mutation dry-run: corpus.jsonl carries the class of the mutated version",
      corpus.map { |row| row["class"] } == classes.call(rows, %w[diff git md5sum sort]) && corpus.all? { |row| row.keys == corpus_keys }

# 結果の file の key は、docs の表に名前がある (key を足したら、docs にも足す)。
keys = (dry.keys + base.keys + mut.keys + dry["counts"].keys + base["control"].keys + mut["control"].keys +
        mut["control"]["expected"].keys + dry["cells"][0].keys + dry["coverage"].keys + corpus_keys).uniq
check "docs: every key of the two files is named: #{keys.reject { |key| docs.include?("`#{key}`") }.inspect}",
      keys.all? { |key| docs.include?("`#{key}`") }
exit(@failed.zero? ? 0 : 1)
RUBY

# 生成の入口の、走らせる所。preflight と Judge.observe を差し替え、同じ process の中から入口を呼ぶ (何も走らせない)。
# 見るのは、observe に渡る command (走らせる対象の選び方と順番)、preflight の回数、結果の file、exit code。
TMPDIR="$cli_tmp" ruby -r"$script_dir/lib/check_helper" -rjson -rdigest - "$entry" "$stub" "$tmp" "$docs" "$repo_root/scripts/README.md" <<'RUBY'
require "stringio"
require ARGV[0]
stub = ARGV[1]
tmp = File.realpath(ARGV[2])
P = ProbeClassifierInvariants
I = P::Isolation
J = P::Judge
G = P::Generator
M = P::Mutations
standin, side_a, side_b = %w[standin.rb side-a.rb side-b.rb].map { |name| File.join(tmp, name) }

# 入口を呼び、[exit code, stdout, stderr] を返す。
call = lambda do |*argv|
  saved = [$stdout, $stderr]
  $stdout = StringIO.new
  $stderr = StringIO.new
  begin
    code = P.main(argv)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = saved
  end
end
# preflight と observe の呼ばれ方を、順番ごと残す。observe は、plan が返す Verdict を返すだけ。
events = []
passed = I::Preflight.new(ok: true, unavailable: false, checks: [], reasons: [])
pre = passed
I.define_singleton_method(:preflight) do |_session, **_opts|
  events << [:preflight]
  pre
end
verdict = lambda do |variant, violations: [], human: [], unmeasured: nil|
  J::Verdict.new(variant: variant, ending: "ok", exit_code: 0, timed_out: false, unmeasured: unmeasured,
                 violations: violations, human: human, changes: [])
end
clean = ->(_command, variant) { verdict.call(variant) }
plan = clean
J.define_singleton_method(:observe) do |_session, command, variant: "zsh", **_opts|
  events << [:observe, command, variant]
  plan.call(command, variant)
end

# 引数の誤り。どれも、何かを読む前に exit 2 で止まる。
out_dir = File.join(tmp, "o-arg")
bad = {
  "--count 0" => %w[--count 0], "--count above the limit" => %w[--count 5001], "a negative --count" => %w[--count -1],
  "--count with a sign" => %w[--count +5], "--count with a fraction" => %w[--count 1.5], "--count with a space" => ["--count", "5 "],
  "an empty --count" => ["--count", ""], "--count in hex" => %w[--count 0x10], "--count without a value" => %w[--count],
  "--seed that is not a number" => %w[--seed abc], "a negative --seed" => %w[--seed -1], "--seed above the limit" => %w[--seed 1000000000],
  "--seed with a line break" => ["--seed", "7\n8"], "--mutation followed by an option" => %w[--mutation --run],
  "--baseline without a value" => %w[--baseline],
}
bad.each do |label, argv|
  code, out, err = call.call("--out", out_dir, "--classifier", stub, *argv)
  check "arguments: #{label} is exit 2: #{code.inspect} #{err.lines.first.inspect}", code == 2 && out.empty? && err.start_with?("error: --")
end
[%w[--seed 1], %w[--count 3], %w[--run], ["--baseline", stub]].each do |extra|
  code, out, err = call.call("--out", out_dir, "--command", "cat README.md", "--classifier", stub, *extra)
  check "arguments: --command with #{extra[0]} is exit 2: #{code.inspect} #{err.lines.first.inspect}",
        code == 2 && out.empty? && err.lines.first == "error: --command cannot be combined with #{extra[0]}\n"
end
[%w[--seed 1], %w[--count 3], %w[--run], ["--baseline", stub], %w[--mutation plain-read-sort], %w[--variant sh], ["--classifier", stub]].each do |extra|
  code, out, err = call.call("--preflight", *extra)
  check "arguments: --preflight with #{extra[0]} is exit 2: #{code.inspect} #{err.lines.first.inspect}",
        code == 2 && out.empty? && err.lines.first == "error: --preflight takes only --out (got #{extra[0]})\n"
end
code, _out, err = call.call("--out", out_dir, "--classifier", stub, "--baseline", File.join(tmp, "absent.rb"))
check "arguments: a baseline file that is missing is exit 2: #{err.lines.first.inspect}",
      code == 2 && err.lines.first == "error: --baseline is not a readable file\n"
code, _out, err = call.call("--count", "3", "--classifier", stub)
check "arguments: generating without --out is exit 2: #{err.lines.first.inspect}", code == 2 && err.lines.first == "error: --out is required (or --preflight)\n"
check "arguments: nothing was asked or run, and --out was not created", events.empty? && !File.exist?(out_dir)

# 既定の seed と件数。dry-run は、隔離の session を開かない。
opened = I::Session.method(:open)
I::Session.define_singleton_method(:open) { |*_args, **_opts| raise "a dry-run must not open a session" }
begin
  code, _out, err = call.call("--out", File.join(tmp, "o-idef"), "--classifier", stub)
ensure
  I::Session.define_singleton_method(:open, opened)
end
defaults = code == 0 ? JSON.parse(File.read(File.join(tmp, "o-idef", "results.json"))) : {}
check "dry-run: the defaults are seed 754, 200 rows and zsh, and no session is opened: #{code.inspect} #{err.inspect}",
      code == 0 && err.empty? && defaults.values_at("mode", "seed", "count", "variant") == ["dry-run", 754, 200, "zsh"] &&
      File.readlines(File.join(tmp, "o-idef", "corpus.jsonl")).length == 200 && events.empty?
check "dry-run: 200 rows reach every cell", defaults["cells"].all? { |c| c["generated"] >= 1 } && defaults["counts"]["guard_rejected"] == 0

# 生成の run。30 行のうち、先頭の語が sort の 2 行と、uniq の 2 行を使う。
rows = G.generate(754, 30)
first = ->(row) { row.command.split.first }
sorts = rows.select { |row| first.call(row) == "sort" }
uniqs = rows.select { |row| first.call(row) == "uniq" }
check "run: the rows this part relies on: #{sorts.map(&:command).inspect}",
      sorts.map(&:index) == [11, 21] && uniqs.map(&:index) == [12, 22] && sorts.map(&:cell) == %w[sort/dashdash sort/bundle] &&
      sorts.map(&:command) == ["sort --reverse -- README.md", "sort --output=out.txt in.txt"]
write = { "invariant" => "I1", "kinds" => ["created"], "paths" => ["fx/out.txt"] }
# 入口を、seed 754 の 30 行で呼ぶ。戻り値は [exit code, stdout, stderr, results.json の中身 (無ければ nil), 呼ばれ方]。
gen = lambda do |name, *extra|
  events.clear
  code, out, err = call.call("--out", File.join(tmp, name), "--seed", "754", "--count", "30", *extra)
  file = File.join(tmp, name, "results.json")
  [code, out, err, File.exist?(file) ? JSON.parse(File.read(file)) : nil, events.dup]
end
watch = ->(list, variant = "zsh") { list.map { |row| [:observe, row.command, variant] } }

# 比べる相手つき。差分の組 (a で read、b で read でない) だけが、番号の順に走る。preflight は初めに 1 回。
plan = ->(command, variant) { verdict.call(variant, violations: command == sorts[1].command ? [write] : []) }
code, out, err, r, seen = gen.call("o-ia", "--classifier", side_a, "--baseline", side_b, "--run")
check "run with a baseline: one preflight, then only the pairs, and the candidate two more times: #{seen.inspect}",
      seen == [[:preflight]] + watch.call([sorts[0]]) + watch.call([sorts[1]]) * 3
check "run with a baseline: exit 1 and the report: #{code.inspect} #{out.inspect}",
      code == 1 && out.lines.length == 6 &&
      out.lines.first(4) == ["generated: mode=run seed=754 count=30 variant=zsh\n", "classes: read=7 unknown=23\n",
                             "selected=2 guard-rejected=0 executed=2 unmeasured=0 violations=1 human=0\n",
                             "control: pairs=2 result=found confirmed=1 variant-only=0\n"] &&
      out.lines[4].match?(/\Acoverage: lines=\d+ load=\d+ all=\d+ read=\d+\n\z/) &&
      out.lines[5] == "  I1 created fx/out.txt x1 #21 [sort/bundle] sort --output=out.txt in.txt\n"
check "run with a baseline: the progress goes to stderr: #{err.inspect}", err == "run: 2 commands to run (variant zsh)\nrun: 1/2\n"
found = { "invariant" => "I1", "index" => 21, "cell" => "sort/bundle", "command" => sorts[1].command, "variant" => "zsh",
          "kinds" => ["created"], "paths" => ["fx/out.txt"] }
check "run with a baseline: counts and control: #{r['counts'].inspect} #{r['control'].inspect}",
      r["mode"] == "run" && r["baseline"]["version"] == 12 &&
      r["counts"] == { "generated" => 30, "by_class" => { "read" => 7, "unknown" => 23 }, "selected" => 2, "guard_rejected" => 0, "executed" => 2, "unmeasured" => 0 } &&
      r["control"] == { "pairs" => 2, "result" => "found", "confirmed" => 1, "variant_only" => 0, "indexes" => [11, 21] }
check "run with a baseline: the counterexample carries its index and cell, and is grouped: #{r['violations'].inspect}",
      r["violations"] == [found] && r["human"] == [] && r["violation_groups"] == [found.merge("count" => 1)] && r["human_groups"] == []
check "run with a baseline: one row per launch, with the index of its command",
      r["runs"].map { |run| run["index"] } == [11, 21, 21, 21] &&
      r["runs"].all? { |run| run.keys == %w[index variant ending exit_code timed_out unmeasured] && run["ending"] == "ok" }
cell = ->(data, name) { data["cells"].find { |c| c["cell"] == name } }
check "run with a baseline: the table of cells: #{cell.call(r, 'sort/bundle').inspect}",
      cell.call(r, "sort/bundle") == { "cell" => "sort/bundle", "generated" => 1, "read" => 1, "selected" => 1, "executed" => 1, "effective" => 1,
                                        "endings" => { "ok" => 1 }, "violations" => 1, "human" => 0 } &&
      cell.call(r, "sort/dashdash").values_at("executed", "violations") == [1, 0] &&
      cell.call(r, "uniq/dashdash").values_at("read", "selected", "executed") == [0, 0, 0] &&
      cell.call(r, "diff/opt-after").values_at("read", "selected", "executed") == [1, 0, 0]
check "run with a baseline: the tools this machine lacks are listed by name", r["tools_missing"].is_a?(Hash) && r["tools_missing"].keys.all? { |k| k.match?(/\A[a-z0-9]+\z/) }
check "run with a baseline: corpus.jsonl is written too", File.readlines(File.join(tmp, "o-ia", "corpus.jsonl")).length == 30

# 向きを逆にすると、差分の組は uniq の 2 行になる。違反が無ければ、対照の結果は missed で exit 0。
plan = clean
code, _out, _err, r, seen = gen.call("o-ib", "--classifier", side_b, "--baseline", side_a, "--run")
check "run with the sides swapped: the pairs are the other rows, and the control is missed: #{seen.inspect} #{r['control'].inspect}",
      seen == [[:preflight]] + watch.call(uniqs) && code == 0 && r["classifier"]["version"] == 12 && r["baseline"]["version"] == 11 &&
      r["control"] == { "pairs" => 2, "result" => "missed", "confirmed" => 0, "variant_only" => 0, "indexes" => [12, 22] }

# 相手が無ければ、read の全件が走る。変種は observe まで届く。
reads = rows.select { |row| %w[sort diff git].include?(first.call(row)) }
code, _out, _err, r, seen = gen.call("o-ic", "--classifier", side_a, "--run", "--variant", "sh")
check "run without a baseline: every read row is run once, in the given variant: #{seen.length}",
      seen == [[:preflight]] + watch.call(reads, "sh") && reads.length == 7 && code == 0 && !r.key?("control") && !r.key?("baseline") &&
      r["variant"] == "sh" && r["counts"].values_at("selected", "executed") == [7, 7] && r["runs"].map { |run| run["index"] } == reads.map(&:index)

# 未測定の回は、件数と人に出す行の両方に出て、exit 3 になる。
plan = ->(command, variant) { verdict.call(variant, unmeasured: command == sorts[0].command ? "group-not-empty" : nil) }
code, out, _err, r, = gen.call("o-id", "--classifier", side_a, "--baseline", side_b, "--run")
check "run with an unmeasured row: exit 3, counted, and listed for a human: #{code.inspect} #{r['human'].inspect}",
      code == 3 && r["counts"]["unmeasured"] == 1 && r["violations"] == [] && r["control"]["result"] == "missed" &&
      r["human"] == [{ "reason" => "unmeasured", "index" => 11, "cell" => "sort/dashdash", "command" => sorts[0].command, "variant" => "zsh",
                       "why" => ["group-not-empty"] }] &&
      out.lines.last == "  human unmeasured group-not-empty x1 #11 [sort/dashdash] sort --reverse -- README.md\n"

# 既定でない変種だけで出る違反は、反例に数えず人に出す (exit 3)。対照の結果は found になる。
plan = ->(command, variant) { verdict.call(variant, violations: command == sorts[1].command && variant == "zsh-extendedglob" ? [write] : []) }
code, _out, _err, r, seen = gen.call("o-ie", "--classifier", side_a, "--baseline", side_b, "--run", "--variant", "zsh-extendedglob")
check "run in a non-default variant: a violation only there is found, and goes to a human: #{code.inspect} #{r['control'].inspect}",
      code == 3 && r["violations"] == [] && r["control"].values_at("result", "confirmed", "variant_only") == ["found", 0, 1] &&
      r["human"].map { |h| h.values_at("reason", "index", "cell", "variant", "invariant", "paths") } ==
      [["non-default-variant", 21, "sort/bundle", "zsh-extendedglob", "I1", ["fx/out.txt"]]] &&
      seen == [[:preflight]] + watch.call([sorts[0]], "zsh-extendedglob") + watch.call([sorts[1]], "zsh-extendedglob") * 3 + watch.call([sorts[1]], "zsh")

# guard が拒んだ件は走らせない。件数と人に出す行に出て、exit 3 になる (dry-run でも同じ)。
guard = I.method(:guard)
I.define_singleton_method(:guard) { |command, **opts| command == sorts[0].command ? "stubbed-reason" : guard.call(command, **opts) }
begin
  plan = clean
  code, _out, err, r, seen = gen.call("o-if", "--classifier", side_a, "--baseline", side_b, "--run")
  dry_code, _dry_out, dry_err, dry, dry_seen = gen.call("o-if2", "--classifier", side_a, "--baseline", side_b)
ensure
  I.define_singleton_method(:guard, guard)
end
rejected = { "reason" => "guard-rejected", "index" => 11, "cell" => "sort/dashdash", "command" => sorts[0].command, "variant" => "zsh",
             "why" => ["stubbed-reason"] }
warning = "warning: the guard rejected 1 generated command(s); they are not run (see results.json)\n"
check "run with a rejected row: it is not run, and it is counted and listed: #{seen.inspect} #{r['counts'].inspect}",
      seen == [[:preflight]] + watch.call([sorts[1]]) && code == 3 && r["human"] == [rejected] && r["violations"] == [] &&
      r["counts"].values_at("selected", "guard_rejected", "executed") == [2, 1, 1] && r["control"]["result"] == "missed" &&
      err.lines.first == warning
check "dry-run with a rejected row: the same row, and exit 3: #{dry_code.inspect}",
      dry_code == 3 && dry_seen.empty? && dry["human"] == [rejected] && dry["counts"].values_at("guard_rejected", "executed") == [1, 0] && dry_err == warning
check "the guard is restored", I.guard(sorts[0].command).nil?

# preflight が通らなければ、何も走らせず、file も書かない。
pre = I::Preflight.new(ok: false, unavailable: false, reasons: ["network: stubbed"],
                       checks: [I::Check.new(name: "network", ok: false, negative: {}, control: {})])
code, out, err, r, seen = gen.call("o-ig", "--classifier", side_a, "--run")
check "run with a failed preflight: exit 2, nothing run, nothing written: #{code.inspect} #{err.inspect}",
      code == 2 && out.empty? && err == "error: the isolation preflight failed: network: stubbed\n" && seen == [[:preflight]] && r.nil? &&
      !File.exist?(File.join(tmp, "o-ig"))
pre = passed

# 分類の失敗は exit 2 (分類できなかった行を「read でない」と数えない)。例外の文言は写さず、番号と class の名前だけを出す。
File.write(File.join(tmp, "raising.rb"), <<~'SOURCE')
  module SkillBehaviorClassifier
    VERSION = 1
    def self.classify_shell(command, _depth = 0, **_opts)
      raise ArgumentError, "boom in /some/private/place" if command.start_with?("sort ")

      "read"
    end
  end
SOURCE
code, out, err, r, seen = gen.call("o-ii", "--classifier", File.join(tmp, "raising.rb"), "--run")
check "a classifier that raises on a row: exit 2 with the row's index: #{code.inspect} #{err.inspect}",
      code == 2 && out.empty? && err == "error: the classifier raised ArgumentError on row 11\n" && seen.empty? && r.nil?
code, _out, err, r, = gen.call("o-ii", "--classifier", File.join(tmp, "odd-classifier.rb"))
check "a classifier that returns an unknown class: exit 2: #{err.inspect}",
      code == 2 && err == "error: the classifier returned an unexpected result\n" && r.nil? && !File.exist?(File.join(tmp, "o-ii"))

# 1 件の --command に --mutation を足すと、変異した版で分類する (witness を直接確かめる入口)。
plan = ->(_command, variant) { verdict.call(variant, violations: [write]) }
events.clear
witness = "sort -o out.txt in.txt"
code, _out, _err = call.call("--out", File.join(tmp, "o-ih"), "--command", witness, "--classifier", standin, "--mutation", "plain-read-sort")
h = JSON.parse(File.read(File.join(tmp, "o-ih", "results.json")))
check "command with a mutation: read under the mutated version, so it is run: #{code.inspect} #{events.inspect}",
      code == 1 && events == [[:preflight]] + [[:observe, witness, "zsh"]] * 3 && h["mode"] == "command" &&
      h["counts"]["by_class"] == { "read" => 1 } && !h.key?("control")
check "command with a mutation: the given file by hash, the mutation by name, and the hash of the mutated source",
      h["classifier"] == { "version" => 3, "sha256" => Digest::SHA256.file(standin).hexdigest } && h["mutation"] == "plain-read-sort" &&
      h["mutated_sha256"] == Digest::SHA256.hexdigest(M.apply(File.read(standin), "plain-read-sort"))
events.clear
code, out, = call.call("--out", File.join(tmp, "o-ih2"), "--command", witness, "--classifier", standin)
check "command without the mutation: not read, so not run: #{out.inspect}",
      code == 0 && out == "command: class=unknown (not read; not run)\n" && events.empty? &&
      !JSON.parse(File.read(File.join(tmp, "o-ih2", "results.json"))).key?("mutation")
check "the entry left no temp dir behind (sessions and the mutated classifier)", Dir.children(ENV.fetch("TMPDIR")).empty?

# 走らせる対象の選び方 (区分の並びから)。
check "select_rows: without a partner, every read row", P.select_rows(%w[read unknown read exec], nil) == [0, 2]
check "select_rows: with a partner, read here and not read there",
      P.select_rows(%w[read read unknown unknown read], %w[read unknown read unknown file-write]) == [1, 4]

# 対照の結果の決め方。値は [Setup, 差分の組, 走らせた結論, 道具の表, 期待する結果]。
tools = Struct.new(:names)
with_rg = tools.new(%w[cat rg])
without_rg = tools.new(%w[cat])
outcome = lambda do |violations: [], human: [], unmeasured: false|
  J::Outcome.new(violations: violations, human: human, unmeasured: unmeasured, runs: [])
end
ok = outcome.call
plain = P::Setup.new(mutation: nil)
needs_rg = P::Setup.new(mutation: "rg-glob-word-any")
table = {
  "no pairs" => [plain, [], {}, with_rg, "missed"],
  "pairs that are all clean" => [plain, [11, 21], { 11 => ok, 21 => ok }, with_rg, "missed"],
  "a confirmed violation" => [plain, [11, 21], { 11 => ok, 21 => outcome.call(violations: [write]) }, with_rg, "found"],
  "a violation only under a non-default variant" =>
    [plain, [11, 21], { 11 => ok, 21 => outcome.call(human: [{ "reason" => "non-default-variant" }.merge(write)]) }, with_rg, "found"],
  "a flaky violation only" => [plain, [11, 21], { 11 => ok, 21 => outcome.call(human: [{ "reason" => "flaky" }.merge(write)]) }, with_rg, "missed"],
  "pairs that are all unmeasured" => [plain, [11, 21], { 11 => outcome.call(unmeasured: true), 21 => outcome.call(unmeasured: true) }, with_rg, "unmeasurable"],
  "one measured pair" => [plain, [11, 21], { 11 => outcome.call(unmeasured: true), 21 => ok }, with_rg, "missed"],
  "pairs that were not run" => [plain, [11, 21], {}, with_rg, "unmeasurable"],
  "a needed tool is missing" => [needs_rg, [11], { 11 => ok }, without_rg, "unmeasurable"],
  "a needed tool is missing, without pairs" => [needs_rg, [], {}, without_rg, "unmeasurable"],
  "the needed tool is there" => [needs_rg, [11], { 11 => ok }, with_rg, "missed"],
  "a violation, although a needed tool is missing" => [needs_rg, [11], { 11 => outcome.call(violations: [write]) }, without_rg, "found"],
  "a dry-run" => [plain, [11, 21], {}, nil, nil],
}
table.each do |label, (setup, selected, outcomes, toolset, want)|
  batch = P::Batch.new(rows: rows, classes: [], partner_classes: [], selected: selected, rejected: {}, outcomes: outcomes)
  got = P.control_data(setup, batch, toolset)
  check "control (#{label}): #{want.inspect}: #{got.inspect}", got["result"] == want && got["pairs"] == selected.length && got["indexes"] == selected
end
batch = P::Batch.new(rows: rows, classes: [], partner_classes: [], selected: [11], rejected: {}, outcomes: { 11 => ok })
check "control: a mutation's expectation and the tools it lacks are recorded",
      P.control_data(needs_rg, batch, without_rg).values_at("expected", "needs_missing") ==
      [{ "invariant" => "I2", "variant" => "zsh", "expect" => "violation", "needs" => ["rg"] }, ["rg"]] &&
      P.control_data(needs_rg, batch, with_rg)["needs_missing"] == [] &&
      (P.control_data(plain, batch, with_rg).keys & %w[expected needs_missing]).empty?

# 束ね方。同じ cell、不変条件、差分の種類、path の行を 1 つにし、最も短い command (同じ長さなら番号の小さい方) を代表にする。
item = lambda do |index, command, paths|
  { "invariant" => "I1", "index" => index, "cell" => "sort/bundle", "command" => command, "variant" => "zsh", "kinds" => ["created"], "paths" => paths }
end
items = [item.call(5, "sort -o out.txt in.txt", ["fx/out.txt"]), item.call(9, "sort -oout.txt x", ["fx/out.txt"]),
         item.call(7, "sort -o lib/p x", ["fx/lib/p"]), item.call(3, "sort -o out.txt x", ["fx/out.txt"]),
         item.call(2, "sort -o out.txt in.txt", ["fx/out.txt"]).merge("cell" => "sort/write-form")]
check "grouped: rows of the same shape become one, with the shortest command and a count: #{P.grouped(items).inspect}",
      P.grouped(items) == [items[1].merge("count" => 3), items[2].merge("count" => 1), items[4].merge("count" => 1)]
check "grouped: among commands of the same length, the smaller index",
      P.grouped([item.call(8, "sort -o a x", ["fx/a"]), item.call(4, "sort -o a y", ["fx/a"])]) == [item.call(4, "sort -o a y", ["fx/a"]).merge("count" => 2)]
# 報告に出す束は、上限まで。残りは件数だけを出す。
many = Array.new(P::REPORT_GROUPS + 2) { |n| item.call(n, "sort -o f#{n} x", ["fx/f#{n}"]).merge("count" => 1) }
saved = $stdout
$stdout = StringIO.new
begin
  P.report_generated({ "mode" => "run", "seed" => 1, "count" => 40, "variant" => "zsh", "coverage" => nil,
                       "counts" => { "by_class" => { "read" => 40 }, "selected" => 40, "guard_rejected" => 0, "executed" => 40, "unmeasured" => 0 },
                       "violations" => many, "human" => [], "violation_groups" => many, "human_groups" => [] }, nil)
  lines = $stdout.string.lines
ensure
  $stdout = saved
end
check "report: at most #{P::REPORT_GROUPS} groups, then how many more: #{lines.length} #{lines.last.inspect}",
      lines.length == 3 + P::REPORT_GROUPS + 1 && lines[3] == "  I1 created fx/f0 x1 #0 [sort/bundle] sort -o f0 x\n" &&
      lines.last == "  (+2 more groups in results.json)\n"

# file の操作の失敗は、path を出さずに、理由の所だけを出す (--out の dir や分類器の file の場所を、stderr に写さない)。
# 結果の file を書く所に、失敗を注入して見る (session の外と、session の中)。
missing = begin
  File.read(File.join(tmp, "no-such-dir-zz", "x"))
rescue SystemCallError => e
  e
end
check "errors: the reason of a file error, without the path: #{P.errno_reason(missing).inspect}",
      P.errno_reason(missing) == "No such file or directory" && P.errno_reason(Errno::EACCES.new("/secret/place")) == "Permission denied"
write_results = P.method(:write_results)
P.define_singleton_method(:write_results) { |out, *_rest| raise Errno::EACCES, File.join(out, "results.json") }
begin
  plan = clean
  dry_code, dry_out, dry_err, = gen.call("o-ij", "--classifier", side_a)
  run_code, _run_out, run_err, = gen.call("o-ik", "--classifier", side_a, "--baseline", side_b, "--run")
ensure
  P.define_singleton_method(:write_results, write_results)
end
check "errors: a failed write outside a session is exit 2, without the path: #{dry_code.inspect} #{dry_err.inspect}",
      dry_code == 2 && dry_out.empty? && dry_err == "error: Permission denied\n"
check "errors: a failed write inside a session is exit 2, without the path: #{run_code.inspect} #{run_err.lines.last.inspect}",
      run_code == 2 && run_err.lines.last == "error: Errno::EACCES: Permission denied\n"
check "errors: the entry still left no temp dir behind", Dir.children(ENV.fetch("TMPDIR")).empty?

# docs と README の usage の行と、引数の範囲は、入口の定数と同じ (定数を変えたら、docs も直す)。
docs = File.read(ARGV[3])
readme = File.read(ARGV[4])
usage = P::USAGE.lines.first(4).join
check "docs and README: the usage lines are the ones the entry prints: #{usage.inspect}",
      usage.lines.all? { |line| line.include?("probe-classifier-invariants.sh") || line.include?("--run") } && docs.include?(usage) && readme.include?(usage)
check "docs: the defaults and limits of --seed and --count, and the number of groups in the report",
      docs.include?("| `--seed N` | 生成の seed。既定は #{P::DEFAULT_SEED}。0 から #{P::MAX_SEED} の整数 |") &&
      docs.include?("| `--count N` | 生成する件数。既定は #{P::DEFAULT_COUNT}。1 から #{P::MAX_COUNT} の整数 |") &&
      docs.include?("それぞれ #{P::REPORT_GROUPS} 個まで") && docs.include?("生成の件数の上限は #{P::MAX_COUNT}。")
exit(@failed.zero? ? 0 : 1)
RUBY
no_abs_paths "generated runs in process" "$tmp/o-ia/results.json" "$tmp/o-ia/corpus.jsonl" "$tmp/o-ih/results.json"

# sandbox を適用できないときは、何も走らせずに exit 2 で、理由を 1 行出す (素の実行には戻らない)。
# 適用できる環境では、何でも許す sandbox の中から入口を呼び、入れ子で適用できない状態を作る。
# 使い方: run_unavailable <label> <引数>...
run_unavailable() {
  ru_label=$1
  shift
  ru_status=0
  if [ "$sandbox" = yes ]; then
    TMPDIR="$cli_tmp" /usr/bin/sandbox-exec -p '(version 1)(allow default)' "$probe" "$@" > "$tmp/cli.out" 2> "$tmp/cli.err" || ru_status=$?
  else
    TMPDIR="$cli_tmp" "$probe" "$@" > "$tmp/cli.out" 2> "$tmp/cli.err" || ru_status=$?
  fi
  [ "$ru_status" -eq 2 ] || fail "$ru_label: expected exit 2, got $ru_status: $(cat "$tmp/cli.out" "$tmp/cli.err")"
  [ "$(wc -l < "$tmp/cli.err" | tr -d ' ')" -eq 1 ] || fail "$ru_label: the reason must be one line: $(cat "$tmp/cli.err")"
  grep -q '^error: sandbox-exec cannot be applied here: ' "$tmp/cli.err" || fail "$ru_label: missing the reason: $(cat "$tmp/cli.err")"
  [ ! -s "$tmp/cli.out" ] || fail "$ru_label: nothing must be reported as run: $(cat "$tmp/cli.out")"
  [ -z "$(ls -A "$cli_tmp")" ] || fail "$ru_label: the entry left a temp dir behind"
}
run_unavailable "preflight without a usable sandbox" --preflight
run_unavailable "command without a usable sandbox" --out "$tmp/o-nosb" --command 'cat README.md' --classifier "$stub"
[ ! -e "$tmp/o-nosb" ] || fail "command without a usable sandbox: it must write no results"
run_unavailable "generated run without a usable sandbox" --out "$tmp/o-nosb" --seed 754 --count 3 --classifier "$stub" --run
[ ! -e "$tmp/o-nosb" ] || fail "generated run without a usable sandbox: it must write no results"
echo "ok T5 (entry: arguments, --out, guard, classification, dry-run, selection, control)"

# --- T6: 入口 (sandbox の要る部分) -----------------------------------------------------------
if [ "$sandbox" = yes ]; then
  run_cli 0 "preflight" --preflight --out "$tmp/o-pre"
  grep -q '^preflight: ok (11 checks)$' "$tmp/cli.out" || fail "preflight: missing the ok line: $(cat "$tmp/cli.out")"
  no_abs_paths "preflight" "$tmp/o-pre/results.json" "$tmp/cli.out" "$tmp/cli.err"
  # K1 の形。代役の分類器が read と答えるので走り、fx/-c の作成が I1 になる。本物の preflight を通ってから走る。
  run_cli 1 "command with a write" --out "$tmp/o-k1" --command 'uniq in.txt -c' --classifier "$stub"
  grep -q '^  I1 created fx/-c$' "$tmp/cli.out" || fail "command with a write: missing the line: $(cat "$tmp/cli.out")"
  no_abs_paths "command with a write" "$tmp/o-k1/results.json" "$tmp/cli.out" "$tmp/cli.err"
  [ ! -e "$tmp/o-pre/corpus.jsonl" ] && [ ! -e "$tmp/o-k1/corpus.jsonl" ] || fail "--preflight and --command must not write corpus.jsonl"

  # 残りの終わり方 (exit 0、exit 3、既定の変種の側の反例) は、同じ process の中から入口を呼んで見る。
  # preflight は「通った」結果に差し替える (この環境で通ることは、T2 と上の 2 回が見ている)。
  # command は、差し替えの無い経路で、本物の profile の下で走る。
  TMPDIR="$cli_tmp" ruby -r"$script_dir/lib/check_helper" - "$repo_root/scripts/lib/probe_classifier_invariants.rb" "$stub" "$tmp" <<'RUBY'
require "stringio"
require ARGV[0]
stub = ARGV[1]
tmp = File.realpath(ARGV[2])
P = ProbeClassifierInvariants
I = P::Isolation

asked = []
passed = I::Preflight.new(ok: true, unavailable: false, checks: [], reasons: [])
I.define_singleton_method(:preflight) do |session, **_opts|
  asked << session.root
  passed
end
# 入口を呼び、[exit code, stdout, stderr] を返す。
call = lambda do |*argv|
  saved = [$stdout, $stderr]
  $stdout = StringIO.new
  $stderr = StringIO.new
  begin
    code = P.main(argv)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = saved
  end
end
command = lambda do |name, text, variant|
  call.call("--out", File.join(tmp, name), "--command", text, "--classifier", stub, "--variant", variant)
end

code, out, err = command.call("o-cat", "cat README.md", "sh")
check "read: exit 0 and one line: #{code.inspect} #{out.inspect} #{err.inspect}",
      code == 0 && err.empty? && out == "command: class=read variant=sh runs=1 violations=0 human=0\n"
outputs = [out, err]
# 既定でない変種でだけ書き込む形 (nullglob では合わない glob が消え、-o が in.txt を取る)。既定の zsh では合わない glob で
# 止まるので、反例に数えず、人に出すものだけになる (exit 3)。
code, out, err = command.call("o-ng", "sort -o nomatch* in.txt", "zsh-nullglob")
check "non-default variant only: exit 3 and the line for a human: #{code.inspect} #{out.inspect} #{err.inspect}",
      code == 3 && err.empty? && out.lines == ["command: class=read variant=zsh-nullglob runs=4 violations=0 human=1\n",
                                               "  human non-default-variant fx/in.txt\n"]
outputs.push(out, err)
# 同じ command は、既定の bash では別の種類の書き込みになる (合わない glob が字のまま残り、その名前の file を作る)。
# 既定の変種で確かめた反例なので、exit 1 で、既定の変種の名前で結果に出る。
code, out, err = command.call("o-bng", "sort -o nomatch* in.txt", "bash-nullglob")
check "a different kind in the default variant: exit 1 and both lines: #{code.inspect} #{out.inspect} #{err.inspect}",
      code == 1 && err.empty? && out.lines == ["command: class=read variant=bash-nullglob runs=6 violations=1 human=1\n",
                                               "  I1 created fx/nomatch*\n", "  human non-default-variant fx/in.txt\n"]
outputs.push(out, err)
check "the entry asks for a preflight before each command, on a new session each time", asked.length == 3 && asked.uniq.length == 3
check "the entry left no temp dir behind", Dir.children(ENV.fetch("TMPDIR")).empty?
File.write(File.join(tmp, "inproc.out"), outputs.join)
exit(@failed.zero? ? 0 : 1)
RUBY
  no_abs_paths "commands run in process" "$tmp/o-cat/results.json" "$tmp/o-ng/results.json" "$tmp/o-bng/results.json" "$tmp/inproc.out"
  [ ! -e "$tmp/o-cat/corpus.jsonl" ] || fail "--command must not write corpus.jsonl"

  ruby -r"$script_dir/lib/check_helper" -rjson - "$tmp/o-pre/results.json" "$tmp/o-k1/results.json" "$tmp/o-cat/results.json" \
    "$tmp/o-ng/results.json" "$tmp/o-bng/results.json" <<'RUBY'
pre = JSON.parse(File.read(ARGV[0]))
k1 = JSON.parse(File.read(ARGV[1]))
cat = JSON.parse(File.read(ARGV[2]))
ng = JSON.parse(File.read(ARGV[3]))
bng = JSON.parse(File.read(ARGV[4]))
found = ng["human"][0] || {}
check "non-default variant: no counterexample, one finding for a human with the command and the variant: #{ng['human'].inspect}",
      ng["violations"] == [] && ng["human"].length == 1 && found["reason"] == "non-default-variant" &&
      found["command"] == "sort -o nomatch* in.txt" && found["variant"] == "zsh-nullglob" && found["invariant"] == "I1" &&
      found["paths"] == ["fx/in.txt"] && ng["variant"] == "zsh-nullglob"
check "non-default variant: three runs in the variant, then the default variant of the same shell",
      ng["runs"].map { |r| r["variant"] } == %w[zsh-nullglob zsh-nullglob zsh-nullglob zsh] && ng["counts"]["executed"] == 1
sort = "sort -o nomatch* in.txt"
check "default variant's own counterexample: listed under the default variant's name: #{bng['violations'].inspect}",
      bng["violations"] == [{ "invariant" => "I1", "command" => sort, "variant" => "bash", "kinds" => ["created"], "paths" => ["fx/nomatch*"] }] &&
      bng["variant"] == "bash-nullglob"
check "default variant's own counterexample: the variant-only write stays with a human: #{bng['human'].inspect}",
      bng["human"] == [{ "reason" => "non-default-variant", "command" => sort, "variant" => "bash-nullglob", "invariant" => "I1",
                         "kinds" => ["content"], "paths" => ["fx/in.txt"] }] &&
      bng["runs"].map { |r| r["variant"] } == %w[bash-nullglob] * 3 + %w[bash] * 3
check "preflight results: mode and every check passed: #{pre.inspect}",
      pre["mode"] == "preflight" && pre["preflight"]["ok"] == true && pre["preflight"]["unavailable"] == false &&
      pre["preflight"]["checks"].length == 11 && pre["preflight"]["checks"].all? { |c| c["ok"] == true } && pre["preflight"]["reasons"] == []
check "preflight results: only the mode and the preflight keys", pre.keys.sort == %w[mode preflight]
check "write: mode, variant, classifier", k1["mode"] == "command" && k1["variant"] == "zsh" && k1["classifier"]["version"] == 754
check "write: counts: #{k1['counts'].inspect}", k1["counts"] == { "generated" => 1, "by_class" => { "read" => 1 }, "executed" => 1, "unmeasured" => 0 }
check "write: one I1 violation at fx/-c: #{k1['violations'].inspect}",
      k1["violations"] == [{ "invariant" => "I1", "command" => "uniq in.txt -c", "variant" => "zsh", "kinds" => ["created"], "paths" => ["fx/-c"] }]
check "write: nothing for a human, and three runs behind the counterexample", k1["human"] == [] && k1["runs"].length == 3 &&
                                                                               k1["runs"].all? { |r| r["variant"] == "zsh" && r["ending"] == "ok" && r["unmeasured"].nil? }
check "read: executed once, with no violation and nothing for a human: #{cat.inspect}",
      cat["mode"] == "command" && cat["variant"] == "sh" && cat["violations"] == [] && cat["human"] == [] &&
      cat["counts"] == { "generated" => 1, "by_class" => { "read" => 1 }, "executed" => 1, "unmeasured" => 0 } &&
      cat["runs"] == [{ "variant" => "sh", "ending" => "ok", "exit_code" => 0, "timed_out" => false, "unmeasured" => nil }]
exit(@failed.zero? ? 0 : 1)
RUBY

  # 生成の run。standin に変異 plain-read-sort を当てた版が read と言う 2 件 (sort で始まる行) だけが、本物の preflight の
  # 後に、本物の隔離の中で走る。1 件は書き込む形 (sort --output=out.txt in.txt) で、反例になる。
  run_cli 1 "generated run with a mutation" --out "$tmp/o-gen" --seed 754 --count 22 --classifier "$tmp/standin.rb" \
    --mutation plain-read-sort --run
  grep -q '^control: pairs=2 result=found confirmed=1 variant-only=0$' "$tmp/cli.out" \
    || fail "generated run with a mutation: missing the control line: $(cat "$tmp/cli.out")"
  grep -q '^  I1 created fx/out.txt x1 #21 \[sort/bundle\] sort --output=out.txt in.txt$' "$tmp/cli.out" \
    || fail "generated run with a mutation: missing the counterexample: $(cat "$tmp/cli.out")"
  no_abs_paths "generated run with a mutation" "$tmp/o-gen/results.json" "$tmp/o-gen/corpus.jsonl" "$tmp/cli.out" "$tmp/cli.err"
  # corpus.jsonl は、dry-run (T5) と byte まで同じ。
  cmp -s "$tmp/o-gen/corpus.jsonl" "$tmp/o-mut/corpus.jsonl" || fail "generated run: corpus.jsonl must be the same as the dry-run's"
  ruby -r"$script_dir/lib/check_helper" -rjson - "$tmp/o-gen/results.json" "$tmp/o-mut/results.json" "$docs" <<'RUBY'
run = JSON.parse(File.read(ARGV[0]))
dry = JSON.parse(File.read(ARGV[1]))
docs = File.read(ARGV[2])
check "docs: the keys that only a run writes are named: #{(run.keys - dry.keys).inspect} #{(run['control'].keys - dry['control'].keys).inspect}",
      run.keys - dry.keys == ["tools_missing"] && run["control"].keys - dry["control"].keys == ["needs_missing"] &&
      (run.keys + run["control"].keys + run["runs"][0].keys).all? { |key| docs.include?("`#{key}`") }
check "generated run: mode, and the same identity as the dry-run",
      run["mode"] == "run" && dry["mode"] == "dry-run" &&
      %w[variant seed count digest classifier mutation mutated_sha256 coverage].all? { |key| run[key] == dry[key] && !run[key].nil? }
check "generated run: only the two pairs are run, out of six read rows: #{run['counts'].inspect}",
      run["counts"] == { "generated" => 22, "by_class" => { "read" => 6, "unknown" => 16 }, "selected" => 2, "guard_rejected" => 0, "executed" => 2, "unmeasured" => 0 }
check "generated run: the control is found, with the expectation of the mutation: #{run['control'].inspect}",
      run["control"] == { "pairs" => 2, "result" => "found", "confirmed" => 1, "variant_only" => 0, "indexes" => [11, 21],
                          "expected" => { "invariant" => "I1", "variant" => "zsh", "expect" => "violation", "needs" => [] }, "needs_missing" => [] }
found = { "invariant" => "I1", "index" => 21, "cell" => "sort/bundle", "command" => "sort --output=out.txt in.txt", "variant" => "zsh",
          "kinds" => ["created"], "paths" => ["fx/out.txt"] }
check "generated run: one I1 counterexample, with its index and cell: #{run['violations'].inspect} #{run['human'].inspect}",
      run["violations"] == [found] && run["human"] == [] && run["violation_groups"] == [found.merge("count" => 1)]
check "generated run: one launch for the clean row, three for the counterexample: #{run['runs'].inspect}",
      run["runs"].map { |r| r.values_at("index", "variant", "ending", "unmeasured") } == [[11, "zsh", "ok", nil]] + [[21, "zsh", "ok", nil]] * 3
cell = ->(name) { run["cells"].find { |c| c["cell"] == name } }
check "generated run: the table of cells has the endings and the violation",
      cell.call("sort/bundle") == { "cell" => "sort/bundle", "generated" => 1, "read" => 1, "selected" => 1, "executed" => 1, "effective" => 1,
                                    "endings" => { "ok" => 1 }, "violations" => 1, "human" => 0 } &&
      cell.call("sort/dashdash").values_at("executed", "effective", "violations") == [1, 1, 0] &&
      cell.call("diff/opt-after").values_at("read", "selected", "executed") == [1, 0, 0]
exit(@failed.zero? ? 0 : 1)
RUBY
  echo "ok T6 (entry: preflight, a command and a generated run in isolation)"
fi

# --- T7: 生成器と変異の表 (sandbox の要らない部分) ----------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$isolation" "$generator" "$mutations" "$docs" <<'RUBY'
require "digest"
require ARGV[0]
require ARGV[1]
require ARGV[2]
I = ProbeClassifier::Isolation
G = ProbeClassifier::Generator
M = ProbeClassifier::Mutations
raises = lambda do |klass, &blk|
  begin
    blk.call
    false
  rescue klass
    true
  end
end

# 同じ seed と件数なら、同じ列。digest の固定値は、Ruby の版に依らず同じ列になることを見る (CI の 2 つの行)。
# 表か選び方を変えたら、この値も変わる (意図した変更なら、値を更新する)。
rows = G.generate(754, 150)
check "generator: the same seed and count give the same rows", G.generate(754, 150) == rows && rows.length == 150
check "generator: the digest of seed 754 and count 150 is the fixed value: #{G.digest(rows)}",
      G.digest(rows) == "051d91bbdc8850455df02ba2d6f30e9a0e024491cd4576efffe36c657ea11ffb"
check "generator: the digest is the SHA-256 of the command lines",
      G.digest(rows) == Digest::SHA256.hexdigest(rows.map { |r| "#{r.command}\n" }.join)
check "generator: a seed given as a string is the same seed", G.generate("754", 150) == rows
other = G.generate(755, 150)
check "generator: another seed gives other rows", other != rows && G.digest(other) != G.digest(rows)
check "generator: a row depends only on the seed and its index", G.generate(754, 300).first(150) == rows && G.row(754, 149) == rows[149]
check "generator: count 0 is an empty list", G.generate(754, 0) == []
check "generator: a count that is not a non-negative integer is refused",
      [-1, "150", nil, 1.5].all? { |count| raises.call(ArgumentError) { G.generate(754, count) } }

# cell。系統とずらしの組に、門の外の 4 つを足した並び。番号の順に回る。
names = G.cell_names
regular = G::CELLS.reject { |c| c.family == G::GATE }
check "cells: 101 names, at most 150, without duplicates: #{names.length}", names.length == 101 && names.length <= 150 && names.uniq == names
check "cells: 11 families and 12 shifts, each of them used",
      G::FAMILIES == %w[plain sort uniq diff sed awk find xargs rg ruby git] &&
      G::SHIFTS == %w[opt-after dashdash bundle value-next write-form brace glob quote prefix name script git-form] &&
      regular.map(&:family).uniq.sort == G::FAMILIES.sort && regular.map(&:shift).uniq.sort == G::SHIFTS.sort
check "cells: a regular cell is named family/shift", regular.all? { |c| c.name == "#{c.family}/#{c.shift}" && G::FAMILIES.include?(c.family) && G::SHIFTS.include?(c.shift) }
check "cells: every cell has something to emit", G::CELLS.all? { |c| !(c.forms + c.bases).empty? }
# 2000 件では、どの cell も 19 回は回る。その中で、表の形が全部出る (seed に依らない)。
# 読むだけの command の基本形 (37 個) だけは、1 つの cell でなく、系統の cell を合わせて全部出る。
%w[754 1 2].each do |seed|
  seen = Hash.new { |h, k| h[k] = [] }
  2000.times do |i|
    cell, entry = G.slot(seed, i)
    seen[cell.name] << entry
  end
  missing = G::CELLS.flat_map { |c| c.forms - seen[c.name] } + regular.reject { |c| c.family == "plain" }.flat_map { |c| c.bases - seen[c.name] }
  tools_seen = regular.select { |c| c.family == "plain" }.flat_map { |c| seen[c.name] & c.bases }.uniq
  check "cells: 2000 rows of seed #{seed} reach every form and every base of the tables: #{missing.length} #{tools_seen.length}",
        missing.empty? && tools_seen.length == 37
end
check "cells: a count equal to the number of cells reaches every cell", G.generate(754, names.length).map(&:cell) == names
check "cells: rows carry their index and go through the cells in order",
      rows.each_with_index.all? { |r, i| r.index == i && r.cell == names[i % names.length] && r.command.is_a?(String) && !r.command.strip.empty? }
check "cells: the record of a row has the three keys of corpus.jsonl",
      rows[3].record == { "index" => 3, "command" => rows[3].command, "cell" => "diff/opt-after" } && rows[3].record.keys == %w[index command cell]
check "cells: each family, the gate and each shift name their counterpart in the classifier",
      (G::FAMILIES + [G::GATE]).all? { |f| !G::SOURCES.fetch(f).empty? } && (G::SHIFTS + ["wrap"]).all? { |s| !G::SHIFT_SOURCES.fetch(s).empty? }

# 生成した全件が guard を通る (4 つの seed で、cell の数の 10 倍ずつ)。
checked = 0
%w[754 1 2 3].each do |seed|
  G.generate(seed, names.length * 10).each do |r|
    checked += 1
    reason = I.guard(r.command)
    check "guard accepts the generated row #{seed}/#{r.index} (#{r.cell}) #{r.command.inspect}: #{reason.inspect}", reason.nil?
  end
end
check "guard: every generated row was checked: #{checked}", checked == 4040

# 門の外の形。閉じた表の文字列を、そのまま出す。回す順番の最後の 4 つの cell なので、割合は 101 件に 4 件。
big = G.generate(754, 2000)
gate_rows = big.select { |r| G.gate?(r.cell) }
gate_forms = G::GATE_FORMS.values.flatten
check "gate: the closed table", G::GATE_FORMS == {
  "gate/ansi-dollar" => ["sort $'-o' out.txt in.txt", "sort in.txt $'-o' out.txt"],
  "gate/dq-dollar" => ['sort "${zz:--o}" out.txt in.txt', 'sort in.txt "${zz:--o}" out.txt'],
  "gate/assignment" => ["n=1", "cat in.txt; n=1", "n=1; cat in.txt", "n=1; m=2"],
  "gate/substitution" => [%q(a=1; RANDOM='a[$(sort -o out.txt in.txt)1]'), %q(RANDOM='a[$(sort -o out.txt in.txt)1]')],
}
# 2000 件の digest も固定する。150 件に出ない形 (cell ごとの形、2 つ目のずらし、包み) まで、版に依らないことを見る。
check "generator: the digest of seed 754 and count 2000 is the fixed value: #{G.digest(big)}",
      G.digest(big) == "432a0d9dc782b1d02c3558b6a524c027bdcf7b3a3f2dd7d4119b0565c25ff240"
check "gate: the four cells close the rotation", names.last(4) == G::GATE_FORMS.keys && G::GATE_FORMS.keys.all? { |n| G.gate?(n) } && !G.gate?("sort/glob")
check "gate: 76 of 2000 rows and 4 of 150 rows: #{gate_rows.length}", gate_rows.length == 76 && rows.count { |r| G.gate?(r.cell) } == 4
check "gate: a gate row is a string of the table, with nothing added", gate_rows.all? { |r| G::GATE_FORMS.fetch(r.cell).include?(r.command) }
check "gate: 2000 rows reach every string of the table", gate_rows.map(&:command).uniq.sort == gate_forms.sort
check "gate: no other row has an expansion", (big - gate_rows).none? { |r| r.command.match?(/[$`()]/) }
gate_forms.each { |c| check "guard accepts the gate form #{c.inspect}: #{I.guard(c).inspect}", I.guard(c).nil? }
# $ を含む形は、guard の表の形だけで出来ている (表の形を除くと、$ が残らない)。環境の変数は読まない。
without_forms = ->(c) { I::DOLLAR_FORMS.keys.reduce(c) { |text, form| text.gsub(form) { "" } } }
check "gate: every $ in the table belongs to a form of the guard's table", gate_forms.none? { |c| without_forms.call(c).include?("$") }
check "gate: the only variable a form reads is the unset one of the guard's table",
      gate_forms.flat_map { |c| c.scan(/\$\{?([A-Za-z_][A-Za-z0-9_]*)/).flatten }.uniq == ["zz"]

# operand。表が当てにする名前は、fixture の表にある。
fixture = I::FIXTURE_FIRST.keys + I::FIXTURE_SCENES.keys + I::CANARIES.select { |c| c.zone == "fx" }.map(&:rel)
check "operands: the names the tables rely on are in the fixture: #{(G::FIXTURE_PATHS - fixture).inspect}",
      (G::FIXTURE_PATHS - fixture).empty? && (G::FIXTURE_DIRS - fixture.map { |p| File.dirname(p) }).empty?
check "operands: the file slots name fixture files, and the dir slots name fixture dirs",
      %w[file gfile rb fb].all? { |slot| (G::SLOTS.fetch(slot) - G::FIXTURE_PATHS).empty? } &&
      (G::APPEND_FILES - G::FIXTURE_PATHS).empty? && (G::SLOTS.fetch("dir") + G::CD_DIRS - G::FIXTURE_DIRS).empty?
check "operands: relative names only", G::SLOTS.values.flatten.none? { |w| w.start_with?("/", "~") || w.include?("..") }
# 読むだけの command の語は、2000 件で全部出る (cd は、包みと手で置いた形から出る)。
tools = G::CELLS.find { |c| c.name == "plain/opt-after" }.bases.map(&:name)
plain = big.select { |r| r.cell.start_with?("plain/") }.map { |r| r.command.split(/[ '"]/) }
check "plain: 2000 rows reach every tool of the table: #{tools.length}",
      tools.length == 37 && tools.uniq == tools && (tools + ["cd"]).all? { |tool| plain.any? { |words| words.include?(tool) } }

# 変異の表の形。
check "mutations: the twelve names, without duplicates: #{M.names.inspect}",
      M.names == %w[plain-read-sort uniq-output-operand uniq-spec-drift find-delete git-output-option brace-expansion-off
                    glob-floor-off dq-dollar assignment-only-read custom-path-floor-off rg-glob-word-any caret-not-glob]
tool_names = I::REQUIRED_TOOLS.keys + I::OPTIONAL_TOOLS.keys
M::TABLE.each do |m|
  check "mutation #{m.name}: replaces a text with a different one", m.from.is_a?(String) && !m.from.empty? && m.to.is_a?(String) && m.from != m.to
  variant = I.variant(m.variant)
  check "mutation #{m.name}: has an expectation (invariant, tools, variant, how it shows)",
        %w[I1 I2].include?(m.invariant) && (m.needs - tool_names).empty? && !variant.nil? && M::EXPECTATIONS.include?(m.expect) &&
        !m.reopens.to_s.empty?
  # 既定でない変種だけで出る違反は、反例でなく、人に出すものになる。
  check "mutation #{m.name}: the expectation fits the variant", !variant.nil? && variant.default == (m.expect == "violation")
  measurable = !m.witnesses.empty? && m.unmeasurable.nil?
  unmeasurable = m.witnesses.empty? && m.unmeasurable.is_a?(String) && !m.unmeasurable.empty?
  check "mutation #{m.name}: has witnesses, or a reason why it cannot be measured", measurable ^ unmeasurable
  m.witnesses.each { |w| check "mutation #{m.name}: guard accepts the witness #{w.inspect}: #{I.guard(w).inspect}", I.guard(w).nil? }
end
check "mutations: fetch returns the row, and the only tool a mutation needs is rg",
      M.fetch("find-delete").name == "find-delete" && M::TABLE.flat_map(&:needs).uniq == ["rg"] && M.fetch("rg-glob-word-any").needs == ["rg"]
check "mutations: caret-not-glob is watched in zsh-extendedglob, as a finding for a human",
      M.fetch("caret-not-glob").variant == "zsh-extendedglob" && M.fetch("caret-not-glob").expect == "non-default-variant"

# 変異の当て方。小さな代役の source で見る (repo の分類器には当てない)。
standin = ->(m, times) { "module Standin\n  A = 1\n#{"  x = #{m.from}\n" * times}end\n" }
M::TABLE.each do |m|
  source = standin.call(m, 1).freeze
  check "apply #{m.name}: the one occurrence is replaced, and nothing else",
        M.apply(source, m.name) == "module Standin\n  A = 1\n  x = #{m.to}\nend\n" && source == standin.call(m, 1)
  check "apply #{m.name}: no occurrence is an error", raises.call(M::Error) { M.apply(standin.call(m, 0), m.name) }
  check "apply #{m.name}: two occurrences are an error", raises.call(M::Error) { M.apply(standin.call(m, 2), m.name) }
end
mini = <<~'SOURCE'
  module SkillBehaviorClassifier
    PLAIN_READ = %w[cat md5sum].freeze
    GLOB_CHAR = /[*?\[^]/.freeze
  end
SOURCE
check "apply: a small stand-in classifier gets sort in its plain list",
      M.apply(mini, "plain-read-sort") == mini.sub("md5sum].freeze") { "md5sum sort].freeze" } && mini.include?("md5sum].freeze")
check "apply: the backslash of a replacement is kept as it is", M.apply(mini, "caret-not-glob").include?('GLOB_CHAR = /[*?\[]/.freeze')
check "apply: a mutation whose text is not in the source is an error", raises.call(M::Error) { M.apply(mini, "find-delete") }
check "apply: an unknown name is an error", raises.call(M::Error) { M.apply(mini, "no-such-mutation") } && raises.call(M::Error) { M.fetch(nil) }
check "apply: a source that is not a string is an error", raises.call(M::Error) { M.apply(nil, "plain-read-sort") }
message = begin
  M.apply(mini, "no-such-mutation")
rescue M::Error => e
  e.message
end
check "apply: the error for an unknown name lists the known ones and does not echo the given one: #{message.inspect}",
      message.include?("plain-read-sort") && message.include?("caret-not-glob") && !message.include?("no-such-mutation")
count_message = begin
  M.apply(standin.call(M.fetch("find-delete"), 2), "find-delete")
rescue M::Error => e
  e.message
end
check "apply: the error says how many times the text occurs: #{count_message.inspect}",
      count_message == "mutation find-delete does not apply: the text to replace occurs 2 times (expected 1)"
# 入口は ProbeClassifier::Error を exit 2 にする。
check "apply: the error is a ProbeClassifier::Error", M::Error.ancestors.include?(ProbeClassifier::Error) && M::Error != ProbeClassifier::Error
check "occurrences are counted without overlap", M.occurrences("aaaa", "aa") == 2 && M.occurrences("abab", "ab") == 2 && M.occurrences("x", "ab") == 0

# docs の表が、source の表と食い違っていないこと。見るのは、名前、数、表の文字列だけ (説明の文は見ない)。
# source の表を変えたら、docs の同じ表も直す。
docs = File.read(ARGV[3])
# 「| `名前` |」で始まる表の行のうち、needles を全部含む行があるか。
row_with = ->(name, needles) { docs.lines.any? { |line| line.start_with?("| `#{name}` |") && needles.all? { |n| line.include?(n) } } }
# source の対応の文字列から、分類器の定数と関数の名前を拾う。
idents = ->(source) { source.scan(/[A-Za-z_]+\??/).select { |w| w.include?("_") || w == w.upcase }.map { |w| "`#{w}`" } }
(G::FAMILIES + [G::GATE]).each do |family|
  check "docs: the family #{family} is listed with its counterpart in the classifier", row_with.call(family, idents.call(G::SOURCES.fetch(family)))
end
G::SHIFTS.each do |shift|
  families = regular.select { |c| c.shift == shift }.map(&:family)
  listed = if families == G::FAMILIES then "| 11 の全部 |"
           elsif families == G::FAMILIES - ["ruby"] then "| `ruby` を除く 10 |"
           else "| #{families.map { |f| "`#{f}`" }.join(' ')} |"
           end
  check "docs: the shift #{shift} is listed with its families (#{listed}) and its counterpart in the classifier",
        row_with.call(shift, [listed] + idents.call(G::SHIFT_SOURCES.fetch(shift)))
end
check "docs: the wraps name their counterpart in the classifier", idents.call(G::SHIFT_SOURCES.fetch("wrap")).all? { |w| docs.include?(w) }
weights = ->(table) { 100 - table.find { |kind, _| kind.nil? }[1] }
check "docs: the number of cells, and how often a second shift and a wrap are added",
      docs.include?("cell は #{G::CELLS.length} 個ある") && docs.include?("`i mod #{G::CELLS.length}` 番目") &&
      docs.include?("2 つ目のずらしは、100 回のうち #{weights.call(G::SECOND_SHIFTS)} 回に足す") &&
      docs.include?("包みは、100 回のうち #{weights.call(G::WRAPS)} 回に足す")
G::GATE_FORMS.each do |name, forms|
  check "docs: the gate cell #{name} is listed with its strings", row_with.call(name, forms.map { |f| "`#{f}`" })
end
I::DOLLAR_FORMS.each do |form, word|
  check "docs: the guard's $ form #{form.inspect} is listed with what it is replaced by", row_with.call(form, ["| `#{word}` ("])
end
check "docs: the guard's script table is listed", I::SCRIPT_TABLE.all? { |s| docs.include?("`#{s}`") } && docs.include?("今は #{I::SCRIPT_TABLE.length} つ。")
I::FIXTURE_SCENES.keys.group_by { |p| File.dirname(p) }.each do |dir, paths|
  check "docs: the scene #{dir} is listed with its files", row_with.call(dir, paths.map { |p| "`#{File.basename(p)}`" })
end
M::TABLE.each do |m|
  needs = m.needs.empty? ? "| なし |" : "| #{m.needs.map { |n| "`#{n}`" }.join(' ')} |"
  shows = m.expect == "violation" ? "| 反例 (exit 1)" : "| 人に出す (`non-default-variant`、exit 3) |"
  check "docs: the mutation #{m.name} is listed with its invariant, tools, variant, expectation and witnesses",
        row_with.call(m.name, ["| #{m.invariant} |", needs, "| `#{m.variant}` |", shows] + m.witnesses.map { |w| "`#{w}`" })
end
head = docs.lines.index { |line| line.start_with?("| 変異 | 置き換えの要旨 |") }
listed = head ? docs.lines.drop(head + 2).take_while { |line| line.start_with?("|") } : []
check "docs: the mutation table has one row for each mutation, in the table's order: #{listed.length}",
      listed.map { |line| line[/\A\| `([a-z-]+)` \|/, 1] } == M.names

exit(@failed.zero? ? 0 : 1)
RUBY
echo "ok T7 (generator and mutations: determinism, cells, guard, gate forms, apply)"

echo "probe-classifier-invariants-test: ok"
