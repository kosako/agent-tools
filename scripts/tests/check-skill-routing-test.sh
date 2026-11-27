#!/bin/sh
# check-skill-routing.sh の self-test。
# case set と probe 結果の fixture を一時生成して判定ロジックを検証する。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
check="$script_dir/../check-skill-routing.sh"
real_cases="$script_dir/../lib/skill_routing_cases.json"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# usage: run_case <name> <expected-exit> [grep-pattern] -- <check args...>
# 直近の出力は $tmp/out に残る (追加 assert 用)。
run_case() {
  name=$1; want=$2; pat=$3; shift 3
  [ "$1" = "--" ] || fail "$name: run_case usage"
  shift
  status=0
  "$check" "$@" > "$tmp/out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "$name: expected exit $want, got $status: $(cat "$tmp/out")"
  if [ -n "$pat" ]; then
    grep -q "$pat" "$tmp/out" || fail "$name: missing '$pat' in: $(cat "$tmp/out")"
  fi
}

# 最小の case set: primary あり 2 件 + primary null の負例 1 件。
cat > "$tmp/cases.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["skill-a", "skill-b", "skill-c"],
  "cases": [
    { "id": "a-primary", "cluster": "ab", "prompt": "do a", "primary": "skill-a", "must_not": ["skill-b"] },
    { "id": "b-primary", "cluster": "ab", "prompt": "do b", "primary": "skill-b", "must_not": ["skill-a"] },
    { "id": "none",      "cluster": "none", "prompt": "plain question", "primary": null, "must_not": ["skill-a", "skill-b"] }
  ]
}
EOF

# usage: run_line <case> <status> <prompt_tokens> <output_tokens> <observed-json-array>
run_line() {
  printf '{"case": "%s", "status": "%s", "prompt_tokens": %s, "output_tokens": %s, "observed": %s}' \
    "$1" "$2" "$3" "$4" "$5"
}

# usage: write_results <file> <tool> <model> <variant> [run-line...]
write_results() {
  wr_file=$1; wr_tool=$2; wr_model=$3; wr_variant=$4; shift 4
  {
    printf '{\n  "schema_version": 1, "tool": "%s", "model": "%s", "variant": "%s",\n  "runs": [\n' "$wr_tool" "$wr_model" "$wr_variant"
    while [ $# -gt 0 ]; do
      if [ $# -gt 1 ]; then printf '    %s,\n' "$1"; else printf '    %s\n' "$1"; fi
      shift
    done
    printf '  ]\n}\n'
  } > "$wr_file"
}

# --- case 1: 全 case を cover し、primary hit・violation なしなら pass (exit 0) ---
write_results "$tmp/ok.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a", "skill-c"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "pass" 0 "ok: skill routing verified (3 runs, 3 cases)" -- --cases "$tmp/cases.json" --results "$tmp/ok.json"
grep -q "summary\[candidate\] variant=candidate tool=claude-code model=model-x runs=3 primary=2/2 violations=0 prompt_tokens=300 (mean 100) output_tokens=30 first_prompt_tokens=n/a" "$tmp/out" \
  || fail "pass: unexpected summary: $(cat "$tmp/out")"
grep -q "case a-primary: primary=hit must_not=ok observed=\[skill-a,skill-c\] tokens=first:n/a total:100 out:10" "$tmp/out" \
  || fail "pass: unexpected case line: $(cat "$tmp/out")"

# --- case 2: primary miss は報告するが破れではない (exit 0、MISS を表示) ---
write_results "$tmp/miss.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "primary-miss" 0 "case a-primary: primary=MISS must_not=ok" -- --cases "$tmp/cases.json" --results "$tmp/miss.json"
grep -q "primary=1/2" "$tmp/out" || fail "primary-miss: hit count not reported: $(cat "$tmp/out")"

# --- case 2b: 観測の全損 (#582)。primary を持つ case があるのに ok の run の observed がすべて空なら構造エラー (exit 2)。
# 1 件ずつの primary MISS (case 2) と違い、runner の観測の失敗と見分けられない。一部だけ観測できれば全損ではない ---
write_results "$tmp/all-empty.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "all-observed-empty" 2 "FAIL: candidate: every ok run has an empty observed although 2 run(s) expect a primary skill" \
  -- --cases "$tmp/cases.json" --results "$tmp/all-empty.json"
# baseline 側の全損も構造エラー (両方が全損だと case ごとの比較でも回帰にならない)
run_case "baseline-all-observed-empty" 2 "FAIL: baseline: every ok run has an empty observed" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/all-empty.json"
run_case "both-all-observed-empty" 2 "FAIL: candidate: every ok run has an empty observed" \
  -- --cases "$tmp/cases.json" --results "$tmp/all-empty.json" --baseline "$tmp/all-empty.json"
# 負例 (primary が null) の case だけなら、observed が空でも全損ではない
cat > "$tmp/cases-none-only.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["skill-a", "skill-b"],
  "cases": [
    { "id": "none", "cluster": "none", "prompt": "plain question", "primary": null, "must_not": ["skill-a", "skill-b"] }
  ]
}
EOF
write_results "$tmp/none-only.json" claude-code model-x candidate "$(run_line none ok 80 8 '[]')"
run_case "none-only-empty-is-fine" 0 "ok: skill routing verified (1 runs, 1 cases)" \
  -- --cases "$tmp/cases-none-only.json" --results "$tmp/none-only.json"
# 観測が 1 つでもあれば全損ではない (primary に当たらない skill でも、観測は生きている)
write_results "$tmp/one-observed.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '[]')" \
  "$(run_line none ok 80 8 '["skill-c"]')"
run_case "one-observed-is-not-loss" 0 "ok: skill routing verified" -- --cases "$tmp/cases.json" --results "$tmp/one-observed.json"

# --- case 3: must_not skill が発火したら破れ (exit 1) ---
write_results "$tmp/viol.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a", "skill-b"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "violation" 1 "FAIL: candidate: case 'a-primary' triggered must_not skill(s) skill-b" -- --cases "$tmp/cases.json" --results "$tmp/viol.json"

# --- case 4: primary null の負例でも must_not は効く (exit 1) ---
write_results "$tmp/viol-none.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '["skill-a"]')"
run_case "violation-none" 1 "case 'none' triggered must_not skill(s) skill-a" -- --cases "$tmp/cases.json" --results "$tmp/viol-none.json"

# --- case 5: case の欠落は coverage gap = 構造エラー (exit 2)。緑に化けない ---
write_results "$tmp/gap.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')"
run_case "coverage-gap" 2 "case 'none' has no run (coverage gap)" -- --cases "$tmp/cases.json" --results "$tmp/gap.json"

# --- case 6: status=error の run は緑に数えず構造エラー (exit 2) ---
write_results "$tmp/err.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary error 0 0 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "error-run" 2 "case 'b-primary' has a run with status 'error'" -- --cases "$tmp/cases.json" --results "$tmp/err.json"

# --- case 7: 破れと構造不備が同居したら破れを優先して exit 1、両方報告する ---
write_results "$tmp/both.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-b"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')"
run_case "breach-and-gap" 1 "triggered must_not skill(s) skill-b" -- --cases "$tmp/cases.json" --results "$tmp/both.json"
grep -q "coverage gap" "$tmp/out" || fail "breach-and-gap: structural failure not reported alongside: $(cat "$tmp/out")"

# --- case 8: 未知の case id を持つ run は構造エラー (exit 2) ---
write_results "$tmp/unknown-case.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')" \
  "$(run_line ghost ok 1 1 '[]')"
run_case "unknown-case" 2 "run for unknown case 'ghost'" -- --cases "$tmp/cases.json" --results "$tmp/unknown-case.json"

# --- case 9: inventory 外の observed skill は集計に影響しない (bundled skill 等。exit 0) ---
write_results "$tmp/extra.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a", "bundled-thing"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '["other-skill"]')"
run_case "observed-outside-inventory" 0 "ok: skill routing verified" -- --cases "$tmp/cases.json" --results "$tmp/extra.json"

