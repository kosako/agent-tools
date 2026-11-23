#!/bin/sh
# 分類器の不変条件の試行 (#754) の self-test。隔離 (scripts/lib/probe_classifier/isolation.rb)、判定
# (scripts/lib/probe_classifier/judge.rb)、入口 (scripts/probe-classifier-invariants.sh) を見る。
# - T1: 隔離の、sandbox の要らない部分。profile の文字列の形、閉じた環境の表、変種・canary・道具の表、guard が
#   通す形と拒む形、出力の path の置き換え、group の空の確かめ、隔離を組めないときの理由。
# - T2: 隔離の、sandbox の要る部分。否定の検査 (一時 dir の外への書き込み、HOME の代役の読み取り、127.0.0.1 への
#   接続、allowlist の外の起動、外の process への signal、親の環境の引き継ぎ、終わらない command) は、どれも対照
#   (相手を許した profile で同じ probe が通る) と組にする。
#   ほかに、sandbox を外した profile での書き込みの閉じ方、表の道具と canary の動き、変種ごとの shell の設定、
#   command ごとの新しい一時 dir を見る。
# - T3: 判定の、sandbox の要らない部分。手で変えた tree の差分の種類、終わり方の区分、拒まれた起動の拾い方、
#   違反と人に出すものの分け方、確かめ直し (走らせる部分を差し替えて見る)。
# - T4: 判定の、sandbox の要る部分 (witness)。書き込む形が I1、canary を走らせる形が I2、書かない形が差分なしに
#   なること、表に無い program の起動が人に出ること、書き込みの後に終わらない形でも I1 が出ること。
# - T5: 入口の、sandbox の要らない部分。引数の誤り、出力先の検査、guard の拒否、read でない command。
# - T6: 入口の、sandbox の要る部分。--preflight と、read の command を走らせた結果の file。
# sandbox を適用できない環境 (入れ子の sandbox の中など) では T2・T4・T6 を skip して 1 行出す。CI
# (GITHUB_ACTIONS=true) では skip せず失敗にする。skip の判断は T2 の中の 1 か所で行う。
# 走らせる command は、この test の一時 dir の中で、相対 path だけを使う。否定の検査の probe だけは、同じ一時 dir に
# 作った代役 (外の dir、HOME の代役、偽の CLI) と /bin/date を絶対 path で指す。network は test が自分で開いた
# 127.0.0.1 の port だけ。本物の codex・claude・gh・opencode・herdr は起動しない (PATH の canary に当たる)。rg は使わない。
# 入口の test は、分類器の代役 (何でも read と答える小さな file) を渡す。repo の分類器の今の穴に結び付けないため。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

isolation="$repo_root/scripts/lib/probe_classifier/isolation.rb"
judge="$repo_root/scripts/lib/probe_classifier/judge.rb"
probe="$repo_root/scripts/probe-classifier-invariants.sh"
[ -f "$isolation" ] || fail "missing $isolation"
[ -f "$judge" ] || fail "missing $judge"
[ -x "$probe" ] || fail "missing or not executable: $probe"

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

