#!/bin/sh
# probe-credential-isolation.sh と lib/credential_isolation_recipe.sh の self-test。
# 実 credential / network には触らない (probe の実行そのものは実機・PR ログが正本)。
# ここで検証するのは: 隔離 recipe の env 構造 / config 不在時の明示 fail /
# dry-run の組み立て / 非 repo cwd での実行。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe="$script_dir/../probe-credential-isolation.sh"
recipe="$script_dir/../lib/credential_isolation_recipe.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --- case 1: 隔離 recipe が認証源 env を構造的に断つ ---
# iso_run 内で見える env を書き出し、ambient の認証源が漏れていないことを確認する。
# shellcheck source=scripts/lib/credential_isolation_recipe.sh
. "$recipe"

# ambient に認証源 env を仕込んでも、隔離 session からは見えないこと。
export SSH_AUTH_SOCK="/tmp/fake-agent.sock"
export GH_TOKEN="fake-token-should-not-leak"
export GITHUB_TOKEN="fake-token-should-not-leak"

scratch=$(iso_make_scratch)
[ -d "$scratch/home" ] || fail "iso_make_scratch should create home"
[ -d "$scratch/cwd" ] || fail "iso_make_scratch should create non-repo cwd"

iso_run "$scratch" sh -c '
  printf "HOME=%s\n" "$HOME"
  printf "GH_CONFIG_DIR=%s\n" "$GH_CONFIG_DIR"
  printf "NETRC=%s\n" "$NETRC"
  printf "SSH_AUTH_SOCK=[%s]\n" "${SSH_AUTH_SOCK:-<unset>}"
  printf "GH_TOKEN=[%s]\n" "${GH_TOKEN:-<unset>}"
  printf "GITHUB_TOKEN=[%s]\n" "${GITHUB_TOKEN:-<unset>}"
  printf "GIT_CONFIG_NOSYSTEM=%s\n" "${GIT_CONFIG_NOSYSTEM:-<unset>}"
  printf "cwd=%s\n" "$(pwd -P)"
' > "$tmp/env-out" 2>&1 || fail "iso_run should execute the command"

grep -q "^HOME=$scratch/home$" "$tmp/env-out" || fail "isolated HOME not set: $(cat "$tmp/env-out")"
grep -q "^GH_CONFIG_DIR=$scratch/gh$" "$tmp/env-out" || fail "isolated GH_CONFIG_DIR not set"
grep -q "^NETRC=/dev/null$" "$tmp/env-out" || fail "NETRC not isolated"
grep -q "^SSH_AUTH_SOCK=\[<unset>\]$" "$tmp/env-out" || fail "SSH_AUTH_SOCK leaked into isolation"
grep -q "^GH_TOKEN=\[<unset>\]$" "$tmp/env-out" || fail "GH_TOKEN leaked into isolation"
grep -q "^GITHUB_TOKEN=\[<unset>\]$" "$tmp/env-out" || fail "GITHUB_TOKEN leaked into isolation"
grep -q "^GIT_CONFIG_NOSYSTEM=1$" "$tmp/env-out" || fail "GIT_CONFIG_NOSYSTEM not set"
# 非 repo scratch cwd で実行される (repo 内の .git/config を読まない)
grep -q "cwd=.*$scratch/cwd$" "$tmp/env-out" || fail "iso_run did not use non-repo scratch cwd: $(cat "$tmp/env-out")"
rm -rf "$scratch"

unset SSH_AUTH_SOCK GH_TOKEN GITHUB_TOKEN

# --- case 2: iso_run は呼び出し側の cwd を汚さない (subshell 実行) ---
before=$(pwd -P)
scratch2=$(iso_make_scratch)
iso_run "$scratch2" true
after=$(pwd -P)
[ "$before" = "$after" ] || fail "iso_run must not change caller cwd ($before -> $after)"
rm -rf "$scratch2"

# --- case 3: amb_run (positive) も非 repo cwd で実行し呼び出し側の cwd を汚さない ---
# negative (iso_run) と positive (amb_run) の唯一の差分を env 隔離だけにするため、positive も
# 非 repo cwd で走る (operation identity, #168 レビュー)。
before3=$(pwd -P)
amb_run sh -c 'echo "amb_cwd=$(pwd -P)"' > "$tmp/amb-out" 2>&1 || fail "amb_run should execute"
after3=$(pwd -P)
[ "$before3" = "$after3" ] || fail "amb_run must not change caller cwd ($before3 -> $after3)"
grep -q "amb_cwd=" "$tmp/amb-out" || fail "amb_run should run the command"
# amb_run の cwd は呼び出し側 (この repo) とは別の非 repo 一時 dir であること
amb_cwd=$(sed 's/amb_cwd=//' "$tmp/amb-out")
[ "$amb_cwd" != "$before3" ] || fail "amb_run must use a neutral (non-caller) cwd"
[ ! -e "$amb_cwd/.git" ] || fail "amb_run cwd must not be a git repo"

