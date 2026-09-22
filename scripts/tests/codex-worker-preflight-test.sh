#!/bin/sh
# personal-codex-worker-preflight.rb の self-test。
# 純粋ロジック (help marker / features table / config の解釈 / launch argv) は check_helper の
# Ruby unit、codex / herdr 連携は PATH 上の fake command で integration 検証する (実 codex /
# herdr / network には触れない)。fail-closed の各分岐に独立した負例を置き、検査を 1 つ外すと
# 落ちる形にする (定義の一覧は test 側に固定値で持ち、実装の定数に依存させない)。
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

# 定義を固定値で pin する (実装側から marker / feature を 1 つ削ると検知される)。
check("必須 marker の一覧",
      P::REQUIRED_HELP_MARKERS.keys.sort == ["config override", "feature disable", "result file",
                                              "sandbox flag", "stdin prompt", "workspace-write mode"])
check("必須 marker の文字列",
      P::REQUIRED_HELP_MARKERS.values.sort == ["--config", "--disable", "--output-last-message",
                                                "--sandbox", "`-`", "workspace-write"])
check("disable する feature の一覧", P::DISABLE_FEATURES == %w[apps computer_use browser_use])

HELP_OK = <<~H
  Options:
    -c, --config <key=value>
        --disable <FEATURE>
    -s, --sandbox <SANDBOX_MODE>
            [possible values: read-only, workspace-write, danger-full-access]
    -o, --output-last-message <FILE>
  Arguments:
    [PROMPT]  If not provided as an argument (or if `-` is used), instructions are read from stdin.
H
check("help に全 marker があれば missing なし", P.missing_help_markers(HELP_OK).empty?)
{ "--config" => "config override", "--disable" => "feature disable", "--sandbox" => "sandbox flag",
  "workspace-write" => "workspace-write mode", "--output-last-message" => "result file",
  "`-`" => "stdin prompt" }.each do |text, name|
  check("#{text} が無いと #{name} が missing", P.missing_help_markers(HELP_OK.sub(text, "")) == [name])
end
check("nil help は 6 marker すべて missing", P.missing_help_markers(nil).size == 6)

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

def cfg(text)
  CodexWorkerPreflight.parse_config(text)
end

def config_error?(text)
  CodexWorkerPreflight.parse_config(text)
  false
rescue CodexWorkerPreflight::ConfigError
  true
end

CONFIG = <<~T
  model = "gpt-x"
  approval_policy = "on-request"
  developer_instructions = """
  [mcp_servers.inside_string]
  approval_mode = "approve"
  """
  note = 'single [not a header]'

  [mcp_servers]
  [mcp_servers.node_repl]
  command = "node" # comment
  [mcp_servers.node_repl.env]
  SECRET_TOKEN = "do-not-print"
  [ mcp_servers . computer-use ]
  url = "http://localhost:1"
  [apps.connector_abc.tools.github_create_issue]
  approval_mode = "approve"
  [apps."connector_quoted".tools.github_update_file]
  approval_mode = "auto"
  [apps.connector_abc.tools.github_fetch]
  approval_mode = "prompt"
  [plugins."x@y"]
  enabled = true
  [plugins.'z@w']
  enabled = true
T
c = cfg(CONFIG)
check("mcp_servers の id を重複なく取る (親 table と nested .env は数えない、空白付き header も読む)",
      c[:mcp_servers] == %w[node_repl computer-use])
check("複数行文字列の中の header は数えない", !c[:mcp_servers].include?("inside_string"))
check("apps の approve / auto を数え、prompt は数えない (quoted な connector id でも)",
      c[:apps_auto_approve_tools] == 2)
check("mcp_servers 以外の quoted section (plugins) は読み飛ばす", !config_error?("[plugins.\"x@y\"]\nenabled = true\n"))
check("config の値を返さない", !c.key?(:approval_policy) && !c.key?(:model))
check("空 config は空の結果", cfg("")[:mcp_servers] == [] && cfg("")[:apps_auto_approve_tools] == 0)
check("CRLF でも読める", cfg("[mcp_servers.a]\r\ncommand = \"x\"\r\n")[:mcp_servers] == ["a"])

