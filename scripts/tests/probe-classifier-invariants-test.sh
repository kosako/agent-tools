#!/bin/sh
# 分類器の不変条件の試行 (#754) の self-test。今あるのは隔離 (scripts/lib/probe_classifier/isolation.rb) の部分。
# - T1: sandbox の要らない部分。profile の文字列の形、閉じた環境の表、変種・canary・道具の表、guard が通す形と
#   拒む形、出力の path の置き換え、group の空の確かめ、隔離を組めないときの理由。
# - T2: sandbox の要る部分。否定の検査 (一時 dir の外への書き込み、HOME の代役の読み取り、127.0.0.1 への接続、
#   allowlist の外の起動、外の process への signal、親の環境の引き継ぎ、終わらない command) は、どれも対照
#   (相手を許した profile で同じ probe が通る) と組にする。
#   ほかに、sandbox を外した profile での書き込みの閉じ方、表の道具と canary の動き、変種ごとの shell の設定、
#   command ごとの新しい一時 dir を見る。
# sandbox を適用できない環境 (入れ子の sandbox の中など) では T2 を skip して 1 行出す。CI (GITHUB_ACTIONS=true)
# では skip せず失敗にする。
# 走らせる command は、この test の一時 dir の中で、相対 path だけを使う。否定の検査の probe だけは、同じ一時 dir に
# 作った代役 (外の dir、HOME の代役、偽の CLI) を絶対 path で指す。network は test が自分で開いた 127.0.0.1 の
# port だけ。本物の codex・claude・gh・opencode・herdr は起動しない (PATH の canary に当たる)。rg は使わない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

isolation="$repo_root/scripts/lib/probe_classifier/isolation.rb"
[ -f "$isolation" ] || fail "missing $isolation"

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
  puts "skip T2: #{pre.reasons.join('; ')}"
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
canaries = session.run_command("./cat x; bin/grep a in.txt; ruby canary_begin.rb; env done rm x; 'fi' rm x; codex exec hi")
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

echo "probe-classifier-invariants-test: ok"
