#!/bin/sh
# scripts/lib/probe_skill_routing.rb の self-test (#372 / #384)。
# - Codex の起動の境界: probe の Codex の起動に、監査 / review と同じ境界 (user config の MCP /
#   connector と rules を外し、sandbox の外へ届く feature を disable する) が付くこと、起動の前に flag と
#   feature の在否を確かめて欠けていれば Codex を起動せずに exit 2 になることを、PATH 上の偽の codex で
#   確かめる。
# - model の選択: --model が無いときは CODEX_HOME の fixture の config.toml の top-level (最初の table
#   header より前) の model だけを使い、無ければエラーにする。
# - raw log の保存先: raw dir の外を指す case id では CLI を起動せずに exit 2 で止まり、raw dir の外に
#   何も作らない。
# 実 codex / network / 実 ~/.codex には触れない。event の解析 (parse_claude / parse_codex) はこの suite の
# 対象外。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/scripts/lib/probe_skill_routing.rb"
[ -f "$src" ] || fail "missing $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- Ruby unit checks: 起動の argv -------------------------------------------------
empty_home="$tmp/codex-home-empty"
mkdir -p "$empty_home"
skill_home="$tmp/codex-home-skills"
mkdir -p "$skill_home/skills/personal-a"
printf -- '---\nname: personal-a\ndescription: a\n---\n' > "$skill_home/skills/personal-a/SKILL.md"

ruby -r"$script_dir/lib/check_helper" - "$src" "$empty_home" "$skill_home" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

ENV["CODEX_HOME"] = ARGV[1]
argv = P.codex_argv({ model: "m-x" }, "/proj", ["personal-a"])
check("境界つきの argv を固定する",
      argv == ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
               "--ignore-user-config", "--ignore-rules", "-s", "read-only", "-c", 'approval_policy="never"',
               "--disable", "apps", "--disable", "computer_use", "--disable", "browser_use",
               "-C", "/proj", "-m", "m-x", "-"])
check("disable する feature の一覧", P::CODEX_DISABLE_FEATURES == %w[apps computer_use browser_use])
check("起動の前に確かめる flag の一覧", P::CODEX_HELP_MARKERS == %w[--ignore-user-config --ignore-rules --disable])

# 候補と同名の user skill の無効化 (-c skills.config) は境界と両立し、prompt (stdin の -) の前に付く
ENV["CODEX_HOME"] = ARGV[2]
argv = P.codex_argv({ model: "m-x" }, "/proj", ["personal-a"])
check("境界の flag は skills.config の override と両立する",
      argv.include?("--ignore-user-config") && argv.include?("--ignore-rules") &&
      argv[-3] == "-c" && argv[-2].start_with?("skills.config=[{path=") && argv[-1] == "-")
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: config からの model の選択 ---------------------------------------
# top-level に model が無く profile の table にだけある config と、両方にある config
profile_home="$tmp/codex-home-profile-model"
mkdir -p "$profile_home"
printf '%s\n' '# top-level に model は無い' '' 'approval_policy = "never"' '' '[profiles.other]' 'model = "CANARY-PROFILE"' \
  > "$profile_home/config.toml"
top_home="$tmp/codex-home-top-model"
mkdir -p "$top_home"
printf '%s\n' '# comment' '' 'approval_policy = "never"' 'model = "m-top"' '' '[profiles.other]' 'model = "CANARY-PROFILE"' \
  > "$top_home/config.toml"

ruby -r"$script_dir/lib/check_helper" - "$src" "$profile_home" "$top_home" "$empty_home" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

# model が無い config で codex_model / codex_argv が --model is required のエラーになるか
def model_required_error?
  yield
  false
rescue ProbeSkillRouting::Error => e
  e.message.include?("--model is required")
end

ENV["CODEX_HOME"] = ARGV[1]
check("profile の table にだけある model は top-level の model として使わない (エラーにする)",
      model_required_error? { P.codex_model({}) })
