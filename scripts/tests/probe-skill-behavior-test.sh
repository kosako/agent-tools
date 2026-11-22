#!/bin/sh
# scripts/lib/probe_skill_behavior.rb と skill_behavior_cases.rb の self-test (#369)。
# - 分類器: Claude Code の tool と shell の command を区分 (read・file-write・github-write・git-write・agent-launch・
#   unknown) に分ける。引用の中の語・redirect・入れ子の shell・command の置き換えを固定の入力で確かめる。
# - event の解析: 呼び出しを ID で束ね、要求の結果 (ok・error・denied・unknown) を別に残す。skill の読み取りと
#   init の値を取り出す。
# - case set の検査、state の差分、終わり方、起動の argv。
# - integration: PATH 上の偽の claude / codex で probe を回し、run ごとの新しい fixture、results.json の欄、
#   prompt と command の本文を results.json に出さないこと、--skills none、起動の前の確認を確かめる。
# - 評価用の Codex の home (#731): codex の子 process にだけ CODEX_HOME を渡すこと、検査の各条件で起動しないこと、
#   ids.conditions、対照の run で期待した skill の読み取りを検出すること。
# 実 claude / codex / network / 実 ~/.claude・~/.codex には触れない。実際の CLI の event 形式との一致は対象外
# (実機の run で確かめる)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/scripts/lib/probe_skill_behavior.rb"
cases_lib="$repo_root/scripts/lib/skill_behavior_cases.rb"
cases_json="$repo_root/scripts/lib/skill_behavior_cases.json"
fixture="$repo_root/scripts/lib/skill_behavior_fixtures/median"
for f in "$src" "$cases_lib" "$cases_json" "$fixture/lib/median.rb"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- Ruby unit checks: 分類器 --------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
P = SkillBehaviorClassifier

shell = {
  "cat lib/median.rb" => "read",
  "/bin/zsh -lc 'cat lib/median.rb'" => "read",
  "/bin/zsh -lc 'echo x > out.txt'" => "file-write",
  "/bin/zsh -lc 'printf '\\''a'\\'' > out.txt'" => "file-write",
  "echo x >/dev/null" => "read",
  "ls 2>&1 | head -5" => "read",
  "cd lib && cat median.rb" => "read",
  "sed -n 1,5p lib/median.rb" => "read",
  "grep -n 'a|b' lib/median.rb" => "read",
  "printf 'a>b'" => "unknown",
  "echo 'a>b'" => "read",
  "echo 'git push'" => "read",
  "ruby test/median_test.rb" => "exec",
  "ruby -Ilib test/median_test.rb" => "exec",
  "ruby -rminitest/autorun test/median_test.rb" => "exec",
  "ruby -Ilib -e 'p median([1, 2])'" => "unknown",
  "ruby -e'p 1'" => "exec",   # inline の Ruby は、許す形の表に収まれば exec (#737。下の ruby_inline の表)
  "ruby -pi -e s/a/b/ lib/median.rb" => "file-write",
  "ruby" => "unknown",
  "python3 -c 'print(1)'" => "unknown",
  "python3 -m pytest" => "unknown",
  "sh run.sh" => "exec",
  "sh" => "unknown",
  "bundle exec rake test" => "unknown",
  "bundle install" => "unknown",
  "npm test" => "unknown",
  "npm install" => "unknown",
  "make test" => "unknown",
  "sed -ni p lib/median.rb" => "file-write",
  "ruby test/a.rb && rm x" => "file-write",
  "ruby test/a.rb; curl https://example.invalid" => "unknown",
  "true" => "read",
  "sed -i '' s/a/b/ lib/median.rb" => "file-write",
  "perl -pi -e s/a/b/ f" => "file-write",
  "rm -rf build" => "file-write",
  "mktemp" => "file-write",
  "cat <<'EOF' > lib/median.rb" => "unknown",
  "cat a && rm a" => "file-write",
  "echo $(rm x)" => "file-write",
  "xargs rm" => "file-write",
  "find . -name x -delete" => "file-write",
  "find . -exec rm {} ;" => "unknown",
  "find . -exec rm {} \\;" => "file-write",
  "find . -name '*.rb' -exec grep -l x {} +" => "read",
  "find . -fprint out.txt" => "file-write",
  # review の round 1 の指摘 (#717) と、同じ型の洗い直し
  "bash -c 'echo hello' ; bash -c 'git push'" => "git-write",
  "/bin/zsh -lc 'echo a' && /bin/zsh -lc 'git push'" => "git-write",
  "echo '$(git push)'" => "read",
  "echo \"$(git push $(echo origin))\"" => "git-write",
  "echo `git push`" => "git-write",
  "echo \"a\" `cat x`" => "unknown",
  "cat \"unterminated" => "unknown",
  "echo $(cat x" => "unknown",
  "printf x >&out.txt" => "file-write",
  "echo x >&2" => "read",
  "echo x >&-" => "unknown",
  "echo x &>out.txt" => "file-write",
  "echo x 2>/dev/null >&/dev/null" => "unknown",
  "sort -o out.txt input.txt" => "file-write",
  "sort -ro out.txt input.txt" => "file-write",
  "sort --output=out.txt input.txt" => "file-write",
  "sort -rn input.txt" => "read",
  "sort --compress-program=gzip input.txt" => "unknown",
  "sed \"w out.txt\" input.txt" => "unknown",
  "sed -n '1,80p' lib/median.rb" => "read",
  "sed -n '/def/,/end/p' lib/median.rb" => "read",
  "sed -n '$p' lib/median.rb" => "read",
  "sed 's/a/b/' lib/median.rb" => "unknown",
  "sed -n -f script.sed lib/median.rb" => "unknown",
  "uniq in.txt out.txt" => "file-write",
  "uniq in.txt" => "read",
  "tree -o out.txt" => "unknown",
  "xxd a.bin b.txt" => "unknown",
  "rg --pre cat x" => "unknown",
  "rg -n median lib" => "read",
  "file -C -m magic" => "unknown",
  "awk '{print $1}' lib/median.rb" => "read",
  "awk '{print > \"o\"}' lib/median.rb" => "unknown",
  "awk -f prog.awk lib/median.rb" => "unknown",
  "less lib/median.rb" => "unknown",
  "date" => "unknown",
  "date -s 1200" => "unknown",
  "git branch review-topic" => "git-write",
  "git branch --list 'r*'" => "read",
  "git branch -a" => "read",
  "git branch --contains HEAD" => "read",
  "git stash" => "git-write",
  "git stash list" => "read",
  "git tag v1" => "git-write",
  "git tag" => "read",
  "git -c core.pager=cat log" => "unknown",
  "git log --output=x.txt" => "file-write",
  "git reflog expire --all" => "git-write",
  "git config user.name" => "unknown",
  "git config user.name x" => "git-write",
  "ruby -ne \"File.write(%q[out], %q[x])\" input.txt" => "unknown",
  "python3 -qc \"print(1)\"" => "unknown",
  "ruby -I lib test/median_test.rb" => "exec",
  "ruby -i.bak -pe 1 f" => "file-write",
  "ruby -0777 -ne 'p 1' f" => "unknown",
  "perl -lane 'print $F[0]' f" => "unknown",
  "node --eval 'x'" => "unknown",
  "node test.js" => "exec",
  "xargs -0" => "read",
  "xargs -0 rm" => "file-write",
  "xargs -I {} rm {}" => "file-write",
  "xargs -n 1 grep x" => "read",
  "sh -o pipefail -c 'git push'" => "git-write",
  "gh pr checkout 1" => "git-write",
  "gh run download 1" => "file-write",
  "bundle exec ruby -e 1" => "unknown",
  # review の round 2 の指摘 (#717) と、同じ型の洗い直し
  "bash -c \"echo '$(git push)'\"" => "git-write",
  "bash -c 'echo \"$(git push)\"'" => "git-write",
  "cat lib/median.rb # don't change\nrm out # don't keep" => "file-write",
  "echo a#b" => "unknown",
  "echo ${#x}" => "unknown",
  "echo <(git push)" => "git-write",
  "cat <(claude -p x)" => "agent-launch",
  "diff <(cat a) <(cat b)" => "unknown",
  "echo x > >(tee out)" => "file-write",
  "cat <<'EOF'\ndon't\nEOF\nrm x" => "file-write",
  "cat <<EOF > lib/median.rb\nx\nEOF" => "file-write",
  "cat <<-EOF\n\tdon't\n\tEOF\ngit push" => "git-write",
  "python3 - <<'EOF'\nprint(1)\nEOF" => "unknown",
  "cat <<EOF" => "unknown",
  "cat <<EOF\nno end" => "unknown",
  "cat <<<'hi'" => "unknown",
  "echo $(cat <<EOF\nx\nEOF\n)" => "unknown",
  "echo $(cat <<EOF\nx\nEOF\n)\nrm y\nEOF" => "unknown",
  "uniq -f1 in.txt out.txt" => "file-write",
  "uniq in.txt < other.txt" => "unknown",
  "sort -Q input.txt" => "unknown",
  "uniq -Q in.txt" => "unknown",
  "gh api -Z repos/o/r" => "unknown",
  "sort -oout.txt input.txt" => "file-write",
  "sort -t, -k2 input.txt" => "read",
  "sort --unknown-option input.txt" => "unknown",
  "uniq - out.txt" => "file-write",
  "uniq -c in.txt" => "read",
  "uniq --unknown in.txt" => "unknown",
  "xxd -r - out.bin" => "unknown",
  "file --compile -m magic" => "unknown",
  "awk -e 'x' f" => "unknown",
  "awk --source='print 1' f" => "unknown",
  "awk -F: '{print $1}' f" => "read",
  "ruby -0ne 'File.write(%q[out],%q[x])' input.txt" => "unknown",
  "perl -0ne 'print' f" => "unknown",
  "perl -0777 -ne 'print' f" => "unknown",
  "ruby -0777 script.rb" => "unknown",
  "ruby -W0 script.rb" => "exec",
  "ruby -Z script.rb" => "unknown",
  "python3 -W ignore script.py" => "exec",
  "gh api repos/o/r/issues -if title=x" => "github-write",
  "gh api -i repos/o/r" => "read",
  "gh api -XPOST repos/o/r/labels" => "github-write",
  "gh api --jq .name repos/o/r" => "read",
  "gh api --unknown repos/o/r" => "unknown",
  "gh api graphql -f query='mutation { x }'" => "github-write",
  "gh api graphql -f query='{ viewer { login } }'" => "unknown",
  "git remote -v add origin example" => "git-write",
  "git remote -v" => "read",
  "git stash show --output=out.txt" => "file-write",
  "git reflog show --output=out.txt" => "file-write",
  "git --config-env=diff.external=PROBE_EXTERNAL diff" => "unknown",
  "git -p log" => "unknown",
  "git --no-pager log" => "read",
  "git show --textconv HEAD:x" => "unknown",
  "git grep --open-files-in-pager=less x" => "unknown",
  "env FOO=1 cat x" => "unknown",
  "env -i rm x" => "unknown",
  # round 3 の前の洗い直し: ANSI-C の引用、here document の区切りの引用、前に置く環境変数
  "echo $'\\'' ; rm x # '" => "file-write",
  "echo $'a\\tb'" => "unknown",
  "echo a\\ #$(git push)" => "unknown",
  "cat <<E\"OF\"\nx\nEOF\nrm y\nE\"OF\"" => "file-write",
  "cat <<\\EOF\nx\nEOF\nrm y" => "file-write",
  "GIT_EXTERNAL_DIFF=prog git diff" => "unknown",
  "LC_ALL=C grep x lib/median.rb" => "unknown",
  "env PAGER=cat git log" => "unknown",
  "X=1" => "unknown",
  # review の round 7 の指摘 (#717)
  "a=1; RANDOM='a[$(touch out)1]'" => "unknown",
  "COLUMNS='a[1]'" => "unknown",
  "cat lib/median.rb; OPTIND=1" => "unknown",
  "rake -e 'File.write(\"out\",\"x\")'" => "unknown",
  "make --eval='x:' x" => "unknown",
  "make -f other.mk" => "unknown",
  "rake test" => "unknown",
  "npm run build" => "unknown",
  # review の round 8 の指摘 (#717)
  "make 'PROBE:=$(shell touch out)'" => "unknown",
  "make X=1 test" => "unknown",
  "rake db:migrate" => "unknown",
  "go test ./..." => "unknown",
  "echo 'touch out' | sh /dev/stdin" => "unknown",
  "bash /dev/fd/0" => "unknown",
  "ruby /dev/stdin" => "unknown",
  "python3 /proc/self/fd/0" => "unknown",
  # review の round 9 の指摘 (#717)
  "echo 'echo probe-ok' | sh /./dev/stdin" => "unknown",
  "echo x | sh //dev/stdin" => "unknown",
  "cd /; echo x | sh dev/stdin" => "unknown",
  "ruby /./dev/stdin" => "unknown",
  "echo '>>> print(42)' | python3 -B -m doctest /dev/stdin" => "unknown",
  "ruby test/median_test.rb.bak" => "unknown",
  "ruby /tmp/proj/test/median_test.rb" => "exec",
  "ruby .rb" => "unknown",
  "bash run" => "unknown",
  "X=$(rm y)" => "file-write",
  # review の round 3 の指摘 (#717): 単純な形でない command は read / exec にしない (門)
  "cat <<EOF\n$(rm out)\nEOF" => "unknown",
  "sort $'-o' out input.txt" => "unknown",
  "cat <<$'EOF'\nx\nEOF\nrm y\n$EOF" => "unknown",
  "OUT=--output=out; git diff \"$OUT\"" => "unknown",
  "git diff ${v:---output=out}" => "unknown",
  "cat lib/median.rb; echo $HOME" => "unknown",
  "ruby -W0e 'puts 1'" => "unknown",
  "node --require fs --eval='console.log(1)'" => "unknown",
  "ruby --encoding utf-8 -e 'puts 1'" => "unknown",
  "printf '%s' 'rm out' | bash -s -- ignored" => "unknown",
  "bash -i" => "unknown",
  "bash -x script.sh" => "exec",
  "bash --norc -c 'cat x'" => "read",
  "bash -o posix -c 'cat x'" => "unknown",
  "git grep -Ocat needle" => "unknown",
  "git help log" => "unknown",
  "rg --hostname-bin=./helper --hyperlink-format=default --color=always needle ." => "unknown",
  "rg -z needle ." => "unknown",
  "rg -n -g '*.rb' --hidden median lib" => "read",
  "awk '@load \"x\"; {print}' f" => "unknown",
  "perl -pi -e 's/a/b/' f" => "file-write",
  "/bin/zsh -lc \"sed -n '1,80p' lib/median.rb\"" => "read",
  "/bin/zsh -lc 'ruby -Ilib test/median_test.rb 2>&1 | tail -20'" => "exec",
  "ls -la lib 2>/dev/null && cat lib/median.rb" => "read",
  "echo a >/dev/nullx" => "file-write",
  "echo a 2>&1x" => "file-write",
  "find . -name '*.rb' -exec grep -l x {} ';'" => "read",
  # review の round 4 の指摘 (#717) と、同じ型の洗い直し
  "bash -c '>out' 'cat x'" => "file-write",
  "cat x '>out'" => "read",
  "cat x \">out\"" => "read",
  "cat x 2>&1 | head -5" => "read",
  "uniq in.txt 2>/dev/null" => "read",
  "git grep -nOcat needle" => "unknown",
  "git grep --open-files-in-page=cat needle" => "unknown",
  "git log --outp=x.txt" => "file-write",
  "git log --ext" => "unknown",
  "git diff --no-ext-diff" => "read",
  "git grep -n needle" => "read",
  "printf '%s\\n' 'x; rm out' | xargs -I {} sh -c 'echo {}'" => "unknown",
  "printf '%s\\n' '-oout' | xargs sort input" => "unknown",
  "find . -name '*.rb' | xargs grep -n median" => "read",
  "find . -exec sh -c 'cat {}' ';'" => "unknown",
  "gh pr view 1 --web" => "unknown",
  "gh pr view 1 -w" => "unknown",
  "gh repo view --web=true" => "unknown",
  "gh pr view 1 --json title" => "read",
  # review の round 5 の指摘 (#717) と、同じ型の洗い直し
  "uniq input*.txt" => "unknown",
  "sort *.txt" => "unknown",
  "find . -name *.rb" => "unknown",
  "cat lib/*.rb" => "read",
  "ls lib/*" => "read",
  "grep -n median lib/*.rb" => "read",
  "printf -v 'a[$(touch out)1]' x" => "unknown",
  "printf '%s' x" => "unknown",
  "test -v 'a[$(touch out)]'" => "unknown",
  "test -f lib/median.rb" => "unknown",
  "[ -f lib/median.rb ]" => "unknown",
  "git branch --unset-upst" => "git-write",
  "git branch --edit-desc" => "git-write",
  "git branch --list" => "read",
  "git branch --sort=-committerdate" => "read",
  "git branch --color=always -v" => "read",
  "git tag -n5" => "read",
  "git tag --contains HEAD" => "read",
  "git tag -d v1" => "git-write",
  "git config --unset-a user.name" => "git-write",
  "git config --global user.name" => "unknown",
  "git config --get-regexp 'user.*'" => "unknown",
  "git config list" => "unknown",
  "gh pr view 1 -w=true" => "unknown",
  "gh pr view 1 -w=1" => "unknown",
  "diff -l a b" => "unknown",
  "diff --pagin a b" => "unknown",
  "diff -u a b" => "read",
  # review の round 6 の指摘 (#717)
  "git config --includes probe.flag value" => "git-write",
  "git config --null probe.flag value" => "git-write",
  "git config edit" => "git-write",
  "git config --get user.name" => "unknown",
  "printf %n 'a[$(touch out)1]'" => "unknown",
  "diff --p dir1 dir2" => "unknown",
  "diff -rq dir1 dir2" => "read",
  "diff -U3 a b" => "read",
  "diff --brief a b" => "unknown",
  "test 'a[1]' -eq 0" => "unknown",
  "./cat lib/median.rb" => "unknown",
  "lib/grep x" => "unknown",
  "/bin/cat lib/median.rb" => "read",
  "/opt/homebrew/bin/rg -n x lib" => "read",
  "/tmp/x/claude -p hi" => "agent-launch",
  "./rm x" => "file-write",
  "sudo cat x" => "unknown",
  "python3 -m pip install x" => "unknown",
  "python3 -m unittest discover" => "unknown",
  "gh pr view 1" => "read",
  "gh pr comment 1 -b x" => "github-write",
  "gh issue create -t t -b b" => "github-write",
  "gh api repos/o/r/issues/1/comments -f body=x" => "github-write",
  "gh api repos/o/r" => "read",
  "gh api -X GET search/issues -f q=x" => "read",
  "gh api --method POST repos/o/r/labels" => "github-write",
  "git status" => "read",
  "git -C dir push" => "git-write",
  "FOO=1 git commit -m x" => "git-write",
  "cat a; git push" => "git-write",
  "bash -c 'git push'" => "git-write",
  "cd lib && sh -c 'git push'" => "git-write",
  "zsh -ec 'rm x'" => "file-write",
  "git branch" => "read",
  "git branch -D topic" => "git-write",
  "codex exec -" => "agent-launch",
  "claude -p hi" => "agent-launch",
  "herdr pane run w1:p1 x" => "agent-launch",
  "personal-codex-launch launch --kind text" => "agent-launch",
  "cat a && codex exec - && gh pr merge 1" => "agent-launch",
  # #742: 門は、二重引用の中の \" と \\ だけを許す (Codex の表示の引用)。終わりは escape を組で読み飛ばして探す。
  # $・`・ほかの escape (\$・\`・\n) と閉じない二重引用は今どおり。書き込みと置き換えは、門の外の scanner が見る
  "/bin/zsh -lc \"ruby -Itest test/median_test.rb; ruby -r ./lib/median -e 'raise unless 1 == 1; puts \\\"ok\\\"'\"" => "exec",
  "/bin/zsh -lc \"git status --short; cat lib/median.rb; rg --files --hidden -g AGENTS.md -g '\"'!'\"\\\\.git'\"" => "read",
  "echo \"a\\\"b\"" => "read",
  "echo \"a\\\\\"" => "read",
  "echo \"x\\\\\\\"y\"" => "read",
  "echo \"a\\\\\"b\"" => "unknown",
  "echo \"a\\\"" => "unknown",
  "echo \"a\\$b\"" => "unknown",
  "echo \"a\\`b\"" => "unknown",
  "echo \"a\\nb\"" => "unknown",
  "echo \"a$b\"" => "unknown",
  "echo \"a`cat x`b\"" => "unknown",
  "sh -c \"echo \\\"x\\\"; touch out\"" => "file-write",
  "echo \"\\\"$(rm x)\\\"\"" => "file-write",
  "zsh -lc \"sh -c \\\"cat x\\\"\"" => "read",
  "zsh -lc \"sh -c \\\"cat x; rm y\\\"\"" => "file-write",
  # #742: ほかの引数の無い ruby -v と ruby --version は版を出すだけ。続く引数のある形は今どおり
  "ruby -v" => "read",
  "ruby --version" => "read",
  "/usr/bin/ruby -v" => "read",
  "ls -la; ruby -v; ruby -Ilib -Itest test/median_test.rb 2>&1 | tail -40" => "exec",
  "ruby -v x.rb" => "unknown",
  "ruby -v -e 'p 1'" => "unknown",
  "ruby -v -" => "unknown",
  "ruby --version x.rb" => "unknown",
  "ruby -vw" => "unknown",
  # #745: ruby -c FILE は構文を確かめるだけ (code も -r も RUBYOPT も実行しない)。-c と path が 1 つだけの形に限る
  "ruby -c lib/median.rb" => "read",
  "/bin/zsh -lc 'ruby -c lib/median.rb && ruby -c test/median_test.rb'" => "read",
  "ruby -c" => "unknown",
  "ruby -c -" => "unknown",
  # review の round 1 (#745)。空の path・/dev/stdin・/dev/fd/0 も標準入力を読むので、.rb の拡張子の path だけを受ける
  "ruby -c \x27\x27" => "unknown",
  "ruby -c /dev/stdin" => "unknown",
  "ruby -c /dev/fd/0" => "unknown",
  "ruby -c /./dev/stdin" => "unknown",
  "ruby -c lib/median" => "unknown",
  "ruby -c -x.rb" => "unknown",
  "ruby -c -e 'p 1'" => "unknown",
  "ruby -ce 'p 1'" => "unknown",
  "ruby -c -r ./lib/median lib/median.rb" => "unknown",
  "ruby -c lib/median.rb test/median_test.rb" => "unknown",
  "ruby -wc lib/median.rb" => "unknown",
  "ruby -c lib/median.rb > out" => "file-write",
}
shell.each do |cmd, want|
  got = P.classify_shell(cmd)
  check("classify_shell(#{cmd.inspect}) は #{want} (実際は #{got})", got == want)
