#!/bin/sh
# scripts/lib/check_evals.rb (evals/evals.json の形式検査, #216) の self-test。
# 一時 directory に fixture を生成して検査の契約を固定し、最後に実 repo の全 evals.json を検査する。
# 実モデルは呼ばない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
check="$script_dir/../lib/check_evals.rb"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 検査を走らせ、exit code を確かめる。stdout は $tmp/out、stderr は $tmp/err に残る。
# 使い方: run_check <label> <want-exit> <check の引数>...
run_check() {
  rc_label=$1
  rc_want=$2
  shift 2
  rc_status=0
  ruby "$check" "$@" > "$tmp/out" 2> "$tmp/err" || rc_status=$?
  [ "$rc_status" -eq "$rc_want" ] \
    || fail "$rc_label: expected exit $rc_want, got $rc_status: $(cat "$tmp/out" "$tmp/err")"
}

# stdout にその文字列とちょうど一致する行があること。
# 使い方: expect_line <label> <line>
expect_line() {
  grep -qxF -- "$2" "$tmp/out" || fail "$1: missing line '$2' in: $(cat "$tmp/out")"
}

# error の数 (stdout の行数と stderr の集計行) が期待どおりであること。余計な error が出ていないことも見る。
# 使い方: expect_errors <label> <error 数> <evals file 数>
expect_errors() {
  ee_lines=$(wc -l < "$tmp/out" | tr -d ' ')
  [ "$ee_lines" -eq "$2" ] || fail "$1: expected $2 error line(s), got $ee_lines: $(cat "$tmp/out")"
  grep -qxF "$2 error(s) in $3 evals file(s)" "$tmp/err" \
    || fail "$1: missing summary '$2 error(s) in $3 evals file(s)' in: $(cat "$tmp/err")"
}

# directory skill (asset.yml + SKILL.md + 空の evals/) を作る。evals.json は呼び出し側が書く。
# manifest の name は第 3 引数で directory 名と変えられる (skill_name の照合の fixture 用)。
# 使い方: make_skill <root> <dir name> [manifest name]
make_skill() {
  ms_dir="$1/shared/skills/$2"
  ms_name=${3:-$2}
  mkdir -p "$ms_dir/evals"
  printf -- '---\nname: %s\ndescription: demo %s\n---\n\n# %s\n' "$ms_name" "$ms_name" "$ms_name" > "$ms_dir/SKILL.md"
  write_asset_manifest "$ms_dir/asset.yml" "$ms_name" skill public "shared/skills/$2" directory claude-code
}

# --- case 1: 正常系。id は連番でなく起点も問わない、assertion の id は case をまたげば重複してよい、
#     name / notes / files は任意。evals.json の無い skill と、evals/ だけあって evals.json の無い
#     skill は error にしない (evals は任意) ---
make_skill "$tmp/valid" personal-good
mkdir -p "$tmp/valid/shared/skills/personal-good/evals/fixtures"
printf 'input\n' > "$tmp/valid/shared/skills/personal-good/evals/fixtures/input.md"
cat > "$tmp/valid/shared/skills/personal-good/evals/evals.json" <<'EOF'
{
  "skill_name": "personal-good",
  "notes": "fixture",
  "evals": [
    {
      "id": 5,
      "name": "first",
      "prompt": "do x",
      "expected_output": "x is done",
      "files": ["evals/fixtures/input.md"],
      "assertions": [
        { "id": "does-x", "text": "x is done" },
        { "id": "no-y", "text": "y is not done" }
      ]
    },
    {
      "id": 0,
      "prompt": "do z",
      "expected_output": "z is done",
      "assertions": [ { "id": "does-x", "text": "the same assertion id in another case is fine" } ]
    },
    {
      "id": 12,
      "name": "",
      "prompt": "p",
      "expected_output": "e",
      "files": [],
      "assertions": [ { "id": "a1", "text": "t" } ]
    }
  ]
}
EOF
make_skill "$tmp/valid" personal-no-evals
rmdir "$tmp/valid/shared/skills/personal-no-evals/evals"
make_skill "$tmp/valid" personal-empty-evals-dir
run_check "valid" 0 --root "$tmp/valid"
expect_line "valid" "ok: 1 evals file(s), 3 case(s) validated"
[ ! -s "$tmp/err" ] || fail "valid: stderr must be empty: $(cat "$tmp/err")"

