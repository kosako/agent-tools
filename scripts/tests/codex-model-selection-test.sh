#!/bin/sh
# personal-codex-model-selection.rb の self-test (#364)。
# 配備と同じ layout (同じ directory に、拡張子なしの名前で personal-codex-worker-preflight と並べる) に
# copy して CLI として実行する。Codex home は fixture の directory を CODEX_HOME で渡し、実物の ~/.codex には
# 触れない。選択結果 (key ごとの重ね方と出所) とエラー契約 (exit 2、理由文、stdout は空、file の中身と path を
# 出さない) を固定する。重ね方そのものは preflight の layered_model_selection が持つので、worker の経路は
# codex-worker-preflight-test.sh が同じ fixture の形で確かめる。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-codex-model-selection.rb"
pf_src="$repo_root/shared/scripts/personal-codex-worker-preflight.rb"
[ -f "$src" ] || fail "missing $src"
[ -f "$pf_src" ] || fail "missing $pf_src"

tmp=$(mktemp -d)
# chmod 000 にした fixture が残っても消せるように、権限を戻してから消す。
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

deploy="$tmp/deploy"
mkdir -p "$deploy"
cp "$src" "$deploy/personal-codex-model-selection"
cp "$pf_src" "$deploy/personal-codex-worker-preflight"
chmod +x "$deploy/personal-codex-model-selection" "$deploy/personal-codex-worker-preflight"
sel="$deploy/personal-codex-model-selection"

# ---- Ruby unit checks: 定義を固定値で pin する ---------------------------------
ruby -r"$script_dir/lib/check_helper" - "$src" "$pf_src" <<'RUBY'
load ARGV[1]
load ARGV[0]
S = CodexModelSelection

check("profile の列挙は公開契約の 2 つだけ",
      S::PROFILES == { "review" => "agent-tools-review", "worker" => "agent-tools-worker" })
check("worker の profile 名は preflight の定義と同じ", S::PROFILES["worker"] == CodexWorkerPreflight::WORKER_PROFILE)
check("出力の形の列挙", S::FORMATS == %w[json model])
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- CLI integration ------------------------------------------------------------
# run_sel <codex home> <args...>: stdout / stderr を分けて取り、rc / out / err に入れる。
run_sel() {
  rs_home=$1
  shift
  set +e
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID CODEX_HOME="$rs_home" "$sel" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  out=$(cat "$tmp/out")
  err=$(cat "$tmp/err")
}

# json の出力を Hash として比べる (key の順序に依存しない)。
expect_json() {
  [ "$rc" -eq 0 ] || fail "$1 should exit 0 (rc=$rc): $err"
  printf '%s' "$out" | ruby -rjson -e 'exit(JSON.parse(STDIN.read) == JSON.parse(ARGV[0]) ? 0 : 1)' "$2" ||
    fail "$1: got $out"
}

# exit 2 で、理由文に $2 を含み、stdout は空、usage に落ちていない (usage を期待する case は別に見る)。
expect_error() {
  [ "$rc" -eq 2 ] || fail "$1 should exit 2 (rc=$rc): out=$out err=$err"
  case "$err" in *"$2"*) : ;; *) fail "$1 should say '$2': $err" ;; esac
  [ -z "$out" ] || fail "$1 must not print a selection on stdout: $out"
  case "$err" in *"usage:"*) fail "$1 must fail on its own check, not usage: $err" ;; esac
  case "$err" in *CANARY*) fail "$1 must not echo file content: $err" ;; esac
  case "$err" in *"$tmp"*) fail "$1 must not echo the path: $err" ;; esac
}

home="$tmp/codex-home"
mkdir -p "$home"
cat > "$home/config.toml" <<'EOF'
model = "gpt-x"
model_reasoning_effort = "xhigh"
approval_policy = "CANARY-POLICY"
[profiles.other]
model = "CANARY-PROFILE-model"
EOF
review="$home/agent-tools-review.config.toml"
worker="$home/agent-tools-worker.config.toml"

