#!/bin/sh
# personal-ci-runner (#803 の PR 1) の self-test。偽の gh と docker を PATH の先頭に置き、本体を本物の Ruby で明示して起動する。
# 偽の gh は tmp の file で返事を切り替え、呼ばれた引数と stdin を記録する。偽の docker は、run の stdin と引数を記録し、
# 動いている間は印の file を置き、stop で止まる。case の ID は Issue #803 の PR 1 の期待値の表 (E01〜E30) と同じ番号。
# 実物の GitHub・docker・HOME には触れない。
# 引数で本体の source を差し替えられる (変異での確認用): <personal-ci-runner.rb>
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src=${1:-"$repo_root/shared/scripts/personal-ci-runner.rb"}
[ -f "$src" ] || fail "missing $src"
real_ruby=$(ruby -rrbconfig -e 'print RbConfig.ruby')

tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -m 700 "$tmp/conf" "$tmp/fake" "$tmp/gh" "$tmp/gh/runners" "$tmp/docker" "$tmp/home"
conf="$tmp/conf/ci-runner.json"
state="$tmp/state"
canary=Q0FOQVJZODAzSklUQ09ORklH
image="ghcr.io/actions/actions-runner@sha256:$(printf '%064d' 0 | tr 0 a)"

# ---- 偽の gh ----------------------------------------------------------------------------------------------------
# 呼び出しごとに結果を指定する (file の中身で選ぶ。無ければ ok):
#   mode-post: ok / fail (500・作られない) / fail-created (500 だが作られる) / hang (作ってから返らない) /
#              late (返らず、止められた後で作られる) / notfound (404)
#   post-body: normal / noid / runnerstring / otherid (返事の id が別の既存 runner を指す) / badcfg
#   mode-list: ok / fail / hang      mode-delete: ok / notfound / notfound-gone / fail
#   list-delay・delete-delay: 一覧・DELETE の前に待つ秒      vis-seq の hang は 90 秒返らない
#   mode-delete の fail-once: 1 回だけ失敗する      ignore-term: TERM を無視する (KILL でだけ止まる)
#   vis-seq: 呼び出しごとの公開範囲 (private / public / mixed / garbage / fail / hang)。最後の行を繰り返す
#   chmod-state-on-post: POST の後に state の dir を書けなくする (記録を消せない形)
# DELETE と POST の時刻を events.log に書く。
cat > "$tmp/fake/gh" <<EOF
#!$real_ruby
require "json"
dir = $(shq "$tmp/gh")
state = $(shq "$state")
mode = ->(name) { f = File.join(dir, name); File.exist?(f) ? File.read(f).strip : "ok" }
event = ->(text) { File.open(File.join(dir, "events.log"), "a") { |f| f.puts("#{Time.now.to_f} #{text}") } }
trap("TERM") {} if File.exist?(File.join(dir, "ignore-term"))
stdin = STDIN.read
File.open(File.join(dir, "argv.log"), "a") { |f| f.puts(JSON.generate(ARGV)) }
File.open(File.join(dir, "stdin.log"), "a") { |f| f.puts(stdin) } unless stdin.empty?
args = ARGV.dup
abort "fake gh: expected api" unless args.shift == "api"
abort "fake gh: expected --hostname github.com" unless args.shift(2) == ["--hostname", "github.com"]
method = "GET"
if args.first == "--method"
  args.shift
  method = args.shift
end
path = args.shift
def http_error(code, text)
  warn "gh: #{text} (HTTP #{code})"
  exit 1
end
runners = File.join(dir, "runners")
if method == "GET" && path.match?(%r{\Arepos/[^/]+/[^/]+\z})
  seq = File.join(dir, "vis-seq")
  kind = File.exist?(seq) ? File.readlines(seq, chomp: true) : ["private"]
  count_file = File.join(dir, "vis-count")
  n = File.exist?(count_file) ? File.read(count_file).to_i : 0
  File.write(count_file, (n + 1).to_s)
  k = kind[[n, kind.length - 1].min]
  full = File.exist?(File.join(dir, "full-name")) ? File.read(File.join(dir, "full-name")).strip : path.sub("repos/", "")
  case k
  when "private" then puts JSON.generate("full_name" => full, "private" => true, "visibility" => "private")
  when "public" then puts JSON.generate("full_name" => full, "private" => false, "visibility" => "public")
  when "mixed" then puts JSON.generate("full_name" => full, "private" => true, "visibility" => "public")
  when "garbage" then puts "not json"
  when "hang" then sleep 90
  else http_error(500, "Server Error")
  end
elsif method == "POST" && path.match?(%r{/actions/runners/generate-jitconfig\z})
  name = JSON.parse(stdin)["name"]
  event.call("POST")
  File.write(File.join(dir, "post-started"), "")
  case mode.call("mode-post")
  when "fail" then http_error(500, "Server Error")
  when "notfound" then http_error(404, "Not Found")
  when "fail-created"
    File.write(File.join(runners, "4242"), name)
    http_error(500, "Server Error")
  when "late"
    child = fork { sleep 3; File.write(File.join(runners, "4242"), name) }
    Process.detach(child)
    sleep 30
    exit 1
  when "hang"
    File.write(File.join(runners, "4242"), name)
    sleep 30
    exit 1
  end
  File.write(File.join(runners, "4242"), name)
  File.chmod(0o500, state) if File.exist?(File.join(dir, "chmod-state-on-post"))
  body = { "runner" => { "id" => 4242, "name" => name }, "encoded_jit_config" => $(shq "$canary") }
  case mode.call("post-body")
  when "noid" then body["runner"].delete("id")
  when "runnerstring" then body["runner"] = "oops"
  when "badcfg" then body["encoded_jit_config"] = "bad!cfg"
  when "otherid"
    File.write(File.join(runners, "5555"), "someone-else")
    body["runner"]["id"] = 5555
  end
  puts JSON.generate(body)
elsif method == "DELETE" && (m = path.match(%r{/actions/runners/(\d+)\z}))
  event.call("DELETE #{m[1]}")
  sleep File.read(File.join(dir, "delete-delay")).to_f if File.exist?(File.join(dir, "delete-delay"))
  case mode.call("mode-delete")
  when "fail" then http_error(500, "Server Error")
  when "fail-once"
    File.write(File.join(dir, "mode-delete"), "ok")
    http_error(500, "Server Error")
  when "hang-once"
    File.write(File.join(dir, "mode-delete"), "ok")
    sleep 30
    exit 1
  when "notfound" then http_error(404, "Not Found")
  when "notfound-gone"
    File.delete(File.join(runners, m[1])) if File.exist?(File.join(runners, m[1]))
    http_error(404, "Not Found")
  end
  file = File.join(runners, m[1])
  http_error(404, "Not Found") unless File.exist?(file)
  File.delete(file)
elsif method == "GET" && path.match?(%r{/actions/runners\?per_page=100\z})
  http_error(500, "Server Error") if mode.call("mode-list") == "fail"
  sleep 30 if mode.call("mode-list") == "hang"
  sleep File.read(File.join(dir, "list-delay")).to_f if File.exist?(File.join(dir, "list-delay"))
  # leak: 孫の process が stdout を持ったまま残る (親が終わっても、出力の pipe が閉じない)
  Process.detach(fork { sleep 30 }) if mode.call("mode-list") == "leak"
  list = Dir.children(runners).sort.map { |id| { "id" => id.to_i, "name" => File.read(File.join(runners, id)) } }
  puts JSON.generate([{ "total_count" => list.length, "runners" => list }])