check("mcp_servers の quoted id は fail-closed", config_error?("[mcp_servers.\"my server\"]\n"))
check("tokenize できない header は fail-closed (読み飛ばさない)", config_error?("[mcp_servers.\"a]b\"]\n"))
check("閉じていない header は fail-closed", config_error?("[mcp_servers.a\n"))
check("header の後ろの余分な文字は fail-closed", config_error?("[mcp_servers.a] junk\n"))
check("array table は fail-closed", config_error?("[[mcp_servers.x]]\n"))
check("id に許可外の文字があれば fail-closed", config_error?("[mcp_servers.bad id]\n"))
check("空 segment は fail-closed", config_error?("[mcp_servers.]\n"))
check("空 header は fail-closed", config_error?("[]\n"))
check("top-level の dotted key 表記は fail-closed", config_error?("mcp_servers.alpha.command = \"node\"\n"))
check("top-level の inline table 表記は fail-closed", config_error?("mcp_servers = { alpha = { command = \"node\" } }\n"))
check("親 table 直下の key は fail-closed", config_error?("[mcp_servers]\nalpha.command = \"node\"\n"))
check("親 table 直下の inline table も fail-closed", config_error?("[mcp_servers]\nalpha = { command = \"node\" }\n"))
check("閉じていない複数行文字列は fail-closed", config_error?("x = \"\"\"\nfoo\n"))
check("同じ行で閉じる複数行文字列は続きを読む", cfg("x = \"\"\"a\"\"\"\n[mcp_servers.b]\n")[:mcp_servers] == ["b"])
check("literal な複数行文字列 (''') も読み飛ばす", cfg("x = '''\n[mcp_servers.no]\n'''\n[mcp_servers.yes]\n")[:mcp_servers] == ["yes"])
check("mcp_servers 以外の key 名は fail-closed にしない", !config_error?("mcp_servers_note = \"x\"\n"))
check("bare な id は通る", cfg("[mcp_servers.ok_id-1]\n")[:mcp_servers] == ["ok_id-1"])

argv = P.launch_argv(%w[a b], %w[apps computer_use])
check("launch argv は workspace-write + approval never を固定",
      argv[0, 6] == ["codex", "exec", "-s", "workspace-write", "-c", 'approval_policy="never"'])
check("launch argv に disable と mcp の enabled=false が並ぶ",
      argv.each_cons(2).include?(["--disable", "apps"]) && argv.each_cons(2).include?(["--disable", "computer_use"]) &&
      argv.each_cons(2).include?(["-c", "mcp_servers.a.enabled=false"]) &&
      argv.each_cons(2).include?(["-c", "mcp_servers.b.enabled=false"]))
check("launch argv は result file と stdin prompt で終わる", argv.last(3) == ["-o", "<run dir>/result.md", "-"])
check("launch argv に --ephemeral を付けない", !argv.include?("--ephemeral"))

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
# 入れ、以降は "\$var" で参照する (#272 の規則)。
cat > "$fakebin/codex" <<EOF
#!/bin/sh
argv_log=$(shq "$tmp/codex-argv.log")
help_default=$(shq "$tmp/exec-help.txt")
features_default=$(shq "$tmp/features.txt")
printf '%s\n' "\$*" >> "\$argv_log"
case "\$1 \$2" in
  "--version ") printf '%s\n' "\${FAKE_CODEX_VERSION:-codex-cli 0.154.0}" ;;
  "exec --help") cat "\${FAKE_CODEX_HELP:-\$help_default}" ;;
  "features list") cat "\${FAKE_CODEX_FEATURES:-\$features_default}" ;;
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
approval_policy = "CANARY-POLICY-do-not-print"
approvals_reviewer = "CANARY-REVIEWER-do-not-print"
sandbox_mode = "workspace-write"
developer_instructions = """
[mcp_servers.inside_string]
"""
[mcp_servers]
[mcp_servers.node_repl]
command = "node"
[mcp_servers.node_repl.env]
SECRET_TOKEN = "CANARY-ENV-do-not-print"
[mcp_servers.computer-use]
url = "http://localhost:1"
[apps.connector_abc.tools.github_create_issue]
approval_mode = "approve"
[plugins."x@y"]
enabled = true
EOF

# 検査対象の env marker は両方とも外してから呼ぶ (片方が残って別の検査を隠さないように)。
run_pf() {
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" "$@"
}
run_pf_env() {
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID "$@" PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home"
}

