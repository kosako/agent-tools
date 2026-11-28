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
cat > "$tmp/fake/gh" <<EOF
#!$real_ruby
require "json"
dir = $(shq "$tmp/gh")
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
def not_found
  warn "gh: Not Found (HTTP 404)"
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
  else
    warn "gh: Server Error (HTTP 500)"
    exit 1
  end
elsif method == "POST" && path.match?(%r{/actions/runners/generate-jitconfig\z})
  mode = File.exist?(File.join(dir, "jit-mode")) ? File.read(File.join(dir, "jit-mode")).strip : "ok"
  if mode == "fail"
    warn "gh: Server Error (HTTP 500)"
    exit 1
  end
  name = JSON.parse(stdin)["name"]
  File.write(File.join(runners, "4242"), name)
  body = { "runner" => { "id" => 4242, "name" => name }, "encoded_jit_config" => $(shq "$canary") }
  body["runner"].delete("id") if mode == "noid"
  body["encoded_jit_config"] = "bad!cfg" if mode == "badcfg"
  puts JSON.generate(body)
elsif method == "GET" && (m = path.match(%r{/actions/runners/(\d+)\z}))
  file = File.join(runners, m[1])
  not_found unless File.exist?(file)
  puts JSON.generate("id" => m[1].to_i, "name" => File.read(file))
elsif method == "DELETE" && (m = path.match(%r{/actions/runners/(\d+)\z}))
  if File.exist?(File.join(dir, "delete-fail"))
    warn "gh: Server Error (HTTP 500)"
    exit 1
  end
  file = File.join(runners, m[1])
  not_found unless File.exist?(file)
  File.delete(file)
elsif method == "GET" && path.match?(%r{/actions/runners\?per_page=100\z})
  list = Dir.children(runners).sort.map { |id| { "id" => id.to_i, "name" => File.read(File.join(runners, id)) } }
  puts JSON.generate([{ "total_count" => list.length, "runners" => list }])
else
  abort "fake gh: unexpected #{method} #{path}"
end
EOF

# ---- 偽の docker ------------------------------------------------------------------------------------------------
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
  sleep 0.05 until Time.now >= deadline || File.exist?(stop)
  File.delete(running)
  Dir.glob(File.join($(shq "$tmp/gh/runners"), "*")).each { |f| File.delete(f) } if File.exist?(File.join(dir, "auto-remove"))
  exit(File.exist?(stop) ? 143 : code)
when "ps"
  filter = args[args.index("--filter") + 1]
  name = filter.sub("name=^/?", "").sub(/\\\$\z/, "")
  puts "c0ffee" if File.exist?(File.join(dir, "running-#{name}"))
when "stop"
  File.write(File.join(dir, "stop-#{args.last}"), "")
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
    AGENT_TOOLS_CI_RUNNER_POLL_SECONDS="${poll:-60}" GH_REPO= GH_HOST= \
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