else
  abort "fake gh: unexpected #{method} #{path}"
end
EOF

# ---- 偽の docker ------------------------------------------------------------------------------------------------
# run は stdin と state の写しを残し、run-seconds の間 (stop が来るまで) 動く。run-exit が 125 なら起動できない形。
# stop と kill は stop-fail の回数だけ失敗し、stop-hang があれば返らない。auto-remove があれば、終わったときに
# runner の登録を消す (job を終えた JIT の runner)。run の終わりの時刻を events.log に書く。動いている container の印は
# running-<名前> で、run が終わるときと stop・kill が成功したときに消える。run の client だけが終わると (KILL、client-drop)、
# 印は残る (container は動き続けている形)。
cat > "$tmp/fake/docker" <<EOF
#!$real_ruby
require "json"
require "fileutils"
dir = $(shq "$tmp/docker")
File.open(File.join(dir, "argv.log"), "a") { |f| f.puts(JSON.generate(ARGV)) }
args = ARGV.dup
abort "fake docker: expected --context" unless args.shift == "--context"
args.shift
case args.shift
when "run"
  name = args[args.index("--name") + 1]
  File.write(File.join(dir, "stdin-#{name}"), STDIN.read)
  state = $(shq "$state")
  FileUtils.cp_r(state, File.join(dir, "state-#{name}")) if File.directory?(state)
  code = File.exist?(File.join(dir, "run-exit")) ? File.read(File.join(dir, "run-exit")).to_i : 0
  exit code if code == 125
  running = File.join(dir, "running-#{name}")
  File.write(running, "")
  seconds = File.exist?(File.join(dir, "run-seconds")) ? File.read(File.join(dir, "run-seconds")).to_f : 0
  deadline = Time.now + seconds
  stop = File.join(dir, "stop-#{name}")
  # client-drop: 秒数の後に、client だけが signal でなく終わる (daemon との接続が切れた形)。動いている印は残す
  drop = File.join(dir, "client-drop")
  drop_at = File.exist?(drop) ? Time.now + File.read(drop).to_f : nil
  sleep 0.05 until Time.now >= deadline || File.exist?(stop) || (drop_at && Time.now >= drop_at)
  exit 125 if drop_at && Time.now >= drop_at && !File.exist?(stop)
  File.delete(running) if File.exist?(running)
  File.open(File.join(dir, "events.log"), "a") { |f| f.puts("#{Time.now.to_f} EXIT") }
  Dir.glob(File.join($(shq "$tmp/gh/runners"), "*")).each { |f| File.delete(f) } if File.exist?(File.join(dir, "auto-remove"))
  exit(File.exist?(stop) ? 143 : code)
when "ps"
  exit 1 if File.exist?(File.join(dir, "ps-fail"))
  filter = args[args.index("--filter") + 1]
  name = filter.sub("name=^/?", "").sub(/\\\$\z/, "")
  puts "c0ffee" if File.exist?(File.join(dir, "running-#{name}"))
when "stop", "kill"
  sleep 30 if File.exist?(File.join(dir, "stop-hang"))
  fail_file = File.join(dir, "stop-fail")
  left = File.exist?(fail_file) ? File.read(fail_file).to_i : 0
  if left.positive?
    File.write(fail_file, (left - 1).to_s)
    warn "fake docker: cannot stop"
    exit 1
  end
  # 本物の docker stop は、container が止まってから返る。client (run) が居なくても、動いている印を外す
  File.write(File.join(dir, "stop-#{args.last}"), "")
  begin
    File.delete(File.join(dir, "running-#{args.last}"))
  rescue Errno::ENOENT
    nil
  end
else
  abort "fake docker: unexpected"
end
EOF
chmod +x "$tmp/fake/gh" "$tmp/fake/docker"

write_conf() { # $1=Ruby の式 (ARGV[0] は image)。設定を書いて 0600 にする
  ruby -rjson -e "File.write(ARGV[1], JSON.generate(($1)))" -- "$image" "$conf"
  chmod 600 "$conf"
}
good_conf='{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => ["kosako/prism"] }'
reset() {
  rm -rf "$state" "$tmp/gh" "$tmp/docker"
  mkdir -m 700 "$tmp/gh" "$tmp/gh/runners" "$tmp/docker"
  write_conf "$good_conf"
}
# 本体を起動する。stdout を $tmp/out、stderr を $tmp/err に書き、exit を $rc に入れる
run() {
  rc=0
  env PATH="$tmp/fake:$PATH" HOME="$tmp/home" AGENT_TOOLS_CI_RUNNER_CONFIG="$conf" AGENT_TOOLS_CI_RUNNER_STATE_DIR="$state" \
    AGENT_TOOLS_CI_RUNNER_POLL_SECONDS="${poll:-40}" GH_REPO= GH_HOST= \
    "$real_ruby" "$src" "$@" > "$tmp/out" 2> "$tmp/err" < /dev/null || rc=$?
}
expect_rc() { # $1=期待する exit  $2=case
  [ "$rc" -eq "$1" ] || fail "$2: expected exit $1, got $rc (out: $(cat "$tmp/out"); err: $(cat "$tmp/err"))"
}
calls() { # $1=偽の gh か docker の dir。記録された呼び出しの数
  if [ -f "$1/argv.log" ]; then grep -c '' "$1/argv.log"; else echo 0; fi
}
posted() {
  [ -f "$tmp/gh/argv.log" ] && grep -F -e '"POST"' "$tmp/gh/argv.log" >/dev/null
}
docker_ran() {
  [ -f "$tmp/docker/argv.log" ] && grep -F -e '"run"' "$tmp/docker/argv.log" >/dev/null
}
no_canary_outside() { # $1=case。JIT の設定が、出力・docker の引数・state の写しに出ていない
  for f in "$tmp/out" "$tmp/err" "$tmp/docker/argv.log"; do
    if [ -f "$f" ] && grep -F -e "$canary" "$f" >/dev/null; then fail "$1: the JIT config leaked into $(basename "$f")"; fi
  done
  for d in "$tmp"/docker/state-*; do
    [ -d "$d" ] || continue
    if grep -rF -e "$canary" "$d" >/dev/null; then fail "$1: the JIT config leaked into the state"; fi
  done
}

# ---- E01: GH_REPO / GH_HOST ----------------------------------------------------------------------------------------
reset
for name in GH_REPO GH_HOST; do
  rc=0
  env PATH="$tmp/fake:$PATH" HOME="$tmp/home" AGENT_TOOLS_CI_RUNNER_CONFIG="$conf" AGENT_TOOLS_CI_RUNNER_STATE_DIR="$state" \
    "$name=x" "$real_ruby" "$src" check > "$tmp/out" 2> "$tmp/err" < /dev/null || rc=$?
  expect_rc 2 "E01 $name"
  [ "$(calls "$tmp/gh")" -eq 0 ] || fail "E01 $name: gh must not be called"
done

