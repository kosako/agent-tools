#!/bin/sh
# 8 entrypoint の CLI 引数処理の characterization test (#192)。
# Cli helper への共通化 (scripts/lib/cli.rb) が守るべき現行挙動を先に固定する:
#   1. 未知 option: stderr に "unknown option: <arg>" + usage を stdout + exit 2
#   2. value flag の値欠落 (argv 枯渇): unknown 行なしで usage を stdout + exit 2
#   3. -h / --help: usage を stdout + exit 0
#   4. --help の後の token は読まない (--help --bogus でも exit 0)
# いずれも repo 状態に依存しない parse 段の挙動なので、cwd は空 tmp で走らせる。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# value flag を持つ全 entrypoint (--root は共通の value flag)。
COMMANDS="sync connect status doctor build register check-manifests check-injection"

for cmd in $COMMANDS; do
  bin="$script_dir/../$cmd.sh"

  # --- 1: 未知 option → stderr に unknown option + stdout に usage + exit 2 ---
  status=0
  (cd "$tmp" && "$bin" --bogus-flag > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 2 ] || fail "$cmd: unknown option should exit 2, got $status"
  grep -q "unknown option: --bogus-flag" "$tmp/err" \
    || fail "$cmd: missing unknown-option line on stderr: $(cat "$tmp/err")"
  grep -q "^usage:" "$tmp/out" || fail "$cmd: usage should go to stdout: $(cat "$tmp/out")"

  # --- 2: value flag の値欠落 → unknown 行なしで usage + exit 2 ---
  status=0
  (cd "$tmp" && "$bin" --root > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 2 ] || fail "$cmd: missing value should exit 2, got $status"
  grep -q "^usage:" "$tmp/out" || fail "$cmd: missing-value usage should go to stdout"
  if grep -q "unknown option" "$tmp/err"; then
    fail "$cmd: missing value must not report unknown option: $(cat "$tmp/err")"
  fi

  # --- 3: -h / --help → usage + exit 0 ---
  for flag in -h --help; do
    status=0
    (cd "$tmp" && "$bin" "$flag" > "$tmp/out" 2> "$tmp/err") || status=$?
    [ "$status" -eq 0 ] || fail "$cmd: $flag should exit 0, got $status"
    grep -q "^usage:" "$tmp/out" || fail "$cmd: $flag should print usage to stdout"
  done

  # --- 4: --help は以降の token を読まない ---
  status=0
  (cd "$tmp" && "$bin" --help --bogus-flag > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 0 ] || fail "$cmd: --help must short-circuit before --bogus-flag, got $status"

  # --- 5: help 時は stderr 空・stdout は usage 1 行のみ ---
  status=0
  (cd "$tmp" && "$bin" --help > "$tmp/out" 2> "$tmp/err") || status=$?
  [ ! -s "$tmp/err" ] || fail "$cmd: --help must not write to stderr: $(cat "$tmp/err")"
  [ "$(wc -l < "$tmp/out" | tr -d ' ')" = "1" ] || fail "$cmd: --help stdout should be the usage line only"
  case "$(cat "$tmp/out")" in "usage: $cmd.sh "*) ;; *) fail "$cmd: usage line should name $cmd.sh: $(cat "$tmp/out")";; esac

  # --- 6: 位置引数は未知 option として拒否 ---
  status=0
  (cd "$tmp" && "$bin" positional > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 2 ] || fail "$cmd: positional arg should exit 2, got $status"
  grep -q "unknown option: positional" "$tmp/err" || fail "$cmd: positional arg should be reported as unknown option"

  # --- 7: 引数途中の -h でも usage + exit 0 (value flag を先に読んでから) ---
  status=0
  (cd "$tmp" && "$bin" --root "$tmp" -h > "$tmp/out" 2> "$tmp/err") || status=$?
  [ "$status" -eq 0 ] || fail "$cmd: mid-args -h should exit 0, got $status"
  grep -q "^usage:" "$tmp/out" || fail "$cmd: mid-args -h should print usage"
done

# --- Cli.parse の直接 unit (外形から観測しにくい equivalence): 空文字列値 / 重複後勝ち /
#     value flag が直後の flag を値として食う / help は以降の argv を消費しない ---
ruby -r"$script_dir/../lib/cli" -e '
  def check(name, cond)
    return if cond
    warn "FAIL: #{name}"
    exit 1
  end
  # 空文字列は有効な値 (値欠落は argv 枯渇 = nil のみ)
  opts = Cli.parse(["--root", ""], usage: "usage: x", value_flags: ["--root"])
  check("empty string value accepted", opts["--root"] == "")
  # 同一 flag 重複は後勝ち
  opts = Cli.parse(["--root", "a", "--root", "b"], usage: "usage: x", value_flags: ["--root"])
  check("duplicate value flag: last wins", opts["--root"] == "b")
  # value flag は直後の token を無条件に値として食う (旧 loop と同じ)
  opts = Cli.parse(["--root", "--quiet"], usage: "usage: x",
                   bool_flags: ["--quiet"], value_flags: ["--root"])
  check("value flag eats following flag token", opts["--root"] == "--quiet" && !opts.key?("--quiet"))
  # help は :help を返し以降の argv を消費しない
  argv = ["--help", "--rest"]
  check("help returns :help", Cli.parse(argv, usage: "usage: x") == :help)
  check("help leaves rest of argv", argv == ["--rest"])
' > /dev/null || fail "Cli.parse direct unit checks failed"

echo "ok: cli-args characterization test passed"
