#!/bin/sh
# personal-changed-scope-qa / personal-fast-edit-check が check を personal-safe-run 経由で起動することの self-test
# (#467)。配備と同じ layout (hook と safe-run を拡張子なしで同じ dir) を tmp に作る。
# - 決定的な分岐は fake の safe-run で確かめる: fake は引数を記録し、plan の report を --report の path に書いて
#   終わる。report の分類・不正な report・予算の計算 (--max-seconds)・cache・cleanup_complete false・上限の上書きと
#   不正値・safe-run の期限 (TERM / KILL)・出力の保持量。時刻は RUBYOPT=-r の注入で hook の時計を file に向け、fake が
#   その file を進める (実時間に頼らない)。
# - 実物の safe-run で確かめる: memory を確保し続ける check が memory の上限で止まり group が空 / 時間の上限 /
#   safe-run が無い・実行できない → check は走らない / safe-run の後も pipe の書き込み側を持つ子がいても期限内に
#   終わる / hook に TERM を送ると check の group が止まり state も出力も無い。
# 各 case は harness の watchdog (期限で hook と記録した pgid の group に KILL) を持ち、test の終わりに記録した
# pgid の group を片付ける。fixture は確保の量と寿命を自分で有限にする。
# 引数で source を差し替えられる (変異での確認用): <changed-scope-qa.rb> <fast-edit-check.rb>
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

qa_src=${1:-"$repo_root/shared/scripts/personal-changed-scope-qa.rb"}
edit_src=${2:-"$repo_root/shared/scripts/personal-fast-edit-check.rb"}
sr_src="$repo_root/shared/scripts/personal-safe-run.rb"
for f in "$qa_src" "$edit_src" "$sr_src"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
# RUBYOPT は空白で分割されるので、注入の path に空白があれば理由を出して止める (#469 の前例)。
case $tmp in *[[:space:]]*) fail "this test needs a tmp path without whitespace for RUBYOPT: $tmp" ;; esac