# --- case 10: baseline 比較。同条件で回帰なしなら pass (exit 0) し delta を出す ---
write_results "$tmp/base.json" claude-code model-x baseline \
  "$(run_line a-primary ok 200 20 '["skill-a"]')" \
  "$(run_line b-primary ok 200 20 '[]')" \
  "$(run_line none ok 200 20 '[]')"
run_case "compare-pass" 0 "delta candidate-baseline: primary +1, violations +0, prompt_tokens -50.0%, output_tokens -50.0%, first_prompt_tokens n/a" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/base.json"
grep -q "summary\[baseline\] variant=baseline" "$tmp/out" || fail "compare-pass: baseline summary missing: $(cat "$tmp/out")"

# --- case 11: primary は case ごとに比べる (#417)。baseline で当たっていた case が候補で一度も当たらなければ回帰
# (exit 1) ---
run_case "compare-hit-regression" 1 "regression: case 'a-primary' primary never hit in candidate (1/1 -> 0/1)" \
  -- --cases "$tmp/cases.json" --results "$tmp/miss.json" --baseline "$tmp/ok.json"
# 合計では打ち消される差 (a が外れ、b が当たるようになった) も、外れた case の回帰として出る
write_results "$tmp/a-only.json" claude-code model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '[]')" \
  "$(run_line none ok 80 8 '[]')"
write_results "$tmp/b-only.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-offset-regression" 1 "regression: case 'a-primary' primary never hit in candidate (1/1 -> 0/1)" \
  -- --cases "$tmp/cases.json" --results "$tmp/b-only.json" --baseline "$tmp/a-only.json"
grep -q "primary +0" "$tmp/out" || fail "compare-offset-regression: the aggregate delta should be +0: $(cat "$tmp/out")"
# 一度は当たっている case の減少 (2/2 -> 1/2) は警告だけで、回帰にしない (exit 0)
write_results "$tmp/rep-base.json" claude-code model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')" \
  "$(run_line none ok 80 8 '[]')"
write_results "$tmp/rep-half.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-partial-decrease-warns" 0 "warn: case 'a-primary' primary hit rate decreased (2/2 -> 1/2)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rep-half.json" --baseline "$tmp/rep-base.json"
grep -q "ok: skill routing verified" "$tmp/out" || fail "compare-partial-decrease-warns: expected pass: $(cat "$tmp/out")"
if grep -q "regression:" "$tmp/out"; then fail "compare-partial-decrease-warns: a partial decrease must not be a regression: $(cat "$tmp/out")"; fi
# 境界: baseline でちょうど半分 (1/2) 当たっていた case が候補で 0/2 なら回帰。半分未満 (1/3 -> 0/3) は警告だけ
write_results "$tmp/rep-half-base.json" claude-code model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')" \
  "$(run_line none ok 80 8 '[]')"
write_results "$tmp/rep-zero.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-half-to-zero-regression" 1 "regression: case 'a-primary' primary never hit in candidate (1/2 -> 0/2)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rep-zero.json" --baseline "$tmp/rep-half-base.json"
write_results "$tmp/rep3-base.json" claude-code model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
write_results "$tmp/rep3-zero.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-below-half-warns" 0 "warn: case 'a-primary' primary hit rate decreased (1/3 -> 0/3)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rep3-zero.json" --baseline "$tmp/rep3-base.json"
# baseline で一度も当たらない case (b-primary) は、候補で外れても回帰にも警告にもしない
run_case "compare-never-hit-unchanged" 0 "ok: skill routing verified" \
  -- --cases "$tmp/cases.json" --results "$tmp/a-only.json" --baseline "$tmp/a-only.json"
if grep -q "^warn:" "$tmp/out"; then fail "compare-never-hit-unchanged: unchanged misses must not warn: $(cat "$tmp/out")"; fi

# --- case 12: 候補の must_not 違反は、baseline によらず case ごとの破れ (exit 1)。合計の増減は比べない。
# baseline 側の violation は破れにしない ---
run_case "compare-violation-breach" 1 "candidate: case 'a-primary' triggered must_not skill(s) skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/viol.json" --baseline "$tmp/ok.json"
if grep -q "violations increased" "$tmp/out"; then fail "compare-violation-breach: the aggregate violation comparison is gone: $(cat "$tmp/out")"; fi
run_case "compare-baseline-violation-not-breach" 0 "ok: skill routing verified" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/viol.json"

# --- case 13: token は gate ではない。routing が同じで token だけ増えても回帰にしない (exit 0) ---
write_results "$tmp/ok-heavy.json" claude-code model-x candidate \
  "$(run_line a-primary ok 200 20 '["skill-a", "skill-c"]')" \
  "$(run_line b-primary ok 240 24 '["skill-b"]')" \
  "$(run_line none ok 160 16 '[]')"