# ---- 設定の検査 (E02〜E08 と決めたこと) ---------------------------------------------------------------------------
reset
rm -f "$conf"
run check
expect_rc 2 "E02"
case $(cat "$tmp/err") in *"設定がありません"*) ;; *) fail "E02: must say the config is missing" ;; esac

bad_conf() { # $1=Ruby の式  $2=case
  reset
  write_conf "$1"
  run check
  expect_rc 2 "$2"
  [ "$(calls "$tmp/gh")" -eq 0 ] || fail "$2: gh must not be called for a bad config"
}
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => ["kosako/prism"], "extra" => 1 }' "E03 unknown key"
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "repos" => ["kosako/prism"] }' "missing key"
for v in '"2"' '2.0' 'true' '0' '17'; do
  bad_conf "{ \"docker_context\" => \"colima-ci\", \"image\" => ARGV[0], \"cpus\" => $v, \"memory_mb\" => 4096, \"pids\" => 1024, \"repos\" => [\"kosako/prism\"] }" "E04/E05 cpus=$v"
done
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 511, "pids" => 1024, "repos" => ["kosako/prism"] }' "E05 memory_mb=511"
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "pids" => 65537, "repos" => ["kosako/prism"] }' "E05 pids=65537"
bad_conf '{ "docker_context" => "colima-ci", "image" => "ghcr.io/actions/actions-runner:latest", "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => ["kosako/prism"] }' "E06 tag"
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0].sub("ghcr.io/actions", "ghcr.io/other"), "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => ["kosako/prism"] }' "E06 other image"
for r in '"prism"' '"-x/prism"' '"kosako/.."' '"kosako/prism/extra"'; do
  bad_conf "{ \"docker_context\" => \"colima-ci\", \"image\" => ARGV[0], \"cpus\" => 2, \"memory_mb\" => 4096, \"pids\" => 1024, \"repos\" => [$r] }" "E07 repo=$r"
done
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => [] }' "empty repos"
bad_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => ["kosako/prism", "Kosako/Prism"] }' "duplicate repos"
bad_conf '{ "docker_context" => "-bad", "image" => ARGV[0], "cpus" => 2, "memory_mb" => 4096, "pids" => 1024, "repos" => ["kosako/prism"] }' "bad context"
# 境界の値は受ける
reset
write_conf '{ "docker_context" => "colima-ci", "image" => ARGV[0], "cpus" => 16, "memory_mb" => 512, "pids" => 64, "repos" => ["kosako/prism"] }'
run check
expect_rc 0 "E05 boundaries"
# key の重なり
reset
printf '{"docker_context":"a","docker_context":"b","image":"%s","cpus":2,"memory_mb":4096,"pids":1024,"repos":["kosako/prism"]}' "$image" > "$conf"
chmod 600 "$conf"
run check
expect_rc 2 "duplicate key"
# E08: symlink、group が書ける file、親の directory が group に書ける、大きすぎる
reset
mv "$conf" "$tmp/conf/real.json"
ln -s "$tmp/conf/real.json" "$conf"
run check
expect_rc 2 "E08 symlink"
rm -f "$conf"
mv "$tmp/conf/real.json" "$conf"
chmod 620 "$conf"
run check
expect_rc 2 "group-writable config"
chmod 600 "$conf"
chmod 770 "$tmp/conf"
run check
expect_rc 2 "group-writable parent"
chmod 700 "$tmp/conf"
# 正しい設定の後ろに空白を足して 64 KiB を超える (JSON としては読める。大きさの検査だけが止める)
ruby -e 'File.write(ARGV[0], File.read(ARGV[0]) + " " * (64 * 1024))' -- "$conf"
run check
expect_rc 2 "too large"
case $(cat "$tmp/err") in *"大きすぎます"*) ;; *) fail "too large: must be refused for its size: $(cat "$tmp/err")" ;; esac

# ---- check (E09〜E11) -----------------------------------------------------------------------------------------------
reset
run check
expect_rc 0 "E09"
[ "$(cat "$tmp/out")" = "kosako/prism private" ] || fail "E09: unexpected output: $(cat "$tmp/out")"
[ "$(calls "$tmp/docker")" -eq 0 ] && ! posted || fail "E09: check must not create a runner"
for kind in public mixed garbage fail; do
  reset
  printf '%s\n' "$kind" > "$tmp/gh/vis-seq"
  run check
  expect_rc 1 "E10/E11 $kind"
  expected=unknown
  [ "$kind" = public ] && expected=public
  [ "$(cat "$tmp/out")" = "kosako/prism $expected" ] || fail "E10/E11 $kind: unexpected output: $(cat "$tmp/out")"
  if grep -F -e "HTTP 500" "$tmp/out" "$tmp/err" >/dev/null; then fail "E11 $kind: the gh error body must not be printed"; fi
done

# ---- once が runner を作らない場合 (E12〜E15) ---------------------------------------------------------------------
reset
run once kosako/other
expect_rc 2 "E12"
[ "$(calls "$tmp/gh")" -eq 0 ] || fail "E12: gh must not be called for an unlisted repo"
for kind in public garbage fail; do
  reset
  printf '%s\n' "$kind" > "$tmp/gh/vis-seq"
  run once kosako/prism
  expect_rc 1 "E13/E14 $kind"
  ! posted || fail "E13/E14 $kind: no JIT runner may be created"
  ! docker_ran || fail "E13/E14 $kind: no container may start"
done
# E15: API の full_name が設定の名前と違う (rename の後の redirect)
reset
printf 'kosako/prism-renamed\n' > "$tmp/gh/full-name"
run once kosako/prism
expect_rc 1 "E15"
! posted || fail "E15: a renamed repo must not get a runner"
# 大文字小文字だけの違いは同じ repo として扱う
reset
printf 'Kosako/Prism\n' > "$tmp/gh/full-name"
run check
expect_rc 0 "E15 case"

# ---- 通常の once (E17・E19・E21・E23・E24) -------------------------------------------------------------------------
reset
run once kosako/prism
expect_rc 0 "E17"
body=$(cat "$tmp/gh/stdin.log")
printf '%s' "$body" | ruby -rjson -e '
  b = JSON.parse(STDIN.read)
  abort "E17: bad body #{b}" unless b["runner_group_id"] == 1 && b["labels"] == %w[self-hosted linux arm64] && b["name"].match?(/\Aagent-tools-ci-[0-9a-f]{16}\z/)
' || fail "E17: the JIT request body"
name=$(printf '%s' "$body" | ruby -rjson -e 'print JSON.parse(STDIN.read)["name"]')
# E23: JIT の設定は container の stdin の 1 行で届く
[ "$(cat "$tmp/docker/stdin-$name")" = "$canary" ] || fail "E23: the JIT config must arrive on stdin"
# E21: docker の引数
ruby -rjson -e '
  line = File.readlines(ARGV[0]).map { |l| JSON.parse(l) }.find { |a| a[2] == "run" }
  need = [["--context", "colima-ci"], ["--rm"], ["-i"], ["--cpus", "2"], ["--memory", "4096m"], ["--memory-swap", "4096m"],
          ["--pids-limit", "1024"], ["--security-opt", "no-new-privileges"], ["--cap-drop", "ALL"],
          ["--label", "agent-tools.ci-runner=kosako/prism"], [ARGV[1]]]
  need.each { |n| abort "E21: missing #{n.inspect}" unless line.each_cons(n.length).include?(n) }
  %w[-v --volume --mount --privileged --network --env -e --env-file].each { |f| abort "E21: forbidden #{f}" if line.include?(f) }
  abort "E21: docker.sock must not appear" if line.any? { |a| a.include?("docker.sock") }
  abort "E21: the inner shell must read stdin into the env" unless line.last.include?("ACTIONS_RUNNER_INPUT_JITCONFIG") && line.last.include?("exec ./run.sh")
  abort "E21: run.sh must not take --jitconfig" if line.any? { |a| a.include?("--jitconfig") }
