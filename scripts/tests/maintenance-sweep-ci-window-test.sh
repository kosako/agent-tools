#!/bin/sh
# personal-maintenance-sweep の `ci` の単位の窓を決める block (RECORD.md の `ci.json` の節。#541) の self-test。
# RECORD.md の「## local の state」の節にある block (`ruby - "$ci_json"` を含む sh の block) を切り出し、sh と zsh で
# いろいろな ci.json に当てて、出力を確かめる。
# - 出力は JSON 1 行で、key は until / since / basis / unseen_from。until は今の時刻 (UTC の秒、Z で終わる形)
# - basis: ci.json が無い (親の directory が無いときも) = first、30 日以内の checked_until = checked_until (窓の始まりは
#   その時刻)、30 日より前 = capped (unseen_from に元の値)、regular file でない・JSON の object でない・checked_until が
#   無い・形が違う・実在しない日時・until 以降 = unreadable。checked_until 以外の始まりは until の 30 日前
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

# 出力を確かめる。$1 = 出力の file、$2 = 期待の basis、$3 = 期待の since の 1 つ目 (floor なら until の 30 日前)、
# $4 = 期待の unseen_from (- なら null)。
cat > "$tmp/verify.rb" <<'RUBY'
require "json"
require "time"
out, want_basis, want_start, want_unseen = ARGV
FORM = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
lines = File.read(out).lines
abort "出力が 1 行でない: #{lines.size} 行" unless lines.size == 1
doc = JSON.parse(lines.first)
abort "key が違う: #{doc.keys.inspect}" unless doc.is_a?(Hash) && doc.keys.sort == %w[basis since unseen_from until]
abort "until の形が違う: #{doc["until"].inspect}" unless doc["until"].is_a?(String) && doc["until"].match?(FORM)
until_t = Time.iso8601(doc["until"])
# until は block を走らせた時刻の秒の切り捨てなので、今より先にならず、今から 10 秒以内。
abort "until が今の時刻でない: #{doc["until"]}" unless until_t <= Time.now && Time.now - until_t <= 10
abort "basis が #{want_basis} でない: #{doc["basis"].inspect}" unless doc["basis"] == want_basis
want_u = want_unseen == "-" ? nil : want_unseen
abort "unseen_from が #{want_u.inspect} でない: #{doc["unseen_from"].inspect}" unless doc["unseen_from"] == want_u
since = doc["since"]
unless since.is_a?(Array) && !since.empty? && since.all? { |s| s.is_a?(String) && s.match?(FORM) }
  abort "since が時刻の配列でない: #{since.inspect}"
