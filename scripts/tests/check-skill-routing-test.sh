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

# --- case 11: 候補で primary hit が減ったら回帰 (exit 1) ---
run_case "compare-hit-regression" 1 "regression: primary hits decreased (2/2 -> 1/2)" \
  -- --cases "$tmp/cases.json" --results "$tmp/miss.json" --baseline "$tmp/ok.json"

# --- case 12: 候補で violation が増えたら回帰 (exit 1)。baseline 側の violation は破れにしない ---
run_case "compare-violation-regression" 1 "regression: must_not violations increased (0 -> 1)" \
  -- --cases "$tmp/cases.json" --results "$tmp/viol.json" --baseline "$tmp/ok.json"
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
printf '{"schema_version": 2, "tool": "codex", "model": "m", "variant": "v", "runs": []}\n' > "$tmp/bad-version.json"
run_case "results-schema-version" 2 "schema_version must be 1" -- --cases "$tmp/cases.json" --results "$tmp/bad-version.json"

# --- case 17: case set 自体の不備も exit 2 (primary が inventory 外 / id 重複 / prompt の制御文字 / primary が must_not に含まれる) ---
sed 's/"primary": "skill-a"/"primary": "skill-z"/' "$tmp/cases.json" > "$tmp/cases-bad-primary.json"
run_case "cases-primary-outside-inventory" 2 "primary must be null or an inventory skill" -- --cases "$tmp/cases-bad-primary.json" --results "$tmp/ok.json"
sed 's/"id": "b-primary"/"id": "a-primary"/' "$tmp/cases.json" > "$tmp/cases-dup.json"
run_case "cases-duplicate-id" 2 "duplicate case id" -- --cases "$tmp/cases-dup.json" --results "$tmp/ok.json"
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

# --- case 19: 正本の case set は schema に通る (inventory 13 件・runtime skill と一致) ---
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  abort "inventory must have 13 skills" unless d["inventory"].length == 13
  ids = d["cases"].map { |c| c["id"] }
  abort "duplicate ids" unless ids.uniq.length == ids.length
  covered = d["cases"].map { |c| c["primary"] }.compact.uniq
  missing = d["inventory"] - covered - ["personal-production-rail"]
  abort "inventory skills without a primary case: #{missing.join(", ")}" unless missing.empty?
' "$real_cases" || fail "real case set: inventory / coverage invariant broken"
# 正本 case set で「全 case を cover した空 observed」を判定に通す = schema としては valid
ruby -rjson -e '
  d = JSON.parse(File.read(ARGV[0]))
  runs = d["cases"].map { |c| { "case" => c["id"], "status" => "ok", "observed" => [], "prompt_tokens" => 0, "output_tokens" => 0 } }
  puts JSON.generate({ "schema_version" => 1, "tool" => "claude-code", "model" => "m", "variant" => "v", "runs" => runs })
' "$real_cases" > "$tmp/real-empty.json"
run_case "real-cases-valid" 0 "ok: skill routing verified" -- --cases "$real_cases" --results "$tmp/real-empty.json"

echo "ok: check-skill-routing self-test passed"
