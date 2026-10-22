#!/bin/sh
# personal-maintenance-sweep の `ci` の単位の窓を決める block (RECORD.md の `ci.json` の節。#541) の self-test。
# RECORD.md の「## local の state」の節にある block (`ruby - "$ci_json"` を含む sh の block) を切り出し、sh と zsh で
# いろいろな ci.json に当てて、出力を明示的な期待値と比べる。
# - 時刻は test の中だけで固定する (RUBYOPT で読む fake_now.rb が Time.now を FAKE_NOW に差し替える)。境界 (30 日
#   ちょうど・30 日と 1 秒前・until と同じ時刻) と短い窓 (1〜4 秒) を、実行の速さに依らずに確かめるため (#554 review R2)。
#   実際の時計で動く case も 1 つ残す (until が今の時刻の秒の切り捨てで、今より先でないこと)
# - 出力は JSON 1 行で、key は until / since / basis / unseen_from。until は今の時刻 (UTC の秒、Z で終わる形)
# - basis: ci.json が無い (親の directory が無いときも) = first、30 日前ちょうどから until の前までの checked_until =
#   checked_until (窓の始まりはその時刻)、30 日前より前 = capped (unseen_from に元の値)、regular file でない・JSON の
#   object でない・checked_until が無い・形が違う・実在しない日時・until 以降 = unreadable。checked_until 以外の始まりは
#   until の 30 日前
# - since は窓の始まりから、前の始まりを until との中間まで遅らせたものを 3 つまで (until より前のものだけ)
# - block は ci.json を書き換えず、file を作らない
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
sweep_dir=${1:-"$script_dir/../../shared/skills/personal-maintenance-sweep"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# RUBYOPT は空白で区切られるので、空白を含む path は渡せない。
case $tmp in
  *[[:space:]]*) fail "一時 directory の path に空白がある: $tmp" ;;
esac

