#!/bin/sh
# probe-credential-isolation.sh と lib/credential_isolation_recipe.sh の self-test。
# 実 credential / network には触らない (probe の実行そのものは実機・PR ログが正本)。
# ここで検証するのは: 隔離 recipe の env 構造 / config 不在時の明示 fail /
# dry-run の組み立て / 非 repo cwd での実行。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
probe="$script_dir/../probe-credential-isolation.sh"
recipe="$script_dir/../lib/credential_isolation_recipe.sh"
judge="$script_dir/../check-credential-isolation.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT


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
  grep -q "^# $ch .*reach:" "$tmp/out-two" || fail "2-key dry-run missing $ch reachability control (#185)"
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
  grep -q "^# $ch .*reach:" "$tmp/out-dry" || fail "dry-run missing $ch reachability control (#185)"
done
# negative = iso_run <cmd>、positive = amb_run <cmd> で cmd は同一 (operation identity)
grep -q "negative = iso_run" "$tmp/out-dry" || fail "dry-run should describe negative as iso_run"
grep -q "positive = amb_run" "$tmp/out-dry" || fail "dry-run should describe positive as amb_run"
grep -q " ls-remote https://github.com/owner/private-repo.git" "$tmp/out-dry" \
  || fail "dry-run git-https cmd should be plain ls-remote (no per-invocation flags)"
# curl channel は --netrc を明示する (無いと ~/.netrc を参照せず netrc auth を行使しない, #180)
grep -qE "^# curl .*cmd:.* --netrc " "$tmp/out-dry" \
  || fail "curl cmd should pass --netrc (netrc is the curl channel's auth source): $(grep '# curl' "$tmp/out-dry")"
grep -q "credential.helper=" "$tmp/out-dry" && fail "probe must not pass per-invocation git -c flags (breaks operation identity)"
# executable identity: git/gh は canonical PATH で解決した絶対パスに pin される (#168 レビュー)
grep -q "pinned binaries" "$tmp/out-dry" || fail "dry-run should report pinned binaries"
grep -qE "gh=/[^ ]+ git=/[^ ]+ curl=/[^ ]+ nc=/[^ ]+" "$tmp/out-dry" \
  || fail "dry-run should pin gh/git/curl/nc to absolute paths: $(grep 'pinned' "$tmp/out-dry")"
# reachability control (#185): 認証なし (--netrc なし・-f なし) の同一ホストアクセス。
grep -E "^# curl .*reach:" "$tmp/out-dry" | grep -q -- '--netrc' \
  && fail "curl reachability must be unauthenticated (no --netrc): $(grep '# curl' "$tmp/out-dry")"
grep -qE "^# gh .*reach:.*api\.github\.com/repos/owner/private-repo" "$tmp/out-dry" \
  || fail "gh reachability should hit the same host+path unauthenticated: $(grep '# gh' "$tmp/out-dry")"
# git-ssh reachability は scp 形式 URL から host を抽出した TCP 到達確認 (port 22)
grep -qE "^# git-ssh .*reach:.* -z .*github\.com 22" "$tmp/out-dry" \
  || fail "git-ssh reachability should be a TCP check against the extracted host: $(grep '# git-ssh' "$tmp/out-dry")"

