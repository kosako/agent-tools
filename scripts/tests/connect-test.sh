#!/bin/sh
# connect.sh の self-test。
# 一時 directory に fixture と fake tool homes を生成して検証する。
# 実際の ~/.codex / ~/.claude には一切触れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$script_dir/../build.sh"
register="$script_dir/../register.sh"
connect="$script_dir/../connect.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_connect() {
  "$connect" --root "$tmp/repo" --codex-home "$tmp/codex" --claude-home "$tmp/claude" "$@"
}

# --- fixture: instruction asset ---
mkdir -p "$tmp/repo/shared/instructions" "$tmp/codex" "$tmp/claude"
cat > "$tmp/repo/shared/instructions/personal-ops.md" <<'EOF'
# operating rules

ドキュメントは日本語を既定にする。
EOF
cat > "$tmp/repo/shared/instructions/personal-ops.asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-ops.md
  format: markdown
EOF

# --- case 0: build 前は connect する artifact が無い ---
run_connect > "$tmp/c0" 2>&1 || fail "connect without artifacts should succeed: $(cat "$tmp/c0")"
grep -q "no instruction artifacts to connect" "$tmp/c0" || fail "missing no-artifacts notice: $(cat "$tmp/c0")"

"$build" --root "$tmp/repo" --quiet > /dev/null
# connect は catalog の registration を gate にするため register まで通す
# (low risk fixture は registered になり exit 0)。
"$register" --root "$tmp/repo" --quiet > /dev/null

# --- case 1: dry-run は plan を出すが書き込まない ---
run_connect > "$tmp/c1" 2>&1 || fail "dry-run should succeed: $(cat "$tmp/c1")"
grep -q "create: \[claude-code\] owned" "$tmp/c1" || fail "missing claude owned create: $(cat "$tmp/c1")"
grep -q "add-import: \[claude-code\] import" "$tmp/c1" || fail "missing claude import plan: $(cat "$tmp/c1")"
grep -q "create: \[codex\] owned" "$tmp/c1" || fail "missing codex owned create: $(cat "$tmp/c1")"
grep -q "dry-run only" "$tmp/c1" || fail "missing dry-run notice"
[ ! -e "$tmp/claude/agent-tools/CLAUDE.md" ] || fail "dry-run must not write owned file"
[ ! -e "$tmp/claude/CLAUDE.md" ] || fail "dry-run must not write import file"
[ ! -e "$tmp/codex/AGENTS.md" ] || fail "dry-run must not write codex owned file"

# --- case 2: --apply で所有ファイルと import が作られる ---
run_connect --apply > "$tmp/c2" 2>&1 || fail "apply should succeed: $(cat "$tmp/c2")"
[ -f "$tmp/claude/agent-tools/CLAUDE.md" ] || fail "owned CLAUDE.md not created"
head -1 "$tmp/claude/agent-tools/CLAUDE.md" | grep -q "agent-tools:managed" || fail "owned file missing marker"
grep -q "ドキュメントは日本語" "$tmp/claude/agent-tools/CLAUDE.md" || fail "owned file missing body"
grep -q '^@agent-tools/CLAUDE.md$' "$tmp/claude/CLAUDE.md" || fail "import line not added"
[ -f "$tmp/codex/AGENTS.md" ] || fail "codex AGENTS.md not created (empty file should be claimable)"
head -1 "$tmp/codex/AGENTS.md" | grep -q "target=codex" || fail "codex owned missing marker"

# --- case 3: 冪等 (再 apply は skip、0 changes) ---
run_connect --apply > "$tmp/c3" 2>&1 || fail "second apply should succeed: $(cat "$tmp/c3")"
grep -q "skip: \[claude-code\] owned.*already connected" "$tmp/c3" || fail "owned should skip when connected: $(cat "$tmp/c3")"
grep -q "skip: \[claude-code\] import.*already present" "$tmp/c3" || fail "import should skip when present"
grep -q "skip: \[codex\] owned.*already connected" "$tmp/c3" || fail "codex owned should skip"
grep -q "0 change(s)" "$tmp/c3" || fail "idempotent run should have 0 changes"

# --- case 4: 人間が書いた CLAUDE.md の内容を保持して import を足す ---
mkdir -p "$tmp/codex2" "$tmp/claude2"
printf '# my notes\nhello\n' > "$tmp/claude2/CLAUDE.md"
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex2" --claude-home "$tmp/claude2" --apply > /dev/null 2>&1
grep -q "hello" "$tmp/claude2/CLAUDE.md" || fail "existing CLAUDE.md content must be preserved"
grep -q '^@agent-tools/CLAUDE.md$' "$tmp/claude2/CLAUDE.md" || fail "import appended to existing CLAUDE.md"

