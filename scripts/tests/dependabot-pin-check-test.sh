#!/bin/sh
# personal-dependabot-pin-check.rb の self-test (#553)。
# 純粋ロジック (版の比較・pin の行の形・uses の抽出) は check_helper の Ruby unit、gh 連携は PATH 上の fake gh
# (endpoint ごとに fixture を返し、それ以外は失敗) で integration 検証する (実 gh / network には触れない)。
# untrusted-input 規律 (PR の本文・patch・file の中身・gh の stderr を出力に出さない) も canary で検証する。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-dependabot-pin-check.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fix="$tmp/fix"
ruby "$script_dir/lib/dependabot_pin_check_fixtures.rb" "$fix" >/dev/null

# ---- Ruby unit checks: 純粋ロジック ------------------------------------------
ruby -r"$script_dir/lib/check_helper" -rjson - "$src" "$fix" <<'RUBY'
require ARGV[0]
fix = ARGV[1]
M = DependabotPinCheck

def fwd(a, b)
  M.version_forward?(a, b)
end

check("v1.9.0 -> v1.10.0 は前に進む (数値の tuple)", fwd("v1.9.0", "v1.10.0"))
check("v1.331.0 -> v1.329.0 は戻る", !fwd("v1.331.0", "v1.329.0"))
check("同じ版は前に進まない", !fwd("v2", "v2"))
check("v4 -> v4.1 は前に進む", fwd("v4", "v4.1"))
check("v の有無は無視する", fwd("1.2.3", "v1.2.4"))

sha = "a" * 40
def uses_match?(line)
  !DependabotPinCheck::USES_LINE_RE.match(line).nil?
end
check("step の pin の行", uses_match?("      - uses: ruby/setup-ruby@#{sha} # v1.2.3"))
check("name の後の uses の行", uses_match?("        uses: owner/repo/path/x@#{sha} #v1"))
check("reusable workflow の job の uses", uses_match?("    uses: octo/workflows/.github/workflows/lint.yml@#{sha} # v2.0.0"))
check("tag への pin (sha でない) は形の外", !uses_match?("      - uses: actions/checkout@v4 # v4"))
check("docker:// は形の外", !uses_match?("      - uses: docker://alpine:3 # v3"))
check("local の action は形の外", !uses_match?("      - uses: ./local # v1"))
check("版のコメントが無い行は形の外", !uses_match?("      - uses: owner/repo@#{sha}"))
check("prerelease の版は形の外", !uses_match?("      - uses: owner/repo@#{sha} # v1.2.3-rc1"))
check("コメントの後に余計な語がある行は形の外", !uses_match?("      - uses: owner/repo@#{sha} # v1 extra"))
check("短い sha は形の外", !uses_match?("      - uses: owner/repo@#{sha[0, 7]} # v1"))
m = DependabotPinCheck::USES_LINE_RE.match("      - uses: ruby/setup-ruby@#{sha} # v1.2.3")
check("ref / sha / tag を取り出す", m[:ref] == "ruby/setup-ruby" && m[:sha] == sha && m[:tag] == "v1.2.3")

old_json = JSON.parse(File.read(Dir.glob(File.join(fix, "ok", "contents", "*", ".github/workflows/test.yml.json")).min))
old_text = old_json["content"].unpack1("m").force_encoding("UTF-8")
uses = M.uses_lines(old_text, "test.yml")
check("uses は step 2 つと job 1 つ", uses.keys == ["jobs.test.steps[0].uses", "jobs.test.steps[1].uses", "jobs.reuse.uses"])
line = uses["jobs.test.steps[1].uses"][:line]
check("uses の行番号は 1 始まりで本文の行と一致", old_text.lines[line - 1].include?("ruby/setup-ruby@"))
check("uses の値は scalar の値", uses["jobs.test.steps[1].uses"][:value].start_with?("ruby/setup-ruby@"))
check("run の block scalar の中の uses: は拾わない", uses.values.none? { |u| u[:value].include?("not/an-action") })

def file_error(text)
  M.uses_lines(text, "x.yml")
  nil
rescue M::FileError => e
  e.message
end
check("jobs の無い YAML は workflow でない", file_error("name: x\n") == "yaml-not-workflow")
check("明示の tag は読まない", file_error("jobs:\n  a:\n    steps:\n      - uses: !!str x\n") == "yaml-unreadable")
check("重なる key は読まない", file_error("jobs:\n  a:\n    steps: []\n  a:\n    steps: []\n") == "yaml-unreadable")
check("複数行の uses は scalar として読まない", file_error("jobs:\n  a:\n    steps:\n      - uses: >-\n          o/r@x\n") == "uses-not-scalar")
check("文書が 2 つは読まない", file_error("jobs:\n  a: {}\n---\njobs:\n  b: {}\n") == "yaml-unreadable")