# --- case 6b: iso_resolve_bin は canonical PATH で絶対パスを返す ---
resolved=$(iso_resolve_bin git)
case "$resolved" in
  /*) ;;
  *) fail "iso_resolve_bin git should return an absolute path, got: $resolved" ;;
esac

# --- case 7: dry-run の出力が judge の実 results.json 形と整合 (operation の ch 別一致) ---
# 生成される results.json の operation id が negative/positive でチャネル毎に一致すること
# (judge の pair 判定の前提) を、runner 内の emit テンプレートと同じ id で確認する。
# reachability は別コマンドなので別 id (<pair-op>-reach, #185)。
for op in gh-api-repo git-https-lsremote git-ssh-lsremote curl-api-repo \
          gh-api-repo-reach git-https-lsremote-reach git-ssh-lsremote-reach curl-api-repo-reach; do
  grep -q "$op" "$script_dir/../probe-credential-isolation.sh" \
    || fail "runner should define operation id $op"
done

# --- case 8: 実 negative/positive 呼び出しが --netrc を渡す (dry-run 表示だけでなく実行経路, #180) ---
# config で iso_run / amb_run / iso_resolve_bin を差し替えて実 argv を記録し、network を使わずに
# 両 curl 呼び出しが --netrc を持ち、negative/positive で argv が同一であることを検証する。
# (dry-run 表示は別文字列なので、実行経路から --netrc が消えても回帰テストが通ってしまう穴を塞ぐ。)
# iso_run は reachability control (curl --max-time / nc -z) だけ成功、auth negative は失敗を
# 返す → 生成 results.json が negative=false / positive=true / reachable=true になり、judge を
# そのまま通ることも pin する (runner/judge の契約整合 end-to-end, #185)。
argvlog="$tmp/argv.log"
: > "$argvlog"
cat > "$tmp/rec.local" <<EOF
PROBE_GH_REPO=owner/private-repo
PROBE_GIT_HTTPS=https://github.com/owner/private-repo.git
PROBE_GIT_SSH=git@github.com:owner/private-repo.git
PROBE_CURL_URL=https://api.github.com/repos/owner/private-repo
iso_resolve_bin() { echo "\$1"; }
iso_make_scratch() { echo "$tmp/recscratch"; }
iso_run() {
  shift; printf 'NEG %s\n' "\$*" >> "$argvlog"
  case "\$*" in *--max-time*|*" -z "*) return 0 ;; *) return 1 ;; esac
}
amb_run() { printf 'POS %s\n' "\$*" >> "$argvlog"; return 0; }
EOF
mkdir -p "$tmp/recscratch"
"$probe" --config "$tmp/rec.local" > "$tmp/out-rec" 2> "$tmp/err-rec" \
  || fail "recording run should exit 0: $(cat "$tmp/out-rec" "$tmp/err-rec")"
neg_curl=$(grep '^NEG curl ' "$argvlog" | grep -- '--netrc' || true)
pos_curl=$(grep '^POS curl ' "$argvlog" | grep -- '--netrc' || true)
[ -n "$neg_curl" ] || fail "negative curl invocation not recorded: $(cat "$argvlog")"
[ -n "$pos_curl" ] || fail "positive curl invocation not recorded: $(cat "$argvlog")"
# operation identity: NEG/POS の prefix を除いた argv が完全一致すること
[ "${neg_curl#NEG }" = "${pos_curl#POS }" ] \
  || fail "negative/positive curl argv must be identical: [$neg_curl] vs [$pos_curl]"
# reachability control は隔離 session (iso_run) 経由で、認証なし (--netrc なし) で走る (#185)
reach_curl_count=$(grep -c '^NEG curl -sS --max-time' "$argvlog" || true)
[ "$reach_curl_count" -eq 3 ] \
  || fail "expected 3 unauthenticated curl reachability probes (gh/git-https/curl), got $reach_curl_count: $(cat "$argvlog")"
grep '^NEG curl -sS --max-time' "$argvlog" | grep -q -- '--netrc' \
  && fail "reachability curl must not pass --netrc: $(cat "$argvlog")"
grep -q '^NEG nc -z -w 20 github.com 22$' "$argvlog" \
  || fail "git-ssh reachability should TCP-check the host extracted from the scp-style URL: $(cat "$argvlog")"
# 生成された results.json は judge をそのまま通る (契約整合の end-to-end pin, #185)
status=0
"$judge" --judge "$tmp/out-rec" > "$tmp/out-judge" 2>&1 || status=$?
[ "$status" -eq 0 ] \
  || fail "runner output should satisfy the judge contract, exit $status: $(cat "$tmp/out-judge"; cat "$tmp/out-rec")"
grep -q "isolation verified (4 channels" "$tmp/out-judge" \
  || fail "judge should verify 4 channels from runner output: $(cat "$tmp/out-judge")"

# --- case 9: PROBE_GIT_SSH が scp 形式でなければ明示 fail (exit 2・host 抽出を推測しない, #185) ---
cat > "$tmp/sshform.local" <<'EOF'
PROBE_GH_REPO=owner/private-repo
PROBE_GIT_HTTPS=https://github.com/owner/private-repo.git
PROBE_GIT_SSH=ssh://git@github.com/owner/private-repo.git
EOF
status=0
"$probe" --config "$tmp/sshform.local" --dry-run > "$tmp/out-sshform" 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "non-scp PROBE_GIT_SSH should exit 2, got $status: $(cat "$tmp/out-sshform")"
grep -q "must be scp-style" "$tmp/out-sshform" \
  || fail "non-scp PROBE_GIT_SSH message absent: $(cat "$tmp/out-sshform")"

echo "ok: probe-credential-isolation self-test passed"
