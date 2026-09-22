#!/bin/sh
# personal-codex-worker-preflight.rb の self-test。
# 純粋ロジック (help marker / features table / model 選択の読み取り / launch argv) は check_helper の
# Ruby unit、codex / herdr 連携は PATH 上の fake command で integration 検証する (実 codex /
# herdr / network には触れない)。fail-closed の各分岐に独立した負例を置き、検査を 1 つ外すと
# 落ちる形にする (定義の一覧は test 側に固定値で持ち、実装の定数に依存させない。Codex の 3 command
# の「出力は正常だが exit が非ゼロ」も subcommand ごとに負例を持つ。herdr は任意の状態表示なので
# 非ゼロでも exit 0 のまま unavailable)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-codex-worker-preflight.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- Ruby unit checks: 純粋ロジック ------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
require ARGV[0]
P = CodexWorkerPreflight

# 定義を固定値で pin する (実装側から marker / feature / key を 1 つ削ると検知される)。
check("必須 marker の一覧",
      P::REQUIRED_HELP_MARKERS.keys.sort == ["config override", "feature disable", "result file", "rules ignore",
                                              "sandbox flag", "stdin prompt", "user config ignore",
                                              "workspace-write mode"])
check("必須 marker の文字列",
      P::REQUIRED_HELP_MARKERS.values.sort == ["--config", "--disable", "--ignore-rules", "--ignore-user-config",
                                                "--output-last-message", "--sandbox", "`-`", "workspace-write"])
check("disable する feature の一覧", P::DISABLE_FEATURES == %w[apps computer_use browser_use])
check("再指定する key の一覧", P::MODEL_KEYS == { "--model" => "model", "--effort" => "model_reasoning_effort" })

HELP_OK = <<~H
  Options:
    -c, --config <key=value>
        --disable <FEATURE>
    -s, --sandbox <SANDBOX_MODE>
            [possible values: read-only, workspace-write, danger-full-access]
        --ignore-user-config
        --ignore-rules
    -o, --output-last-message <FILE>
  Arguments:
    [PROMPT]  If not provided as an argument (or if `-` is used), instructions are read from stdin.
H
check("help に全 marker があれば missing なし", P.missing_help_markers(HELP_OK).empty?)
{ "--config" => "config override", "--disable" => "feature disable", "--sandbox" => "sandbox flag",
  "workspace-write" => "workspace-write mode", "--ignore-user-config" => "user config ignore",
  "--ignore-rules" => "rules ignore", "--output-last-message" => "result file", "`-`" => "stdin prompt" }.each do |text, name|
  check("#{text} が無いと #{name} が missing", P.missing_help_markers(HELP_OK.sub(text, "")) == [name])
end
check("nil help は 8 marker すべて missing", P.missing_help_markers(nil).size == 8)

check("version を読む", P.parse_version("codex-cli 0.154.0\n") == "0.154.0")
check("version 形でなければ nil", P.parse_version("something else").nil?)

FEATURES = <<~F
  apply_patch_preserve_line_endings        under development  false
  apps                                     stable             true
  browser_use                              stable             true
  computer_use                             stable             true
  js_repl                                  removed            false
F
feats = P.parse_features(FEATURES)
check("features table を name => {stage, enabled} に読む",
      feats["apps"] == { stage: "stable", enabled: true } &&
      feats["apply_patch_preserve_line_endings"] == { stage: "under development", enabled: false })
check("列が 2 空白未満の行は読まない", P.parse_features("apps stable true\n").empty?)

def sel(text)
  CodexWorkerPreflight.read_model_selection(text)
end

def sel_error?(text)
  CodexWorkerPreflight.read_model_selection(text)
  false
rescue ArgumentError
  true
end

check("top-level の model と effort を読む",
      sel("model = \"gpt-x\"\nmodel_reasoning_effort = \"xhigh\" # note\n") ==
      { "model" => "gpt-x", "model_reasoning_effort" => "xhigh" })