' -- "$tmp/docker/argv.log" "$image" || fail "E21: docker arguments"
# E19: 記録は POST の前に 1 回だけ書く 4 つの key だけ。0600、dir は 0700
snap="$tmp/docker/state-$name"
ruby -rjson -e '
  f = File.join(ARGV[0], "#{ARGV[1]}.json")
  r = JSON.parse(File.read(f))
  abort "E19: keys #{r.keys.sort}" unless r.keys.sort == %w[container created_at name repo]
  abort "E19: created_at must be an integer" unless r["created_at"].is_a?(Integer)
  abort "E19: the record must be 0600" unless (File.stat(f).mode & 0o777) == 0o600
' -- "$snap" "$name" || fail "E19: the record shape"
[ "$(ruby -e 'printf("%o", File.stat(ARGV[0]).mode & 0o777)' -- "$state")" = 700 ] || fail "E19: the state dir must be 0700"
no_canary_outside "E24"
[ ! -e "$tmp/gh/runners/4242" ] || fail "E26: the registration must be deleted"
[ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "E26: the record must be removed"

# 形の違う JIT の設定は container に渡さない
reset
printf 'badcfg\n' > "$tmp/gh/post-body"
run once kosako/prism
expect_rc 1 "bad jit"
! docker_ran || fail "bad jit: no container may start"
[ ! -e "$tmp/gh/runners/4242" ] || fail "bad jit: the registration must be deleted"

# E30: 同じ repo の once を 2 つ
# 検知の期限を 10 秒、あきらめを 4 秒にして once を流す (load して定数を替える。時間の case 用)
short_main='load ARGV.shift
{ STOP_GIVE_UP_SECONDS: 10, ABANDON_SECONDS: 4 }.each { |k, v| CiRunner.send(:remove_const, k); CiRunner.const_set(k, v) }
exit CiRunner.main(ARGV)'
# 背景で once を起動する。$1=待つもの (running / post / none)。short=1 なら期限を短くする。main_script があれば、それを
# ruby -e で流す (helper を差し替える case 用。ARGV の先頭が本体の path)
start_once() {
  if [ -n "${main_script:-}" ]; then set -- "$1" -e "$main_script" -- "$src"
  elif [ "${short:-0}" = 1 ]; then set -- "$1" -e "$short_main" -- "$src"
  else set -- "$1" "$src"; fi
  wait_for=$1
  shift
  env PATH="$tmp/fake:$PATH" HOME="$tmp/home" AGENT_TOOLS_CI_RUNNER_CONFIG="$conf" AGENT_TOOLS_CI_RUNNER_STATE_DIR="$state" \
    AGENT_TOOLS_CI_RUNNER_POLL_SECONDS="${poll:-40}" GH_REPO= GH_HOST= \
    "$real_ruby" "$@" once kosako/prism > "$tmp/out" 2> "$tmp/err" < /dev/null &
  bg=$!
  set -- "$wait_for"
  i=0
  while :; do
    case $1 in
      running) ls "$tmp/docker" | grep -q '^running-' && break ;;
      post) [ -e "$tmp/gh/post-started" ] && break ;;
      vis2) [ "$(cat "$tmp/gh/vis-count" 2>/dev/null || true)" = 2 ] && break ;;
      none) break ;;
    esac
    i=$((i + 1))
    [ "$i" -lt 400 ] || fail "the background once did not reach $1"
    sleep 0.05
  done
}
wait_bg() {
  rc=0
  wait "$bg" || rc=$?
}
reset
printf '30\n' > "$tmp/docker/run-seconds"
start_once running
bg_first=$bg
run once kosako/prism
expect_rc 3 "E30"
[ "$(grep -c '"POST"' "$tmp/gh/argv.log")" -eq 1 ] || fail "E30: the second once must not create a runner"
bg=$bg_first
kill -TERM "$bg"
wait_bg

# ---- 組の表 (呼び出し × 結果) ------------------------------------------------------------------------------------------
# どの case の後にも、遅れて効く偽の子を待ってから、同じ検査をかける:
# - 偽の GitHub に agent-tools-ci- の runner が残っていれば、その名前の記録も残っている
# - 偽の docker に動いている container が残っていれば、その名前の記録も残っている
# - 偽の gh と docker の process が残っていない
# - TERM を送った case では、once が期限のうちに戻った (検知 + 60 秒。期限を短くした case は 10 秒。余裕を 3 秒ほど)
# - そのあと、全部を成功にし、残った container を人が止めたことにし、記録を 10 分より前に作ったことにして cleanup を
#   流すと、runner も記録も残らない
invariant() { # $1=case
  ruby -rjson -e '
    runners = Dir.children(ARGV[0]).map { |id| File.read(File.join(ARGV[0], id)) }.select { |n| n.start_with?("agent-tools-ci-") }
    running = Dir.children(ARGV[3]).grep(/\Arunning-/).map { |f| f.sub(/\Arunning-/, "") }
    records = File.directory?(ARGV[1]) ? Dir.children(ARGV[1]).grep(/\.json\z/).map { |f| f.sub(/\.json\z/, "") } : []
    missing = runners - records
    abort "#{ARGV[2]}: a runner is left without a record: #{missing}" unless missing.empty?
    alive = running - records
    abort "#{ARGV[2]}: a container is left without a record: #{alive}" unless alive.empty?
  ' -- "$tmp/gh/runners" "$state" "$1" "$tmp/docker" || fail "$1: invariant"
  i=0
  while pgrep -f -- "$tmp/fake/" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "$1: fake gh or docker processes are left: $(pgrep -lf -- "$tmp/fake/" | tr '\n' ' ')"
    sleep 0.05
  done
}
converge() { # $1=case
  rm -f "$tmp/gh"/mode-* "$tmp/gh/post-body" "$tmp/gh/vis-seq" "$tmp/gh/chmod-state-on-post" "$tmp/gh/list-delay" \
    "$tmp/gh/delete-delay" "$tmp/docker/stop-fail" "$tmp/docker/stop-hang" "$tmp/docker/ps-fail" "$tmp/docker"/running-*
  [ -d "$state" ] && chmod 700 "$state"
  for f in "$state"/agent-tools-ci-*.json; do
    [ -f "$f" ] || continue
    ruby -rjson -e 'r = JSON.parse(File.read(ARGV[0])); r["created_at"] -= 3600; File.write(ARGV[0], JSON.generate(r))' -- "$f"
  done
  run cleanup
  expect_rc 0 "$1 converge"
  left=$(ls "$tmp/gh/runners" | while read -r id; do cat "$tmp/gh/runners/$id"; echo; done | grep -c '^agent-tools-ci-' || true)
  [ "$left" -eq 0 ] || fail "$1 converge: runners are left"
  [ -z "$(ls "$state" 2>/dev/null | grep '\.json$' || true)" ] || fail "$1 converge: records are left"
}
now_s() { ruby -e 'print Process.clock_gettime(Process::CLOCK_MONOTONIC)'; }
# case を流す。$1=case 名  $2=TERM の時機 (none / post / running)  $3=遅れて効く偽の子を待つ秒
# short=1 なら期限を 8 秒にして流す。TERM を送った時刻を $sent に残す
run_case() {
  case $2 in
    none) run once kosako/prism ;;
    *)
      start_once "$2"
      sent=$(now_s)
      sent_wall=$(ruby -e "print Time.now.to_f")
      kill -TERM "$bg"
      wait_bg
      limit=63
      [ "${short:-0}" = 1 ] && limit=13.5
      ruby -e 'took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ARGV[0].to_f
        abort "#{ARGV[2]}: once must return within the deadline after TERM (took #{took.round(1)}s)" unless took < ARGV[1].to_f' \
        -- "$sent" "$limit" "$1" || fail "$1: deadline"
      ;;
  esac
  [ "${3:-0}" -gt 0 ] && sleep "$3"
  invariant "$1"
}