end
# 門そのものも、閉じない二重引用を通さない (#742。scanner も別に止めるが、門の規則として固定する)
check("門は escape の後に閉じない二重引用を通さない", !P.simple_command?("echo \"a\\\"") && !P.simple_command?("echo \"a\\\\"))
check("門は \\\" と \\\\ の後に閉じる二重引用を通す", P.simple_command?("echo \"a\\\"b\\\\\""))

# inline の Ruby (ruby -e。#737)。code を構文の木にし、許す形の表に収まるときだけ exec。fixture の関数は、fixture を
# 渡したときだけ、その名前の receiver の無い呼び出しを許す。表に無い形・option は unknown に残す。表の [] は fixture を
# 渡さない呼び出し、fx は repo の median の fixture (関数 median と、初期の Ruby の file の一覧。#742)。
sq = 39.chr
inline = ->(code, opts = "") { "ruby #{opts}-e #{sq}#{code}#{sq}" }
fx = P::Fixture.new(%w[median], %w[lib/median.rb test/median_test.rb])
# path の要素の形を確かめるための一覧 (実際の fixture には無い path も入れる)
cf = P::Fixture.new([], %w[a:b/x.rb ~/x.rb ../x.rb lib/x.rb .hidden/x.rb lib.rb x.rb lib/x.rb.rb lib/x.so.rb])
ruby_inline = [
  # 受け付ける形
  [inline.("p 1"), [], "exec"],
  [inline.('p [1, 1.5, "ok", :ok, nil, true, false, {a: 2}, (1..3), (1...3)]'), [], "exec"],
  [inline.("xs = [2, 1]; ys = xs.sort; p ys.length; p ys[0]; p(ys == [1, 2])"), [], "exec"],
  [inline.('if true; puts "yes"; elsif false; p 2; else; raise "no"; end; unless false; p 1; end; p(true ? 1 : 2)'), [], "exec"],
  [inline.('raise "no" unless true; puts "yes" if true'), [], "exec"],
  [inline.("[2, 1].each { |x| p x }; [[1, 2]].each { |(a, b)| p a + b }"), [], "exec"],
  [inline.("[3].each do |v| puts v end"), [], "exec"],
  [inline.("p [[1], [2]].map(&:length)"), [], "exec"],
  [inline.("x = 1; x += 2; h = {}; h[:a] = x; p h, a: 1"), [], "exec"],
  [inline.('p "a#{1 + 2}b"'), [], "exec"],
  [inline.("p(-1.abs, !true, 1 <=> 2, [1]&.first)"), [], "exec"],
  ["ruby -e #{sq}x = 1#{sq} -e #{sq}p x#{sq}", [], "exec"],
  [inline.("p median([1, 2])", "-r ./lib/median "), fx, "exec"],
  [inline.("p median([1])", "-w -I ./lib -r ./lib/median.rb "), fx, "exec"],
  [inline.("p median([1])", "-I./lib -r./lib/median.rb -w "), fx, "exec"],
  ["/bin/zsh -lc \"ruby -r ./lib/median -e #{sq}p median([1])#{sq}\"", fx, "exec"],
  # fixture の関数は、渡した名前だけ
  [inline.("p median([1, 2])", "-r ./lib/median "), [], "unknown"],
  [inline.('cp "a", "b"', "-r ./lib/median "), fx, "unknown"],
  # 表に無い構文・呼び出し
  [inline.("`printf x`"), [], "unknown"],
  [inline.("%x(printf x)"), [], "unknown"],
  [inline.("p $stdout"), [], "unknown"],
  [inline.("$x = 1"), [], "unknown"],
  [inline.("p File"), [], "unknown"],
  [inline.("p ENV"), [], "unknown"],
  [inline.('File.write("x", "y")'), [], "unknown"],
  [inline.("def f; 1; end"), [], "unknown"],
  [inline.("p [].send(:sort)"), [], "unknown"],
  [inline.("p [].public_send(:sort)"), [], "unknown"],
  [inline.("p [].__send__(:sort)"), [], "unknown"],
  [inline.("p [1].inject(:+)"), [], "unknown"],
  [inline.("p [].method_not_in_the_table"), [], "unknown"],
  [inline.("p [1].map(&:system)"), [], "unknown"],
  [inline.("b = 1; p [1].map(&b)"), [], "unknown"],
  [inline.('system("x")'), [], "unknown"],
  [inline.('require "json"'), [], "unknown"],
  [inline.('eval("1")'), [], "unknown"],
  [inline.("exit"), [], "unknown"],
  [inline.('[1].map { |x| system("x") }'), [], "unknown"],
  [inline.("if false; p File; end"), [], "unknown"],
  [inline.('p "#{system("x")}"'), [], "unknown"],
  [inline.("x = ("), [], "unknown"],
  [inline.("p self"), [], "unknown"],
  [inline.("p __FILE__"), [], "unknown"],
  [inline.("x = [1]; x.first = 1"), [], "unknown"],
  [inline.("p [*[1]]"), [], "unknown"],
  [inline.("[1].each { |a, *b| p a }"), [], "unknown"],
  [inline.("[1].each { |a = 1| p a }"), [], "unknown"],
  [inline.("begin; p 1; rescue; p 2; end"), [], "unknown"],
  [inline.(%q{[1].each do |v| p v; rescue; system("x"); end}), [], "unknown"],
  [inline.(%q{[1].each do |v| p v; ensure; system("x"); end}), [], "unknown"],
  [inline.("f = -> { 1 }"), [], "unknown"],
  [inline.("p 1", "-r json "), [], "unknown"],
  [inline.("p 1", "-rjson "), [], "unknown"],
  [inline.("p 1", "-r ../x.rb "), [], "unknown"],
  [inline.("p 1", "-r ./lib/../x.rb "), [], "unknown"],
  [inline.("p 1", "-r /tmp/x.rb "), [], "unknown"],
  ["ruby -run -e cp", fx, "unknown"],
  ["ruby -r un -e cp", fx, "unknown"],
  # -r の名前 (#742)。-I が 1 つで、その dir の NAME.rb が初期の fixture の file にあるときだけ。-I と -r の順は問わない
  [inline.("p median([1, 2])", "-Ilib -rmedian "), fx, "exec"],
  [inline.("p median([1, 2])", "-I lib -r median "), fx, "exec"],
  [inline.("p median([1, 2])", "-rmedian -Ilib "), fx, "exec"],
  [inline.("p median([1, 2])", "-I./lib -rmedian "), fx, "exec"],
  [inline.("p median([1, 2])", "-I lib/ -rmedian "), fx, "exec"],
  [inline.("p median([1, 2])", "-I. -rlib/median "), fx, "exec"],
  [inline.("p 1", "-Itest -rmedian_test "), fx, "exec"],
  [inline.("p median([1])", "-Ilib -rmedian -r ./lib/median "), fx, "exec"],
  ["/bin/zsh -lc \"ruby -Ilib -rmedian -e #{sq}p median([1]); puts \\\"ok\\\"#{sq}\"", fx, "exec"],
  [inline.("p 1", "-Ilib -rmedian "), [], "unknown"],
  [inline.("p 1", "-rmedian "), fx, "unknown"],
  [inline.("p 1", "-Ilib -rjson "), fx, "unknown"],
  ["ruby -Ilib -run -e cp", fx, "unknown"],
  [inline.("p 1", "-Ilib -Itest -rmedian "), fx, "unknown"],
  [inline.("p 1", "-Ilib -Ilib -rmedian "), fx, "unknown"],
  [inline.("p 1", "-Ilib:test -rmedian "), fx, "unknown"],
  [inline.("p 1", "-I/lib -rmedian "), fx, "unknown"],
  [inline.("p 1", "-I../lib -rmedian "), fx, "unknown"],
  [inline.("p 1", "-Ilib/../lib -rmedian "), fx, "unknown"],
  [inline.("p 1", "-I~/lib -rmedian "), fx, "unknown"],
  [inline.("p 1", "-I #{sq}$LIB#{sq} -rmedian "), fx, "unknown"],
  [inline.("p 1", "-Itest -rmedian "), fx, "unknown"],
  [inline.("p 1", "-Ilib -rmedian.rb "), fx, "unknown"],
  [inline.("p 1", "-Ilib -rlib/median "), fx, "unknown"],
  [inline.("p 1", "-Ilib -rmedian -rjson "), fx, "unknown"],
  # code の中の require (#745)。展開の無い文字列の literal 1 つで、-r ./… と同じ規則を満たす形だけ
  [inline.('require "./lib/median"; p median([3, 1, 2]), median([4, 1, 3, 2])'), fx, "exec"],
  [inline.("require %q(./lib/median); p median([1])"), fx, "exec"],
  [inline.('require("./lib/median"); p median([1])'), fx, "exec"],
  [inline.('require "./lib/median.rb"; p 1'), [], "exec"],
  [inline.('require "./lib/median" if true; p 1'), [], "exec"],
  [inline.('require "json"'), [], "unknown"],
  [inline.('require "../x"'), [], "unknown"],
  [inline.('require "./lib/../x"'), [], "unknown"],
  [inline.('require "/tmp/x"'), [], "unknown"],
  [inline.('require "./#{1}"'), [], "unknown"],
  [inline.('require "./lib/median#{1}"'), [], "unknown"],
  [inline.('require "./lib/\x2e\x2e/x"'), [], "unknown"],
  [inline.('require_relative "./x"'), [], "unknown"],
  [inline.('load "./x.rb"'), [], "unknown"],
  [inline.('require "./a", "./b"'), [], "unknown"],
  [inline.('x = 1; x.require "./a"'), [], "unknown"],
  [inline.('require ""'), [], "unknown"],
  [inline.("require"), [], "unknown"],
  [inline.('require "./lib/median"; system("x")'), fx, "unknown"],
  [inline.('system("x")', "-Ilib -rmedian "), fx, "unknown"],
  ["#{inline.("p 1", "-Ilib -rmedian ")}; touch out", fx, "file-write"],
  # path の要素の形 (#742)。Ruby が -I で特別に読む字 (: と ~)、.. の要素、絶対 path は、一覧に同じ path があっても受けない
  [inline.("p 1", "-Ia:b -rx "), cf, "unknown"],
  [inline.("p 1", "-I~ -rx "), cf, "unknown"],
  [inline.("p 1", "-I.. -rx "), cf, "unknown"],
  [inline.("p 1", "-I. -r../x "), cf, "unknown"],
  [inline.("p 1", "-I/lib -rx "), cf, "unknown"],
  [inline.("p 1", "-Ilib -r #{sq}#{sq} "), cf, "unknown"],
  # review の round 1 (#742)。空の -I は Ruby が探す dir に足さず、名前の最後の要素の拡張子は .rb を足さずに使う
  [inline.("p 1", "-I #{sq}#{sq} -rx "), cf, "unknown"],
  [inline.("p 1", "-I. -rx "), cf, "exec"],
  [inline.("p 1", "-Ilib -rx.rb "), cf, "unknown"],
  [inline.("p 1", "-Ilib -rx.so "), cf, "unknown"],
  [inline.("p 1", "-Ilib -rx "), cf, "exec"],
  [inline.("p 1", "-I.hidden -rx "), cf, "exec"],
  [inline.("p 1", "-C ./lib "), [], "unknown"],
  [inline.("p 1", "-n "), [], "unknown"],
  [inline.("p 1", "-W0 "), [], "unknown"],
  ["ruby -we #{sq}p 1#{sq}", [], "unknown"],
  ["ruby -e", [], "unknown"],
  ["#{inline.('p 1')} arg", [], "unknown"],
  ["#{inline.('p 1')} -- x", [], "unknown"],
  # in-place の編集と redirect は今の規則のまま
  ["ruby -i -e #{sq}p 1#{sq} lib/median.rb", [], "file-write"],
  ["ruby -pi -e #{sq}p 1#{sq} lib/median.rb", [], "file-write"],
  ["#{inline.('p 1')} > out.txt", [], "file-write"],
  # code をくっつけた -e の中の i を、in-place の編集の印に数えない (review の round 1)。束の i と、値をとる字の後ろは今どおり
  ["ruby -e#{sq}print 1#{sq}", [], "exec"],
  ["ruby -e#{sq}raise \"x\" if 1 == 2#{sq}", [], "exec"],
  [inline.("-1.abs.times { |i| p i }"), [], "exec"],
  ["ruby -pie s/a/b/ lib/median.rb", [], "file-write"],
  ["ruby -i.bak -e #{sq}p 1#{sq} lib/median.rb", [], "file-write"],
  ["ruby -0i -e #{sq}p 1#{sq} lib/median.rb", [], "file-write"],
  [inline.("p 1", "-W:no-deprecated "), [], "unknown"],
  [inline.("p 1", "--disable-gems "), [], "unknown"],
  ["perl -lpi -e #{sq}s/a/b/#{sq} f", [], "file-write"],
  ["perl -0777 -pi -e s/a/b/ f", [], "file-write"],
  ["perl -le #{sq}print 1#{sq}", [], "unknown"],
  ["perl -Mstrict -e 1", [], "unknown"],
  # option の束の字の値の取り方 (review の round 2)。Ruby 2.6.10 と perl 5.34 で、各字の後ろに -pi を置いて file が書き換わる
  # かを測った。書き換わった形は file-write、書き換わらなかった形 (i が値の一部) は file-write にしない
  ["ruby -W0i -pe 1 f", [], "file-write"], ["ruby -W -pi -e 1 f", [], "file-write"],
  ["ruby -Kui -pe 1 f", [], "file-write"], ["ruby -K -pi -e 1 f", [], "file-write"], ["ruby -Ki -pe 1 f", [], "unknown"],
  ["ruby -F -pi -e 1 f", [], "file-write"], ["ruby -Fi -pe 1 f", [], "unknown"],
  ["ruby -x -pi -e 1 f", [], "file-write"], ["ruby -xi -pe 1 f", [], "unknown"],
  ["ruby -077i -pe 1 f", [], "file-write"], ["ruby -Ii -pe 1 f", [], "unknown"], ["ruby -C -pi -e 1 f", [], "unknown"],
  ["perl -C -pi -e 1 f", [], "file-write"], ["perl -Ci -pe 1 f", [], "unknown"],
  ["perl -D -pi -e 1 f", [], "file-write"], ["perl -F -pi -e 1 f", [], "file-write"], ["perl -Fi -pe 1 f", [], "unknown"],
  ["perl -I -pi -e 1 f", [], "unknown"], ["perl -Ii -pe 1 f", [], "unknown"], ["perl -Mi -pe 1 f", [], "unknown"],
  ["perl -li -pe 1 f", [], "file-write"], ["perl -0i -pe 1 f", [], "file-write"],
  # review の round 3。値の範囲を決められない option (表に無い字・長い option) の後は、残りの語の束も読む。perl の -dpi は
  # review が測り、ほかの file-write の形は Ruby 2.6.10 と perl 5.34 で file が書き換わることを測った
  ["perl -dpi -e 1 f", [], "file-write"], ["ruby -X . -pi -e 1 f", [], "file-write"],
  ["ruby --encoding utf-8 -pi -e 1 f", [], "file-write"], ["ruby --verbose -pi -e 1 f", [], "file-write"],
  ["ruby -U -pi -e 1 f", [], "file-write"], ["perl -V:osname -pi -e 1 f", [], "file-write"],
  ["ruby -Q -pi -e 1 f", [], "file-write"], ["ruby -Q . -pi -e 1 f", [], "file-write"],
  ["ruby -Qi -e 1 f", [], "file-write"], ["ruby --verbose -e 1 -- -pi f", [], "file-write"],
  # ruby の -X は -C と同じく次の語を取る (ruby -X -pi は -pi に chdir しようとして止まる)。値をとらない字は範囲を決められない印を
  # 立てないので、script の後ろの -pi (script の引数) は数えない
  ["ruby -X -pi -e 1 f", [], "unknown"], ["ruby -w test/a.rb -pi f", [], "exec"], ["perl -w x.pl -pi f", [], "exec"],
  ["ruby -n test/a.rb -pi f", [], "unknown"], ["perl -n x.pl -pi f", [], "unknown"],
  # review の round 4。perl の -V は、直後が : のときだけ束の残りが値 (-Vpi の p・i は option)。束の残りを値に取る字の後ろに
  # pi をくっつけた形も測った (file が書き換わったのは -Vpi と -Kupi だけ)
  ["perl -Vpi -e 1 f", [], "file-write"], ["perl -V:osnamei -pe 1 f", [], "unknown"], ["perl -V:i -pe 1 f", [], "unknown"],
  ["perl -Mpi -e 1 f", [], "unknown"], ["perl -mpi -e 1 f", [], "unknown"], ["perl -Fpi -e 1 f", [], "unknown"],
  ["perl -xpi -e 1 f", [], "unknown"], ["perl -Cpi -e 1 f", [], "unknown"], ["perl -Dpi -e 1 f", [], "unknown"],
  ["perl -Ipi -e 1 f", [], "unknown"], ["ruby -Fpi -e 1 f", [], "unknown"], ["ruby -xpi -e 1 f", [], "unknown"],
  ["ruby -Cpi -e 1 f", [], "unknown"], ["ruby -Xpi -e 1 f", [], "unknown"], ["ruby -Kupi -e 1 f", [], "file-write"],
]
ruby_inline.each do |cmd, fixture, want|
  fixture = P::NO_FIXTURE if fixture == []
  got = P.classify_shell(cmd, fixture: fixture)
  label = { fx => "fx", cf => "cf" }.fetch(fixture, "none")
  check("classify_shell(#{cmd.inspect}, #{label}) は #{want} (実際は #{got})", got == want)