ruby - "$sweep_dir/RECORD.md" "$tmp/block.sh" <<'RUBY'
src, out = ARGV
text = File.read(src, encoding: "UTF-8")
section = text[/^## local の state\n(.*)\z/m, 1]
abort "RECORD.md に「## local の state」の節が無い" unless section
blocks = section.scan(/^( *)```sh\n(.*?)^\1```/m).map { |indent, body| body.lines.map { |l| l.sub(/\A#{indent}/, "") }.join }
picked = blocks.select { |b| b.include?('ruby - "$ci_json"') }
abort "local の state の節に窓の sh の block が 1 つでない (#{picked.size} 個)" unless picked.size == 1
File.write(out, picked.first)
RUBY

mkdir "$tmp/lib"
cat > "$tmp/lib/fake_now.rb" <<'RUBY'
# test の中だけで Time.now を FAKE_NOW (epoch 秒。小数を書ける) に固定する。
if ENV["FAKE_NOW"]
  class << Time
    def now
      Time.at(ENV.fetch("FAKE_NOW").to_r)
    end
  end
end
RUBY

# 出力を確かめる。$1 = 出力の file、$2 = 期待の basis、$3 = 期待の until (real なら実際の時計)、$4 = 期待の
# unseen_from (- なら null)、$5 = 期待の since (, で区切る。real なら until から作る)。
cat > "$tmp/verify.rb" <<'RUBY'
require "json"
require "time"
out, want_basis, want_until, want_unseen, want_since = ARGV
FORM = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
lines = File.read(out).lines
abort "出力が 1 行でない: #{lines.size} 行" unless lines.size == 1
doc = JSON.parse(lines.first)
abort "key が違う: #{doc.keys.inspect}" unless doc.is_a?(Hash) && doc.keys.sort == %w[basis since unseen_from until]
abort "until の形が違う: #{doc["until"].inspect}" unless doc["until"].is_a?(String) && doc["until"].match?(FORM)
if want_until == "real"
  # 実際の時計: until は block を走らせた時刻の秒の切り捨てなので、今より先にならず、今から 10 秒以内。
  until_t = Time.iso8601(doc["until"])
  abort "until が今の時刻でない: #{doc["until"]}" unless until_t <= Time.now && Time.now - until_t <= 10
  fmt = ->(t) { t.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
  want_since = [30 * 86_400, 15 * 86_400, 648_000].map { |s| fmt.call(until_t - s) }
else
  abort "until が #{want_until} でない: #{doc["until"]}" unless doc["until"] == want_until
  want_since = want_since.split(",")
end
abort "basis が #{want_basis} でない: #{doc["basis"].inspect}" unless doc["basis"] == want_basis
want_u = want_unseen == "-" ? nil : want_unseen
abort "unseen_from が #{want_u.inspect} でない: #{doc["unseen_from"].inspect}" unless doc["unseen_from"] == want_u
abort "since が #{want_since.inspect} でない: #{doc["since"].inspect}" unless doc["since"] == want_since
RUBY

# 固定した今の時刻 (秒の端数は block が切り捨てる) と、そこからの時刻。
base=$(ruby -rtime -e 'print Time.iso8601("2026-10-22T12:00:07Z").to_i')
fake_now="$base.7"
# $1 = 固定した今からの秒 (負は過去)。
at() {
  ruby -e 'print Time.at(Integer(ARGV[0]) + Integer(ARGV[1])).utc.strftime("%Y-%m-%dT%H:%M:%SZ")' -- "$base" "$1"
}
DAY=86400
now=$(at 0)
# 窓の始まりが until の 30 日前のときの since (30 日前・15 日前・7.5 日前)。
floor="$(at $((-30 * DAY))),$(at $((-15 * DAY))),$(at -648000)"

mkdir "$tmp/fx"
printf '{"checked_until":"%s","run_id":"20261019T210007"}\n' "$(at $((-3 * DAY)))" > "$tmp/fx/recent.json"
printf '{"checked_until":"%s"}\n' "$(at $((-30 * DAY)))" > "$tmp/fx/exact30.json"
printf '{"checked_until":"%s"}\n' "$(at $((-30 * DAY - 1)))" > "$tmp/fx/over30.json"
printf '{"checked_until":"%s"}\n' "$(at $((-90 * DAY)))" > "$tmp/fx/old.json"
printf '{"checked_until":"%s"}\n' "$now" > "$tmp/fx/equal.json"
printf '{"checked_until":"%s"}\n' "$(at $DAY)" > "$tmp/fx/future.json"
for s in 1 2 3 4; do
  printf '{"checked_until":"%s"}\n' "$(at "-$s")" > "$tmp/fx/span$s.json"
done
printf '{"checked_until":"2026-02-30T00:00:00Z"}\n' > "$tmp/fx/no-such-day.json"
printf '{"checked_until":"2026-10-01T23:59:60Z"}\n' > "$tmp/fx/leap-second.json"
printf '{"checked_until":"2026-10-01T00:00:00+09:00"}\n' > "$tmp/fx/offset.json"
printf '{"checked_until":"2026-10-01T00:00:00.5Z"}\n' > "$tmp/fx/fraction.json"
printf '{"checked_until":1790000000}\n' > "$tmp/fx/number.json"
printf '{"run_id":"20261001T000000"}\n' > "$tmp/fx/no-key.json"
printf '["%s"]\n' "$(at $((-3 * DAY)))" > "$tmp/fx/array.json"
printf '"%s"\n' "$(at $((-3 * DAY)))" > "$tmp/fx/string.json"
printf '{\n' > "$tmp/fx/broken.json"
: > "$tmp/fx/empty.json"
ln -s "$tmp/fx/recent.json" "$tmp/fx/symlink.json"
mkdir "$tmp/fx/dir.json"

# case: 名前、ci.json の path、期待の basis、期待の unseen_from、期待の since (, で区切る)。until はすべて $now。
cases() {
  cat <<EOF
missing	$tmp/fx/missing.json	first	-	$floor
missing-parent	$tmp/fx/no-dir/ci.json	first	-	$floor
recent	$tmp/fx/recent.json	checked_until	-	$(at $((-3 * DAY))),$(at -129600),$(at -64800)
exact30	$tmp/fx/exact30.json	checked_until	-	$floor
over30	$tmp/fx/over30.json	capped	$(at $((-30 * DAY - 1)))	$floor
old	$tmp/fx/old.json	capped	$(at $((-90 * DAY)))	$floor
equal	$tmp/fx/equal.json	unreadable	-	$floor
future	$tmp/fx/future.json	unreadable	-	$floor
span1	$tmp/fx/span1.json	checked_until	-	$(at -1)
span2	$tmp/fx/span2.json	checked_until	-	$(at -2),$(at -1)
span3	$tmp/fx/span3.json	checked_until	-	$(at -3),$(at -1)
span4	$tmp/fx/span4.json	checked_until	-	$(at -4),$(at -2),$(at -1)
no-such-day	$tmp/fx/no-such-day.json	unreadable	-	$floor
leap-second	$tmp/fx/leap-second.json	unreadable	-	$floor
offset	$tmp/fx/offset.json	unreadable	-	$floor
fraction	$tmp/fx/fraction.json	unreadable	-	$floor
number	$tmp/fx/number.json	unreadable	-	$floor
no-key	$tmp/fx/no-key.json	unreadable	-	$floor
array	$tmp/fx/array.json	unreadable	-	$floor
string	$tmp/fx/string.json	unreadable	-	$floor
broken	$tmp/fx/broken.json	unreadable	-	$floor
empty	$tmp/fx/empty.json	unreadable	-	$floor
symlink	$tmp/fx/symlink.json	unreadable	-	$floor
dir	$tmp/fx/dir.json	unreadable	-	$floor
EOF
}

(cd "$tmp/fx" && ls -lAR .) > "$tmp/before"
tab=$(printf '\t')
ran=0
for shell in sh zsh; do
  command -v "$shell" > /dev/null 2>&1 || continue
  case $shell in
    zsh) shell_argv='zsh -f' ;;
    *) shell_argv=sh ;;
  esac
  ran=$((ran + 1))
  cases > "$tmp/cases"
  while IFS=$tab read -r name path basis unseen since; do
    rc=0
    # shellcheck disable=SC2086 # $shell_argv は上の定数 (sh / zsh -f)
    env RUBYOPT="-I$tmp/lib -rfake_now" FAKE_NOW="$fake_now" ci_json="$path" $shell_argv "$tmp/block.sh" \
      > "$tmp/out" 2> "$tmp/err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$shell: $name: block の exit が 0 でない ($rc): $(cat "$tmp/err")"
    [ ! -s "$tmp/err" ] || fail "$shell: $name: block が stderr に出した: $(cat "$tmp/err")"
    ruby "$tmp/verify.rb" "$tmp/out" "$basis" "$now" "$unseen" "$since" 2> "$tmp/err" \
      || fail "$shell: $name: $(cat "$tmp/err")"
  done < "$tmp/cases"

  # 実際の時計 (FAKE_NOW も RUBYOPT も渡さない)。
  rc=0
  # shellcheck disable=SC2086 # $shell_argv は上の定数 (sh / zsh -f)
  env -u RUBYOPT -u FAKE_NOW ci_json="$tmp/fx/missing.json" $shell_argv "$tmp/block.sh" > "$tmp/out" 2> "$tmp/err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$shell: real-clock: block の exit が 0 でない ($rc): $(cat "$tmp/err")"
  ruby "$tmp/verify.rb" "$tmp/out" first real - - 2> "$tmp/err" || fail "$shell: real-clock: $(cat "$tmp/err")"
done
[ "$ran" -gt 0 ] || fail "sh も zsh も無い"

(cd "$tmp/fx" && ls -lAR .) > "$tmp/after"
cmp -s "$tmp/before" "$tmp/after" \
  || fail "block が ci.json の置き場の file を書き換えた・作った: $(diff "$tmp/before" "$tmp/after" || true)"

echo "ok: maintenance-sweep-ci-window"
