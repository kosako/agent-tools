#!/bin/sh
# 前の turn のある case (#769) の probe の self-test。CLI は起動しない (偽の claude / codex)。network にも実の home にも触れない。
# - session の記録の読み取りと後片付け (scripts/lib/skill_behavior_session.rb): 自分の id の通常の file と、空になった dir だけを消す。
# - 起動の argv: 1 turn 目と再開した turn、前の turn の無い case は今のまま。
# - 偽の CLI での run: turn ごとの記録と差分、2 turn 目を始める条件、session と Codex の実際の設定の記録、raw log、後片付け。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/scripts/lib/probe_skill_behavior.rb"
session_lib="$repo_root/scripts/lib/skill_behavior_session.rb"
turn_cases="$repo_root/scripts/lib/skill_behavior_turn_cases.json"
for f in "$src" "$session_lib" "$turn_cases"; do
  [ -f "$f" ] || fail "missing $f"
done
unset CLAUDE_CONFIG_DIR CLAUDE_CODE_DISABLE_AUTO_MEMORY 2>/dev/null || :

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- session の記録 ---------------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp/unit" <<'RUBY'
require "fileutils"
require "json"
load ARGV[0]
P = ProbeSkillBehavior
S = SkillBehaviorSession
C = SkillBehaviorCases
root = ARGV[1]
id = "0a1b2c3d-0000-4000-8000-0123456789ab"
other = "ffffffff-0000-4000-8000-0123456789ab"

check("UUID の形だけを id とみなす", S.id?(id) && [nil, 1, "", "x", id.upcase, "#{id}\n", "../#{id}", id[0..-2], "#{id}0", id.tr("-", "/")].none? { |x| S.id?(x) })
check("Claude Code の記録の置き場", S.claude_projects("CLAUDE_CONFIG_DIR" => "/c") == "/c/projects" &&
      S.claude_projects({}) == File.join(Dir.home, ".claude", "projects"))

# Claude Code
fresh = lambda do |name|
  d = File.join(root, name)
  FileUtils.mkdir_p(d)
  d
end
write = lambda do |path, text = "x\n"|
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, text)
  path
end
pr = fresh.call("c1")
mine = write.call(File.join(pr, "-a", "#{id}.jsonl"))
keep = [write.call(File.join(pr, "-b", "#{other}.jsonl")), write.call(File.join(pr, "-c", "notes.txt"))]
check("自分の記録を消し、空になった dir も消す", S.remove_claude(pr, id) == 0 && !File.exist?(mine) && !File.exist?(File.join(pr, "-a")) &&
      keep.all? { |f| File.file?(f) })
pr = fresh.call("c2")
write.call(File.join(pr, "-a", "#{id}.jsonl"))
sibling = write.call(File.join(pr, "-a", "#{other}.jsonl"))
check("ほかの記録のある dir は残す", S.remove_claude(pr, id) == 0 && File.file?(sibling) && Dir.children(File.join(pr, "-a")) == ["#{other}.jsonl"])
pr = fresh.call("c3")
write.call(File.join(pr, "-a", "#{id}.jsonl"))
write.call(File.join(pr, "-a", id, "tool-results", "x.txt"))
check("id の名前の dir は消さずに数える", S.remove_claude(pr, id) == 1 && File.file?(File.join(pr, "-a", id, "tool-results", "x.txt")) &&
      !File.exist?(File.join(pr, "-a", "#{id}.jsonl")))
pr = fresh.call("c3b")
write.call(File.join(pr, "-a", "#{id}.jsonl"))
deep = write.call(File.join(pr, "-a", "cache", "x-#{id}-y.bin"))
hidden = write.call(File.join(pr, "-b", ".hidden", "#{id}", "z"))
check("深い所に残った id の名前のものも数える", S.remove_claude(pr, id) == 2 && File.file?(deep) && File.file?(hidden))
pr = fresh.call("c4")
target = write.call(File.join(root, "outside.txt"))
FileUtils.mkdir_p(File.join(pr, "-a"))
File.symlink(target, File.join(pr, "-a", "#{id}.jsonl"))
check("記録が link なら、link も先も消さずに数える", S.remove_claude(pr, id) == 1 && File.symlink?(File.join(pr, "-a", "#{id}.jsonl")) && File.file?(target))
pr = fresh.call("c5")
FileUtils.mkdir_p(File.join(pr, "-a", "#{id}.jsonl"))
check("記録の名前の dir は消さずに数える", S.remove_claude(pr, id) == 1 && File.directory?(File.join(pr, "-a", "#{id}.jsonl")))
pr = fresh.call("c6")
out = fresh.call("c6-outside")
linked = write.call(File.join(out, "#{id}.jsonl"))
File.symlink(out, File.join(pr, "-a"))
check("projects の下の link の dir は辿らない", S.remove_claude(pr, id) == 0 && File.file?(linked))
check("projects が無ければ 0", S.remove_claude(File.join(root, "none"), id) == 0)
check("id の形でなければ何もしない", S.remove_claude(pr, "*").nil? && S.remove_claude(pr, nil).nil? && File.file?(linked))

# Codex
proj = fresh.call("proj")
measured = { "approval_policy" => "never", "cwd" => proj, "model" => "m",
             "sandbox_policy" => { "type" => "workspace-write", "network_access" => false, "exclude_tmpdir_env_var" => true, "exclude_slash_tmp" => true } }