# guard が通す形。手書きの受け入れの command (K1 から K4 を含む) と、生成器が出す門の外の形。
accept = [
  "uniq in.txt -c", %q(sed -n '/a\/,/w lib/p' x), "git branch --format --list x", "sort -o out.txt in.txt",
  "./cat x", "git status", "env done rm x", "'fi' rm x", "cat in.txt 2>/dev/null", "cat x 2>&1 | wc -l",
  "cat in.txt >&2", "cat in.txt &>/dev/null", "cd lib && cat median.rb", "ruby -c lib/median.rb", "bin/grep a in.txt",
  "sort $'-o' out.txt in.txt", %q(sort "${zz:--o}" out.txt in.txt), "zsh -lc 'cat in.txt'", "sh -c 'cat in.txt'",
  "find . -name x -exec cat {} +", "find . -name '*.rb'", "echo in.txt | xargs -n 1 cat", "echo in.txt | xargs grep -o a",
  "tail -n 2 in.txt | cut -f1", "tail +2 in.txt", "grep -F a in.txt | tail -n 1", "cat lib/*.rb", "cat x/{a,b}.md", "sort {-o,out.txt} in.txt",
  "git -C . status", "git log --format=%H", "cat {in,x}.txt", "echo in.txt | xargs -I{} cat {}", "uniq - -c", "cat in.txt; cat x", %q(ruby -e 'puts [1, 2].sum'), "echo ^in.txt",
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
  "cat a:/b" => "abs-path", "cat \\/etc/hosts" => "abs-path", "cat `pwd`/x" => "abs-path", "sort --output=/abs in.txt" => "abs-path",
  "x=/abs cat" => "abs-path", "cat x > /dev/null" => "abs-path", "cat x >/dev/nullx" => "abs-path", "cat x 2>/dev/null/x" => "abs-path",
  "sort $'-o'/abs in.txt" => "abs-path",
  # 短い option に付いた path、zsh の =name、brace と glob が作る ..。
  "git -C/x status" => "option-path", "sort -o/abs in.txt" => "option-path", "cat =ls" => "equals-word",
  "cat .{.,a}" => "brace-dot", "cat {.,x}./y" => "brace-dot", "cat {a,}." => "brace-dot", "cat x/{..,y}" => "dotdot",
  "tail -{f,F} x" => "brace-glued", "xargs -{p,t} cat" => "brace-glued", "{ta,x}il -f x" => "brace-glued",
  "ta{il,x} -f x" => "brace-glued", "{g,x}{h,y} api" => "brace-glued", "tail '-'{f,F} x" => "brace-glued",
  "tail -{f,{F,x}} x" => "brace-glued",
  "cd .?/marks && uniq - -c" => "glob-dot", "cat .*" => "glob-dot", "cat ./.*/x" => "glob-dot", "cat '.'*" => "glob-dot",
  # 語の位置に依らない形 (前置き、xargs、find -exec、brace、入れ子の shell)。
  "xargs tail -f" => "tail-follow", "find . -exec tail -F {} +" => "tail-follow", "env tail -f x" => "tail-follow",
  "{tail,-f} x" => "tail-follow", "sh -c 'tail -f x'" => "tail-follow", "sh -c \"sh -c 'tail -f x'\"" => "tail-follow",
  "zsh -lc \"gh api x\"" => "gh", "git -C . remote show x" => "git-remote", "xargs -0p cat" => "xargs-tty",
  "xargs -n 1 -p cat" => "xargs-tty", "xargs -E eof -o cat" => "xargs-tty", "xargs -I {} -p cat {}" => "xargs-tty",
  "cd fx tools" => "cd-args", "builtin cd fx tools" => "cd-args",
  # 外の process への signal。
  "kill -9 -1" => "signal", "echo 1 | xargs kill" => "signal", "sh -c 'kill -0 1'" => "signal", "killall zsh" => "signal",
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
check "guard: the table matches the whole quoted word", I.guard("sed -n '/x/p;w /abs' in.txt", scripts: ["/x/p"]) == "abs-path"
check "guard: the rest of the command is still checked", I.guard("sed -n '/x/p' ../in.txt", scripts: ["/x/p"]) == "dotdot"
check "guard: the dollar table is closed", I.guard("sort $'-o' out.txt in.txt", dollar_forms: []) == "dollar"

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

# 1 件の command を走らせる入口。block には走らせる前の layout が渡り、command ごとに新しい一時 dir になる。
seen_before = nil
first = session.run_command("sort -o out.txt in.txt") { |l| seen_before = File.exist?(File.join(l.fx, "out.txt")) }
check "run_command yields the layout before the launch", seen_before == false && File.file?(File.join(first.layout.fx, "out.txt"))
check "run_command returns how the command ended",
      first.exit_code == 0 && first.signal.nil? && first.timed_out == false && first.group_empty == true &&
      first.sandbox_error == false && first.variant == "zsh" && first.command == "sort -o out.txt in.txt"
second = session.run_command("ls; pwd; env; git log --oneline | wc -l; uniq -c in.txt; cat x")
check "each command gets a new temp dir", second.layout.base != first.layout.base && !second.out.lines.include?("out.txt\n")
out = second.out.lines.map(&:chomp)
check "the fixture: files and canaries", (%w[README.md in.txt x lib cat bin canary_begin.rb] - out).empty?
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
# fixture の中の実行できる file は canary だけ (git init が置く hook の見本を残さない)。
executables = Dir.glob(File.join(layout.fx, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) && File.executable?(p) }
check "the fixture has no executable file other than the canaries: #{executables.length}",
      executables.map { |p| p.sub("#{layout.fx}/", "") }.sort == %w[bin/grep cat]
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
  "fx/new.txt" => ["created"], "fx/quiet" => ["dir-mtime"], "fx/replaced.txt" => ["rewrite"],
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
  # 最後の終了 code が 0 でも、stderr の行から拾う (/bin/date; echo x)。
  ["/bin/bash: /bin/date: Operation not permitted\n", 0] => ["/bin/date"],
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
].each { |err, code| check "denied-exec: not reported for #{err.inspect} exit #{code}", denied.call(err, code) == [] }
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
      v.violations == [i1] && v.ending == "timeout" && v.timed_out == true && v.unmeasured.nil?
v = J.judge(before: still, after: wrote, run: fake.call(exit_code: 1, err: "uniq: x\n"))
check "judge: a failed ending does not drop the violation", v.violations == [i1] && v.ending == "nonzero"
v = J.judge(before: still, after: wrote, run: fake.call(group_empty: false))
check "judge: a run whose group is not confirmed empty is unmeasured, and keeps what was seen", v.unmeasured == "group-not-empty" && v.violations == [i1]
v = J.judge(before: still, after: still, run: fake.call(group_empty: false))
check "judge: an unmeasured run without a diff is not clean", v.unmeasured == "group-not-empty" && v.violations.empty? && !v.clean?
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
o, = examine.call("zsh-extendedglob", "zsh-extendedglob" => [verdict_of.call([i1])] * 3,
                                      "zsh" => [verdict_of.call([i1]), verdict_of.call([]), verdict_of.call([i1])])