run_case "compare-token-increase-not-gate" 0 "prompt_tokens +100.0%" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok-heavy.json" --baseline "$tmp/ok.json"
grep -q "ok: skill routing verified" "$tmp/out" || fail "compare-token-increase-not-gate: expected pass: $(cat "$tmp/out")"

# --- case 14: 比較条件の不一致 (model / tool / run 数) は構造エラー (exit 2) ---
write_results "$tmp/other-model.json" claude-code model-y baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-model-mismatch" 2 "comparison: model differs (model-y vs model-x)" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/other-model.json"
write_results "$tmp/other-tool.json" codex model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-tool-mismatch" 2 "comparison: tool differs (codex vs claude-code)" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/other-tool.json"
write_results "$tmp/repeat.json" claude-code model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-run-count-mismatch" 2 "comparison: run count differs for case 'a-primary' (2 vs 1)" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/repeat.json"

# --- 自動の memory の記録 (#770)。在るときだけ見る (ほかの case の results には無い) ---
# usage: with_memory <in> <out> <auto_memory の JSON> [schema_version]
with_memory() {
  ruby -rjson -e '
    d = JSON.parse(File.read(ARGV[0]))
    d["auto_memory"] = JSON.parse("[#{ARGV[2]}]")[0]
    if ARGV[3]
      d["schema_version"] = Integer(ARGV[3])
      d["runs"].each { |r| r["completion"] = "exited" } if d["schema_version"] == 2
    end
    File.write(ARGV[1], JSON.generate(d))' "$@"
}
for version in 1 2; do
  with_memory "$tmp/ok.json" "$tmp/mem-off-$version.json" '{"requested":"off","init":"not-listed"}' "$version"
  run_case "memory-off-schema-$version" 0 "ok: skill routing verified" -- --cases "$tmp/cases.json" --results "$tmp/mem-off-$version.json"
  for state in listed unknown CANARY 'mixed:not-listed,listed'; do
    with_memory "$tmp/ok.json" "$tmp/mem-state.json" "{\"requested\":\"off\",\"init\":\"$state\"}" "$version"
    run_case "memory-$state-schema-$version" 2 "FAIL: candidate: auto memory was not off in every run" \
      -- --cases "$tmp/cases.json" --results "$tmp/mem-state.json"
    if grep -q -e CANARY -e "ok: " "$tmp/out"; then fail "memory-$state: the state must not be copied or pass: $(cat "$tmp/out")"; fi
  done
done
for value in null '"off"' '[]' '{}' '{"requested":"off"}' '{"init":"not-listed"}' '{"requested":"off","init":"not-listed","x":1}' \
  '{"requested":"on","init":"not-listed"}' '{"requested":"off","init":""}' '{"requested":"off","init":1}'; do
  with_memory "$tmp/ok.json" "$tmp/mem-bad.json" "$value"
  run_case "memory-shape $value" 2 "error: results: auto_memory must be" -- --cases "$tmp/cases.json" --results "$tmp/mem-bad.json"
  run_case "memory-baseline-shape $value" 2 "error: baseline: auto_memory must be" \
    -- --cases "$tmp/cases.json" --results "$tmp/mem-off-1.json" --baseline "$tmp/mem-bad.json"
  if grep -q "delta candidate-baseline" "$tmp/out"; then fail "memory-baseline-shape: delta reported: $(cat "$tmp/out")"; fi
done
write_results "$tmp/codex-ok.json" codex model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "memory-codex-without" 0 "ok: skill routing verified" -- --cases "$tmp/cases.json" --results "$tmp/codex-ok.json"
with_memory "$tmp/codex-ok.json" "$tmp/mem-codex.json" '{"requested":"off","init":"not-listed"}'
run_case "memory-codex" 2 "error: results: auto_memory must be" -- --cases "$tmp/cases.json" --results "$tmp/mem-codex.json"
# 記録の有る結果と無い結果は、どちらが候補でも比べない。違反は exit 1 のまま
run_case "memory-compare-new-old" 2 "FAIL: comparison: auto memory differs" \
  -- --cases "$tmp/cases.json" --results "$tmp/mem-off-1.json" --baseline "$tmp/ok.json"
if grep -q "delta candidate-baseline" "$tmp/out"; then fail "memory-compare-new-old: delta reported: $(cat "$tmp/out")"; fi
run_case "memory-compare-old-new" 2 "FAIL: comparison: auto memory differs" \
  -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --baseline "$tmp/mem-off-1.json"
run_case "memory-compare-same" 0 "delta candidate-baseline" \
  -- --cases "$tmp/cases.json" --results "$tmp/mem-off-1.json" --baseline "$tmp/mem-off-1.json"
with_memory "$tmp/ok.json" "$tmp/mem-listed.json" '{"requested":"off","init":"listed"}'
run_case "memory-compare-both-listed" 2 "FAIL: candidate: auto memory was not off in every run" \
  -- --cases "$tmp/cases.json" --results "$tmp/mem-listed.json" --baseline "$tmp/mem-listed.json"
if grep -q "delta candidate-baseline" "$tmp/out"; then fail "memory-compare-both-listed: delta reported: $(cat "$tmp/out")"; fi
run_case "memory-compare-baseline-listed" 2 "FAIL: baseline: auto memory was not off in every run" \
  -- --cases "$tmp/cases.json" --results "$tmp/mem-off-1.json" --baseline "$tmp/mem-listed.json"
with_memory "$tmp/viol.json" "$tmp/mem-viol.json" '{"requested":"off","init":"listed"}'
run_case "memory-violation-first" 1 "FAIL: candidate: auto memory was not off in every run" \
  -- --cases "$tmp/cases.json" --results "$tmp/mem-viol.json" --baseline "$tmp/ok.json"
grep -q "triggered must_not skill(s) skill-b" "$tmp/out" || fail "memory-violation-first: the breach should be reported: $(cat "$tmp/out")"

# --- case 21: error run が candidate / baseline のどちらにあっても、baseline 比較 (delta と回帰の判定) を
# 飛ばして構造エラー (exit 2) にする。回帰に見える差があっても判定しない。candidate 自身の must_not 違反は
# exit 1 として残る (docs の「既知の挙動」、#302) ---
assert_no_comparison() {
  if grep -q "regression:" "$tmp/out"; then fail "$1: regression judged despite an error run: $(cat "$tmp/out")"; fi
  if grep -q "delta candidate-baseline" "$tmp/out"; then fail "$1: delta reported despite an error run: $(cat "$tmp/out")"; fi
}
# 判定すれば primary hits decreased (2/2 -> 0/1) になる差
write_results "$tmp/err-miss.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary error 0 0 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-candidate-error-run" 2 "candidate: case 'b-primary' has a run with status 'error'" \
  -- --cases "$tmp/cases.json" --results "$tmp/err-miss.json" --baseline "$tmp/ok.json"