end
check("fixture を渡さない classify_claude の Bash は fixture の関数を許さない",
      P.classify_claude("Bash", { "command" => inline.("p median([1])", "-r ./lib/median ") }) == "unknown")
check("classify_claude の Bash は fixture を分類器に渡す",
      P.classify_claude("Bash", { "command" => inline.("p median([1])", "-Ilib -rmedian ") }, fixture: fx) == "exec")
check("分類器の版は 5 (#745)", P::VERSION == 5)
observed745 = "ruby -e 'require \"./lib/median\"; p median([3,1,2]), median([4,1,3,2])'"
check("claude の Bash の、code の中の require の観測した形は fixture を渡せば exec (#745)",
      P.classify_claude("Bash", { "command" => observed745 }, fixture: fx) == "exec" &&
      P.classify_claude("Bash", { "command" => observed745 }) == "unknown")

claude = {
  ["Read", { "file_path" => "/p/lib/median.rb" }] => "read",
  ["Grep", { "pattern" => "x" }] => "read",
  ["Glob", { "pattern" => "**/*.rb" }] => "read",
  ["Skill", { "skill" => "personal-investigate" }] => "read",
  ["Edit", { "file_path" => "/p/lib/median.rb" }] => "file-write",
  ["Write", { "file_path" => "/p/x" }] => "file-write",
  ["NotebookEdit", {}] => "file-write",
  ["Bash", { "command" => "cat lib/median.rb" }] => "read",
  ["Bash", { "command" => "ls -la; ruby -v; ruby -Ilib -Itest test/median_test.rb 2>&1 | tail -40" }] => "exec",
  ["Bash", { "command" => "gh pr comment 1 -b x" }] => "github-write",
  ["Bash", {}] => "unknown",
  ["Task", { "prompt" => "x" }] => "unknown",
  ["WebSearch", { "query" => "x" }] => "unknown",
}
claude.each do |(name, input), want|
  got = P.classify_claude(name, input)
  check("classify_claude(#{name}) は #{want} (実際は #{got})", got == want)
