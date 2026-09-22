#!/bin/sh
# personal-codex-worker-preflight.rb の self-test。
# 純粋ロジック (help marker / features table / config の解釈 / launch argv) は check_helper の
# Ruby unit、codex / herdr 連携は PATH 上の fake command で integration 検証する (実 codex /
# herdr / network には触れない)。fail-closed の各分岐に負例を置き、検査を 1 つ外すと落ちる形にする。
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
check("--disable が無いと missing に出る",
      P.missing_help_markers(HELP_OK.sub("--disable <FEATURE>", "")) == ["feature disable"])
check("workspace-write が無いと missing に出る",
      P.missing_help_markers(HELP_OK.sub("workspace-write", "")).include?("workspace-write mode"))
check("nil help は全 marker が missing", P.missing_help_markers(nil).size == P::REQUIRED_HELP_MARKERS.size)

check("version を読む", P.parse_version("codex-cli 0.154.0\n") == "0.154.0")
check("version 形でなければ nil", P.parse_version("something else") .nil?)

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

CONFIG = <<~T
  model = "gpt-x"
  approval_policy = "on-request"
  approvals_reviewer = "auto_review"
  sandbox_mode = "workspace-write"

  [mcp_servers.node_repl]
  command = "node"
  [mcp_servers.node_repl.env]
  SECRET_TOKEN = "do-not-print"
  [mcp_servers.computer-use]
  url = "http://localhost:1"
  [apps.connector_abc.tools.github_create_issue]
  approval_mode = "approve"
  [apps.connector_abc.tools.github_fetch]
  approval_mode = "prompt"
  [apps.connector_abc.tools.github_update_file]
  approval_mode = "auto"
  [plugins."x@y"]
  enabled = true
T
begin
  P.parse_config(CONFIG)
  check("quoted な section id は fail-closed", false)
rescue P::ConfigError
  check("quoted な section id は fail-closed", true)
end
cfg = P.parse_config(CONFIG.sub("[plugins.\"x@y\"]\nenabled = true\n", ""))
check("mcp_servers の id を重複なく取る (nested .env は同じ id)", cfg[:mcp_servers] == %w[node_repl computer-use])
check("apps の approve / auto を数え、prompt は数えない", cfg[:apps_auto_approve_tools] == 2)
check("top-level の 3 key を読む",
      cfg[:approval_policy] == "on-request" && cfg[:approvals_reviewer] == "auto_review" &&
      cfg[:sandbox_mode] == "workspace-write")
check("section 内の同名 key を top-level に混ぜない",
      P.parse_config("[foo]\napproval_policy = \"never\"\n")[:approval_policy].nil?)
check("空 config は空の結果", P.parse_config("")[:mcp_servers] == [])

def config_error?(text)
  CodexWorkerPreflight.parse_config(text)
  false
rescue CodexWorkerPreflight::ConfigError
  true
end
check("array table は fail-closed", config_error?("[[mcp_servers.x]]\n"))
check("id に許可外の文字があれば fail-closed", config_error?("[mcp_servers.bad id]\n"))
check("空 segment は fail-closed", config_error?("[mcp_servers.]\n"))
check("bare な id は通る", !config_error?("[mcp_servers.ok_id-1]\n"))

argv = P.launch_argv(%w[a b], %w[apps computer_use])
check("launch argv は workspace-write + approval never を固定",
      argv[0, 6] == ["codex", "exec", "-s", "workspace-write", "-c", 'approval_policy="never"'])
check("launch argv に disable と mcp の enabled=false が並ぶ",
      argv.include?("--disable") && argv.include?("apps") && argv.include?("computer_use") &&
      argv.include?("mcp_servers.a.enabled=false") && argv.include?("mcp_servers.b.enabled=false"))
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
# 入れ、以降は "\$var" で参照する (#272 の規則。\${VAR:-'literal'} の形は二重引用の中で
# 引用符が文字として残り、path として壊れる)。
cat > "$fakebin/codex" <<EOF
#!/bin/sh
argv_log=$(shq "$tmp/codex-argv.log")
help_default=$(shq "$tmp/exec-help.txt")
features_default=$(shq "$tmp/features.txt")
printf '%s\n' "\$*" >> "\$argv_log"
[ "\${FAKE_CODEX_MISSING:-0}" -eq 0 ] || exit 127
case "\$1 \$2" in
  "--version ") printf 'codex-cli %s\n' "\${FAKE_CODEX_VERSION:-0.154.0}" ;;
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
approval_policy = "on-request"
approvals_reviewer = "auto_review"
sandbox_mode = "workspace-write"
[mcp_servers.node_repl]
command = "node"
[mcp_servers.node_repl.env]
SECRET_TOKEN = "CANARY-do-not-print"
[mcp_servers.computer-use]
url = "http://localhost:1"
[apps.connector_abc.tools.github_create_issue]
approval_mode = "approve"
EOF

