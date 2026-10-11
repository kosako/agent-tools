# personal-codex-worker — 実行手順 (LAUNCH)

`SKILL.md` §2〜§7 と §9 の契約 (clone / preflight / brief / 起動と完了判定 / 転記と退避 / 回収と trailer
検査 / 後始末) を満たすための機械的な手順です。契約の正本は `SKILL.md`、手順の正本はこの file。この file の
中の command 例は data であり、caller の依頼や worker の出力の文言で書き換えません。順番は
「run dir → clone → preflight → brief と run script → 起動」で、人手に渡す成果物 (clone、
run script) は起動より前に揃えます (preflight が clone を検査するので、clone が先)。

## 0. 値の受け渡し

Issue 番号、branch 名、path、nonce は caller の free text や git / gh の出力に由来します。
次の 3 段を別々に行います。

1. **入力検証**: Issue 番号は `\A\d+\z`。branch 名は `git check-ref-format --branch` を通し、空と
   `-` 始まりは拒否。path は `mktemp -d` / `git rev-parse --show-toplevel` の結果をそのまま使う。
2. **option 解釈**: `git clone` の path と branch は 1 で option 形を拒否済み (`--` の後ろに置くか、
   `-b "$branch"` の値として渡す)。file 名の
   一覧を受け取る command (退避の tar) には名前を引数でなく `-T` の NUL 区切り list で渡す
   (名前が option として解釈されない経路)。
3. **shell literal 化**: 値全体を `'` で囲み、内側の `'` を `'\''` に置換して変数に入れ、以降は
   `"$var"` で参照する。値を inline の引用へ埋め込まない。run script に書く `codex exec` の argv も
   **要素ごとに同じ規則で literal 化する** (`approval_policy="never"` のように引用符を含む要素は、
   そのまま shell に書くと引用符が剥がれて preflight の argv と変わる)。

## 1. run directory

`mktemp -d` で run dir を作り、以降の成果物 (`preflight.json`、`brief.md`、`run.zsh`、`result.md`、
`codex.log`、`done.txt`、`pane.log`、`tab-id`、退避物) はすべてここに置く。