check("実測の turn_context は、決まった値になる", S.context_text(measured, proj) == C::CODEX_TURN_CONTEXT)
change = ->(h) { S.context_text(measured.merge(h), proj) }
{
  "承認が違う" => [{ "approval_policy" => "on-request" }, C::CODEX_TURN_CONTEXT.sub("never", "on-request")],
  "承認が無い" => [{ "approval_policy" => nil }, C::CODEX_TURN_CONTEXT.sub("never", "?")],
  "作業 dir が違う" => [{ "cwd" => root }, C::CODEX_TURN_CONTEXT.sub("cwd=project", "cwd=other")],
  "作業 dir が相対" => [{ "cwd" => "proj" }, C::CODEX_TURN_CONTEXT.sub("cwd=project", "cwd=other")],
  "作業 dir が無い dir" => [{ "cwd" => "/nope/x" }, C::CODEX_TURN_CONTEXT.sub("cwd=project", "cwd=other")],
  "作業 dir が文字列でない" => [{ "cwd" => 1 }, C::CODEX_TURN_CONTEXT.sub("cwd=project", "cwd=other")],
  "sandbox が read-only" => [{ "sandbox_policy" => { "type" => "read-only" } }, 'approval=never cwd=project sandbox={"type":"read-only"}'],
  "sandbox が object でない" => [{ "sandbox_policy" => "workspace-write" }, "approval=never cwd=project sandbox=?"],
  "sandbox に path" => [{ "sandbox_policy" => { "type" => "workspace-write", "writable_roots" => ["/Users/x/secret"] } },
                        'approval=never cwd=project sandbox={"type":"workspace-write","writable_roots":"?"}'],
  "sandbox の値が path" => [{ "sandbox_policy" => { "type" => "/Users/x" } }, 'approval=never cwd=project sandbox={"type":"?"}'],
  "sandbox の key が path" => [{ "sandbox_policy" => { "/Users/x" => true } }, 'approval=never cwd=project sandbox={"?":true}'],
}.each do |label, (h, want)|
  got = change.call(h)
  check("#{label}: #{got}", got == want && !got.include?("/Users"))
end
Dir.chdir(File.dirname(proj)) do
  check("作業 dir が、今いる dir からの相対でも other", S.same_dir?(File.basename(proj), proj) == false && S.same_dir?(proj, proj))
end
home = fresh.call("h1")
meta = ->(cwd, h = {}) { JSON.generate("type" => "session_meta", "payload" => { "id" => "x", "cwd" => cwd }.merge(h)) + "\n" }
day = File.join(home, "sessions", "2026", "11", "25")
line = ->(payload) { JSON.generate("type" => "turn_context", "payload" => payload) }
roll = write.call(File.join(day, "rollout-1-#{id}.jsonl"),
                  meta.call(proj) + [line.call(measured), "not json", "\xff\xfe", "[1]", line.call("x"), "{\"type\":\"event\",\"payload\":{}}",
                   line.call(measured.merge("sandbox_policy" => { "type" => "read-only" }))].join("\n") + "\n")
check("rollout の turn_context を並んだ順に読む",
      S.codex_contexts(home, id, proj) == [C::CODEX_TURN_CONTEXT, 'approval=never cwd=project sandbox={"type":"read-only"}'])
h2 = fresh.call("h2")
write.call(File.join(h2, "sessions", "rollout-#{id}.jsonl"), meta.call(proj))
check("turn_context の無い rollout は空", S.codex_contexts(h2, id, proj) == [])
check("id の形でなければ読まない", ["*", nil, "rollout", ""].all? { |x| S.codex_contexts(h2, x, proj).nil? })
check("名前に session の id が無い rollout は読まない", S.codex_contexts(h2, other, proj).nil?)
check("作業 dir が違う rollout は、自分の記録でない", S.codex_contexts(h2, id, root).nil? && S.remove_codex(h2, root, S.codex_entries(h2)) == 0 &&
      File.file?(File.join(h2, "sessions", "rollout-#{id}.jsonl")))
keep = write.call(File.join(day, "rollout-1-#{other}.jsonl"), meta.call(root))
before = S.codex_entries(home) - [roll]
check("ほかの run の rollout が在っても、自分の 1 つを読む", S.codex_contexts(home, id, proj).length == 2)
mine2 = write.call(File.join(home, "sessions", "2026", "11", "24", "rollout-2-#{id}.jsonl"), meta.call(proj) + line.call(measured))
check("自分の rollout が 2 つなら読まない", S.codex_contexts(home, id, proj).nil?)
check("自分の rollout を全部消し、空になった日付の dir も消す", S.remove_codex(home, proj, before) == 0 && !File.exist?(roll) && !File.exist?(mine2) &&
      File.file?(keep) && Dir.children(File.join(home, "sessions", "2026", "11")) == ["25"])
alone = fresh.call("h1b")
write.call(File.join(alone, "sessions", "2026", "11", "25", "rollout-1-#{id}.jsonl"), meta.call(proj))
check("自分の rollout が最後なら、sessions の下を空にし、sessions は残す", S.remove_codex(alone, proj, []) == 0 && Dir.children(File.join(alone, "sessions")).empty?)
# 自分の記録とみなさない rollout (先頭の行が session_meta でない・作業 dir が違う・名前や種類が違う) は、消さずに数える
first_lines = {
  "空" => "", "JSON でない" => "not json\n", "object でない" => "[1]\n", "UTF-8 でない" => "\xff\xfe\n", "種類が違う" => JSON.generate("type" => "event", "payload" => { "cwd" => proj }),
  "payload が無い" => "{\"type\":\"session_meta\"}\n", "payload が文字列" => JSON.generate("type" => "session_meta", "payload" => proj),
  "作業 dir が無い" => meta.call(nil), "作業 dir が違う" => meta.call(root), "作業 dir が相対" => meta.call("proj"), "2 行目に session_meta" => "{}\n" + meta.call(proj),
}
first_lines.each_with_index do |(label, text), i|
  h = fresh.call("hx#{i}")
  f = write.call(File.join(h, "sessions", "rollout-#{id}.jsonl"), text)
  check("先頭の行が#{label}の rollout は消さずに数える", S.remove_codex(h, proj, []) == 1 && File.file?(f) && S.codex_contexts(h, id, proj).nil?)
  check("run の前からあるものは数えない (#{label})", S.remove_codex(h, proj, S.codex_entries(h)) == 0)
