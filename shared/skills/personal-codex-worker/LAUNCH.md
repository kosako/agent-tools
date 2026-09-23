# personal-codex-worker — 実行手順 (LAUNCH)

`SKILL.md` §2〜§7 の契約 (clone / preflight / brief / 起動と完了判定 / 転記と退避 / 回収と trailer
検査) を満たすための機械的な手順です。契約の正本は `SKILL.md`、手順の正本はこの file。この file の
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

## 2. clone

main worktree から:

```sh
# 再開なら、この手順で作った既存 clone をそのまま使う (作り直さない)
[ -d "$clone/.git" ] && git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 \
  || git clone --quiet --no-hardlinks -- "$main" "$clone"

# branch: main 側に既にあれば その tip から、無ければ新規に切る
if git -C "$clone" rev-parse --verify --quiet --end-of-options "refs/heads/$branch" >/dev/null; then
  git -C "$clone" switch -- "$branch"
elif git -C "$clone" rev-parse --verify --quiet --end-of-options "refs/remotes/origin/$branch" >/dev/null; then
  git -C "$clone" switch -c "$branch" --no-track "refs/remotes/origin/$branch"
else
  git -C "$clone" switch -c "$branch"
fi
```

- **`--no-hardlinks` は必須**。local path からの `git clone` は既定で object を hardlink するため、
  clone 側の object / pack が main と同じ実体になり「main の Git 管理領域を worker に開けない」が
  成立しない (実測: 既定 clone は object の link 数 2、`--no-hardlinks` は 1)。再利用してよいのは
  **この手順で作った clone だけ**で、素性が不明なら作り直す。
- **branch は取り違えない**。main 側に同名 branch があると clone にも `origin/<branch>` として入って
  いるので、`switch -c` だけで作ると clone の既定 HEAD (main の default branch) から切ってしまい、
  既存の commit を含まない履歴で worker が始まる。上のように「local branch → `origin/<branch>` →
  新規」の順で分岐する。
- `$clone` は `<main worktree>-clones/<issue>` のように **main と同じ identity context の中**に切る
  (`SKILL.md` §3。context の外に切ると user.email が空になり、worker の commit が落ちる)。
- upstream は当てにしない (`--no-track` で作るのは新規分のみで、clone が最初に作った branch や
  再利用 branch の upstream は残る)。push は orchestrator が main から行うので、worker 側の upstream は
  使わない。
- clone の origin は main repository の path になる (worker に network は無い)。worker はここに
  push しない。commit の回収は orchestrator が §9 の fetch で行う。
- clone / switch が失敗したら `Blocked at: clone`。
- 既存 clone を再利用するときは、`git -C "$clone" status --porcelain` の結果を run dir に控えてから
  起動する (前 round の残りと、この round の変更を区別するため)。

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
preflight=<tool home>/agent-tools/scripts/personal-codex-worker-preflight
"$preflight" --clone "$clone" --json > "$run/preflight.json"; rc=$?
```

- rc が 0 以外なら停止 (`SKILL.md` §2)。exit 2 には clone の検査 (`<clone>/.git` が directory でない =
  linked worktree、orchestrator 自身の repository、git dir の不一致) も含まれる。`--add-dir` を自分で
  足して回避しない。
- honest-label: preflight の検査は **その時点の path** を見る。検査から起動までの間に `.git` を
  symlink へ差し替える competing write までは防げない (同じ path を使い回し、`clone_root` /
  `clone_git_dir` を preflight の出力から取ることで窓を狭めている)。clone は orchestrator が作った
  ものだけを使う。
- `launch_argv` には `--add-dir <clone>/.git` が 1 つ入る (sandbox は workdir の内側でも `.git` を
  保護するため)。`launch_argv` (配列) の `<run dir>/result.md` を実際の `"$run/result.md"` に
  置き換え、要素を run script に写す (§4)。
- `herdr` field が `running` でなくても、ここでは止めない (§2 と §4 の成果物を揃えてから §5 で
  `launch-path` にする)。

## 4. brief と run script

`brief.md` は `SKILL.md` §4 のとおり。run script は次の形で、`codex exec` の argv は
`preflight.json` の `launch_argv` を **そのまま** (要素ごとに literal 化して) 並べます。この例の
flag は 2026-09-22 時点の preflight が出す形で、手で編集しません。

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

# 3a. 0 件: tab を作る。ID は応答から読み (推測しない)、tab ID を run dir に記録する
herdr tab create --workspace "$ws" --cwd "$clone" --label "$label" --no-focus
#     tab  = .result.tab.tab_id / pane = .result.root_pane.pane_id
printf '%s\n' "$tab" > "$run/tab-id"

# 3b. 1 件で、所有を確かめられた (下記) とき: その tab の pane を 1 つ選んで分割し、
#     同じ tab ID を新しい run dir にも記録する (次の round と §11 が辿れるように)
herdr pane split --pane <その tab の pane-id> --direction down --cwd "$clone" --no-focus
#     pane = .result.pane.pane_id
printf '%s\n' "$tab" > "$run/tab-id"

# 4. 名前を付けて実行する
herdr pane rename "$pane" <worker-<issue> または worker-<issue>-r<N> の shell literal>
herdr pane run "$pane" <"zsh " + run script path の shell literal>
```