# --- case 5: codex AGENTS.md に unmanaged な中身があると conflict (書き込まない) ---
mkdir -p "$tmp/codex3" "$tmp/claude3"
echo "my codex notes" > "$tmp/codex3/AGENTS.md"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex3" --claude-home "$tmp/claude3" --apply > "$tmp/c5" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "unmanaged codex AGENTS.md should conflict (exit 1): $(cat "$tmp/c5")"
grep -q "conflict: \[codex\] owned.*unmanaged" "$tmp/c5" || fail "missing codex conflict: $(cat "$tmp/c5")"
grep -q "my codex notes" "$tmp/codex3/AGENTS.md" || fail "unmanaged codex file must not be overwritten"
grep -q "nothing was applied" "$tmp/c5" || fail "conflict should stop all writes"
[ ! -e "$tmp/claude3/agent-tools/CLAUDE.md" ] || fail "conflict must stop claude writes too"

# --- case 6: claude CLAUDE.md が symlink なら conflict (置き換えない) ---
mkdir -p "$tmp/codex4" "$tmp/claude4"
echo "real" > "$tmp/realclaude.md"
ln -s "$tmp/realclaude.md" "$tmp/claude4/CLAUDE.md"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex4" --claude-home "$tmp/claude4" --apply > "$tmp/c6" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlink CLAUDE.md should conflict: $(cat "$tmp/c6")"
grep -q "conflict: \[claude-code\] import.*symlink" "$tmp/c6" || fail "missing symlink conflict: $(cat "$tmp/c6")"
[ -L "$tmp/claude4/CLAUDE.md" ] || fail "symlink must not be replaced"

# --- case 7: CLAUDE.md がディレクトリなら conflict (部分適用しない) ---
mkdir -p "$tmp/codex5" "$tmp/claude5/CLAUDE.md"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex5" --claude-home "$tmp/claude5" --apply > "$tmp/c7" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "directory CLAUDE.md should conflict: $(cat "$tmp/c7")"
grep -q "conflict: \[claude-code\] import.*not a regular file" "$tmp/c7" || fail "missing non-regular conflict: $(cat "$tmp/c7")"
[ ! -e "$tmp/claude5/agent-tools/CLAUDE.md" ] || fail "conflict must prevent owned write"

# --- case 8: 余分キーを持つ marker は managed と認識しない (厳密 parse) ---
mkdir -p "$tmp/codex6" "$tmp/claude6"
printf '<!-- agent-tools:managed v=1 repo=agent-tools name=x target=codex artifact_kind=instruction source=shared/x.md build_id=sha256:abc evil=1 -->\nbody\n' > "$tmp/codex6/AGENTS.md"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex6" --claude-home "$tmp/claude6" --apply > "$tmp/c8" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "marker with extra key should not be managed: $(cat "$tmp/c8")"
grep -q "conflict: \[codex\] owned.*unmanaged" "$tmp/c8" || fail "extra-key marker should be treated as unmanaged: $(cat "$tmp/c8")"

# --- case 9: CRLF の CLAUDE.md に import を足しても改行スタイルを保つ ---
mkdir -p "$tmp/codex7" "$tmp/claude7"
printf '# notes\r\nhello\r\n' > "$tmp/claude7/CLAUDE.md"
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex7" --claude-home "$tmp/claude7" --apply > /dev/null 2>&1
ruby -e 'c=File.binread(ARGV[0]); abort "CRLF not preserved" unless c.include?("@agent-tools/CLAUDE.md\r\n")' \
  "$tmp/claude7/CLAUDE.md" || fail "import line should keep CRLF newline style"

# --- case 10: 所有先の親 dir が symlink なら conflict (意図外書き込みを防ぐ) ---
mkdir -p "$tmp/codex8" "$tmp/claude8" "$tmp/realdir"
ln -s "$tmp/realdir" "$tmp/claude8/agent-tools"
status=0
"$connect" --root "$tmp/repo" --codex-home "$tmp/codex8" --claude-home "$tmp/claude8" --apply > "$tmp/c10" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked owned parent should conflict: $(cat "$tmp/c10")"
grep -q "conflict: \[claude-code\] owned.*symlink" "$tmp/c10" || fail "missing parent symlink conflict: $(cat "$tmp/c10")"
[ ! -e "$tmp/realdir/CLAUDE.md" ] || fail "must not write through a symlinked parent"

# --- case 11: 未登録 (human_review_required) の instruction は connect しない (review gate) ---
mkdir -p "$tmp/repo2/shared/instructions" "$tmp/codex9" "$tmp/claude9"
cat > "$tmp/repo2/shared/instructions/personal-pending.md" <<'EOF'
# pending rules

