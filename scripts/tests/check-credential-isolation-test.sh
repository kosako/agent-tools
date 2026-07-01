#!/bin/sh
# check-credential-isolation.sh の self-test。
# probe 結果 fixture を一時生成して判定ロジックを検証する。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check="$script_dir/../check-credential-isolation.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# usage: run_case <name> <json-file> <expected-exit> [grep-pattern]
run_case() {
  name=$1; file=$2; want=$3; pat=${4:-}
  status=0
  "$check" --judge "$file" > "$tmp/out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "$name: expected exit $want, got $status: $(cat "$tmp/out")"
  if [ -n "$pat" ]; then
    grep -q "$pat" "$tmp/out" || fail "$name: missing '$pat' in: $(cat "$tmp/out")"
  fi
}

# --- case 1: 4 canonical channel が同一 operation ペアで揃い polarity 正なら pass (exit 0) ---
cat > "$tmp/pass.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-ssh",   "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-ssh",   "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "all-clean" "$tmp/pass.json" 0 "isolation verified"

# --- case 2: negative が認証を通したら credential leak (exit 1) ---
cat > "$tmp/leak.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": true},
    {"channel": "gh",        "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-ssh",   "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-ssh",   "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "leak" "$tmp/leak.json" 1 "credential leak: negative probe authenticated on channel gh"

# --- case 3: positive-control が失敗したら false-green (exit 1) ---
cat > "$tmp/falsegreen.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "read-priv", "authenticated": false},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-ssh",   "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-ssh",   "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "false-green" "$tmp/falsegreen.json" 1 "false-green: positive-control probe failed on channel gh"

# --- case 4: negative/positive の operation がずれたら pair 不成立 (exit 1) ---
cat > "$tmp/mismatch.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv",   "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "read-public", "authenticated": true},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv",   "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv",   "authenticated": true},
    {"channel": "git-ssh",   "mode": "negative", "operation": "read-priv",   "authenticated": false},
    {"channel": "git-ssh",   "mode": "positive", "operation": "read-priv",   "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv",   "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv",   "authenticated": true}
  ]
}
EOF
run_case "operation-mismatch" "$tmp/mismatch.json" 1 "channel gh: operation mismatch"

# --- case 5: canonical channel を丸ごと欠くと fail (偽の安心を弾く) ---
cat > "$tmp/missing.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "missing-channel" "$tmp/missing.json" 1 "channel git-ssh: expected exactly one negative probe, got 0"

# --- case 6: 同一 channel/mode の重複は曖昧なので fail ---
cat > "$tmp/dup.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "git-ssh",   "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "git-ssh",   "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "duplicate-probe" "$tmp/dup.json" 1 "channel gh: expected exactly one negative probe, got 2"

# --- case 7: 旧 required_channels bypass の回帰検出。
#     top-level required_channels を無視し、canonical 全チャネルを要求し続けること。 ---
cat > "$tmp/legacy-required.json" <<'EOF'
{
  "required_channels": ["gh"],
  "probes": [
    {"channel": "gh", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh", "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "legacy-required-channels-ignored" "$tmp/legacy-required.json" 1 \
  "channel git-https: expected exactly one negative probe, got 0"

# --- case 8: canonical 外の channel は入力エラー (exit 2) ---
cat > "$tmp/unknown.json" <<'EOF'
{ "probes": [ {"channel": "wat", "mode": "negative", "operation": "read-priv", "authenticated": false} ] }
EOF
run_case "unknown-channel" "$tmp/unknown.json" 2 "channel must be one of"

# --- case 9: operation 欠落は入力エラー (exit 2) ---
cat > "$tmp/noop.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "negative", "authenticated": false} ] }
EOF
run_case "missing-operation" "$tmp/noop.json" 2 "operation must be a non-empty string"

# --- case 10: 型不正 (authenticated が boolean でない) は入力エラー (exit 2) ---
cat > "$tmp/badtype.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "negative", "operation": "read-priv", "authenticated": "false"} ] }
EOF
run_case "bad-probe-type" "$tmp/badtype.json" 2 "authenticated must be a boolean"

# --- case 11: 不正 JSON は silent pass せず入力エラー (exit 2) ---
printf '{ not json ' > "$tmp/bad.json"
run_case "malformed-json" "$tmp/bad.json" 2 "error:"

# --- case 12: 引数不正 (--judge なし) は usage を出して exit 2 ---
status=0
"$check" > "$tmp/out" 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "usage: expected exit 2, got $status: $(cat "$tmp/out")"
grep -q "usage: check-credential-isolation.sh" "$tmp/out" \
  || fail "usage: missing usage text: $(cat "$tmp/out")"

# --- case 13: 存在しない results file は入力エラー (exit 2) ---
run_case "missing-file" "$tmp/does-not-exist.json" 2 "results file not found"

echo "ok: check-credential-isolation self-test passed"