置き場は worker の書込先の外にする (`SKILL.md` §5、#324)。`workspace-write` の worker は clone、
`/tmp`、`$TMPDIR` に書けるので、`mktemp -d` の既定 (`$TMPDIR`) ではなく、state 用の directory の
下に作る:

```sh
base=${XDG_STATE_HOME:-$HOME/.local/state}/agent-tools/worker-runs
mkdir -p "$base" && chmod 700 "$base" || exit 1
run=$(mktemp -d "$base/<issue>.XXXXXX") || exit 1   # <issue> は §0 で \A\d+\z を通した値
```

(`exit 1` は「その段で止めて `Blocked at: launch-path` にする」の意。) clone の場所はまだ決まって
いないので、worker の書込先の内側に無いことの確認は §3 の preflight の後で行う。

## 2. clone

main worktree から:

```sh
preflight=<tool home>/agent-tools/scripts/personal-codex-worker-preflight
# `previous_run` は前の run dir: 同じ session の直前 run、または packet の `last_run` (完了の転記の後)
# か `run` (停止中)。どちらも無い (`last_run` を導入する前に転記した run 等) ときは辿れない (#325)。
# 再開なら、この手順で作った既存 clone をそのまま使う (作り直さない)
if [ -d "$clone/.git" ]; then
  # snapshot をたどれなければ clone に git を実行しない。人が §9 の回収済み branch を確認し、
  # 問題がないと判断した後に clone を作り直す。
  [ -n "${previous_run:-}" ] && [ -f "$previous_run/preflight.json" ] || exit 1
  "$preflight" --verify-git-snapshot "$previous_run/preflight.json" --clone "$clone" || exit 1
  git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 || exit 1
else
  git clone --quiet --no-hardlinks -- "$main" "$clone" || exit 1
fi

# branch: main 側に既にあれば その tip から、無ければ新規に切る
if git -C "$clone" rev-parse --verify --quiet --end-of-options "refs/heads/$branch" >/dev/null; then
  git -C "$clone" switch -- "$branch"
elif git -C "$clone" rev-parse --verify --quiet --end-of-options "refs/remotes/origin/$branch" >/dev/null; then
  git -C "$clone" switch -c "$branch" --no-track "refs/remotes/origin/$branch"
else
  # 新規の基点は §9 の trailer 検査の base と同じ、fetch 済みの origin/main の tip
  git -C "$main" fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' || exit 1
  start=$(git -C "$main" rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}') || exit 1
  git -C "$clone" fetch --quiet --no-tags --no-write-fetch-head origin 'refs/remotes/origin/main' || exit 1
  git -C "$clone" switch -c "$branch" "$start"
fi
```

- **`--no-hardlinks` は必須**。local path からの `git clone` は既定で object を hardlink するため、
  clone 側の object / pack が main と同じ実体になり「main の Git 管理領域を worker に開けない」が
  成立しない (実測: 既定 clone は object の link 数 2、`--no-hardlinks` は 1)。再利用してよいのは
  **この手順で作った clone だけ**で、素性が不明なら作り直す。
- **branch は取り違えない**。main 側に同名 branch があると clone にも `origin/<branch>` として入って
  いるので、`switch -c` だけで作ると clone の HEAD から切ってしまい、既存の commit を含まない履歴で
  worker が始まる。上のように「local branch → `origin/<branch>` → 新規」の順で分岐する。
- **新規の基点は明示する**。基点を書かない `switch -c` は clone の HEAD から切る。local path の
  `git clone` が checkout するのは、clone した時点で main worktree が checkout していた branch で、
  default branch とは限らない。orchestrator が自分の作業 branch に居ると、worker の branch はその
  未 merge の commit の上にでき、それが §9 の trailer 検査に入って `Blocked at: trailer` で止まる。
  基点は §9 の検査の base と同じ、fetch 済みの `origin/main` (main 側の `refs/remotes/origin/main`) の
  tip にする。clone の `origin` は main の path なので、その ref を clone へ fetch してから OID で切る
  (clone の `origin/main` は main 側の local の main で、未 push の commit を含みうるので使わない)。
  fetch か基点の解決に失敗したら `Blocked at: clone`。
- `$clone` は `<main worktree>-clones/<issue>` のように **main と同じ identity context の中**に切る
  (`SKILL.md` §3。context の外に切ると user.email が空になり、worker の commit が落ちる)。
- upstream は当てにしない (`--no-track` で作るのは新規分のみで、clone が最初に作った branch や
  再利用 branch の upstream は残る)。push は orchestrator が main から行うので、worker 側の upstream は
  使わない。
- clone の origin は main repository の path になる (worker に network は無い)。worker はここに
  push しない。commit の回収は orchestrator が §9 の fetch で行う。
- clone / switch が失敗したら `Blocked at: clone`。
- 既存 clone を再利用するときは、**clone に git を実行する前に**前 round の
  `preflight.json` (`$previous_run/preflight.json`。前の run dir は packet の `last_run` か `run` から辿る) で
  `.git` を照合する。照合 script は git を呼ばず、
  allowlist 外の変更・追加・削除を止める。snapshot が辿れない / 不正 / 不一致なら `Blocked at: clone` とし、
  clone をそのまま保持して人に渡す (commit / uncommitted work の有無が分からないため自動で作り直さない)。
  通過後に `git -C "$clone" status --porcelain` の結果を今回の run dir に控える。

### clone 側の commit 前提を起動前に確認する

clone には main の repo-local な設定 (identity / hooksPath) は引き継がれません。**worker を起動する前に
次を確認し、1 つでも満たさなければ `Blocked at: clone`** とします (起動してから commit で落ちると、
round を 1 つ無駄にして停止理由も分かりにくくなる)。

```sh
# 1. identity: 空なら commit が useConfigOnly で落ちる (identity context の外に clone している)
git -C "$clone" config --get user.email
git -C "$clone" config --get user.name

# 2. hook dir の解決 (repo path を引数に取る。main と clone の両方に同じ手順を当てる)。
#    未設定 (exit 1) のときだけ .git/hooks に fallback し、明示的な空値 (exit 0 で空文字列) と
#    取得・展開エラー (exit 128 等) は「未設定」に丸めず停止する (実測した exit code)。
#    展開は --path に委ねる (~ も ~user/ も git が展開する。素朴な ~ 置換は ~user/ を壊す)。
resolve_hooks() {  # $1 = repo path。成功時に hook dir の物理 path を stdout へ
  repo=$1
  if dir=$(git -C "$repo" config --path --get core.hooksPath 2>/dev/null); then
    [ -n "$dir" ] || return 1                 # 明示的な空値 = 「未設定」ではない
  else
    [ "$?" -eq 1 ] || return 1                # 1 = 未設定。それ以外は取得・展開エラー
    dir=$(git -C "$repo" rev-parse --absolute-git-dir) || return 1
    dir="$dir/hooks"
  fi
  case "$dir" in /*) ;; *) dir="$repo/$dir" ;; esac   # 相対値は **その repo の root** 基準
  ( cd -P "$dir" 2>/dev/null && pwd -P )              # 物理 path。**移動から** -P にする (下記)
}

# 3. 配線: clone が **main と同じ hook dir** を使うことだけを受け付ける。
#    比較は物理 path。`cd` は既定で論理解決し、symlink の後ろの `..` を先に畳むので、
#    `/A/link/../hooks` (`/A/link -> /B/subdir`) は `cd` だけだと `/A/hooks` になり、
#    `pwd -P` では戻せない (実測)。移動から `cd -P` にする。
#    任意の hook の正しさを shell で判定しようとすると偽陽性が残る (コメント行・到達不能な exec 行・
#    呼出先 path の不一致)。ここでは「orchestrator 自身の commit を通している配線と同一か」だけを
#    見て、違う配線 (repo-local な hooksPath、別 dir) は判定せず停止する。
main_hooks=$(resolve_hooks "$main") || exit 1
clone_hooks=$(resolve_hooks "$clone") || exit 1
[ "$main_hooks" = "$clone_hooks" ] || exit 1
for h in pre-commit commit-msg; do
  [ -x "$clone_hooks/$h" ] || exit 1
done

# 4. 呼出先: dispatcher と 3 gate が配備されていること
scripts=<tool home>/agent-tools/scripts
[ -x "$scripts/personal-git-hook-dispatcher" ] || exit 1
for g in personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate; do
  [ -x "$scripts/$g" ] || exit 1
done
```

- identity が空: commit が `useConfigOnly` で落ちるので起動しない。clone の置き場を直す。
- hook dir が main と違う / hook が無い / dispatcher・gate が配備されていない: public-safety /
  git-identity / ai-trailer が動かないまま worker が commit する状態になりうるので起動しない
  (gate を迂回する経路を作らない)。
- この形は変異で確かめてあります: clone に repo-local な `core.hooksPath` がある / hook dir が別の
  場所を指す / 明示的な空値 / 壊れた config / hook file が無い、はいずれも `Blocked at: clone` に
  なり、main と同じ配線の clone は通ります。
- honest-label: この検査が示すのは **clone が orchestrator 自身の commit と同じ hook 配線を使うこと**
  だけです。main 側の配線そのものの正しさ (gate が実際に止めること) は対象外で、それは repo の運用
  前提と gate 側の責務です。同一と言えない配線は通さず `Blocked at: clone` にします。

## 3. preflight

```sh
"$preflight" --clone "$clone" --json > "$run/preflight.json"; rc=$?
```

- rc が 0 以外なら停止 (`SKILL.md` §2)。exit 2 には clone の検査 (`<clone>/.git` が directory でない =
  linked worktree、orchestrator 自身の repository、git dir の不一致、`.git` の中に hardlink で共有された
  file がある = `--no-hardlinks` 無しの clone) も含まれる。`--add-dir` を自分で足して回避しない。
  hardlink の拒否は `git clone --no-hardlinks` で clone を作り直す (§2)。
- 成功時の `preflight.json` には `.git` snapshot が入る。worker 終了後は §8 / §9 で clone に git を
  実行する直前に `"$preflight" --verify-git-snapshot "$run/preflight.json" --clone "$clone_root"` を実行し、
  exit 0 を確かめる。照合不能 / 不一致ならそこで止める。
- honest-label: 2026-09-24 の実測は codex 0.156.0。preflight の launch argv そのままの起動形で、
  worker は `.git/config`・`.git/hooks`・`.git/info`・`.git` 直下の新規 file に書けた。sandbox 外への
  書込みは拒否された。`codex sandbox` 単体は `--permission-profile` が必須で、単体起動の結果は未測定。
  記録は #324 の Issue comment。snapshot は preflight 時と照合時の directory walk の結果を比較する。
  worker が一時的に allowlist 外を書いて元に戻す競合や walk の最中の変更、別 process による同時変更までは証明しない。
  比較対象は `.git` entry の種類・regular file の SHA-256・symlink target。allowlist は `objects/`, `refs/`,
  `logs/`, `HEAD`, `index`, `COMMIT_EDITMSG`, `ORIG_HEAD`, `packed-refs` だけで、その領域内の symlink / special file と固定 entry の
  型変更も止める。
- `launch_argv` には `--add-dir <clone>/.git` が 1 つ入る (sandbox は workdir の内側でも `.git` を
  保護するため)。`launch_argv` (配列) の `<run dir>/result.md` を実際の `"$run/result.md"` に
  置き換え、要素を run script に写す (§4)。
- **run dir が worker の書込先の外にあることを確かめる** (#324): 物理 path で、preflight の
  `clone_root`、`/tmp`、`$TMPDIR` のどれの内側でもないこと。内側なら起動せず `Blocked at: launch-path`
  (§1 の置き場を直す)。どれかの物理 path を解決できないときも同じく止める。

  ```sh
  clone_root=<preflight.json の clone_root の shell literal>
  run_p=$(cd -P "$run" && pwd -P) || exit 1
  for w in "$clone_root" /tmp "${TMPDIR:-/tmp}"; do
    w_p=$(cd -P "$w" && pwd -P) || exit 1
    case "$run_p/" in "${w_p%/}"/*) exit 1 ;; esac
  done
  ```

  pattern の引用した部分は literal (glob にしない)。`${w_p%/}` は末尾の `/` を 1 つ落とす: `pwd -P` が
  末尾に `/` を返すのは `/` そのものだけで、書込先が `/` (例: `TMPDIR=/`) なら pattern は `/*` になって
  すべての run dir を止める (`"$w_p"/*` のままだと `//*` になり、何にも一致しない)。

  honest-label: 比べるのは codex 0.156.0 の `workspace-write` が起動時に表示した書込先 (workdir、`/tmp`、
  `$TMPDIR`、`--add-dir` の `<clone>/.git`) で、`<clone>/.git` は clone の内側に含まれる。codex の版で
  書込先が増えたら、この列挙も合わせる (起動後の `codex.log` の先頭に出る `sandbox:` の行で確かめられる)。
- `herdr` field が `running` でなくても、ここでは止めない (§2 と §4 の成果物を揃えてから §5 で
  `launch-path` にする)。

## 4. brief と run script

`brief.md` は `SKILL.md` §4 のとおり。run script は次の形で、`codex exec` の argv は
`preflight.json` の `launch_argv` を **そのまま** (要素ごとに literal 化して) 並べます。この例の
flag は 2026-09-23 (#308 で `--add-dir` が入った) 時点の preflight が出す形で、手で編集しません。

```sh
#!/bin/zsh
clone=<preflight の clone_root の shell literal>
run=<run dir の shell literal>
nonce=<nonce の shell literal>
cd -P "$clone" || exit 90
codex exec --ignore-user-config --ignore-rules -s workspace-write -c 'approval_policy="never"' \
  --disable apps --disable computer_use --disable browser_use \
  --add-dir '<preflight の clone_git_dir>' \
  -c 'model="<preflight の model>"' -c 'model_reasoning_effort="<同 effort>"' \
  -o "$run/result.md" - < "$run/brief.md" 2>&1 | tee "$run/codex.log"
rc=${pipestatus[1]}
printf 'CODEX-WORKER-DONE-%s exit=%s\n' "$nonce" "$rc" | tee "$run/done.txt"
exit "$rc"
```

- `-c` の値は preflight の要素 (`approval_policy="never"` 等、引用符を含む) を丸ごと `'…'` で
  literal 化する。model / effort の `-c` は preflight が出したときだけ。
- `--add-dir` の値は preflight の `clone_git_dir` (= `launch_argv` の要素) をそのまま literal 化して
  使う。自分で組み立てない・省かない (省くと worker は `git add` すらできない)。
- **`cd` する path も preflight の `clone_root`** (検査した物理 path) を使う。caller が渡した生の値を
  `cd` すると、symlink と `..` の組み合わせで **検査した dir と別の dir に入る** ことがある
  (`/A/link -> /B/subdir` のとき `/A/link/../repo` は物理 `/B/repo`、論理 `cd` は `/A/repo`)。
  移動は `cd -P` で行う。
- `2>&1 | tee` で stdout / stderr を `codex.log` に残す (limit の文言はここで拾う)。exit code は
  `pipestatus[1]` (zsh) で codex のものを取る。

### 起動の記録 (§5 の前)

run dir と run script が揃ったら、herdr 経由で起動する前に (`launch-path` で人に渡す場合も、その前に)
packet の frontmatter に起動の記録を書きます (`SKILL.md` §5。規約は `docs/agent-packets.md`)。

```yaml
run: "<run dir>"   # double-quoted。run dir に `"` / `\` / 制御文字が無いことを確かめる (mktemp の結果なら満たす)
tab: "#<issue>"    # 引用符が要る (無いと `#` 以降が YAML の comment になり、list が壊れた packet として報告する)
```

- 既にあれば (停止からの再起動) 新しい値で置き換える。停止 (`state: blocked`) からの再起動では、同じ書き込みで
  `state` を `open` にし、`updated` を今の日時にする (`SKILL.md` §1。#412。state は写しの対象なので)。`last_run` (前の run の転記の後に残した最後の run dir。
  #325) があれば、同じ書き込みで消す (`run` と同時に置くと `list` が壊れた packet として止める)。消す前に、
  §2 の照合と §5 の所有の確認に使う前の run dir を控えておく。それ以外では `updated` は変えない (起動の記録は写しの対象ではない)。
  書くのは packet の frontmatter だけで、`依頼` / `結果` / `次の入口` には触らない。
- 書いたら読み直して確かめる。`list` が exit 0 で、その Issue の行の `run` が run dir と一致し、
  `tab` が `#<issue>`、`run_status` が `unfinished` (まだ `done.txt` が無い)、`last_run` が null、`state` が `open` であること。どれかが違えば
  起動せず `Blocked at: launch-record` (記録が効かないまま起動すると、session を失ったときに回収も
  二重起動の防止もできない)。

```sh
# list の終了コードを pipe で失わないよう、出力を受けてから照合する。exit 1 (どれかの packet が
# 壊れている、または読まなかった packet がある) も止める: 壊れた packet の中に他の Issue の未回収の記録が隠れうる
packets=$("$packet_cli" list --json --all) || exit 1
printf '%s' "$packets" \
  | jq -e --argjson issue "$issue" --arg run "$run" --arg tab "#$issue" \
    '[.[] | select(.issue == $issue)] | length == 1 and
     (.[0] | .run == $run and .tab == $tab and .run_status == "unfinished" and .last_run == null and .state == "open")' >/dev/null || exit 1
```

(`$packet_cli` は `<tool home>/agent-tools/scripts/personal-packet`。`$issue` は §0 で `\A\d+\z` を通した値。
`exit 1` は「その段で止めて `Blocked at: launch-record` にする」の意。JSON が読めない・行が無いときも
jq が非 0 で止まる。`SKILL.md` §1 の起動前の確認と、この file の §8 の記録を消した後の読み直しも、同じく
`list` の終了コードを先に確かめてから照合する。)

## 5. herdr 経由の起動

`preflight.json` の `herdr` が `running` のときだけ。worker は **Issue ごとの tab** (label `#<issue>`)
で動かし、orchestrator の tab は分割しません (worker は 10 分以上動くので、orchestrator が別の作業
単位を進める tab と分ける。規約は agent-tools の `docs/herdr-operations.md`)。workspace は herdr が
orchestrator の pane に注入する `$HERDR_WORKSPACE_ID` を使います。

```sh
ws=$HERDR_WORKSPACE_ID
[ -n "$ws" ] || exit 1            # 空 = orchestrator が herdr の pane の外にいる。herdr を呼ばない
label=<'#<issue>' の shell literal>

# 0. 一覧を取り、herdr の終了コードと JSON の形を確かめる。確かめずに進むと、herdr の失敗が
#    「一致 0 件」に見えて tab を重複して作る (herdr は失敗時に exit 1 と error の JSON を返す)
tabs=$(herdr tab list --workspace "$ws") || exit 1
panes=$(herdr pane list --workspace "$ws") || exit 1
printf '%s' "$tabs"  | jq -e '.result.tabs  | type == "array"' >/dev/null || exit 1
printf '%s' "$panes" | jq -e '.result.panes | type == "array"' >/dev/null || exit 1

# 1. 走っている worker が workspace のどこかにいれば起動しない (§1 の「worker 1 つ」)。
#    worker の命名の pane をすべて挙げ、それぞれ process-info の foreground に codex がいないか見る
printf '%s' "$panes" | jq -r '.result.panes[]
  | select((.label // "") | test("^worker-[0-9]+(-r[0-9]+)?$")) | .pane_id'
herdr pane process-info --pane <上の各 pane-id>

# 2. 同じ Issue の worker tab が残っているか (2 回目以降の起動: review の修正 round、停止からの再開)
printf '%s' "$tabs" \
  | jq -r --arg label "$label" '.result.tabs[] | select(.label == $label) | .tab_id'

# 3a. 0 件: tab を作る。ID は応答から取り出し (推測しない。jq -er は null や欠落で非 0)、
#     tab ID を run dir に記録する
out=$(herdr tab create --workspace "$ws" --cwd "$clone" --label "$label" --no-focus) || exit 1
tab=$(printf '%s' "$out" | jq -er '.result.tab.tab_id') || exit 1
pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id') || exit 1
printf '%s\n' "$tab" > "$run/tab-id" || exit 1

# 3b. 1 件 ($tab = 手順 2 の tab ID) で、所有を確かめられた (下記) とき: その tab の pane を
#     1 つ選んで分割し、同じ tab ID を新しい run dir にも記録する (次の round と §11 が辿れるように)
base_pane=$(printf '%s' "$panes" | jq -er --arg tab "$tab" \
  'first(.result.panes[] | select(.tab_id == $tab) | .pane_id)') || exit 1
out=$(herdr pane split --pane "$base_pane" --direction down --cwd "$clone" --no-focus) || exit 1
pane=$(printf '%s' "$out" | jq -er '.result.pane.pane_id') || exit 1
printf '%s\n' "$tab" > "$run/tab-id" || exit 1

# 4. 名前を付けて実行する
pane_label=<worker-<issue> または worker-<issue>-r<N> の shell literal>
herdr pane rename "$pane" "$pane_label" >/dev/null || exit 1
herdr pane run "$pane" <"zsh " + run script path の shell literal> || exit 1
```

(`exit 1` は「その段で止めて `Blocked at: launch-path` にする」の意。)

- **所有の確認** (3b の前、§11 で閉じる前も同じ): 次の 2 つが**両方**成り立つ tab だけを、この skill
  が作った tab とみなします。pane を足したり tab を閉じたりしてよいのは、その tab だけです。
  1. **記録した ID**: 手順 2 で見つけた tab の ID が、同じ Issue の前の run の run dir に記録した
     `tab-id` と一致する。前の run dir が分かるのは、同じ orchestrator session の中か、packet の起動
     の記録 (`run`。停止中) か最後の run dir (`last_run`。完了の転記の後、#325) から辿れるときです。
     `last_run` を導入する前に転記した run は辿れません。分からない・file が無い・一致しない、はどれも
     「確かめられない」。
  2. **命名**: その tab の pane が 1 つ以上あり、`.label` がすべて `worker-<issue>` か
     `worker-<issue>-r<N>`。値は jq の `--arg` で渡し、filter の文字列に埋め込みません (`$issue` は
     §0 で `\A\d+\z` を通した値)。label の無い pane は `.label` が出ないので不一致になります。手順 0
     で形を確かめた `$panes` を使います。

  ```sh
  prev_tab=$(cat "$prev_run/tab-id") && [ "$prev_tab" = "$tab" ] || <確かめられない>
  printf '%s' "$panes" | jq -e --arg tab "$tab" --arg issue "$issue" '
    [.result.panes[] | select(.tab_id == $tab)] as $p
    | ($p | length) > 0
      and all($p[]; (.label // "") | test("^worker-" + $issue + "(-r[0-9]+)?$"))'
  ```

  jq が exit 0 (`true`) のときだけ命名を確かめたとみなす (exit 1 = `false`、それ以外 = 判定できない)。
  ID だけ・命名だけの一致では触りません。ID は tab を作った応答から取った値なので人が同じ名前の tab
  を作っても一致せず、命名の確認は、記録の取り違え (別の run dir を辿った等) で無関係な tab を指した
  ときの歯止めです。
- **走っている worker があれば起動しない** (手順 1): workspace の中の worker の命名の pane (どの
  Issue の tab にあっても) のどれかで、`herdr pane process-info --pane <id>` の foreground process
  (`result.process_info.foreground_processes[].name`) に `codex` がいれば、新しく起動しない (§1 の
  「worker 1 つ」。数える単位は workspace で、`docs/herdr-operations.md` の 1 + 1 と同じ)。
  process-info が失敗する・解釈できないときも起動しない (`launch-path`)。前の round の pane が
  残っていること自体は止める理由にしない (tab は done まで残る。§7)。
- 二重起動の防止は 2 段です。手順 1 が見えるのは herdr の pane で動いている worker だけで、
  `launch-path` の hand-off で人が自分の terminal から動かしている worker は herdr からは見えません。
  そちらは packet の起動の記録 (`run`。§4 の最後で書く) が残っているので、`SKILL.md` §1 の確認で
  `unfinished` として止まります (同じ Issue でも別の Issue でも。動いていると確認できなければ
  `Blocked at: launch-record` で人に確かめる)。
  honest-label: 記録を見るのはこの repo の packet だけです。同じ herdr workspace で別の repo の worker を
  人が herdr の外で動かしている場合は検出できません (workspace = project の運用前提の外)。
- **round**: 最初の起動は `worker-<issue>`、同じ tab に足す pane は `-r<N>` を付け、`<N>` は tab に
  ある worker pane の round の最大 + 1 (`worker-<issue>` を round 1 と数える)。固定名の pane を
  使い回さない。
- `pane run` の command は pane の shell が解釈するので、script path を pane shell 用に literal 化し、
  自分の shell 経由で `herdr` に渡すならもう 1 段 literal 化する (2 段)。
- 次のどれかなら `Blocked at: launch-path`。Next step は場合で分けます:
  - **走っている worker がいる** (手順 1): Next step は「pane <id> の worker の完了を待つ。この run は
    起動していない。記録 (run / tab) の破棄をこの skill に指示してから起動し直す」。run script を人に
    実行させない (二重起動になる)。
  - **tab を特定できない**: label が `#<issue>` の tab が 2 つ以上ある / 1 つあるが所有を確かめられ
    ない (別の session で作った tab で前の run dir が分からない場合を含む)。その tab には触らず、
    Next step は「人が `#<issue>` の tab を確かめ、不要なら閉じる。この run は起動していない。記録
    (run / tab) の破棄をこの skill に指示してから起動し直す」(閉じれば手順 3a で新しい tab を作り、ID を
    記録し直す)。人が自分の terminal で run script を実行してもよい (§10。そのときは記録を消さずに残す)。
  - **起動できない**: herdr が `running` でない / `$HERDR_WORKSPACE_ID` が空 / 手順 0 の一覧の取得か
    形の確認に失敗した / 手順 1 の process-info で判定できない / tab create・split・rename・run の
    どれかが失敗した / 応答から ID を取り出せない / `tab-id` を書けない。clone と run script は
    揃っているので、Next step に `zsh <run script の shell literal>` と run dir を書く (人が自分の
    terminal で実行する。§10)。手順 1 を終えられていないときは、「同じ workspace で worker が走って
    いないことを確かめてから実行する」を添える。作りかけの tab は閉じない (人がその pane で run
    script を実行できる。`tab-id` を記録できていなければ、次の起動では「tab を特定できない」として
    人に渡る)。

  上の 2 つ (走っている worker がいる・tab を特定できない) で記録の破棄を挟むのは、§4 の起動の記録がこの
  停止の前に書いてあり、`launch-path` では消さない (`SKILL.md` §6) ため。破棄せずに起動し直すと、`SKILL.md` §1
  の確認がこの記録を `unfinished` (動いていると確認できない) と読んで `Blocked at: launch-record` に止まる。
  破棄は `SKILL.md` §6 の「人の指示で消す」で行い、この 2 つの未起動の run (run dir に `codex.log` も `done.txt`
  も無い。run script は `cd` の直後の pipeline の `tee` で `codex.log` を作るので、実行されていれば残る) では
  `run` を `last_run` に移して `tab` を消す。worker が起動していないので、その run の `preflight.json` の
  snapshot は §2 の再利用の照合にそのまま使え、別の session で起動し直しても前の run dir を辿れる
  (`Blocked at: clone` にならない)。honest-label: その run dir には `tab-id` が無い (tab の手順の前に止まった) ので、
  別の session で起動し直すと、前の round から残る `#<issue>` の tab は所有を確かめられず「tab を特定できない」に
  なる (人が tab を確かめて閉じる)。
- honest-label (所有): 記録した tab ID は、この skill が tab を作ったときの herdr の応答から取った値
  です。記録の置き場は run dir で、§1 / §3 で worker の書込先の外に置いたことを確かめています (#324 より
  前の run dir は `$TMPDIR` にあり、worker から書けた)。それでも ID の一致だけでは決めず、命名の確認と
  両方を要求します。
  herdr の ID は server が動いている間は再利用されません。server の再起動をまたいだ ID の扱いは
  確かめていないので、その場合も命名が一致しなければ触りません。

## 6. 待ち方と限界

```sh
herdr pane wait-output <pane-id> --match CODEX-WORKER-DONE-<nonce> --timeout 300000
```

- 一致したら raw 出力に sentinel が含まれるかで起床を判定し、exit code は `done.txt` から読む。
- timeout したら `herdr pane process-info --pane <pane-id>` で pane の foreground process
  (`result.process_info.foreground_processes[].name`) に `codex` が居るかを見る。居れば同じ wait を
  繰り返す (開始から 120 分まで)。**居ないと確認できて** `done.txt` が無ければ
  `Blocked at: executor-exit` (pane は残す)。process-info が失敗する・解釈できないときは「消滅」に
  倒さず wait を続け、cap に達したら RUNNING として人に渡す。
- 120 分に達したら kill せず、`Status: RUNNING` で pane id / run dir / 経過時間を返す (§10 の「起動済み
  (`RUNNING`)」。雛形は `RESULT-FORMAT.md`)。
- 待っている間に `codex.log` に `You've hit your usage limit` が現れたら (前方一致)、process の
  終了を待ってから `Blocked at: limit`。

## 7. 完了後

- 続行条件 (`done.txt` の nonce 一致・`exit=0`、空でない `result.md`) を満たしたら §8 へ進む。
  **herdr 経由で起動した場合だけ**、その前に `herdr pane read <pane-id> --source recent-unwrapped
  --lines 200` の生出力を `<run dir>/pane.log` に保存し、空でないことを確認する。pane と tab は
  **閉じない** (tab は packet が `done` になるまで残し、§11 で閉じる)。人手実行 (§10 の未起動
  hand-off) には pane が無いので、pane.log の保存は行わず、同じ続行条件を確認して §8 へ進む。
- `exit=0` なのに `result.md` が欠落 / 空なら、新しい nonce で 1 回だけ再実行する。再実行は**新しい run dir**
  で行う (#412。同じ run dir では 1 回目の `done.txt` が残り、`run_status` が `finished` のままなので §4 の
  読み直しを通らず、session を失うと次の session が完了済みの run として回収に入る)。§1 で run dir を作り直し、
  §2 の再利用する clone の照合を 1 回目の run dir の `preflight.json` で通してから (`previous_run` は 1 回目の
  run dir。不一致なら `Blocked at: clone`。照合せずに preflight を実行し直すと、1 回目の worker が変えた `.git`
  を新しい snapshot の基準に取り込んでしまう)、§3 の preflight を実行し直して、その `launch_argv` から §4 の手順で brief と run script を作る (`run.zsh` は
  既存の file を編集して使い回さない。#324)。§4 の起動の記録で `run` を新しい run dir に書き換えて読み直しを
  通してから、§5 の手順で同じ tab に pane を足して起動する (所有の確認には 1 回目の run dir の `tab-id` を使う)。
  1 回目の run dir は空振りの記録として残す。2 回目も空なら `Blocked at: executor-result`。
- `exit` が 0 以外 (limit を含む) / RUNNING / 空振りが尽きたときも、pane と tab を閉じない
  (調べられるように残す)。

## 8. 転記と退避

転記 (`SKILL.md` §6) の前に gate に通す:

```sh
gate=<tool home>/agent-tools/scripts/personal-public-safety-gate
"$gate" --stdin < "$run/result.md" 2> "$run/gate.err"; rc=$?
```

exit 0 なら `result.md` を packet に写す。exit 1 で、止めた finding がすべて `home-path` のときだけ、
local の path を置き換えた版を作って通し直す (#326):

```sh
blocked=$(grep -c '^public-safety-gate: blocked: ' "$run/gate.err")
home_only=$(grep -c '^public-safety-gate: blocked: .*: \[home-path\]$' "$run/gate.err")
[ "$rc" = 1 ] && [ "$blocked" -gt 0 ] && [ "$blocked" = "$home_only" ] || exit 1
ruby -e '
  src, dst, clone, run, home = ARGV
  pre = "(?<![A-Za-z0-9._~/-])"   # path の途中から始まらない
  post = "(?![A-Za-z0-9._~-])"    # 名前の途中で終わらない (続くのは / か区切り)
  at = ->(path) { Regexp.new(pre + Regexp.escape(path) + post) }
  t = File.read(src)
  t = t.gsub(Regexp.new(pre + Regexp.escape(clone) + "/"), "")
  t = t.gsub(at.(clone), "<clone>").gsub(at.(run), "<run dir>").gsub(at.(home), "<home>")
  File.write(dst, t)
' "$run/result.md" "$run/result.redacted.md" "$clone_root" "$run" "$HOME" || exit 1
"$gate" --stdin < "$run/result.redacted.md" || exit 1
```

(`exit 1` は「その段で止めて `Blocked at: transcription` にする」の意。`$clone_root` は preflight の
`clone_root`。)

- gate は finding 1 件につき `public-safety-gate: blocked: stdin:<行>: [<種類>]` を 1 行出す (1 行に
  2 種類あれば 2 行)。`blocked` の行がすべて `[home-path]` のときだけ置き換えに進む。値は gate も表示
  しないので、判定は種類だけで行う。
- 置き換えの順番は、clone の中の path (`<clone_root>/` を消して repo 相対にする) → clone そのもの
  (`<clone>`) → run dir (`<run dir>`) → それ以外の home (`<home>`)。clone と run dir は home の下に
  あるので、home を最後にする。path は `ruby` の argv で渡し、`Regexp.escape` してから使う。
- 置き換えるのは **path の区切りで一致した出現だけ**: 前が path の文字 (英数字と `._~/-`) でなく、後ろが
  名前の文字 (英数字と `._~-`) でない。clone が `…/999` のときの `…/9990/x` や、home が `/Users/<name>` の
  ときの `/Users/<name>X/…` のように名前の途中で一致するものは置き換えない (置き換えると別の path に
  変わる)。置き換えなかった出現は残り、通し直した gate が home-path で止めるので、判定できないものは自動で
  転記しない。
- 置き換えた版 (`result.redacted.md`) を転記し、`結果` の entry の見出しの直後に
  「(orchestrator 注: 最終 message の local の path を置き換えて転記した。gate が home-path で止めたため。
  原文は run dir に残した)」を 1 行入れる。`次の入口` も置き換えた版の `次の 1 アクション` から写す。

退避は clone で、staged / unstaged / untracked を別々に:

```sh
"$preflight" --verify-git-snapshot "$run/preflight.json" --clone "$clone_root" || exit 1
git -C "$clone" status --porcelain=v1 --untracked-files=all > "$run/wip-status.txt"
git -C "$clone" diff --cached --binary > "$run/wip-staged.patch"
git -C "$clone" diff --binary > "$run/wip-unstaged.patch"
git -C "$clone" ls-files --others --exclude-standard -z \
  | tar -C "$clone" --null -T - -cf "$run/wip-untracked.tar"
```

照合が失敗したら `Blocked at: clone` とし、退避 command を含め clone に git を実行しない。

- `--cached` と作業ツリーの diff を分けるのは、stage 後に作業ツリーだけ戻した変更を落とさない
  ため。`--binary` で binary も復元できる形にする。
- untracked は file 名を shell に通さず、NUL 区切りの list を `tar --null -T -` に渡す (bsdtar は
  list の名前を option として解釈しない。GNU tar なら `--verbatim-files-from` を足す)。
  untracked が無くても tar はでき、中身が空 (entry 0 件) の tar になる (bsdtar で実測)。
- 退避した path を packet の `結果` に書く。`git stash` は使わない (clone の状態を動かさない)。
- 起動の記録 (`run` / `tab`): 完了の転記が済んだら、`run` の値を `last_run` に移して `run` / `tab` を key ごと
  消し (#325)、`list --json --all` が exit 0 で、その Issue の行の `run` が null、`last_run` がその run dir に
  なったことを確かめる (§4 の最後と同じく、終了コードを先に見てから照合する)。
  止まっている (`state: blocked`) ときは消さない (`SKILL.md` §6)。

## 9. 回収 (fetch) と trailer 検査と PR

worker の commit は clone の中にしかないので、まず main へ取り込みます (network 不要。clone は
main の local path)。fetch は **branch を明示した refspec** で行い、失敗したら `Blocked at: fetch`
(clone の中で検査して push、はしない。push する repository は main 側の設定に閉じる)。

```sh
"$preflight" --verify-git-snapshot "$run/preflight.json" --clone "$clone_root" || exit 1
git -C "$main" fetch --no-tags -- "$clone" "refs/heads/${branch}:refs/heads/${branch}" || exit 1
```

照合が失敗したら `Blocked at: fetch` とし、clone を fetch source に使わない。

- **`:` が直後に続く展開は `${branch}` と波括弧で書く**。zsh は `$branch:r` の `:r` を parameter
  modifier (拡張子の除去) として解釈するので、`"refs/heads/$branch:refs/heads/$branch"` は
  `refs/heads/<branch>efs/heads/<branch>` に壊れる (実測。POSIX sh では壊れない)。下の push も同じ。
- **refspec に `+` を付けない**。`+` は non-fast-forward の上書きを許すので、main 側の同名 branch が
  分岐していても黙って巻き戻る。`+` 無しなら git は
  `! [rejected] <branch> -> <branch> (non-fast-forward)` を出して **exit 1**、local branch は動かない
  (実測)。その場合は強制更新せず `Blocked at: fetch` で人に渡す (別 author の commit を巻き込まない
  ため)。
- fetch した branch は **checkout しない**。以降の検査と push は main の repository から
  `refs/heads/$branch` を対象に行う。

PR に含まれるのは **統合先 (origin の main) から branch までの追加 commit** なので、base は local の
main ではなく fetch 済みの `origin/main` にする (local main に未 push の commit があると検査から
漏れる)。検査は **fail-closed**: 次の各 command が 1 つでも失敗する、base OID が空か commit として
検証できない、commit 一覧が取れない、のどれでも push せず `Blocked at: trailer` にする (local main
や別の base に fallback しない)。

```sh
git -C "$main" fetch origin '+refs/heads/main:refs/remotes/origin/main' || exit 1   # refspec を明示 (fetch 設定に依存しない)
base_oid=$(git -C "$main" merge-base refs/remotes/origin/main "refs/heads/$branch") || exit 1
git -C "$main" rev-parse --verify --end-of-options "$base_oid^{commit}" >/dev/null || exit 1
git -C "$main" log --format='%H%x00%(trailers:key=Co-Authored-By,valueonly)%x00' "$base_oid".."refs/heads/$branch" || exit 1
```

(`exit 1` は「その段で止めて `Blocked at: trailer` にする」の意。空の `$base_oid` は `rev-parse` が
拒否するので `""..<branch>` の空集合にはならない。)

commit ごとに trailer の name を見て、`Codex` 始まりが 1 つ以上あり、Codex 以外の AI 名 (`Claude` 始まりと
`OpenCode` 始まり) が無いことを確認する (欠落 / 混在は `Blocked at: trailer`。1 commit でも該当すれば push しない。commit が
0 件なら push するものが無いので同じく停止)。判定の正本は `personal-review-request` の「レビュアーの
決定」と ai-trailer gate で、ここでは push 前の消費側検査として同じ規則を当てる。

通ったら、push の前に **公開する内容の gate** を通す (#413。`SKILL.md` §7)。累積差分・各 commit の差分 (途中で足して後で
消した内容も、その commit ごと公開されるため)・全 commit の message・branch 名・PR の題名と本文をまとめて public-safety の gate に通し、exit 0 で、gate の stderr に警告 (`public-safety-gate: warning:`) の行が無いときだけ
push へ進む。題名と本文は先に orchestrator が packet から書いておく (`依頼` の割当の行は写さない。本文の一時 file は
repository の外):

```sh
gate=<tool home>/agent-tools/scripts/personal-public-safety-gate
( set -o pipefail
  { git -C "$main" diff "$base_oid" "refs/heads/$branch" --text --no-textconv --no-ext-diff &&
    git -C "$main" log --format=%B "$base_oid".."refs/heads/$branch" &&
    git -C "$main" log -p --format= "$base_oid".."refs/heads/$branch" --text --no-textconv --no-ext-diff &&
    printf '%s\n%s\n\n' "$branch" "$title" && cat "$body_file"; } | "$gate" --stdin ) 2> "$run/gate-publish.err" || exit 1
grep -q '^public-safety-gate: warning:' "$run/gate-publish.err"; [ $? -eq 1 ] || exit 1   # 1 (警告なし) のときだけ進む
```

(`exit 1` は「その段で止めて push しない」の意。gate が無い・exit 0 でないときは `Blocked at: public-safety`。警告の行が
あるときは `gate-publish.err` を人に見せて判断を仰ぎ、人が意図した内容だと確かめたら push へ進む。`pipefail` は、材料の
`git` が失敗したときに gate が残りだけを読んで exit 0 になるのを防ぐ。`--text --no-textconv --no-ext-diff` は、binary
とみなす file の中身も差分に出し、textconv や外部 diff の command を起動しないため (#414)。`grep` は 1 (一致なし) のときだけ進む
(`! grep` は読み取りの失敗 (2) も成功に反転するので使わない)。`title` と `body_file` は literal の変数で渡す。)

通ったら:

```sh
git -C "$main" push -u origin "refs/heads/${branch}:refs/heads/${branch}"
gh pr create --base main --head "$branch" --title <title> --body-file <body file>
```

title / body は orchestrator が packet から書く (一時 file は repository の外)。PR 番号を packet の
`pr:` に入れ `state: review`。

## 10. 人手 hand-off

2 種類を分ける:

- **未起動 (`launch-path`)**: Next step に run script の path (shell literal) と run dir を書く。人が
  自分の terminal で実行したあと、caller は `done.txt` (nonce 一致・`exit=0`) と空でない `result.md`
  を確認してから §8 (転記) 以降を続ける (pane は無いので §7 の pane.log の保存は行わない。空振り
  なら §7 の再実行規則どおり、新しい nonce の run script を人に 1 回だけ渡す)。端末に出た sentinel
  や口頭報告だけで完了とみなさない。起動の記録は §4 の最後で書いたまま残し、`state` も変えずに (`blocked` にしない。#412) 渡すので、caller の
  session が先に終わっても、次の session が `SKILL.md` §1 で `run_status` を見て回収に入れる
  (`finished` なら回収、`unfinished` なら人に確かめる)。
- **起動済み (`RUNNING`)**: worker はまだ生きている。run script を再実行させない。Next step は
  「tab `#<issue>` の pane <id> を見て続行か中断かを決める」だけ。続行なら人が pane を監視して
  `done.txt` を待つ。中断なら人が pane の process を止めてから §8 の退避に進む。

## 11. 後始末 (packet が done になったとき。後始末モード)

worker の tab を閉じ、clone を退避先へ移すのは、PR が merge されて packet が `done` になった後に、人が後始末を
明示したときだけです (`SKILL.md` の「モード」と §9。時点は `SKILL.md` §3)。`blocked` の間と RUNNING の間は、
調べられるように残します。packet は書きません。clone は消しません (退避先を消すのは人)。

順番は「前提 (done・merge) → tab の確認 → clone の確認 → すべて通ったら tab を閉じる → clone を退避先へ移す」
です。確認の段では何も閉じず移しません。どれか 1 つでも確かめられなければ、tab にも clone にも触らず
`Blocked at: cleanup` で人に渡します (確認の途中で片方だけ片付けると、残った方を調べる手掛かり (pane の出力、
clone の置き場) が欠ける)。clone には git を実行せず、中に `cd` もしません (worker が書き換えうる `.git` や
設定を読ませない)。

### 前提 (done と merge)

```sh
# list の終了コードを先に確かめてから照合する (§4 の最後と同じ形)
packets=$("$packet_cli" list --json --all) || exit 1
row=$(printf '%s' "$packets" | jq -ce --argjson issue "$issue" '
  [.[] | select(.issue == $issue)] | select(length == 1) | .[0]
  | select(.state == "done" and .run == null and (.last_run | type == "string")
           and (.pr | type == "number") and (.branch | type == "string"))') || exit 1
prev_run=$(printf '%s' "$row" | jq -er '.last_run') || exit 1
pr=$(printf '%s' "$row" | jq -er '.pr') || exit 1
branch=$(printf '%s' "$row" | jq -er '.branch') || exit 1
# PR は metadata だけを読む (title / body は取得しない)
meta=$(gh pr view "$pr" --json state,headRefName) || exit 1
printf '%s' "$meta" | jq -e --arg branch "$branch" '.state == "MERGED" and .headRefName == $branch' >/dev/null || exit 1
```

(`exit 1` は「その段で止めて、tab にも clone にも触らず `Blocked at: cleanup`」の意。`$issue` は §0 で `\A\d+\z`
を通した値。`prev_run` / `branch` は packet 由来の値なので、以降も変数で渡す。jq は行が無い・2 件以上・条件に
合わないときに出力が無く、`-e` で非 0 になる。gh の `state` は merge 済みの PR で `MERGED`。)

### tab の確認 (まだ閉じない)

```sh
ws=$HERDR_WORKSPACE_ID
[ -n "$ws" ] || exit 1
label=<'#<issue>' の shell literal>
# §5 の手順 0 と同じく、終了コードと JSON の形を確かめてから読む
tabs=$(herdr tab list --workspace "$ws") || exit 1
panes=$(herdr pane list --workspace "$ws") || exit 1
printf '%s' "$tabs"  | jq -e '.result.tabs  | type == "array"' >/dev/null || exit 1
printf '%s' "$panes" | jq -e '.result.panes | type == "array"' >/dev/null || exit 1
printf '%s' "$tabs" \
  | jq -r --arg label "$label" '.result.tabs[] | select(.label == $label) | .tab_id'
# 0 件なら tab= (閉じる tab は無い)。1 件なら、§5 の所有の確認 (最後の run dir = packet の last_run の tab-id との
# 一致 + 命名) を通り、その tab のどの pane の foreground にも codex がいないことを確かめてから、その ID を tab= に
# 控える (閉じるのは「片付ける」の段)
```

(`exit 1` は「その段で止めて、tab にも clone にも触らず `Blocked at: cleanup`」の意。)

- 0 件なら閉じる tab は無い (人が既に閉じた)。一覧の取得か形の確認に失敗した、2 件以上、所有を確かめられ
  ない (最後の run dir が分からない場合を含む)、codex がまだ foreground にいる、process-info で判定
  できない、のどれかなら、tab にも clone にも触らず `Blocked at: cleanup` とし、人に「tab `#<issue>` を
  確かめてください」と伝える (人の tab と、走っている worker を閉じない。一覧が読めないことを「0 件」と
  取り違えない)。
- orchestrator 自身がいる tab (`personal-codex-review` の review pane もここに置かれる) は、記録した
  tab ID と一致せず、pane の名前も `worker-<issue>` の形でないので、閉じる対象にならない。

### clone の確認 (まだ移さない)

```sh
# path の lstat の種類を出す。ENOENT だけを absent とし、権限エラーなどの失敗は非 0 で止める
# (test -e は「無い」と「確かめられない」を区別しない)
lstat_kind() {
  ruby -e 'begin
      s = File.lstat(ARGV[0])
      puts(s.symlink? ? "symlink" : s.directory? ? "dir" : "other")
    rescue Errno::ENOENT
      puts "absent"
    end' "$1"
}
clone=<§2 の置き場 (<main worktree>-clones/<issue>) の path の shell literal>
clone_root=
kind=$(lstat_kind "$clone") || exit 1
case "$kind" in
  absent) ;;                                   # 置き場に clone は無い (人が既に片付けた)。clone の確認を飛ばす
  dir)
    want=$(jq -er '.clone_root' "$prev_run/preflight.json") || exit 1
    clone_root=$(ruby -e 'puts File.realpath(ARGV[0])' "$clone") || exit 1   # 中に cd しない
    [ "$clone_root" = "$want" ] || exit 1      # 最後の run が検査した clone が、置き場の path の実体
    cleaned=${clone_root%/*}/.cleaned          # 退避先は同じ置き場の下 (§2 の <issue> と名前が衝突しない)
    dest=${cleaned}/${issue}-$(date -u +%Y%m%dT%H%M%SZ)
    ck=$(lstat_kind "$cleaned") || exit 1
    case "$ck" in absent|dir) ;; *) exit 1 ;; esac   # .cleaned が symlink や file なら移さない
    dk=$(lstat_kind "$dest") || exit 1
    [ "$dk" = absent ] || exit 1               # 退避先が既に在れば何もしない
    # worker の pane (worker-<issue>[-r<N>]) のどの foreground にも codex がいない (上の tab の確認で読んだ
    # $panes を、§5 の手順 1 と同じ読み方で見る)
    ;;
  *) exit 1 ;;                                 # symlink / file などは置き場の clone と確かめられない
esac
```

(`exit 1` は「その段で止めて、tab にも clone にも触らず `Blocked at: cleanup`」の意。)

- 置き場の path が無い (lstat が `ENOENT`) ときだけ clone の確認を飛ばす (移す clone は無い。tab の確認が通れば
  tab だけ閉じる)。lstat が権限エラーなどで失敗したときは「無い」と取り違えず止める。
- 置き場の path が symlink / directory でない、`last_run` の `preflight.json` が無い・読めない、`clone_root` が
  置き場の path の実体と一致しない (別の場所に切った clone を含む)、`.cleaned` が directory でない、退避先が既に
  在る・確かめられない、codex がまだ foreground にいる、herdr の一覧や process-info で判定できない、のどれかなら、
  tab にも clone にも触らず `Blocked at: cleanup` とし、人に「clone を確かめてください」と伝える。

### 片付ける (確認がすべて通った後)

```sh
if [ -n "$tab" ]; then herdr tab close "$tab" || exit 1; fi        # 0 件なら閉じる tab は無い
if [ -n "$clone_root" ]; then                                        # 置き場に無ければ移す clone は無い
  mkdir -p -- "$cleaned" || exit 1
  ruby -e 'File.rename(ARGV[0], ARGV[1])' "$clone_root" "$dest" || exit 1   # rename(2)。copy に倒さない
fi
```

(`exit 1` は「その段で止めて `Blocked at: cleanup`」の意。tab を閉じられなければ clone を移さない。rename が
失敗したら clone はそのまま残る (何も消さない)。どちらも、何が済んだかと退避先を返却に書く。)

- 移動は `mv` ではなく `rename(2)` (Ruby の `File.rename`) で行う。`mv` は移動先が directory だとその中へ移し、別の file system なら
  copy して元を消す。rename は別の file system (`EXDEV`)・中身のある directory や file が移動先にある・書けない、の
  どれでも失敗し、元の clone を残す (一時 dir で、中身のある directory・file・書けない `.cleaned` への rename が
  失敗して元が残ることを実測した)。確認と rename の間に空の directory が移動先に作られた場合だけは、その空の
  directory と置き換わる (失われる中身は無い)。
- honest-label: 消さないので、退避で失われるものは無い (commit、reflog、stash、index、未 commit の変更、ignored な
  file はすべて退避先に残る)。そのため、未回収の commit や未 commit の変更の確認はしない。disk は人が退避先を
  消すまで空かない。退避先の clone の `.git` は worker が書き換えうるので、人が中で git を実行する前に中身を
  確かめる。確認から rename までの間の差し替え (同じ user の権限による TOCTOU) は防がない (packet の `check` と
  同じ立場)。