# --- case 4: probe target config が無ければ明示 fail (exit 2・silent skip しない) ---
status=0
"$probe" --config "$tmp/nonexistent.local" > "$tmp/out-nocfg" 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "missing config should exit 2, got $status: $(cat "$tmp/out-nocfg")"
grep -q "probe target config not found" "$tmp/out-nocfg" || fail "missing config message absent"

# --- case 5: required キー欠落は明示 fail (exit 2)。curl は required でない (#129 P3-02) ---
cat > "$tmp/partial.local" <<'EOF'
PROBE_GH_REPO=owner/repo
EOF
status=0
"$probe" --config "$tmp/partial.local" > "$tmp/out-partial" 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "partial config should exit 2, got $status: $(cat "$tmp/out-partial")"
grep -q "missing required keys" "$tmp/out-partial" || fail "partial config should name missing required keys"
grep -q "PROBE_GIT_HTTPS" "$tmp/out-partial" || fail "missing key list should include PROBE_GIT_HTTPS"
grep -q "PROBE_GIT_SSH" "$tmp/out-partial" && fail "PROBE_GIT_SSH must not be a required key (opt-in)"
grep -q "PROBE_CURL_URL" "$tmp/out-partial" && fail "PROBE_CURL_URL must not be a required key (opt-in)"

# --- case 5b: required 2 キーのみ (git-ssh/curl 無し) の config は valid。dry-run で両方 skip ---
cat > "$tmp/two.local" <<'EOF'
PROBE_GH_REPO=owner/private-repo
PROBE_GIT_HTTPS=https://github.com/owner/private-repo.git
EOF
"$probe" --config "$tmp/two.local" --dry-run > "$tmp/out-two" 2>&1 \
  || fail "2-key config dry-run should exit 0: $(cat "$tmp/out-two")"
grep -q "git-ssh .*skipped" "$tmp/out-two" || fail "git-ssh should be skipped when PROBE_GIT_SSH unset: $(cat "$tmp/out-two")"
grep -q "curl .*skipped" "$tmp/out-two" || fail "curl should be skipped when PROBE_CURL_URL unset: $(cat "$tmp/out-two")"
for ch in gh git-https; do
  grep -q "^# $ch .*cmd:" "$tmp/out-two" || fail "2-key dry-run missing $ch cmd"
done

# --- case 6: dry-run は実行せず全チャネルの (negative/positive 共通) command を表示する ---
cat > "$tmp/full.local" <<'EOF'
PROBE_GH_REPO=owner/private-repo
PROBE_GIT_HTTPS=https://github.com/owner/private-repo.git
PROBE_GIT_SSH=git@github.com:owner/private-repo.git
PROBE_CURL_URL=https://api.github.com/repos/owner/private-repo
EOF
"$probe" --config "$tmp/full.local" --dry-run > "$tmp/out-dry" 2>&1 \
  || fail "dry-run should exit 0: $(cat "$tmp/out-dry")"
for ch in gh git-https git-ssh curl; do
  grep -q "^# $ch .*cmd:" "$tmp/out-dry" || fail "dry-run missing $ch cmd"
done
# negative = iso_run <cmd>、positive = amb_run <cmd> で cmd は同一 (operation identity)
grep -q "negative = iso_run" "$tmp/out-dry" || fail "dry-run should describe negative as iso_run"
grep -q "positive = amb_run" "$tmp/out-dry" || fail "dry-run should describe positive as amb_run"
grep -q " ls-remote https://github.com/owner/private-repo.git" "$tmp/out-dry" \
  || fail "dry-run git-https cmd should be plain ls-remote (no per-invocation flags)"
grep -q "credential.helper=" "$tmp/out-dry" && fail "probe must not pass per-invocation git -c flags (breaks operation identity)"
# executable identity: git/gh は canonical PATH で解決した絶対パスに pin される (#168 レビュー)
grep -q "pinned binaries" "$tmp/out-dry" || fail "dry-run should report pinned binaries"
grep -qE "gh=/[^ ]+ git=/[^ ]+" "$tmp/out-dry" \
  || fail "dry-run should pin gh/git to absolute paths: $(grep 'pinned' "$tmp/out-dry")"

# --- case 6b: iso_resolve_bin は canonical PATH で絶対パスを返す ---
resolved=$(iso_resolve_bin git)
case "$resolved" in
  /*) ;;
  *) fail "iso_resolve_bin git should return an absolute path, got: $resolved" ;;
esac

# --- case 7: dry-run の出力が judge の実 results.json 形と整合 (operation の ch 別一致) ---
# 生成される results.json の operation id が negative/positive でチャネル毎に一致すること
# (judge の pair 判定の前提) を、runner 内の emit テンプレートと同じ id で確認する。
for op in gh-api-repo git-https-lsremote git-ssh-lsremote curl-api-repo; do
  grep -q "$op" "$script_dir/../probe-credential-isolation.sh" \
    || fail "runner should define operation id $op"
done

echo "ok: probe-credential-isolation self-test passed"