end
["#{id}.jsonl", "rollout-#{id}.txt", "rollout-#{id}.jsonl.bak", "x-rollout-#{id}.jsonl"].each_with_index do |name, i|
  h = fresh.call("hn#{i}")
  f = write.call(File.join(h, "sessions", name), meta.call(proj))
  check("rollout でない名前 (#{name}) は消さずに数える", S.remove_codex(h, proj, []) == 1 && File.file?(f))
end
h3 = fresh.call("h3")
real = write.call(File.join(root, "h3-real.jsonl"), meta.call(proj))
FileUtils.mkdir_p(File.join(h3, "sessions"))
File.symlink(real, File.join(h3, "sessions", "rollout-#{id}.jsonl"))
check("rollout が link なら読まず、link も先も消さずに数える", S.codex_contexts(h3, id, proj).nil? && S.remove_codex(h3, proj, []) == 1 && File.file?(real) &&
      File.symlink?(File.join(h3, "sessions", "rollout-#{id}.jsonl")))
h5 = fresh.call("h5")
out = fresh.call("h5-outside")
linked = write.call(File.join(out, "rollout-#{id}.jsonl"), meta.call(proj))
File.symlink(out, File.join(h5, "sessions"))
check("sessions が link なら辿らない", S.remove_codex(h5, proj, []) == 0 && S.codex_contexts(h5, id, proj).nil? && File.file?(linked))
check("sessions が無ければ 0", S.remove_codex(fresh.call("h6"), proj, []) == 0)
# 読めない dir があれば、0 と数えずに nil
shut = lambda do |dir, &blk|
  File.chmod(0o000, dir)
  blk.call
ensure
  File.chmod(0o700, dir)
end
h = fresh.call("h8")
write.call(File.join(h, "sessions", "2026", "x"))
check("sessions の下に読めない dir があれば nil", shut.call(File.join(h, "sessions", "2026")) { S.remove_codex(h, proj, []) }.nil? &&
      shut.call(File.join(h, "sessions")) { S.remove_codex(h, proj, []) }.nil?)
pr = fresh.call("c7")
write.call(File.join(pr, "-a", "sub", "x"))
check("projects の下に読めない dir があれば nil", shut.call(File.join(pr, "-a", "sub")) { S.remove_claude(pr, id) }.nil? && shut.call(pr) { S.remove_claude(pr, id) }.nil?)
check("見ている間に消えた dir は、空とみなす", S.walk(File.join(root, "gone")) == [])
check("walk は link の先を辿らない", begin
  d = fresh.call("w1")
  write.call(File.join(d, "a", "x"))
  File.symlink(root, File.join(d, "l"))
  S.walk(d).map { |f| f.delete_prefix("#{d}/") } == ["a", "a/x", "l"]
end)
check("隠し file も数える", begin
  h = fresh.call("h7")
  write.call(File.join(h, "sessions", "2026", ".lock"))
  S.remove_codex(h, proj, []) == 1
end)

# 起動の argv
plain = P.claude_argv({ max_turns: 12 }, "<p>")
check("前の turn の無い case の claude の argv は、今のまま",
      plain == ["claude", "-p", "--setting-sources", "project", "--strict-mcp-config", "--tools", P::CLAUDE_TOOLS.join(","), "--permission-mode", "acceptEdits",
                "--output-format", "stream-json", "--verbose", "--max-turns", "12", "--no-session-persistence", "<p>"])
first = P.claude_argv({ max_turns: 12, model: "m" }, "<p>", { id: id, resume: false })
again = P.claude_argv({ max_turns: 12, model: "m" }, "<p>", { id: id, resume: true })
swap = ->(*w) { (plain[0...-1] - ["--no-session-persistence"]) + w + ["--model", "m", "<p>"] }
check("claude の 1 turn 目は id を渡し、記録を残す", first == swap.call("--session-id", id))
check("claude の再開した turn は、同じ条件で id を再開する", again == swap.call("--resume", id))
disable = ProbeSkillRouting::CODEX_DISABLE_FEATURES.flat_map { |f| ["--disable", f] }
config = P::CODEX_SANDBOX_CONFIG.flat_map { |k, v| ["-c", "#{k}=#{v}"] }
plain = P.codex_argv({ model: "m" }, "/proj")
check("前の turn の無い case の codex の argv は、今のまま",
      plain == ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-s", "workspace-write",
                "-c", 'approval_policy="never"', *disable, *config, "-C", "/proj", "-m", "m", "-"])
check("codex の 1 turn 目は、--ephemeral だけを外す", P.codex_argv({ model: "m" }, "/proj", { id: nil, resume: false }) == plain - ["--ephemeral"])
check("codex の再開した turn は、sandbox・承認・除外・禁じる feature を渡し直す",
      P.codex_argv({ model: "m" }, "/proj", { id: id, resume: true }) ==
      ["codex", "exec", "resume", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-c", 'sandbox_mode="workspace-write"',
       "-c", 'approval_policy="never"', *disable, *config, "-m", "m", id, "-"])

# event の session の id
sys = ->(h) { JSON.generate({ "type" => "system", "subtype" => "init" }.merge(h)) }
check("claude の init の session の id", P.parse_claude([sys.call("session_id" => "a"), sys.call("session_id" => "a")].join("\n"), [])[:session_ids] == ["a"] &&
      P.parse_claude([sys.call("session_id" => "a"), sys.call("session_id" => "b")].join("\n"), [])[:session_ids] == %w[a b] &&
      P.parse_claude("", [])[:session_ids] == [])