# --quiet は成功時に何も出さない。
run_check "valid-quiet" 0 --root "$tmp/valid" --quiet
[ ! -s "$tmp/out" ] || fail "valid-quiet: stdout must be empty: $(cat "$tmp/out")"

# --- case 2: 壊れた JSON / top-level が object でない / UTF-8 でない ---
make_skill "$tmp/malformed" personal-broken
printf '{"skill_name": "personal-broken", "evals": [' > "$tmp/malformed/shared/skills/personal-broken/evals/evals.json"
make_skill "$tmp/malformed" personal-array
printf '[]\n' > "$tmp/malformed/shared/skills/personal-array/evals/evals.json"
make_skill "$tmp/malformed" personal-latin1
printf '{"skill_name": "personal-latin1", "notes": "\377"}\n' > "$tmp/malformed/shared/skills/personal-latin1/evals/evals.json"
run_check "malformed" 1 --root "$tmp/malformed"
grep -qF "shared/skills/personal-broken/evals/evals.json: invalid JSON: " "$tmp/out" \
  || fail "malformed: missing invalid JSON line: $(cat "$tmp/out")"
expect_line "malformed" "shared/skills/personal-array/evals/evals.json: top-level must be a JSON object"
expect_line "malformed" "shared/skills/personal-latin1/evals/evals.json: must be valid UTF-8"
expect_errors "malformed" 3 3

# --- case 3: evals が空・配列でない・欠落、skill_name の欠落・型の誤り ---
make_skill "$tmp/empty" personal-empty
printf '{"skill_name": "personal-empty", "evals": []}\n' > "$tmp/empty/shared/skills/personal-empty/evals/evals.json"
make_skill "$tmp/empty" personal-object
printf '{"skill_name": "personal-object", "evals": {}}\n' > "$tmp/empty/shared/skills/personal-object/evals/evals.json"
make_skill "$tmp/empty" personal-missing
printf '{"notes": "no skill_name and no evals"}\n' > "$tmp/empty/shared/skills/personal-missing/evals/evals.json"
make_skill "$tmp/empty" personal-numeric
printf '{"skill_name": 5, "evals": [{"id": 0, "prompt": "p", "expected_output": "e", "assertions": [{"id": "a", "text": "t"}]}]}\n' \
  > "$tmp/empty/shared/skills/personal-numeric/evals/evals.json"
run_check "empty" 1 --root "$tmp/empty"
expect_line "empty" "shared/skills/personal-empty/evals/evals.json:evals: must be a non-empty array"
expect_line "empty" "shared/skills/personal-object/evals/evals.json:evals: must be a non-empty array"
expect_line "empty" "shared/skills/personal-missing/evals/evals.json:skill_name: missing required field"
expect_line "empty" "shared/skills/personal-missing/evals/evals.json:evals: missing required field"
expect_line "empty" "shared/skills/personal-numeric/evals/evals.json:skill_name: must be a non-empty string"
expect_errors "empty" 5 4

# --- case 4: case id の重複 (file 内で一意) ---
make_skill "$tmp/dup" personal-dup
cat > "$tmp/dup/shared/skills/personal-dup/evals/evals.json" <<'EOF'
{
  "skill_name": "personal-dup",
  "evals": [
    { "id": 3, "prompt": "p", "expected_output": "e", "assertions": [{ "id": "a", "text": "t" }] },
    { "id": 3, "prompt": "p", "expected_output": "e", "assertions": [{ "id": "a", "text": "t" }] },
    { "id": 4, "prompt": "p", "expected_output": "e", "assertions": [{ "id": "a", "text": "t" }] },
    { "id": 3, "prompt": "p", "expected_output": "e", "assertions": [{ "id": "a", "text": "t" }] }
  ]
}
EOF
run_check "dup" 1 --root "$tmp/dup"
expect_line "dup" "shared/skills/personal-dup/evals/evals.json:evals[1](id=3):id: duplicate case id 3 (also at evals[0])"
expect_line "dup" "shared/skills/personal-dup/evals/evals.json:evals[3](id=3):id: duplicate case id 3 (also at evals[0])"
expect_errors "dup" 2 1