# 正常系: config.toml だけ
run_sel "$home" --profile review --format json
expect_json "config only (json)" '{"selection":{"model":"gpt-x","model_reasoning_effort":"xhigh"},"sources":{"model":"user config","model_reasoning_effort":"user config"}}'
run_sel "$home" --profile review --format model
[ "$rc" -eq 0 ] && [ "$out" = "gpt-x" ] || fail "config only (model) should print the model (rc=$rc): $out $err"

# profile 優先 (key ごと): review profile に effort だけ → model は config、effort は profile。他の key は出さない
cat > "$review" <<'EOF'
model_reasoning_effort = "medium"
approval_policy = "CANARY-REVIEW-POLICY"
[mcp_servers.CANARY]
command = "/opt/CANARY/bin"
EOF
run_sel "$home" --profile review --format json
expect_json "review profile effort" '{"selection":{"model":"gpt-x","model_reasoning_effort":"medium"},"sources":{"model":"user config","model_reasoning_effort":"review profile"}}'
case "$out" in *CANARY*) fail "output must not echo other profile values: $out" ;; esac
# profile に model の行が無ければ base の model のまま (BUDGET の読み方)
run_sel "$home" --profile review --format model
[ "$rc" -eq 0 ] && [ "$out" = "gpt-x" ] || fail "profile without a model line should keep the base model (rc=$rc): $out $err"
# profile が model を持てば profile が勝つ
printf 'model = "gpt-review"\n' > "$review"
run_sel "$home" --profile review --format json
expect_json "review profile model" '{"selection":{"model":"gpt-review","model_reasoning_effort":"xhigh"},"sources":{"model":"review profile","model_reasoning_effort":"user config"}}'
run_sel "$home" --profile review --format model
[ "$rc" -eq 0 ] && [ "$out" = "gpt-review" ] || fail "review profile model should win (rc=$rc): $out $err"

# --profile worker は worker の file だけを読む (review の file は読まない)
printf 'model = "gpt-worker"\n' > "$worker"
run_sel "$home" --profile worker --format json
expect_json "worker profile" '{"selection":{"model":"gpt-worker","model_reasoning_effort":"xhigh"},"sources":{"model":"worker profile","model_reasoning_effort":"user config"}}'
rm "$worker"
run_sel "$home" --profile worker --format model
[ "$rc" -eq 0 ] && [ "$out" = "gpt-x" ] || fail "worker must not read the review profile (rc=$rc): $out $err"

# dotfiles が置く symlink の config.toml (指す先は regular file) は読む
linked="$tmp/linked-home"
mkdir -p "$linked"
printf 'model = "gpt-linked"\n' > "$tmp/real-config.toml"
ln -s "$tmp/real-config.toml" "$linked/config.toml"
run_sel "$linked" --profile review --format model
[ "$rc" -eq 0 ] && [ "$out" = "gpt-linked" ] || fail "symlinked regular config should be read (rc=$rc): $out $err"

# 無し: file が無い / Codex home 自体が無い → 空の選択 (Codex の既定に委ねる)。model は空行 1 つ
empty="$tmp/empty-home"
mkdir -p "$empty"
for h in "$empty" "$tmp/no-such-home"; do
  run_sel "$h" --profile review --format json
  expect_json "no files ($h)" '{"selection":{},"sources":{}}'
  run_sel "$h" --profile review --format model
  [ "$rc" -eq 0 ] || fail "no files (model) should exit 0 (rc=$rc): $err"
  [ "$(wc -c < "$tmp/out" | tr -d ' ')" = 1 ] || fail "no model should print exactly one empty line: $(od -c "$tmp/out")"
done

