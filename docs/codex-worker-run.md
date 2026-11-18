# Codex worker の起動と回収

`personal-codex-worker-run launch` は、packet の依頼から worker を起動します (#706)。
Ruby 2.6 の標準 library、git、herdr、codex と配備済み script を使います。
`launch`、`collect`、`retry-empty`、公開前の検査を行う `check` を実装しています。

起動の許可は caller が持つ現在の依頼で判断します。
packet の存在や本文だけで、委譲を始める許可があるとは扱いません。
GitHub への書き込みは、この command の範囲外です。
`check` は公開先と個人 project の判定に限り、gh で読み取ります。
現行 skill と `LAUNCH.md` の手順は、#706 の最後の PR まで使います。

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
| 0 | `STARTED` / `DONE` / `READY` | 起動の受付 / 完了の転記 / 公開前の検査の成功 |
| 1 | `BLOCKED` | 指定した段で停止した |
| 2 | `BLOCKED` | 入力が不正。成果物を作る前に停止した |
| 3 | `RUNNING` | 同じ Issue の worker が動いている / collect の待つ上限 / 人手実行の完了待ち |

起動に成功したときの key は `status`、`issue`、`run_dir`、`nonce`、`tab_id`、`pane_id`、
`pane_label`、`round_pane`、`packet` です。
`packet` は `{"written":true,"record":"run"}` です。
`STARTED` は起動の受付を示し、worker の完了や結果の正しさは示しません。

停止時は `status`、`blocked_at`、`reason_code`、`reason`、`issue`、`phase`、`packet` を返します。
run directory を作った後なら `run_dir` も返します。
`records` で同じ Issue の記録が原因なら、既存の run を `run_dir` に返します。
別の Issue の記録が原因なら、`other_issue` と `other_run_dir` にその番号と run を返します。
この場合は `run_dir` を返しません。
preflight の停止では `dependency_exit` に依存 command の exit を添えます。
起動できなかった場合や signal の場合は null です。
`packet.written` は起動記録や回収結果の書き込みを示します。先に保存した branch はこの値に含みません。
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
| `clone` | `clone` | `snapshot-untraceable`、`snapshot-mismatch`、`clone-command` |
| `commit-prerequisites` | `clone` | `commit-prerequisite`: identity または hook 配線を確認できない。`clone-command`: 起動時の HEAD を読めない |
| `preflight` | `preflight` | `preflight`、`launch-argv` |
| `run-location` | `launch-path` | `writable-run`: run が worker の書込先の外と確認できない |
| `artifacts` | `launch-path` | `io`: brief または run script の保存に失敗 |
| `run-record` | `launch-record` | `packet-update`、`run-record`、`packet-list` |
| `herdr` | `launch-path` | `herdr-response`、`tab-ownership`、`worker-running` |

file 操作などの予期しない失敗は、その段の区分で `io` を返します。
`RUNNING` には `blocked_at` を含めません。
起動時は `records` の `worker-running`、collect は `wait` の `wait-limit` または
`manual-completion-pending` です。
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
| SKILL §5、LAUNCH §6 | collect が完了記録を確認し、最大300秒ずつ待つ |
| LAUNCH §7 | collect が終了を判定し、生出力と残った process を確認。retry-empty が空の結果を1回だけ再実行 |
| SKILL §6、LAUNCH §8 | snapshot を照合し、結果を検査して転記。停止時は変更を退避して stop を記録 |

再利用 clone では、git を呼ぶ前に `last_run` の snapshot を照合します。
`state: blocked` の場合は `run` を使い、無ければ `last_run` を使います。
照合後の status は run directory の `clone-status.txt` に保存します。

`snapshot-untraceable` は、前の run または `preflight.json` を辿れない場合です。
`snapshot-mismatch` は、snapshot の照合 command が成功しなかった場合です。
後者では `.git` の変更も疑い、照合結果と前の run を人が調べます。
ただし、clone を作った後、起動の記録の前に止まった場合にも起こります。
この場合は、下の回復手順で clone の由来を確認します。
どちらも clone で git を実行する前に止まります。

照合 command が失敗すると、stderr を今回の `run_dir` の `snapshot-verify.txt` に保存します。
stdout の JSON には、その内容を載せません。人が照合をやり直す command は次のとおりです。

```text
personal-codex-worker-preflight --verify-git-snapshot <前の run>/preflight.json --clone <clone>
```

clone を作った後、起動の記録の前に止まると、その run が packet に残らない場合があります。
原因を直して再実行しても、残った clone の照合で止まります。
packet が前の run を指していなければ、`snapshot-untraceable` になります。
前の run を指していれば、その snapshot と新しい clone が異なるため `snapshot-mismatch` になります。
参照する記録は `last_run`、または `state: blocked` の `run` です。
参照先の `preflight.json` を辿れない場合は、`snapshot-untraceable` になります。
人は次の順に確認して回復します。

1. 停止時の `phase`、`reason_code`、`run_dir` を確認し、元の停止原因を直します。
2. packet の起動記録と herdr を調べ、該当 clone の worker が動いていないことを確かめます。
3. 残った clone の由来と、未回収の変更や commit の有無を確認します。
   snapshot が無い clone では、確認のために無条件で git を実行しません。
   判断できない内容は保持し、人が調査します。
4. 必要な内容を失わないよう、clone 全体を元の path の外へ退避します。
   不要と確認できた clone は、人の判断で削除することもできます。
5. 元の clone path が空いたら `launch` を再実行し、新規 clone を作ります。

script は clone の削除や作り直しを行いません。

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

## 起動の記録 (`launch.json`)

brief と run script を生成する段で、起動記録を書く前に `launch.json` を保存します。
herdr から ID が返ったら、一時 file と rename で更新します。
`collect` と `retry-empty` はこの JSON を読みます。run script は解析しません。

```json
{"schema":1,"issue":7,"branch":"feat/7-example","clone_root":"<clone>","nonce":"0123456789abcdef","tab_id":null,"pane_id":null,"pane_label":null,"round":null,"previous_run":null,"start_head":"<起動時の HEAD OID>","created_at":"2026-11-18T00:00:00Z"}
```

`schema` は整数の 1 です。`round` は指定した整数か null です。
`previous_run` は前の run directory か null です。
`start_head` は branch 解決後の clone の HEAD です。retry-empty でも今回の起動前に読み直します。
`clone_root` と run directory の値には、実際には絶対 path を保存します。
`tab_id`、`pane_id`、`pane_label` は未確定の間だけ null です。
再実行では、`retry_of` に1回目の run directory を追加します。
古い run に JSON が無ければ、回収は `no-launch-record` で止まります。

## collect の入力と出力

```text
personal-codex-worker-run collect --repo <main worktree の root> --issue <N> [--wait-minutes <M>]
```

対象は packet の `run` だけです。`--run-dir` は受け付けません。
待つ上限は1〜120分の整数で、既定は120分です。
完了記録があれば待たずに照合します。無ければ `wait-output` を最大300秒ずつ呼びます。
残り時間が300秒未満なら、その時間に timeout を縮めます。
wait-output が早く戻った場合は、呼び出しから15秒になるまで待ちます。
待機は上限までの残り時間で短縮します。herdr の即時失敗でも短周期の再試行を避けます。
改行で終わらない done.txt は書き込み中として待ちます。
process の消滅を確認した場合も、1秒待って完了記録を読み直してから停止を判定します。
端末の一致は起床の合図で、終了の判定には `done.txt` を使います。
process-info が失敗した場合や読めない場合は、worker の消滅と判断せずに待ちます。

完了時は exit 0 で、次の形を返します。

```json
{"status":"DONE","issue":7,"run_dir":"<run dir>","head_oid":"<HEAD OID>","commits_this_run":1,"redacted":false,"leftover":{"foreground":{"checked":true,"processes":[]},"clone_arguments":{"checked":true,"processes":[]}},"packet":{"written":true,"state":"open","record":"last_run"}}
```

`head_oid` は snapshot 照合後の clone の HEAD です。
`commits_this_run` は、clone 内の `start_head..HEAD` の commit 数です。
start_head が無い場合や clone 内に該当 commit が無い場合は null とし、転記を続けます。
collect は clone にも main にも fetch しません。
`leftover` は pane の shell 以外の process と、clone の path を引数に持つ process の観測です。
確認できない項目は `checked: false` だけを返します。観測結果は転記を妨げません。
残った process は pid と名前を返します。名前を確認できなければ name は null です。

待つ上限では exit 3、`status: RUNNING`、`reason_code: wait-limit` を返します。
`run_dir`、`pane_id`、`elapsed_minutes` と `packet.written: false` を含みます。
`RUNNING` に `blocked_at` は含めません。
process は止めず、packet を保持します。pane と tab は、成功と失敗のどちらでも閉じません。

`launch.json` の `pane_id` が null の run は、人手で run script を実行する経路です。
pane の rename または run が失敗した場合も、launch.json の pane_id を null に戻します。
作成済みの pane と tab は閉じず、pane-id と tab-id の file に記録を残します。
完了記録が無ければ即座に exit 3、`RUNNING`、`manual-completion-pending` を返します。
この場合も `blocked_at` は無く、packet は保持します。
完了記録があれば、pane.log と foreground の観測を省いて照合と転記へ進みます。
`leftover.foreground` は `{"checked":false}` です。

| status | reason_code | blocked_at | packet |
| --- | --- | --- | --- |
| RUNNING | wait-limit | key 無し | 書かない。待つ上限に達した |
| RUNNING | manual-completion-pending | key 無し | 書かない。pane が無く、人手実行の完了を待っている |

完了の転記は次の順です。

1. pane があれば生出力を `pane.log` に保存し、空でないことを確かめる。
2. 残った process を観測し、snapshot を照合する。
3. 最終 message の6つの見出しと順序、packet の予約構文が無いことを検査する。
4. public-safety gate に通し、必要なら home-path だけを置き換えて再検査する。
5. 停止理由の節が「なし」なら result として転記し、run から last_run への移動を読み直す。

見出しは `到達点`、`判断`、`未完`、`停止理由 または 質問`、`commits`、`次の 1 アクション` です。
それぞれ `### ` を付け、この順に1回ずつ必要です。
停止理由の「なし」の前後では、空白と句点を除いて比較します。
brief は、この節を orchestrator の判断待ちで作業を止める理由に限ります。
実行できなかった test や読めなかった process 一覧は「未完」に書きます。
止まらずに終えた場合は、停止理由に「なし」とだけ書きます。
置き換えの順序と path 境界は LAUNCH §8 と同じです。
原文を残して `result.redacted.md` を作り、転記 entry の先頭に注記を足します。
gate の stderr は `gate.err` に控えます。本文や診断の内容は stdout と stderr に出しません。

## collect の停止と packet

停止時は exit 1、`status: BLOCKED` です。理由は固定文です。

| blocked_at | reason_code | packet と退避 |
| --- | --- | --- |
| launch-record | no-launch-record / invalid-launch-record | 書かない。run や JSON が無い、または読めない |
| executor-exit | nonce-mismatch / done-invalid / executor-exit | snapshot 照合後に退避し、stop で blocked にする |
| limit | limit | 非0の exit と行頭の利用上限メッセージを確認後、照合・退避・stop を行う |
| executor-result | empty-result (retryable: true) | 1回目の空の結果。state と起動記録を保持する |
| executor-result | empty-result (retryable: false) | 2回目の空の結果。照合・退避・stop を行う |
| executor-result | worker-question (retryable: false) | 最終 message を worker/codex の stop として転記する |
| transcription | pane-log / result-format / gate | 書かない。生出力、書式、公開検査のいずれかで停止 |
| transcription | packet-update | worker-update が失敗したら書かない。exit 0 の応答が不正なら packet.written は true |
| transcription | run-record | result の書き込み後の読み直しが一致しない。packet.written は true |
| clone | snapshot-mismatch | clone で git を呼ばず、退避も packet の更新もしない |
| clone | backup | 退避が未完。backup_step に status / staged / unstaged / untracked を返し、packet は保持 |

`RESULT-FORMAT.md` の停止時の state 規則とは、次の点が異なります。
transcription で停止しても、それを理由に packet を blocked にする更新は行いません。
packet の更新前の停止なら、回収の再試行に備えて元の state と起動記録を保持します。
書き込み後に停止した場合は、packet.written を確認し、packet を読み直します。
終了後の snapshot 照合の失敗と退避の失敗でも、元の state と起動記録を保持します。

停止の退避は `wip-status.txt`、`wip-staged.patch`、`wip-unstaged.patch`、`wip-untracked.tar` に分けます。
各 command の成功を確認し、失敗した段で止めます。
snapshot の stderr は `snapshot-verify.txt` に保存します。
最終 message が書式と gate を通れば worker/codex の entry を使います。
通らなければ orchestrator/claude の固定文で、区分、exit、退避 file 名だけを記録します。
stop は run と tab を残します。

## retry-empty の入力と出力

```text
personal-codex-worker-run retry-empty --repo <main worktree の root> --issue <N>
```

packet の run が1回目で、nonce が一致し、exit 0 で結果が欠落または0 byte の場合だけ起動します。
対象外なら `launch-record` の `not-retryable` で止まり、packet を書きません。
新しい run directory と nonce を作り、元の snapshot で clone を照合してから preflight をやり直します。
brief は byte のまま写します。元の run directory は保持します。

`run-start` の `expected_run` に元の run を渡し、起動記録を新しい run に差し替えます。
tab の存在と元の `tab-id` との一致、pane の名前は、起動記録の書き換え前に確認します。
確認できなければ `launch-path` で止まり、元の run を保持します。
起動の段でも所有を再確認し、同じ tab に pane を足します。
成功時は launch と同じ `STARTED` の JSON で exit 0 です。
起動の共通段で止まった場合も、launch と同じ区分と packet.written を返します。

人手実行かどうかは、`launch.json` の `pane_id` が null であることで見分けます。
その1回目が空の結果で終わった場合、retry-empty は packet を変えずに止まります。
workspace の ID が無ければ `workspace`、herdr の応答を読めなければ `herdr-response` です。
動いている worker がいれば `worker-running`、それ以外は `tab-ownership` で止まります。
この workspace の検査と tab の検査の `blocked_at` は `launch-path` です。
先に別の Issue の未回収 run が見つかれば、起動と同じ `records` の区分で止まります。
この場合は LAUNCH.md §10 の人手の手順を続けます。
新しい run directory と nonce の run script を用意し、人に1回だけ渡して起動し直します。
元の script の再実行では代えません。この手順用の subcommand は追加しません。
手で作った新しい run には `launch.json` がありません。
その run を `collect` に渡すと、`launch-record` の `no-launch-record` で止まります。
回収も現行の人手の手順で行います。

結合検査は `scripts/tests/codex-worker-collect-test.sh` です。
launch の検査と fixture を共有し、herdr と codex は偽物を使います。
packet、snapshot の照合、public-safety gate の検出処理は実物で検査します。
一時 HOME の検査では、gate に渡す HOME の判定だけを fixture 用に差し替えます。

## check の入力と出力

```text
personal-codex-worker-run check --repo <main worktree の root> --issue <N> --title <題名> --body-file <file> [--accept-warnings]
```

対象は完了の転記後の `last_run` です。packet の state は `open` または `review` を受け付けます。
未回収の `run` がある、`last_run` が無い、state が対象外の場合は `launch-record` で止まります。
題名は空でない1行、本文は UTF-8 の空でない regular file にします。
本文の file は main と clone の外に置きます。symlink は受け付けません。
`GH_REPO` は空にします。herdr と codex は呼びません。

成功時は exit 0、stdout は次の JSON 1行です。

```json
{"status":"READY","issue":7,"branch":"feat/7-example","base_oid":"<base OID>","head_oid":"<head OID>","commits":2,"slug":"owner/repo","style_findings":0,"marker":"ok","run_dir":"<last_run>"}
```

`head_oid` は main に取り込んだ branch の tip です。以後の検査もこの OID に固定します。
`base_oid` は fetch 済みの `origin/main` と head の merge-base です。
`commits` はその範囲の commit 数で、0件は成功しません。
`style_findings` は題名と本文の文体の指摘数です。指摘だけでは止めません。
`marker` は個人 project の目印が通れば `ok`、対象外または判定不能なら `skipped` です。
`--accept-warnings` を付け、gate の警告を受け入れて成功した場合は `"accepted_warnings":true` も返します。
警告が無い場合は、この項目を返しません。

## check の段と停止

次の順で実行します。前の段で止まったら、後ろの段を呼びません。
失敗は exit 1、入力の誤りは exit 2 です。どちらも `BLOCKED` の JSON 1行を返します。
`reason` は固定文です。題名、本文、差分、外部 command の診断を出力に載せません。

| phase | blocked_at | reason_code と検査 |
| --- | --- | --- |
| input | authorization | `input`: 引数、main root、本文の形式と置き場 |
| environment | preflight | `gh-repo`: GH_REPO が空でない |
| packet | launch-record | `packet-check` / `packet-list` / `check-record`: packet と回収済み run |
| snapshot | fetch | `snapshot-mismatch`: last_run の preflight.json との照合 |
| fetch | fetch | `fetch`: clone から main への取り込み。non-fast-forward も拒否 |
| trailer | trailer | `trailer`: origin/main の fetch、base と head、全 commit の trailer |
| merge-commits | public-safety | `merge-commit` / `publish-material`: merge commit の有無 |
| style | public-safety | `style`: 文体検査の実行または応答の失敗 |
| publish-gate | public-safety | `publish-material` / `publish-gate` / `gate-warning`: 公開する材料と gate |
| destination | public-safety | `destination`: slug と origin の push URL |
| marker | public-safety | `marker`: 個人 project の PR の目印 |

予期しない file 操作などの失敗は、その段で `io` を返します。
snapshot の stderr は `last_run` の `snapshot-verify.txt` に保存します。
照合が通るまでは clone を git に渡しません。clone の `.git` に書き込む操作もありません。
取り込みは `git fetch --no-tags -- <clone> refs/heads/<branch>:refs/heads/<branch>` です。
refspec に `+` を付けず、main の checkout も変えません。

全 commit に `Codex` 始まりの trailer が1つ以上必要です。
`Claude` または `OpenCode` 始まりが混在していれば止まります。
NUL 区切りの git 出力は Ruby の string で読みます。
merge commit は、その差分の検査を省かないため、公開前に止めます。

文体検査には `personal-ja-style-check --stdin --json` を使います。
public-safety gate には累積差分、各 commit の差分、全 message、branch 名、題名と本文を渡します。
差分の取得には `--text --no-textconv --no-ext-diff` を指定します。
材料の git が1つでも失敗すれば、部分的な内容だけで gate を通しません。
git と gate の stderr は `gate-publish.err` に保存します。
既定では、gate の exit 0 に加え、`public-safety-gate: warning:` の行が無いことも必要です。
exit が 0 でなければ、warning や `--accept-warnings` の有無によらず `publish-gate` で止まります。
exit 0 で warning がある場合は、`--accept-warnings` が無ければ `gate-warning` で止まります。

`gate-warning` で止まったら、指揮役は `gate-publish.err` を人に見せます。
人が意図した内容だと確かめたときだけ、`--accept-warnings` を付けて `check` をやり直します。
指揮役は人の確認なしに、この option を付けません。
一度目の `check` が main に branch を取り込んでいても、同じ tip なら再度の取り込みは通ります。
warning を受け入れても、公開先と個人 project の目印の検査は行います。
`READY` を得た後、返された `head_oid` で下記の push の手順へ進みます。
これは現行の `LAUNCH.md` §9 と同じく、人が確認した警告で進む手順です。

題名と本文に修正が必要な場合は、その内容を直して `check` をやり直します。
commit の差分や message に修正が必要な場合は、履歴を書き換える必要があります。
各 commit の差分も検査するので、後続の commit で削除するだけでは警告は消えません。
書き換えた branch をそのまま取り込むと、main に取り込み済みの tip に対して non-fast-forward になります。
その場合、`check` は `fetch` で止まります。
人が対象と履歴を確認し、clone の branch と main の branch の ref を修正後の履歴に付け替えます。
この履歴の書き換えと ref の付け替えは、`check` と worker の範囲外です。
人の作業が終わってから、指揮役が `check` をやり直します。

公開先は main で `gh repo view --json nameWithOwner` を読み、slug の形を確認します。
origin の push URL は `LAUNCH.md` §9 の6形式のいずれかとの完全一致が必要です。
その後、`gh api user` と `gh api repos/<slug>` を GET で読みます。
owner.type が `User` で、owner.login が認証 user の login と一致した場合だけ目印を検査します。
目印には `personal-work-marker-check --kind pr --stdin` を使います。
owner を判定できない場合は `marker: skipped` とします。
公開先の判定が必要なので、この目印の検査は公開先の照合後に行います。

`check` は成功時も停止時も packet を変更しません。
停止したら指揮役が packet を読み直し、digest を得ます。
`personal-packet worker-update <N> --stdin` の `stop` で、停止区分と固定の理由を記録します。
`next` には今の `次の入口` の本文をそのまま渡し、worker の次の 1 アクションを保持します。
`expected_sha256` は読み直した値を使い、外部 command の生出力は転記しません。
`stop` の既存の前提は `state: open` です。
`review` で止まった場合は、許可された修正依頼を `round` で記録して open に戻してから行います。
依頼がまだ無ければ指揮役が判断し、前提を満たすためだけの依頼は作りません。

## check 後の指揮役の手順

1. `READY` の結果を読み、文体の指摘を直すか、そのままにする理由を持ちます。
   題名、本文、commit を直した場合は `check` をやり直します。
2. 別の呼び出しで、main から `git push origin <head_oid>:refs/heads/<branch>` を実行します。
   `head_oid` は `check` が返した full OID を使います。push が失敗したら PR を作りません。
3. 題名と本文を `personal-post-check` に通し、結果を読んでから PR を作ります。
   `gh pr create --repo <slug> --base main --head <branch> --title <題名> --body-file <file>` を使います。
   修正 round では既存 PR を使います。値は argv か shell literal で渡します。
4. packet を読み直して digest を得ます。
   `personal-packet worker-update <N> --stdin` の `review` で PR 番号を記録し、state を `review` にします。
   すでに `review` で PR 番号も一致する場合は、そのまま保持します。

これらの push、PR 作成、packet の更新は `check` の処理に含めません。
現行 skill の手順の切り替えは #706 の最後の PR で行います。

結合検査は `scripts/tests/codex-worker-check-test.sh` です。
launch と collect の fixture を共有し、一時 directory を cwd にして実行します。
packet、snapshot、文体、目印、public-safety の検出は実物を使います。
gh は許可した3つの読み取りだけを受け付ける偽物です。