# M01: POST 成功、すぐ終わる
reset
run_case M01 none
expect_rc 0 "M01"
converge M01
# M02・M03: POST が 500 で作られない / 404 -> container を起動しない。作られたか分からないので、記録は 10 分残る
for m in fail notfound; do
  reset
  printf '%s\n' "$m" > "$tmp/gh/mode-post"
  run_case "M02 $m" none
  expect_rc 1 "M02 $m"
  ! docker_ran || fail "M02 $m: no container may start"
  converge "M02 $m"
done
# M04: POST は 500 だが作られている -> 名前で見つけて消す
reset
printf 'fail-created\n' > "$tmp/gh/mode-post"
run_case M04 none
expect_rc 1 "M04"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M04: the created runner must be found by name and deleted"
converge M04
# M05: POST が作ってから返らない -> TERM で止め、名前で見つけて消す
reset
printf 'hang\n' > "$tmp/gh/mode-post"
run_case M05 post
[ "$rc" -eq 1 ] || fail "M05: expected exit 1, got $rc"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M05: the runner must be deleted"
converge M05
# M06: POST が返らず、止められた後で作られる -> 記録が残り、後の cleanup が消す
reset
printf 'late\n' > "$tmp/gh/mode-post"
run_case M06 post 4
[ "$rc" -eq 1 ] || fail "M06: expected exit 1, got $rc"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "M06: the record must be kept"
converge M06
# M07・M08: 返事の形 (id が無い・runner が object でない・id が別の既存 runner を指す) -> id は使わない。名前で消す
for b in noid runnerstring otherid; do
  reset
  printf '%s\n' "$b" > "$tmp/gh/post-body"
  run_case "M07 $b" none
  expect_rc 0 "M07 $b"
  [ ! -e "$tmp/gh/runners/4242" ] || fail "M07 $b: our runner must be deleted by name"
  if [ "$b" = otherid ]; then
    [ "$(cat "$tmp/gh/runners/5555")" = someone-else ] || fail "M07 otherid: another runner must be left alone"
    rm -f "$tmp/gh/runners/5555"
  fi
  converge "M07 $b"
done
# M09: 一覧が失敗する -> 登録を消せないので記録を残す
reset
printf 'fail\n' > "$tmp/gh/mode-list"
run_case M09 none
expect_rc 1 "M09"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "M09: the record must be kept"
converge M09
# M10: DELETE が失敗する -> 記録を残す
reset
printf "fail\n" > "$tmp/gh/mode-delete"
run_case M10 none
expect_rc 1 "M10"
converge M10
# M11: DELETE が 404 で実際に消えている -> 記録を外す。404 なのに一覧に残っている -> 記録を残す
reset
printf "notfound-gone\n" > "$tmp/gh/mode-delete"
run_case "M11 gone" none
expect_rc 0 "M11 gone"
converge "M11 gone"
reset
printf "notfound\n" > "$tmp/gh/mode-delete"
run_case "M11 listed" none
expect_rc 1 "M11 listed"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "M11 listed: the record must be kept while the runner is listed"
converge "M11 listed"
# M12: docker run が 125 (起動できない) -> 名前で見つけて消す
reset
printf '125\n' > "$tmp/docker/run-exit"
run_case M12 none
expect_rc 1 "M12"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M12: the registration must be deleted"
converge M12
# M13: job を終えた runner は GitHub の側で消える -> 名前で見つからず、container の終わりを回収したので記録を外す
reset
touch "$tmp/docker/auto-remove"
run_case M13 none
expect_rc 0 "M13"
[ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "M13: the record must be removed"
converge M13
# M14: 動いている間に TERM -> 止めて消す。登録を消すのは、container が終わる前に始まっている。docker stop と kill が
# 失敗しても 5 秒ごとに繰り返し、TERM から 30 秒のうちに止める (繰り返さなければ、55 秒であきらめるまで止まらない)
reset
printf '90\n' > "$tmp/docker/run-seconds"
printf '3\n' > "$tmp/docker/stop-fail"
run_case M14 running
[ "$rc" -eq 1 ] || fail "M14: expected exit 1, got $rc"
grep -F -e '"kill"' "$tmp/docker/argv.log" >/dev/null || fail "M14: docker kill must be tried after docker stop fails"
ruby -e '
  ev = File.readlines(ARGV[0]).map(&:split) + File.readlines(ARGV[1]).map(&:split)
  del = ev.select { |t, e| e == "DELETE" }.map { |t, _| t.to_f }.min
  ex = ev.select { |t, e| e == "EXIT" }.map { |t, _| t.to_f }.min
  abort "M14: DELETE #{del.inspect} must start before the container exits #{ex.inspect}" unless del && ex && del < ex
  abort "M14: the stop must be retried until the container exits (#{(ex - ARGV[2].to_f).round(1)}s)" unless ex - ARGV[2].to_f < 30
' -- "$tmp/gh/events.log" "$tmp/docker/events.log" "$sent_wall" || fail "M14: the registration removal must not wait for the container"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M14: the registration must be deleted"
converge M14
# M15・M16・M17: 動いている間の確かめが public / 失敗 / 形の違う返事 -> 止めて消す
# (sh では `VAR=x 関数` の代入が関数の後も残るので、poll と short は代入してから戻す)
poll=1
for v in public fail mixed; do
  reset
  printf '30\n' > "$tmp/docker/run-seconds"
  printf 'private\nprivate\n%s\n' "$v" > "$tmp/gh/vis-seq"
  run_case "M15 $v" none
  expect_rc 1 "M15 $v"
  ls "$tmp/docker" | grep -q '^stop-' || fail "M15 $v: the container must be stopped"
  converge "M15 $v"
done
# M22: 動いている間の確かめが返らない -> 20 秒で切って止める (検知まで 1 + 20 秒。60 秒待たない)
reset
printf '90\n' > "$tmp/docker/run-seconds"
printf 'private\nprivate\nhang\n' > "$tmp/gh/vis-seq"
t0=$(now_s)
run_case M22 none
ruby -e 'took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ARGV[0].to_f
  abort "M22: a hanging check must be cut at 20 seconds (took #{took.round(1)}s)" unless took < 40' -- "$t0" || fail "M22: timing"
expect_rc 1 "M22"
converge M22
poll=
# M18: JIT を作った直後の確かめで public -> container を起動せず、名前で消す
reset
printf 'private\npublic\n' > "$tmp/gh/vis-seq"
run_case M18 none
expect_rc 1 "M18"
! docker_ran || fail "M18: no container may start"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M18: the registration must be deleted"
converge M18
# M24: JIT を作った直後の確かめの途中で TERM -> signal として知らせ、container を起動せず、名前で消して記録を外す
reset
printf 'private\nhang\n' > "$tmp/gh/vis-seq"
run_case M24 vis2
[ "$rc" -eq 1 ] || fail "M24: expected exit 1, got $rc"
case $(cat "$tmp/out") in *"止める signal を受けました"*) ;; *) fail "M24: unexpected output: $(cat "$tmp/out")" ;; esac
! docker_ran || fail "M24: no container may start"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M24: the registration must be deleted"
[ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "M24: the record must be removed"
converge M24
# M19: 記録を書けない (POST の前) -> API を呼ばない
reset
mkdir -m 700 "$state"
lock_name=$(ruby -rdigest -e 'print "lock-" + Digest::SHA256.hexdigest("kosako/prism")[0, 16]')
: > "$state/$lock_name"
chmod 600 "$state/$lock_name"
chmod 500 "$state"
run_case M19 none
chmod 700 "$state"
expect_rc 1 "M19"
case $(cat "$tmp/out") in *"state に記録できないので runner を作りません"*) ;; *) fail "M19: must stop at the record write: $(cat "$tmp/out")" ;; esac
! posted || fail "M19: the JIT runner must not be created without a record"
converge M19
# lock の file を用意できない -> runner を作らず exit 1。backtrace を出さない
reset
mkdir -m 700 "$state"
chmod 500 "$state"
run_case "lock unavailable" none
chmod 700 "$state"
expect_rc 1 "lock unavailable"
case $(cat "$tmp/out") in *"lock の file を用意できない"*) ;; *) fail "lock unavailable: unexpected output: $(cat "$tmp/out")" ;; esac
! posted || fail "lock unavailable: the JIT runner must not be created"
if grep -F -e ".rb:" "$tmp/err" >/dev/null; then fail "lock unavailable: no backtrace may be printed: $(cat "$tmp/err")"; fi
converge "lock unavailable"
# M20: 記録を消せない (state の dir を後で書けなくする) -> 登録は消し、記録は残る
reset
touch "$tmp/gh/chmod-state-on-post"
run_case M20 none
expect_rc 1 "M20"
[ ! -e "$tmp/gh/runners/4242" ] || fail "M20: the registration must still be deleted"
converge M20
# M21: 動いている間に TERM、DELETE が失敗する -> 記録を残す
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf 'fail\n' > "$tmp/gh/mode-delete"
run_case M21 running
[ "$rc" -eq 1 ] || fail "M21: expected exit 1, got $rc"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "M21: the record must be kept"
converge M21