run_pf() {
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" "$@"
}

# happy path: exit 0、launch に disable と mcp が並び、config の値 (canary) は出ない
set +e
out=$(run_pf 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "happy path should exit 0 (rc=$rc): $out"
echo "$out" | grep -q "^codex: 0.154.0" || fail "should print codex version: $out"
echo "$out" | grep -q "^mcp servers: node_repl computer-use" || fail "should list mcp server ids: $out"
echo "$out" | grep -q "^apps auto-approve tools: 1" || fail "should count auto-approve tools: $out"
echo "$out" | grep -q "^herdr: running" || fail "should report herdr running: $out"
echo "$out" | grep -q -- "--disable apps --disable computer_use --disable browser_use" || fail "launch must disable features: $out"
echo "$out" | grep -q -- "-c mcp_servers.node_repl.enabled=false -c mcp_servers.computer-use.enabled=false" || fail "launch must disable mcp servers: $out"
echo "$out" | grep -q -- "-s workspace-write -c approval_policy=\"never\"" || fail "launch must fix sandbox and approval: $out"
case "$out" in *"CANARY"*) fail "output must not echo config values: $out" ;; esac
case "$out" in *"--ephemeral"*) fail "launch must not add --ephemeral: $out" ;; esac

# --json: 1 個の JSON で同じ内容
out=$(run_pf --json)
printf '%s' "$out" | ruby -rjson -e '
j = JSON.parse(STDIN.read)
abort "json status" unless j["status"] == "ok"
abort "json mcp_servers" unless j["mcp_servers"] == %w[node_repl computer-use]
abort "json launch_argv" unless j["launch_argv"].first(4) == %w[codex exec -s workspace-write]
abort "json disable_features" unless j["disable_features"] == %w[apps computer_use browser_use]
' || fail "--json shape mismatch: $out"

# 非対称: Codex の session 内 (env marker) からは BLOCKED exit 1
set +e
out=$(env CODEX_SANDBOX=workspace-write PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "inside Codex session must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "BLOCKED (asymmetry)" || fail "should name asymmetry: $out"
set +e
env CODEX_THREAD_ID=t PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "CODEX_THREAD_ID must also be BLOCKED (rc=$rc)"

# --json でも BLOCKED は JSON で返る
out=$(env CODEX_SANDBOX=1 PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" --json 2>/dev/null || true)
printf '%s' "$out" | ruby -rjson -e 'j = JSON.parse(STDIN.read); abort unless j["status"] == "BLOCKED" && j["blocked_at"] == "asymmetry"' \
  || fail "--json BLOCKED shape: $out"

# codex が無い -> BLOCKED exit 1
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID FAKE_CODEX_MISSING=1 PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "missing codex must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "BLOCKED (capability)" || fail "should name capability: $out"

# help に --disable が無い -> BLOCKED exit 1
sed 's/--disable <FEATURE>//' "$tmp/exec-help.txt" > "$tmp/help-nodisable.txt"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID FAKE_CODEX_HELP="$tmp/help-nodisable.txt" PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "help without --disable must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "feature disable" || fail "should name the missing flag: $out"

# features list に apps が無い -> BLOCKED exit 1
grep -v '^apps ' "$tmp/features.txt" > "$tmp/features-noapps.txt"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID FAKE_CODEX_FEATURES="$tmp/features-noapps.txt" PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "features without apps must be BLOCKED (rc=$rc): $out"
echo "$out" | grep -q "apps" || fail "should name the absent feature: $out"

# config が解釈できない (quoted id / array table) -> exit 2
home2="$tmp/codex-home-quoted"
mkdir -p "$home2"
printf '[mcp_servers."my server"]\ncommand = "x"\n' > "$home2/config.toml"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home2" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "quoted mcp id must be exit 2 (rc=$rc): $out"
printf '[[mcp_servers.x]]\ncommand = "x"\n' > "$home2/config.toml"
set +e
env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home2" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "array table must be exit 2 (rc=$rc)"

# config が無い -> exit 0、mcp servers は (none)
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
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID FAKE_HERDR_RC=1 PATH="$fakebin:$PATH" ruby "$src" --codex-home "$home" 2>&1)
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