# --- case 5: 空の assertions と型の誤り。すべての error を集めてから exit 1 ---
make_skill "$tmp/types" personal-types
cat > "$tmp/types/shared/skills/personal-types/evals/evals.json" <<'EOF'
{
  "skill_name": "personal-types",
  "notes": 7,
  "evals": [
    { "id": -1, "prompt": "p", "expected_output": "e", "assertions": [{ "id": "a", "text": "t" }] },
    { "id": 1.5, "prompt": "", "expected_output": "  ", "name": 3, "assertions": [{ "id": "a", "text": "t" }] },
    { "id": "2", "prompt": 4, "assertions": [
      { "id": "Bad Slug", "text": "" },
      "x",
      { "text": "t" },
      { "id": "dup", "text": "t" },
      { "id": "dup", "text": "t2" }
    ] },
    { "id": true, "prompt": "p", "expected_output": "e", "files": "evals/x", "assertions": {} },
    "not-an-object",
    { "id": 9, "prompt": "p", "expected_output": "e", "assertions": [] },
    { "id": 10, "prompt": "p", "expected_output": "e" }
  ]
}
EOF
run_check "types" 1 --root "$tmp/types"
f=shared/skills/personal-types/evals/evals.json
expect_line "types" "$f:notes: must be a string"
expect_line "types" "$f:evals[0]:id: must be a non-negative integer"
expect_line "types" "$f:evals[1]:id: must be a non-negative integer"
expect_line "types" "$f:evals[1]:prompt: must be a non-empty string"
expect_line "types" "$f:evals[1]:expected_output: must be a non-empty string"
expect_line "types" "$f:evals[1]:name: must be a string"
expect_line "types" "$f:evals[2]:id: must be a non-negative integer"
expect_line "types" "$f:evals[2]:prompt: must be a non-empty string"
expect_line "types" "$f:evals[2]:expected_output: missing required field"
expect_line "types" "$f:evals[2]:assertions[0].id: must be a lower kebab-case slug, got \"Bad Slug\""
expect_line "types" "$f:evals[2]:assertions[0].text: must be a non-empty string"
expect_line "types" "$f:evals[2]:assertions[1]: must be a JSON object"
expect_line "types" "$f:evals[2]:assertions[2].id: missing required field"
expect_line "types" "$f:evals[2]:assertions[4].id: duplicate assertion id \"dup\" in this case (also at assertions[3])"
expect_line "types" "$f:evals[3]:id: must be a non-negative integer"
expect_line "types" "$f:evals[3]:files: must be an array"
expect_line "types" "$f:evals[3]:assertions: must be a non-empty array"
expect_line "types" "$f:evals[4]: must be a JSON object"
expect_line "types" "$f:evals[5](id=9):assertions: must be a non-empty array"
expect_line "types" "$f:evals[6](id=10):assertions: missing required field"
expect_errors "types" 20 1