check("init でない event の session の id は数えない", P.parse_claude(JSON.generate("type" => "result", "session_id" => "z"), [])[:session_ids] == [])
started = ->(v) { JSON.generate("type" => "thread.started", "thread_id" => v) }
check("codex の thread の id", P.parse_codex([started.call("a"), started.call("a")].join("\n"), [])[:session_ids] == ["a"] &&
      P.parse_codex([started.call("a"), started.call("b")].join("\n"), [])[:session_ids] == %w[a b] && P.parse_codex("", [])[:session_ids] == [])
check("再開の状態", { [[id], id] => "same", [[other], id] => "differs", [[id, other], id] => "differs", [[], id] => "unknown", [[nil], id] => "unknown",
                      [[nil, id], id] => "differs" }.all? { |(ids, want), state| P.resumed_state(ids, want) == state })
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- 偽の CLI ---------------------------------------------------------------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
log="$tmp/calls.log"
thread=11112222-3333-4444-8555-666677778888
# fake-turn <turn>: turn ごとの書き込み・待ち・終わり方。FAKE_WRITE_1 / _2 は書き換える file、FAKE_SLEEP_1 / _2、FAKE_RC_1 / _2。
cat > "$fakebin/fake-turn" <<'EOF'
eval "w=\${FAKE_WRITE_$1:-} s=\${FAKE_SLEEP_$1:-} c=\${FAKE_RC_$1:-0} h=\${FAKE_HOOK_$1:-}"
[ -z "$h" ] || sh -c "$h"
[ -z "$w" ] || printf 'changed %s\n' "$1" >> "$w"
[ -z "$s" ] || sleep "$s"
exit "$c"
EOF
cat > "$fakebin/claude" <<'EOF'
#!/bin/sh
printf 'claude memory=%s %s\n' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-unset}" "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--permission-mode' '--tools' '--session-id' '--resume' | grep -v -x -e "${FAKE_HELP_DROP:-none}"
  exit 0
fi
turn=0
id=
prev=
for a in "$@"; do
  case $prev in
    --session-id) turn=1; id=$a ;;
    --resume) turn=2; id=$a ;;
  esac
  prev=$a
done
[ "$turn" -gt 0 ] || { echo "fake claude: no session" >&2; exit 64; }
store="$CLAUDE_CONFIG_DIR/projects/-fake-proj"
mkdir -p "$store"
[ "$turn" -eq 1 ] || [ -f "$store/$id.jsonl" ] || { echo "fake claude: no such session" >&2; exit 65; }
printf 'turn %s\n' "$turn" >> "$store/$id.jsonl"
[ -z "${FAKE_LEFT:-}" ] || mkdir -p "$store/$id/tool-results"
eval "shown=\${FAKE_ID_$turn:-\$id} mode=\${FAKE_MODE_$turn:-acceptEdits} events=\${FAKE_EVENTS_$turn:-}"
[ "$shown" = none ] || printf '{"type":"system","subtype":"init","model":"m-fake","claude_code_version":"9.9.9","tools":["Read","Glob","Grep","Edit","Write","NotebookEdit","Bash","Skill"],"permissionMode":"%s","session_id":"%s"}\n' "$mode" "$shown"
[ -z "$events" ] || cat "$events"
printf '%s\n' '{"type":"result","subtype":"success"}'
. "$(dirname "$0")/fake-turn" "$turn"
EOF
cat > "$fakebin/codex" <<'EOF'
#!/bin/sh
printf 'codex %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  --version) echo "codex-cli 9.9.9"; exit 0 ;;
  "exec --help") printf '%s\n' --ignore-user-config --ignore-rules --disable; exit 0 ;;
  "exec resume --help") printf '%s\n' --ignore-user-config --ignore-rules --disable | grep -v -x -e "${FAKE_HELP_DROP:-none}"; exit "${FAKE_RC_RESUME_HELP:-0}" ;;
  "features list") printf '%s\n' 'apps  stable  true' 'computer_use  beta  false' 'browser_use  beta  false'; exit 0 ;;
esac
prompt=$(cat)
turn=1
sandbox='{"type":"workspace-write","network_access":false,"exclude_tmpdir_env_var":true,"exclude_slash_tmp":true}'
if [ "$1 $2" = "exec resume" ]; then
  turn=2
  # 実物と同じく、渡し直さなければ read-only になる
  case "$*" in
    *'sandbox_mode="workspace-write"'*'sandbox_workspace_write.exclude_slash_tmp=true'*'sandbox_workspace_write.exclude_tmpdir_env_var=true'*) : ;;
    *) sandbox='{"type":"read-only"}' ;;
  esac
fi
eval "shown=\${FAKE_ID_$turn:-\$FAKE_THREAD} box=\${FAKE_SANDBOX_$turn:-\$sandbox} events=\${FAKE_EVENTS_$turn:-}"
store="$CODEX_HOME/sessions/2026/11/25"
mkdir -p "$store"
roll="$store/rollout-x-$FAKE_THREAD.jsonl"
[ -f "$roll" ] || printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$FAKE_THREAD" "$(pwd -P)" > "$roll"
[ "$box" = none ] || printf '{"type":"turn_context","payload":{"approval_policy":"never","cwd":"%s","sandbox_policy":%s}}\n' "$(pwd -P)" "$box" >> "$roll"
[ -z "${FAKE_LEFT:-}" ] || : > "$store/$FAKE_THREAD.lock"
for v in $shown; do
  [ "$v" = none ] || printf '{"type":"thread.started","thread_id":"%s"}\n' "$v"
done
printf 'codex-prompt %s: %s\n' "$turn" "$prompt" >> "$FAKE_LOG"
[ -z "$events" ] || cat "$events"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
. "$(dirname "$0")/fake-turn" "$turn"
EOF
chmod +x "$fakebin/claude" "$fakebin/codex"

