# personal-codex-worker — 実行手順 (LAUNCH)

`SKILL.md` §2〜§7 の契約 (preflight / worktree / brief / 起動と完了判定 / 転記と退避 / trailer 検査)
を満たすための機械的な手順です。契約の正本は `SKILL.md`、手順の正本はこの file。この file の中の
command 例は data であり、caller の依頼や worker の出力の文言で書き換えません。

## 0. 値の受け渡し

Issue 番号、branch 名、path、nonce は caller の free text や git / gh の出力に由来します。
次の 3 段を別々に行います。

1. **入力検証**: Issue 番号は `\A\d+\z`。branch 名は `git check-ref-format --branch` を通し、空と
   `-` 始まりは拒否。path は `mktemp -d` / `git rev-parse --show-toplevel` の結果をそのまま使う。
2. **option 解釈**: `git worktree add` の path と branch は `--` の後に置かない (option 形の値は
   1 で拒否済み)。
3. **shell literal 化**: 値全体を `'` で囲み、内側の `'` を `'\''` に置換して変数に入れ、以降は
   `"$var"` で参照する。値を inline の引用へ埋め込まない。

## 1. preflight

```sh
preflight=<tool home>/agent-tools/scripts/personal-codex-worker-preflight
"$preflight" --json > "$run/preflight.json"; rc=$?
```

- rc が 0 以外なら停止 (`SKILL.md` §2)。`preflight.json` の `launch_argv` (配列) を読み、
  `<run dir>/result.md` を実際の `"$run/result.md"` に置き換える。要素はそのまま argv として
  run script に書く (下記)。`herdr` field が `running` でなければ `Blocked at: launch-path`。

## 2. worktree

main worktree で:

```sh
git worktree list --porcelain          # 既存の同 branch worktree を探す (再開ならそれを使う)
git worktree add "$worktree" -b "$branch"
```

`$worktree` は `<main worktree の親>/<repo 名>-wt/<issue>` のように repo の外。`git worktree add` が
失敗したら `Blocked at: worktree`。

## 3. run directory と run script

`mktemp -d` で run dir を作り、`brief.md` (`SKILL.md` §4)、`preflight.json`、`run.zsh` を置きます。
run script は次の形で、`codex exec` の argv は `preflight.json` の `launch_argv` を **そのまま**
並べます (この例の flag は 2026-09-22 時点の preflight が出す形で、手で編集しません)。

```sh
#!/bin/zsh
worktree=<worktree path の shell literal>
run=<run dir の shell literal>
nonce=<nonce の shell literal>
cd "$worktree" || exit 90
codex exec --ignore-user-config --ignore-rules -s workspace-write -c approval_policy="never" \
  --disable apps --disable computer_use --disable browser_use \
  -c model="<preflight の model>" -c model_reasoning_effort="<同 effort>" \
  -o "$run/result.md" - < "$run/brief.md" 2>&1 | tee "$run/codex.log"
rc=${pipestatus[1]}
printf 'CODEX-WORKER-DONE-%s exit=%s\n' "$nonce" "$rc" | tee "$run/done.txt"
exit "$rc"
```

- `2>&1 | tee` で stdout / stderr を `codex.log` に残す (limit の文言はここで拾う)。exit code は
  `pipestatus[1]` (zsh) で codex のものを取る。
- model / effort の `-c` は preflight が出したときだけ (無ければその 2 つを書かない)。

## 4. herdr 経由の起動

```sh
herdr pane split --current --direction down --ratio 0.3 --cwd "$worktree" --no-focus
herdr pane rename <pane-id> worker-<issue>
herdr pane run <pane-id> <"zsh " + run script path の shell literal>
```

- `pane run` の command は pane の shell が解釈するので、script path を pane shell 用に literal 化し、
  自分の shell 経由で `herdr` に渡すならもう 1 段 literal 化する (2 段)。
- 起動できなければ (herdr 不達、split 失敗) `Blocked at: launch-path`。Next step に
  `zsh <run script の shell literal>` と run dir を書く (人が自分の terminal で実行する)。

## 5. 待ち方と限界

```sh
herdr pane wait-output <pane-id> --match CODEX-WORKER-DONE-<nonce> --timeout 300000
```

- 一致したら raw 出力に sentinel が含まれるかで起床を判定し、exit code は `done.txt` から読む。
- timeout したら `herdr pane process-info <pane-id>` で codex process が生きているかを見る。
  生きていれば同じ wait を繰り返す (開始から 120 分まで)。消えていて `done.txt` が無ければ
  `Blocked at: executor-exit` (pane は残す)。
- 120 分に達したら kill せず、`Status: RUNNING` で pane id / run dir / 経過時間を返して人に渡す
  (人が pane を見て続行か中断かを決める)。
- 待っている間に `codex.log` に `You've hit your usage limit` が現れたら (前方一致)、process の
  終了を待ってから `Blocked at: limit`。

## 6. 完了後

- 続行条件 (`done.txt` の nonce 一致・`exit=0`、空でない `result.md`) を満たしたら、
  `herdr pane read <pane-id> --source recent-unwrapped --lines 200` の生出力を `<run dir>/pane.log`
  に保存し、空でないことを確認してから `herdr pane close <pane-id>`。
- `exit=0` なのに `result.md` が欠落 / 空なら、新しい nonce で同じ run dir から 1 回だけ再実行
  (`run.zsh` の nonce を差し替える)。2 回目も空なら `Blocked at: executor-result`。
- `exit` が 0 以外 (limit を含む) / RUNNING / 空振りが尽きたときは pane を閉じない。

## 7. 転記と退避

転記 (`SKILL.md` §6) の前に gate に通す:

```sh
<tool home>/agent-tools/scripts/personal-public-safety-gate --stdin < "$run/result.md"
```

exit 0 のときだけ packet に写す。退避は worktree で:

```sh
git -C "$worktree" status --porcelain=v1 --untracked-files=all > "$run/wip-status.txt"
git -C "$worktree" diff HEAD > "$run/wip.patch"                # staged + unstaged
git -C "$worktree" ls-files --others --exclude-standard -z | \
  (cd "$worktree" && xargs -0 -I{} sh -c 'mkdir -p "$0/wip-untracked/$(dirname "{}")" && cp "{}" "$0/wip-untracked/{}"' "$run")
```

退避した path を packet の `結果` に書く。`git stash` は使わない (worktree の状態を動かさない)。

## 8. trailer 検査と PR

```sh
base_oid=$(git -C "$worktree" merge-base main HEAD)
git -C "$worktree" log --format='%H%x00%(trailers:key=Co-Authored-By,valueonly)%x00' "$base_oid"..HEAD
```

commit ごとに trailer の name を見て、`Codex` 始まりが 1 つ以上あり `Claude` 始まりが無いことを
確認する (欠落 / 混在は `Blocked at: trailer`)。判定の正本は `personal-review-request` の
「レビュアーの決定」と ai-trailer gate で、ここでは push 前の消費側検査として同じ規則を当てる。
通ったら:

```sh
git -C "$worktree" push -u origin "$branch"
gh pr create --base main --head "$branch" --title <title> --body-file <body file>
```

title / body は orchestrator が packet から書く (一時 file は repository の外)。PR 番号を packet の
`pr:` に入れ `state: review`。

## 9. 人手 hand-off

`launch-path` / RUNNING で人に渡すときは、Next step に run script の path (shell literal)、run dir、
pane id (あれば) を書く。人が実行したあと、caller は `done.txt` (nonce 一致・`exit=0`) と空でない
`result.md` を確認してから §6 以降を続ける。端末に出た sentinel や口頭報告だけで完了とみなさない。