# --- case 6: files は skill の directory からの相対 path で、外へ出ず、存在し、symlink を含まない
#     regular file。symlink の先 (repo の外) は読まない ---
make_skill "$tmp/files" personal-files
mkdir -p "$tmp/outside" "$tmp/files/shared/skills/personal-files/evals/fixtures"
printf 'outside\n' > "$tmp/outside/secret.md"
printf 'outside\n' > "$tmp/outside/x.md"
printf 'ok\n' > "$tmp/files/shared/skills/personal-files/evals/fixtures/ok.md"
ln -s "$tmp/outside/secret.md" "$tmp/files/shared/skills/personal-files/evals/link.md"
ln -s "$tmp/outside" "$tmp/files/shared/skills/personal-files/evals/linkdir"
cat > "$tmp/files/shared/skills/personal-files/evals/evals.json" <<'EOF'
{
  "skill_name": "personal-files",
  "evals": [
    {
      "id": 0,
      "prompt": "p",
      "expected_output": "e",
      "files": [
        "/etc/hosts",
        "../personal-other/SKILL.md",
        "evals/../SKILL.md",
        "evals//fixtures/ok.md",
        "./SKILL.md",
        "evals/missing.md",
        "evals/link.md",
        "evals/linkdir/x.md",
        "evals",
        "",
        3,
        "evals/fixtures/ok.md",
        "SKILL.md"
      ],
      "assertions": [{ "id": "a", "text": "t" }]
    }
  ]
}
EOF
run_check "files" 1 --root "$tmp/files"
f="shared/skills/personal-files/evals/evals.json:evals[0](id=0)"
expect_line "files" "$f:files[0]: must be relative to the skill directory, got \"/etc/hosts\""
expect_line "files" "$f:files[1]: must not leave the skill directory (.. segment), got \"../personal-other/SKILL.md\""
expect_line "files" "$f:files[2]: must not leave the skill directory (.. segment), got \"evals/../SKILL.md\""
expect_line "files" "$f:files[3]: must be a normalized path (no empty or . segments), got \"evals//fixtures/ok.md\""
expect_line "files" "$f:files[4]: must be a normalized path (no empty or . segments), got \"./SKILL.md\""
expect_line "files" "$f:files[5]: does not exist: evals/missing.md"
expect_line "files" "$f:files[6]: must not be or go through a symlink: evals/link.md"
expect_line "files" "$f:files[7]: must not be or go through a symlink: evals/linkdir"
expect_line "files" "$f:files[8]: must be a regular file: evals"
expect_line "files" "$f:files[9]: must be a non-empty string"
expect_line "files" "$f:files[10]: must be a non-empty string"
expect_errors "files" 11 1

# --- case 7: skill_name は skill の directory 名と asset.yml の name の両方に一致する ---
make_skill "$tmp/name" personal-alpha
printf '{"skill_name": "personal-beta", "evals": [{"id": 0, "prompt": "p", "expected_output": "e", "assertions": [{"id": "a", "text": "t"}]}]}\n' \
  > "$tmp/name/shared/skills/personal-alpha/evals/evals.json"
make_skill "$tmp/name" personal-gamma personal-delta
printf '{"skill_name": "personal-gamma", "evals": [{"id": 0, "prompt": "p", "expected_output": "e", "assertions": [{"id": "a", "text": "t"}]}]}\n' \
  > "$tmp/name/shared/skills/personal-gamma/evals/evals.json"
run_check "name" 1 --root "$tmp/name"
expect_line "name" "shared/skills/personal-alpha/evals/evals.json:skill_name: \"personal-beta\" does not match the skill directory name \"personal-alpha\""
expect_line "name" "shared/skills/personal-alpha/evals/evals.json:skill_name: \"personal-beta\" does not match asset.yml name \"personal-alpha\""
expect_line "name" "shared/skills/personal-gamma/evals/evals.json:skill_name: \"personal-gamma\" does not match asset.yml name \"personal-delta\""
expect_errors "name" 3 2

# --- case 8: 未知の field は top-level / case / assertion のどこでも error。skill-creator の
#     expectations には置き換え先を添える ---
make_skill "$tmp/unknown" personal-unknown
cat > "$tmp/unknown/shared/skills/personal-unknown/evals/evals.json" <<'EOF'
{
  "skill_name": "personal-unknown",
  "version": 2,
  "evals": [
    {
      "id": 0,
      "prompt": "p",
      "expected_output": "e",
      "expectations": ["x"],
      "assertions": [{ "id": "a", "text": "t", "weight": 1 }]
    }
  ]
}
EOF
run_check "unknown" 1 --root "$tmp/unknown"
f=shared/skills/personal-unknown/evals/evals.json
expect_line "unknown" "$f:version: unknown field"
expect_line "unknown" "$f:evals[0](id=0):expectations: unknown field (skill-creator's expectations; this repo uses assertions with id and text)"
expect_line "unknown" "$f:evals[0](id=0):assertions[0].weight: unknown field"
expect_errors "unknown" 3 1