source_dir="$tmp/source"
for s in personal-investigate personal-production-rail; do
  mkdir -p "$source_dir/$s"
  printf -- '---\nname: %s\ndescription: d\n---\n' "$s" > "$source_dir/$s/SKILL.md"
done
eval_home="$tmp/codex-eval-home"
mkdir -p "$eval_home"
: > "$eval_home/auth.json"
usual_home="$tmp/usual-codex-home"
claude_home="$tmp/claude-home"
mkdir -p "$usual_home" "$claude_home/projects/-fake-proj"
# ほかの session の記録。どの run の後も残る
printf 'keep\n' > "$claude_home/projects/-fake-proj/99999999-0000-4000-8000-000000000000.jsonl"
mkdir -p "$eval_home/sessions/2026/11/25"
printf 'keep\n' > "$eval_home/sessions/2026/11/25/rollout-x-99999999-0000-4000-8000-000000000000.jsonl"

# 検査 (fix_check) には sandbox-exec が要るので、外した表で回す。fixture は隣に置く。
work="$tmp/cases"
mkdir -p "$work"
cp -R "$repo_root/scripts/lib/skill_behavior_fixtures" "$work/skill_behavior_fixtures"
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  d["cases"].each { |c| c.delete("fix_check") }
  File.write(File.join(ARGV[1], "all.json"), JSON.generate(d))
  d["cases"].each { |c| File.write(File.join(ARGV[1], "#{c["id"]}.json"), JSON.generate(d.merge("cases" => [c]))) }' "$turn_cases" "$work"

reading="$tmp/reading.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/proj/lib/median.rb"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"src"}]}}' > "$reading"
editing="$tmp/editing.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/x/proj/lib/median.rb"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"done"}]}}' > "$editing"
reading_codex="$tmp/reading-codex.jsonl"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc '"'"'cat lib/median.rb'"'"'","exit_code":0,"status":"completed"}}' > "$reading_codex"
editing_codex="$tmp/editing-codex.jsonl"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/x/proj/lib/median.rb","kind":"update"}],"status":"completed"}}' > "$editing_codex"

# run_turns <tool> <case> <args...>: FAKE_* は呼ぶ側が export する
res="$tmp/res.json"
run_turns() {
  tool=$1
  case_id=$2
  shift 2
  set -- --tool "$tool" --cases "$work/$case_id.json" --source "$source_dir" --model m-x --out "$res" "$@"
  [ "$tool" = claude-code ] || set -- "$@" --codex-home "$eval_home"
  : > "$log"
  rm -rf "$res" "$res.raw"
  set +e
  out=$(env FAKE_LOG="$log" FAKE_THREAD="$thread" CODEX_HOME="$usual_home" CLAUDE_CONFIG_DIR="$claude_home" PATH="$fakebin:$PATH" ruby "$src" "$@" 2>&1)
  rc=$?
  set -e
}
json_get() { ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); r = d["runs"][0]; puts eval(ARGV[1]).to_json' "$res" "$1"; }
expect() {
  got=$(json_get "$2")
  [ "$got" = "$3" ] || fail "$1: $2 は $3 (実際は $got): $out"
}
launches() { grep -c -e 'claude memory=1 -p' -e 'codex exec --json' -e 'codex exec resume --json' "$log" || :; }
# 自分の記録が残らず、ほかの記録は残る
clean() {
  [ "$(find "$claude_home/projects" "$eval_home/sessions" -type f | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "$1: only the other sessions should remain: $(find "$claude_home/projects" "$eval_home/sessions")"
}
judge() {
  set +e
  judged=$(sh "$repo_root/scripts/check-skill-behavior.sh" --cases "$work/$1.json" --results "$res" 2>&1)
  judged_rc=$?
  set -e
}

# --- 2 turn とも終わる run (負例)。judge がそのまま受ける ---
for tool in claude-code codex; do
  if [ "$tool" = codex ]; then FAKE_EVENTS_1=$reading_codex; else FAKE_EVENTS_1=$reading; fi
  export FAKE_EVENTS_1
  run_turns "$tool" investigate-then-question
  [ "$rc" -eq 0 ] || fail "$tool: two turns should exit 0 (rc=$rc): $out"
  [ "$(launches)" -eq 2 ] || fail "$tool: each turn should be one process: $(cat "$log")"
  expect "$tool" 'r.keys' '["case","index","completion","calls","reached","changed","skills_read","skills_unresolved","before"]'
  expect "$tool" 'r["before"].map(&:keys)' '[["completion","calls","reached","changed","skills_read","skills_unresolved"]]'
  expect "$tool" '[r["before"][0]["completion"], r["before"][0]["reached"], r["before"][0]["calls"].map { |c| c["class"] }, r["before"][0]["changed"]]' '["exited",true,["read"],[]]'
  expect "$tool" '[r["completion"], r["reached"], r["calls"], r["changed"]]' '["exited",false,[],[]]'
  expect "$tool" 'd["ids"]["resume_session"]' '"same"'
  [ -f "$res.raw/investigate-then-question-1.turn1.jsonl" ] && [ -f "$res.raw/investigate-then-question-1.jsonl" ] || fail "$tool: each turn should have a raw log"
  if grep -q -F "$thread" "$res"; then fail "$tool: results must not contain the session id"; fi
  case "$out" in *'warning: session record'*) fail "$tool: no record should be left: $out" ;; esac
  clean "$tool"
  judge investigate-then-question
  [ "$judged_rc" -eq 0 ] || fail "$tool: the judge should accept the probe's own results (rc=$judged_rc): $judged"
  case "$judged" in *'turn 1 clean=1 violation=0 unevaluable=0; turn 2 after a clean turn 1: violation=0 passed=1'*) : ;; *) fail "$tool: turn counts: $judged" ;; esac