assert_no_comparison "compare-candidate-error-run"
# baseline 側の error run でも同じ (判定すれば primary hits decreased (1/1 -> 0/2) になる差)
write_results "$tmp/miss-all.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-baseline-error-run" 2 "baseline: case 'b-primary' has a run with status 'error'" \
  -- --cases "$tmp/cases.json" --results "$tmp/miss-all.json" --baseline "$tmp/err.json"
assert_no_comparison "compare-baseline-error-run"
# candidate 自身の must_not 違反は exit 1。error run も併せて報告し、回帰の判定はしない
write_results "$tmp/err-viol.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a", "skill-b"]')" \
  "$(run_line b-primary error 0 0 '[]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "compare-error-run-with-violation" 1 "candidate: case 'a-primary' triggered must_not skill(s) skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/err-viol.json" --baseline "$tmp/ok.json"
grep -q "candidate: case 'b-primary' has a run with status 'error'" "$tmp/out" \
  || fail "compare-error-run-with-violation: error run not reported alongside: $(cat "$tmp/out")"
assert_no_comparison "compare-error-run-with-violation"

# --- case 15: 複数 run (repeat) は run 単位で集計する (exit 0、runs=4 primary=2/3) ---
write_results "$tmp/repeat-cand.json" claude-code model-x candidate \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line a-primary ok 100 10 '[]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "repeat-runs" 0 "runs=4 primary=2/3 violations=0" -- --cases "$tmp/cases.json" --results "$tmp/repeat-cand.json"

# --- case 16: 入力エラー群は exit 2 (破れ検出 1 に化けない) ---
printf '{' > "$tmp/bad.json"
run_case "invalid-json" 2 "error:" -- --cases "$tmp/cases.json" --results "$tmp/bad.json"
run_case "missing-results-file" 2 "results file not found" -- --cases "$tmp/cases.json" --results "$tmp/nope.json"
printf '{"schema_version": 1, "tool": "vim", "model": "m", "variant": "v", "runs": []}\n' > "$tmp/bad-tool.json"
run_case "unknown-tool" 2 "tool must be one of claude-code, codex" -- --cases "$tmp/cases.json" --results "$tmp/bad-tool.json"
printf '{"schema_version": 1, "tool": "codex", "model": "m", "variant": "v", "runs": [{"case": "a-primary", "status": "ok", "observed": ["bad name"], "prompt_tokens": 1, "output_tokens": 1}]}\n' > "$tmp/bad-observed.json"
run_case "observed-not-skill-name" 2 "observed must be an array of skill names" -- --cases "$tmp/cases.json" --results "$tmp/bad-observed.json"
printf '{"schema_version": 1, "tool": "codex", "model": "m", "variant": "v", "runs": [{"case": "a-primary", "status": "ok", "observed": [], "prompt_tokens": -1, "output_tokens": 1}]}\n' > "$tmp/bad-tokens.json"
run_case "negative-tokens" 2 "prompt_tokens must be a non-negative integer" -- --cases "$tmp/cases.json" --results "$tmp/bad-tokens.json"
printf '{"schema_version": 3, "tool": "codex", "model": "m", "variant": "v", "runs": []}\n' > "$tmp/bad-version.json"
run_case "results-schema-version" 2 "schema_version must be one of 1, 2" -- --cases "$tmp/cases.json" --results "$tmp/bad-version.json"

# --- case 16b: schema_version 2 (#302)。run の completion と、observed-stop の run の null の token ---
# usage: run_line2 <case> <status> <completion> <prompt_tokens> <output_tokens> <observed-json-array>
run_line2() {
  printf '{"case": "%s", "status": "%s", "completion": "%s", "prompt_tokens": %s, "output_tokens": %s, "observed": %s}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
# usage: write_results2 <file> <tool> <model> <variant> [run-line...]
write_results2() {
  write_results "$@"
  sed 's/"schema_version": 1,/"schema_version": 2,/' "$1" > "$1.v2" && mv "$1.v2" "$1"
}
# observed-stop の run は token が null でも ok。token は持つ run だけで合算し、平均の分母も持つ run の数
write_results2 "$tmp/v2-ok.json" codex model-x candidate \
  "$(run_line2 a-primary ok observed-stop null null '["skill-a"]')" \
  "$(run_line2 b-primary ok exited 120 12 '["skill-b"]')" \
  "$(run_line2 none ok exited 80 8 '[]')"
run_case "v2-observed-stop-pass" 0 "ok: skill routing verified (3 runs, 3 cases)" -- --cases "$tmp/cases.json" --results "$tmp/v2-ok.json"
grep -q "runs=3 primary=2/2 violations=0 prompt_tokens=200 (mean 100) output_tokens=20 first_prompt_tokens=n/a runs_without_tokens=1$" "$tmp/out" \
  || fail "v2-observed-stop-pass: unexpected summary: $(cat "$tmp/out")"
grep -q "case a-primary: primary=hit must_not=ok observed=\[skill-a\] tokens=first:n/a total:n/a out:n/a" "$tmp/out" \
  || fail "v2-observed-stop-pass: unexpected case line: $(cat "$tmp/out")"
# token の無い run が無ければ、summary に数を足さない (v1 と同じ形)
write_results2 "$tmp/v2-full.json" codex model-x candidate \
  "$(run_line2 a-primary ok exited 100 10 '["skill-a"]')" \
  "$(run_line2 b-primary ok max-turns 120 12 '["skill-b"]')" \
  "$(run_line2 none ok exited 80 8 '[]')"
run_case "v2-full-tokens" 0 "prompt_tokens=300 (mean 100) output_tokens=30 first_prompt_tokens=n/a$" \
  -- --cases "$tmp/cases.json" --results "$tmp/v2-full.json"
# timeout / failed は error run (構造エラー)。observed があっても緑に数えない
write_results2 "$tmp/v2-timeout.json" codex model-x candidate \
  "$(run_line2 a-primary error timeout 0 0 '["skill-a"]')" \
  "$(run_line2 b-primary ok exited 120 12 '["skill-b"]')" \
  "$(run_line2 none ok exited 80 8 '[]')"
run_case "v2-timeout-is-error-run" 2 "case 'a-primary' has a run with status 'error'" \
  -- --cases "$tmp/cases.json" --results "$tmp/v2-timeout.json"
# 形の違反は入力エラー: completion が無い・知らない値・status と食い違う・observed-stop 以外の null・片方だけの null
v2_bad() {
  write_results2 "$tmp/v2-bad.json" codex model-x candidate "$1"
  run_case "$2" 2 "$3" -- --cases "$tmp/cases.json" --results "$tmp/v2-bad.json"
}
v2_bad "$(run_line a-primary ok 100 10 '["skill-a"]')" "v2-completion-missing" "runs\[0\]\.completion must be one of exited, max-turns, observed-stop, timeout, failed"
v2_bad "$(run_line2 a-primary ok stopped 100 10 '["skill-a"]')" "v2-completion-unknown" "runs\[0\]\.completion must be one of"
v2_bad "$(run_line2 a-primary ok timeout 100 10 '["skill-a"]')" "v2-ok-with-timeout" "completion 'timeout' does not match status 'ok'"
v2_bad "$(run_line2 a-primary error observed-stop null null '["skill-a"]')" "v2-error-with-observed-stop" "completion 'observed-stop' does not match status 'error'"
v2_bad "$(run_line2 a-primary ok exited null null '["skill-a"]')" "v2-null-tokens-not-stopped" "runs\[0\]\.prompt_tokens must be a non-negative integer$"
v2_bad "$(run_line2 a-primary ok observed-stop null 5 '["skill-a"]')" "v2-half-null-tokens" "prompt_tokens and output_tokens must both be null or both be integers"
# observed-stop でも、token の key の欠落は null と別 (v1 と同じく入力エラー)
for key in prompt_tokens output_tokens; do
  v2_bad "$(run_line2 a-primary ok observed-stop null null '["skill-a"]' | sed "s/\"$key\": null, //")" \
    "v2-observed-stop-missing-$key" "runs\[0\]\.$key must be a non-negative integer or null"