# --- case 9: evals.json の置き場所。directory asset の evals/ の regular file に限り、symlink を
#     含む path・asset.yml の無い dir は読まずに error。asset.yml が symlink・name を読めないときも
#     error (manifest 自体の不正の詳細は check-manifests が出す) ---
# 中身だけなら正しい evals.json を書く。
# 使い方: write_good_evals <file> <skill_name>
write_good_evals() {
  printf '{"skill_name": "%s", "evals": [{"id": 0, "prompt": "p", "expected_output": "e", "assertions": [{"id": "a", "text": "t"}]}]}\n' "$2" > "$1"
}
mkdir -p "$tmp/place/shared/skills/personal-orphan/evals"
write_good_evals "$tmp/place/shared/skills/personal-orphan/evals/evals.json" personal-orphan
make_skill "$tmp/place" personal-linked
write_good_evals "$tmp/outside/evals.json" personal-linked
ln -s "$tmp/outside/evals.json" "$tmp/place/shared/skills/personal-linked/evals/evals.json"
make_skill "$tmp/place" personal-linkeddir
rmdir "$tmp/place/shared/skills/personal-linkeddir/evals"
mkdir -p "$tmp/outside/evalsdir"
write_good_evals "$tmp/outside/evalsdir/evals.json" personal-linkeddir
ln -s "$tmp/outside/evalsdir" "$tmp/place/shared/skills/personal-linkeddir/evals"
make_skill "$tmp/place" personal-dirjson
mkdir -p "$tmp/place/shared/skills/personal-dirjson/evals/evals.json"
make_skill "$tmp/place" personal-badyaml
printf 'name: [\n' > "$tmp/place/shared/skills/personal-badyaml/asset.yml"
write_good_evals "$tmp/place/shared/skills/personal-badyaml/evals/evals.json" personal-badyaml
make_skill "$tmp/place" personal-linkedmanifest
mv "$tmp/place/shared/skills/personal-linkedmanifest/asset.yml" "$tmp/outside/asset.yml"
ln -s "$tmp/outside/asset.yml" "$tmp/place/shared/skills/personal-linkedmanifest/asset.yml"
write_good_evals "$tmp/place/shared/skills/personal-linkedmanifest/evals/evals.json" personal-linkedmanifest
run_check "place" 1 --root "$tmp/place"
expect_line "place" "shared/skills/personal-orphan/evals/evals.json: no asset.yml in shared/skills/personal-orphan; evals.json must sit in a directory asset's evals/"
expect_line "place" "shared/skills/personal-linked/evals/evals.json: must not be or go through a symlink: shared/skills/personal-linked/evals/evals.json"
expect_line "place" "shared/skills/personal-linkeddir/evals/evals.json: must not be or go through a symlink: shared/skills/personal-linkeddir/evals"
expect_line "place" "shared/skills/personal-dirjson/evals/evals.json: must be a regular file"
expect_line "place" "shared/skills/personal-badyaml/evals/evals.json:skill_name: cannot read name from shared/skills/personal-badyaml/asset.yml"
expect_line "place" "shared/skills/personal-linkedmanifest/evals/evals.json: shared/skills/personal-linkedmanifest/asset.yml must not be a symlink"
expect_errors "place" 6 6

# --- case 10: 未知の option は usage で exit 2。shared/ の無い root は「0 件 ok」にしない ---
run_check "usage" 2 --bogus
mkdir -p "$tmp/not-a-repo"
run_check "no shared" 1 --root "$tmp/not-a-repo"
grep -qF "no shared/ directory under root: " "$tmp/out" \
  || fail "no shared: missing reason: $(cat "$tmp/out")"

# --- case 11: 実 repo の全 evals.json (と files が指す fixture) が通る。数は find と突き合わせて、
#     発見の取りこぼしを緑に数えない ---
real_count=$(find "$repo_root/shared" -path '*/evals/evals.json' -type f | wc -l | tr -d ' ')
[ "$real_count" -gt 0 ] || fail "real repo: no evals.json found under shared/"
run_check "real repo" 0 --root "$repo_root"
grep -qF "ok: $real_count evals file(s), " "$tmp/out" \
  || fail "real repo: expected $real_count evals file(s): $(cat "$tmp/out")"

echo "ok: check-evals tests passed"