done
expect codex 'd["ids"].key?("auto_memory")' 'false'
[ "$(json_get 'd["ids"]["turn_context"]')" = "$(ruby -rjson -I"$repo_root/scripts/lib" -rskill_behavior_cases -e 'puts SkillBehaviorCases::CODEX_TURN_CONTEXT.to_json')" ] \
  || fail "codex should record the effective settings of the turns: $(json_get 'd["ids"]["turn_context"]')"
grep -q -- "^codex exec resume --json .* $thread -\$" "$log" || fail "codex should resume the thread: $(cat "$log")"
if grep -q -- '--ephemeral' "$log"; then fail "codex turns must keep the session: $(cat "$log")"; fi
run_turns claude-code investigate-then-question
expect claude '[d["ids"].key?("turn_context"), d["ids"]["auto_memory"], d["ids"]["permission_mode"]]' '[false,{"requested":"off","init":"not-listed"},"acceptEdits"]'
[ "$(sed -n 's/.*--session-id \([^ ]*\) .*/\1/p' "$log")" = "$(sed -n 's/.*--resume \([^ ]*\) .*/\1/p' "$log")" ] || fail "claude should resume its own session: $(cat "$log")"
[ "$(grep -c 'claude memory=1 ' "$log")" -eq 3 ] || fail "every claude call should turn the auto memory off: $(cat "$log")"
first_id=$(sed -n 's/.*--session-id \([^ ]*\) .*/\1/p' "$log")
run_turns claude-code investigate-then-question
[ "$(sed -n 's/.*--session-id \([^ ]*\) .*/\1/p' "$log")" != "$first_id" ] || fail "each run should use its own session"
run_turns claude-code investigate-then-question --repeat 2
[ "$(sed -n 's/.*--session-id \([^ ]*\) .*/\1/p' "$log" | sort -u | wc -l | tr -d ' ')" -eq 2 ] || fail "each repeat should use its own session: $(cat "$log")"
clean "repeat"

# --- turn ごとの依頼の文。1 turn 目は前の turn のもの、2 turn 目は case のもの ---
first_prompt=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["cases"][0]["before"][0]["prompt"]' "$work/investigate-then-question.json")
last_prompt=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["cases"][0]["prompt"]' "$work/investigate-then-question.json")
[ -n "$first_prompt" ] && [ -n "$last_prompt" ] && [ "$first_prompt" != "$last_prompt" ] || fail "the two prompts should differ"
run_turns claude-code investigate-then-question
grep -q -- "--session-id [^ ]* --model m-x $first_prompt\$" "$log" || fail "claude: turn 1 should get the prompt of the turn before: $(cat "$log")"
grep -q -- "--resume [^ ]* --model m-x $last_prompt\$" "$log" || fail "claude: turn 2 should get the prompt of the case: $(cat "$log")"
run_turns codex investigate-then-question
[ "$(grep '^codex-prompt ' "$log")" = "codex-prompt 1: $first_prompt
codex-prompt 2: $last_prompt" ] || fail "codex: each turn should get its own prompt: $(cat "$log")"

# --- turn ごとの差分。2 turn 目の差分は、1 turn 目の後からの差 ---
for tool in claude-code codex; do
  if [ "$tool" = codex ]; then FAKE_EVENTS_1=$reading_codex; else FAKE_EVENTS_1=$reading; fi
  FAKE_WRITE_1=lib/median.rb
  FAKE_WRITE_2=test/median_test.rb
  export FAKE_EVENTS_1 FAKE_WRITE_1 FAKE_WRITE_2
  run_turns "$tool" investigate-then-question
  unset FAKE_WRITE_1 FAKE_WRITE_2
  expect "$tool" '[r["before"][0]["changed"], r["changed"]]' '[["lib/median.rb"],["test/median_test.rb"]]'
  judge investigate-then-question
  [ "$judged_rc" -eq 1 ] || fail "$tool: writes in a turn should be violations (rc=$judged_rc): $judged"
  case "$judged" in *'turn 1: changed outside allowed_changes: lib/median.rb; turn 2: changed outside allowed_changes: test/median_test.rb'*) : ;;
    *) fail "$tool: each turn should be judged on its own: $judged" ;; esac
  # 正例。2 turn 目で直す
  if [ "$tool" = codex ]; then FAKE_EVENTS_2=$editing_codex; else FAKE_EVENTS_2=$editing; fi
  FAKE_WRITE_2=lib/median.rb
  export FAKE_EVENTS_2 FAKE_WRITE_2
  run_turns "$tool" investigate-then-fix
  unset FAKE_EVENTS_2 FAKE_WRITE_2
  expect "$tool" '[r["before"][0]["changed"], r["changed"], r["calls"].map { |c| c["class"] }]' '[[],["lib/median.rb"],["file-write"]]'
  judge investigate-then-fix
  [ "$judged_rc" -eq 0 ] || fail "$tool: the fix should be achieved (rc=$judged_rc): $judged"
done

# --- 2 turn 目を始めない条件。記録は not-started で、中身は空。CLI は 1 回だけ起動し、記録は消える ---
not_started() {
  [ "$rc" -eq 0 ] || fail "$1: the probe should finish (rc=$rc): $out"
  [ "$(launches)" -eq 1 ] || fail "$1: only the first turn should run: $(cat "$log")"
  expect "$1" '[r["completion"], r["calls"], r["reached"], r["changed"], r["skills_read"], r["skills_unresolved"], r.key?("fix_check")]' '["not-started",[],false,[],[],false,false]'
  expect "$1" 'd["ids"]["resume_session"]' '"unknown"'
  [ -f "$res.raw/investigate-then-question-1.turn1.jsonl" ] && [ ! -e "$res.raw/investigate-then-question-1.jsonl" ] || fail "$1: only turn 1 should have a raw log"
  clean "$1"
  judge investigate-then-question
  [ "$judged_rc" -eq 2 ] || fail "$1: the judge should call it unevaluable (rc=$judged_rc): $judged"
}
for tool in claude-code codex; do
  FAKE_RC_1=1; export FAKE_RC_1
  run_turns "$tool" investigate-then-question
  unset FAKE_RC_1
  not_started "$tool failed"
  expect "$tool failed" 'r["before"][0]["completion"]' '"failed"'
  FAKE_SLEEP_1=20; export FAKE_SLEEP_1
  run_turns "$tool" investigate-then-question --timeout 1
  unset FAKE_SLEEP_1
  not_started "$tool timeout"
  expect "$tool timeout" 'r["before"][0]["completion"]' '"timeout"'