check("profile の table にだけある model で Codex を起動しない",
      model_required_error? { P.codex_argv({}, "/proj", []) })

ENV["CODEX_HOME"] = ARGV[2]
check("top-level の model を使う", P.codex_model({}) == "m-top")
argv = P.codex_argv({}, "/proj", [])
check("top-level の model を -m に渡す", argv[argv.index("-m") + 1] == "m-top")
check("--model があれば config より優先する", P.codex_model({ model: "m-x" }) == "m-x")

ENV["CODEX_HOME"] = ARGV[3]
check("config.toml が無ければ --model is required のエラーにする", model_required_error? { P.codex_model({}) })
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- Ruby unit checks: raw log の保存先 -------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
P = ProbeSkillRouting

raw = File.join("out", "results.json.raw")
check("raw log は raw dir の直下に <case id>-<n>.<ext> で保存する",
      P.raw_log_path(raw, "a-primary", 1, "jsonl") == File.join(raw, "a-primary-1.jsonl") &&
      P.raw_log_path(raw, "a.b_c-2", 3, "stderr") == File.join(raw, "a.b_c-2-3.stderr"))
["../escaped", "../../escaped", "sub/escaped"].each do |id|
  stopped = begin
    P.raw_log_path(raw, id, 1, "jsonl")
    false
  rescue P::Error => e
    e.message.include?("outside")
  end
  check("raw dir の外を指す case id (#{id}) は保存の前に止める", stopped)
end
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- integration: 偽の codex で preflight と起動を確かめる -----------------------------
fakebin="$tmp/bin"
mkdir -p "$fakebin"
log="$tmp/codex-calls.log"
cat > "$fakebin/codex" <<'EOF'
#!/bin/sh
# 偽の codex。呼ばれた argv を 1 行ずつ log に残し、help / features list / exec を模倣する。
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
case "$1 $2" in
  "exec --help")
    help='Options:
  -c, --config <key=value>
      --ignore-user-config
      --ignore-rules
      --disable <FEATURE>
  -s, --sandbox <SANDBOX_MODE>'
    [ -n "${FAKE_HELP_DROP:-}" ] && help=$(printf '%s\n' "$help" | grep -v -- "$FAKE_HELP_DROP")
    printf '%s\n' "$help"
    exit "${FAKE_RC_HELP:-0}" ;;
  "features list")
    printf '%s\n' "${FAKE_FEATURES:-apps  stable  true
computer_use  beta  false
browser_use  beta  false}"
    exit "${FAKE_RC_FEATURES:-0}" ;;
  exec*)
    cat > /dev/null
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"personal-a"}}'
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
    exit 0 ;;
esac
echo "fake codex: unexpected args: $*" >&2
exit 64
EOF
chmod +x "$fakebin/codex"

source_dir="$tmp/source"
mkdir -p "$source_dir/personal-a"
printf -- '---\nname: personal-a\ndescription: a\n---\n' > "$source_dir/personal-a/SKILL.md"

# run_probe <args...>: 偽の codex を PATH に置き、実 ~/.codex の代わりに空の CODEX_HOME で probe を回す
run_probe() {
  : > "$log"
  set +e
  out=$(env FAKE_CODEX_LOG="$log" CODEX_HOME="$empty_home" PATH="$fakebin:$PATH" \
    ruby "$src" --tool codex --model m-x --source "$source_dir" "$@" 2>&1)
  rc=$?
  set -e
}

# 正常: preflight (help と features list) を通ってから、境界つきの argv で exec が起動する
run_probe --smoke
[ "$rc" -eq 0 ] || fail "smoke with a capable codex should exit 0 (rc=$rc): $out"
grep -q '^exec --help$' "$log" || fail "preflight should read exec --help: $(cat "$log")"
grep -q '^features list$' "$log" || fail "preflight should read features list: $(cat "$log")"
grep -q -- '^exec --json .*--ignore-user-config --ignore-rules -s read-only .*--disable apps --disable computer_use --disable browser_use ' "$log" \
  || fail "exec must be launched with the boundary flags: $(cat "$log")"