レビュー待ちの instruction。
EOF
cat > "$tmp/repo2/shared/instructions/personal-pending.asset.yml" <<'EOF'
schema_version: 1
name: personal-pending
kind: instruction
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: medium
  privacy: low
source:
  path: shared/instructions/personal-pending.md
  format: markdown
EOF
"$build" --root "$tmp/repo2" --quiet > /dev/null
# 宣言 medium + 未承認 → register は human_review_required (exit 3, 非致命) になる
status=0
"$register" --root "$tmp/repo2" --quiet > /dev/null || status=$?
[ "$status" -eq 3 ] || fail "pending instruction should register as human_review_required (exit 3), got $status"
"$connect" --root "$tmp/repo2" --codex-home "$tmp/codex9" --claude-home "$tmp/claude9" --apply > "$tmp/c11" 2>&1 \
  || fail "connect should not error on unregistered instruction: $(cat "$tmp/c11")"
grep -q "skip: \[claude-code\] owned.*not registered" "$tmp/c11" || fail "claude owned should skip when not registered: $(cat "$tmp/c11")"
grep -q "skip: \[codex\] owned.*not registered" "$tmp/c11" || fail "codex owned should skip when not registered: $(cat "$tmp/c11")"
grep -q "0 change(s)" "$tmp/c11" || fail "unregistered instruction connect should apply 0 changes: $(cat "$tmp/c11")"
[ ! -e "$tmp/claude9/agent-tools/CLAUDE.md" ] || fail "unregistered instruction must not create owned claude file"
[ ! -e "$tmp/claude9/CLAUDE.md" ] || fail "unregistered instruction must not add import"
[ ! -e "$tmp/codex9/AGENTS.md" ] || fail "unregistered instruction must not create owned codex file"

# --- case 12: registered な catalog のまま source を変えて build だけ再実行したら connect は skip ---
# (古い registered catalog で未レビュー content を配置しないこと = build_id 照合の回帰)
mkdir -p "$tmp/repo3/shared/instructions" "$tmp/codex10" "$tmp/claude10"
cat > "$tmp/repo3/shared/instructions/personal-ops.md" <<'EOF'
# operating rules

ドキュメントは日本語を既定にする。
EOF
cat > "$tmp/repo3/shared/instructions/personal-ops.asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-ops.md
  format: markdown
EOF
"$build" --root "$tmp/repo3" --quiet > /dev/null
"$register" --root "$tmp/repo3" --quiet > /dev/null
# source を変更 (build_id が変わる) して build だけ再実行 (register しない → catalog は古い registered)
printf '\n追記: catalog 未更新の変更。\n' >> "$tmp/repo3/shared/instructions/personal-ops.md"
"$build" --root "$tmp/repo3" --quiet > /dev/null
"$connect" --root "$tmp/repo3" --codex-home "$tmp/codex10" --claude-home "$tmp/claude10" --apply > "$tmp/c12" 2>&1 \
  || fail "connect should not error on stale build: $(cat "$tmp/c12")"
grep -q "skip: \[claude-code\] owned.*stale" "$tmp/c12" || fail "claude owned should skip when generated build_id != catalog: $(cat "$tmp/c12")"
grep -q "skip: \[codex\] owned.*stale" "$tmp/c12" || fail "codex owned should skip when generated build_id != catalog: $(cat "$tmp/c12")"
grep -q "0 change(s)" "$tmp/c12" || fail "stale connect should apply 0 changes: $(cat "$tmp/c12")"
[ ! -e "$tmp/claude10/agent-tools/CLAUDE.md" ] || fail "stale generated instruction must not create owned file"
[ ! -e "$tmp/claude10/CLAUDE.md" ] || fail "stale generated instruction must not add import"
[ ! -e "$tmp/codex10/AGENTS.md" ] || fail "stale generated instruction must not create owned codex file"

# --- case 13: register 後に manifest だけ変えたら connect は gate で止まる (#148) ---
# (source は不変で build_id 一致でも、登録判断 (risk/review) が古い catalog は配置しない。
#  connect は初回配置を担うので、ここを塞がないと sync の manifest gate を迂回できる)
mkdir -p "$tmp/repo4/shared/instructions" "$tmp/codex11" "$tmp/claude11"
cat > "$tmp/repo4/shared/instructions/personal-ops.md" <<'EOF'
# operating rules

ドキュメントは日本語を既定にする。
EOF
cat > "$tmp/repo4/shared/instructions/personal-ops.asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-ops.md
  format: markdown