done
for shown in none aaaaaaaa-0000-4000-8000-000000000000; do
  FAKE_ID_1=$shown; export FAKE_ID_1
  run_turns claude-code investigate-then-question
  unset FAKE_ID_1
  not_started "claude id $shown"
done
# codex の id が取れない・2 つある・形が違うときも、作業 dir で自分の記録を見つけて消す
for shown in none not-an-id "$thread aaaaaaaa-0000-4000-8000-000000000000" '../../x'; do
  FAKE_ID_1=$shown; export FAKE_ID_1
  run_turns codex investigate-then-question
  unset FAKE_ID_1
  not_started "codex id $shown"
  expect "codex id $shown" '[r["before"][0]["completion"], d["ids"]["turn_context"]]' '["exited","unknown"]'
  case "$out" in *'warning: session record'*) fail "codex id $shown: no record should be left: $out" ;; esac
done

# --- 割り込み。1 turn 目か 2 turn 目の途中で止められても、自分の記録を消す (Codex は id がまだ分からない) ---
for sig in INT TERM; do
  for tool in claude-code codex; do
    for turn in 1 2; do
      : > "$log"
      rm -rf "$res" "$res.raw"
      set -- --tool "$tool" --cases "$work/investigate-then-question.json" --source "$source_dir" --model m-x --out "$res"
      [ "$tool" = claude-code ] || set -- "$@" --codex-home "$eval_home"
      if [ "$tool" = codex ]; then watch="$eval_home/sessions"; else watch="$claude_home/projects"; fi
      env FAKE_LOG="$log" FAKE_THREAD="$thread" CODEX_HOME="$usual_home" CLAUDE_CONFIG_DIR="$claude_home" PATH="$fakebin:$PATH" \
        WATCH="$watch" "FAKE_SLEEP_$turn=60" ruby -e '
          sig, log, turn, *cmd = ARGV
          pid = Process.spawn(*cmd, out: "/dev/null", err: "/dev/null")
          limit = Time.now + 30
          # 起動の数と、記録ができたことを見てから送る
          sleep 0.1 until File.read(log).lines.grep(/claude memory=1 -p|codex exec --json|codex exec resume --json/).length >= turn.to_i &&
                          !Dir.glob(File.join(ENV["WATCH"], "**", "*.jsonl")).reject { |f| f.include?("99999999") }.empty? || Time.now > limit
          sleep 0.5
          Process.kill(sig, pid)
          Process.wait(pid)
          exit($?.success? ? 1 : 0)
        ' "$sig" "$log" "$turn" ruby "$src" "$@" > /dev/null 2>&1 || fail "$tool: $sig in turn $turn should stop the probe"
      [ ! -e "$res" ] || fail "$tool: an interrupted probe must not write results"
      clean "$tool $sig in turn $turn"
    done
  done
done

# --- 2 turn 目の終わり方 ---
for tool in claude-code codex; do
  FAKE_RC_2=1; export FAKE_RC_2
  run_turns "$tool" investigate-then-question
  unset FAKE_RC_2
  expect "$tool turn 2 failed" '[r["before"][0]["completion"], r["completion"], d["ids"]["resume_session"]]' '["exited","failed","same"]'
  clean "$tool turn 2 failed"
  FAKE_SLEEP_2=20; export FAKE_SLEEP_2
  run_turns "$tool" investigate-then-question --timeout 1
  unset FAKE_SLEEP_2
  expect "$tool turn 2 timeout" 'r["completion"]' '"timeout"'
  clean "$tool turn 2 timeout"
done

# --- 再開した session が違う・分からない。judge は条件の食い違いにする ---
for pair in "none|unknown" "aaaaaaaa-0000-4000-8000-000000000000|differs"; do
  for tool in claude-code codex; do
    FAKE_ID_2=${pair%%|*}; export FAKE_ID_2
    run_turns "$tool" investigate-then-question
    unset FAKE_ID_2
    expect "$tool resumed ${pair%%|*}" 'd["ids"]["resume_session"]' "\"${pair#*|}\""
    clean "$tool resumed ${pair%%|*}"
    judge investigate-then-question
    case "$judged" in *'condition: the last turn did not resume the same session'*) : ;; *) fail "$tool: a different session should be a condition issue: $judged" ;; esac
  done
done

# --- Codex の実際の設定が違う・記録に無い。turn ごとに読む (2 turn 目だけの違いも見つける) ---
for pair in 'FAKE_SANDBOX_2={"type":"read-only"}' 'FAKE_SANDBOX_2={"type":"workspace-write","writable_roots":["/Users/x/CANARY"]}' 'FAKE_SANDBOX_2=none' 'FAKE_SANDBOX_1={"type":"read-only"}' 'FAKE_SANDBOX_1=none'; do
  export "${pair?}"
  run_turns codex investigate-then-question
  unset "${pair%%=*}"
  case "$(json_get 'd["ids"]["turn_context"]')" in '"mixed:'*) : ;; *) fail "$pair: the settings should differ between turns: $(json_get 'd["ids"]["turn_context"]')" ;; esac
  if grep -q -e CANARY -e /Users "$res"; then fail "$pair: results must not contain a path: $(cat "$res")"; fi
  clean "$pair"
  judge investigate-then-question
  case "$judged" in *'condition: the effective settings of the turns differ'*) : ;; *) fail "$pair: it should be a condition issue: $judged" ;; esac
