#!/bin/sh
# personal-safe-run.rb の self-test (#466)。
# 配備と同じ layout (拡張子なしの名前) に copy して CLI として実行する。各 case は test 用の runner (harness) が
# safe-run を起動し、期限 (watchdog: 過ぎたら safe-run と fixture の group に KILL) と signal の送り込みを持つ。
# fixture は自分の pid (= process group の id) を <case>.pgid に書き、test はその pgid で group が空になったことを
# 確かめる (safe-run は別 group なので使わない)。memory を確保する fixture は確保の量と寿命を自分で有限にする。
# test の終わり (trap) で、記録した pgid の group に member が残っていれば KILL する。
# 固定するもの: usage と前提 (exit 2、command を起動しない、report を書かない)、起動できない (127 / 126)、透過
# (exit code、stdout / stderr、argv、stdin)、時間の上限と KILL への escalation、footprint の上限 (node --test の
# 子、group の合計)、leader の終了後に残った process の片付け (leader は最後まで回収しない)、中断 (TERM / TSTP、
# 2 回目の signal、同じ巡回の 2 つの signal)、終了と期限の競合、計測不能 (monitor。proc_listpids の 0 件を含む) と
# 一部だけの回復、別 group の pid を数えない、phys_footprint の decode と footprint CLI との一致、report の書き込みの
# 失敗、端末の stdin、SIGCHLD を無視する親、起動時に無視されていた signal (nohup の HUP)、後始末の中の観測の例外、
# 後始末の列挙の直後の fork、self-pipe の close の境界の signal、読まれずに詰まった stderr。
# fixture は寿命を自分で有限にする (TERM を無視するものも 30 秒前後で自分から終わる)。
# 注入 (RUBYOPT=-r) は safe-run の 1 起動だけに付け、本体の module の singleton class に prepend する。
# 引数で script の source を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src=${1:-"$repo_root/shared/scripts/personal-safe-run.rb"}
[ -f "$src" ] || fail "missing $src"
command -v node >/dev/null 2>&1 || fail "node is required (footprint case runs node --test)"
[ -x /usr/bin/footprint ] || fail "/usr/bin/footprint is required (the CLI comparison case)"
[ -x /usr/bin/script ] || fail "/usr/bin/script is required (the tty case)"

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

deploy="$tmp/deploy"
mkdir -p "$deploy"
cp "$src" "$deploy/personal-safe-run"
chmod +x "$deploy/personal-safe-run"
sr="$deploy/personal-safe-run"

# ---- harness ------------------------------------------------------------------------------------
# 使い方: ruby harness.rb <result> <timeout 秒> <pgid file> [--stdin FILE | --hold-stdin] [--stuck-stderr] [--at FILE ACTION]... -- <command...>
# command を shell を通さずに起動し、終わるまで待つ。--hold-stdin は書かずに開けたままの pipe を stdin に、
# --stuck-stderr は読まずに開けたままの pipe を stderr にする (command が書けば詰まる)。--at は順に、FILE が現れたら ACTION を行う (ACTION は signal 名
# なら command に送る、run:<script> なら sh <script> を同期で走らせる)。期限を過ぎたら command と pgid file の group に
# KILL して "timeout" を書く。result の 1 行: <exit|signal|timeout> <値> <経過秒> <最初の signal からの秒|-> <行った --at の数>
cat > "$tmp/harness.rb" <<'RB'
def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
result, timeout, pgid_file, *rest = ARGV
sep = rest.index("--") or abort("harness: -- がありません")
opts = rest[0...sep]
cmd = rest[(sep + 1)..-1]
stdin = File::NULL
hold_r = hold_w = nil
stuck_r = stuck_w = nil
ats = []
until opts.empty?
  case (opt = opts.shift)
  when "--stdin" then stdin = opts.shift
  when "--hold-stdin" then hold_r, hold_w = IO.pipe; stdin = hold_r
  when "--stuck-stderr" then stuck_r, stuck_w = IO.pipe
  when "--at" then ats << [opts.shift, opts.shift]
  else abort("harness: unknown option #{opt}")
  end
end
# test を起動した側の扱い (nohup の HUP、背景 job の INT / QUIT の無視) を command に継承させない。safe-run は
# 起動時に無視されていた signal を無視のまま残すので、継承すると signal の case が起動の仕方で変わる。
%w[INT TERM HUP QUIT TSTP].each { |name| Signal.trap(name, "SYSTEM_DEFAULT") }
started = now
deadline = started + Float(timeout)
spawn_opts = { in: stdin }
spawn_opts[:err] = stuck_w if stuck_w
pid = Process.spawn([cmd[0], cmd[0]], *cmd[1..-1], **spawn_opts)
hold_r&.close
stuck_w&.close
first_signal = nil
done = 0
status = nil
loop do
  _, status = Process.waitpid2(pid, Process::WNOHANG)
  break if status

  if now >= deadline
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
    pg = File.read(pgid_file).to_i rescue 0
    Process.kill("KILL", -pg) rescue nil if pg.positive?
    File.write(result, "timeout - #{(now - started).round(3)} - #{done}\n")
    exit 0
  end
  if (at = ats.first) && File.exist?(at[0])
    ats.shift
    done += 1
    if at[1].start_with?("run:")
      system("sh", at[1].sub("run:", "")) or abort("harness: probe failed")
    else
      first_signal ||= now
      Process.kill(at[1], pid)
    end
  end
  sleep 0.02
end
hold_w&.close
stuck_r&.close
finished = now
kind = status.exited? ? "exit" : "signal"
value = status.exited? ? status.exitstatus : status.termsig
since = first_signal ? (finished - first_signal).round(3) : "-"
File.write(result, "#{kind} #{value} #{(finished - started).round(3)} #{since} #{done}\n")
RB

# run_case <case> <timeout 秒> [harness の option...] -- <command...>
# harness で起動し、stdout / stderr を <case>.out / <case>.err に取る。kind / code / elapsed / since / done に結果を入れる。
# watchdog が働いたら fail。
run_case() {
  rc_case=$1
  rc_timeout=$2
  shift 2
  rc_status=0
  ruby "$tmp/harness.rb" "$tmp/$rc_case.result" "$rc_timeout" "$tmp/$rc_case.pgid" "$@" \
    >"$tmp/$rc_case.out" 2>"$tmp/$rc_case.err" || rc_status=$?
  [ "$rc_status" -eq 0 ] || fail "$rc_case: harness failed ($rc_status): $(cat "$tmp/$rc_case.err")"
  read -r kind code elapsed since done < "$tmp/$rc_case.result"
  [ "$kind" != timeout ] || fail "$rc_case: watchdog fired after ${rc_timeout}s: $(cat "$tmp/$rc_case.err")"
}

