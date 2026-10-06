#!/bin/sh
# personal-maintenance-sweep の fix モードの、check-injection の exit 3 の比べ方の self-test (#419)。
# FIX.md の「## 検証 (累積差分に対して)」の節にある比べ方の sh の code block (comm -13 を含むもの) を切り出し、
# 合成した check-injection の出力 (base と branch) で sh と zsh で走らせる。branch にだけある finding の行が
# あれば exit 1、無ければ exit 0。同じ file・同じ category の finding が増えた場合も止まる (Codex review の F1)。
# 出力の file が無い、一時 directory を作れないなど、比べられないときは exit 2 で止まる (fail-closed。F3)。
# noclobber の再実行でも、前回の途中の file に引きずられない。
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
sweep_dir=${1:-"$script_dir/../../shared/skills/personal-maintenance-sweep"}

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

ruby - "$sweep_dir/FIX.md" "$tmp/compare.sh" <<'RUBY'
src, out = ARGV
text = File.read(src)
section = text[/^## 検証 \(累積差分に対して\)\n(.*?)(?=^## )/m, 1]
abort "FIX.md に「## 検証 (累積差分に対して)」の節が無い" unless section
blocks = section.scan(/^( *)```sh\n(.*?)^\1```/m).map { |indent, body| body.lines.map { |l| l.sub(/\A#{indent}/, "") }.join }
cmp = blocks.select { |b| b.include?("comm -13") }
abort "検証の節に比べ方の sh の block (comm -13) が 1 つでない (#{cmp.size} 個)" unless cmp.size == 1
File.write(out, cmp.first)
RUBY

warn_line='warn: medium risk findings present (human review required)'
f30='shared/skills/personal-asset-miner/SKILL.md:30: [medium] runtime-state: references tool-managed or runtime state paths'
f31='shared/skills/personal-asset-miner/SKILL.md:31: [medium] runtime-state: references tool-managed or runtime state paths'
f40='shared/skills/personal-asset-miner/SKILL.md:40: [medium] runtime-state: references tool-managed or runtime state paths'
f32='shared/skills/personal-asset-miner/SKILL.md:32: [medium] runtime-state: references tool-managed or runtime state paths'
printf '%s\n' "$warn_line" "$f30" "$f31" > "$tmp/base.out"

# $1 = shell の argv、残り = branch の出力の行。exit code を rc に入れる。
run_compare() {
  rc_shell=$1
  shift
  printf '%s\n' "$@" > "$tmp/branch.out"
  rc=0
  # shellcheck disable=SC2086 # rc_shell は下の定数 (sh / zsh -f)
  (cd "$tmp" && env inj_base="$tmp/base.out" inj_branch="$tmp/branch.out" $rc_shell "$tmp/compare.sh") > "$tmp/out" 2>&1 || rc=$?
}

ran=0
for shell in sh zsh; do
  command -v "$shell" > /dev/null 2>&1 || continue
  case $shell in
    zsh) shell_argv='zsh -f' ;;
    *) shell_argv=sh ;;
  esac
  ran=$((ran + 1))

  # (a) 同じ finding だけなら続行 (exit 0)。
  run_compare "$shell_argv" "$warn_line" "$f30" "$f31"
  [ "$rc" -eq 0 ] || fail "[$shell] identical findings did not pass (rc=$rc): $(cat "$tmp/out")"

  # (b) 同じ file・同じ category の finding が別の行に増えたら止まる (F1)。
  run_compare "$shell_argv" "$warn_line" "$f30" "$f31" "$f40"
  [ "$rc" -eq 1 ] || fail "[$shell] a new finding with the same file and category did not stop (rc=$rc)"
  grep -q 'SKILL.md:40:' "$tmp/out" || fail "[$shell] the new finding was not reported: $(cat "$tmp/out")"

  # (c) 同じ行の finding の件数が増えたら止まる。
  run_compare "$shell_argv" "$warn_line" "$f30" "$f31" "$f31"
  [ "$rc" -eq 1 ] || fail "[$shell] a duplicated finding did not stop (rc=$rc)"

  # (d) finding が減っただけなら続行。
  run_compare "$shell_argv" "$warn_line" "$f30"
  [ "$rc" -eq 0 ] || fail "[$shell] a removed finding did not pass (rc=$rc): $(cat "$tmp/out")"

  # (e) 行番号がずれただけでも止まる (安全側。人に見せて判断する)。
  run_compare "$shell_argv" "$warn_line" "$f31" "$f32"
  [ "$rc" -eq 1 ] || fail "[$shell] shifted line numbers did not stop (rc=$rc)"

  # (f) branch の出力の file が無ければ、比べられないので止まる (exit 2。F3)。
  rc=0
  # shellcheck disable=SC2086
  (cd "$tmp" && env inj_base="$tmp/base.out" inj_branch="$tmp/missing.out" $shell_argv "$tmp/compare.sh") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "[$shell] a missing branch output did not stop with exit 2 (rc=$rc): $(cat "$tmp/out")"

  # (g) 一時 directory を作れなければ止まる (exit 2。F3)。PATH の先頭の偽の mktemp で失敗させる。
  mkdir -p "$tmp/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/fakebin/mktemp"
  chmod +x "$tmp/fakebin/mktemp"
  rc=0
  # shellcheck disable=SC2086
  (cd "$tmp" && env PATH="$tmp/fakebin:$PATH" inj_base="$tmp/base.out" inj_branch="$tmp/branch.out" $shell_argv "$tmp/compare.sh") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "[$shell] a failing mktemp did not stop with exit 2 (rc=$rc): $(cat "$tmp/out")"

  # (h) noclobber (set -C) で再実行しても、前回の結果に引きずられず新しい finding で止まる (F3 の round 3)。
  #     呼び出し側の path の横に古い途中の file を置いても使わない。
  printf '%s\n' "$warn_line" "$f30" "$f31" > "$tmp/branch.out"
  : > "$tmp/base.out.findings"
  : > "$tmp/branch.out.findings"
  rc=0
  # shellcheck disable=SC2086
  (cd "$tmp" && env inj_base="$tmp/base.out" inj_branch="$tmp/branch.out" $shell_argv -C "$tmp/compare.sh") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "[$shell] identical findings under noclobber did not pass (rc=$rc): $(cat "$tmp/out")"
  printf '%s\n' "$warn_line" "$f30" "$f31" "$f40" > "$tmp/branch.out"
  rc=0
  # shellcheck disable=SC2086
  (cd "$tmp" && env inj_base="$tmp/base.out" inj_branch="$tmp/branch.out" $shell_argv -C "$tmp/compare.sh") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "[$shell] a new finding on a noclobber re-run did not stop (rc=$rc): $(cat "$tmp/out")"
done
[ "$ran" -gt 0 ] || fail "比べ方の command を走らせる shell (sh / zsh) が無い"

echo "ok: maintenance-sweep-fix-injection-compare"
