# Codex worker の起動

`personal-codex-worker-run launch` は、packet の依頼から worker を起動します (#706)。
Ruby 2.6 の標準 library、git、herdr、codex と配備済み script を使います。
現在実装している subcommand は `launch` だけです。
`collect`、`retry-empty`、`check` は後の PR で追加します。

起動の許可は caller が持つ現在の依頼で判断します。
packet の存在や本文だけで、委譲を始める許可があるとは扱いません。
GitHub の読み書き、結果の回収、公開前の検査はこの command の範囲外です。
現行 skill と `LAUNCH.md` の手順は、この PR では切り替えません。

## 入力

```text
personal-codex-worker-run launch --repo <main worktree の root> --issue <N> [--branch <名前>] [--round <K>]
```

- `--repo` は git の main worktree の root の絶対 path です。
- `--issue` と `--round` は正の整数です。
- branch は packet の値を使います。値が無いときは `--branch` が必須です。
  両方に値があれば一致が必要です。新しく指定した branch は `worker-update branch` で保存します。
- `--round K` は brief の冒頭に、修正 round K の項だけを実装する旨を足します。
  pane の番号は tab 内の最大番号から決めるため、この値とは独立です。
- `GH_REPO` は空、`HERDR_WORKSPACE_ID` は起動する workspace の ID とします。

同じ実体の directory に `personal-packet` と `personal-codex-worker-preflight` が必要です。
hook dispatcher と public-safety、git-identity、ai-trailer の各 gate も同じ配置で検査します。
これらは拡張子なしの名前で解決します。JSON の解析に jq は使いません。

## 出力

通常の stdout は JSON 1 行です。`--help` のみ使い方を表示します。
理由は固定文で、packet の依頼、外部 command の stderr、例外本文は出しません。

| exit | status | 意味 |
| --- | --- | --- |
| 0 | `STARTED` | herdr の pane run が成功した |
| 1 | `BLOCKED` | 指定した段で停止した |
| 2 | `BLOCKED` | 入力が不正。成果物を作る前に停止した |
| 3 | `RUNNING` | 同じ Issue に未完了の起動記録があり、worker の生存を確認した |

成功時の key は `status`、`issue`、`run_dir`、`nonce`、`tab_id`、`pane_id`、
`pane_label`、`round_pane`、`packet` です。
`packet` は `{"written":true,"record":"run"}` です。
`STARTED` は起動の受付を示し、worker の完了や結果の正しさは示しません。

停止時は `status`、`blocked_at`、`reason_code`、`reason`、`issue`、`phase`、`packet` を返します。
run directory を作った後なら `run_dir` も返します。
preflight の停止では `dependency_exit` に依存 command の exit を添えます。
起動できなかった場合や signal の場合は null です。
`packet.written` は起動記録の書き込みを示します。先に保存した branch はこの値に含みません。
herdr の失敗を含め、書いた起動記録と作成済みの file は削除しません。

## 段と停止の区分

前の段で止まったときは、後ろの段を実行しません。
`phase` は止まった処理、`blocked_at` は skill の停止区分です。

| phase | blocked_at | 主な reason_code と意味 |
| --- | --- | --- |
| `input` | `authorization` | `input`: 引数や main worktree の指定が不正 |
| `environment` | `preflight` | `gh-repo`: GH_REPO が空でない |
| `packet` | `authorization` / `launch-record` | `packet-missing`、`request-empty`、`packet-state` / `packet-check`、`packet-list` |
| `records` | `launch-record` / `launch-path` | `collect-required`、`run-unconfirmed`、`run-missing` / `worker-running` |
| `workspace` | `launch-path` | `workspace`、`herdr-response`、`worker-running` |
| `branch` | `authorization` / `launch-record` | `branch` / `packet-update` |
| `run-directory` | `launch-path` | `run-directory`: run の置き場を作れない |
| `clone` | `clone` | `snapshot`、`clone-command` |
| `commit-prerequisites` | `clone` | `commit-prerequisite`: identity または hook 配線を確認できない |
| `preflight` | `preflight` | `preflight`、`launch-argv` |
| `run-location` | `launch-path` | `writable-run`: run が worker の書込先の外と確認できない |
| `artifacts` | `launch-path` | `io`: brief または run script の保存に失敗 |
| `run-record` | `launch-record` | `packet-update`、`run-record`、`packet-list` |
| `herdr` | `launch-path` | `herdr-response`、`tab-ownership`、`worker-running` |

file 操作などの予期しない失敗は、その段の区分で `io` を返します。
`RUNNING` の場合は `records` の `worker-running` です。
同じ Issue の記録を先に検査するため、別の Issue の worker と区別できます。

## 現行手順との対応

正本の手順は [SKILL.md](../shared/skills/personal-codex-worker/SKILL.md) と
[LAUNCH.md](../shared/skills/personal-codex-worker/LAUNCH.md) です。

| 手順 | command の処理 |
| --- | --- |
| SKILL §1、LAUNCH §0 | 引数、packet の依頼と state、既存 run と workspace の生存確認 |
| LAUNCH §1 | state directory の `agent-tools/worker-runs` を mode 700 にし、`<issue>.XXXXXX` を作る |
| LAUNCH §2 | `<main root>-clones/<issue>` の snapshot を git 実行前に照合。無ければ `--no-hardlinks` で clone |
| LAUNCH §2 の branch | local branch、origin の同名 branch、新規の順で解決。新規は main で fetch した origin/main の tip |
| LAUNCH §2 の commit 前提 | identity、main と同じ実体の hook directory、実行可能な hook と隣の gate を確認 |
| LAUNCH §3 | preflight JSON を保存。launch_argv と run directory の境界を確認 |
| SKILL §4、LAUNCH §4 | 依頼を byte のまま brief に写し、固定の指示と最終 message の見出しを足す |
| LAUNCH §4 の起動記録 | digest を前提に run-start を実行し、list の成功と記録の一致を確認 |
| LAUNCH §5 | Issue tab を作成、または所有確認した既存 tab の最初の pane を下に分割して起動 |

再利用 clone では、git を呼ぶ前に `last_run` の snapshot を照合します。
`state: blocked` の場合は `run` を使い、無ければ `last_run` を使います。
照合後の status は run directory の `clone-status.txt` に保存します。

`preflight.json`、`brief.md`、`run.zsh`、`tab-id`、`pane-id` を run directory に保存します。
`run.zsh` は preflight の argv を要素ごとに shell literal 化します。
置き換える値は `<run dir>/result.md` だけです。flag の追加や削除はしません。
実行時は `codex.log` に stdout と stderr を残します。
codex の exit を zsh の `pipestatus[1]` で取り、16 桁 hex の nonce とともに `done.txt` に書きます。

run directory が clone、`/tmp`、`$TMPDIR` の実体の内側なら起動しません。
既存 tab の確認には、前の run の `tab-id` と pane の名前の両方を使います。
tab や pane を閉じる操作は持ちません。

この確認は現在の packet と herdr の観測に基づきます。同時に複数の caller を起動する lock ではありません。
起動記録のない外部 terminal の worker や、snapshot の照合中の差し替えまでは証明しません。

## 検証

`scripts/tests/codex-worker-run-test.sh` は一時の main と origin を使います。
packet と preflight は実装を配備と同じ名前で配置し、herdr と codex は偽物に置き換えます。
run script の実行、特殊文字を含む path、snapshot、起動記録、停止後の非実行を検証します。
本物の herdr、codex、GitHub には接続しません。