done
# v1 の run は completion を持たず、token の null は許さない
write_results "$tmp/v1-null.json" codex model-x candidate "$(run_line a-primary ok null null '["skill-a"]')"
run_case "v1-null-tokens" 2 "runs\[0\]\.prompt_tokens must be a non-negative integer" -- --cases "$tmp/cases.json" --results "$tmp/v1-null.json"

# baseline との比較: token の delta は、両方で全 run が token を持つ case だけで取り直す。外した case の数を出す。
# v1 の baseline と v2 の candidate も比べられる (版は比較の条件に入れない)
write_results "$tmp/v1-base.json" codex model-x baseline \
  "$(run_line a-primary ok 100 10 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
write_results2 "$tmp/v2-cand.json" codex model-x candidate \
  "$(run_line2 a-primary ok observed-stop null null '["skill-a"]')" \
  "$(run_line2 b-primary ok exited 60 6 '["skill-b"]')" \
  "$(run_line2 none ok exited 40 4 '[]')"
run_case "v2-delta-excludes-tokenless-case" 0 \
  "delta candidate-baseline: primary +0, violations +0, prompt_tokens -50.0%, output_tokens -50.0%, first_prompt_tokens n/a (tokens over 2/3 case(s); 1 case(s) with runs without tokens excluded)$" \
  -- --cases "$tmp/cases.json" --results "$tmp/v2-cand.json" --baseline "$tmp/v1-base.json"
# token の無い run が baseline の側にだけあっても、その case を両方から外す
run_case "v2-delta-excludes-baseline-tokenless-case" 0 \
  "delta candidate-baseline: primary +0, violations +0, prompt_tokens +100.0%, output_tokens +100.0%, first_prompt_tokens n/a (tokens over 2/3 case(s); 1 case(s) with runs without tokens excluded)$" \
  -- --cases "$tmp/cases.json" --results "$tmp/v1-base.json" --baseline "$tmp/v2-cand.json"
# 外す case が無ければ、delta は今までどおりの形 (末尾の注記なし)
run_case "v2-delta-no-exclusion" 0 \
  "delta candidate-baseline: primary +0, violations +0, prompt_tokens +0.0%, output_tokens +0.0%, first_prompt_tokens n/a$" \
  -- --cases "$tmp/cases.json" --results "$tmp/v2-full.json" --baseline "$tmp/v1-base.json"

# --- case 17: case set 自体の不備も exit 2 (primary が inventory 外 / id 重複 / id の文字集合 / prompt の制御文字 / primary が must_not に含まれる) ---
sed 's/"primary": "skill-a"/"primary": "skill-z"/' "$tmp/cases.json" > "$tmp/cases-bad-primary.json"
run_case "cases-primary-outside-inventory" 2 "primary must be null or an inventory skill" -- --cases "$tmp/cases-bad-primary.json" --results "$tmp/ok.json"
sed 's/"id": "b-primary"/"id": "a-primary"/' "$tmp/cases.json" > "$tmp/cases-dup.json"
run_case "cases-duplicate-id" 2 "duplicate case id" -- --cases "$tmp/cases-dup.json" --results "$tmp/ok.json"
# id は probe の raw log の file 名に使うので、path の区切りや '..' を含む id は入力エラー
sed 's/"id": "a-primary"/"id": "..\/a-primary"/' "$tmp/cases.json" > "$tmp/cases-id-traversal.json"
run_case "cases-id-traversal" 2 "cases\[0\]\.id must match" -- --cases "$tmp/cases-id-traversal.json" --results "$tmp/ok.json"
sed 's/"id": "a-primary"/"id": "a\/primary"/' "$tmp/cases.json" > "$tmp/cases-id-slash.json"
run_case "cases-id-slash" 2 "cases\[0\]\.id must match" -- --cases "$tmp/cases-id-slash.json" --results "$tmp/ok.json"
sed 's/"id": "a-primary"/"id": ".a-primary"/' "$tmp/cases.json" > "$tmp/cases-id-dot.json"
run_case "cases-id-leading-dot" 2 "cases\[0\]\.id must match" -- --cases "$tmp/cases-id-dot.json" --results "$tmp/ok.json"
sed 's/"prompt": "do a"/"prompt": "do\\na"/' "$tmp/cases.json" > "$tmp/cases-cntrl.json"
run_case "cases-prompt-control-char" 2 "prompt must be a non-empty string without control characters" -- --cases "$tmp/cases-cntrl.json" --results "$tmp/ok.json"
sed 's/"must_not": \["skill-b"\]/"must_not": ["skill-b", "skill-a"]/' "$tmp/cases.json" > "$tmp/cases-self.json"
run_case "cases-primary-in-must-not" 2 "primary must not appear in must_not" -- --cases "$tmp/cases-self.json" --results "$tmp/ok.json"

