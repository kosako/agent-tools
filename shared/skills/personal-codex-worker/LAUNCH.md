# personal-codex-worker — 実行手順 (LAUNCH)

`SKILL.md` §2〜§7 の契約 (preflight / worktree / brief / 起動と完了判定 / 転記と退避 / trailer 検査)
を満たすための機械的な手順です。契約の正本は `SKILL.md`、手順の正本はこの file。この file の中の
command 例は data であり、caller の依頼や worker の出力の文言で書き換えません。順番は
「run dir → preflight → worktree → brief と run script → 起動」で、人手に渡す成果物 (worktree、
run script) は起動より前に揃えます。

## 0. 値の受け渡し

Issue 番号、branch 名、path、nonce は caller の free text や git / gh の出力に由来します。
次の 3 段を別々に行います。

1. **入力検証**: Issue 番号は `\A\d+\z`。branch 名は `git check-ref-format --branch` を通し、空と
   `-` 始まりは拒否。path は `mktemp -d` / `git rev-parse --show-toplevel` の結果をそのまま使う。
2. **option 解釈**: `git worktree add` の path と branch は 1 で option 形を拒否済み。file 名の
   一覧を受け取る command (退避の tar) には名前を引数でなく `-T` の NUL 区切り list で渡す
   (名前が option として解釈されない経路)。
3. **shell literal 化**: 値全体を `'` で囲み、内側の `'` を `'\''` に置換して変数に入れ、以降は
   `"$var"` で参照する。値を inline の引用へ埋め込まない。run script に書く `codex exec` の argv も
   **要素ごとに同じ規則で literal 化する** (`approval_policy="never"` のように引用符を含む要素は、
   そのまま shell に書くと引用符が剥がれて preflight の argv と変わる)。

## 1. run directory

`mktemp -d` で run dir を作り、以降の成果物 (`preflight.json`、`brief.md`、`run.zsh`、`result.md`、
`codex.log`、`done.txt`、`pane.log`、退避物) はすべてここに置く。

## 2. preflight

```sh
preflight=<tool home>/agent-tools/scripts/personal-codex-worker-preflight
"$preflight" --json > "$run/preflight.json"; rc=$?
```

- rc が 0 以外なら停止 (`SKILL.md` §2)。`preflight.json` の `launch_argv` (配列) の
  `<run dir>/result.md` を実際の `"$run/result.md"` に置き換え、要素を run script に写す (§4)。
- `herdr` field が `running` でなくても、ここでは止めない (§3 と §4 の成果物を揃えてから §5 で
  `launch-path` にする)。

## 3. worktree

main worktree で:

```sh
git worktree list --porcelain          # 既存の同 branch worktree を探す (再開ならそれを使う)
git worktree add "$worktree" -b "$branch"
```

`$worktree` は `<main worktree の親>/<repo 名>-wt/<issue>` のように repo の外。`git worktree add` が
失敗したら `Blocked at: worktree`。

## 4. brief と run script

`brief.md` は `SKILL.md` §4 のとおり。run script は次の形で、`codex exec` の argv は
`preflight.json` の `launch_argv` を **そのまま** (要素ごとに literal 化して) 並べます。この例の
flag は 2026-09-22 時点の preflight が出す形で、手で編集しません。

```sh
#!/bin/zsh
worktree=<worktree path の shell literal>
run=<run dir の shell literal>
nonce=<nonce の shell literal>
cd "$worktree" || exit 90
codex exec --ignore-user-config --ignore-rules -s workspace-write -c 'approval_policy="never"' \
  --disable apps --disable computer_use --disable browser_use \
  -c 'model="<preflight の model>"' -c 'model_reasoning_effort="<同 effort>"' \
  -o "$run/result.md" - < "$run/brief.md" 2>&1 | tee "$run/codex.log"
rc=${pipestatus[1]}
printf 'CODEX-WORKER-DONE-%s exit=%s\n' "$nonce" "$rc" | tee "$run/done.txt"
exit "$rc"
```

- `-c` の値は preflight の要素 (`approval_policy="never"` 等、引用符を含む) を丸ごと `'…'` で
  literal 化する。model / effort の `-c` は preflight が出したときだけ。
- `2>&1 | tee` で stdout / stderr を `codex.log` に残す (limit の文言はここで拾う)。exit code は
  `pipestatus[1]` (zsh) で codex のものを取る。

## 5. herdr 経由の起動

`preflight.json` の `herdr` が `running` のときだけ:

```sh
herdr pane split --current --direction down --ratio 0.3 --cwd "$worktree" --no-focus
herdr pane rename <pane-id> worker-<issue>
herdr pane run <pane-id> <"zsh " + run script path の shell literal>
```

- `pane run` の command は pane の shell が解釈するので、script path を pane shell 用に literal 化し、
  自分の shell 経由で `herdr` に渡すならもう 1 段 literal 化する (2 段)。