check("片方だけでも読む", sel("model = \"gpt-x\"\n") == { "model" => "gpt-x" })
check("無ければ空 (Codex の既定に委ねる)", sel("") == {} && sel("other = \"x\"\n") == {})
check("table header より後の model は読まない", sel("[profiles.a]\nmodel = \"other\"\n") == {})
check("comment 行は読まない", sel("# model = \"gpt-x\"\n") == {})
check("CRLF でも読める", sel("model = \"gpt-x\"\r\n") == { "model" => "gpt-x" })
check("1 行で閉じる配列・literal string・bare scalar の行は通る",
      sel("notify = [\"a\", \"b\"]\nx = 'lit'\nn = 12\nb = true\nmodel = \"gpt-x\"\n") == { "model" => "gpt-x" })
check("値の中の [ は header と誤認しない", sel("s = \"[not a header]\"\nmodel = \"gpt-x\"\n") == { "model" => "gpt-x" })
check("許可した文字だけの値は通る", sel("model = \"gpt-6.1_astra-x\"\n") == { "model" => "gpt-6.1_astra-x" })

check("複数行文字列の開始行は fail-closed (偽 key が 1 つでも拾わない)",
      sel_error?("developer_instructions = '''\nmodel = \"CANARY\"\n[example]\n'''\nmodel = \"gpt-x\"\n"))
check("複数行文字列 (basic) も fail-closed", sel_error?("note = \"\"\"\nmodel = \"b\"\n\"\"\"\n"))
check("複数行に跨る配列 (継続行) は fail-closed", sel_error?("notify = [\n  \"a\",\n]\nmodel = \"gpt-x\"\n"))
check("comment の ] で閉じたように見える配列 + [ 始まりの継続行は fail-closed (header と誤認しない)",
      sel_error?("matrix = [ # ]\n  [1, 2]\n]\nmodel = \"gpt-x\"\n"))
check("配列の要素に \"\"\" / ''' があれば fail-closed",
      sel_error?("note = [\"\"\"x\"\"\"]\n") && sel_error?("note = ['''x''']\n"))
check("配列の要素の文字列に ] / [ / # があれば fail-closed",
      sel_error?("a = [\"x]y\"]\n") && sel_error?("a = [\"x[y\"]\n") && sel_error?("a = [\"x#y\"]\n"))
check("入れ子の配列は fail-closed", sel_error?("a = [1, [2]]\n"))
check("平坦な配列 (空・末尾 comma・空白あり) は通る",
      sel("a = []\nb = [ ]\nc = [1, 2,]\nd = [ \"x\" , 'y' ]\nmodel = \"gpt-x\"\n") == { "model" => "gpt-x" })
check("inline table は fail-closed", sel_error?("t = { a = 1 }\n"))
check("quoted key は fail-closed", sel_error?("\"model\" = \"gpt-x\"\n") && sel_error?("'model_reasoning_effort' = \"x\"\n"))
check("dotted key は fail-closed", sel_error?("model.name = \"x\"\n"))
check("escape を含む文字列は fail-closed", sel_error?("model = \"a\\\"\"\n"))
check("model の値が basic string 以外は fail-closed", sel_error?("model = 'gpt-x'\n") && sel_error?("model = gpt\n"))
check("同じ key が複数なら fail-closed", sel_error?("model = \"a\"\nmodel = \"b\"\n"))
check("値に空白があれば fail-closed", sel_error?("model = \"a b\"\n"))
check("値が空なら fail-closed", sel_error?("model = \"\"\n"))
check("model と無関係な行でも分類できなければ fail-closed", sel_error?("weird line\nmodel = \"gpt-x\"\n"))

argv = P.launch_argv(%w[apps computer_use], { "model" => "gpt-x", "model_reasoning_effort" => "xhigh" })
check("launch argv は --ignore-user-config + --ignore-rules + workspace-write + approval never を固定",
      argv[0, 8] == ["codex", "exec", "--ignore-user-config", "--ignore-rules", "-s", "workspace-write",
                     "-c", 'approval_policy="never"'])
check("launch argv に disable が並ぶ",
      argv.each_cons(2).include?(["--disable", "apps"]) && argv.each_cons(2).include?(["--disable", "computer_use"]))