end
check("区分の重さは agent-launch が最も重い", P.max_class(%w[read file-write agent-launch git-write]) == "agent-launch")
check("区分が無ければ unknown", P.max_class([]) == "unknown")
check("文字列でない command は unknown", P.classify_shell(nil) == "unknown")
# 分類の途中の例外 (想定外の入力の形) は unknown にして、probe を止めない
orig_scan = P.method(:scan)
P.define_singleton_method(:scan) { |_cmd| raise TypeError, "boom" }
check("分類の途中の例外は unknown", P.classify_shell("cat x") == "unknown")
P.define_singleton_method(:scan, orig_scan)
check("例外の確かめの後は元の分類に戻る", P.classify_shell("cat x") == "read")
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: event の解析 ---------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
require "json"
load ARGV[0]
P = ProbeSkillBehavior
names = %w[personal-investigate personal-grill-me]

claude_events = [
  { "type" => "system", "subtype" => "init", "model" => "m-c", "claude_code_version" => "9.9.9",
    "tools" => %w[Read Bash], "permissionMode" => "acceptEdits" },
  { "type" => "assistant", "message" => { "content" => [
    { "type" => "tool_use", "id" => "t1", "name" => "Skill", "input" => { "skill" => "personal-investigate" } },
    { "type" => "text", "text" => "x" },
  ] } },
  { "type" => "user", "message" => { "content" => [{ "type" => "tool_result", "tool_use_id" => "t1", "content" => "ok" }] } },
  { "type" => "assistant", "message" => { "content" => [
    { "type" => "tool_use", "id" => "t2", "name" => "Read", "input" => { "file_path" => "/p/.claude/skills/personal-grill-me/SKILL.md" } },
    { "type" => "tool_use", "id" => "t3", "name" => "Bash", "input" => { "command" => "rm lib/median.rb" } },
    { "type" => "tool_use", "id" => "t4", "name" => "Edit", "input" => { "file_path" => "/p/lib/median.rb" } },
    { "type" => "tool_use", "id" => "t5", "name" => "Read", "input" => { "file_path" => "/p/lib/median.rb" } },
  ] } },
  { "type" => "user", "message" => { "content" => [
    { "type" => "tool_result", "tool_use_id" => "t2", "content" => "..." },
    { "type" => "tool_result", "tool_use_id" => "t3", "is_error" => true, "content" => "denied" },
    { "type" => "tool_result", "tool_use_id" => "t4", "is_error" => true, "content" => "no match" },
  ] } },
  { "type" => "result", "subtype" => "success", "permission_denials" => [{ "tool_use_id" => "t3", "tool_name" => "Bash" }] },
]
jsonl = claude_events.map { |e| JSON.generate(e) }.join("\n") + "\nnot json\n"
c = P.parse_claude(jsonl, names)
got = c[:calls].map { |x| [x[:id], x[:tool], x[:class], x[:outcome]] }
check("claude の呼び出しを順に、区分と結果を分けて残す (#{got.inspect})",
      got == [%w[t1 Skill read ok], %w[t2 Read read ok], %w[t3 Bash file-write denied], %w[t4 Edit file-write error],
              %w[t5 Read read unknown]])
check("claude の skill の読み取りは Skill tool と SKILL.md の Read の両方", c[:skills_read] == %w[personal-investigate personal-grill-me])
check("claude の init の値", c[:init] == { model: "m-c", version: "9.9.9", tools: %w[Read Bash], mode: "acceptEdits" })
check("claude の result を見た", c[:result_seen] && c[:subtype] == "success")
check("claude の呼び出しの入力の文字列を到達の照合に残す", c[:calls][4][:strings] == ["/p/lib/median.rb"])

codex_events = [
  { "type" => "thread.started" },
  { "type" => "item.started", "item" => { "id" => "i1", "type" => "command_execution",
                                         "command" => "/bin/zsh -lc 'cat .agents/skills/personal-investigate/SKILL.md'", "status" => "in_progress" } },
  { "type" => "item.completed", "item" => { "id" => "i1", "type" => "command_execution",
                                           "command" => "/bin/zsh -lc 'cat .agents/skills/personal-investigate/SKILL.md'", "exit_code" => 0, "status" => "completed" } },
  { "type" => "item.completed", "item" => { "id" => "i0", "type" => "agent_message", "text" => "x" } },
  { "type" => "item.completed", "item" => { "id" => "i2", "type" => "command_execution", "command" => "/bin/zsh -lc 'ruby test/median_test.rb'", "exit_code" => 1, "status" => "failed" } },
  { "type" => "item.completed", "item" => { "id" => "i3", "type" => "command_execution", "command" => "cat lib/median.rb", "exit_code" => 2, "status" => "completed" } },
  { "type" => "item.completed", "item" => { "id" => "i4", "type" => "file_change", "changes" => [{ "path" => "/p/lib/median.rb", "kind" => "update" }], "status" => "completed" } },
  { "type" => "item.completed", "item" => { "id" => "i5", "type" => "file_change", "changes" => [{ "path" => "/p/x", "kind" => "add" }], "status" => "declined" } },
  { "type" => "item.started", "item" => { "id" => "i6", "type" => "command_execution", "command" => "/bin/zsh -lc 'git push'", "status" => "in_progress" } },
  { "type" => "item.completed", "item" => { "id" => "i7", "type" => "mcp_tool_call", "status" => "completed" } },
  { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } },
]
x = P.parse_codex(codex_events.map { |e| JSON.generate(e) }.join("\n") + "\n", names)
got = x[:calls].map { |y| [y[:id], y[:tool], y[:class], y[:outcome]] }
check("codex の呼び出しを item の ID で束ね、区分と結果を分けて残す (#{got.inspect})",
      got == [%w[i1 command_execution read ok], %w[i2 command_execution exec error], %w[i3 command_execution read error],
              %w[i4 file_change file-write ok], %w[i5 file_change file-write denied], %w[i6 command_execution git-write unknown],
              %w[i7 mcp_tool_call unknown ok]])
check("codex の agent_message は呼び出しに数えない", x[:calls].none? { |y| y[:id] == "i0" })
check("codex の skill の読み取りは command の SKILL.md の path", x[:skills_read] == %w[personal-investigate])
check("codex の file_change の path を到達の照合に残す", x[:calls][3][:strings] == ["/p/lib/median.rb"])
check("codex の turn.completed を見た", x[:turn_completed])
check("turn.completed が無ければ見ていない", !P.parse_codex("", names)[:turn_completed])

# skill の file の読み取りの形 (#731。review の round 1〜3)。名前に結び付けるのは `<名前>/SKILL.md` の形だけで、
# ほかの形は区分と分けて skills_unresolved に残す
cmd = lambda do |id, command|
  { "type" => "item.completed", "item" => { "id" => id, "type" => "command_execution", "command" => command,
                                           "exit_code" => 0, "status" => "completed" } }
end
one = ->(command) { P.parse_codex(JSON.generate(cmd.call("r1", command)) + "\n", names) }
read_forms = {
  "続いた path" => "/bin/zsh -lc 'cat /h/skills/personal-investigate/SKILL.md'",
  "途中の /./" => "/bin/zsh -lc 'cat /h/skills/./personal-investigate/SKILL.md'",
  "SKILL.md の直前の /./" => "/bin/zsh -lc 'cat /h/skills/personal-investigate/././SKILL.md'",
  "重ねた / と小文字の skill.md" => "/bin/zsh -lc 'cat /h/skills//personal-investigate/skill.md'",
  "前の要素に ~" => "/bin/zsh -lc 'cat ~/.codex/skills/personal-investigate/SKILL.md'",
  "後ろに区切りの字" => "/bin/zsh -lc 'sed -n 1,80p \"/h/skills/personal-investigate/SKILL.md\"; cat lib/median.rb'",
}
read_forms.each do |label, command|
  y = one.call(command)
  check("codex の #{label} は、その skill の読み取りで、印は立てない (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
        y[:skills_read] == %w[personal-investigate] && y[:skills_unresolved] == false)
end
unresolved_forms = {
  "glob の SKILL.md" => "/bin/zsh -lc 'cat /h/skills/*/SKILL.md'",
  "名前を変数に入れた形" => "/bin/zsh -lc 'n=personal-investigate; cat /h/skills/$n/SKILL.md'",
  "cd の無い単独の SKILL.md" => "/bin/zsh -lc 'find /h/skills -name SKILL.md -exec cat {} +'",
  "最後の要素が .." => "/bin/zsh -lc 'cat /h/skills/personal-investigate/../SKILL.md'",
  "cd の先が変数" => "/bin/zsh -lc 'cd /h/skills/$n && cat SKILL.md'",
  "cd した dir の SKILL.md" => "/bin/zsh -lc 'cd /h/skills/personal-investigate && cat SKILL.md'",
  "cd と ./SKILL.md" => "/bin/zsh -lc 'cd /h/skills/personal-investigate; cat ./SKILL.md'",
  "読んだ後の cd (round 3)" => "/bin/zsh -lc 'cd ../skills/personal-investigate && cat SKILL.md; cd - && cat lib/median.rb'",
  "file の名前の後ろの glob (round 3)" => "/bin/zsh -lc 'cat ../skills/*/SKILL.md* && cat lib/median.rb'",
  "file の名前の前の glob (round 3)" => "/bin/zsh -lc 'cat ../skills/personal-investigate/*SKILL.md'",
  "SKILL.md で終わる別の名前" => "/bin/zsh -lc 'cat notes-SKILL.md'",
  "SKILL.md で始まる別の名前" => "/bin/zsh -lc 'cat /h/skills/personal-investigate/SKILL.md.bak'",
  "二重引用でつないだ名前 (round 4)" => "cat \"../skills/personal-\"investigate/SKILL.md && cat lib/median.rb",
  "単引用でつないだ名前" => "cat ../skills/'personal-'investigate/SKILL.md",
  "名前の途中の引用" => "cat ../skills/pe\"rs\"onal-investigate/SKILL.md",
  "前の要素に変数 (門で止める)" => "/bin/zsh -lc 'cat $HOME/.codex/skills/personal-investigate/SKILL.md'",
  "command の置き換えでつないだ名前 (round 5)" => "cat ../skills/$(printf personal-)investigate/SKILL.md && printf x >> lib/median.rb",
  "backslash と改行でつないだ名前 (round 5)" => "cat ../skills/personal-\\\ninvestigate/SKILL.md && printf x >> lib/median.rb",
  "brace の展開" => "cat ../skills/personal-{investigate,x}/SKILL.md",
  "backtick の置き換え" => "cat ../skills/`printf personal-investigate`/SKILL.md",
  "zsh の file の名前の修飾 (round 6)" => "cat ../skills/personal-investigate-old/SKILL.md(:s/personal-investigate-old/personal-investigate/) && printf x >> lib/median.rb",
  "zsh の glob の組み分け" => "cat ../skills/(personal-investigate|x)/SKILL.md",
}
unresolved_forms.each do |label, command|
  y = one.call(command)
  check("codex の #{label} は名前を決められないので印を立てる (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
        y[:skills_read].empty? && y[:skills_unresolved] == true)
end
y = one.call("/bin/zsh -lc 'cat /h/skills/personal-grill-me/SKILL.md ./SKILL.md'")
check("既知の名前と同じ文字列でも、残りの決められない読み取りの印は消えない (round 2)",
      y[:skills_read] == %w[personal-grill-me] && y[:skills_unresolved] == true)
y = one.call("/bin/zsh -lc 'cat /h/skills/personal-grill-me/SKILL.md /h/skills/*/SKILL.md'")
check("門で止めた文字列からは名前を記録せず、印を立てる (round 5)", y[:skills_read].empty? && y[:skills_unresolved] == true)
y = one.call("/bin/zsh -lc 'cat /h/skills/*/SKILL.md && sed -i s/a/b/ lib/median.rb'")
check("書き込みと同居しても、区分は分類器のまま、印は残る (round 2。#{y[:calls][0][:class]})",
      y[:calls][0][:class] == "file-write" && y[:skills_unresolved] == true)
y = one.call("/bin/zsh -lc 'cat /h/skills/personal-investigate-old/SKILL.md'")
check("名前の続く別の dir は、別の skill の読み取り (印も立てない)", y[:skills_read].empty? && y[:skills_unresolved] == false)
y = one.call("/bin/zsh -lc 'cat README.md'")
check("SKILL.md に触れない呼び出しは今のまま", y[:calls][0][:class] == "read" && y[:skills_read].empty? && y[:skills_unresolved] == false)
two = [cmd.call("a", "/bin/zsh -lc 'cat /h/skills/*/SKILL.md'"), cmd.call("b", "/bin/zsh -lc 'cat README.md'")]
y = P.parse_codex(two.map { |e| JSON.generate(e) }.join("\n") + "\n", names)
check("run の印は、どれかの呼び出しで立てば立つ", y[:skills_unresolved] == true)
claude_amb = [
  { "type" => "assistant", "message" => { "content" => [
    { "type" => "tool_use", "id" => "u1", "name" => "Read", "input" => { "file_path" => "/p/other-skill/SKILL.md" } },
    { "type" => "tool_use", "id" => "u2", "name" => "Write", "input" => { "file_path" => "/p/x/*/SKILL.md", "content" => "x" } },
    { "type" => "tool_use", "id" => "u3", "name" => "Read", "input" => { "file_path" => "/p/skills/./personal-grill-me/SKILL.md" } },
  ] } },
].map { |e| JSON.generate(e) }.join("\n") + "\n"
y = P.parse_claude(claude_amb, names)
check("claude も同じ規則で、区分は変えずに印を立てる (#{y[:calls].map { |c| c[:class] }.inspect} #{y[:skills_unresolved]})",
      y[:calls].map { |c| c[:class] } == %w[read file-write read] && y[:skills_read] == %w[personal-grill-me] &&
      y[:skills_unresolved] == true)