# ---- E16: JIT を作った直後の確かめで public になっていた ----------------------------------------------------------
reset
printf 'private\npublic\n' > "$tmp/gh/vis-seq"
run once kosako/prism
expect_rc 1 "E16"
posted || fail "E16: the JIT runner should have been created before the recheck"
! docker_ran || fail "E16: no container may start after the repo became public"
[ ! -e "$tmp/gh/runners/4242" ] || fail "E16: the registration must be deleted"
[ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "E16: the record must be removed"

# ---- 通常の once (E17・E19・E21・E23・E24・E26) -------------------------------------------------------------------
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
# E19: state の記録は repo・名前・container・id だけで、0600
snap="$tmp/docker/state-$name"
ruby -rjson -e '
  f = File.join(ARGV[0], "#{ARGV[1]}.json")
  r = JSON.parse(File.read(f))
  abort "E19: keys #{r.keys.sort}" unless r.keys.sort == %w[container id name repo]
' -- "$snap" "$name" || fail "E19: the record shape"
[ "$(ruby -e 'printf("%o", File.stat(ARGV[0]).mode & 0o777)' -- "$state")" = 700 ] || fail "E19: the state dir must be 0700"
no_canary_outside "E24"
# E26: 終わった後で登録が残っていれば消し、記録を外す
[ ! -e "$tmp/gh/runners/4242" ] || fail "E26: the registration must be deleted"
grep -F -e '"DELETE"' "$tmp/gh/argv.log" >/dev/null || fail "E26: a DELETE must be sent"
[ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "E26: the record must be removed"

# 登録が GitHub の側で消えていれば (job を終えた JIT の runner)、DELETE を送らずに記録を外す
reset
touch "$tmp/docker/auto-remove"
run once kosako/prism
expect_rc 0 "gone after job"
! grep -F -e '"DELETE"' "$tmp/gh/argv.log" >/dev/null || fail "gone after job: no DELETE is needed"
[ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "gone after job: the record must be removed"

# ---- 作った後の失敗 (E18・E20・E25 と決めたこと) ------------------------------------------------------------------
# E18: 返事に id が無い -> 名前で探して消す。container は起動しない
reset
printf 'noid\n' > "$tmp/gh/jit-mode"
run once kosako/prism
expect_rc 1 "E18"
! docker_ran || fail "E18: no container may start"
[ ! -e "$tmp/gh/runners/4242" ] || fail "E18: the runner must be found by name and deleted"
# JIT の設定の形が違う -> container に渡さず消す
reset
printf 'badcfg\n' > "$tmp/gh/jit-mode"
run once kosako/prism
expect_rc 1 "bad jit"
! docker_ran || fail "bad jit: no container may start"
[ ! -e "$tmp/gh/runners/4242" ] || fail "bad jit: the registration must be deleted"
# E20: 作りかけの記録を書けない -> API を呼ばない。lock の file は先に置いておき、記録の書き込みの失敗まで届かせる
reset
mkdir -m 700 "$state"
lock_name=$(ruby -rdigest -e 'print "lock-" + Digest::SHA256.hexdigest("kosako/prism")[0, 16]')
: > "$state/$lock_name"
chmod 600 "$state/$lock_name"
chmod 500 "$state"
run once kosako/prism
chmod 700 "$state"
expect_rc 1 "E20"
case $(cat "$tmp/out") in *"state に記録できないので runner を作りません"*) ;; *) fail "E20: must stop at the record write: $(cat "$tmp/out")" ;; esac
! posted || fail "E20: the JIT runner must not be created without a record"
# lock の file を用意できない -> runner を作らず exit 1。backtrace を出さない
reset
mkdir -m 700 "$state"
chmod 500 "$state"
run once kosako/prism
chmod 700 "$state"
expect_rc 1 "lock unavailable"
case $(cat "$tmp/out") in *"lock の file を用意できない"*) ;; *) fail "lock unavailable: unexpected output: $(cat "$tmp/out")" ;; esac
! posted || fail "lock unavailable: the JIT runner must not be created"
if grep -F -e ".rb:" "$tmp/err" >/dev/null; then fail "lock unavailable: no backtrace may be printed: $(cat "$tmp/err")"; fi
# E25: container を起動できない (docker run の exit 125) -> 登録を消す
reset
printf '125\n' > "$tmp/docker/run-exit"
run once kosako/prism
expect_rc 1 "E25"
[ ! -e "$tmp/gh/runners/4242" ] || fail "E25: the registration must be deleted"
# 登録を消せない -> 記録を残して exit 1。後の cleanup が消す
reset
touch "$tmp/gh/delete-fail"
run once kosako/prism
expect_rc 1 "delete failure"
[ -n "$(ls "$state" | grep '\.json$' || true)" ] || fail "delete failure: the record must be kept"
rm -f "$tmp/gh/delete-fail"
run cleanup
expect_rc 0 "cleanup after delete failure"
[ ! -e "$tmp/gh/runners/4242" ] && [ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "cleanup after delete failure"

# ---- cleanup (E27・E28 と照合) ------------------------------------------------------------------------------------
put_record() { # $1=名前  $2=id (空なら付けない)
  mkdir -p -m 700 "$state"
  ruby -rjson -e 'r = { "repo" => "kosako/prism", "name" => ARGV[1], "container" => ARGV[1] }; r["id"] = ARGV[2].to_i unless ARGV[2].empty?; File.write(File.join(ARGV[0], "#{ARGV[1]}.json"), JSON.generate(r))' -- "$state" "$1" "$2"
}
n1=agent-tools-ci-0000000000000001
# E27: 動いていない container の記録 -> 消す
reset
put_record "$n1" 7
printf '%s' "$n1" > "$tmp/gh/runners/7"
run cleanup
expect_rc 0 "E27"
[ ! -e "$tmp/gh/runners/7" ] && [ ! -e "$state/$n1.json" ] || fail "E27: the leftover must be cleaned"
# E28: 動いている container の記録 -> 残す
reset
put_record "$n1" 7
printf '%s' "$n1" > "$tmp/gh/runners/7"
touch "$tmp/docker/running-$n1"
run cleanup
expect_rc 0 "E28"
[ -e "$tmp/gh/runners/7" ] && [ -e "$state/$n1.json" ] || fail "E28: a running runner must be kept"
# id の runner の名前が記録と違う -> 消さない
reset
put_record "$n1" 7
printf 'someone-else' > "$tmp/gh/runners/7"
run cleanup
expect_rc 1 "name mismatch"
[ -e "$tmp/gh/runners/7" ] && [ -e "$state/$n1.json" ] || fail "name mismatch: nothing may be deleted"
# id の無い記録 (作りかけ) -> 名前で探す。無ければ記録だけ外す
reset
put_record "$n1" ""
run cleanup
expect_rc 0 "pending record"
[ ! -e "$state/$n1.json" ] || fail "pending record: must be removed when no runner has the name"
# 壊れた記録 -> 消さずに知らせる
reset
mkdir -p -m 700 "$state"
printf 'not json' > "$state/$n1.json"
run cleanup
expect_rc 1 "broken record"

# ---- signal と公開の変化 (E29 と決めたこと) -----------------------------------------------------------------------
start_once() { # 背景で once を起動し、container が動き出すまで待つ。pid を $bg に入れる
  env PATH="$tmp/fake:$PATH" HOME="$tmp/home" AGENT_TOOLS_CI_RUNNER_CONFIG="$conf" AGENT_TOOLS_CI_RUNNER_STATE_DIR="$state" \
    AGENT_TOOLS_CI_RUNNER_POLL_SECONDS="${poll:-60}" GH_REPO= GH_HOST= \
    "$real_ruby" "$src" once kosako/prism > "$tmp/bg-out" 2> "$tmp/bg-err" < /dev/null &
  bg=$!
  i=0
  until ls "$tmp/docker" | grep -q '^running-'; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "the background once did not start a container"
    sleep 0.05
  done
}
wait_bg() {
  bg_rc=0
  wait "$bg" || bg_rc=$?
}
# E29: 動いている間に TERM -> container を止め、登録を消す
reset
printf '30\n' > "$tmp/docker/run-seconds"
start_once
kill -TERM "$bg"
wait_bg
[ "$bg_rc" -eq 1 ] || fail "E29: expected exit 1 after TERM, got $bg_rc"
ls "$tmp/docker" | grep -q '^stop-' || fail "E29: the container must be stopped"
[ ! -e "$tmp/gh/runners/4242" ] && [ -z "$(ls "$state" | grep '\.json$' || true)" ] || fail "E29: the registration and record must be removed"
# 動いている間に public になった -> container を止め、登録を消す
reset
printf '30\n' > "$tmp/docker/run-seconds"
printf 'private\nprivate\npublic\n' > "$tmp/gh/vis-seq"
poll=1 start_once
wait_bg
[ "$bg_rc" -eq 1 ] || fail "made public: expected exit 1, got $bg_rc"
ls "$tmp/docker" | grep -q '^stop-' || fail "made public: the container must be stopped"
[ ! -e "$tmp/gh/runners/4242" ] || fail "made public: the registration must be deleted"

# ---- E30: 同じ repo の once を 2 つ -----------------------------------------------------------------------------
reset
printf '30\n' > "$tmp/docker/run-seconds"
start_once
run once kosako/prism
expect_rc 3 "E30"
[ "$(grep -c '"POST"' "$tmp/gh/argv.log")" -eq 1 ] || fail "E30: the second once must not create a runner"
kill -TERM "$bg"
wait_bg

# ---- 使い方の誤り --------------------------------------------------------------------------------------------------
reset
for args in "" "bogus" "check extra" "once" "once a/b c/d" "cleanup extra"; do
  # shellcheck disable=SC2086 # args は空白で分けて渡す
  run $args
  expect_rc 2 "usage [$args]"
done

echo "ok: ci-runner self-test"