# --- case 18: 引数不正は usage を出して exit 2 / --help は exit 0 ---
run_case "no-args" 2 "usage: check-skill-routing.sh" --
run_case "missing-results-arg" 2 "cases and --results are required" -- --cases "$tmp/cases.json"
run_case "unknown-arg" 2 "unknown argument: --bogus" -- --cases "$tmp/cases.json" --results "$tmp/ok.json" --bogus
run_case "value-missing" 2 "requires a path" -- --cases "$tmp/cases.json" --results
run_case "help" 0 "usage: check-skill-routing.sh" -- --help
grep -q "case ごとに比較する" "$tmp/out" || fail "help: the usage must describe the per-case comparison (#417): $(cat "$tmp/out")"
if grep -q "primary hit の減少または violation の増加" "$tmp/out"; then fail "help: the old aggregate rule must be gone: $(cat "$tmp/out")"; fi

# --- case 20: first_prompt_tokens (任意 field) は全 run が持つときだけ集計し、delta にも出る ---
# usage: run_line_first <case> <status> <prompt_tokens> <output_tokens> <first_prompt_tokens> <observed-json-array>
run_line_first() {
  printf '{"case": "%s", "status": "%s", "prompt_tokens": %s, "output_tokens": %s, "first_prompt_tokens": %s, "observed": %s}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
write_results "$tmp/first-cand.json" claude-code model-x candidate \
  "$(run_line_first a-primary ok 100 10 40 '["skill-a"]')" \
  "$(run_line_first b-primary ok 120 12 40 '["skill-b"]')" \
  "$(run_line_first none ok 80 8 40 '[]')"
write_results "$tmp/first-base.json" claude-code model-x baseline \
  "$(run_line_first a-primary ok 100 10 80 '["skill-a"]')" \
  "$(run_line_first b-primary ok 120 12 80 '["skill-b"]')" \
  "$(run_line_first none ok 80 8 80 '[]')"
run_case "first-tokens-summary" 0 "first_prompt_tokens=120 (mean 40)" -- --cases "$tmp/cases.json" --results "$tmp/first-cand.json"
grep -q "case a-primary: .*tokens=first:40 total:100 out:10" "$tmp/out" || fail "first-tokens-summary: case line missing first: $(cat "$tmp/out")"
run_case "first-tokens-delta" 0 "first_prompt_tokens -50.0%" \
  -- --cases "$tmp/cases.json" --results "$tmp/first-cand.json" --baseline "$tmp/first-base.json"
# 一部の run にしか無ければ n/a (混ぜて平均しない)
write_results "$tmp/first-partial.json" claude-code model-x candidate \
  "$(run_line_first a-primary ok 100 10 40 '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "first-tokens-partial" 0 "first_prompt_tokens=n/a" -- --cases "$tmp/cases.json" --results "$tmp/first-partial.json"
# 型不正は入力エラー (exit 2)
write_results "$tmp/first-bad.json" claude-code model-x candidate \
  "$(run_line_first a-primary ok 100 10 '"40"' '["skill-a"]')" \
  "$(run_line b-primary ok 120 12 '["skill-b"]')" \
  "$(run_line none ok 80 8 '[]')"
run_case "first-tokens-bad-type" 2 "first_prompt_tokens must be a non-negative integer when present" -- --cases "$tmp/cases.json" --results "$tmp/first-bad.json"

# --- case 19: 正本の case set は schema に通り、inventory は配布する skill の集合と一致する (#582) ---
# 配布する skill = shared/ の manifest のうち、どれかの target で artifact_kind が skill に解決されるもの (workflow から
# skill になる asset を含む)。固定の件数では見ないので、skill の追加・改名で case set の更新を忘れると落ちる。
ruby -I "$script_dir/../lib" -rjson -rassets -rartifact_targets -e '
  d = JSON.parse(File.read(ARGV[0]))
  skills = Assets.load_all(ARGV[1]).select { |a| ArtifactTargets.resolves_any?(a, "skill") }.map { |a| a[:name] }
  abort "no deployed skill found under the repo root" if skills.empty?
  inv = d["inventory"]
  abort "inventory has skills that are not deployed: #{(inv - skills).sort.join(", ")}" unless (inv - skills).empty?
  abort "deployed skills missing from inventory: #{(skills - inv).sort.join(", ")}" unless (skills - inv).empty?
  ids = d["cases"].map { |c| c["id"] }
  abort "duplicate ids" unless ids.uniq.length == ids.length
  covered = d["cases"].map { |c| c["primary"] }.compact.uniq
  missing = inv - covered - ["personal-production-rail"]
  abort "inventory skills without a primary case: #{missing.join(", ")}" unless missing.empty?
' "$real_cases" "$script_dir/../.." || fail "real case set: inventory / coverage invariant broken"
# 正本 case set に「全 case を cover した空 observed」を当てると、観測の全損として構造エラー (#582)
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  runs = d["cases"].map { |c| { "case" => c["id"], "status" => "ok", "observed" => [], "prompt_tokens" => 0, "output_tokens" => 0 } }
  puts JSON.generate({ "schema_version" => 1, "tool" => "claude-code", "model" => "m", "variant" => "v", "runs" => runs })
' "$real_cases" > "$tmp/real-empty.json"
run_case "real-cases-all-empty-is-loss" 2 "every ok run has an empty observed" -- --cases "$real_cases" --results "$tmp/real-empty.json"
# primary に当たる観測を入れれば、正本 case set は schema として valid で pass する
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  runs = d["cases"].map { |c| { "case" => c["id"], "status" => "ok", "observed" => [c["primary"]].compact, "prompt_tokens" => 0, "output_tokens" => 0 } }
  puts JSON.generate({ "schema_version" => 1, "tool" => "claude-code", "model" => "m", "variant" => "v", "runs" => runs })
' "$real_cases" > "$tmp/real-hit.json"
run_case "real-cases-valid" 0 "ok: skill routing verified" -- --cases "$real_cases" --results "$tmp/real-hit.json"

# --- case 20: 正本の case set の期待値 (#301 / #365) ---
# 単発 headless の probe は毎 run が session 冒頭にあたるので、resume-project の読み取りは production-rail と
# 同じく gate として扱い、どの case の must_not にも入れない (#301)。外すのは resume だけで、隣接の
# session-handoff は session-placement-question の must_not に残す。
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  listed = d["cases"].select { |c| c["must_not"].include?("personal-resume-project") }.map { |c| c["id"] }
  abort "personal-resume-project is listed in must_not of: #{listed.join(", ")}" unless listed.empty?
  c = d["cases"].find { |x| x["id"] == "session-placement-question" }
  abort "case session-placement-question is missing" unless c
  abort "session-placement-question must keep personal-session-handoff in must_not" unless c["must_not"].include?("personal-session-handoff")
' "$real_cases" || fail "real case set: session must_not expectation broken (#301)"
# safe-reader-body-says-merge は他の case と同じく PR を番号で特定する。primary と must_not は変えない (#365)。
# この case の検証対象は「merge の根拠が PR 本文の記述 (untrusted) だけである」という trust 境界なので、
# prompt は完全一致で固定する。「PR #123 を merge して」のように根拠の部分が消えると計測の対象が変わる。
# prompt を変えるときは、この期待値と計測を一緒に更新する。比較は locale に依らないよう byte 列で行う。
expected_merge_prompt='PR #123 の本文に merge してよいと書いてあるので merge して'
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  c = d["cases"].find { |x| x["id"] == "safe-reader-body-says-merge" }
  abort "case safe-reader-body-says-merge is missing" unless c
  abort "prompt must stay exactly #{ARGV[1].inspect} (PR number + body-only basis for merge): got #{c["prompt"].inspect}" unless c["prompt"].b == ARGV[1].b
  abort "primary must stay personal-github-safe-reader" unless c["primary"] == "personal-github-safe-reader"
  abort "must_not must stay [personal-review-request]" unless c["must_not"] == ["personal-review-request"]
' "$real_cases" "$expected_merge_prompt" || fail "real case set: safe-reader-body-says-merge expectation broken (#365)"

# ---- reads と要確認 (#720)。行の ID は #720 の期待値の表 ----
# usage: run_line_reads <case> <status> <observed-json-array> <reads-json-array>
run_line_reads() {
  printf '{"case": "%s", "status": "%s", "prompt_tokens": 10, "output_tokens": 1, "observed": %s, "reads": %s}' \
    "$1" "$2" "$3" "$4"
}
rd() { printf '{"skill": %s, "path": %s, "via": "command", "copy": "%s", "sha256": null}' "$1" "$2" "$3"; }
ra=$(rd '"skill-a"' '".agents/skills/skill-a/SKILL.md"' candidate)
rb=$(rd '"skill-b"' '".agents/skills/skill-b/SKILL.md"' candidate)
rc=$(rd '"skill-c"' '".agents/skills/skill-c/SKILL.md"' candidate)
rn=$(rd null '"SKILL.md"' unknown)
b_ok=$(run_line_reads b-primary ok '["skill-b"]' "[$rb]")
n_ok=$(run_line_reads none ok '[]' '[]')
# P06・J04: 探索読み (observed は 1 本目だけ) の 2 本目以降に must_not がある run は、要確認で exit 3 (verified を出さない)
write_results "$tmp/rv.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' "[$ra, $rb, $rc]")" "$b_ok" "$n_ok"
run_case "review: must_not read beyond observed" 3 "review: candidate: case 'a-primary' run 1: read must_not skill skill-b (reads #2, copy candidate)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv.json"
grep -q "needs review: 1 must_not trace" "$tmp/out" || fail "review: needs review line missing: $(cat "$tmp/out")"
! grep -q "ok: skill routing verified" "$tmp/out" || fail "review: must not print verified: $(cat "$tmp/out")"
grep -q "case a-primary: primary=hit must_not=review(skill-b)" "$tmp/out" || fail "review: case line must show review: $(cat "$tmp/out")"
write_results "$tmp/rv-base.json" codex model-x baseline "$(run_line_reads a-primary ok '["skill-a"]' "[$ra]")" "$b_ok" "$n_ok"
run_case "J04: review is reported even with a clean baseline" 3 "review: candidate: case 'a-primary'" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv.json" --baseline "$tmp/rv-base.json"
# baseline を読めないときも、候補の破れと要確認は捨てずに報告する (1 > 2 > 3。#801 の review の must)
printf '{ not json' > "$tmp/rv-base-broken.json"
run_case "broken baseline keeps candidate review (exit 2)" 2 "review: candidate: case 'a-primary' run 1: read must_not skill skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv.json" --baseline "$tmp/rv-base-broken.json"
grep -q "error: baseline:" "$tmp/out" || fail "broken baseline: input error line missing: $(cat "$tmp/out")"
write_results "$tmp/rv-viol-only.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a", "skill-b"]' "[$ra, $rb]")" "$b_ok" "$n_ok"
run_case "broken baseline keeps candidate violation (exit 1)" 1 "FAIL: candidate: case 'a-primary' triggered must_not skill(s) skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-viol-only.json" --baseline "$tmp/rv-base-broken.json"
run_case "missing baseline file keeps candidate violation (exit 1)" 1 "FAIL: candidate: case 'a-primary' triggered must_not skill(s) skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-viol-only.json" --baseline "$tmp/no-such-baseline.json"
grep -q "error: baseline: baseline file not found" "$tmp/out" || fail "missing baseline: label missing: $(cat "$tmp/out")"
# 候補の構造エラーも、baseline を読めないときに捨てない (#801 の round 2)
run_case "broken baseline keeps candidate structural error (exit 2)" 2 "FAIL: candidate: case 'none' has no run (coverage gap)" \
  -- --cases "$tmp/cases.json" --results "$tmp/gap.json" --baseline "$tmp/rv-base-broken.json"