# CODEX_HOME が空なら HOME の下の .codex
defhome="$tmp/default-home"
mkdir -p "$defhome/.codex"
printf 'model = "gpt-default"\n' > "$defhome/.codex/config.toml"
set +e
out=$(env -u CODEX_SANDBOX -u CODEX_THREAD_ID CODEX_HOME="" HOME="$defhome" "$sel" --profile review --format model 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$out" = "gpt-default" ] || fail "empty CODEX_HOME should fall back to HOME/.codex (rc=$rc): $out"

# 解釈できない行 (複数行文字列の中身を key として拾わない) → exit 2、file の label を出し中身は出さない
bad="$tmp/bad-home"
mkdir -p "$bad"
printf 'developer_instructions = """\nmodel = "CANARY"\n"""\n' > "$bad/config.toml"
run_sel "$bad" --profile review --format model
expect_error "unparsable config" "user config の top-level に解釈できない行があります"
rm "$bad/config.toml"
printf 'developer_instructions = """\nmodel = "CANARY"\n"""\n' > "$bad/agent-tools-review.config.toml"
run_sel "$bad" --profile review --format json
expect_error "unparsable review profile" "agent-tools-review.config.toml の top-level に解釈できない行があります"

# 値が形に合わない / 一意に読めない → exit 2 (値そのものは出さない)
printf 'model = "CANARY bad"\n' > "$bad/agent-tools-review.config.toml"
run_sel "$bad" --profile review --format json
expect_error "unsafe value" "agent-tools-review.config.toml の model の値に argv へ安全に埋められない文字があります"
printf 'model = "a"\nmodel = "b"\n' > "$bad/agent-tools-review.config.toml"
run_sel "$bad" --profile review --format json
expect_error "duplicate key" "agent-tools-review.config.toml の model が top-level に複数あり一意に読めません"
rm "$bad/agent-tools-review.config.toml"

# 在るが regular file でない → 無いことにせず exit 2 (config / profile それぞれ)
mkdir "$bad/config.toml"
run_sel "$bad" --profile review --format json
expect_error "config is a directory" "user config が regular file ではありません"
rmdir "$bad/config.toml"
mkdir "$bad/agent-tools-review.config.toml"
run_sel "$bad" --profile review --format model
expect_error "review profile is a directory" "agent-tools-review.config.toml が regular file ではありません"
rmdir "$bad/agent-tools-review.config.toml"

# 権限で確かめられない・読めない → exit 2 (root は権限を無視するので飛ばす)
if [ "$(id -u)" -ne 0 ]; then
  locked="$tmp/locked-home"
  mkdir -p "$locked"
  printf 'model = "gpt-x"\n' > "$locked/config.toml"
  chmod 000 "$locked/config.toml"
  run_sel "$locked" --profile review --format model
  expect_error "unreadable config" "user config を確かめられないか読めません (Errno::EACCES)"
  chmod 644 "$locked/config.toml"
  # 親 dir を読めない (search 権限なし) → stat が失敗する。無い file と同じ扱いにしない
  chmod 000 "$locked"
  run_sel "$locked" --profile review --format model
  expect_error "unsearchable codex home" "user config を確かめられないか読めません (Errno::EACCES)"
  chmod 755 "$locked"
fi

# usage: 列挙外の profile (path や shell 片を含む) / 列挙外の形 / 不足 / 重複 / 余分な引数 → exit 2 と usage
for args in "" "--profile review" "--format json" "--profile other --format json" \
  "--profile ../agent-tools-review --format json" "--profile review;id --format json" \
  "--profile review --format yaml" "--profile review --profile worker --format json" \
  "--profile review --format json extra" "--profile" "--bogus x"; do
  # 引数の分割は意図どおり (値に空白を含めない fixture)
  # shellcheck disable=SC2086
  run_sel "$home" $args
  [ "$rc" -eq 2 ] || fail "usage error should exit 2 for '$args' (rc=$rc): $out"
  case "$err" in *"usage: personal-codex-model-selection"*) : ;; *) fail "should print usage for '$args': $err" ;; esac
  [ -z "$out" ] || fail "usage error must not print on stdout for '$args': $out"
done

# preflight が同じ directory に配備されていない → exit 2 (path は出さない)
lone="$tmp/lone"
mkdir -p "$lone"
cp "$src" "$lone/personal-codex-model-selection"
chmod +x "$lone/personal-codex-model-selection"
set +e
env -u CODEX_SANDBOX -u CODEX_THREAD_ID CODEX_HOME="$home" "$lone/personal-codex-model-selection" \
  --profile review --format json >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
out=$(cat "$tmp/out")
err=$(cat "$tmp/err")
expect_error "missing preflight" "personal-codex-worker-preflight を load できません"

echo "codex-model-selection-test: ok"