done
FAKE_SANDBOX_1=none; FAKE_SANDBOX_2=none; export FAKE_SANDBOX_1 FAKE_SANDBOX_2
run_turns codex investigate-then-question
unset FAKE_SANDBOX_1 FAKE_SANDBOX_2
expect "no turn_context" 'd["ids"]["turn_context"]' '"unknown"'

# --- Claude Code の 2 turn 目の permission の mode が違えば、今の欄に mixed で出る ---
FAKE_MODE_2=default; export FAKE_MODE_2
run_turns claude-code investigate-then-question
unset FAKE_MODE_2
expect "claude mode" 'd["ids"]["permission_mode"]' '"mixed:acceptEdits,default"'

# --- 消し残し (id の名前のほかのもの) は、消さずに数を出す ---
for tool in claude-code codex; do
  FAKE_LEFT=1; export FAKE_LEFT
  run_turns "$tool" investigate-then-question
  unset FAKE_LEFT
  case "$out" in *'warning: session record(s) left in the home: 1 (investigate-then-question [1/1])'*) : ;; *) fail "$tool: a left record should be reported: $out" ;; esac
done
[ -n "$(find "$claude_home/projects" -name tool-results)" ] || fail "claude: the left directory must stay"
[ -f "$eval_home/sessions/2026/11/25/$thread.lock" ] || fail "codex: the left file must stay"
find "$claude_home/projects" -name tool-results -exec rmdir {} +
find "$claude_home/projects/-fake-proj" -mindepth 1 -type d -empty -exec rmdir {} +
rm -f "$eval_home/sessions/2026/11/25/$thread.lock"
clean "after the left records"

# --- 数えられないとき (読めない dir) は unknown と出す ---
for tool in claude-code codex; do
  if [ "$tool" = codex ]; then shut="$eval_home/sessions/2026"; else shut="$claude_home/projects/-fake-proj"; fi
  FAKE_HOOK_2="chmod 000 '$shut'"; export FAKE_HOOK_2
  run_turns "$tool" investigate-then-question
  unset FAKE_HOOK_2
  chmod 700 "$shut"
  [ "$rc" -eq 0 ] || fail "$tool: an unreadable record dir should not stop the probe (rc=$rc): $out"
  case "$out" in *'warning: session record(s) left in the home: unknown (investigate-then-question [1/1])'*) : ;; *) fail "$tool: an unreadable record dir should be reported as unknown: $out" ;; esac
done
find "$claude_home/projects/-fake-proj" "$eval_home/sessions" -type f ! -name '*99999999*' -exec rm -f {} +
clean "after the unreadable dirs"

# --- 2 turn 目の前に評価用の home が変わったら止める。1 turn 目の記録は消す ---
FAKE_HOOK_1="touch '$eval_home/AGENTS.md'"; export FAKE_HOOK_1
run_turns codex investigate-then-question
unset FAKE_HOOK_1
[ "$rc" -eq 2 ] || fail "a changed eval home must stop the probe (rc=$rc): $out"
[ "$(launches)" -eq 1 ] || fail "the second turn must not start in a changed home: $(cat "$log")"
[ ! -e "$res" ] || fail "a stopped probe must not write results"
rm -f "$eval_home/AGENTS.md"
clean "changed home"

# --- 起動の前の確認。前の turn のある case で使う flag が欠ければ起動しない ---
for flag in --session-id --resume; do
  FAKE_HELP_DROP=$flag; export FAKE_HELP_DROP
  run_turns claude-code investigate-then-question
  unset FAKE_HELP_DROP
  [ "$rc" -eq 2 ] && [ "$(launches)" -eq 0 ] || fail "claude without $flag must not run (rc=$rc): $out"
  case "$out" in *"lacks flag(s): $flag"*) : ;; *) fail "claude: $flag should be named: $out" ;; esac
done
for flag in --ignore-user-config --ignore-rules --disable; do
  FAKE_HELP_DROP=$flag; export FAKE_HELP_DROP
  run_turns codex investigate-then-question
  unset FAKE_HELP_DROP
  [ "$rc" -eq 2 ] && [ "$(launches)" -eq 0 ] || fail "codex exec resume without $flag must not run (rc=$rc): $out"
  case "$out" in *"exec resume lacks boundary flag(s): $flag"*) : ;; *) fail "codex: $flag should be named: $out" ;; esac
done
FAKE_RC_RESUME_HELP=3; export FAKE_RC_RESUME_HELP
run_turns codex investigate-then-question
unset FAKE_RC_RESUME_HELP
[ "$rc" -eq 2 ] && [ "$(launches)" -eq 0 ] || fail "a failing exec resume --help must stop the probe (rc=$rc): $out"

# --- 3 件の表の全部と、dry-run の表示 ---
run_turns claude-code all
expect all 'd["runs"].map { |x| [x["case"], x["completion"], x["before"].length] }' \
  '[["investigate-then-question","exited",1],["investigate-then-symptom","exited",1],["investigate-then-fix","exited",1]]'
clean all
for tool in claude-code codex; do
  run_turns "$tool" all --dry-run
  [ "$rc" -eq 0 ] && [ ! -s "$log" ] || fail "$tool: dry-run must not launch a CLI (rc=$rc): $out"
  case "$out" in *'argv (turn 1): '*'argv (turn 2): '*) : ;; *) fail "$tool: dry-run should show both turns: $out" ;; esac
done

echo "probe-skill-behavior-turns-test: ok"