check("launch argv に model / effort の再指定が並ぶ",
      argv.each_cons(2).include?(["-c", 'model="gpt-x"']) &&
      argv.each_cons(2).include?(["-c", 'model_reasoning_effort="xhigh"']))
check("選択が無ければ再指定を付けない", P.launch_argv(%w[apps], {}).none? { |a| a.start_with?("model") })
check("launch argv は result file と stdin prompt で終わる", argv.last(3) == ["-o", "<run dir>/result.md", "-"])
check("launch argv に --ephemeral や mcp_servers を付けない",
      !argv.include?("--ephemeral") && argv.none? { |a| a.include?("mcp_servers") })

exit(@failed.zero? ? 0 : 1)
RUBY

# ---- integration: fake codex / herdr 経由 ---------------------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$tmp/exec-help.txt" <<'EOF'
Run Codex non-interactively
Options:
  -c, --config <key=value>
      --disable <FEATURE>
  -s, --sandbox <SANDBOX_MODE>
          [possible values: read-only, workspace-write, danger-full-access]
      --ignore-user-config
      --ignore-rules
  -o, --output-last-message <FILE>
Arguments:
  [PROMPT]  If not provided as an argument (or if `-` is used), instructions are read from stdin.
EOF
cat > "$tmp/features.txt" <<'EOF'
apps                                     stable             true
browser_use                              stable             true
computer_use                             stable             true
multi_agent                              stable             true
EOF
# 生成する fake の中へ runtime の path を埋めるときは shell literal 化した値を変数に 1 回だけ
# 入れ、以降は "\$var" で参照する (#272 の規則)。subcommand ごとに「出力は正常のまま exit だけ
# 非ゼロ」にできる (FAKE_CODEX_RC_*)。
cat > "$fakebin/codex" <<EOF
#!/bin/sh
argv_log=$(shq "$tmp/codex-argv.log")
help_default=$(shq "$tmp/exec-help.txt")
features_default=$(shq "$tmp/features.txt")
printf '%s\n' "\$*" >> "\$argv_log"
case "\$1 \$2" in
  "--version ") printf '%s\n' "\${FAKE_CODEX_VERSION:-codex-cli 0.154.0}"; exit "\${FAKE_CODEX_RC_VERSION:-0}" ;;
  "exec --help") cat "\${FAKE_CODEX_HELP:-\$help_default}"; exit "\${FAKE_CODEX_RC_HELP:-0}" ;;
  "features list") cat "\${FAKE_CODEX_FEATURES:-\$features_default}"; exit "\${FAKE_CODEX_RC_FEATURES:-0}" ;;
  *) echo "unexpected: \$*" >&2; exit 3 ;;
esac
EOF
chmod +x "$fakebin/codex"
cat > "$fakebin/herdr" <<'EOF'
#!/bin/sh
[ "${FAKE_HERDR_RC:-0}" -eq 0 ] || exit "$FAKE_HERDR_RC"
printf 'server:\n  status: running\n'
EOF
chmod +x "$fakebin/herdr"

home="$tmp/codex-home"
mkdir -p "$home"
cat > "$home/config.toml" <<'EOF'
model = "gpt-x"
model_reasoning_effort = "xhigh"
approval_policy = "CANARY-POLICY-do-not-print"
sandbox_mode = "workspace-write"
notify = ["python3", "/opt/CANARY-NOTIFY/notify.py"]
[mcp_servers.node_repl]
command = "/opt/CANARY-PATH/node"
[profiles.other]
model = "CANARY-PROFILE-model"
EOF

# 検査対象の env marker は両方とも外してから呼ぶ (片方が残って別の検査を隠さないように)。
run_pf() {
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" "$@"
}
run_pf_env() {
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID "$@" PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home"
}

launch_expected='launch: codex exec --ignore-user-config --ignore-rules -s workspace-write -c approval_policy="never" --disable apps --disable computer_use --disable browser_use -c model="gpt-x" -c model_reasoning_effort="xhigh" -o <run dir>/result.md -'