check "examine: flaky in the default variant is not a confirmation there", o.violations.empty? && o.human == [{ "reason" => "non-default-variant" }.merge(i1)]
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

# 引数の誤りは exit 2。生成の入口の引数は、まだ受けない。
for later in "--seed 754" "--count 3" "--run" "--baseline $stub" "--mutation plain-read-sort"; do
  # shellcheck disable=SC2086
  run_cli 2 "later option ($later)" --out "$tmp/o-later" --command 'cat README.md' --classifier "$stub" $later
  grep -q 'is not available yet' "$tmp/cli.err" || fail "later option ($later): missing the reason: $(cat "$tmp/cli.err")"
  [ ! -e "$tmp/o-later" ] || fail "later option ($later): --out must not be created"
done
run_cli 2 "no arguments"
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
echo "ok T5 (entry: arguments, --out, guard, classification)"

# --- T6: 入口 (sandbox の要る部分) -----------------------------------------------------------
if [ "$sandbox" = yes ]; then
  run_cli 0 "preflight" --preflight --out "$tmp/o-pre"
  grep -q '^preflight: ok (11 checks)$' "$tmp/cli.out" || fail "preflight: missing the ok line: $(cat "$tmp/cli.out")"
  no_abs_paths "preflight" "$tmp/o-pre/results.json" "$tmp/cli.out" "$tmp/cli.err"
  # K1 の形。代役の分類器が read と答えるので走り、fx/-c の作成が I1 になる。
  run_cli 1 "command with a write" --out "$tmp/o-k1" --command 'uniq in.txt -c' --classifier "$stub"
  no_abs_paths "command with a write" "$tmp/o-k1/results.json" "$tmp/cli.out" "$tmp/cli.err"
  run_cli 0 "command without a write" --out "$tmp/o-cat" --command 'cat README.md' --classifier "$stub" --variant sh
  no_abs_paths "command without a write" "$tmp/o-cat/results.json" "$tmp/cli.out" "$tmp/cli.err"
  [ ! -e "$tmp/o-pre/corpus.jsonl" ] && [ ! -e "$tmp/o-k1/corpus.jsonl" ] || fail "--preflight and --command must not write corpus.jsonl"
  # 既定でない変種でだけ書き込む形 (nullglob では合わない glob が消え、-o が in.txt を取る)。既定の zsh では合わない glob で
  # 止まるので、反例に数えず、人に出すものだけになる (exit 3)。
  run_cli 3 "command that writes only under a non-default variant" --out "$tmp/o-ng" --command 'sort -o nomatch* in.txt' \
    --classifier "$stub" --variant zsh-nullglob
  grep -q '^  human non-default-variant fx/in.txt$' "$tmp/cli.out" || fail "non-default variant: missing the line: $(cat "$tmp/cli.out")"
  no_abs_paths "non-default variant" "$tmp/o-ng/results.json" "$tmp/cli.out" "$tmp/cli.err"
  ruby -r"$script_dir/lib/check_helper" -rjson - "$tmp/o-pre/results.json" "$tmp/o-k1/results.json" "$tmp/o-cat/results.json" \
    "$tmp/o-ng/results.json" <<'RUBY'
pre = JSON.parse(File.read(ARGV[0]))
k1 = JSON.parse(File.read(ARGV[1]))
cat = JSON.parse(File.read(ARGV[2]))
ng = JSON.parse(File.read(ARGV[3]))
found = ng["human"][0] || {}
check "non-default variant: no counterexample, one finding for a human with the command and the variant: #{ng['human'].inspect}",
      ng["violations"] == [] && ng["human"].length == 1 && found["reason"] == "non-default-variant" &&
      found["command"] == "sort -o nomatch* in.txt" && found["variant"] == "zsh-nullglob" && found["invariant"] == "I1" &&
      found["paths"] == ["fx/in.txt"] && ng["variant"] == "zsh-nullglob"
check "non-default variant: three runs in the variant, then the default variant of the same shell",
      ng["runs"].map { |r| r["variant"] } == %w[zsh-nullglob zsh-nullglob zsh-nullglob zsh] && ng["counts"]["executed"] == 1
check "preflight results: mode and every check passed: #{pre.inspect}",
      pre["mode"] == "preflight" && pre["preflight"]["ok"] == true && pre["preflight"]["unavailable"] == false &&
      pre["preflight"]["checks"].length == 11 && pre["preflight"]["checks"].all? { |c| c["ok"] == true } && pre["preflight"]["reasons"] == []
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
  echo "ok T6 (entry: preflight and a command in isolation)"
fi

echo "probe-classifier-invariants-test: ok"