# 欠けたら Codex を起動せず exit 2 (存在しない flag を試さない)。理由に欠けたものを出す
for flag in --ignore-user-config --ignore-rules --disable; do
  FAKE_HELP_DROP="$flag"
  export FAKE_HELP_DROP
  run_probe --smoke
  unset FAKE_HELP_DROP
  [ "$rc" -eq 2 ] || fail "missing $flag must exit 2 (rc=$rc): $out"
  case "$out" in *"$flag"*) : ;; *) fail "missing $flag should be named: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "codex must not be launched without $flag: $(cat "$log")"; fi
done

for feature in apps computer_use browser_use; do
  FAKE_FEATURES=$(printf 'apps  stable  true\ncomputer_use  beta  false\nbrowser_use  beta  false\n' | grep -v "^$feature ")
  export FAKE_FEATURES
  run_probe --smoke
  unset FAKE_FEATURES
  [ "$rc" -eq 2 ] || fail "missing feature $feature must exit 2 (rc=$rc): $out"
  case "$out" in *"$feature"*) : ;; *) fail "missing feature $feature should be named: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "codex must not be launched without feature $feature: $(cat "$log")"; fi
done

# help / features list が非ゼロなら、出力が正常でも信じない
for pair in "FAKE_RC_HELP|exec --help" "FAKE_RC_FEATURES|features list"; do
  var=${pair%%|*}
  what=${pair#*|}
  run_probe_env() {
    : > "$log"
    set +e
    out=$(env "$var=3" FAKE_CODEX_LOG="$log" CODEX_HOME="$empty_home" PATH="$fakebin:$PATH" \
      ruby "$src" --tool codex --model m-x --source "$source_dir" --smoke 2>&1)
    rc=$?
    set -e
  }
  run_probe_env
  [ "$rc" -eq 2 ] || fail "non-zero $what must exit 2 (rc=$rc): $out"
  case "$out" in *"$what"*) : ;; *) fail "non-zero $what should be named: $out" ;; esac
  if grep -q '^exec --json' "$log"; then fail "codex must not be launched when $what fails: $(cat "$log")"; fi
done

# dry-run は CLI を起動しない (preflight もしない) が、表示する argv に境界が載る
run_probe --dry-run
[ "$rc" -eq 0 ] || fail "dry-run should exit 0 (rc=$rc): $out"
[ ! -s "$log" ] || fail "dry-run must not call codex: $(cat "$log")"
case "$out" in *'"--ignore-user-config" "--ignore-rules"'*'"--disable" "browser_use"'*) : ;; *) fail "dry-run argv should show the boundary: $out" ;; esac

# case id は raw log の file 名に使う。raw dir の外を指す id では Codex を起動せずに exit 2 で止まり、
# raw dir の外 (ここでは --out の directory) に何も作らない
cat > "$tmp/escape-cases.json" <<'EOF'
{
  "schema_version": 1,
  "inventory": ["personal-a"],
  "cases": [
    { "id": "../escaped", "cluster": "x", "prompt": "do a", "primary": "personal-a", "must_not": [] }
  ]
}
EOF
mkdir -p "$tmp/escape"
run_probe --cases "$tmp/escape-cases.json" --out "$tmp/escape/out/results.json"
[ "$rc" -eq 2 ] || fail "case id outside the raw dir must exit 2 (rc=$rc): $out"
case "$out" in *error:*) : ;; *) fail "case id outside the raw dir should be reported as an error: $out" ;; esac
if grep -q '^exec --json' "$log"; then fail "codex must not be launched for a case id outside the raw dir: $(cat "$log")"; fi
find "$tmp/escape" -type f > "$tmp/escape-files"
[ ! -s "$tmp/escape-files" ] || fail "nothing may be written for a case id outside the raw dir: $(cat "$tmp/escape-files")"

echo "probe-skill-routing-test: ok"