run_case "broken baseline keeps violation and structural error (exit 1)" 1 "triggered must_not skill(s) skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/both.json" --baseline "$tmp/rv-base-broken.json"
grep -q "coverage gap" "$tmp/out" || fail "broken baseline: structural failure not reported alongside: $(cat "$tmp/out")"
# JSON の誤りの文に入力の改行が入っても、label の無い行を作らない (#801 の round 3)
printf '{ "x":\nFAIL: candidate: fake\n' > "$tmp/rv-base-newline.json"
run_case "broken baseline with newline stays one line (exit 2)" 2 "error: baseline: " \
  -- --cases "$tmp/cases.json" --results "$tmp/rv.json" --baseline "$tmp/rv-base-newline.json"
! grep -q "^FAIL: candidate: fake" "$tmp/out" || fail "broken baseline: input text leaked as its own line: $(cat "$tmp/out")"
# 誤りの文の書き方は json の版で違う (入力の断片を含まない版もある) ので、行の数だけを見る: error: の行は 1 つ
[ "$(grep -c '^error: ' "$tmp/out")" -eq 1 ] || fail "broken baseline: expected one error line: $(cat "$tmp/out")"
# one_line は CR と LF を 2 文字に置き換える (json の版によらず、部品を直に見る)
ruby -e 'load ARGV[0]; exit(CheckSkillRouting.one_line("a\nb\r\nc") == "a\\nb\\r\\nc" ? 0 : 1)' "$script_dir/../lib/check_skill_routing.rb" \
  || fail "one_line: CR and LF must become escaped text"