# 期限を 10 秒にした once (返らない gh と docker を、本物の偽の子で置く。helper は差し替えない)
short=1
# T3: 動いている間に TERM、一覧が返らない -> container は登録の削除を待たずにすぐ止め、once は期限のうちに戻る
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf 'hang\n' > "$tmp/gh/mode-list"
run_case T3 running
[ "$rc" -eq 1 ] || fail "T3: expected exit 1, got $rc"
ruby -e '
  ex = File.readlines(ARGV[0]).map(&:split).select { |_, e| e == "EXIT" }.map { |t, _| t.to_f }.min
  abort "T3: the container must stop within 3s of TERM (exit at #{ex.inspect})" unless ex && ex - ARGV[1].to_f < 3
' -- "$tmp/docker/events.log" "$sent_wall" || fail "T3: the container stop must not wait for the registration removal"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "T3: the record must be kept"
converge T3
# T4: 作る段で TERM、一覧が遅く DELETE が返らない -> TERM の時点の期限で、後の呼び出しも切る
reset
printf 'hang\n' > "$tmp/gh/mode-post"
printf '3\n' > "$tmp/gh/list-delay"
printf '30\n' > "$tmp/gh/delete-delay"
run_case T4 post
[ "$rc" -eq 1 ] || fail "T4: expected exit 1, got $rc"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "T4: the record must be kept"
converge T4
# T5: 動いている間に TERM、docker stop も kill も返らない -> docker の client をあきらめ、container の名前を出し、記録を残す
reset
printf '30\n' > "$tmp/docker/run-seconds"
touch "$tmp/docker/stop-hang"
run_case T5 running
[ "$rc" -eq 1 ] || fail "T5: expected exit 1, got $rc"
case $(cat "$tmp/out") in *"手で止めてください"*) ;; *) fail "T5: unexpected output: $(cat "$tmp/out")" ;; esac
ls "$tmp/docker" | grep -q '^running-' || fail "T5: the fake container must still look alive"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "T5: the record must be kept while the container may be alive"
converge T5
# T6: T5 に加えて、登録の削除が 1 回目だけ失敗する -> 後片付けで登録は消せても、container が動いているかもしれないので記録を残す
reset
printf '30\n' > "$tmp/docker/run-seconds"
touch "$tmp/docker/stop-hang"
printf 'fail-once\n' > "$tmp/gh/mode-delete"
run_case T6 running
[ "$rc" -eq 1 ] || fail "T6: expected exit 1, got $rc"
[ ! -e "$tmp/gh/runners/4242" ] || fail "T6: the registration must be deleted on the second try"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "T6: the record must be kept while the container may be alive"
converge T6
# T7: 動いている間に TERM、一覧が返らず、gh が TERM を無視する -> 期限で残った gh を止め (KILL)、期限のうちに戻る
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf 'hang\n' > "$tmp/gh/mode-list"
touch "$tmp/gh/ignore-term"
run_case T7 running
[ "$rc" -eq 1 ] || fail "T7: expected exit 1, got $rc"
rm -f "$tmp/gh/ignore-term"
converge T7
# T8: 作る段で TERM、一覧が返らず、gh が TERM を無視する -> TERM から KILL までの猶予も期限の残りで切り、期限のうちに戻る
reset
printf 'hang\n' > "$tmp/gh/mode-post"
printf 'hang\n' > "$tmp/gh/mode-list"
touch "$tmp/gh/ignore-term"
run_case T8 post
[ "$rc" -eq 1 ] || fail "T8: expected exit 1, got $rc"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "T8: the record must be kept"
rm -f "$tmp/gh/ignore-term"
converge T8
# 偽の docker の client (run) を KILL する。pattern に $tmp を入れ、並べて流したほかの test の偽の docker に当てない
kill_client() {
  pkill -KILL -f -- "$tmp/fake/docker --context colima-ci run" || true
}
# client だけが終わり、止まったと確かめられない case (T10・T12・T13)。登録の削除は 1 回目だけ失敗させる (fail-once)。
# 後片付けが登録を見つけて消せる形にすると、記録を残す理由が「container が動いているかもしれない」だけになる
kept_alive_checks() { # $1=case
  [ "$rc" -eq 1 ] || fail "$1: expected exit 1, got $rc"
  invariant "$1"
  case $(cat "$tmp/out") in *"手で止めてください"*) ;; *) fail "$1: unexpected output: $(cat "$tmp/out")" ;; esac
  ls "$tmp/docker" | grep -q '^running-' || fail "$1: the fake container must still look alive"
  [ ! -e "$tmp/gh/runners/4242" ] || fail "$1: the registration must be deleted on the second try"
  [ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "$1: the record must be kept while the container may be alive"
  converge "$1"
}
within_short_deadline() { # $1=case  $2=始めの時刻
  ruby -e 'took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ARGV[0].to_f
    abort "#{ARGV[1]}: once must return within the deadline (took #{took.round(1)}s)" unless took < 13.5' -- "$2" "$1" || fail "$1: deadline"
}
# T10: 止めている途中で docker の client が KILL される (docker stop も返らない)
reset
printf '30\n' > "$tmp/docker/run-seconds"
touch "$tmp/docker/stop-hang"
printf 'fail-once\n' > "$tmp/gh/mode-delete"
start_once running
kill -TERM "$bg"
sleep 1
kill_client
wait_bg
kept_alive_checks T10
# T12: 動いている間に docker の client が KILL され、docker stop も返らない
reset
printf '30\n' > "$tmp/docker/run-seconds"
touch "$tmp/docker/stop-hang"
printf 'fail-once\n' > "$tmp/gh/mode-delete"
start_once running
t0=$(now_s)
kill_client
wait_bg
within_short_deadline T12 "$t0"
kept_alive_checks T12
# T13: 動いている間に docker の client だけが signal でなく終わり (daemon との接続が切れた形)、docker stop も返らない
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf '1\n' > "$tmp/docker/client-drop"
touch "$tmp/docker/stop-hang"
printf 'fail-once\n' > "$tmp/gh/mode-delete"
start_once running
t0=$(now_s)
wait_bg
within_short_deadline T13 "$t0"
kept_alive_checks T13
short=
# client だけが終わり、名前で止められる case (M23・M25) -> container を止め、止まったと確かめて、登録と記録を片付ける
stopped_by_name_checks() { # $1=case
  [ "$rc" -eq 1 ] || fail "$1: expected exit 1, got $rc"
  invariant "$1"
  case $(cat "$tmp/out") in *"docker の client だけが終わったので container を止めました"*) ;; *) fail "$1: unexpected output: $(cat "$tmp/out")" ;; esac
  ls "$tmp/docker" | grep -q '^stop-' || fail "$1: the container must be stopped by name"
  ! ls "$tmp/docker" | grep -q '^running-' || fail "$1: the fake container must not look alive"
  [ ! -e "$tmp/gh/runners/4242" ] || fail "$1: the registration must be deleted"
  [ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "$1: the record must be removed once the container is confirmed gone"
  converge "$1"
}
# M23: 動いている間に docker の client が KILL される
reset
printf '30\n' > "$tmp/docker/run-seconds"
start_once running
kill_client
wait_bg
stopped_by_name_checks M23
# M25: 動いている間に docker の client だけが signal でなく終わる (exit 125。起動の失敗と同じ exit code でも、container が
# 動いていれば止める)
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf '1\n' > "$tmp/docker/client-drop"
start_once running
wait_bg
stopped_by_name_checks M25
# T11: 止める段が 1 回目だけ例外を出し、登録を消す thread の DELETE が返らない -> 例外の受け口が container を止めて後片付けを
# し、once の終わりに、残った gh を止める (process を残さない)
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf 'hang-once\n' > "$tmp/gh/mode-delete"
main_script='load ARGV.shift
first = true
original = CiRunner.method(:stop_until_exit)
CiRunner.define_singleton_method(:stop_until_exit) do |*a|
  if first
    first = false
    sleep 1 # 登録を消す thread が DELETE に入るのを待つ
    raise "boom"
  end
  original.call(*a)