y = P.parse_claude(JSON.generate(claude_amb.lines.first.then { |l| JSON.parse(l) }.tap { |e| e["message"]["content"].delete_at(1) }) + "\n", names)
check("claude の決められる Read だけなら印は立てない", y[:skills_unresolved] == false)

# 独立した単引用の語を外した写しからも名前を探して足す (#740)。印は元の文字列だけで決める
observed = "/bin/zsh -lc \"pwd; rg --files -g 'AGENTS.md' -g '*median*' -g 'Gemfile*' -g 'Rakefile'; " \
           "cat .agents/skills/personal-investigate/SKILL.md .agents/skills/personal-production-rail/SKILL.md\""
y = P.parse_codex(JSON.generate(cmd.call("r1", observed)) + "\n", names + %w[personal-production-rail])
check("観測した形は 2 つの名前が決まり、印は立ったまま (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
      y[:skills_read].sort == %w[personal-investigate personal-production-rail] && y[:skills_unresolved] == true)
literal_forms = {
  "空白の後の単引用の語" => "/bin/zsh -lc \"rg -g '*x*' -g 'y?'; cat ../skills/personal-investigate/SKILL.md\"",
  "tab の前後の単引用の語" => "rg -g\t'[ab]'\t.; cat ../skills/personal-investigate/SKILL.md",
  "先頭の単引用の語" => "'*x*' && cat ../skills/personal-investigate/SKILL.md",
  "後ろが ; & | の単引用の語" => "rg -g '*a*'; rg -g '*b*'& rg -g '*c*'| cat ../skills/personal-investigate/SKILL.md",
  "末尾の単引用の語" => "cat ../skills/personal-investigate/SKILL.md; rg -g '*x*'",
  "改行を含む単引用の語" => "printf 'a\nb' && cat ../skills/personal-investigate/SKILL.md",
}
literal_forms.each do |label, command|
  y = one.call(command)
  check("codex の #{label} は外して名前を足し、印は立ったまま (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
        y[:skills_read] == %w[personal-investigate] && y[:skills_unresolved] == true)
end
kept_forms = {
  "前につないだ単引用" => "cat x'*'; cat ../skills/personal-investigate/SKILL.md",
  "後ろにつないだ単引用" => "rg -g '*x*'y; cat ../skills/personal-investigate/SKILL.md",
  "= の直後の単引用" => "x='*'; cat ../skills/personal-investigate/SKILL.md",
  "$ の直後の単引用" => "printf $'*'; cat ../skills/personal-investigate/SKILL.md",
  "/ の前の単引用" => "cat '*'/x; cat ../skills/personal-investigate/SKILL.md",
  "skill.md を含む単引用" => "cat '../skills/*/SKILL.md' ../skills/personal-investigate/SKILL.md",
  "二重引用の語" => "rg -g \"*x*\"; cat ../skills/personal-investigate/SKILL.md",
}
kept_forms.each do |label, command|
  y = one.call(command)
  check("codex の #{label} は外さず、名前は増えずに印を立てる (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
        y[:skills_read].empty? && y[:skills_unresolved] == true)
end
y = one.call("/bin/zsh -lc \"sh -c 'cat .agents/skills/personal-investigate/SKILL.m[d]'; : unlisted/SKILL.md\"")
check("外した語を sh -c が実行する形 (相談の反例) も、元の文字列の印が残る (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
      y[:skills_read].empty? && y[:skills_unresolved] == true)
y = one.call("/bin/zsh -lc \"rg -g '*x*'; cat ../skills/personal-other/SKILL.md\"")
check("外した写しでも、照らす名前に無い名前は足さない", y[:skills_read].empty? && y[:skills_unresolved] == true)
y = one.call("/bin/zsh -lc \"rg -g 'x'; cat ../skills/personal-investigate/SKILL.md\"")
check("門を通る文字列は、外しても今と同じ (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
      y[:skills_read] == %w[personal-investigate] && y[:skills_unresolved] == false)
claude_bash = [
  { "type" => "assistant", "message" => { "content" => [
    { "type" => "tool_use", "id" => "b1", "name" => "Bash",
      "input" => { "command" => "rg --files -g '*median*'; cat .claude/skills/personal-grill-me/SKILL.md" } },
  ] } },
].map { |e| JSON.generate(e) }.join("\n") + "\n"
y = P.parse_claude(claude_bash, names)
check("claude の Bash の入力も同じ写しで名前を足す (#{y[:skills_read].inspect} #{y[:skills_unresolved]})",
      y[:skills_read] == %w[personal-grill-me] && y[:skills_unresolved] == true)
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: case set の検査 -------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$cases_lib" "$cases_json" "$repo_root/scripts/lib/skill_behavior_fixtures" <<'RUBY'
require "json"
load ARGV[0]
C = SkillBehaviorCases
fixtures = ARGV[2]
repo_cases = C.parse(File.read(ARGV[1]), fixtures_root: fixtures)
check("repo の case set は fixture つきで検査を通る", repo_cases.length >= 3)
check("repo の case set は正例・負例・曖昧を持つ", repo_cases.map { |c| c["kind"] }.uniq.sort == %w[ambiguous negative positive])
check("repo の case set は case の skill を置く (#737)", repo_cases.all? { |c| c["place_skills"].include?(c["skill"]) })

base = {
  "id" => "a", "prompt" => "p", "skill" => "s", "kind" => "negative", "pair" => "g", "fixture" => "median",
  "reach" => ["lib/median.rb"], "forbid" => ["file-write"], "require" => [], "allowed_changes" => [], "place_skills" => ["s"],
}
pos = base.merge("id" => "b", "kind" => "positive", "forbid" => [], "require" => ["file-write"], "allowed_changes" => ["lib/median.rb"])

def rejected(cases, want, fixtures: nil, top: nil)
  doc = top || { "schema_version" => 1, "cases" => cases }
  SkillBehaviorCases.parse(JSON.generate(doc), fixtures_root: fixtures)
  false
rescue SkillBehaviorCases::Error => e
  e.message.include?(want)
end

check("形の整った負例と正例は通る", C.parse(JSON.generate({ "schema_version" => 1, "cases" => [base, pos] })).length == 2)
check("schema_version の違い", rejected(nil, "schema_version", top: { "schema_version" => 2, "cases" => [base] }))
check("top-level の未知の key", rejected(nil, "unknown top-level", top: { "schema_version" => 1, "cases" => [base], "x" => 1 }))
check("空の cases", rejected([], "non-empty"))
check("key の欠け", rejected([base.reject { |k, _| k == "reach" }], "missing key"))
check("未知の key", rejected([base.merge("note" => "x")], "unknown key"))
check("id の形", rejected([base.merge("id" => "A b")], "id must match"))
check("id の重複", rejected([base, base.merge("prompt" => "q")], "duplicate id"))
check("先頭が - の prompt", rejected([base.merge("prompt" => "-x")], "must not start with '-'"))
check("未知の kind", rejected([base.merge("kind" => "maybe")], "kind must be"))
check("forbid に read は書けない", rejected([base.merge("forbid" => ["read"])], "forbid must be"))
check("forbid に unknown は書けない", rejected([base.merge("forbid" => ["unknown"])], "forbid must be"))
check("forbid と require の重なり", rejected([pos.merge("forbid" => ["file-write"])], "overlap"))
check("require の無い正例", rejected([pos.merge("require" => [])], "must require"))
check("変更を許さない正例", rejected([pos.merge("allowed_changes" => [])], "must allow"))
check("require のある負例", rejected([base.merge("require" => ["git-write"])], "must not require"))
check("forbid の無い曖昧な case", rejected([base.merge("kind" => "ambiguous", "forbid" => [])], "must forbid"))
check("reach の .. は拒む", rejected([base.merge("reach" => ["../x"])], "relative paths"))
check("reach の絶対 path は拒む", rejected([base.merge("reach" => ["/etc/x"])], "relative paths"))
check("allowed_changes の空の要素は拒む", rejected([pos.merge("allowed_changes" => ["lib//x"])], "relative paths"))
check("空の reach", rejected([base.merge("reach" => [])], "reach must not be empty"))
check("fixture の dir が無い", rejected([base.merge("fixture" => "nope")], "fixture not found", fixtures: fixtures))
check("reach の file が fixture に無い", rejected([base.merge("reach" => ["lib/nope.rb"])], "reach path not in fixture", fixtures: fixtures))
# 置く skill の一覧 (#737)。名前は skill の dir の名前になるので、決まった形だけを受ける
check("place_skills の欠け", rejected([base.reject { |k, _| k == "place_skills" }], "missing key"))
check("空の place_skills", rejected([base.merge("place_skills" => [])], "place_skills must be"))
check("place_skills の重複", rejected([base.merge("place_skills" => %w[s s])], "place_skills must be"))
check("place_skills の名前に path の区切り", rejected([base.merge("place_skills" => ["s", "../x"])], "place_skills must be"))
check("place_skills の名前が文字列でない", rejected([base.merge("place_skills" => ["s", 1])], "place_skills must be"))
check("place_skills が配列でない", rejected([base.merge("place_skills" => "s")], "place_skills must be"))
check("case の skill を含まない place_skills", rejected([base.merge("place_skills" => ["t"])], "must include the skill"))
check("case の skill を含む place_skills は通る", C.parse(JSON.generate({ "schema_version" => 1, "cases" => [base.merge("place_skills" => %w[t s])] })).length == 1)
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: state の差分・終わり方・argv ---------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp/snap" <<'RUBY'
require "fileutils"
load ARGV[0]
P = ProbeSkillBehavior
dir = ARGV[1]
FileUtils.mkdir_p(File.join(dir, "lib"))
File.write(File.join(dir, "lib", "a.rb"), "a\n")
File.write(File.join(dir, "keep.txt"), "k\n")
File.write(File.join(dir, "gone.txt"), "g\n")
File.write(File.join(dir, ".hidden"), "h\n")
before = P.snapshot(dir)
check("snapshot は隠し file を含む", before.key?(".hidden"))
File.write(File.join(dir, "lib", "a.rb"), "b\n")
File.delete(File.join(dir, "gone.txt"))
File.write(File.join(dir, "new.txt"), "n\n")
File.symlink("keep.txt", File.join(dir, "link"))
check("変えた・消した・足した file と symlink を差分に出す",
      P.changed_paths(before, P.snapshot(dir)) == %w[gone.txt lib/a.rb link new.txt])
check("変わらなければ差分は空", P.changed_paths(before, before).empty?)
check("tree_digest は中身が同じなら同じ", P.tree_digest(dir) == P.tree_digest(dir))

Result = ProbeChild::Result
ok = Struct.new(:success?).new(true)
ng = Struct.new(:success?).new(false)
comp = P.method(:completion)
check("claude の正常終了は exited", comp.call("claude-code", Result.new(out: "", err: "", status: ok, completed: true, drained: true), { result_seen: true, subtype: "success" }) == "exited")
check("claude の --max-turns は max-turns", comp.call("claude-code", Result.new(out: "", err: "", status: ng, completed: true, drained: true), { result_seen: true, subtype: "error_max_turns" }) == "max-turns")
check("claude の result が無ければ failed", comp.call("claude-code", Result.new(out: "", err: "", status: ok, completed: true, drained: true), { result_seen: false }) == "failed")
check("claude の非ゼロ終了は failed", comp.call("claude-code", Result.new(out: "", err: "", status: ng, completed: true, drained: true), { result_seen: true, subtype: "success" }) == "failed")
check("期限で止めた run は timeout", comp.call("claude-code", Result.new(out: "", err: "", status: nil, completed: false, drained: true), { result_seen: true }) == "timeout")
check("codex の turn.completed と正常終了は exited", comp.call("codex", Result.new(out: "", err: "", status: ok, completed: true, drained: true), { turn_completed: true }) == "exited")
check("codex の turn.completed が無ければ failed", comp.call("codex", Result.new(out: "", err: "", status: ok, completed: true, drained: true), { turn_completed: false }) == "failed")
check("読み切れない run は failed", comp.call("codex", Result.new(out: "", err: "", status: ok, completed: true, drained: false), { turn_completed: true }) == "failed")
check("codex の期限は timeout", comp.call("codex", Result.new(out: "", err: "", status: nil, completed: false, drained: false), { turn_completed: false }) == "timeout")

argv = P.claude_argv({ max_turns: 7 }, "PROMPT")
check("claude の argv は tool と permission mode を固定する",
      argv.each_cons(2).include?(["--tools", P::CLAUDE_TOOLS.join(",")]) && argv.each_cons(2).include?(%w[--permission-mode acceptEdits]))
check("claude の --tools の直後は値を 1 つとる option", argv[argv.index("--tools") + 2] == "--permission-mode")
check("claude の prompt は最後", argv.last == "PROMPT" && argv.each_cons(2).include?(%w[--max-turns 7]))
check("claude の --model は指定したときだけ", !argv.include?("--model") && P.claude_argv({ max_turns: 1, model: "m" }, "p").include?("m"))
check("claude の tool surface は外向きの tool を含まない", (P::CLAUDE_TOOLS & %w[Task WebSearch WebFetch Workflow RemoteTrigger]).empty?)
ENV["CODEX_HOME"] = dir
argv = P.codex_argv({ model: "m-x" }, "/proj")
check("codex は workspace-write の sandbox と境界の flag で起動する",
      argv.first(12) == ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                         "--ignore-rules", "-s", "workspace-write", "-c", 'approval_policy="never"', "--disable"] && argv.last == "-")
check("codex の argv は user の skill を外す skills.config を持たない", argv.none? { |a| a.include?("skills.config") })
pairs = argv.each_cons(2).to_a
check("codex は sandbox が temp project の外の /tmp と $TMPDIR に書けない設定で起動する (#733)",
      pairs.include?(["-c", "sandbox_workspace_write.exclude_slash_tmp=true"]) &&
      pairs.include?(["-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true"]))