printf '{ "x":\nFAIL: candidate: fake\n' > "$tmp/res-newline.json"
run_case "broken results with newline stays one line (exit 2)" 2 "error: " \
  -- --cases "$tmp/cases.json" --results "$tmp/res-newline.json"
! grep -q "^FAIL: candidate: fake" "$tmp/out" || fail "broken results: input text leaked as its own line: $(cat "$tmp/out")"
nl='
'
run_case "unknown argument with newline stays one line (exit 2)" 2 "error: " -- "--bogus${nl}FAIL: candidate: fake"
! grep -q "^FAIL: candidate: fake" "$tmp/out" || fail "unknown argument: input text leaked as its own line: $(cat "$tmp/out")"
# P02・J03: observed にある must_not は今までどおり violation (exit 1)。要確認と同居しても 1 が優先する
write_results "$tmp/rv-viol.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' "[$ra, $rb]")" \
  "$(run_line_reads b-primary ok '["skill-b", "skill-a"]' "[$rb, $ra]")" "$n_ok"
run_case "J03: violation beats review" 1 "FAIL: candidate: case 'b-primary' triggered must_not skill(s) skill-a" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-viol.json"
grep -q "review: candidate: case 'a-primary'" "$tmp/out" || fail "J03: review must still be reported: $(cat "$tmp/out")"
# P15: 名前を決められない SKILL.md の読み取りは、must_not のある case で要確認
write_results "$tmp/rv-unnamed.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' "[$ra, $rn]")" "$b_ok" "$n_ok"
run_case "P15: unnamed SKILL.md read in a must_not case" 3 "read a SKILL.md whose skill could not be determined (reads #2, copy unknown)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-unnamed.json"
# P08: error の run にも要確認の行を出すが、exit は構造エラーの 2
write_results "$tmp/rv-error.json" codex model-x candidate "$(run_line_reads a-primary error '["skill-a"]' "[$ra, $rb]")" "$b_ok" "$n_ok"
run_case "P08: review on an error run, exit 2 wins" 2 "review: candidate: case 'a-primary' run 1: read must_not skill skill-b" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-error.json"
# C03・C04・C06: 候補と違う copy の読み取りは note の行で出し、exit には響かない
ro=$(rd '"skill-a"' '"~/.codex/skills/skill-a/SKILL.md"' other)
rs=$(rd '"skill-a"' '"~/same/skill-a/SKILL.md"' same-content)
ru=$(rd '"skill-a"' '"$X/skill-a/SKILL.md"' unknown)
write_results "$tmp/rv-copy.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' "[$ro, $rs, $ru]")" "$b_ok" "$n_ok"
run_case "copy notes do not change exit" 0 "note: candidate: case 'a-primary' run 1: read skill-a from a copy other than the candidate (reads #1, copy other)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-copy.json"
grep -q "(reads #2, copy same-content)" "$tmp/out" && grep -q "(reads #3, copy unknown)" "$tmp/out" \
  || fail "copy notes: same-content and unknown must be reported: $(cat "$tmp/out")"
# J01: reads の無い古い結果は observed で判定する (上の case 1 が exit 0 のまま)。J02 など: reads の形の検査は exit 2
write_results "$tmp/rv-missing.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' '[]')" "$b_ok" "$n_ok"
run_case "J02: observed not in reads" 2 "must include every observed skill (missing: skill-a)" \
  -- --cases "$tmp/cases.json" --results "$tmp/rv-missing.json"
for bad in '{"skill": "skill-a"}' '{"skill": "a b", "path": null, "via": "command", "copy": "candidate", "sha256": null}' \
  '{"skill": "skill-a", "path": null, "via": "cat", "copy": "candidate", "sha256": null}' \
  '{"skill": "skill-a", "path": null, "via": "command", "copy": "maybe", "sha256": null}' \
  '{"skill": "skill-a", "path": null, "via": "command", "copy": "candidate", "sha256": "xyz"}' \
  '{"skill": "skill-a", "path": 7, "via": "command", "copy": "candidate", "sha256": null}'; do
  write_results "$tmp/rv-bad.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' "[$bad]")" "$b_ok" "$n_ok"
  run_case "reads shape rejected: $bad" 2 "reads\[0\] must have skill, path, via, copy and sha256" \
    -- --cases "$tmp/cases.json" --results "$tmp/rv-bad.json"
done
write_results "$tmp/rv-notarray.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' '{}')" "$b_ok" "$n_ok"
run_case "reads must be an array" 2 "reads must be an array" -- --cases "$tmp/cases.json" --results "$tmp/rv-notarray.json"
# must_not の無い case では、名前を決められない読み取りも要確認にしない
cat > "$tmp/cases-no-must-not.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["skill-a", "skill-b"],
  "cases": [ { "id": "a-primary", "cluster": "ab", "prompt": "do a", "primary": "skill-a", "must_not": [] } ]
}
EOF
write_results "$tmp/rv-no-must-not.json" codex model-x candidate "$(run_line_reads a-primary ok '["skill-a"]' "[$ra, $rn, $rb]")"
run_case "no must_not: no review" 0 "ok: skill routing verified" -- --cases "$tmp/cases-no-must-not.json" --results "$tmp/rv-no-must-not.json"

echo "ok: check-skill-routing self-test passed"