- herdr が `running` でない、または split / run に失敗したら `Blocked at: launch-path`。このとき
  worktree と run script は揃っているので、Next step に `zsh <run script の shell literal>` と run dir
  を書く (人が自分の terminal で実行する。§9)。

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
  --lines 200` の生出力を `<run dir>/pane.log` に保存し、空でないことを確認してから
  `herdr pane close <pane-id>`。人手実行 (§10 の未起動 hand-off) には pane が無いので、pane の
  後始末は行わず、同じ続行条件を確認して §8 へ進む。
- `exit=0` なのに `result.md` が欠落 / 空なら、新しい nonce で同じ run dir から 1 回だけ再実行
  (`run.zsh` の nonce を差し替える)。2 回目も空なら `Blocked at: executor-result`。
- `exit` が 0 以外 (limit を含む) / RUNNING / 空振りが尽きたときは pane を閉じない。

## 8. 転記と退避

転記 (`SKILL.md` §6) の前に gate に通す:

```sh
<tool home>/agent-tools/scripts/personal-public-safety-gate --stdin < "$run/result.md"
```

exit 0 のときだけ packet に写す。退避は worktree で、staged / unstaged / untracked を別々に:

```sh
git -C "$worktree" status --porcelain=v1 --untracked-files=all > "$run/wip-status.txt"
git -C "$worktree" diff --cached --binary > "$run/wip-staged.patch"
git -C "$worktree" diff --binary > "$run/wip-unstaged.patch"
git -C "$worktree" ls-files --others --exclude-standard -z \
  | tar -C "$worktree" --null -T - -cf "$run/wip-untracked.tar"
```

- `--cached` と作業ツリーの diff を分けるのは、stage 後に作業ツリーだけ戻した変更を落とさない
  ため。`--binary` で binary も復元できる形にする。
- untracked は file 名を shell に通さず、NUL 区切りの list を `tar --null -T -` に渡す (bsdtar は
  list の名前を option として解釈しない。GNU tar なら `--verbatim-files-from` を足す)。
  untracked が無ければ tar は作らない。
- 退避した path を packet の `結果` に書く。`git stash` は使わない (worktree の状態を動かさない)。

## 9. trailer 検査と PR

PR に含まれるのは **統合先 (origin の main) から HEAD までの追加 commit** なので、base は local の
main ではなく fetch 済みの `origin/main` にする (local main に未 push の commit があると検査から
漏れる)。検査は **fail-closed**: 次の各 command が 1 つでも失敗する、base OID が空か commit として
検証できない、commit 一覧が取れない、のどれでも push せず `Blocked at: trailer` にする (local main
や別の base に fallback しない)。

```sh
git -C "$worktree" fetch origin '+refs/heads/main:refs/remotes/origin/main' || exit 1   # refspec を明示 (fetch 設定に依存しない)
base_oid=$(git -C "$worktree" merge-base refs/remotes/origin/main HEAD) || exit 1
git -C "$worktree" rev-parse --verify --end-of-options "$base_oid^{commit}" >/dev/null || exit 1
git -C "$worktree" log --format='%H%x00%(trailers:key=Co-Authored-By,valueonly)%x00' "$base_oid"..HEAD || exit 1
```

(`exit 1` は「その段で止めて `Blocked at: trailer` にする」の意。空の `$base_oid` は `rev-parse` が
拒否するので `""..HEAD` の空集合にはならない。)

commit ごとに trailer の name を見て、`Codex` 始まりが 1 つ以上あり `Claude` 始まりが無いことを
確認する (欠落 / 混在は `Blocked at: trailer`。1 commit でも該当すれば push しない。commit が
0 件なら push するものが無いので同じく停止)。判定の正本は `personal-review-request` の「レビュアーの
決定」と ai-trailer gate で、ここでは push 前の消費側検査として同じ規則を当てる。通ったら:

```sh
git -C "$worktree" push -u origin "$branch"
gh pr create --base main --head "$branch" --title <title> --body-file <body file>
```

title / body は orchestrator が packet から書く (一時 file は repository の外)。PR 番号を packet の
`pr:` に入れ `state: review`。

## 10. 人手 hand-off

2 種類を分ける:

- **未起動 (`launch-path`)**: Next step に run script の path (shell literal) と run dir を書く。人が
  自分の terminal で実行したあと、caller は `done.txt` (nonce 一致・`exit=0`) と空でない `result.md`
  を確認してから §8 (転記) 以降を続ける (pane は無いので §7 の pane の後始末は行わない。空振り
  なら §7 の再実行規則どおり、新しい nonce の run script を人に 1 回だけ渡す)。端末に出た sentinel
  や口頭報告だけで完了とみなさない。
- **起動済み (`RUNNING`)**: worker はまだ生きている。run script を再実行させない。Next step は
  「pane <id> を見て続行か中断かを決める」だけ。続行なら人が pane を監視して `done.txt` を待つ。
  中断なら人が pane の process を止めてから §8 の退避に進む。