# expect_exit <case> <code>: safe-run が signal で死なず、exit <code> で終わった
expect_exit() {
  [ "$kind" = exit ] || fail "$1: safe-run must exit (not die by signal $code): $(cat "$tmp/$1.err")"
  [ "$code" -eq "$2" ] || fail "$1: exit should be $2, got $code: $(cat "$tmp/$1.err")"
}

# expect_report <case> <key><op><value>...: report の key の集合が契約どおりで、各条件を満たす。
# op は = (inspect 表記で一致)、> / < (数値の比較)。
expect_report() {
  er_case=$1
  shift
  [ -f "$tmp/$er_case.json" ] || fail "$er_case: report was not written: $(cat "$tmp/$er_case.err")"
  ruby -rjson -e '
    data = JSON.parse(File.read(ARGV.shift))
    keys = %w[version command_started reason signal exit_status command_exit command_signal peak_footprint_mib
              elapsed_seconds leftover_killed cleanup_complete]
    bad = []
    bad << "keys: #{data.keys.sort.inspect}" unless data.keys.sort == keys.sort
    ARGV.each do |cond|
      key, op, want = cond.match(/\A(\w+)([=<>])(.*)\z/).captures
      got = data[key]
      ok = case op
           when "=" then got.inspect == want
           when ">" then got.is_a?(Numeric) && got > Float(want)
           else got.is_a?(Numeric) && got < Float(want)
           end
      bad << "#{key}: want #{op}#{want}, got #{got.inspect}" unless ok
    end
    unless bad.empty?
      warn bad.join("; ")
      exit 1
    end
  ' "$tmp/$er_case.json" "$@" || fail "$er_case: report mismatch: $(cat "$tmp/$er_case.json")"
}

# expect_group_gone <case>: fixture の process group が期限 (5 秒) までに空になる (回収待ちの zombie が消えるまで待つ)
expect_group_gone() {
  [ -s "$tmp/$1.pgid" ] || fail "$1: fixture did not record its pgid"
  eg_pgid=$(cat "$tmp/$1.pgid")
  eg_i=0
  while pgrep -g "$eg_pgid" >/dev/null 2>&1; do
    eg_i=$((eg_i + 1))
    [ "$eg_i" -le 100 ] || fail "$1: process group $eg_pgid still has members: $(pgrep -l -g "$eg_pgid" | tr '\n' ' ')"
    sleep 0.05
  done
}

# expect_err_has <case> <文字列>
expect_err_has() {
  grep -qF -- "$2" "$tmp/$1.err" || fail "$1: stderr should contain '$2': $(cat "$tmp/$1.err")"
}

# expect_err_only_prefixed <case>: stderr の行はすべて safe-run の固定の接頭辞で始まる (fixture が stderr に書かない case)
expect_err_only_prefixed() {
  if grep -v '^personal-safe-run: ' "$tmp/$1.err" >/dev/null; then
    fail "$1: stderr must hold only personal-safe-run: lines: $(cat "$tmp/$1.err")"
  fi
}