end
exit CiRunner.main(ARGV)'
run_case T11 running
main_script=
[ "$rc" -eq 1 ] || fail "T11: expected exit 1, got $rc"
ls "$tmp/docker" | grep -q '^stop-' || fail "T11: the container must be stopped"
[ ! -e "$tmp/gh/runners/4242" ] || fail "T11: the registration must be deleted by the settle"
converge T11

# ---- cleanup の個別の case ---------------------------------------------------------------------------------------
put_record() { # $1=名前  $2=何秒前に作ったか
  mkdir -p -m 700 "$state"
  ruby -rjson -e '
    r = { "repo" => "kosako/prism", "name" => ARGV[1], "container" => ARGV[1], "created_at" => Time.now.to_i - ARGV[2].to_i }
    File.write(File.join(ARGV[0], "#{ARGV[1]}.json"), JSON.generate(r))
  ' -- "$state" "$1" "$2"
}
n1=agent-tools-ci-0000000000000001
# E27: 動いていない container の記録 -> 名前で見つけて消す
reset
put_record "$n1" 0
printf '%s' "$n1" > "$tmp/gh/runners/7"
run cleanup
expect_rc 0 "E27"
[ ! -e "$tmp/gh/runners/7" ] && [ ! -e "$state/$n1.json" ] || fail "E27: the leftover must be cleaned"
# E28: 動いている container の記録 -> 残す
reset
put_record "$n1" 0
printf '%s' "$n1" > "$tmp/gh/runners/7"
touch "$tmp/docker/running-$n1"
run cleanup
expect_rc 0 "E28"
[ -e "$tmp/gh/runners/7" ] && [ -e "$state/$n1.json" ] || fail "E28: a running runner must be kept"
# 名前で見つからない記録: 作ってから 10 分たつまで残し、たったら外す。ほかの名前の runner には触れない
reset
put_record "$n1" 0
printf 'someone-else' > "$tmp/gh/runners/9"
run cleanup
expect_rc 0 "young absent"
[ -e "$state/$n1.json" ] && [ -e "$tmp/gh/runners/9" ] || fail "young absent: the record and the other runner must be kept"
reset
put_record "$n1" 3600
run cleanup
expect_rc 0 "old absent"
[ ! -e "$state/$n1.json" ] || fail "old absent: the record must be removed"
# 同じ名前の runner が 2 つ・id が 0 -> どれも消さず、記録を残して知らせる
reset
put_record "$n1" 3600
printf '%s' "$n1" > "$tmp/gh/runners/7"
printf '%s' "$n1" > "$tmp/gh/runners/8"
run cleanup
expect_rc 1 "duplicate names"
[ -e "$tmp/gh/runners/7" ] && [ -e "$tmp/gh/runners/8" ] && [ -e "$state/$n1.json" ] || fail "duplicate names: nothing may be deleted"
reset
put_record "$n1" 3600
printf '%s' "$n1" > "$tmp/gh/runners/0"
run cleanup
expect_rc 1 "zero id"
[ -e "$tmp/gh/runners/0" ] && [ -e "$state/$n1.json" ] || fail "zero id: nothing may be deleted"
# docker に問い合わせられない -> 動いているとみなして残す
reset
put_record "$n1" 3600
printf '%s' "$n1" > "$tmp/gh/runners/7"
touch "$tmp/docker/ps-fail"
run cleanup
expect_rc 0 "ps fails"
[ -e "$tmp/gh/runners/7" ] && [ -e "$state/$n1.json" ] || fail "ps fails: the runner and record must be kept"
# 一覧の gh が終わっても、孫の process が出力の pipe を持ち続ける -> 読み切りを待ち続けず、失敗として記録を残す
reset
put_record "$n1" 3600
printf '%s' "$n1" > "$tmp/gh/runners/7"
printf 'leak\n' > "$tmp/gh/mode-list"
t0=$(now_s)
run cleanup
ruby -e 'took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ARGV[0].to_f
  abort "leaked pipe: must not wait for the grandchild (took #{took.round(1)}s)" unless took < 15' -- "$t0" || fail "leaked pipe: timing"