# happy path (1 行配列を含む実 config 相当): exit 0、model / effort は config から、他の値は出ない
set +e
out=$(run_pf 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "happy path should exit 0 (rc=$rc): $out"
echo "$out" | grep -q "^codex: 0.154.0" || fail "should print codex version: $out"
echo "$out" | grep -q "^model: gpt-x (config)$" || fail "should print the model from config: $out"
echo "$out" | grep -q "^model_reasoning_effort: xhigh (config)$" || fail "should print the effort from config: $out"
echo "$out" | grep -q "^herdr: running" || fail "should report herdr running: $out"
echo "$out" | grep -q -F "$launch_expected" || fail "launch line mismatch: $out"
case "$out" in *"CANARY"*) fail "output must not echo other config values: $out" ;; esac
case "$out" in *"--ephemeral"*|*"mcp_servers"*) fail "launch must not add --ephemeral or mcp flags: $out" ;; esac
grep -q "^exec --help$" "$tmp/codex-argv.log" || fail "should call codex exec --help"
grep -q "^features list$" "$tmp/codex-argv.log" || fail "should call codex features list"

# --json: 1 個の JSON で同じ内容
out=$(run_pf --json)
case "$out" in *"CANARY"*) fail "--json must not echo other config values: $out" ;; esac
printf '%s' "$out" | ruby -rjson -e '
j = JSON.parse(STDIN.read)
abort "json status" unless j["status"] == "ok"
abort "json model" unless j["model"] == "gpt-x" && j["model_reasoning_effort"] == "xhigh" && j["model_source"] == "config"
abort "json launch_argv" unless j["launch_argv"].first(6) == %w[codex exec --ignore-user-config --ignore-rules -s workspace-write]
abort "json disable_features" unless j["disable_features"] == %w[apps computer_use browser_use]
' || fail "--json shape mismatch: $out"

# --model / --effort の明示: config を読まない (解釈できない config でも exit 0)
home2="$tmp/codex-home-bad"
mkdir -p "$home2"
printf 'developer_instructions = """\nmodel = "CANARY-STRING"\n"""\n' > "$home2/config.toml"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home2" --model gpt-y --effort high 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "explicit --model/--effort should bypass config (rc=$rc): $out"
echo "$out" | grep -q "^model: gpt-y (explicit)$" || fail "explicit model should be used: $out"
echo "$out" | grep -q -- '-c model="gpt-y" -c model_reasoning_effort="high"' || fail "explicit values must reach launch: $out"
case "$out" in *"CANARY"*) fail "config must not be read when explicit: $out" ;; esac
# 明示の値が不正 -> exit 2
set +e
run_pf --model "gpt y" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unsafe explicit model must be exit 2 (rc=$rc)"

