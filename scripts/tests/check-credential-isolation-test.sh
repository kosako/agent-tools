#!/bin/sh
# check-credential-isolation.sh の self-test。
# probe 結果 fixture を一時生成して判定ロジックを検証する。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
check="$script_dir/../check-credential-isolation.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT


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

# usage: probe_line <channel> <mode> <operation> <authenticated>
# probe 1 件分の JSON object を 1 行で出す (write_probes に渡す)。
probe_line() {
  printf '{"channel": "%s", "mode": "%s", "operation": "%s", "authenticated": %s}' \
    "$1" "$2" "$3" "$4"
}

# usage: reach_line <channel> <operation> <reachable>
# reachability control 1 件分の JSON object を 1 行で出す (#185)。
reach_line() {
  printf '{"channel": "%s", "mode": "reachability", "operation": "%s", "reachable": %s}' \
    "$1" "$2" "$3"
}

# usage: write_probes <file> [probe-line...]
# probe_line の出力を {"probes": [...]} に包んで file へ書く (fixture は $tmp に残る)。
# 構造そのものが主題の fixture (unknown top-level key / 型不正 / 不正 JSON 等) は
# この helper を使わず inline で書く。
write_probes() {
  wp_file=$1; shift
  {
    printf '{\n  "probes": [\n'
    while [ $# -gt 0 ]; do
      if [ $# -gt 1 ]; then printf '    %s,\n' "$1"; else printf '    %s\n' "$1"; fi
      shift
    done
    printf '  ]\n}\n'
  } > "$wp_file"
}

# --- case 1: 4 canonical channel が同一 operation ペア + reachability で揃い polarity 正なら pass (exit 0) ---
write_probes "$tmp/pass.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "all-clean" "$tmp/pass.json" 0 "isolation verified"

# --- case 2: 被覆は床 (1組以上)。同一 channel に別 operation のペアを足しても pass (exit 0) ---
#     カバレッジを増やした runner を「破れ検出」で罰しないことを pin する。
#     reachability はチャネル単位でちょうど 1 本 (operation を増やしても増やさない)。
write_probes "$tmp/superset.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(probe_line gh        negative clone-priv false)" \
  "$(probe_line gh        positive clone-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "superset-coverage" "$tmp/superset.json" 0 "isolation verified"

# --- case 3: negative が認証を通したら credential leak (exit 1) ---
write_probes "$tmp/leak.json" \
  "$(probe_line gh        negative read-priv true)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "leak" "$tmp/leak.json" 1 "credential leak: negative probe authenticated on channel gh"

# --- case 4: positive-control が失敗したら false-green (exit 1) ---
write_probes "$tmp/falsegreen.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv false)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "false-green" "$tmp/falsegreen.json" 1 "false-green: positive-control probe failed on channel gh"

# --- case 5: negative/positive の operation がずれたら完全ペア不成立 = 構造エラー (exit 2) ---
#     破れの観測ではないので 1 ではなく 2 (入力・構造エラー)。
write_probes "$tmp/mismatch.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-public true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "operation-mismatch" "$tmp/mismatch.json" 2 "channel gh: no complete negative/positive probe pair"

# --- case 6: required channel (git-https) を丸ごと欠くと構造エラー (exit 2・偽の安心を弾く) ---
# opt-in の git-ssh / curl があっても required floor の欠落は塞げない。
write_probes "$tmp/missing.json" \
  "$(probe_line gh      negative read-priv false)" \
  "$(probe_line gh      positive read-priv true)" \
  "$(reach_line gh      reach true)" \
  "$(probe_line git-ssh negative read-priv false)" \
  "$(probe_line git-ssh positive read-priv true)" \
  "$(reach_line git-ssh reach true)" \
  "$(probe_line curl    negative read-priv false)" \
  "$(probe_line curl    positive read-priv true)" \
  "$(reach_line curl    reach true)"
run_case "missing-channel" "$tmp/missing.json" 2 "channel git-https: no complete negative/positive probe pair"

# --- case 7: 同一 (channel, operation, mode) の重複は曖昧 = 構造エラー (exit 2) ---
write_probes "$tmp/dup.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "duplicate-probe" "$tmp/dup.json" 2 \
  "channel gh (operation read-priv): expected exactly one negative probe, got 2"

# --- case 8: 構造不備と破れが同居したら、破れを優先して exit 1 かつ両方報告する ---
#     (構造エラーの陰で leak の証跡が報告から漏れない = 抑制しないことを pin) ---
write_probes "$tmp/dup-and-leak.json" \
  "$(probe_line gh        negative read-priv true)" \
  "$(probe_line gh        negative read-priv true)" \
  "$(probe_line gh        positive read-priv false)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
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
    {"channel": "gh", "mode": "positive", "operation": "read-priv", "authenticated": true},
    {"channel": "gh", "mode": "reachability", "operation": "reach", "reachable": true}
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

# --- case 19: 同一 (channel, operation) の positive 重複も曖昧 = 構造エラー (exit 2) (#150) ---
# (case 7 は negative 重複のみで、positive 側の件数分岐が未到達だった)
write_probes "$tmp/duppos.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(probe_line curl      positive read-priv true)" \
  "$(reach_line curl      reach true)"
run_case "duplicate-positive-probe" "$tmp/duppos.json" 2 \
  "channel gh (operation read-priv): expected exactly one positive-control probe, got 2"

# --- case 20: top-level が JSON object でなければ入力エラー (exit 2) (#150) ---
echo '[]' > "$tmp/toplevel-array.json"
run_case "top-level-not-object" "$tmp/toplevel-array.json" 2 "input must be a JSON object"

# --- case 21: probes が array でなければ入力エラー (exit 2) (#150) ---
echo '{ "probes": {} }' > "$tmp/probes-not-array.json"
run_case "probes-not-array" "$tmp/probes-not-array.json" 2 "probes must be an array"

# --- case 22: curl は opt-in。required 3 チャネルだけで完全なら pass (exit 0) (#129 P3-02) ---
# curl の ambient 認証源 (~/.netrc) は環境依存で不在のことがあり、required floor から外した。
write_probes "$tmp/three.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)"
run_case "curl-optional-three-channel-pass" "$tmp/three.json" 0 "isolation verified (3 channels"

# --- case 23: curl を含めたなら curl も完全ペアが要る (opt-in でも骨抜けにしない) (exit 2) ---
write_probes "$tmp/curl-incomplete.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)" \
  "$(probe_line curl      negative read-priv false)" \
  "$(reach_line curl      reach true)"
run_case "curl-optin-must-be-complete" "$tmp/curl-incomplete.json" 2 \
  "channel curl (operation read-priv): expected exactly one positive-control probe, got 0"

# --- case 24: required チャネル (gh) を丸ごと欠くと構造エラー (exit 2・required floor は不変) ---
write_probes "$tmp/no-gh.json" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(probe_line git-ssh   positive read-priv true)" \
  "$(reach_line git-ssh   reach true)"
run_case "required-gh-missing" "$tmp/no-gh.json" 2 "channel gh: no complete negative/positive probe pair"

# --- case 25: required 2 チャネル (gh + git-https) だけで完全なら pass (exit 0) (#129 P3-02) ---
# git-ssh (ssh-agent) / curl (~/.netrc) は ambient 認証源がセッション依存のため opt-in。
write_probes "$tmp/two.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)"
run_case "required-two-channel-pass" "$tmp/two.json" 0 "isolation verified (2 channels"

# --- case 26: opt-in git-ssh を含めたなら git-ssh も完全ペアが要る (exit 2) ---
write_probes "$tmp/ssh-incomplete.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(probe_line git-ssh   negative read-priv false)" \
  "$(reach_line git-ssh   reach true)"
run_case "ssh-optin-must-be-complete" "$tmp/ssh-incomplete.json" 2 \
  "channel git-ssh (operation read-priv): expected exactly one positive-control probe, got 0"

# --- case 27: reachability control の欠落は構造エラー (exit 2)。到達不能由来の false-green を
#     見分けられないので緑にしない (#185) ---
write_probes "$tmp/no-reach.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)"
run_case "missing-reachability" "$tmp/no-reach.json" 2 \
  "channel git-https: no reachability control probe"

# --- case 28: reachable=false は indeterminate (exit 2)。破れ (1) にも緑 (0) にもしない (#185) ---
write_probes "$tmp/unreachable.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach false)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)"
run_case "unreachable-indeterminate" "$tmp/unreachable.json" 2 \
  "indeterminate: channel gh unreachable from isolated session"

# --- case 29: indeterminate と破れが同居したら破れを優先して exit 1 かつ両方報告する (#185) ---
write_probes "$tmp/unreachable-and-leak.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach false)" \
  "$(probe_line git-https negative read-priv true)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)"
run_case "indeterminate-with-breach" "$tmp/unreachable-and-leak.json" 1 \
  "credential leak: negative probe authenticated on channel git-https"
grep -q "indeterminate: channel gh unreachable from isolated session" "$tmp/out" \
  || fail "indeterminate-with-breach: indeterminate not co-reported: $(cat "$tmp/out")"

# --- case 30: reachability の重複は曖昧 = 構造エラー (exit 2) (#185) ---
write_probes "$tmp/dup-reach.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(reach_line gh        reach2 true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)"
run_case "duplicate-reachability" "$tmp/dup-reach.json" 2 \
  "channel gh: expected exactly one reachability probe, got 2"

# --- case 31: pair の無いチャネルへの reachability だけの混入も構造エラー (exit 2・fail-closed) ---
write_probes "$tmp/orphan-reach.json" \
  "$(probe_line gh        negative read-priv false)" \
  "$(probe_line gh        positive read-priv true)" \
  "$(reach_line gh        reach true)" \
  "$(probe_line git-https negative read-priv false)" \
  "$(probe_line git-https positive read-priv true)" \
  "$(reach_line git-https reach true)" \
  "$(reach_line curl      reach true)"
run_case "orphan-reachability" "$tmp/orphan-reach.json" 2 \
  "channel curl: reachability probe without a negative/positive probe pair"

# --- case 32: reachability probe の field 混同は入力エラー (exit 2)。mode ごとに観測 field は
#     1 つ (reachability=reachable / negative,positive=authenticated) (#185) ---
cat > "$tmp/reach-no-flag.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "reachability", "operation": "reach"} ] }
EOF
run_case "reachability-missing-reachable" "$tmp/reach-no-flag.json" 2 "reachable must be a boolean"
cat > "$tmp/reach-with-auth.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "reachability", "operation": "reach", "reachable": true, "authenticated": true} ] }
EOF
run_case "reachability-with-authenticated" "$tmp/reach-with-auth.json" 2 \
  "reachability probe must not carry authenticated"
cat > "$tmp/negative-with-reach.json" <<'EOF'
{ "probes": [ {"channel": "gh", "mode": "negative", "operation": "read-priv", "authenticated": false, "reachable": true} ] }
EOF
run_case "negative-with-reachable" "$tmp/negative-with-reach.json" 2 \
  "negative probe must not carry reachable"

echo "ok: check-credential-isolation self-test passed"
