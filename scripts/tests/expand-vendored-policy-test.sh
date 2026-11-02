#!/bin/sh
# scripts/expand-vendored-policy.sh (takt の facet の include の展開, #622) の self-test。
# 一時 directory に upstream の形の fixture を作り、展開の規則 (takt の facet-includes と同じ) を固定する。
# 最後に、vendor した review.md に include の token が残っていないかを見る。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
expand="$script_dir/../expand-vendored-policy.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

facets=builtins/ja/facets
root="$tmp/root"
mkdir -p "$root/$facets/policies" "$root/$facets/partials/policies" "$root/$facets/partials/knowledge"

# 展開して、stdout を $tmp/out、stderr を $tmp/err に残し、exit code を確かめる。
# 使い方: run_expand <label> <want-exit> <entry> [追加の引数]...
run_expand() {
  re_label=$1
  re_want=$2
  re_entry=$3
  shift 3
  re_status=0
  "$expand" --root "$root" --facets-root "$facets" --entry "$re_entry" "$@" > "$tmp/out" 2> "$tmp/err" || re_status=$?
  [ "$re_status" -eq "$re_want" ] \
    || fail "$re_label: expected exit $re_want, got $re_status: $(cat "$tmp/out" "$tmp/err")"
}

# --- 入れ子の展開。token だけを置き換え、token の外の文字と改行は残す ---
printf '# Review\n\n{{include:policies/common}}\nafter\n' > "$root/$facets/policies/review.md"
printf 'common head\n{{ include : policies/leaf }} tail\n' > "$root/$facets/partials/policies/common.md"
printf 'LEAF' > "$root/$facets/partials/policies/leaf.md"
run_expand "nested" 0 "$facets/policies/review.md"
printf '# Review\n\ncommon head\nLEAF tail\n\nafter\n' > "$tmp/want"
cmp -s "$tmp/out" "$tmp/want" || fail "nested expansion differs: $(od -c "$tmp/out" | head -5)"

# --- 同じ partial を 2 回 include するのは循環ではない。kind の違う partial も読める ---
printf 'A{{include:policies/leaf}}B{{include:policies/leaf}}C {{include:knowledge/k}}\n' > "$root/$facets/policies/twice.md"
printf 'K' > "$root/$facets/partials/knowledge/k.md"
run_expand "twice" 0 "$facets/policies/twice.md"
[ "$(cat "$tmp/out")" = "ALEAFBLEAFC K" ] || fail "repeated include: $(cat "$tmp/out")"

# --- --check は一致で 0、違えば 1。どちらも stdout には出さない ---
printf '# Review\n\ncommon head\nLEAF tail\n\nafter\n' > "$tmp/vendored"
run_expand "check same" 0 "$facets/policies/review.md" --check "$tmp/vendored"
[ ! -s "$tmp/out" ] || fail "--check must not print the expansion"
printf 'stale\n' > "$tmp/stale"
run_expand "check differs" 1 "$facets/policies/review.md" --check "$tmp/stale"
grep -q "differs" "$tmp/err" || fail "check differs: missing message: $(cat "$tmp/err")"
run_expand "check missing file" 1 "$facets/policies/review.md" --check "$tmp/no-such-file"

# --- 循環は error (自分自身と、2 段の循環) ---
printf 'x{{include:policies/self}}\n' > "$root/$facets/partials/policies/self.md"
printf '{{include:policies/self}}\n' > "$root/$facets/policies/self-entry.md"
run_expand "self cycle" 2 "$facets/policies/self-entry.md"
grep -q "cyclic include" "$tmp/err" || fail "self cycle: $(cat "$tmp/err")"
printf '{{include:policies/b}}' > "$root/$facets/partials/policies/a.md"
printf '{{include:policies/a}}' > "$root/$facets/partials/policies/b.md"
printf '{{include:policies/a}}\n' > "$root/$facets/policies/ab.md"
run_expand "two-step cycle" 2 "$facets/policies/ab.md"
grep -q "cyclic include" "$tmp/err" || fail "two-step cycle: $(cat "$tmp/err")"

# --- 見つからない partial、形の外れた参照は error で、何も出さない ---
# `policies/../x` の行き先 (partials/x.md) には file を置き、名前の検査だけで止まることを見る。
printf 'escaped\n' > "$root/$facets/partials/x.md"
for ref in policies/none 'policies/../x' 'unknown/leaf' 'policies' 'policies/@owner/x' ''; do
  printf '{{include:%s}}\n' "$ref" > "$root/$facets/policies/bad.md"
  run_expand "bad ref '$ref'" 2 "$facets/policies/bad.md"
  [ ! -s "$tmp/out" ] || fail "bad ref '$ref' must not print a partial expansion"
done

# --- partial が symlink なら読まない (取得した tree の外を読まない) ---
printf 'outside\n' > "$tmp/outside.md"
ln -s "$tmp/outside.md" "$root/$facets/partials/policies/link.md"
printf '{{include:policies/link}}\n' > "$root/$facets/policies/link-entry.md"
run_expand "symlink partial" 2 "$facets/policies/link-entry.md"

# --- entry が無い、引数が足りない ---
run_expand "missing entry" 2 "$facets/policies/none.md"
st=0; "$expand" --root "$root" > "$tmp/out" 2> "$tmp/err" || st=$?
[ "$st" -eq 2 ] || fail "missing args: expected exit 2, got $st"

# --- vendor した review.md に include の token が残っていない ---
vendored="$script_dir/../../shared/skills/personal-production-rail/references/policies/review.md"
grep -q '{{[[:space:]]*include' "$vendored" && fail "vendored review.md still has include tokens"

echo "ok: expand-vendored-policy"