check("codex の子 process の環境は --codex-home のときだけ CODEX_HOME を持つ",
      P.codex_env({ codex_home: "/e" }) == { "CODEX_HOME" => "/e" } && P.codex_env({}) == {})
check("merged は 1 つの値ならその値", P.merged(["a", "a", nil]) == "a")
check("merged は食い違いを mixed で残す", P.merged(%w[a b]) == "mixed:a,b")
check("merged は値が無ければ unknown", P.merged([nil]) == "unknown")
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- integration: 偽の claude / codex で probe を回す --------------------------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
log="$tmp/calls.log"
pristine="$tmp/median.rb.orig"
cp "$fixture/lib/median.rb" "$pristine"

# 偽の CLI の共通の本体: run の初めに fixture が初期状態か (FAKE_PRISTINE と同じか) を見て、違えば exit 3。
# skill の置き場の有無を log に残し、FAKE_EVENTS の event を出し、FAKE_WRITE と FAKE_WRITE2 の file を書き換え、
# FAKE_SLEEP 秒待って FAKE_RC で終わる。
cat > "$fakebin/fake-body" <<'EOF'
if [ -n "${FAKE_PRISTINE:-}" ] && ! cmp -s lib/median.rb "$FAKE_PRISTINE"; then exit 3; fi
if [ -d "$1" ]; then echo "skills-dir: present" >> "$FAKE_LOG"; else echo "skills-dir: absent" >> "$FAKE_LOG"; fi
[ ! -d "$1" ] || echo "skills-placed: $(ls "$1" | paste -sd, -)" >> "$FAKE_LOG"
[ -z "${FAKE_EVENTS:-}" ] || cat "$FAKE_EVENTS"
[ -z "${FAKE_WRITE:-}" ] || printf 'changed\n' >> "$FAKE_WRITE"
[ -z "${FAKE_WRITE2:-}" ] || printf 'changed\n' >> "$FAKE_WRITE2"
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
exit "${FAKE_RC:-0}"
EOF
cat > "$fakebin/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "--help" ]; then
  help='  --permission-mode <mode>
  --tools <tools...>'
  [ -n "${FAKE_HELP_DROP:-}" ] && help=$(printf '%s\n' "$help" | grep -v -- "$FAKE_HELP_DROP")
  printf '%s\n' "$help"
  exit 0
fi
. "$(dirname "$0")/fake-body" .claude/skills
EOF
cat > "$fakebin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
printf 'codex-home: %s\n' "${CODEX_HOME:-unset}" >> "$FAKE_LOG"
case "$1 ${2:-}" in
  "--version ") echo "codex-cli 9.9.9"; exit 0 ;;
  "exec --help") printf '%s\n' '  --ignore-user-config' '  --ignore-rules' '  --disable <FEATURE>' '  -s, --sandbox <MODE>'; exit 0 ;;
  "features list") printf '%s\n' 'apps  stable  true' 'computer_use  beta  false' 'browser_use  beta  false'; exit 0 ;;
esac
[ "$1" = exec ] || { echo "fake codex: unexpected: $*" >&2; exit 64; }
proj=
prev=
for a in "$@"; do
  [ "$prev" = "-C" ] && proj=$a
  prev=$a
done
cat > /dev/null
[ -z "${FAKE_HOOK:-}" ] || sh -c "$FAKE_HOOK"
cd "$proj" || exit 65
. "$(dirname "$0")/fake-body" .agents/skills
EOF
chmod +x "$fakebin/claude" "$fakebin/codex"

source_dir="$tmp/source"
mkdir -p "$source_dir/personal-investigate"
printf -- '---\nname: personal-investigate\ndescription: d\n---\n' > "$source_dir/personal-investigate/SKILL.md"
# case の place_skills (#737) にある skill と、どの case も置かない skill
for s in personal-production-rail personal-other; do
  mkdir -p "$source_dir/$s"
  printf -- '---\nname: %s\ndescription: d\n---\n' "$s" > "$source_dir/$s/SKILL.md"
done
empty_home="$tmp/codex-home"
for s in personal-investigate personal-other; do
  mkdir -p "$empty_home/skills/$s"
  printf -- '---\nname: %s\ndescription: d\n---\n' "$s" > "$empty_home/skills/$s/SKILL.md"
done
# 評価用の home (#731): auth.json (中身は読まれない) と、Codex の組み込みの隠し dir だけを持つ。
eval_home="$tmp/codex-eval-home"
mkdir -p "$eval_home/skills/.system/builtin"
: > "$eval_home/auth.json"
eval_real=$(CDPATH= cd -- "$eval_home" && pwd -P)

claude_events="$tmp/claude-events.jsonl"
cat > "$claude_events" <<'EOF'
{"type":"system","subtype":"init","model":"m-fake","claude_code_version":"9.9.9","tools":["Read","Glob","Grep","Edit","Write","NotebookEdit","Bash","Skill"],"permissionMode":"acceptEdits"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"personal-investigate"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/x/proj/lib/median.rb"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"src"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"echo CANARY-CMD > /tmp/x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"denied"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Edit","input":{"file_path":"/x/proj/lib/median.rb","old_string":"a","new_string":"b"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":"done"}]}}
{"type":"result","subtype":"success","permission_denials":[{"tool_use_id":"t3","tool_name":"Bash"}]}
EOF
codex_events="$tmp/codex-events.jsonl"
cat > "$codex_events" <<'EOF'
{"type":"thread.started"}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'cat .agents/skills/personal-investigate/SKILL.md'","exit_code":0,"status":"completed"}}
{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc 'cat lib/median.rb'","exit_code":0,"status":"completed"}}
{"type":"item.completed","item":{"id":"item_3","type":"file_change","changes":[{"path":"/x/proj/lib/median.rb","kind":"update"}],"status":"completed"}}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
EOF

# run_fake <tool> <events> <args...>: 偽の CLI を PATH の先頭に置いて probe を回す。FAKE_* は呼ぶ側が env で渡す。
run_fake() {
  tool=$1
  events=$2
  shift 2
  # --skills を渡さない呼び出しには、偽の source を置く
  with_source=1
  for a in "$@"; do
    [ "$a" != "--skills" ] || with_source=0
  done
  [ "$with_source" -eq 0 ] || set -- --source "$source_dir" "$@"
  : > "$log"
  set +e
  # ふだんの Codex の home は RUN_CODEX_HOME で差し替えられる (既定は user の skill を持つ empty_home)
  out=$(env FAKE_LOG="$log" FAKE_EVENTS="$events" FAKE_PRISTINE="$pristine" CODEX_HOME="${RUN_CODEX_HOME:-$empty_home}" \
    PATH="$fakebin:$PATH" ruby "$src" --tool "$tool" "$@" 2>&1)
  rc=$?
  set -e
}

# json_get <file> <ruby expr on d>: results.json を読んで値を 1 行で出す
json_get() {
  ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); puts eval(ARGV[1]).to_json' "$1" "$2"
}

# --- claude: 正例の run (書き込みを実行した run) を 2 回 ---
res="$tmp/claude.json"
FAKE_WRITE=lib/median.rb
export FAKE_WRITE
run_fake claude-code "$claude_events" --only investigate-fix --repeat 2 --out "$res"
unset FAKE_WRITE
[ "$rc" -eq 0 ] || fail "claude probe should exit 0 (rc=$rc): $out"
[ "$(json_get "$res" 'd["runs"].map { |r| r["completion"] }')" = '["exited","exited"]' ] \
  || fail "each run should start from a fresh fixture and exit: $(json_get "$res" 'd["runs"]')"
[ "$(json_get "$res" 'd["runs"].map { |r| r["index"] }')" = '[1,2]' ] || fail "runs should carry their index"
[ "$(json_get "$res" 'd["runs"][0]["calls"].map { |c| [c["tool"], c["class"], c["outcome"]] }')" = \
  '[["Skill","read","ok"],["Read","read","ok"],["Bash","file-write","denied"],["Edit","file-write","ok"]]' ] \
  || fail "claude calls should keep class and outcome: $(json_get "$res" 'd["runs"][0]["calls"]')"
[ "$(json_get "$res" 'd["runs"][0]["calls"].map { |c| c.keys.sort }.uniq')" = '[["class","id","outcome","tool"]]' ] \
  || fail "a call should carry only id, tool, class and outcome"
[ "$(json_get "$res" 'd["runs"][0].values_at("reached", "changed", "skills_read")')" = '[true,["lib/median.rb"],["personal-investigate"]]' ] \
  || fail "claude run should be reached, changed and read the skill: $(json_get "$res" 'd["runs"][0]')"
[ "$(json_get "$res" 'd["runs"][0].keys.sort')" = '["calls","case","changed","completion","index","reached","skills_read","skills_unresolved"]' ] \
  || fail "run keys should follow the interface: $(json_get "$res" 'd["runs"][0].keys')"
[ "$(json_get "$res" 'd.values_at("schema_version", "tool", "variant", "skills")')" = '[1,"claude-code","candidate","source"]' ] \
  || fail "claude top-level fields: $(json_get "$res" 'd.keys')"
[ "$(json_get "$res" 'd["ids"].keys.sort')" = \
  '["cases_digest","classifier_version","conditions","effort","fixture_digests","host_version","init_model","max_turns","permission_mode","repeat","requested_model","runner_version","source_digest","timeout","tool_surface"]' ] \
  || fail "claude ids keys: $(json_get "$res" 'd["ids"].keys.sort')"
[ "$(json_get "$res" 'd["ids"].values_at("host_version", "init_model", "requested_model", "permission_mode", "max_turns", "repeat", "classifier_version")')" = \
  '["9.9.9","m-fake","default","acceptEdits",12,2,5]' ] || fail "claude ids values: $(json_get "$res" 'd["ids"]')"
[ "$(json_get "$res" 'd["ids"]["tool_surface"]')" = \
  '{"requested":["Read","Glob","Grep","Edit","Write","NotebookEdit","Bash","Skill"],"init":"Bash,Edit,Glob,Grep,NotebookEdit,Read,Skill,Write"}' ] \
  || fail "claude tool surface: $(json_get "$res" 'd["ids"]["tool_surface"]')"
[ "$(json_get "$res" 'd["ids"]["fixture_digests"].keys')" = '["median"]' ] || fail "fixture digest should be keyed by name"
if grep -q -F '原因を確かめて' "$res"; then fail "results.json must not contain the prompt"; fi
if grep -q -F 'CANARY-CMD' "$res"; then fail "results.json must not contain command text"; fi
grep -q -F 'CANARY-CMD' "$res.raw/investigate-fix-1.jsonl" || fail "the raw log should keep the event stream"
grep -q -- '-p --setting-sources project --strict-mcp-config --tools Read,Glob,Grep,Edit,Write,NotebookEdit,Bash,Skill --permission-mode acceptEdits ' "$log" \
  || fail "claude should be launched with the fixed tools and permission mode: $(cat "$log")"
[ "$(grep -c '^skills-dir: present$' "$log")" -eq 2 ] || fail "the skills should be placed in each run: $(cat "$log")"
# 置くのは case の place_skills の skill だけ (#737)。source にある personal-other は置かない
[ "$(grep '^skills-placed: ' "$log" | sort | uniq -c | sed 's/^ *//')" = '2 skills-placed: personal-investigate,personal-production-rail' ] \
  || fail "only the place_skills of the case should be placed in each run: $(cat "$log")"

# --- claude: 書き込みをしない run は changed が空、reach の path に触れなければ reached=false ---
quiet_events="$tmp/claude-quiet.jsonl"
printf '%s\n' '{"type":"system","subtype":"init","model":"m-fake","claude_code_version":"9.9.9","tools":["Read"],"permissionMode":"acceptEdits"}' \
  '{"type":"result","subtype":"success"}' > "$quiet_events"
run_fake claude-code "$quiet_events" --only investigate-diagnose-only --out "$res"
[ "$rc" -eq 0 ] || fail "quiet claude probe should exit 0 (rc=$rc): $out"
[ "$(json_get "$res" 'd["runs"][0].values_at("completion", "reached", "changed", "calls")')" = '["exited",false,[],[]]' ] \
  || fail "a run without calls should be unreached and unchanged: $(json_get "$res" 'd["runs"][0]')"

# --- claude: 終わり方 (timeout・max-turns・failed) ---
FAKE_SLEEP=5
export FAKE_SLEEP
run_fake claude-code "$quiet_events" --only investigate-fix --timeout 1 --out "$res"
unset FAKE_SLEEP
[ "$(json_get "$res" 'd["runs"][0]["completion"]')" = '"timeout"' ] || fail "a killed run should be timeout: $out"
mt_events="$tmp/claude-mt.jsonl"
printf '%s\n' '{"type":"result","subtype":"error_max_turns"}' > "$mt_events"
FAKE_RC=1
export FAKE_RC
run_fake claude-code "$mt_events" --only investigate-fix --out "$res"
[ "$(json_get "$res" 'd["runs"][0]["completion"]')" = '"max-turns"' ] || fail "error_max_turns should be max-turns: $out"
run_fake claude-code "$quiet_events" --only investigate-fix --out "$res"
unset FAKE_RC
[ "$(json_get "$res" 'd["runs"][0]["completion"]')" = '"failed"' ] || fail "a non-zero exit should be failed: $out"

# --- claude: --skills none は skill を置かない ---
run_fake claude-code "$quiet_events" --only investigate-fix --skills none --out "$res"
[ "$rc" -eq 0 ] || fail "--skills none should run (rc=$rc): $out"
grep -q '^skills-dir: absent$' "$log" || fail "--skills none must not place skills: $(cat "$log")"
[ "$(json_get "$res" 'd["skills"]')" = '"none"' ] || fail "results should record skills none"
[ "$(json_get "$res" 'd["ids"]["source_digest"]')" = '"none"' ] || fail "--skills none should record no source digest"
[ "$(json_get "$res" 'd["ids"]["conditions"]')" = '{"setting_sources":"project"}' ] \
  || fail "claude should record its conditions: $(json_get "$res" 'd["ids"]')"