expect_rc 1 "leaked pipe"
[ -e "$tmp/gh/runners/7" ] && [ -e "$state/$n1.json" ] || fail "leaked pipe: the runner and record must be kept"
pkill -f -- "$tmp/fake/gh" || true
# 壊れた記録と、知らない key を持つ記録 -> 消さずに知らせる
reset
mkdir -p -m 700 "$state"
printf 'not json' > "$state/$n1.json"
run cleanup
expect_rc 1 "broken record"
reset
put_record "$n1" 0
ruby -rjson -e 'r = JSON.parse(File.read(ARGV[0])); r["id"] = 7; File.write(ARGV[0], JSON.generate(r))' -- "$state/$n1.json"
run cleanup
expect_rc 1 "record with an unknown key"

# ---- helper を直接呼ぶ case ----------------------------------------------------------------------------------------
# R1: 動いている間の確かめの間隔は 40 秒が上限
ruby -e '
  load ARGV[0]
  { "3600" => 40, "41" => 40, "40" => 40, "1" => 1, "0" => 40, "x" => 40 }.each do |value, want|
    ENV["AGENT_TOOLS_CI_RUNNER_POLL_SECONDS"] = value
    got = CiRunner.poll_seconds
    abort "R1: poll_seconds for #{value} must be #{want}, got #{got}" unless got == want
  end
' -- "$src" || fail "R1: the poll interval must be capped at 40 seconds"
# 子の待ちには期限がある
ruby -e '
  load ARGV[0]
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  _o, _e, status = CiRunner.run_child(["sleep", "30"], timeout: 1)
  took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  abort "R4: a timed-out child must give a nil status" unless status.nil?
  abort "R4: the timeout must stop the child promptly (#{took})" unless took < 10
' -- "$src" || fail "R4: run_child must time out"
# T1: 検知の期限は、返らない gh と返らない docker が同時にあっても効く (上限を 8 秒・あきらめを 2 秒にして呼ぶ)
reset
touch "$tmp/docker/stop-hang"
printf 'hang\n' > "$tmp/gh/mode-list"
env PATH="$tmp/fake:$PATH" GH_REPO= GH_HOST= ruby -e '
  load ARGV[0]
  { STOP_GIVE_UP_SECONDS: 8, ABANDON_SECONDS: 2 }.each { |k, v| CiRunner.send(:remove_const, k); CiRunner.const_set(k, v) }
  CiRunner.instance_variable_set(:@interrupted, true)
  pid = Process.spawn("sleep", "60")
  record = { "repo" => "kosako/prism", "name" => "agent-tools-ci-0000000000000002", "container" => "agent-tools-ci-0000000000000002" }
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = CiRunner.wait_container({ "docker_context" => "colima-ci" }, "kosako/prism", { record: record, pid: pid })
  took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  abort "T1: expected :stop_failed, got #{result}" unless result == :stop_failed
  abort "T1: the detection deadline must bound everything (took #{took.round(1)}s)" unless took < 12
' -- "$src" || fail "T1: the detection deadline must apply to gh and docker together"
rm -f "$tmp/docker/stop-hang" "$tmp/gh/mode-list"
# T2: 想定外の例外 (動いている間の確かめで raise) -> container を止め、名前で消して記録を外す
reset
printf '30\n' > "$tmp/docker/run-seconds"
rc=0
env PATH="$tmp/fake:$PATH" HOME="$tmp/home" AGENT_TOOLS_CI_RUNNER_CONFIG="$conf" AGENT_TOOLS_CI_RUNNER_STATE_DIR="$state" \
  AGENT_TOOLS_CI_RUNNER_POLL_SECONDS=1 GH_REPO= GH_HOST= "$real_ruby" -e '
  load ARGV[0]
  calls = 0
  original = CiRunner.method(:visibility)
  CiRunner.define_singleton_method(:visibility) do |*a, **k|
    calls += 1
    raise "boom" if calls == 3
    original.call(*a, **k)
  end
  exit CiRunner.main(["once", "kosako/prism"])
' -- "$src" > "$tmp/out" 2> "$tmp/err" || rc=$?
[ "$rc" -eq 1 ] || fail "T2: expected exit 1, got $rc ($(cat "$tmp/out"))"
case $(cat "$tmp/out") in *"想定外の失敗で止めました (RuntimeError)"*) ;; *) fail "T2: unexpected output: $(cat "$tmp/out")" ;; esac
ls "$tmp/docker" | grep -q '^stop-' || fail "T2: the container must be stopped"
[ ! -e "$tmp/gh/runners/4242" ] && [ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "T2: the runner and record must be cleaned up"
invariant T2
# T9: T2 に加えて、例外の後は出力も失敗する -> 出力より先に container を止めて後片付けをする
reset
printf '30\n' > "$tmp/docker/run-seconds"
rc=0
env PATH="$tmp/fake:$PATH" HOME="$tmp/home" AGENT_TOOLS_CI_RUNNER_CONFIG="$conf" AGENT_TOOLS_CI_RUNNER_STATE_DIR="$state" \
  AGENT_TOOLS_CI_RUNNER_POLL_SECONDS=1 GH_REPO= GH_HOST= "$real_ruby" -e '
  load ARGV[0]
  broken = Object.new
  def broken.puts(*args)
    raise IOError, "closed stream" if $broken
    STDOUT.puts(*args)
  end
  calls = 0
  original = CiRunner.method(:visibility)
  CiRunner.define_singleton_method(:visibility) do |*a, **k|
    calls += 1
    if calls == 3
      $broken = true
      raise "boom"
    end
    original.call(*a, **k)
  end
  exit CiRunner.main(["once", "kosako/prism"], out: broken)
' -- "$src" > "$tmp/out" 2> "$tmp/err" || rc=$?
[ "$rc" -eq 1 ] || fail "T9: expected exit 1, got $rc ($(cat "$tmp/out"))"
ls "$tmp/docker" | grep -q '^stop-' || fail "T9: the container must be stopped before any output"
[ ! -e "$tmp/gh/runners/4242" ] && [ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "T9: the runner and record must be cleaned up"
invariant T9

# ---- 使い方の誤り --------------------------------------------------------------------------------------------------
reset
for args in "" "bogus" "check extra" "once" "once a/b c/d" "cleanup extra"; do
  # shellcheck disable=SC2086 # args は空白で分けて渡す
  run $args
  expect_rc 2 "usage [$args]"
done

echo "ok: ci-runner self-test"