# happy path (plugins の quoted section と親 table を含む実 config 相当): exit 0
set +e
out=$(run_pf 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "happy path should exit 0 (rc=$rc): $out"
echo "$out" | grep -q "^codex: 0.154.0" || fail "should print codex version: $out"
echo "$out" | grep -q "^mcp servers: node_repl computer-use$" || fail "should list exactly the mcp server ids: $out"
echo "$out" | grep -q "^apps auto-approve tools: 1" || fail "should count auto-approve tools: $out"
echo "$out" | grep -q "^herdr: running" || fail "should report herdr running: $out"
echo "$out" | grep -q -- "--disable apps --disable computer_use --disable browser_use" || fail "launch must disable features: $out"
echo "$out" | grep -q -- "-c mcp_servers.node_repl.enabled=false -c mcp_servers.computer-use.enabled=false" || fail "launch must disable mcp servers: $out"
echo "$out" | grep -q -- "-s workspace-write -c approval_policy=\"never\"" || fail "launch must fix sandbox and approval: $out"
case "$out" in *"CANARY"*) fail "output must not echo config values: $out" ;; esac
case "$out" in *"inside_string"*|*"mcp_servers..enabled"*) fail "must not enumerate strings or the parent table: $out" ;; esac
case "$out" in *"--ephemeral"*) fail "launch must not add --ephemeral: $out" ;; esac

# --json: 1 個の JSON で同じ内容、config の値は載らない
out=$(run_pf --json)
case "$out" in *"CANARY"*) fail "--json must not echo config values: $out" ;; esac
printf '%s' "$out" | ruby -rjson -e '
j = JSON.parse(STDIN.read)
abort "json status" unless j["status"] == "ok"
abort "json mcp_servers" unless j["mcp_servers"] == %w[node_repl computer-use]
abort "json launch_argv" unless j["launch_argv"].first(4) == %w[codex exec -s workspace-write]
abort "json disable_features" unless j["disable_features"] == %w[apps computer_use browser_use]
abort "json must not carry config values" if j.key?("approval_policy") || j.key?("approvals_reviewer") || j.key?("sandbox_mode")
' || fail "--json shape mismatch: $out"

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

# help の marker を 1 つずつ欠く -> それぞれ BLOCKED exit 1 で、欠けた marker の名前が出る
i=0
for pair in "--config|config override" "--disable <FEATURE>|feature disable" "--sandbox|sandbox flag" \
            "workspace-write|workspace-write mode" "--output-last-message|result file" "\`-\`|stdin prompt"; do
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

# config を安全に解釈できない -> exit 2 (quoted な mcp id / array table / dotted 表記 / 閉じない複数行)
home2="$tmp/codex-home-bad"
mkdir -p "$home2"
for bad in '[mcp_servers."my server"]
command = "x"' '[[mcp_servers.x]]
command = "x"' 'mcp_servers.alpha.command = "node"' '[mcp_servers]
alpha = { command = "node" }' 'x = """
never closed'; do
  printf '%s\n' "$bad" > "$home2/config.toml"
  set +e
  out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home2" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unsafe config must be exit 2 (rc=$rc) for: $bad :: $out"
done

# config が無い -> exit 0、mcp servers は (none)、enabled=false は出ない
home3="$tmp/codex-home-empty"
mkdir -p "$home3"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home3" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "missing config should still exit 0 (rc=$rc): $out"
echo "$out" | grep -q "^mcp servers: (none)" || fail "missing config should list no mcp servers: $out"
case "$out" in *"enabled=false"*) fail "no mcp flags without config: $out" ;; esac

# herdr が無い / 止まっている -> exit 0 のまま unavailable
set +e
out=$(run_pf_env FAKE_HERDR_RC=1 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "herdr down should not block (rc=$rc): $out"
echo "$out" | grep -q "^herdr: unavailable" || fail "should report herdr unavailable: $out"

# 下位 command は argv で呼ぶ (shell を介さない) — fake が受けた引数を確認
grep -q "^exec --help$" "$tmp/codex-argv.log" || fail "should call codex exec --help"
grep -q "^features list$" "$tmp/codex-argv.log" || fail "should call codex features list"

# usage エラー -> exit 2
set +e
ruby "$src" --bogus >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown option should be exit 2 (rc=$rc)"
set +e
ruby "$src" --codex-home >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "--codex-home without value should be exit 2 (rc=$rc)"

echo "ok: codex-worker-preflight self-test"