end
fmt = ->(t) { t.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
start = want_start == "floor" ? fmt.call(until_t - 30 * 24 * 60 * 60) : want_start
abort "since の 1 つ目が #{start} でない: #{since.first}" unless since.first == start
# 前の始まりを until との中間まで遅らせたもの (秒は切り捨て) を、until より前の間だけ、3 つまで。
span = (until_t - Time.iso8601(since.first)).to_i
want = [1, 2, 4].map { |d| until_t - span / d }.select { |t| t < until_t }.uniq.map(&fmt)
abort "since が #{want.inspect} でない: #{since.inspect}" unless since == want
RUBY

# 時刻を作る。$1 = 今からの秒 (負は過去)。
at() {
  ruby -e 'puts (Time.at(Time.now.to_i).utc + Integer(ARGV[0])).strftime("%Y-%m-%dT%H:%M:%SZ")' -- "$1"
}

DAY=86400
recent=$(at $((-3 * DAY)))
inside=$(at $((-29 * DAY)))
old=$(at $((-90 * DAY)))
future=$(at $DAY)
just=$(at -2)

mkdir "$tmp/fx"
printf '{"checked_until":"%s","run_id":"20261001T000000"}\n' "$recent" > "$tmp/fx/recent.json"
printf '{"checked_until":"%s"}\n' "$inside" > "$tmp/fx/inside.json"
printf '{"checked_until":"%s"}\n' "$old" > "$tmp/fx/old.json"
printf '{"checked_until":"%s"}\n' "$future" > "$tmp/fx/future.json"
printf '{"checked_until":"%s"}\n' "$just" > "$tmp/fx/just.json"
printf '{"checked_until":"2026-02-30T00:00:00Z"}\n' > "$tmp/fx/no-such-day.json"
printf '{"checked_until":"2026-10-01T23:59:60Z"}\n' > "$tmp/fx/leap-second.json"
printf '{"checked_until":"2026-10-01T00:00:00+09:00"}\n' > "$tmp/fx/offset.json"
printf '{"checked_until":"2026-10-01T00:00:00.5Z"}\n' > "$tmp/fx/fraction.json"
printf '{"checked_until":1790000000}\n' > "$tmp/fx/number.json"
printf '{"run_id":"20261001T000000"}\n' > "$tmp/fx/no-key.json"
printf '["%s"]\n' "$recent" > "$tmp/fx/array.json"
printf '"%s"\n' "$recent" > "$tmp/fx/string.json"
printf '{\n' > "$tmp/fx/broken.json"
: > "$tmp/fx/empty.json"
ln -s "$tmp/fx/recent.json" "$tmp/fx/symlink.json"
mkdir "$tmp/fx/dir.json"

# case: 名前、ci.json の path、期待の basis、期待の since の 1 つ目、期待の unseen_from
cases() {
  cat <<EOF
missing	$tmp/fx/missing.json	first	floor	-
missing-parent	$tmp/fx/no-dir/ci.json	first	floor	-
recent	$tmp/fx/recent.json	checked_until	$recent	-
inside	$tmp/fx/inside.json	checked_until	$inside	-
just	$tmp/fx/just.json	checked_until	$just	-
old	$tmp/fx/old.json	capped	floor	$old
future	$tmp/fx/future.json	unreadable	floor	-
no-such-day	$tmp/fx/no-such-day.json	unreadable	floor	-
leap-second	$tmp/fx/leap-second.json	unreadable	floor	-
offset	$tmp/fx/offset.json	unreadable	floor	-
fraction	$tmp/fx/fraction.json	unreadable	floor	-
number	$tmp/fx/number.json	unreadable	floor	-
no-key	$tmp/fx/no-key.json	unreadable	floor	-
array	$tmp/fx/array.json	unreadable	floor	-
string	$tmp/fx/string.json	unreadable	floor	-
broken	$tmp/fx/broken.json	unreadable	floor	-
empty	$tmp/fx/empty.json	unreadable	floor	-
symlink	$tmp/fx/symlink.json	unreadable	floor	-
dir	$tmp/fx/dir.json	unreadable	floor	-
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
  while IFS=$tab read -r name path basis start unseen; do
    rc=0
    # shellcheck disable=SC2086 # $shell_argv は上の定数 (sh / zsh -f)
    env ci_json="$path" $shell_argv "$tmp/block.sh" > "$tmp/out" 2> "$tmp/err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$shell: $name: block の exit が 0 でない ($rc): $(cat "$tmp/err")"
    [ ! -s "$tmp/err" ] || fail "$shell: $name: block が stderr に出した: $(cat "$tmp/err")"
    ruby "$tmp/verify.rb" "$tmp/out" "$basis" "$start" "$unseen" 2> "$tmp/err" \
      || fail "$shell: $name: $(cat "$tmp/err")"
  done < "$tmp/cases"
done
[ "$ran" -gt 0 ] || fail "sh も zsh も無い"

(cd "$tmp/fx" && ls -lAR .) > "$tmp/after"
cmp -s "$tmp/before" "$tmp/after" \
  || fail "block が ci.json の置き場の file を書き換えた・作った: $(diff "$tmp/before" "$tmp/after" || true)"

echo "ok: maintenance-sweep-ci-window"
