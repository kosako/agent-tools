#!/bin/sh
# scripts/lib/probe_skill_behavior.rb と skill_behavior_cases.rb の self-test (#369)。
# - 分類器: Claude Code の tool と shell の command を区分 (read・file-write・github-write・git-write・agent-launch・
#   unknown) に分ける。引用の中の語・redirect・入れ子の shell・command の置き換えを固定の入力で確かめる。
# - event の解析: 呼び出しを ID で束ね、要求の結果 (ok・error・denied・unknown) を別に残す。skill の読み取りと
#   init の値を取り出す。
# - case set の検査、state の差分、終わり方、起動の argv。
# - integration: PATH 上の偽の claude / codex で probe を回し、run ごとの新しい fixture、results.json の欄、
#   prompt と command の本文を results.json に出さないこと、--skills none、起動の前の確認を確かめる。
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
  "ruby -e'p 1'" => "unknown",
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
}
shell.each do |cmd, want|
  got = P.classify_shell(cmd)
  check("classify_shell(#{cmd.inspect}) は #{want} (実際は #{got})", got == want)
end

claude = {
  ["Read", { "file_path" => "/p/lib/median.rb" }] => "read",
  ["Grep", { "pattern" => "x" }] => "read",
  ["Glob", { "pattern" => "**/*.rb" }] => "read",
  ["Skill", { "skill" => "personal-investigate" }] => "read",
  ["Edit", { "file_path" => "/p/lib/median.rb" }] => "file-write",
  ["Write", { "file_path" => "/p/x" }] => "file-write",
  ["NotebookEdit", {}] => "file-write",
  ["Bash", { "command" => "cat lib/median.rb" }] => "read",
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

base = {
  "id" => "a", "prompt" => "p", "skill" => "s", "kind" => "negative", "pair" => "g", "fixture" => "median",
  "reach" => ["lib/median.rb"], "forbid" => ["file-write"], "require" => [], "allowed_changes" => [],
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
argv = P.codex_argv({ model: "m-x" }, "/proj", [])
check("codex は workspace-write の sandbox と境界の flag で起動する",
      argv.first(12) == ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                         "--ignore-rules", "-s", "workspace-write", "-c", 'approval_policy="never"', "--disable"] && argv.last == "-")
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
# skill の置き場の有無を log に残し、FAKE_EVENTS の event を出し、FAKE_WRITE の file を書き換え、FAKE_SLEEP 秒待って
# FAKE_RC で終わる。
cat > "$fakebin/fake-body" <<'EOF'
if [ -n "${FAKE_PRISTINE:-}" ] && ! cmp -s lib/median.rb "$FAKE_PRISTINE"; then exit 3; fi
if [ -d "$1" ]; then echo "skills-dir: present" >> "$FAKE_LOG"; else echo "skills-dir: absent" >> "$FAKE_LOG"; fi
[ -z "${FAKE_EVENTS:-}" ] || cat "$FAKE_EVENTS"
[ -z "${FAKE_WRITE:-}" ] || printf 'changed\n' >> "$FAKE_WRITE"
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
cd "$proj" || exit 65
. "$(dirname "$0")/fake-body" .agents/skills
EOF
chmod +x "$fakebin/claude" "$fakebin/codex"

source_dir="$tmp/source"
mkdir -p "$source_dir/personal-investigate"
printf -- '---\nname: personal-investigate\ndescription: d\n---\n' > "$source_dir/personal-investigate/SKILL.md"
empty_home="$tmp/codex-home"
for s in personal-investigate personal-other; do
  mkdir -p "$empty_home/skills/$s"
  printf -- '---\nname: %s\ndescription: d\n---\n' "$s" > "$empty_home/skills/$s/SKILL.md"
done

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
  out=$(env FAKE_LOG="$log" FAKE_EVENTS="$events" FAKE_PRISTINE="$pristine" CODEX_HOME="$empty_home" \
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
[ "$(json_get "$res" 'd["runs"][0].keys.sort')" = '["calls","case","changed","completion","index","reached","skills_read"]' ] \
  || fail "run keys should follow the interface: $(json_get "$res" 'd["runs"][0].keys')"
[ "$(json_get "$res" 'd.values_at("schema_version", "tool", "variant", "skills")')" = '[1,"claude-code","candidate","source"]' ] \
  || fail "claude top-level fields: $(json_get "$res" 'd.keys')"
[ "$(json_get "$res" 'd["ids"].keys.sort')" = \
  '["cases_digest","classifier_version","effort","fixture_digests","host_version","init_model","max_turns","permission_mode","repeat","requested_model","runner_version","source_digest","timeout","tool_surface"]' ] \
  || fail "claude ids keys: $(json_get "$res" 'd["ids"].keys.sort')"
[ "$(json_get "$res" 'd["ids"].values_at("host_version", "init_model", "requested_model", "permission_mode", "max_turns", "repeat", "classifier_version")')" = \
  '["9.9.9","m-fake","default","acceptEdits",12,2,1]' ] || fail "claude ids values: $(json_get "$res" 'd["ids"]')"
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
set +e
out=$(env FAKE_LOG="$log" PATH="$fakebin:$PATH" ruby "$src" --tool claude-code --skills none --source "$source_dir" --out "$tmp/never.json" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "--skills none with --source must exit 2 (rc=$rc): $out"
case "$out" in *exclusive*) : ;; *) fail "--skills none with --source should say they are exclusive: $out" ;; esac

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
run_fake codex "$codex_events" --model m-x --only investigate-fix --out "$res"
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
grep -q -- '^exec --json .*--ignore-user-config --ignore-rules -s workspace-write ' "$log" \
  || fail "codex should be launched with workspace-write and the boundary flags: $(cat "$log")"
grep -q 'skills.config=\[{path=.*personal-investigate/SKILL.md' "$log" || fail "codex should disable the same-name user skill: $(cat "$log")"
if grep -q 'personal-other/SKILL.md' "$log"; then fail "codex should keep other user skills when skills are placed: $(cat "$log")"; fi

# --- codex: --skills none でも同名の user の skill は外し、project には置かない ---
run_fake codex "$codex_events" --model m-x --only investigate-fix --skills none --out "$res"
[ "$rc" -eq 0 ] || fail "codex --skills none should run (rc=$rc): $out"
grep -q '^skills-dir: absent$' "$log" || fail "codex --skills none must not place skills: $(cat "$log")"
grep -q 'skills.config=\[{path=.*personal-investigate/SKILL.md.*personal-other/SKILL.md' "$log" \
  || fail "codex --skills none should disable every user skill: $(cat "$log")"

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
run_fake claude-code "$quiet_events" --only nope --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "unknown --only id must exit 2 (rc=$rc): $out"
run_fake claude-code "$quiet_events" --skills some --out "$tmp/never.json"
[ "$rc" -eq 2 ] || fail "--skills other than none must exit 2 (rc=$rc): $out"

echo "probe-skill-behavior-test: ok"