exit(@failed.zero? ? 0 : 1)
RUBY

# ---- integration: fake gh 経由 ------------------------------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
# argv 全体を endpoint ごとに照合して fixture を返す。無い fixture は 404 (gh の文言を stderr に)、想定外の argv は失敗。
# stderr には常に canary を出す (script が親の出力へ流さないことを固定する)。
cat > "$fakebin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> $(shq "$tmp/gh-argv.log")
echo "STDERR-CANARY-do-not-echo \$*" >&2
[ "\${FAKE_GH_RC:-0}" -eq 0 ] || exit "\$FAKE_GH_RC"
fix=\$FAKE_FIX_DIR
args=\$*
serve() {
  if [ -f "\$1" ]; then cat "\$1"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
}
if printf '%s' "\$args" | grep -Eq '^api repos/[^/ ]+/[^/ ]+/pulls/[0-9]+\$'; then
  n=\$(cat "\$fix/pull-count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$fix/pull-count"
  if [ "\$n" -ge 2 ] && [ -f "\$fix/pull2.json" ]; then serve "\$fix/pull2.json"; else serve "\$fix/pull.json"; fi
elif printf '%s' "\$args" | grep -Eq '^api --paginate --slurp repos/[^/ ]+/[^/ ]+/pulls/[0-9]+/files\\?per_page=100\$'; then
  serve "\$fix/files.json"
elif printf '%s' "\$args" | grep -Eq '^api repos/[^/ ]+/[^/ ]+/contents/[^ ?]+\\?ref=[0-9a-f]{40}\$'; then
  rel=\$(printf '%s' "\$args" | sed -E 's#^api repos/[^/ ]+/[^/ ]+/contents/([^ ?]+)\\?ref=([0-9a-f]{40})\$#\\2/\\1#')
  serve "\$fix/contents/\$rel.json"
elif printf '%s' "\$args" | grep -Eq '^api repos/[^/ ]+/[^/ ]+/git/ref/tags/[^ /]+\$'; then
  rel=\$(printf '%s' "\$args" | sed -E 's#^api repos/([^/ ]+/[^/ ]+)/git/ref/tags/([^ /]+)\$#\\1/\\2#')
  serve "\$fix/tags/\$rel.json"
elif printf '%s' "\$args" | grep -Eq '^api repos/[^/ ]+/[^/ ]+/git/tags/[0-9a-f]{40}\$'; then
  rel=\$(printf '%s' "\$args" | sed -E 's#^.*/git/tags/([0-9a-f]{40})\$#\\1#')
  serve "\$fix/tagobj/\$rel.json"
elif printf '%s' "\$args" | grep -Eq '^api repos/[^/ ]+/[^/ ]+/commits/[0-9a-f]{40}/check-runs\\?check_name=[^&]+&per_page=100\$'; then
  rel=\$(printf '%s' "\$args" | sed -E 's#^.*check-runs\\?check_name=([^&]+)&per_page=100\$#\\1#')
  serve "\$fix/checkruns/\$rel.json"
else
  echo "fake gh: undefined endpoint" >&2; exit 1
fi
EOF
chmod +x "$fakebin/gh"

run_check() {
  rm -f "$fix/$1/pull-count"
  env PATH="$fakebin:$PATH" FAKE_FIX_DIR="$fix/$1" ruby "$src" "${2:-555}" ${3:+--repo "$3"}
}

base_sha=$(printf '%040x' 101)
head_sha=$(printf '%040x' 102)

# ok: 1 pin の bump、CI 2 本 success -> exit 0。stdout は閉じた label だけ (本文・patch・stderr の canary を出さない)
set +e
out=$(run_check ok 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "ok scenario should pass (rc=$rc): $out"
case "$out" in *"INJECTION-CANARY"*|*"STDERR-CANARY"*) fail "output must not echo the PR body / patch / gh stderr: $out" ;; esac
out=$(run_check ok 2>/dev/null)
expected="target: base $base_sha / head $head_sha
.github/workflows/test.yml: pin-only-change (1 line(s))
.github/workflows/test.yml:12: pin-ok (v1.329.0 -> v1.331.0)
ci self-tests (3.4): success
ci self-tests (system): success
pin-check: ok (1 pin(s), 2 check(s))"
[ "$out" = "$expected" ] || fail "ok stdout must be the closed labels only: $out"
# pulls/<n> は最初と最後に読む (snapshot)
[ "$(grep -c '^api repos/{owner}/{repo}/pulls/555$' "$tmp/gh-argv.log")" -ge 2 ] || fail "pulls/<n> should be read twice: $(cat "$tmp/gh-argv.log")"
grep -q '^api repos/ruby/setup-ruby/git/ref/tags/v1.331.0$' "$tmp/gh-argv.log" || fail "the tag should be resolved in the action's repository"

# --repo は全 path に埋まる
: > "$tmp/gh-argv.log"
set +e
run_check ok 12 "owner/repo" >/dev/null 2>&1
set -e
grep -q '^api repos/owner/repo/pulls/12$' "$tmp/gh-argv.log" || fail "--repo should be embedded in the pulls path"
grep -q "^api repos/owner/repo/contents/.github/workflows/test.yml?ref=$head_sha$" "$tmp/gh-argv.log" || fail "--repo should be embedded in the contents path"
grep -q "^api repos/owner/repo/commits/$head_sha/check-runs?check_name=self-tests+%283.4%29&per_page=100$" "$tmp/gh-argv.log" || fail "check-runs query should carry the encoded name: $(cat "$tmp/gh-argv.log")"

# not ok の scenario: exit 1 と label
expect_not_ok() {
  set +e
  out=$(run_check "$1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "$1 should be not ok (rc=$rc): $out"
  echo "$out" | grep -q "$2" || fail "$1 should print $2: $out"
  echo "$out" | grep -q '^pin-check: not ok$' || fail "$1 should end with not ok: $out"
  case "$out" in *"INJECTION-CANARY"*|*"STDERR-CANARY"*) fail "$1 must not echo canaries: $out" ;; esac
}
expect_not_ok notcommit "tag-not-commit"
expect_not_ok tagmissing "tag-not-found"
expect_not_ok mismatch "pin-mismatch"
expect_not_ok backward "version-not-forward (v1.329.0 -> v1.328.0)"
expect_not_ok sameversion "version-not-forward"
expect_not_ok refchanged "ref-changed"
expect_not_ok nonpin "non-pin-change"
expect_not_ok runblock "non-pin-change"
expect_not_ok structure "structure-changed"
expect_not_ok nochange "no-pin-bump"
expect_not_ok outside "not-workflow-file"
expect_not_ok added "not-modified (added)"
expect_not_ok unsafename "not-workflow-file"
expect_not_ok yamltag "yaml-unreadable"
expect_not_ok folded "uses-not-scalar"
expect_not_ok cifail "ci self-tests (system): failure"
expect_not_ok cipending "ci self-tests (system): pending"
expect_not_ok cimissing "ci self-tests (system): missing"
expect_not_ok cimixed "ci self-tests (system): failure"
expect_not_ok ciundef "ci-undefined"
expect_not_ok ciempty "ci-undefined"
expect_not_ok toolarge "file-too-large"

# annotated tag は commit に解いて ok
set +e
out=$(run_check annotated 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "annotated tag should resolve to the commit (rc=$rc): $out"
grep -q "^api repos/ruby/setup-ruby/git/tags/$(printf '%040x' 14)$" "$tmp/gh-argv.log" || fail "the tag object should be read"

# outside: workflow の file の方は pin-only-change と出し、外の file の名前は出さない
set +e
out=$(run_check outside 2>&1)
set -e
echo "$out" | grep -q "test.yml: pin-only-change" || fail "the workflow file should still be labelled: $out"
case "$out" in *README*) fail "a file outside the workflows must not be named: $out" ;; esac

# 判定できない -> exit 2: head が動いた / changed_files と数が合わない / file が多すぎる / gh の失敗 / usage
set +e
run_check snapshot >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a moved head must be exit 2 (rc=$rc)"
set +e
run_check countmismatch >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "changed_files mismatch must be exit 2 (rc=$rc)"
set +e
run_check toomany >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "too many files must be exit 2 (rc=$rc)"
set +e
env PATH="$fakebin:$PATH" FAKE_FIX_DIR="$fix/ok" FAKE_GH_RC=1 ruby "$src" 555 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "gh failure must be exit 2 (rc=$rc)"
set +e
ruby "$src" not-a-number >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "non-numeric PR must be exit 2 (rc=$rc)"
set +e
ruby "$src" 12 --repo "bad repo" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "malformed --repo must be exit 2 (rc=$rc)"
set +e
ruby "$src" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing PR must be exit 2 (rc=$rc)"

echo "ok: dependabot-pin-check self-test"