EOF
"$build" --root "$tmp/repo4" --quiet > /dev/null
"$register" --root "$tmp/repo4" --quiet > /dev/null
# source は変えず manifest だけ変更 (build_id 不変・manifest_digest 変化)。register しない。
printf '\n# reviewed comment (catalog 未更新)\n' >> "$tmp/repo4/shared/instructions/personal-ops.asset.yml"
"$connect" --root "$tmp/repo4" --codex-home "$tmp/codex11" --claude-home "$tmp/claude11" --apply > "$tmp/c13" 2>&1 \
  || fail "connect should not error on manifest-stale catalog: $(cat "$tmp/c13")"
grep -q "skip: \[claude-code\] owned.*manifest changed" "$tmp/c13" \
  || fail "claude owned should skip when manifest changed since register: $(cat "$tmp/c13")"
grep -q "skip: \[codex\] owned.*manifest changed" "$tmp/c13" \
  || fail "codex owned should skip when manifest changed since register: $(cat "$tmp/c13")"
[ ! -e "$tmp/claude11/agent-tools/CLAUDE.md" ] || fail "manifest-stale instruction must not create owned file"
[ ! -e "$tmp/codex11/AGENTS.md" ] || fail "manifest-stale instruction must not create owned codex file"

# --- case 14: 非 UTF-8 バイトで crash しない (#149) ---
mkdir -p "$tmp/repo5/shared/instructions"
cat > "$tmp/repo5/shared/instructions/personal-ops.md" <<'EOF'
# operating rules
EOF
cat > "$tmp/repo5/shared/instructions/personal-ops.asset.yml" <<'EOF'
schema_version: 1
name: personal-ops
kind: instruction
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/instructions/personal-ops.md
  format: markdown
EOF
"$build" --root "$tmp/repo5" --quiet > /dev/null
"$register" --root "$tmp/repo5" --quiet > /dev/null

# 14a: unmanaged な非 UTF-8 所有先は conflict (String#strip の ArgumentError で落ちない)
mkdir -p "$tmp/codex14a" "$tmp/claude14a"
printf 'existing \377\376 content\n' > "$tmp/codex14a/AGENTS.md"
status=0
"$connect" --root "$tmp/repo5" --codex-home "$tmp/codex14a" --claude-home "$tmp/claude14a" > "$tmp/c14a" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "connect with non-UTF-8 owned file should conflict (exit 1), not crash: $(cat "$tmp/c14a")"
grep -q "conflict: \[codex\] owned.*unmanaged" "$tmp/c14a" \
  || fail "non-UTF-8 owned AGENTS.md should be an unmanaged conflict: $(cat "$tmp/c14a")"

# 14b: 人間の CLAUDE.md の非 UTF-8 バイトは import 判定を crash させず、追記でバイト列を保全する
mkdir -p "$tmp/codex14b" "$tmp/claude14b"
printf '# human notes \377\376\n' > "$tmp/claude14b/CLAUDE.md"
cp "$tmp/claude14b/CLAUDE.md" "$tmp/c14b-orig"
orig_size=$(wc -c < "$tmp/c14b-orig")
"$connect" --root "$tmp/repo5" --codex-home "$tmp/codex14b" --claude-home "$tmp/claude14b" --apply > "$tmp/c14b" 2>&1 \
  || fail "connect with non-UTF-8 CLAUDE.md should succeed: $(cat "$tmp/c14b")"
grep -q "add-import: \[claude-code\]" "$tmp/c14b" || fail "expected add-import plan: $(cat "$tmp/c14b")"
grep -q "@agent-tools/CLAUDE.md" "$tmp/claude14b/CLAUDE.md" || fail "import line should be appended"
head -c "$orig_size" "$tmp/claude14b/CLAUDE.md" | cmp -s - "$tmp/c14b-orig" \
  || fail "existing CLAUDE.md bytes must be preserved on append"

# --- case 15: 所有先 AGENTS.md 自体が symlink なら conflict (実体へ書き抜けない) (#150) ---
mkdir -p "$tmp/codex15" "$tmp/claude15"
echo "# real file elsewhere" > "$tmp/real-agents.md"
ln -s "$tmp/real-agents.md" "$tmp/codex15/AGENTS.md"
status=0
"$connect" --root "$tmp/repo5" --codex-home "$tmp/codex15" --claude-home "$tmp/claude15" --apply > "$tmp/c15" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "symlinked owned AGENTS.md should conflict (exit 1): $(cat "$tmp/c15")"
grep -q "conflict: \[codex\] owned.*symlink" "$tmp/c15" \
  || fail "missing owned-symlink conflict: $(cat "$tmp/c15")"
grep -q "# real file elsewhere" "$tmp/real-agents.md" \
  || fail "must not write through a symlinked owned file"

echo "ok: connect self-test passed"