# 記録した pgid の group に member が残っていれば KILL し、chmod した fixture も消せるように権限を戻す。
cleanup() {
  for f in "$tmp"/*.pgid; do
    [ -f "$f" ] || continue
    pg=$(cat "$f" 2>/dev/null || :)
    case $pg in '' | *[!0-9]*) continue ;; esac
    if pgrep -g "$pg" >/dev/null 2>&1; then kill -KILL -- "-$pg" 2>/dev/null || :; fi
  done
  chmod -R u+rwx "$tmp" 2>/dev/null || :
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

repo="$tmp/repo"
git init -q "$repo"
echo base > "$repo/base.txt"
(cd "$repo" && git add base.txt && git commit -qm seed)
repo_real=$(ruby -e 'puts File.realpath(ARGV[0])' "$repo")
mkdir -p "$tmp/home"

# ---- 配備の layout ------------------------------------------------------------------------------
# deploy: 実物の safe-run / fake: fake の safe-run / none: safe-run が無い / noexec: safe-run が実行できない
deploy_hooks() {
  mkdir -p "$1"
  cp "$qa_src" "$1/personal-changed-scope-qa"
  cp "$edit_src" "$1/personal-fast-edit-check"
  chmod +x "$1/personal-changed-scope-qa" "$1/personal-fast-edit-check"
}
deploy_hooks "$tmp/deploy"
cp "$sr_src" "$tmp/deploy/personal-safe-run"
chmod +x "$tmp/deploy/personal-safe-run"
deploy_hooks "$tmp/none"
deploy_hooks "$tmp/noexec"
cp "$sr_src" "$tmp/noexec/personal-safe-run"
chmod 644 "$tmp/noexec/personal-safe-run"
deploy_hooks "$tmp/fake"
# fake の safe-run: argv を FAKE_SR_LOG に JSON で 1 行ずつ記録し、FAKE_SR_PLAN (JSON の配列) の先頭の step を消費する。
# step: elapse (時計 FAKE_CLOCK を進める秒) / report (--report の path に書く文字列) / output_bytes (stdout に書く量) /
# hang (true なら寝続ける。寿命は 60 秒) / ignore_term (true なら TERM で時計を 30 秒進めて寝続ける) / exit (exit code)。
# hang の step は、時計を進める前に TERM の handler を置き、TERM を受けたら FAKE_SR_TERM_MARK に印を書く (ignore_term で
# なければ 143 で終わる)。時計は一時 file + rename で進める (hook が読む途中の空の file を見せない)。
cat > "$tmp/fake/personal-safe-run" <<'RB'
#!/usr/bin/env ruby
require "json"
File.open(ENV.fetch("FAKE_SR_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
plan_path = ENV.fetch("FAKE_SR_PLAN")
plan = JSON.parse(File.read(plan_path))
step = plan.shift || abort("fake safe-run: the plan is empty")
File.write(plan_path, JSON.generate(plan))
clock = ENV.fetch("FAKE_CLOCK")
bump = lambda do |seconds|
  tmp = "#{clock}.#{Process.pid}.tmp"
  File.write(tmp, (Float(File.read(clock)) + seconds).to_s)
  File.rename(tmp, clock)
end
if step["hang"]
  trap("TERM") do
    File.open(ENV.fetch("FAKE_SR_TERM_MARK"), "a") { |f| f.puts "term" }
    step["ignore_term"] ? bump.call(30) : exit(143)
  end
end
bump.call(step.fetch("elapse", 0))
report = ARGV[ARGV.index("--report") + 1]
File.write(report, step["report"]) if step.key?("report")
$stdout.write("x" * step["output_bytes"]) if step.key?("output_bytes")
$stdout.flush
sleep 60 if step["hang"]
exit step.fetch("exit", 0)
RB
chmod +x "$tmp/fake/personal-safe-run"

# 注入: hook の時計 (SafeRunCheck.now) を FAKE_CLOCK の file の値にする。本体より前に -r で読まれるので、module を
# 先に開いて singleton class に prepend する。RUBYOPT は子 (fake の safe-run) に漏らさない。
cat > "$tmp/clock.rb" <<'RB'
ENV.delete("RUBYOPT")
module ChangedScopeQa; module SafeRunCheck; end; end
module FastEditCheck; module SafeRunCheck; end; end
module FakeClock
  def now
    Float(File.read(ENV.fetch("FAKE_CLOCK")))
  end
end
ChangedScopeQa::SafeRunCheck.singleton_class.prepend(FakeClock)
FastEditCheck::SafeRunCheck.singleton_class.prepend(FakeClock)
RB

# 注入: changed-scope-qa の state の書き込みの途中で自分に TERM を送り、handler が flag を立てるまで待つ (1 回だけ)。
# STATE_INTERRUPT=before-rename は一時 file (*.tmp) を書いた直後、after-rename は一時 file を state (*.json) に rename
# した直後。効いた印を STATE_INTERRUPT_LOG に書く。
cat > "$tmp/state-interrupt.rb" <<'RB'
module ChangedScopeQa; module SafeRunCheck; end; end
module StateInterrupt
  def write(*args, **kw)
    result = kw.empty? ? super(*args) : super(*args, **kw)
    state_interrupt("before-rename") if args[0].to_s.end_with?(".tmp")
    result
  end

  def rename(from, to)
    result = super
    state_interrupt("after-rename") if from.to_s.end_with?(".tmp") && to.to_s.end_with?(".json")
    result
  end

  def state_interrupt(mode)
    return unless ENV["STATE_INTERRUPT"] == mode && !$state_interrupted

    $state_interrupted = true
    File.open(ENV.fetch("STATE_INTERRUPT_LOG"), "a") { |f| f.puts mode }
    Process.kill("TERM", Process.pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.01 until ChangedScopeQa::SafeRunCheck.interrupted? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
File.singleton_class.prepend(StateInterrupt)
RB

# ---- 1. 2 つの hook の SafeRunCheck は同じ本文 -----------------------------------------------------
ruby -e '
blocks = ARGV.map do |path|
  text = File.read(path)
  start = text.index("  # ---- safe-run 経由の check の起動 (#467。")
  stop = text.index("  # ---- safe-run 経由の check の起動 (ここまで)")
  abort "#{path}: the SafeRunCheck block markers are missing" unless start && stop
  text[start...stop]
end
abort "the SafeRunCheck blocks of the two hooks must be identical" unless blocks.uniq.size == 1
' "$qa_src" "$edit_src" || fail "case 1: the two hooks must carry the same SafeRunCheck"

# ---- 2. fake の safe-run で決定的な分岐 (Ruby の driver) ---------------------------------------------
cat > "$tmp/fake-cases.rb" <<'RUBY'
require "json"
require "fileutils"
deploy, clock_rb, tmp, repo, state_rb = ARGV
QA = File.join(deploy, "personal-changed-scope-qa")
EDIT = File.join(deploy, "personal-fast-edit-check")
LOG = File.join(tmp, "fake-sr.log")
PLAN = File.join(tmp, "fake-sr-plan.json")
CLOCK = File.join(tmp, "fake-clock")
CONFIG = File.join(tmp, "fake-checks.json")
STATE = File.join(tmp, "fake-qa-state")
TERM_MARK = File.join(tmp, "fake-sr-term.mark")
INTERRUPT_LOG = File.join(tmp, "state-interrupt.log")

def report(reason: nil, exit: 0, signal: nil, started: true, cleanup: true, status: nil)
  JSON.generate("version" => 1, "command_started" => started, "reason" => reason, "signal" => nil,
                "exit_status" => status || exit || 137, "command_exit" => exit, "command_signal" => signal,
                "peak_footprint_mib" => 1.0, "elapsed_seconds" => 0.1, "leftover_killed" => 0,
                "cleanup_complete" => cleanup)
end

def write_config(qa: nil, edit: nil)
  entry = {}
  entry["qa_checks"] = qa if qa
  entry["edit_checks"] = edit if edit
  File.write(CONFIG, JSON.generate(File.realpath(ARGV[3]) => entry))
end

# hook を 1 回起動する (期限つき)。戻り値は [exit code, stdout, stderr, fake の呼び出しの argv の配列]。
# state_interrupt を渡すと、state の書き込みの途中で TERM を送る注入 (STATE_INTERRUPT) も読ませる。
def run_hook(path, payload, plan, fresh_state: true, cwd: ARGV[3], state_interrupt: nil)
  FileUtils.rm_rf(STATE) if fresh_state
  File.write(LOG, "")
  File.write(PLAN, JSON.generate(plan))
  File.write(CLOCK, "1000.0")
  FileUtils.rm_f([TERM_MARK, INTERRUPT_LOG])
  rubyopt = "-r#{ARGV[1]}"
  rubyopt += " -r#{ARGV[4]}" if state_interrupt
  env = { "AGENT_TOOLS_CHECKS_CONFIG" => CONFIG, "AGENT_TOOLS_QA_STATE_DIR" => STATE, "HOME" => File.join(ARGV[2], "home"),
          "RUBYOPT" => rubyopt, "FAKE_CLOCK" => CLOCK, "FAKE_SR_PLAN" => PLAN, "FAKE_SR_LOG" => LOG,
          "FAKE_SR_TERM_MARK" => TERM_MARK, "STATE_INTERRUPT" => state_interrupt.to_s, "STATE_INTERRUPT_LOG" => INTERRUPT_LOG }
  out_r, out_w = IO.pipe
  err_r, err_w = IO.pipe
  in_r, in_w = IO.pipe
  pid = Process.spawn(env, path, chdir: cwd, in: in_r, out: out_w, err: err_w)
  [in_r, out_w, err_w].each(&:close)
  in_w.write(JSON.generate(payload))
  in_w.close
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  status = nil
  until status
    _, status = Process.waitpid2(pid, Process::WNOHANG)
    next if status

    if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Process.kill("KILL", pid)
      Process.wait(pid)
      abort "FAIL: the hook did not finish within 30 s (#{path})"
    end
    sleep 0.02
  end
  calls = File.readlines(LOG).map { |line| JSON.parse(line) }
  [status.exitstatus, out_r.read, err_r.read, calls]
ensure
  [out_r, err_r].each { |io| io.close if io && !io.closed? }
end

STOP = { "hook_event_name" => "Stop", "stop_hook_active" => false }.freeze
def edit_payload(file)
  { "hook_event_name" => "PostToolUse", "tool_name" => "Edit", "tool_input" => { "file_path" => file } }
end

def state
  file = Dir.glob(File.join(STATE, "*.json")).first
  file ? JSON.parse(File.read(file)) : nil
end

def message(out)
  out.empty? ? "" : JSON.parse(out).fetch("systemMessage")
end

def context(out)
  out.empty? ? "" : JSON.parse(out).fetch("hookSpecificOutput").fetch("additionalContext")
end

def max_seconds(call)
  call[call.index("--max-seconds") + 1]
end

File.write(File.join(repo, "dirty.txt"), "dirty\n")
suite = [{ "name" => "suite", "command" => ["true"] }]
write_config(qa: suite)

# 2a: pass。引数は既定の上限 (memory 4096 MiB、qa の時間 300 秒) と新しい report の path、command は -- の後のまま。
code, out, err, calls = run_hook(QA, STOP, [{ "report" => report }])
check("2a: pass exits 0 silently (#{code} #{out} #{err})", code.zero? && out.empty?)
check("2a: one safe-run call", calls.size == 1)
args = calls.first || []
check("2a: default limits and the command after -- (#{args.inspect})",
      args[0, 4] == ["--max-footprint-mb", "4096", "--max-seconds", "300"] && args[4] == "--report" &&
      args[6..-1] == ["--", "true"])
check("2a: the report path is a fresh path in a temporary dir that is removed afterwards",
      args[5].to_s.end_with?("/report.json") && !File.exist?(File.dirname(args[5].to_s)))
check("2a: the pass is cached", state && state["outcome"] == "pass" && state["missing"] == [])

# 2b: failure の種類 (block。理由の文)
[
  ["exit 1", report(exit: 1, status: 1), "- suite: exit 1"],
  ["exit 2", report(exit: 2, status: 2), "- suite: exit 2"],
  ["exit 126", report(exit: 126, status: 126), "- suite: exit 126"],
  ["exit 127", report(exit: 127, status: 127), "- suite: exit 127"],
  ["signal", report(exit: nil, signal: 15, status: 143), "- suite: terminated by SIGTERM"],
  ["time", report(reason: "time", exit: nil, signal: 9), "- suite: safe-run が止めました (時間の上限 300 秒)"],
  ["footprint", report(reason: "footprint", exit: nil, signal: 15), "- suite: safe-run が止めました (memory の上限 4096 MiB)"],
  ["monitor", report(reason: "monitor", exit: nil, signal: 15), "- suite: safe-run が止めました (memory を監視できません)"]
].each do |label, rep, want|
  code, out, err, = run_hook(QA, STOP, [{ "report" => rep, "exit" => 1 }])
  check("2b #{label}: blocks with exit 2 (#{code} #{out} #{err})", code == 2)
  check("2b #{label}: the block names the reason '#{want}': #{err}", err.include?(want))
  check("2b #{label}: the failure is cached as fail", state && state["outcome"] == "fail" && state["missing"] == [])
end

# 2c: missing (警告、cache で確定しない) の種類
bad_reports = {
  "no report" => nil, "not json" => "{broken", "empty object" => "{}",
  "version 2" => report.sub('"version":1', '"version":2'),
  "unknown reason" => report.sub('"reason":null', '"reason":"bogus"'),
  "string exit" => report.sub('"command_exit":0', '"command_exit":"0"'),
  "float exit" => report.sub('"command_exit":0', '"command_exit":0.0'),
  "both exit and signal" => report(exit: 0, signal: 15),
  "neither exit nor signal" => report(exit: nil, signal: nil),
  "no cleanup_complete" => report.sub(',"cleanup_complete":true', ""),
  "bool started as string" => report.sub('"command_started":true', '"command_started":"true"')
}
# 必須 field (null を取りうる reason / command_exit / command_signal を含む) を 1 つずつ欠いた report
%w[version command_started reason exit_status command_exit command_signal cleanup_complete].each do |key|
  data = JSON.parse(report)
  data.delete(key)
  bad_reports["without #{key}"] = JSON.generate(data)
end
bad_reports.each do |label, rep|
  step = rep.nil? ? { "exit" => 2 } : { "report" => rep }
  code, out, err, = run_hook(QA, STOP, [step])
  check("2c #{label}: does not block (#{code} #{err})", code.zero?)
  check("2c #{label}: warns that the report is missing or invalid: #{out}",
        message(out).include?("suite (safe-run の report が無いか不正です)"))
  check("2c #{label}: kept as missing", state && state["outcome"] == "pass" && state["missing"] == ["suite"])
end
[
  ["not started", report(started: false, exit: nil, status: 127), "suite (spawn failed (exit 127))"],
  ["interrupted", report(reason: "interrupted", exit: nil, signal: 15), "suite (safe-run が signal で中断されました)"]
].each do |label, rep, want|
  code, out, err, = run_hook(QA, STOP, [{ "report" => rep }])
  check("2c #{label}: does not block (#{code} #{err})", code.zero?)
  check("2c #{label}: warns '#{want}': #{out}", message(out).include?(want))
  check("2c #{label}: kept as missing", state && state["missing"] == ["suite"])
end

# 2d: cleanup_complete false。pass でも警告し、pass として cache しない (次の Stop で再実行する)
code, out, err, = run_hook(QA, STOP, [{ "report" => report(cleanup: false) }])
check("2d: a pass with an incomplete cleanup does not block (#{code} #{err})", code.zero?)
check("2d: warns that the group was not fully stopped: #{out}", message(out).include?("process group を止め切れませんでした"))
check("2d: not cached as a plain pass", state && state["missing"] == ["suite"])
code, out, _err, calls = run_hook(QA, STOP, [{ "report" => report }], fresh_state: false)
check("2d: the same scope runs the check again (#{calls.size})", calls.size == 1 && code.zero? && out.empty?)
code, _out, err, = run_hook(QA, STOP, [{ "report" => report(exit: 1, status: 1, cleanup: false) }])
check("2d: a failure with an incomplete cleanup still blocks and says so: #{err}",
      code == 2 && err.include?("process group を止め切れませんでした"))

# 2d-2: failure と missing が混在する scope の cache-hit。再試行した check がまだ実行できなければ、その名前と理由を
# 警告に出す (cleanup の未完了の警告が cache-hit で消えない)
write_config(qa: [{ "name" => "failing", "command" => ["true"] }, { "name" => "flaky", "command" => ["true"] }])
code, _out, err, = run_hook(QA, STOP, [{ "report" => report(exit: 1, status: 1) }, { "report" => report(cleanup: false) }])
check("2d-2: the failure blocks and lists the missing check (#{code}): #{err}",
      code == 2 && err.include?("(未実行の check: flaky (safe-run が check の process group を止め切れませんでした))"))
check("2d-2: the state keeps the failure and the missing check", state && state["outcome"] == "fail" && state["missing"] == ["flaky"])
code, out, _err, calls = run_hook(QA, STOP, [{ "report" => report(cleanup: false) }], fresh_state: false)
check("2d-2: the cache-hit retries only the missing check (#{calls.size})", calls.size == 1 && code.zero?)
check("2d-2: the cache-hit warning names the retried check and its reason: #{out}",
      message(out).include?("未解消の check 失敗") &&
      message(out).include?("flaky (safe-run が check の process group を止め切れませんでした)"))
write_config(qa: suite)

# 2e: 総予算 (540 秒)。check の --max-seconds は min(上限, 残り)。総予算で短くした期限の time は予算切れ (missing)
two = [{ "name" => "first", "command" => ["true"] }, { "name" => "second", "command" => ["true"] }]
write_config(qa: two)
code, out, err, calls = run_hook(QA, STOP, [{ "elapse" => 300, "report" => report },
                                             { "report" => report(reason: "time", exit: nil, signal: 9) }])
check("2e: the second check gets the rest of the budget (#{calls.map { |c| max_seconds(c) }})",
      calls.size == 2 && max_seconds(calls[0]) == "300" && max_seconds(calls[1]) == "240")
check("2e: a time stop under the shortened limit is a missing, not a failure (#{code} #{err})", code.zero?)
check("2e: warns the budget ran out: #{out}", message(out).include?("second (時間の予算が尽きました"))
check("2e: kept as missing", state && state["outcome"] == "pass" && state["missing"] == ["second"])
code, out, _err, calls = run_hook(QA, STOP, [{ "report" => report }], fresh_state: false)
check("2e: the same scope retries only the missing check with a fresh budget (#{calls.inspect})",
      calls.size == 1 && max_seconds(calls[0]) == "300" && code.zero? && out.empty?)
code, out, _err, calls = run_hook(QA, STOP, [{ "elapse" => 539.5, "report" => report }])
check("2e: no check starts with less than 1 s left (#{calls.size})", calls.size == 1)
check("2e: the skipped check is a missing: #{out}", code.zero? && message(out).include?("second (時間の予算が尽きたので起動しませんでした)"))
code, out, _err, calls = run_hook(QA, STOP, [{ "elapse" => 300, "report" => report }, { "report" => report }])
check("2e: a pass under a shortened limit is a plain pass", code.zero? && out.empty? && state["missing"] == [])

# 2f: 上限の上書きと不正値
write_config(qa: [{ "name" => "tuned", "command" => ["true"], "max_footprint_mb" => 128, "max_seconds" => 7 }])
_code, _out, _err, calls = run_hook(QA, STOP, [{ "report" => report }])
check("2f: per-check limits override the defaults (#{calls.first.inspect})",
      calls.size == 1 && calls.first[0, 4] == ["--max-footprint-mb", "128", "--max-seconds", "7"])
invalid = [0, -1, 86_401, "10", 1.5, true, nil].map { |v| { "name" => "s#{v.inspect}", "command" => ["true"], "max_seconds" => v } } +
          [0, 1_048_577, "64", 64.0, false].map { |v| { "name" => "m#{v.inspect}", "command" => ["true"], "max_footprint_mb" => v } }
write_config(qa: invalid + suite)
code, out, _err, calls = run_hook(QA, STOP, [{ "report" => report }])
check("2f: only the valid check runs (#{calls.size})", calls.size == 1 && calls.first[-1] == "true")
check("2f: invalid limits are config errors: #{out}",
      code.zero? && message(out).include?("不正な check 宣言を無視しました") &&
      (0...invalid.size).all? { |i| message(out).include?("qa_checks[#{i}]") })

# 2g: safe-run の期限 (max_seconds + 20 秒)。過ぎたら TERM、TERM を無視したら 10 秒後に KILL。どちらも missing
write_config(qa: suite)
code, out, err, = run_hook(QA, STOP, [{ "elapse" => 400, "hang" => true }])
check("2g: an overdue safe-run is stopped and reported as a missing (#{code} #{err}): #{out}",
      code.zero? && message(out).include?("suite (safe-run が期限 (320 秒) までに終わりませんでした)"))
check("2g: the overdue safe-run received TERM", File.file?(TERM_MARK) && File.readlines(TERM_MARK) == ["term\n"])
# TERM を無視する fake は 60 秒寝続けるので、hook が期限 (30 秒) の内に終わるのは KILL まで進んだときだけ
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
code, out, err, = run_hook(QA, STOP, [{ "elapse" => 400, "hang" => true, "ignore_term" => true }])
check("2g: a safe-run that ignores TERM is killed (#{code} #{err}): #{out}",
      code.zero? && message(out).include?("suite (safe-run が期限 (320 秒) までに終わりませんでした)"))
check("2g: the TERM-ignoring safe-run received TERM before the KILL", File.file?(TERM_MARK) && File.readlines(TERM_MARK) == ["term\n"])
check("2g: the TERM-ignoring safe-run is gone well before its 60 s sleep ends",
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 20)

# 2g-2: hook が state を書いている途中で中断されたら、今回の state を置かず (rename の前) / 前の state に戻し (rename の
# 直後)、何も出さずに exit 0。block になる failure の scope と、無言の pass の scope で確かめる
[["fail", { "report" => report(exit: 1, status: 1) }], ["pass", { "report" => report }]].each do |label, step|
  %w[before-rename after-rename].each do |mode|
    [nil, "previous"].each do |previous|
      FileUtils.rm_rf(STATE)
      before = nil
      if previous
        # 別の scope で pass した state を先に置く (中断の後もこの内容のまま残ること)
        File.write(File.join(repo, "other-scope.txt"), "previous\n")
        run_hook(QA, STOP, [{ "report" => report }], fresh_state: false)
        File.delete(File.join(repo, "other-scope.txt"))
        before = Dir.glob(File.join(STATE, "*.json")).map { |f| [f, File.read(f)] }
      end
      code, out, err, = run_hook(QA, STOP, [step], fresh_state: false, state_interrupt: mode)
      name = "2g-2 #{label} #{mode}#{previous ? ' over a previous state' : ''}"
      check("#{name}: the injection fired", File.file?(INTERRUPT_LOG) && File.read(INTERRUPT_LOG) == "#{mode}\n")
      check("#{name}: exits 0 without output (#{code}): out=#{out} err=#{err}", code.zero? && out.empty? && err.empty?)
      after = Dir.exist?(STATE) ? Dir.glob(File.join(STATE, "*.json")).map { |f| [f, File.read(f)] } : []
      check("#{name}: the state is left as it was (#{after.inspect})", after == (before || []))
      check("#{name}: no temporary state file is left", Dir.glob(File.join(STATE, "*.tmp")).empty?)
    end
  end
end

# 2h: fast-edit-check。既定の上限 (30 秒)、command の後に file、失敗の理由、予算 (120 秒)、不正な report、cleanup
file = File.join(repo, "a.rb")
File.write(file, "puts 1\n")
lint = { "name" => "lint", "pattern" => "\\.rb$", "command" => ["true"] }
write_config(edit: [lint])
code, out, _err, calls = run_hook(EDIT, edit_payload(file), [{ "report" => report }])
check("2h: edit pass is silent", code.zero? && out.empty?)
check("2h: edit default limits and the file after the command (#{calls.first.inspect})",
      calls.size == 1 && calls.first[0, 4] == ["--max-footprint-mb", "4096", "--max-seconds", "30"] &&
      calls.first[6..-1] == ["--", "true", file])
_code, out, = run_hook(EDIT, edit_payload(file), [{ "report" => report(reason: "footprint", exit: nil, signal: 15), "output_bytes" => 5 }])
check("2h: an edit check stopped by the memory limit is reported with the reason: #{out}",
      context(out).include?("[lint] safe-run が止めました (memory の上限 4096 MiB)\nxxxxx"))
_code, out, = run_hook(EDIT, edit_payload(file), [{ "report" => report(exit: 1, status: 1), "output_bytes" => 3 }])
check("2h: an edit check failure keeps the exit reason and the output: #{out}", context(out).include?("[lint] exit 1\nxxx"))
_code, out, = run_hook(EDIT, edit_payload(file), [{ "report" => "{}" }])
check("2h: an invalid report is shown as not run: #{out}",
      context(out).include?("[lint] check を実行できません (safe-run の report が無いか不正です)"))
_code, out, = run_hook(EDIT, edit_payload(file), [{ "report" => report(cleanup: false) }])
check("2h: an edit pass with an incomplete cleanup warns: #{out}", context(out).include?("process group を止め切れませんでした"))
write_config(edit: [lint, lint.merge("name" => "lint2")])
_code, out, _err, calls = run_hook(EDIT, edit_payload(file), [{ "elapse" => 100, "report" => report },
                                                              { "report" => report(reason: "time", exit: nil, signal: 9) }])
check("2h: the edit budget is 120 s (#{calls.map { |c| max_seconds(c) }})",
      calls.size == 2 && max_seconds(calls[0]) == "30" && max_seconds(calls[1]) == "20")
check("2h: an edit time stop under the shortened limit is a missing: #{out}",
      context(out).include?("[lint2] check を実行できません (時間の予算が尽きました"))
write_config(edit: [lint.merge("max_seconds" => 5, "max_footprint_mb" => 64), lint.merge("name" => "bad", "max_seconds" => 0)])
_code, out, _err, calls = run_hook(EDIT, edit_payload(file), [{ "report" => report }])
check("2h: edit per-check limits override the defaults (#{calls.inspect})",
      calls.size == 1 && calls.first[0, 4] == ["--max-footprint-mb", "64", "--max-seconds", "5"])
check("2h: an invalid edit limit is a config error: #{out}", context(out).include?("不正な check 宣言を無視しました"))

# 2i: 出力は先頭 64 KiB だけ保持する (残りは読み捨て、check は詰まらずに終わる)。library として load して確かめる
load QA
load EDIT
[ChangedScopeQa::SafeRunCheck, FastEditCheck::SafeRunCheck].each do |mod|
  File.write(PLAN, JSON.generate([{ "output_bytes" => 1_000_000, "report" => report }]))
  File.write(CLOCK, "1000.0")
  ENV["FAKE_CLOCK"] = CLOCK
  ENV["FAKE_SR_PLAN"] = PLAN
  ENV["FAKE_SR_LOG"] = LOG
  result = mod.run(["true"], repo, 4096, 30, mod.now + 120)
  check("2i #{mod}: a 1 MB output passes through without blocking (#{result[:status]})", result[:status] == :pass)
  check("2i #{mod}: only the first 64 KiB is kept (#{result[:output].bytesize})", result[:output].bytesize == 64 * 1024)
end
exit(@failed.zero? ? 0 : 1)
RUBY
ruby -r"$script_dir/lib/check_helper" "$tmp/fake-cases.rb" "$tmp/fake" "$tmp/clock.rb" "$tmp" "$repo" "$tmp/state-interrupt.rb" \
  || fail "case 2: the fake safe-run cases failed"
rm -f "$repo/dirty.txt"

# ---- harness (実物の case) ------------------------------------------------------------------------
# 使い方: ruby harness.rb <result> <timeout 秒> <pgid file> [--stdin FILE] [--chdir DIR] [--at FILE SIGNAL]... -- <command...>
# command を shell を通さずに起動し、終わるまで待つ。--at は順に、FILE が現れたら SIGNAL を command に送る。期限を過ぎたら
# command と pgid file の group に KILL して "timeout" を書く。result の 1 行: <exit|signal|timeout> <値> <経過秒>
cat > "$tmp/harness.rb" <<'RB'
def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
result, timeout, pgid_file, *rest = ARGV
sep = rest.index("--") or abort("harness: -- がありません")
opts = rest[0...sep]
cmd = rest[(sep + 1)..-1]
spawn_opts = { in: File::NULL }
ats = []
until opts.empty?
  case (opt = opts.shift)
  when "--stdin" then spawn_opts[:in] = opts.shift
  when "--chdir" then spawn_opts[:chdir] = opts.shift
  when "--at" then ats << [opts.shift, opts.shift]
  else abort("harness: unknown option #{opt}")
  end
end
# test を起動した側の扱い (nohup の HUP、背景 job の INT / QUIT の無視) を command に継承させない。
%w[INT TERM HUP QUIT TSTP].each { |name| Signal.trap(name, "SYSTEM_DEFAULT") }
started = now
deadline = started + Float(timeout)
pid = Process.spawn([cmd[0], cmd[0]], *cmd[1..-1], **spawn_opts)
status = nil
loop do
  _, status = Process.waitpid2(pid, Process::WNOHANG)
  break if status

  if now >= deadline
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
    pg = File.read(pgid_file).to_i rescue 0
    Process.kill("KILL", -pg) rescue nil if pg.positive?
    File.write(result, "timeout - #{(now - started).round(3)}\n")
    exit 0
  end
  if (at = ats.first) && File.size?(at[0])
    ats.shift
    Process.kill(at[1], pid)
  end
  sleep 0.02
end
kind = status.exited? ? "exit" : "signal"
value = status.exited? ? status.exitstatus : status.termsig
File.write(result, "#{kind} #{value} #{(now - started).round(3)}\n")
RB

# run_case <case> <timeout 秒> [harness の option...] -- <command...>
# stdout / stderr を <case>.out / <case>.err に取り、kind / code / elapsed に結果を入れる。watchdog が働いたら fail。
run_case() {
  rc_case=$1
  rc_timeout=$2
  shift 2
  rc_status=0
  ruby "$tmp/harness.rb" "$tmp/$rc_case.result" "$rc_timeout" "$tmp/$rc_case.pgid" "$@" \
    >"$tmp/$rc_case.out" 2>"$tmp/$rc_case.err" || rc_status=$?
  [ "$rc_status" -eq 0 ] || fail "$rc_case: harness failed ($rc_status): $(cat "$tmp/$rc_case.err")"
  read -r kind code elapsed < "$tmp/$rc_case.result"
  [ "$kind" != timeout ] || fail "$rc_case: watchdog fired after ${rc_timeout}s: $(cat "$tmp/$rc_case.err")"
}

# expect_group_gone <case>: check の process group が期限 (5 秒) までに空になる
expect_group_gone() {
  [ -s "$tmp/$1.pgid" ] || fail "$1: the check did not record its pgid"
  eg_pgid=$(cat "$tmp/$1.pgid")
  eg_i=0
  while pgrep -g "$eg_pgid" >/dev/null 2>&1; do
    eg_i=$((eg_i + 1))
    [ "$eg_i" -le 100 ] || fail "$1: process group $eg_pgid still has members: $(pgrep -l -g "$eg_pgid" | tr '\n' ' ')"
    sleep 0.05
  done
}

expect_quick() {
  ruby -e 'exit(Float(ARGV[0]) < Float(ARGV[1]) ? 0 : 1)' "$elapsed" "$2" || fail "$1: should finish within $2 s, took $elapsed"
}

real_config="$tmp/real-checks.json"
# qa の check を 1 つ宣言する: write_qa <name> <上限の JSON (例 {"max_seconds":1})> <command...>
write_qa() {
  ruby -rjson -e '
    root, conf, name, limits, *command = ARGV
    File.write(conf, JSON.generate(root => { "qa_checks" => [{ "name" => name, "command" => command }.merge(JSON.parse(limits))] }))
  ' "$repo_real" "$real_config" "$@"
}
write_edit() {
  ruby -rjson -e '
    root, conf, name, limits, *command = ARGV
    File.write(conf, JSON.generate(root => { "edit_checks" => [{ "name" => name, "pattern" => "\\.rb$", "command" => command }.merge(JSON.parse(limits))] }))
  ' "$repo_real" "$real_config" "$@"
}
printf '{"hook_event_name":"Stop","stop_hook_active":false}' > "$tmp/stop.json"
printf '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$repo/a.rb" > "$tmp/edit.json"
echo 'puts 1' > "$repo/a.rb"
# run_qa_case <case> <timeout> <deploy dir> [--at ...]: qa の hook を repo で起動する (state は <case>.state)
run_qa_case() {
  rq_case=$1
  rq_timeout=$2
  rq_deploy=$3
  shift 3
  run_case "$rq_case" "$rq_timeout" --stdin "$tmp/stop.json" --chdir "$repo" "$@" \
    -- env AGENT_TOOLS_CHECKS_CONFIG="$real_config" AGENT_TOOLS_QA_STATE_DIR="$tmp/$rq_case.state" HOME="$tmp/home" \
    "$rq_deploy/personal-changed-scope-qa"
}
run_edit_case() {
  re_case=$1
  re_timeout=$2
  re_deploy=$3
  shift 3
  run_case "$re_case" "$re_timeout" --stdin "$tmp/edit.json" "$@" \
    -- env AGENT_TOOLS_CHECKS_CONFIG="$real_config" HOME="$tmp/home" "$re_deploy/personal-fast-edit-check"
}

# fx-alloc.rb: 64 MiB ずつ書き込みながら確保し (最大 512 MiB)、寿命 20 秒で終わる
cat > "$tmp/fx-alloc.rb" <<'RB'
held = []
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  held << ("x" * (64 * 1024 * 1024)) if held.size < 8
  sleep 0.2
end
RB
# 自分の pid (= pgid) を $0 の file に書いてから、残りの引数を exec する
record='echo $$ > "$0"; exec "$@"'

# ---- 3. memory を確保し続ける check が safe-run の memory の上限で止まり、group が空 (qa / edit) ----------------
echo mem >> "$repo/base.txt"
write_qa mem '{"max_footprint_mb":128}' sh -c "$record" "$tmp/mem.pgid" ruby "$tmp/fx-alloc.rb"
run_qa_case mem 60 "$tmp/deploy"
[ "$code" -eq 2 ] || fail "mem: a check over the memory limit must block (exit $code): $(cat "$tmp/mem.err")"
grep -qF -- "- mem: safe-run が止めました (memory の上限 128 MiB)" "$tmp/mem.err" || fail "mem: the block must name the memory limit: $(cat "$tmp/mem.err")"
expect_group_gone mem
write_edit memedit '{"max_footprint_mb":128}' sh -c "$record" "$tmp/memedit.pgid" ruby "$tmp/fx-alloc.rb"
run_edit_case memedit 60 "$tmp/deploy"
[ "$code" -eq 0 ] || fail "memedit: the edit hook must not block (exit $code)"
grep -qF "[memedit] safe-run が止めました (memory の上限 128 MiB)" "$tmp/memedit.out" || fail "memedit: the context must name the memory limit: $(cat "$tmp/memedit.out")"
expect_group_gone memedit

# ---- 4. 時間の上限 ------------------------------------------------------------------------------
echo time >> "$repo/base.txt"
write_qa slow '{"max_seconds":1}' sh -c "$record" "$tmp/slow.pgid" sleep 30
run_qa_case slow 30 "$tmp/deploy"
[ "$code" -eq 2 ] || fail "slow: a check over the time limit must block (exit $code): $(cat "$tmp/slow.err")"
grep -qF -- "- slow: safe-run が止めました (時間の上限 1 秒)" "$tmp/slow.err" || fail "slow: the block must name the time limit: $(cat "$tmp/slow.err")"
expect_group_gone slow
expect_quick slow 10

# ---- 5. safe-run が無い・実行できない → check は走らず、起動失敗の警告 -------------------------------------
for variant in none noexec; do
  echo "$variant" >> "$repo/base.txt"
  : > "$tmp/ran.log"
  write_qa guarded '{}' sh -c 'echo ran >> "$0"' "$tmp/ran.log"
  run_qa_case "qa-$variant" 30 "$tmp/$variant"
  [ "$code" -eq 0 ] || fail "qa-$variant: an unusable safe-run must not block (exit $code)"
  grep -qF "guarded (safe-run を使えません (personal-safe-run が無いか実行できません))" "$tmp/qa-$variant.out" \
    || fail "qa-$variant: must warn that safe-run is unusable: $(cat "$tmp/qa-$variant.out")"
  write_edit guarded '{}' sh -c 'echo ran >> "$0"' "$tmp/ran.log"
  run_edit_case "edit-$variant" 30 "$tmp/$variant"
  grep -qF "[guarded] check を実行できません (safe-run を使えません" "$tmp/edit-$variant.out" \
    || fail "edit-$variant: must report that safe-run is unusable: $(cat "$tmp/edit-$variant.out")"
  [ ! -s "$tmp/ran.log" ] || fail "$variant: the check must not run without safe-run"
done

# ---- 6. safe-run が終わった後も pipe の書き込み側を持つ子 (group を抜けた子) がいても、hook は期限内に終わる --------
# check は group を抜けた子 (setpgrp。stdout は pipe のまま) を残して exit 0。safe-run は group だけを止めて終わり、
# hook は pipe の EOF を待たない。子は test の片付けが止める (pgid を escaped.pgid に記録)。
echo escaped >> "$repo/base.txt"
cat > "$tmp/fx-escape.sh" <<'SH'
perl -e 'setpgrp(0, 0); open(my $f, ">", $ARGV[0]) or die; print $f "$$\n"; close $f; sleep 30' "$1" &
i=0
while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
exit 0
SH
write_qa escape '{}' sh "$tmp/fx-escape.sh" "$tmp/escaped.pgid"
run_qa_case escape 30 "$tmp/deploy"
[ "$code" -eq 0 ] || fail "escape: a passing check must not block (exit $code): $(cat "$tmp/escape.err")"
[ ! -s "$tmp/escape.out" ] || fail "escape: a passing check must be silent: $(cat "$tmp/escape.out")"
[ -s "$tmp/escaped.pgid" ] || fail "escape: the escaped child did not start"
pgrep -g "$(cat "$tmp/escaped.pgid")" >/dev/null || fail "escape: the escaped child should still hold the pipe (fixture assumption)"
expect_quick escape 8

# ---- 7. hook に TERM を送ると、動いている check の group が止まり、state も出力も無いまま終わる ------------------
echo term >> "$repo/base.txt"
write_qa held '{}' sh -c "$record" "$tmp/term.pgid" sleep 30
run_qa_case term 30 "$tmp/deploy" --at "$tmp/term.pgid" TERM
[ "$kind" = exit ] && [ "$code" -eq 0 ] || fail "term: the interrupted hook must exit 0 ($kind $code): $(cat "$tmp/term.err")"
[ ! -s "$tmp/term.out" ] || fail "term: the interrupted hook must not print: $(cat "$tmp/term.out")"
[ ! -s "$tmp/term.err" ] || fail "term: the interrupted hook must not print on stderr: $(cat "$tmp/term.err")"
[ -z "$(ls -A "$tmp/term.state" 2>/dev/null)" ] || fail "term: the interrupted hook must not write state: $(ls -A "$tmp/term.state")"
expect_group_gone term
expect_quick term 10
write_edit heldedit '{}' sh -c "$record" "$tmp/termedit.pgid" sleep 30
run_edit_case termedit 30 "$tmp/deploy" --at "$tmp/termedit.pgid" TERM
[ "$kind" = exit ] && [ "$code" -eq 0 ] || fail "termedit: the interrupted hook must exit 0 ($kind $code)"
[ ! -s "$tmp/termedit.out" ] || fail "termedit: the interrupted hook must not print: $(cat "$tmp/termedit.out")"
expect_group_gone termedit
expect_quick termedit 10

echo "ok: quality-loop safe-run self-test"
