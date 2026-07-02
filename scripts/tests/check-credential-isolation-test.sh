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
# 直近の出力は $tmp/out に残る (追加 assert 用)。
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

# --- case 2: 被覆は床 (1組以上)。同一 channel に別 operation のペアを足しても pass (exit 0) ---
#     カバレッジを増やした runner を「破れ検出」で罰しないことを pin する。
cat > "$tmp/superset.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv",  "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "read-priv",  "authenticated": true},
    {"channel": "gh",        "mode": "negative", "operation": "clone-priv", "authenticated": false},
    {"channel": "gh",        "mode": "positive", "operation": "clone-priv", "authenticated": true},
    {"channel": "git-https", "mode": "negative", "operation": "read-priv",  "authenticated": false},
    {"channel": "git-https", "mode": "positive", "operation": "read-priv",  "authenticated": true},
    {"channel": "git-ssh",   "mode": "negative", "operation": "read-priv",  "authenticated": false},
    {"channel": "git-ssh",   "mode": "positive", "operation": "read-priv",  "authenticated": true},
    {"channel": "curl",      "mode": "negative", "operation": "read-priv",  "authenticated": false},
    {"channel": "curl",      "mode": "positive", "operation": "read-priv",  "authenticated": true}
  ]
}
EOF
run_case "superset-coverage" "$tmp/superset.json" 0 "isolation verified"

# --- case 3: negative が認証を通したら credential leak (exit 1) ---
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

# --- case 4: positive-control が失敗したら false-green (exit 1) ---
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

# --- case 5: negative/positive の operation がずれたら完全ペア不成立 = 構造エラー (exit 2) ---
#     破れの観測ではないので 1 ではなく 2 (入力・構造エラー)。
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
run_case "operation-mismatch" "$tmp/mismatch.json" 2 "channel gh: no complete negative/positive probe pair"

# --- case 6: canonical channel を丸ごと欠くと構造エラー (exit 2・偽の安心を弾く) ---
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
run_case "missing-channel" "$tmp/missing.json" 2 "channel git-ssh: no complete negative/positive probe pair"

# --- case 7: 同一 (channel, operation, mode) の重複は曖昧 = 構造エラー (exit 2) ---
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
run_case "duplicate-probe" "$tmp/dup.json" 2 \
  "channel gh (operation read-priv): expected exactly one negative probe, got 2"

# --- case 8: 構造不備と破れが同居したら、破れを優先して exit 1 かつ両方報告する ---
#     (構造エラーの陰で leak の証跡が報告から漏れない = 抑制しないことを pin) ---
cat > "$tmp/dup-and-leak.json" <<'EOF'
{
  "probes": [
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": true},
    {"channel": "gh",        "mode": "negative", "operation": "read-priv", "authenticated": true},
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
run_case "breach-with-structural" "$tmp/dup-and-leak.json" 1 \
  "credential leak: negative probe authenticated on channel gh"
grep -q "expected exactly one negative probe, got 2" "$tmp/out" \
  || fail "breach-with-structural: structural failure not co-reported: $(cat "$tmp/out")"
grep -q "false-green: positive-control probe failed on channel gh" "$tmp/out" \
  || fail "breach-with-structural: false-green not co-reported: $(cat "$tmp/out")"

# --- case 9: top-level の unknown key (required_channels 等) で required set を縮められない ---
#     (縮小不可の pin。judge は未知 top-level key を無視し、canonical 全チャネルを要求し続ける) ---
cat > "$tmp/shrink-attempt.json" <<'EOF'
{
  "required_channels": ["gh"],
  "probes": [
    {"channel": "gh", "mode": "negative", "operation": "read-priv", "authenticated": false},
    {"channel": "gh", "mode": "positive", "operation": "read-priv", "authenticated": true}
  ]
}
EOF
run_case "required-set-cannot-shrink" "$tmp/shrink-attempt.json" 2 \
  "channel git-https: no complete negative/positive probe pair"

# --- case 10: probes が空でも構造エラー (exit 2)。破れ検出 (1) と混同しない ---
cat > "$tmp/empty.json" <<'EOF'
{ "probes": [] }
EOF
run_case "empty-probes" "$tmp/empty.json" 2 "no complete negative/positive probe pair"

# --- case 11: canonical 外の channel は入力エラー (exit 2) ---
cat > "$tmp/unknown.json" <<'EOF'
{ "probes": [ {"channel": "wat", "mode": "negative", "operation": "read-priv", "authenticated": false} ] }
EOF
run_case "unknown-channel" "$tmp/unknown.json" 2 "channel must be one of"

# --- case 12: operation 欠落は入力エラー (exit 2) ---
cat > "$tmp/noop.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "negative", "authenticated": false} ] }
EOF
run_case "missing-operation" "$tmp/noop.json" 2 "operation must be a non-empty string"

# --- case 13: operation に制御文字 (改行等) は入力エラー (exit 2)。
#     改行入りラベルで「ok: ...」等の出力行を偽造できないことを pin する。 ---
cat > "$tmp/ctrl.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "negative", "operation": "x\nok: forged", "authenticated": true} ] }
EOF
run_case "control-char-operation" "$tmp/ctrl.json" 2 "must not contain control characters"

# --- case 14: 型不正 (authenticated が boolean でない) は入力エラー (exit 2) ---
cat > "$tmp/badtype.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "negative", "operation": "read-priv", "authenticated": "false"} ] }
EOF
run_case "bad-probe-type" "$tmp/badtype.json" 2 "authenticated must be a boolean"

# --- case 15: 不正 JSON は silent pass せず入力エラー (exit 2) ---
printf '{ not json ' > "$tmp/bad.json"
run_case "malformed-json" "$tmp/bad.json" 2 "error:"

# --- case 16: 引数不正 (--judge なし) は usage を出して exit 2 / --help は exit 0 ---
status=0
"$check" > "$tmp/out" 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "usage: expected exit 2, got $status: $(cat "$tmp/out")"
grep -q "usage: check-credential-isolation.sh" "$tmp/out" \
  || fail "usage: missing usage text: $(cat "$tmp/out")"
status=0
"$check" --help > "$tmp/out" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "help: expected exit 0, got $status: $(cat "$tmp/out")"
grep -q "usage: check-credential-isolation.sh" "$tmp/out" \
  || fail "help: missing usage text: $(cat "$tmp/out")"

# --- case 17: 存在しない results file は入力エラー (exit 2) ---
run_case "missing-file" "$tmp/does-not-exist.json" 2 "results file not found"

# --- case 18: 読めない results file も入力エラー (exit 2)。破れ検出 (1) に化けない ---
#     (root はファイル権限を無視して読めてしまうため skip)
if [ "$(id -u)" -ne 0 ]; then
  cp "$tmp/pass.json" "$tmp/unreadable.json"
  chmod 000 "$tmp/unreadable.json"
  run_case "unreadable-file" "$tmp/unreadable.json" 2 "error:"
  chmod 644 "$tmp/unreadable.json"
fi

echo "ok: check-credential-isolation self-test passed"