# config を安全に解釈できない -> exit 2 (複数行文字列 / 継続行 / quoted key / 重複 / 不正な値)
i=0
for bad in 'developer_instructions = """
model = "CANARY"
"""
model = "gpt-x"' 'notify = [
  "a",
]
model = "gpt-x"' 'matrix = [ # ]
  [1, 2]
]
model = "gpt-x"' 'note = ["""CANARY"""]
model = "gpt-x"' '"model" = "gpt-x"' 'model = "a"
model = "b"' 'model = "a b"' 'model_reasoning_effort = ""'; do
  i=$((i + 1))
  printf '%s\n' "$bad" > "$home2/config.toml"
  set +e
  out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home2" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unsafe config #$i must be exit 2 (rc=$rc): $out"
  case "$out" in *"CANARY"*) fail "error output must not echo config content: $out" ;; esac
done

# config が無い -> exit 0、model は codex default、再指定を付けない
home3="$tmp/codex-home-empty"
mkdir -p "$home3"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home3" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "missing config should still exit 0 (rc=$rc): $out"
echo "$out" | grep -q "^model: (codex default)" || fail "missing config should leave the model to codex: $out"
case "$out" in *"-c model"*) fail "no model flags without config: $out" ;; esac

# 非対称: env marker のどちらか 1 つだけで BLOCKED exit 1 (もう片方は外す)
set +e
out=$(env -u CODEX_THREAD_ID CODEX_SANDBOX=workspace-write PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "CODEX_SANDBOX must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "BLOCKED (asymmetry)" || fail "should name asymmetry: $out"
set +e
out=$(env -u CODEX_SANDBOX CODEX_THREAD_ID=t PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "CODEX_THREAD_ID must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "BLOCKED (asymmetry)" || fail "should name asymmetry for CODEX_THREAD_ID: $out"

# --json でも BLOCKED は JSON で返る
out=$(env -u CODEX_THREAD_ID CODEX_SANDBOX=1 PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" --json 2>/dev/null || true)
printf '%s' "$out" | ruby -rjson -e 'j = JSON.parse(STDIN.read); abort unless j["status"] == "BLOCKED" && j["blocked_at"] == "asymmetry"' \
  || fail "--json BLOCKED shape: $out"

# codex が PATH に無い (実際の command 不在) -> BLOCKED exit 1
emptybin="$tmp/emptybin"
mkdir -p "$emptybin"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$emptybin:/usr/bin:/bin" "$(command -v ruby)" "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "missing codex must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "BLOCKED (capability)" || fail "should name capability for missing codex: $out"

# 版が読めない -> BLOCKED exit 1
set +e
out=$(run_pf_env FAKE_CODEX_VERSION="not a version" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "unparseable version must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "BLOCKED (capability)" || fail "should name capability for bad version: $out"

# Codex の 3 command が「正常な出力のまま exit 非ゼロ」-> それぞれ BLOCKED exit 1
for var in FAKE_CODEX_RC_VERSION FAKE_CODEX_RC_HELP FAKE_CODEX_RC_FEATURES; do
  set +e
  out=$(run_pf_env "$var=1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "$var=1 (normal output, non-zero exit) must be BLOCKED (rc=$rc): $out"
  echo "$out" | grep -q "BLOCKED (capability)" || fail "$var=1 should name capability: $out"
done

# help の marker を 1 つずつ欠く -> それぞれ BLOCKED exit 1 で、欠けた marker の名前が出る
i=0
for pair in "--config|config override" "--disable <FEATURE>|feature disable" "--sandbox|sandbox flag" \
            "workspace-write|workspace-write mode" "--ignore-user-config|user config ignore" \
            "--ignore-rules|rules ignore" "--output-last-message|result file" "\`-\`|stdin prompt"; do
  i=$((i + 1))
  text=${pair%%|*}
  name=${pair#*|}
  ruby -e 'File.write(ARGV[2], File.read(ARGV[0]).sub(ARGV[1], ""))' "$tmp/exec-help.txt" "$text" "$tmp/help-missing-$i.txt"
  set +e
  out=$(run_pf_env FAKE_CODEX_HELP="$tmp/help-missing-$i.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "help without '$text' must be BLOCKED (rc=$rc): $out"
  echo "$out" | grep -q "$name" || fail "should name the missing marker '$name': $out"
done

# features list の行を 1 つずつ欠く -> それぞれ BLOCKED exit 1 で、欠けた feature の名前が出る
for feature in apps computer_use browser_use; do
  grep -v "^$feature " "$tmp/features.txt" > "$tmp/features-no-$feature.txt"
  set +e
  out=$(run_pf_env FAKE_CODEX_FEATURES="$tmp/features-no-$feature.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "features without $feature must be BLOCKED (rc=$rc): $out"
  echo "$out" | grep -q "$feature" || fail "should name the absent feature $feature: $out"
done

# herdr は任意の状態表示: 無い / 止まっていても exit 0 のまま unavailable
set +e
out=$(run_pf_env FAKE_HERDR_RC=1 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "herdr down should not block (rc=$rc): $out"
echo "$out" | grep -q "^herdr: unavailable" || fail "should report herdr unavailable: $out"

# usage エラー -> exit 2
set +e
ruby "$src" --bogus >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown option should be exit 2 (rc=$rc)"
for opt in --codex-home --model --effort; do
  set +e
  ruby "$src" "$opt" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$opt without value should be exit 2 (rc=$rc)"
done

echo "ok: codex-worker-preflight self-test"