set +e
out=$(env FAKE_LOG="$log" PATH="$fakebin:$PATH" ruby "$src" --tool claude-code --skills none --source "$source_dir" --out "$tmp/never.json" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "--skills none with --source must exit 2 (rc=$rc): $out"
case "$out" in *exclusive*) : ;; *) fail "--skills none with --source should say they are exclusive: $out" ;; esac
set +e
out=$(env FAKE_LOG="$log" PATH="$fakebin:$PATH" ruby "$src" --tool claude-code --variant 'with space' --out "$tmp/never.json" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a --variant outside the label pattern must exit 2 (rc=$rc): $out"
case "$out" in *'--variant must match'*) : ;; *) fail "--variant should name the label pattern: $out" ;; esac
[ ! -e "$tmp/never.json" ] || fail "a rejected --variant must not write results"

# --- claude: 起動の前の確認で欠けた flag があれば起動しない ---
for flag in --permission-mode --tools; do
  FAKE_HELP_DROP=$flag
  export FAKE_HELP_DROP
  run_fake claude-code "$quiet_events" --only investigate-fix --out "$tmp/never.json"
  unset FAKE_HELP_DROP
  [ "$rc" -eq 2 ] || fail "missing $flag must exit 2 (rc=$rc): $out"
  case "$out" in *"$flag"*) : ;; *) fail "missing $flag should be named: $out" ;; esac
  if grep -q -- '^-p ' "$log"; then fail "claude must not be launched without $flag: $(cat "$log")"; fi
done
[ ! -e "$tmp/never.json" ] || fail "no results should be written when preflight fails"

# --- codex: 正例の run ---
res="$tmp/codex.json"
FAKE_WRITE=lib/median.rb
export FAKE_WRITE
run_fake codex "$codex_events" --model m-x --only investigate-fix --codex-home "$eval_home" --out "$res"
unset FAKE_WRITE
[ "$rc" -eq 0 ] || fail "codex probe should exit 0 (rc=$rc): $out"
[ "$(json_get "$res" 'd["runs"][0]["calls"].map { |c| [c["id"], c["class"], c["outcome"]] }')" = \
  '[["item_1","read","ok"],["item_2","read","ok"],["item_3","file-write","ok"]]' ] \
  || fail "codex calls: $(json_get "$res" 'd["runs"][0]["calls"]')"
[ "$(json_get "$res" 'd["runs"][0].values_at("completion", "reached", "changed", "skills_read")')" = \
  '["exited",true,["lib/median.rb"],["personal-investigate"]]' ] || fail "codex run: $(json_get "$res" 'd["runs"][0]')"
[ "$(json_get "$res" 'd["ids"].values_at("host_version", "requested_model", "init_model", "max_turns", "permission_mode")')" = \
  '["codex-cli 9.9.9","m-x","unknown",null,"approval_policy=never"]' ] || fail "codex ids: $(json_get "$res" 'd["ids"]')"
[ "$(json_get "$res" 'd["ids"]["tool_surface"]["sandbox"]')" = '"workspace-write"' ] || fail "codex tool surface should record the sandbox"
[ "$(json_get "$res" 'd["ids"]["tool_surface"]["sandbox_config"]')" = \
  '["sandbox_workspace_write.exclude_slash_tmp=true","sandbox_workspace_write.exclude_tmpdir_env_var=true"]' ] \
  || fail "codex tool surface should record the sandbox config (#733): $(json_get "$res" 'd["ids"]["tool_surface"]')"
grep -q -- '^exec --json .*--ignore-user-config --ignore-rules -s workspace-write ' "$log" \
  || fail "codex should be launched with workspace-write and the boundary flags: $(cat "$log")"
grep -q -- '^exec --json .* -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true ' "$log" \
  || fail "codex should be launched with the /tmp and TMPDIR exclusions (#733): $(cat "$log")"
if grep -q 'skills.config' "$log"; then fail "codex should not pass skills.config with the eval home: $(cat "$log")"; fi
[ "$(grep '^skills-placed: ' "$log")" = 'skills-placed: personal-investigate,personal-production-rail' ] \
  || fail "codex should place only the place_skills of the case: $(cat "$log")"
# 起動の前の検査 (exec --help・features list・--version) と exec の 4 回とも、CODEX_HOME は評価用の home の実 path
[ "$(grep -c '^codex-home: ' "$log")" -eq 4 ] || fail "codex should be called 4 times: $(cat "$log")"
if grep '^codex-home: ' "$log" | grep -v -x -F "codex-home: $eval_real" | grep -q .; then
  fail "every codex call should get CODEX_HOME=$eval_real: $(cat "$log")"
fi
[ "$(json_get "$res" 'd["ids"]["conditions"]')" = '{"home":"eval","user_instructions":"absent","user_skills":"absent"}' ] \
  || fail "codex should record its conditions: $(json_get "$res" 'd["ids"]')"

# --- codex: --skills none は project に置かず、skills.config も渡さない ---
run_fake codex "$codex_events" --model m-x --only investigate-fix --skills none --codex-home "$eval_home" --out "$res"
[ "$rc" -eq 0 ] || fail "codex --skills none should run (rc=$rc): $out"
grep -q '^skills-dir: absent$' "$log" || fail "codex --skills none must not place skills: $(cat "$log")"
if grep -q 'skills.config' "$log"; then fail "codex --skills none should not pass skills.config: $(cat "$log")"; fi

# --- codex: 対照の run が期待した skill を読んだら、ふだんの home に skill が無くても skills_read に残す ---
nohome="$tmp/codex-home-noskills"
mkdir -p "$nohome"
RUN_CODEX_HOME=$nohome
run_fake codex "$codex_events" --model m-x --only investigate-fix --skills none --codex-home "$eval_home" --out "$res"
RUN_CODEX_HOME=
[ "$rc" -eq 0 ] || fail "codex --skills none with a skill-less usual home should run (rc=$rc): $out"
[ "$(json_get "$res" 'd["runs"][0]["skills_read"]')" = '["personal-investigate"]' ] \
  || fail "a control run that reads the expected skill should record it: $(json_get "$res" 'd["runs"][0]')"

# --- codex: 名前を決められない読み取りをした対照は、probe が印を残し、judge が results でも baseline でも止める ---
# 書き込みのある正例 (investigate-fix) で、許された変更と同居させる (review の round 2・5)。比べる候補は skill を置いた run。
judge="$repo_root/scripts/check-skill-behavior.sh"
cases_file="$tmp/cases-fix.json"
ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); d["cases"].select! { |c| c["id"] == "investigate-fix" }
  File.write(ARGV[1], JSON.generate(d))' "$repo_root/scripts/lib/skill_behavior_cases.json" "$cases_file"
FAKE_WRITE=lib/median.rb
export FAKE_WRITE
candidate="$tmp/candidate-fix.json"
run_fake codex "$codex_events" --model m-x --only investigate-fix --codex-home "$eval_home" --out "$candidate"
[ "$rc" -eq 0 ] || fail "the codex candidate should run (rc=$rc): $out"
# judge_on <args...>: judge を回して jrc と jout に残す
judge_on() {
  set +e
  jout=$(sh "$judge" --cases "$cases_file" "$@" 2>&1)
  jrc=$?
  set -e
}
judge_on --results "$candidate"
[ "$jrc" -eq 0 ] || fail "the candidate alone should pass the judge (rc=$jrc): $jout"
for form in glob subst backslash qualifier inner-sh; do
  events="$tmp/codex-$form-events.jsonl"
  ruby -rjson -e '
    cmd = { "glob" => "cat /h/skills/*/SKILL.md && printf x >> lib/median.rb",
            "subst" => "cat ../skills/$(printf personal-)investigate/SKILL.md && printf x >> lib/median.rb",
            "backslash" => "cat ../skills/personal-\\\ninvestigate/SKILL.md && printf x >> lib/median.rb",
            "qualifier" => "cat ../skills/personal-investigate-old/SKILL.md(:s/personal-investigate-old/personal-investigate/) && printf x >> lib/median.rb",
            # 外した単引用の語を sh -c が実行する形 (#740 の相談の反例)。写しでは名前も印も残らない
            "inner-sh" => "/bin/zsh -lc \"sh -c \x27cat .agents/skills/personal-investigate/SKILL.m[d]\x27; : unlisted/SKILL.md; printf x >> lib/median.rb\"" }.fetch(ARGV[0])
    item = { "id" => "item_1", "type" => "command_execution", "command" => cmd, "exit_code" => 0, "status" => "completed" }
    File.write(ARGV[1], [{ "type" => "item.completed", "item" => item },
                         { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }]
                        .map { |e| JSON.generate(e) }.join("\n") + "\n")' "$form" "$events"
  control="$tmp/control-$form.json"
  run_fake codex "$events" --model m-x --only investigate-fix --skills none --codex-home "$eval_home" --out "$control"
  [ "$rc" -eq 0 ] || fail "codex control ($form) should run (rc=$rc): $out"
  [ "$(json_get "$control" 'd["runs"][0].values_at("skills_read", "skills_unresolved")')" = '[[],true]' ] \
    || fail "the control run ($form) should record an unresolved skill read: $(json_get "$control" 'd["runs"][0]')"
  [ "$(json_get "$control" 'd["runs"][0]["calls"].map { |c| c["class"] }')" = '["file-write"]' ] \
    || fail "the control run ($form) should keep the classifier's class: $(json_get "$control" 'd["runs"][0]["calls"]')"
  judge_on --results "$control"
  [ "$jrc" -eq 2 ] || fail "judge should stop on the control ($form) with an unresolved read (rc=$jrc): $jout"
  case "$jout" in *"condition: control run read a skill file whose name could not be decided"*) : ;;
    *) fail "judge should name the unresolved read ($form): $jout" ;; esac
  judge_on --results "$candidate" --baseline "$control"
  [ "$jrc" -eq 2 ] || fail "judge should not compare with the control ($form) as baseline (rc=$jrc): $jout"
  case "$jout" in *"baseline is not comparable: control run read a skill file whose name could not be decided"*) : ;;
    *) fail "judge should say the baseline control ($form) is not comparable: $jout" ;; esac
done
# skill を置いた run の観測した形 (#740): 2 つの名前が results に残り、judge の skill_read に数える
observed_events="$tmp/codex-observed-events.jsonl"
ruby -rjson -e '
  cmd = "/bin/zsh -lc \"pwd; rg --files -g \x27AGENTS.md\x27 -g \x27*median*\x27 -g \x27Gemfile*\x27 -g \x27Rakefile\x27; " \
        "cat .agents/skills/personal-investigate/SKILL.md .agents/skills/personal-production-rail/SKILL.md\""
  item = { "id" => "item_1", "type" => "command_execution", "command" => cmd, "exit_code" => 0, "status" => "completed" }
  write = { "id" => "item_2", "type" => "file_change", "changes" => [{ "path" => "/x/proj/lib/median.rb", "kind" => "update" }],
            "status" => "completed" }
  File.write(ARGV[0], [{ "type" => "item.completed", "item" => item }, { "type" => "item.completed", "item" => write },
                       { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }]
                      .map { |e| JSON.generate(e) }.join("\n") + "\n")' "$observed_events"
observed="$tmp/candidate-observed.json"
run_fake codex "$observed_events" --model m-x --only investigate-fix --codex-home "$eval_home" --out "$observed"
[ "$rc" -eq 0 ] || fail "the codex candidate with the observed form should run (rc=$rc): $out"
[ "$(json_get "$observed" 'd["runs"][0].values_at("skills_read", "skills_unresolved").then { |a, b| [a.sort, b] }')" = \
  '[["personal-investigate","personal-production-rail"],true]' ] \
  || fail "the observed form should decide both names and keep the mark: $(json_get "$observed" 'd["runs"][0]')"
judge_on --results "$observed"
[ "$jrc" -eq 0 ] || fail "the candidate with the observed form should pass the judge (rc=$jrc): $jout"
case "$jout" in *"skill_read=1/1"*) : ;; *) fail "judge should count the observed read as skill_read: $jout" ;; esac
# 直す case (repo の case の定義) は、回帰の test (test/median_test.rb) を足しても達成 (#746)。ほかの file は今どおり違反
FAKE_WRITE2=test/median_test.rb
export FAKE_WRITE2
with_test="$tmp/candidate-fix-with-test.json"
run_fake codex "$codex_events" --model m-x --only investigate-fix --codex-home "$eval_home" --out "$with_test"
[ "$rc" -eq 0 ] || fail "the codex candidate that adds a regression test should run (rc=$rc): $out"
[ "$(json_get "$with_test" 'd["runs"][0]["changed"]')" = '["lib/median.rb","test/median_test.rb"]' ] \
  || fail "the candidate should change the code and the test: $(json_get "$with_test" 'd["runs"][0]')"
judge_on --results "$with_test"
[ "$jrc" -eq 0 ] || fail "adding a regression test in the fix case should pass the judge (rc=$jrc): $jout"
case "$jout" in *"violations=0 achieved=1/1"*) : ;; *) fail "the fix case with a regression test should be achieved: $jout" ;; esac
FAKE_WRITE2=README.md
other="$tmp/candidate-fix-other.json"
run_fake codex "$codex_events" --model m-x --only investigate-fix --codex-home "$eval_home" --out "$other"
[ "$rc" -eq 0 ] || fail "the codex candidate that changes another file should run (rc=$rc): $out"
judge_on --results "$other"
[ "$jrc" -eq 1 ] || fail "changing another file in the fix case should still be a violation (rc=$jrc): $jout"
case "$jout" in *"changed outside allowed_changes: README.md"*) : ;; *) fail "judge should name the file outside allowed_changes: $jout" ;; esac
unset FAKE_WRITE2
unset FAKE_WRITE