# ---- fixtures -----------------------------------------------------------------------------------
# fx-sleep.sh <pgid> <ready> <秒>: 子の sleep を起動してから ready を書き、子を待つ
cat > "$tmp/fx-sleep.sh" <<'SH'
echo $$ > "$1"
sleep "$3" &
: > "$2"
wait
SH
# fx-ignore-term.sh <pgid>: TERM を無視する leader と子と孫 (無視は exec を越えて継承される)。寿命は孫の sleep の 30 秒
cat > "$tmp/fx-ignore-term.sh" <<'SH'
trap '' TERM
echo $$ > "$1"
sh -c 'sleep 30 & wait' &
wait
SH
# fx-leftover.sh <pgid> <孫の pid>: sleep 30 の孫を残して exit 0
cat > "$tmp/fx-leftover.sh" <<'SH'
echo $$ > "$1"
sleep 30 &
echo $! > "$2"
exit 0
SH
# fx-trapper.sh <got_term> <ready>: TERM を受けたら印を書いて動き続ける (KILL でしか止まらない。寿命は 30 巡)
cat > "$tmp/fx-trapper.sh" <<'SH'
trap 'echo t >> "$1"' TERM
: > "$2"
i=0
while [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
SH
# fx-leftover-trap.sh <pgid> <got_term> <ready> <trapper>: trapper を残し、trap を入れ終えてから exit 0 (待ちは上限つき)
cat > "$tmp/fx-leftover-trap.sh" <<'SH'
echo $$ > "$1"
sh "$4" "$2" "$3" &
i=0
while [ ! -e "$3" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
exit 0
SH
# fx-term-loop.sh <pgid> <got_term>: leader が TERM を受けたら印を書いて動き続ける (寿命は 30 巡)
cat > "$tmp/fx-term-loop.sh" <<'SH'
trap 'echo t >> "$2"' TERM
echo $$ > "$1"
i=0
while [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
SH
# fx-forker.sh <go> <child> <ready>: 合図 (go) を待ち、子 (sleep 30) を fork して pid を child に書いてから自分は
# 終わる (待ちは上限つき)
cat > "$tmp/fx-forker.sh" <<'SH'
: > "$3"
i=0
while [ ! -e "$1" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
sleep 30 &
echo $! > "$2"
exit 0
SH
# fx-fork-leader.sh <pgid> <go> <child> <ready> <forker>: forker を残し、forker が動き出してから exit 0
cat > "$tmp/fx-fork-leader.sh" <<'SH'
echo $$ > "$1"
sh "$5" "$2" "$3" "$4" &
i=0
while [ ! -e "$4" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
exit 0
SH
# fx-alloc.rb <MiB> <寿命 秒>: MiB を確保して書き込み (footprint に乗る)、寿命まで待って終わる
cat > "$tmp/fx-alloc.rb" <<'RB'
held = "x" * (Integer(ARGV[0]) * 1024 * 1024)
sleep Float(ARGV[1])
held.size
RB
# fx-group.sh <pgid> <alloc> <MiB> <寿命>: 3 つの子がそれぞれ MiB を確保する
cat > "$tmp/fx-group.sh" <<'SH'
echo $$ > "$1"
ruby "$2" "$3" "$4" &
ruby "$2" "$3" "$4" &
ruby "$2" "$3" "$4" &
wait
SH
# node --test が test file を子 process で走らせ、test file がさらに確保する子を起動する。確保は STEP MiB ずつ
# 最大 MAX MiB、寿命 LIFE ミリ秒で終わる。
mkdir -p "$tmp/node"
cat > "$tmp/node/alloc.mjs" <<'JS'
const step = Number(process.env.ALLOC_STEP_MIB);
const max = Number(process.env.ALLOC_MAX_MIB);
const end = Date.now() + Number(process.env.ALLOC_LIFE_MS);
const held = [];
const timer = setInterval(() => {
  if (held.length * step < max) held.push(Buffer.alloc(step * 1024 * 1024, 0x5a));
  if (Date.now() >= end) clearInterval(timer);
}, 200);
JS
cat > "$tmp/node/alloc.test.mjs" <<'JS'
import { test } from "node:test";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
test("a child allocates a bounded amount", async () => {
  const child = spawn(process.execPath, [fileURLToPath(new URL("./alloc.mjs", import.meta.url))], { stdio: "inherit" });
  await new Promise((resolve) => child.on("exit", resolve));
});
JS
cat > "$tmp/fx-node.sh" <<'SH'
echo $$ > "$1"
exec node --test "$2"
SH
# fx-flood.pl <pgid>: leader として stderr に書き続ける (読まれない pipe なら詰まって止まる)。寿命は alarm の 30 秒
cat > "$tmp/fx-flood.pl" <<'PL'
open(my $f, ">", $ARGV[0]) or die "pgid: $!";
print $f "$$\n";
close $f;
alarm 30;
print STDERR ("x" x 1000), "\n" while 1;
PL

# 注入: 本体より前に -r で読まれるので、module を先に開いて singleton class に prepend する (module_function の
# 定義より前に入っても、lookup は prepend した module が先)。RUBYOPT は command に漏らさない。効いた印を stderr に書く。
cat > "$tmp/inject.rb" <<'RB'
ENV.delete("RUBYOPT")
module SafeRun; end
module SafeRunInjection
  MODE = ENV.fetch("SAFE_RUN_INJECT")

  def inject_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # listpids-zero: Fiddle の呼び出しの境界で、command の group の proc_listpids を 0 にする (libproc が syscall の
  # 失敗を変えた値)。自分の group (起動前の自己検査) には効かせない。
  def bind_libproc
    super
    return unless MODE == "listpids-zero"

    real = @listpids
    own = Process.getpgrp
    @listpids = Object.new
    @listpids.define_singleton_method(:call) do |type, pgid, buf, size|
      next real.call(type, pgid, buf, size) if pgid == own

      $stderr.write("inject: listpids-zero\n")
      0
    end
  end

  # delay-first: 最初の巡回を 1.5 秒遅らせる。signal の handler で sleep が早く戻っても、1.5 秒は巡回に戻らない。
  def wait_tick(reader, seconds)
    if MODE == "delay-first" && !@inject_delayed
      @inject_delayed = true
      $stderr.write("inject: delay-first\n")
      until_at = inject_now + 1.5
      loop do
        left = until_at - inject_now
        break if left <= 0

        sleep left
      end
    end
    super
  end

  def measure_group(pgid)
    @inject_measures = (@inject_measures || 0) + 1
    @inject_pgid = pgid
    @inject_measuring = true
    super
  ensure
    @inject_measuring = false
  end

  # cleanup-raise: 後始末の中 (計測の外) の列挙で例外を出す。
  # fork-race: 後始末の最初の列挙の直後に member へ合図し、member が子を fork して自分は終わるのを待ってから古い
  # 結果を返す (列挙と計測の間に起きた fork を同期して再現する)。
  def list_group(leader)
    if MODE == "cleanup-raise" && !@inject_measuring
      $stderr.write("inject: cleanup-raise\n")
      raise "injected"
    end
    pids = super
    if MODE == "fork-race" && !@inject_measuring && !@inject_forked
      @inject_forked = true
      inject_fork_race(leader, pids)
    end
    pids
  end

  def inject_fork_race(leader, pids)
    File.write(ENV.fetch("SAFE_RUN_INJECT_GO"), "")
    child = ENV.fetch("SAFE_RUN_INJECT_CHILD")
    others = Array(pids) - [leader]
    deadline = inject_now + 5
    until File.size?(child) && !others.empty? && others.none? { |pid| member_state(pid, leader).first == :alive }
      if inject_now > deadline
        $stderr.write("inject: fork-race timeout\n")
        return
      end
      sleep 0.02
    end
    $stderr.write("inject: fork-race ready\n")
  end

  # eperm / eperm-recover: 計測の中だけ、leader 以外の member を EPERM にする (後始末の生死の判定には効かせない)。
  def pid_rusage(pid)
    if @inject_measuring && pid != @inject_pgid &&
       (MODE == "eperm" || (MODE == "eperm-recover" && (@inject_measures % 3) != 0))
      $stderr.write("inject: eperm\n")
      return [:error, Errno::EPERM::Errno]
    end
    super
  end

  # foreign-pgid: 計測の中だけ、leader 以外の member を別の group の process に見せる (列挙の後に pid が再利用された状態)。
  def pid_pgid(pid)
    if @inject_measuring && pid != @inject_pgid && MODE == "foreign-pgid"
      $stderr.write("inject: foreign-pgid\n")
      return [:ok, @inject_pgid + 1]
    end
    super
  end

  # close-signal: self-pipe の close の境界 (最初に閉じた側の直後) で自分に TERM を送り、handler が走るまで待つ。
  def install_traps(writer)
    inject_arm_close(writer) if MODE == "close-signal"
    super
  end

  def watch(leader, options, reader, started)
    inject_arm_close(reader) if MODE == "close-signal"
    super
  end

  def inject_arm_close(io)
    injection = self
    io.define_singleton_method(:close) do
      super()
      injection.inject_close_boundary
    end
  end

  def inject_close_boundary
    return if @inject_closed

    @inject_closed = true
    $stderr.write("inject: close-signal\n")
    Process.kill("TERM", Process.pid)
    deadline = inject_now + 2
    sleep 0.01 until @signal || inject_now > deadline
  end
end
SafeRun.singleton_class.prepend(SafeRunInjection)
RB

# ---- case 1: unit。decode は phys_footprint (offset 72) と exit 時刻 (offset 88) を返す ----------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
S = SafeRun
# uuid 16 byte の後に uint64 × 10: user, system, pkg_idle_wkups, interrupt_wkups, pageins, wired, resident, phys, start, exit
values = [101, 102, 103, 104, 105, 106, 107, 108, 109, 110]
buf = ("\xAA".b * 16) + values.pack("Q*")
check("rusage は 96 byte", buf.bytesize == 96)
decoded = S.decode_rusage(buf)
check("footprint は phys_footprint (resident_size ではない)", decoded[:footprint] == 108)
check("exit 時刻は proc_exit_abstime", decoded[:exit_abstime] == 110)
bad_size = begin
  S.decode_rusage(buf[0, 95])
  false
rescue ArgumentError
  true
end
check("大きさの違う buffer は拒否する", bad_size)
bsd = ("\x00".b * 100) + [4242].pack("L") + ("\x00".b * 32)
check("bsdinfo の pgid は offset 100", S.decode_bsdinfo_pgid(bsd) == 4242)
check("上限の範囲", S::FOOTPRINT_RANGE == (1..1_048_576) && S::SECONDS_RANGE == (1..86_400))
check("巡回 0.25 秒・incomplete 3 回・猶予 2 秒", S::INTERVAL == 0.25 && S::INCOMPLETE_LIMIT == 3 && S::GRACE_SECONDS == 2.0)
check("中断として受ける signal", S::TRAPPED_SIGNALS == %w[INT TERM HUP QUIT TSTP])
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- case 2: 動いている process の phys_footprint を script の計測と footprint CLI で比べて一致 (offset の回帰) ---
# 全体を harness の期限つきで走らせ (fixture の pgid は cli.pgid に書く)、CLI も 1 回ごとに期限で止めて回収する。
cat > "$tmp/cli-check.rb" <<'RUBY'
load ARGV[0]
S = SafeRun

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# argv を起動し、期限までに終われば出力 (stdout と stderr) を、終わらなければ KILL して回収し nil を返す。
def run_cli(argv, seconds)
  r, w = IO.pipe
  pid = Process.spawn(*argv, out: w, err: w, in: File::NULL)
  w.close
  out = String.new
  deadline = now + seconds
  loop do
    left = deadline - now
    if left <= 0
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid)
      return nil
    end
    next unless IO.select([r], nil, nil, left)

    chunk = r.read_nonblock(65_536, exception: false)
    next if chunk == :wait_readable
    break if chunk.nil?

    out << chunk
  end
  Process.wait(pid)
  out
ensure
  r.close
end

S.load_libproc
r, w = IO.pipe
pid = Process.spawn("ruby", "-e", 'held = "x" * (40 * 1024 * 1024); STDOUT.puts "ready"; STDOUT.flush; sleep 20; held.size',
                    out: w, pgroup: true)
w.close
File.write(ARGV[1], "#{pid}\n")
begin
  check("fixture が ready を出す", IO.select([r], nil, nil, 15) && r.gets == "ready\n")
  matched = false
  seen = []
  5.times do
    before = S.member_state(pid, pid)
    cli = run_cli(["/usr/bin/footprint", "--noCategories", "-f", "bytes", "-p", pid.to_s], 15)
    after = S.member_state(pid, pid)
    value = cli && cli[/^\s*phys_footprint: (\d+) B$/, 1]
    seen << [before, cli.nil? ? :timeout : value, after]
    next if value.nil?

    if [before, after].include?([:alive, Integer(value)])
      matched = true
      break
    end
  end
  check("script の phys_footprint が footprint CLI の phys_footprint と一致する: #{seen.inspect}", matched)
  check("40 MiB の確保が乗っている", seen.last[0][1].to_i > 40 * 1024 * 1024)
ensure
  Process.kill("KILL", -pid) rescue nil
  Process.wait(pid)
end
exit(@failed.zero? ? 0 : 1)
RUBY
run_case cli 120 -- ruby -r"$script_dir/lib/check_helper" "$tmp/cli-check.rb" "$src" "$tmp/cli.pgid"
expect_exit cli 0

# ---- case 3: usage と前提の誤り → exit 2、command を起動せず、report を書かない -------------------------------
marker="$tmp/usage-marker"
printf 'old report\n' > "$tmp/existing.json"
ln -s "$tmp/no-such-target" "$tmp/dangling.json"
# expect_usage <label> <理由の文言> <safe-run の引数...>: command は marker を作る sh
expect_usage() {
  eu_label=$1
  eu_reason=$2
  shift 2
  eu_status=0
  "$sr" "$@" </dev/null >"$tmp/usage.out" 2>"$tmp/usage.err" || eu_status=$?
  [ "$eu_status" -eq 2 ] || fail "usage $eu_label: should exit 2, got $eu_status: $(cat "$tmp/usage.err")"
  [ ! -e "$marker" ] || fail "usage $eu_label: the command must not start"
  [ ! -e "$tmp/usage-report.json" ] || fail "usage $eu_label: the report must not be written"
  [ ! -s "$tmp/usage.out" ] || fail "usage $eu_label: stdout must be empty"
  grep -qF -- "$eu_reason" "$tmp/usage.err" || fail "usage $eu_label: stderr should say '$eu_reason': $(cat "$tmp/usage.err")"
  if grep -v '^personal-safe-run: ' "$tmp/usage.err" >/dev/null; then
    fail "usage $eu_label: stderr must hold only personal-safe-run: lines: $(cat "$tmp/usage.err")"
  fi
}
# command は起動されたら marker を作る (sh -c の $0 に marker の path を渡す)
mk=': > "$0"'
expect_usage "no footprint" "--max-footprint-mb は必須です" --max-seconds 5 --report "$tmp/usage-report.json" -- sh -c "$mk" "$marker"
expect_usage "no seconds" "--max-seconds は必須です" --max-footprint-mb 10 --report "$tmp/usage-report.json" -- sh -c "$mk" "$marker"
for bad in abc 0 -1 1.5 01 1048577 ""; do
  expect_usage "footprint '$bad'" "--max-footprint-mb は 1〜1048576 の整数です" --max-footprint-mb "$bad" --max-seconds 5 -- sh -c "$mk" "$marker"
done
for bad in abc 0 86401; do
  expect_usage "seconds '$bad'" "--max-seconds は 1〜86400 の整数です" --max-footprint-mb 10 --max-seconds "$bad" -- sh -c "$mk" "$marker"
done
expect_usage "no --" "-- と command がありません" --max-footprint-mb 10 --max-seconds 5 sh -c "$mk" "$marker"
expect_usage "empty command" "-- の後に command がありません" --max-footprint-mb 10 --max-seconds 5 --
expect_usage "unknown option" "知らない option です" --max-footprint-mb 10 --max-seconds 5 --verbose 1 -- sh -c "$mk" "$marker"
expect_usage "duplicate" "--max-seconds が 2 回あります" --max-footprint-mb 10 --max-seconds 5 --max-seconds 6 -- sh -c "$mk" "$marker"
expect_usage "missing value" "--max-seconds に値がありません" --max-footprint-mb 10 --max-seconds -- sh -c "$mk" "$marker"
expect_usage "empty report" "--report の値が空です" --max-footprint-mb 10 --max-seconds 5 --report "" -- sh -c "$mk" "$marker"
expect_usage "report exists" "--report の file が既に在ります" --max-footprint-mb 10 --max-seconds 5 --report "$tmp/existing.json" -- sh -c "$mk" "$marker"
[ "$(cat "$tmp/existing.json")" = "old report" ] || fail "usage: an existing report must stay as it was"
expect_usage "report is a dangling symlink" "--report の file が既に在ります" --max-footprint-mb 10 --max-seconds 5 --report "$tmp/dangling.json" -- sh -c "$mk" "$marker"
[ ! -e "$tmp/no-such-target" ] || fail "usage: nothing may be written through a symlink"
expect_usage "report dir missing" "--report の親 directory がありません" --max-footprint-mb 10 --max-seconds 5 --report "$tmp/no-dir/r.json" -- sh -c "$mk" "$marker"
# --help は usage を stdout に出して 0
"$sr" --help > "$tmp/help.out" || fail "--help should exit 0"
grep -q '^usage: personal-safe-run --max-footprint-mb N --max-seconds N \[--report FILE\] -- <command> \[args...\]$' "$tmp/help.out" \
  || fail "--help should print the usage line: $(cat "$tmp/help.out")"

# ---- case 4: 起動できない → 127 / 126、report は command_started: false --------------------------------------
run_case nf 20 -- "$sr" --max-footprint-mb 10 --max-seconds 5 --report "$tmp/nf.json" -- no-such-command-466
expect_exit nf 127
expect_report nf command_started=false 'reason=nil' exit_status=127 'command_exit=nil' 'command_signal=nil' \
  'peak_footprint_mib=nil' leftover_killed=0 cleanup_complete=true
expect_err_has nf "personal-safe-run: command を起動できません (Errno::ENOENT)"
printf '#!/bin/sh\nexit 0\n' > "$tmp/not-executable"
chmod 644 "$tmp/not-executable"
run_case nx 20 -- "$sr" --max-footprint-mb 10 --max-seconds 5 --report "$tmp/nx.json" -- "$tmp/not-executable"
expect_exit nx 126
expect_report nx command_started=false exit_status=126 'reason=nil'
run_case ndir 20 -- "$sr" --max-footprint-mb 10 --max-seconds 5 -- "$tmp"
expect_exit ndir 126

# ---- case 5: 透過。exit code、stdout / stderr、argv (空白・shell の特殊文字・空・--)、stdin ---------------------
run_case ok 20 -- "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/ok.json" -- true
expect_exit ok 0
expect_report ok command_started=true 'reason=nil' 'signal=nil' exit_status=0 command_exit=0 'command_signal=nil' \
  leftover_killed=0 cleanup_complete=true 'elapsed_seconds<5'
[ ! -s "$tmp/ok.err" ] || fail "ok: stderr must be empty when nothing happens: $(cat "$tmp/ok.err")"
run_case three 20 -- "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/three.json" \
  -- sh -c 'printf "out\n"; printf "err\n" >&2; exit 3'
expect_exit three 3
expect_report three 'reason=nil' exit_status=3 command_exit=3
[ "$(cat "$tmp/three.out")" = out ] || fail "three: stdout should pass through: $(cat "$tmp/three.out")"
# stderr は command の分だけ (Ruby や Fiddle の警告が出ればここで落ちる)
[ "$(cat "$tmp/three.err")" = err ] || fail "three: stderr should hold only the command's line: $(cat "$tmp/three.err")"
printf '%s\n' 'a b' '$(echo x)' "'q'" '*' '' '-- x' '--' > "$tmp/args.expected"
run_case args 20 -- "$sr" --max-footprint-mb 100 --max-seconds 10 -- printf '%s\n' 'a b' '$(echo x)' "'q'" '*' '' '-- x' '--'
expect_exit args 0
cmp -s "$tmp/args.expected" "$tmp/args.out" || fail "args: argv must reach the command as is: $(cat "$tmp/args.out")"
printf 'line 1\nline 2\n' > "$tmp/stdin.txt"
run_case stdin 20 --stdin "$tmp/stdin.txt" -- "$sr" --max-footprint-mb 100 --max-seconds 10 -- cat
expect_exit stdin 0
cmp -s "$tmp/stdin.txt" "$tmp/stdin.out" || fail "stdin: a file on stdin should pass through: $(cat "$tmp/stdin.out")"
run_case selfkill 20 -- "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/selfkill.json" -- sh -c 'kill -TERM $$'
expect_exit selfkill 143
expect_report selfkill 'reason=nil' exit_status=143 'command_exit=nil' command_signal=15

# ---- case 6: 時間の上限。TERM を無視する子と孫 → KILL まで進んで 137、group が空、数秒で終わる ---------------------
run_case time 30 -- "$sr" --max-footprint-mb 100 --max-seconds 1 --report "$tmp/time.json" \
  -- sh "$tmp/fx-ignore-term.sh" "$tmp/time.pgid"
expect_exit time 137
expect_report time 'reason="time"' 'signal=nil' exit_status=137 command_signal=9 'command_exit=nil' leftover_killed=0 \
  cleanup_complete=true 'elapsed_seconds>0.99' 'elapsed_seconds<2'
expect_group_gone time
expect_err_has time "personal-safe-run: stopped (reason=time)"
expect_err_only_prefixed time
ruby -e 'exit(Float(ARGV[0]) < 8 ? 0 : 1)' "$elapsed" || fail "time: should finish within a few seconds, took $elapsed"

# ---- case 7: footprint の上限 (受け入れ条件 1)。node --test の子の子が確保 → 137、group が空 -------------------
# 対照: 確保しない同じ fixture は同じ上限で exit 0 (node の基準の footprint は上限より下)
run_case nodebase 60 -- env ALLOC_STEP_MIB=64 ALLOC_MAX_MIB=0 ALLOC_LIFE_MS=1000 \
  "$sr" --max-footprint-mb 192 --max-seconds 40 --report "$tmp/nodebase.json" \
  -- sh "$tmp/fx-node.sh" "$tmp/nodebase.pgid" "$tmp/node/alloc.test.mjs"
expect_exit nodebase 0
expect_report nodebase 'reason=nil' 'peak_footprint_mib<192' 'peak_footprint_mib>1'
expect_group_gone nodebase
run_case node 60 -- env ALLOC_STEP_MIB=64 ALLOC_MAX_MIB=384 ALLOC_LIFE_MS=20000 \
  "$sr" --max-footprint-mb 192 --max-seconds 40 --report "$tmp/node.json" \
  -- sh "$tmp/fx-node.sh" "$tmp/node.pgid" "$tmp/node/alloc.test.mjs"
expect_exit node 137
expect_report node 'reason="footprint"' exit_status=137 'peak_footprint_mib>192' cleanup_complete=true
expect_group_gone node
expect_err_has node "personal-safe-run: stopped (reason=footprint)"

# ---- case 8: group の合計。3 つの子はそれぞれ上限未満、合計が上限超え → footprint -------------------------------
# 対照: 子 1 つ (同じ確保量) は同じ上限で止まらない
run_case single 30 -- "$sr" --max-footprint-mb 120 --max-seconds 20 --report "$tmp/single.json" \
  -- sh -c 'echo $$ > "$0"; exec ruby "$1" 48 1.5' "$tmp/single.pgid" "$tmp/fx-alloc.rb"
expect_exit single 0
expect_report single 'reason=nil' 'peak_footprint_mib>48' 'peak_footprint_mib<120'
run_case group 30 -- "$sr" --max-footprint-mb 120 --max-seconds 20 --report "$tmp/group.json" \
  -- sh "$tmp/fx-group.sh" "$tmp/group.pgid" "$tmp/fx-alloc.rb" 48 20
expect_exit group 137
expect_report group 'reason="footprint"' 'peak_footprint_mib>120' cleanup_complete=true
expect_group_gone group

# ---- case 9: 残り。leader が sleep 300 の孫を残して exit 0 → exit 0、warning、leftover_killed 1、孫が消える -------
run_case left 30 -- "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/left.json" \
  -- sh "$tmp/fx-leftover.sh" "$tmp/left.pgid" "$tmp/left.gc"
expect_exit left 0
expect_report left 'reason=nil' exit_status=0 command_exit=0 leftover_killed=1 cleanup_complete=true
expect_err_has left "personal-safe-run: warning: command の終了後に残っていた process 1 個を止めました"
expect_group_gone left
gc=$(cat "$tmp/left.gc")
if kill -0 "$gc" 2>/dev/null; then fail "left: the grandchild $gc must be gone"; fi
# 9b: TERM を受けても動き続ける残り → 猶予の間も leader は回収されずに zombie のまま (pgid を保持)、KILL まで進む
cat > "$tmp/probe-zombie.sh" <<SH
ps -o stat= -p "\$(cat $(shq "$tmp/left2.pgid"))" > $(shq "$tmp/left2.zombie") 2>&1 || :
SH
run_case left2 30 --at "$tmp/left2.got" "run:$tmp/probe-zombie.sh" -- "$sr" --max-footprint-mb 100 --max-seconds 20 \
  --report "$tmp/left2.json" -- sh "$tmp/fx-leftover-trap.sh" "$tmp/left2.pgid" "$tmp/left2.got" "$tmp/left2.ready" "$tmp/fx-trapper.sh"
expect_exit left2 0
[ "$done" -eq 1 ] || fail "left2: the probe should run while the leftover is in its grace period"
grep -q '^Z' "$tmp/left2.zombie" || fail "left2: the leader must stay an unreaped zombie during the cleanup: $(cat "$tmp/left2.zombie")"
expect_report left2 'reason=nil' command_exit=0 'leftover_killed>0' cleanup_complete=true
expect_group_gone left2

# ---- case 10: 中断。safe-run に TERM → 143 / TSTP → 146、group が空、reason interrupted --------------------------
run_case term 30 --at "$tmp/term.ready" TERM -- "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/term.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/term.pgid" "$tmp/term.ready" 300
expect_exit term 143
expect_report term 'reason="interrupted"' 'signal="TERM"' exit_status=143 command_signal=15 cleanup_complete=true
expect_group_gone term
expect_err_has term "personal-safe-run: stopped (reason=interrupted): SIGTERM"
expect_err_only_prefixed term
run_case tstp 30 --at "$tmp/tstp.ready" TSTP -- "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/tstp.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/tstp.pgid" "$tmp/tstp.ready" 300
expect_exit tstp 146
expect_report tstp 'reason="interrupted"' 'signal="TSTP"' exit_status=146 cleanup_complete=true
expect_group_gone tstp
# 10b: TERM の猶予中 (leader が TERM を受けた印の後) に 2 回目の TERM → 結果が同じで、猶予を延ばさない
run_case term2 30 --at "$tmp/term2.pgid" TERM --at "$tmp/term2.got" TERM -- "$sr" --max-footprint-mb 100 --max-seconds 20 \
  --report "$tmp/term2.json" -- sh "$tmp/fx-term-loop.sh" "$tmp/term2.pgid" "$tmp/term2.got"
expect_exit term2 143
[ "$done" -eq 2 ] || fail "term2: both signals should be sent (sent $done)"
expect_report term2 'reason="interrupted"' 'signal="TERM"' exit_status=143 command_signal=9 cleanup_complete=true
expect_group_gone term2
ruby -e 'exit(Float(ARGV[0]).between?(1.9, 4.5) ? 0 : 1)' "$since" || fail "term2: the grace must be 2s and not extended, took $since"
# 10c: 猶予中の 2 回目が別の signal (INT) でも、理由と exit code は最初の TERM のまま
run_case termint 30 --at "$tmp/termint.pgid" TERM --at "$tmp/termint.got" INT -- "$sr" --max-footprint-mb 100 --max-seconds 20 \
  --report "$tmp/termint.json" -- sh "$tmp/fx-term-loop.sh" "$tmp/termint.pgid" "$tmp/termint.got"
expect_exit termint 143
[ "$done" -eq 2 ] || fail "termint: both signals should be sent (sent $done)"
expect_report termint 'reason="interrupted"' 'signal="TERM"' exit_status=143
expect_group_gone termint
# 10d: 同じ巡回の間に TERM と INT が続けて届いても、handler は最初の TERM を上書きしない。注入で最初の巡回を
# 1.5 秒遅らせ、その間に 2 つを送る (巡回が先に TERM を拾って抜けると上書きを観測できないため)
run_case twosig 30 --at "$tmp/twosig.ready" TERM --at "$tmp/twosig.ready" INT \
  -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=delay-first "$sr" --max-footprint-mb 100 --max-seconds 20 \
  --report "$tmp/twosig.json" -- sh "$tmp/fx-sleep.sh" "$tmp/twosig.pgid" "$tmp/twosig.ready" 300
expect_exit twosig 143
[ "$done" -eq 2 ] || fail "twosig: both signals should be sent (sent $done)"
expect_err_has twosig "inject: delay-first"
expect_report twosig 'reason="interrupted"' 'signal="TERM"' exit_status=143 'elapsed_seconds>1.4'
expect_group_gone twosig

# ---- case 11: 終了と期限の競合。最初の巡回を 1.5 秒遅らせ、true を --max-seconds 1 → 終了を先に観測して exit 0 ----
run_case race 20 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=delay-first \
  "$sr" --max-footprint-mb 100 --max-seconds 1 --report "$tmp/race.json" -- true
expect_exit race 0
expect_err_has race "inject: delay-first"
expect_report race 'reason=nil' exit_status=0 command_exit=0 'elapsed_seconds>1'

# ---- case 12: 計測不能。leader 以外の proc_pid_rusage が EPERM / 列挙の失敗 → 3 巡回で 137、reason monitor --------
run_case eperm 30 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=eperm \
  "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/eperm.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/eperm.pgid" "$tmp/eperm.ready" 30
expect_exit eperm 137
[ "$(grep -c '^inject: eperm$' "$tmp/eperm.err")" -eq 3 ] || fail "eperm: exactly 3 incomplete rounds should stop it: $(cat "$tmp/eperm.err")"
expect_report eperm 'reason="monitor"' exit_status=137 'peak_footprint_mib=nil' cleanup_complete=true
expect_err_has eperm "personal-safe-run: stopped (reason=monitor)"
expect_group_gone eperm
# 12a: proc_listpids が 0 件を返す (libproc は syscall の失敗を 0 に変える)。leader の居ない列挙は失敗として扱い、
# 監視では 3 巡回で monitor、後始末では止まったと確定できないので cleanup_complete が false (最後の KILL で group は空)
run_case listzero 30 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=listpids-zero \
  "$sr" --max-footprint-mb 100 --max-seconds 5 --report "$tmp/listzero.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/listzero.pgid" "$tmp/listzero.ready" 30
expect_exit listzero 137
[ "$(grep -c '^inject: listpids-zero$' "$tmp/listzero.err")" -ge 3 ] || fail "listzero: the injection should hit: $(cat "$tmp/listzero.err")"
expect_report listzero 'reason="monitor"' exit_status=137 'peak_footprint_mib=nil' cleanup_complete=false
expect_err_has listzero "personal-safe-run: warning: process group を止め切れませんでした (cleanup incomplete)"
expect_group_gone listzero
# 対照: 注入なしの同じ fixture は monitor では止まらず、時間の上限で止まる
run_case noinject 30 -- "$sr" --max-footprint-mb 100 --max-seconds 1 --report "$tmp/noinject.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/noinject.pgid" "$tmp/noinject.ready" 30
expect_exit noinject 137
expect_report noinject 'reason="time"' 'peak_footprint_mib>0'
expect_group_gone noinject
# 12b: 生きている member は pgid を確かめてから足す (列挙の後に pid が別 group の process に再利用されたら数えない)。
# 注入で leader 以外を別 group に見せると、子の確保は合計に入らず止まらない。対照: 注入なしでは同じ子で止まる
run_case foreign 30 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=foreign-pgid \
  "$sr" --max-footprint-mb 40 --max-seconds 20 --report "$tmp/foreign.json" \
  -- sh -c 'echo $$ > "$0"; ruby "$1" 48 1.5; exit 0' "$tmp/foreign.pgid" "$tmp/fx-alloc.rb"
expect_exit foreign 0
expect_err_has foreign "inject: foreign-pgid"
expect_report foreign 'reason=nil' command_exit=0 'peak_footprint_mib<40'
run_case foreignctl 30 -- "$sr" --max-footprint-mb 40 --max-seconds 20 --report "$tmp/foreignctl.json" \
  -- sh -c 'echo $$ > "$0"; ruby "$1" 48 1.5; exit 0' "$tmp/foreignctl.pgid" "$tmp/fx-alloc.rb"
expect_exit foreignctl 137
expect_report foreignctl 'reason="footprint"' 'peak_footprint_mib>40'
expect_group_gone foreignctl

# ---- case 13: 一部だけ回復。2 巡回 EPERM → 1 巡回成功の繰り返し → 連続回数が戻るので止まらない --------------------
run_case recover 30 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=eperm-recover \
  "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/recover.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/recover.pgid" "$tmp/recover.ready" 3
expect_exit recover 0
[ "$(grep -c '^inject: eperm$' "$tmp/recover.err")" -ge 4 ] || fail "recover: the injection should hit at least 2 cycles: $(cat "$tmp/recover.err")"
expect_report recover 'reason=nil' command_exit=0 'peak_footprint_mib>0'
expect_group_gone recover

# ---- case 14: report を書けない → warning、exit は変わらず、一時 file が残らない -----------------------------------
mkdir "$tmp/ro"
chmod 555 "$tmp/ro"
run_case ro 20 -- "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/ro/r.json" -- sh -c 'exit 4'
expect_exit ro 4
expect_err_has ro "personal-safe-run: warning: report を書けませんでした (Errno::EACCES)"
[ -z "$(ls -A "$tmp/ro")" ] || fail "ro: nothing may be left in the report dir: $(ls -A "$tmp/ro")"
chmod 755 "$tmp/ro"
# 14b: 一時 file は書けたが rename が失敗する (report の path に command が directory を作る) → 一時 file を消す
mkdir "$tmp/rdir"
run_case rdir 20 -- "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/rdir/r.json" -- mkdir "$tmp/rdir/r.json"
expect_exit rdir 0
expect_err_has rdir "personal-safe-run: warning: report を書けませんでした"
[ "$(ls -A "$tmp/rdir")" = r.json ] || fail "rdir: the temporary file must be removed: $(ls -A "$tmp/rdir")"
[ -d "$tmp/rdir/r.json" ] && [ -z "$(ls -A "$tmp/rdir/r.json")" ] || fail "rdir: the report must not be written into the directory"
# 14c: report は 0600
[ "$(stat -f %Lp "$tmp/ok.json")" = 600 ] || fail "report should be 0600: $(stat -f %Lp "$tmp/ok.json")"

# ---- case 15: tty。stdin が端末なら /dev/null に替える (背景の group が端末を読んで SIGTTIN で止まらない) ------------
run_case tty 30 --hold-stdin -- /usr/bin/script -q /dev/null "$sr" --max-footprint-mb 100 --max-seconds 5 \
  --report "$tmp/tty.json" -- cat
expect_report tty 'reason=nil' exit_status=0 command_exit=0 'elapsed_seconds<4'

# ---- case 16: SIGCHLD を無視する親から起動しても、leader の終了 status が伝わる ------------------------------------
run_case chld 20 -- perl -e '$SIG{CHLD} = "IGNORE"; exec { $ARGV[0] } @ARGV or die "exec: $!"' \
  "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/chld.json" -- sh -c 'sleep 0.5; exit 5'
expect_exit chld 5
expect_report chld 'reason=nil' exit_status=5 command_exit=5

# ---- case 17: 起動時に無視されていた signal (nohup の HUP) は無視のまま。HUP で止まらず、command も無視を継承する ----
run_case nohup 30 --at "$tmp/nohup.ready" HUP -- perl -e '$SIG{HUP} = "IGNORE"; exec { $ARGV[0] } @ARGV or die "exec: $!"' \
  "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/nohup.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/nohup.pgid" "$tmp/nohup.ready" 1.5
expect_exit nohup 0
[ "$done" -eq 1 ] || fail "nohup: HUP should be sent (sent $done)"
expect_report nohup 'reason=nil' command_exit=0
run_case nohupchild 20 -- perl -e '$SIG{HUP} = "IGNORE"; exec { $ARGV[0] } @ARGV or die "exec: $!"' \
  "$sr" --max-footprint-mb 100 --max-seconds 10 -- perl -e 'print defined $SIG{HUP} ? $SIG{HUP} : "default"'
expect_exit nohupchild 0
[ "$(cat "$tmp/nohupchild.out")" = IGNORE ] || fail "nohupchild: the command should inherit the ignored HUP: $(cat "$tmp/nohupchild.out")"
# 対照: 無視されていなければ HUP で中断して 129
run_case hup 30 --at "$tmp/hup.ready" HUP -- "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/hup.json" \
  -- sh "$tmp/fx-sleep.sh" "$tmp/hup.pgid" "$tmp/hup.ready" 300
expect_exit hup 129
expect_report hup 'reason="interrupted"' 'signal="HUP"' exit_status=129
expect_group_gone hup

# ---- case 18: 後始末の中の観測が例外を出しても、TERM を無視する子を KILL で止め、leader を回収し、report を書く --
run_case craise 30 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=cleanup-raise \
  "$sr" --max-footprint-mb 100 --max-seconds 1 --report "$tmp/craise.json" -- sh "$tmp/fx-ignore-term.sh" "$tmp/craise.pgid"
expect_exit craise 137
expect_err_has craise "inject: cleanup-raise"
expect_report craise 'reason="time"' exit_status=137 command_signal=9 cleanup_complete=false
expect_err_has craise "personal-safe-run: warning: 後始末の観測が例外を出しました (RuntimeError)"
expect_group_gone craise
ruby -e 'exit(Float(ARGV[0]) < 8 ? 0 : 1)' "$elapsed" || fail "craise: should finish within a few seconds, took $elapsed"

# ---- case 19: 後始末の列挙の直後に member が子を fork して自分は終わっても、最後の KILL でその子を止める -----------
run_case fork 30 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=fork-race \
  SAFE_RUN_INJECT_GO="$tmp/fork.go" SAFE_RUN_INJECT_CHILD="$tmp/fork.child" \
  "$sr" --max-footprint-mb 100 --max-seconds 20 --report "$tmp/fork.json" \
  -- sh "$tmp/fx-fork-leader.sh" "$tmp/fork.pgid" "$tmp/fork.go" "$tmp/fork.child" "$tmp/fork.ready" "$tmp/fx-forker.sh"
expect_exit fork 0
expect_err_has fork "inject: fork-race ready"
expect_report fork 'reason=nil' exit_status=0 command_exit=0 cleanup_complete=true 'leftover_killed<2'
expect_group_gone fork
forked=$(cat "$tmp/fork.child")
if kill -0 "$forked" 2>/dev/null; then fail "fork: the child forked after the listing ($forked) must be gone"; fi

# ---- case 20: self-pipe の close の境界で signal が届いても、exit と report が一致する ---------------------------
run_case closesig 20 -- env RUBYOPT="-r$tmp/inject.rb" SAFE_RUN_INJECT=close-signal \
  "$sr" --max-footprint-mb 100 --max-seconds 10 --report "$tmp/closesig.json" -- sh -c 'exit 6'
expect_exit closesig 6
expect_err_has closesig "inject: close-signal"
expect_report closesig 'reason=nil' exit_status=6 command_exit=6

# ---- case 21: stderr が読まれずに詰まっていても、group を止めて report を書き、期限内に終わる (診断は捨てる) -------
run_case stuck 15 --stuck-stderr -- "$sr" --max-footprint-mb 100 --max-seconds 1 --report "$tmp/stuck.json" \
  -- perl "$tmp/fx-flood.pl" "$tmp/stuck.pgid"
expect_exit stuck 137
expect_report stuck 'reason="time"' exit_status=137 cleanup_complete=true
expect_group_gone stuck
ruby -e 'exit(Float(ARGV[0]) < 8 ? 0 : 1)' "$elapsed" || fail "stuck: should finish within a few seconds, took $elapsed"

echo "ok: safe-run self-test passed"