(`exit 1` は「その段で止めて `Blocked at: launch-path` にする」の意。)

- **所有の確認** (3b の前、§11 で閉じる前も同じ): 次の 2 つが**両方**成り立つ tab だけを、この skill
  が作った tab とみなします。pane を足したり tab を閉じたりしてよいのは、その tab だけです。
  1. **記録した ID**: 手順 2 で見つけた tab の ID が、同じ Issue の前の run の run dir に記録した
     `tab-id` と一致する。前の run dir が分かるのは、同じ orchestrator session の中か、packet の起動
     記録 (`run`、#315) から辿れるときだけです。分からない・file が無い・一致しない、はどれも
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
- honest-label (二重起動): 手順 1 が見えるのは herdr の pane で動いている worker だけです。
  `launch-path` の hand-off で人が自分の terminal から動かしている worker は herdr からは見えず、
  この確認では検出できません (この変更の前から同じ)。起動の記録を packet に残して起動前に確かめる
  仕組みは #315 で足します。それまでは、hand-off した run の `done.txt` を確かめる前に同じ Issue を
  起動し直さないことを orchestrator が守ります。
- **round**: 最初の起動は `worker-<issue>`、同じ tab に足す pane は `-r<N>` を付け、`<N>` は tab に
  ある worker pane の round の最大 + 1 (`worker-<issue>` を round 1 と数える)。固定名の pane を
  使い回さない。
- `pane run` の command は pane の shell が解釈するので、script path を pane shell 用に literal 化し、
  自分の shell 経由で `herdr` に渡すならもう 1 段 literal 化する (2 段)。
- 次のどれかなら `Blocked at: launch-path`。Next step は場合で分けます:
  - **走っている worker がいる** (手順 1): Next step は「pane <id> の worker の完了を待ってから、この
    skill で起動し直す」。run script を人に実行させない (二重起動になる)。
  - **tab を特定できない**: label が `#<issue>` の tab が 2 つ以上ある / 1 つあるが所有を確かめられ
    ない (別の session で作った tab で前の run dir が分からない場合を含む)。その tab には触らず、
    Next step は「人が `#<issue>` の tab を確かめ、不要なら閉じてから、この skill で起動し直す」
    (閉じれば手順 3a で新しい tab を作り、ID を記録し直す)。人が自分の terminal で run script を
    実行してもよい (§10)。
  - **起動できない**: herdr が `running` でない / `$HERDR_WORKSPACE_ID` が空 / 手順 0 の一覧の取得か
    形の確認に失敗した / 手順 1 の process-info で判定できない / tab create・split・rename・run の
    どれかが失敗した。clone と run script は揃っているので、Next step に
    `zsh <run script の shell literal>` と run dir を書く (人が自分の terminal で実行する。§10)。
    手順 1 を終えられていないときは、「同じ workspace で worker が走っていないことを確かめてから
    実行する」を添える。作りかけの tab は閉じない (人がその pane で run script を実行できる)。
- honest-label (所有): 記録した tab ID は、この skill が tab を作ったときの herdr の応答から取った値
  です。記録の置き場は run dir (orchestrator が `mktemp -d` で作る一時領域) で、worker の sandbox から
  書けないことまでは確かめていないので、ID の一致だけでは決めず命名の確認と両方を要求します。
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
- 120 分に達したら kill せず、`Status: RUNNING` で pane id / run dir / 経過時間を返す (§9)。
- 待っている間に `codex.log` に `You've hit your usage limit` が現れたら (前方一致)、process の
  終了を待ってから `Blocked at: limit`。

## 7. 完了後

- 続行条件 (`done.txt` の nonce 一致・`exit=0`、空でない `result.md`) を満たしたら §8 へ進む。
  **herdr 経由で起動した場合だけ**、その前に `herdr pane read <pane-id> --source recent-unwrapped
  --lines 200` の生出力を `<run dir>/pane.log` に保存し、空でないことを確認する。pane と tab は
  **閉じない** (tab は packet が `done` になるまで残し、§11 で閉じる)。人手実行 (§10 の未起動
  hand-off) には pane が無いので、pane.log の保存は行わず、同じ続行条件を確認して §8 へ進む。
- `exit=0` なのに `result.md` が欠落 / 空なら、新しい nonce で同じ run dir から 1 回だけ再実行
  (`run.zsh` の nonce を差し替える)。2 回目も空なら `Blocked at: executor-result`。
- `exit` が 0 以外 (limit を含む) / RUNNING / 空振りが尽きたときも、pane と tab を閉じない
  (調べられるように残す)。

## 8. 転記と退避

転記 (`SKILL.md` §6) の前に gate に通す:

```sh
<tool home>/agent-tools/scripts/personal-public-safety-gate --stdin < "$run/result.md"
```

exit 0 のときだけ packet に写す。退避は clone で、staged / unstaged / untracked を別々に:

```sh
git -C "$clone" status --porcelain=v1 --untracked-files=all > "$run/wip-status.txt"
git -C "$clone" diff --cached --binary > "$run/wip-staged.patch"
git -C "$clone" diff --binary > "$run/wip-unstaged.patch"
git -C "$clone" ls-files --others --exclude-standard -z \
  | tar -C "$clone" --null -T - -cf "$run/wip-untracked.tar"
```

- `--cached` と作業ツリーの diff を分けるのは、stage 後に作業ツリーだけ戻した変更を落とさない
  ため。`--binary` で binary も復元できる形にする。
- untracked は file 名を shell に通さず、NUL 区切りの list を `tar --null -T -` に渡す (bsdtar は
  list の名前を option として解釈しない。GNU tar なら `--verbatim-files-from` を足す)。
  untracked が無ければ tar は作らない。
- 退避した path を packet の `結果` に書く。`git stash` は使わない (clone の状態を動かさない)。

## 9. 回収 (fetch) と trailer 検査と PR

worker の commit は clone の中にしかないので、まず main へ取り込みます (network 不要。clone は
main の local path)。fetch は **branch を明示した refspec** で行い、失敗したら `Blocked at: fetch`
(clone の中で検査して push、はしない。push する repository は main 側の設定に閉じる)。

```sh
git -C "$main" fetch --no-tags -- "$clone" "refs/heads/${branch}:refs/heads/${branch}" || exit 1
```

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

commit ごとに trailer の name を見て、`Codex` 始まりが 1 つ以上あり `Claude` 始まりが無いことを
確認する (欠落 / 混在は `Blocked at: trailer`。1 commit でも該当すれば push しない。commit が
0 件なら push するものが無いので同じく停止)。判定の正本は `personal-review-request` の「レビュアーの
決定」と ai-trailer gate で、ここでは push 前の消費側検査として同じ規則を当てる。通ったら:

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
  や口頭報告だけで完了とみなさない。
- **起動済み (`RUNNING`)**: worker はまだ生きている。run script を再実行させない。Next step は
  「tab `#<issue>` の pane <id> を見て続行か中断かを決める」だけ。続行なら人が pane を監視して
  `done.txt` を待つ。中断なら人が pane の process を止めてから §8 の退避に進む。

## 11. tab の後始末 (packet が done になったとき)

worker の tab を閉じるのは、PR が merge されて packet が `done` になったときだけです (clone を片付ける
のと同じ時点。`SKILL.md` §3)。`blocked` の間と RUNNING の間は、調べられるように残します。

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
# 1 件で、§5 の所有の確認 (最後の run dir の tab-id との一致 + 命名) を通り、
# その tab のどの pane の foreground にも codex がいないときだけ
herdr tab close <tab-id>
```

(`exit 1` は「その段で止めて閉じない」の意。)

- 0 件なら何もしない (人が既に閉じた)。一覧の取得か形の確認に失敗した、2 件以上、所有を確かめられ
  ない (最後の run dir が分からない場合を含む)、codex がまだ foreground にいる、process-info で判定
  できない、のどれかなら閉じずに、人に「tab `#<issue>` を確かめて閉じてください」と伝える (人の tab
  と、走っている worker を閉じない。一覧が読めないことを「0 件」と取り違えない)。
- orchestrator 自身がいる tab (`personal-codex-review` の review pane もここに置かれる) は、記録した
  tab ID と一致せず、pane の名前も `worker-<issue>` の形でないので、閉じる対象にならない。