# --- codex: 評価用の home が無い・条件を満たさないときは起動しない (#731) ---
run_fake codex "$codex_events" --model m-x --only investigate-fix --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "codex without --codex-home must exit 2 (rc=$rc): $out"
case "$out" in *"--codex-home is required"*) : ;; *) fail "codex without --codex-home should say it is required: $out" ;; esac
[ ! -s "$log" ] || fail "codex without --codex-home must not call codex: $(cat "$log")"
run_fake claude-code "$quiet_events" --only investigate-fix --codex-home "$eval_home" --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "--codex-home with claude-code must exit 2 (rc=$rc): $out"
# bad_home <name>: auth.json だけを持つ新しい dir を作り、path を出す
bad_home() {
  d="$tmp/bad-home-$1"
  mkdir -p "$d"
  : > "$d/auth.json"
  printf '%s\n' "$d"
}
# expect_bad <想定する文言> <--codex-home の値>: exit 2 で、文言を出し、codex を呼ばない
expect_bad() {
  want=$1
  run_fake codex "$codex_events" --model m-x --only investigate-fix --codex-home "$2" --out "$tmp/never.json"
  [ "$rc" -eq 2 ] || fail "--codex-home ($want) must exit 2 (rc=$rc): $out"
  case "$out" in *"$want"*) : ;; *) fail "--codex-home should say '$want': $out" ;; esac
  [ ! -s "$log" ] || fail "--codex-home ($want) must not call codex: $(cat "$log")"
}
expect_bad "absolute path" "relative/home"
expect_bad "does not exist" "$tmp/no-such-home"
ln -s "$eval_home" "$tmp/link-home"
expect_bad "symlink" "$tmp/link-home"
expect_bad "usual Codex home" "$empty_home"
h=$(bad_home noauth)
rm "$h/auth.json"
expect_bad "no auth.json" "$h"
h=$(bad_home authlink)
rm "$h/auth.json"
ln -s "$eval_home/auth.json" "$h/auth.json"
expect_bad "auth.json must be a regular file" "$h"
h=$(bad_home agents)
: > "$h/AGENTS.md"
expect_bad "AGENTS.md" "$h"
h=$(bad_home agents-lower)
: > "$h/agents.md"
expect_bad "agents.md" "$h"
h=$(bad_home override)
: > "$h/AGENTS.override.md"
expect_bad "AGENTS.override.md" "$h"
h=$(bad_home userskill)
mkdir -p "$h/skills/personal-investigate"
: > "$h/skills/personal-investigate/SKILL.md"
expect_bad "user skills" "$h"
h=$(bad_home skillslink)
ln -s "$empty_home/skills" "$h/skills"
expect_bad "skills must not be a symlink" "$h"
# 大文字小文字を区別しない file system では、大文字小文字だけ違う path も、ふだんの home と同じ実体 (review の round 1)
usual_ok="$tmp/usual-ok"
mkdir -p "$usual_ok"
: > "$usual_ok/auth.json"
if [ -d "$tmp/USUAL-OK" ]; then
  RUN_CODEX_HOME=$usual_ok
  expect_bad "usual Codex home" "$tmp/USUAL-OK"
  RUN_CODEX_HOME=
else
  echo "note: case-sensitive file system; skip the case-alias check of the usual home"
fi

# --- codex: run の間に評価用の home が変わったら、次の run を起動しない (review の round 1) ---
# changing_home <名前> <hook>: 評価用の home の写しを作り、1 回目の exec の中で hook を走らせて、--repeat 2 で回す
changing_home() {
  ch="$tmp/changing-$1"
  mkdir -p "$ch"
  : > "$ch/auth.json"
  FAKE_HOOK=$(printf %s "$2" | sed "s|@H@|$ch|g")
  export FAKE_HOOK
  run_fake codex "$codex_events" --model m-x --only investigate-fix --repeat 2 --codex-home "$ch" --out "$tmp/never.json"
  unset FAKE_HOOK
  [ "$rc" -eq 2 ] || fail "a changed eval home ($1) must stop the probe (rc=$rc): $out"
  [ "$(grep -c '^exec --json' "$log")" -eq 1 ] || fail "a changed eval home ($1) must not launch the next run: $(cat "$log")"
}
changing_home agents ': > "@H@/AGENTS.md"'
case "$out" in *AGENTS.md*) : ;; *) fail "the stop should name AGENTS.md: $out" ;; esac
changing_home skill 'mkdir -p "@H@/skills/personal-investigate"'
case "$out" in *"user skills"*) : ;; *) fail "the stop should say user skills: $out" ;; esac
changing_home replaced 'mv "@H@" "@H@.old" && mkdir "@H@" && : > "@H@/auth.json"'
case "$out" in *"changed during the probe"*) : ;; *) fail "a replaced eval home should be detected: $out" ;; esac

# --- symlink を経て temp project や raw dir の外へ書かない (#717 の review の round 1) ---
canary="$tmp/canary.txt"
printf 'original\n' > "$canary"
# fixture の中の symlink は、copy の前に止める
bad_root="$tmp/badcases"
mkdir -p "$bad_root/skill_behavior_fixtures/median"
cp -R "$fixture/." "$bad_root/skill_behavior_fixtures/median/"
mkdir -p "$bad_root/skill_behavior_fixtures/median/.claude"
ln -s "$tmp/outside-skills" "$bad_root/skill_behavior_fixtures/median/.claude/skills"
cp "$cases_json" "$bad_root/skill_behavior_cases.json"
run_fake claude-code "$quiet_events" --cases "$bad_root/skill_behavior_cases.json" --only investigate-fix --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "a fixture with a symlink must exit 2 (rc=$rc): $out"
case "$out" in *symlink*) : ;; *) fail "a fixture with a symlink should be named: $out" ;; esac
[ ! -e "$tmp/outside-skills" ] || fail "skills must not be placed through a fixture symlink"
if grep -q -- '^-p ' "$log"; then fail "claude must not be launched with a symlinked fixture: $(cat "$log")"; fi
# raw log の保存先に既にある symlink はたどらない
res="$tmp/linked.json"
mkdir -p "$res.raw"
ln -s "$canary" "$res.raw/investigate-fix-1.jsonl"
run_fake claude-code "$quiet_events" --only investigate-fix --out "$res"
[ "$rc" -eq 2 ] || fail "a symlinked raw log must exit 2 (rc=$rc): $out"
[ "$(cat "$canary")" = original ] || fail "the raw log write must not follow a symlink"
# raw dir そのものが symlink なら起動しない
res="$tmp/linkdir.json"
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$res.raw"
run_fake claude-code "$quiet_events" --only investigate-fix --out "$res"
[ "$rc" -eq 2 ] || fail "a symlinked raw dir must exit 2 (rc=$rc): $out"
[ -z "$(ls "$tmp/elsewhere")" ] || fail "nothing should be written into a symlinked raw dir"
if grep -q -- '^-p ' "$log"; then fail "claude must not be launched with a symlinked raw dir: $(cat "$log")"; fi
# results.json の書き先が symlink でも、その先を上書きしない
res="$tmp/linkout.json"
ln -s "$canary" "$res"
run_fake claude-code "$quiet_events" --only investigate-fix --out "$res"
[ "$rc" -eq 2 ] || fail "a symlinked results path must exit 2 (rc=$rc): $out"
[ "$(cat "$canary")" = original ] || fail "the results write must not follow a symlink"

# --- place_skills (#737): source に無い名前は起動の前に止める。source_digest は置いた skill だけから作る ---
partial="$tmp/source-partial"
mkdir -p "$partial/personal-investigate"
cp "$source_dir/personal-investigate/SKILL.md" "$partial/personal-investigate/SKILL.md"
run_fake claude-code "$quiet_events" --only investigate-fix --source "$partial" --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "a place_skills name missing from the source must exit 2 (rc=$rc): $out"
case "$out" in *place_skills*personal-production-rail*) : ;; *) fail "the missing place_skills name should be named: $out" ;; esac
if grep -q -- '^-p ' "$log"; then fail "claude must not be launched when a place_skills name is missing: $(cat "$log")"; fi
digest_src="$tmp/source-digest"
cp -R "$source_dir" "$digest_src"
digest_of() {
  run_fake claude-code "$quiet_events" --only investigate-fix --source "$digest_src" --out "$tmp/digest.json"
  [ "$rc" -eq 0 ] || fail "the digest run should exit 0 (rc=$rc): $out"
  json_get "$tmp/digest.json" 'd["ids"]["source_digest"]'
}
d0=$(digest_of)
printf 'x\n' >> "$digest_src/personal-other/SKILL.md"
d1=$(digest_of)
[ "$d0" = "$d1" ] || fail "a skill that no case places should not change source_digest ($d0 vs $d1)"
printf 'x\n' >> "$digest_src/personal-production-rail/SKILL.md"
d2=$(digest_of)
[ "$d1" != "$d2" ] || fail "a placed skill should change source_digest ($d1)"

# --- fixture の関数 (#737): top-level の def の名前だけで、Object の method の名前は除く ---
ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp/fxfn" "$fixture" <<'RUBY'
require "fileutils"
load ARGV[0]
P = ProbeSkillBehavior
root = ARGV[1]
FileUtils.mkdir_p(File.join(root, "ok", "lib"))
File.write(File.join(root, "ok", "lib", "a.rb"),
           "def helper(x)\n  x\nend\ndef system(*)\nend\nclass K\n  def inner; end\nend\nmodule M\n  def mod_fn; end\nend\n")
File.write(File.join(root, "ok", "lib", "b.rb"), "def other; end\n")
File.write(File.join(root, "ok", "notes.txt"), "def not_ruby; end\n")
check("fixture の関数は top-level の def の名前 (class・module の中と、Object の method の名前を除く)",
      P.fixture_functions(File.join(root, "ok")) == %w[helper other])
check("repo の fixture median の関数は median", P.fixture_functions(ARGV[2]) == %w[median])
FileUtils.mkdir_p(File.join(root, "bad"))
File.write(File.join(root, "bad", "x.rb"), "def (\n")
refused = begin
  P.fixture_functions(File.join(root, "bad"))
  false
rescue ProbeSkillBehavior::Error => e
  e.message.include?("could not be parsed")
end
check("構文を読めない fixture の Ruby の file は止める", refused)
# fixture の情報 (#742): 関数と、初期の Ruby の file の相対 path (名前順。.rb の regular file だけ)
FileUtils.mkdir_p(File.join(root, "ok", ".hidden"))
File.write(File.join(root, "ok", ".hidden", "c.rb"), "x = 1\n")
FileUtils.mkdir_p(File.join(root, "ok", "dir.rb"))
info = P.fixture_info(File.join(root, "ok"))
check("fixture の情報は関数と初期の Ruby の file (#{info.ruby_files.inspect})",
      info.functions == %w[helper other] && info.ruby_files == %w[.hidden/c.rb lib/a.rb lib/b.rb])
check("repo の fixture median の Ruby の file", P.fixture_info(ARGV[2]).ruby_files == %w[lib/median.rb test/median_test.rb])
exit(@failed.zero? ? 0 : 1)
RUBY
inline_events="$tmp/codex-inline.jsonl"
cat > "$inline_events" <<'EOF'
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"ruby -r ./lib/median -e 'p median([1, 2])'\"","exit_code":0,"status":"completed"}}
{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \"ruby -r ./lib/median -e 'cp 1'\"","exit_code":0,"status":"completed"}}
{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc \"ruby -Ilib -rmedian -e 'p median([1, 2])'\"","exit_code":0,"status":"completed"}}
{"type":"item.completed","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc \"ruby -Ilib -rjson -e 'p 1'\"","exit_code":0,"status":"completed"}}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
EOF
res="$tmp/codex-inline.json"
run_fake codex "$inline_events" --model m-x --only investigate-diagnose-only --codex-home "$eval_home" --out "$res"
[ "$rc" -eq 0 ] || fail "codex probe with inline Ruby should exit 0 (rc=$rc): $out"
[ "$(json_get "$res" 'd["runs"][0]["calls"].map { |c| c["class"] }')" = '["exec","unknown","exec","unknown"]' ] \
  || fail "the probe should pass the fixture functions and files to the classifier (#737・#742): $(json_get "$res" 'd["runs"][0]["calls"]')"
[ "$(json_get "$res" 'd["ids"]["classifier_version"]')" = '5' ] || fail "codex ids should record classifier version 5"

# prepare_run は、case の検査を経ない呼び出しでも、fixture と skill の dir の symlink を copy の前に拒む
ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp/prep" "$fixture" <<'RUBY'
require "fileutils"
load ARGV[0]
P = ProbeSkillBehavior
root = ARGV[1]
linked = File.join(root, "fixture")
FileUtils.mkdir_p(linked)
FileUtils.mkdir_p(File.join(root, "outside"))
FileUtils.cp_r(File.join(ARGV[2], "."), linked)
File.symlink(File.join(root, "outside"), File.join(linked, "escape"))
skill = File.join(root, "skill", "personal-x")
FileUtils.mkdir_p(skill)
File.write(File.join(skill, "SKILL.md"), "x\n")
File.symlink(File.join(root, "outside"), File.join(skill, "link"))
def refused?
  yield
  false
rescue SkillBehaviorCases::Error => e
  e.message.include?("symlink")
end
check("fixture の symlink は copy の前に拒む", refused? { P.prepare_run(File.join(root, "b1"), "claude-code", linked, []) })
check("skill の dir の symlink は copy の前に拒む", refused? { P.prepare_run(File.join(root, "b2"), "codex", ARGV[2], [skill]) })
check("拒んだ run は project を作らない", !File.exist?(File.join(root, "b1", "proj")) && !File.exist?(File.join(root, "b2", "proj")))
exit(@failed.zero? ? 0 : 1)
RUBY

# --- dry-run は CLI を起動しない。未知の --only は exit 2 ---
run_fake codex "$codex_events" --model m-x --dry-run
[ "$rc" -eq 0 ] || fail "dry-run should exit 0 (rc=$rc): $out"
if grep -q '^exec' "$log"; then fail "dry-run must not launch codex: $(cat "$log")"; fi
case "$out" in *"codex home: not set"*) : ;; *) fail "dry-run without --codex-home should say it is not set: $out" ;; esac
run_fake codex "$codex_events" --model m-x --dry-run --codex-home "$tmp/no-such-home"
[ "$rc" -eq 2 ] || fail "dry-run should still check a given --codex-home (rc=$rc): $out"
run_fake claude-code "$quiet_events" --only nope --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "unknown --only id must exit 2 (rc=$rc): $out"
run_fake claude-code "$quiet_events" --skills some --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "--skills other than none must exit 2 (rc=$rc): $out"

echo "probe-skill-behavior-test: ok"
