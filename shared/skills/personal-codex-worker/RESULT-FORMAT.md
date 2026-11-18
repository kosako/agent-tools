# personal-codex-worker — 返却形式 (RESULT-FORMAT)

`SKILL.md` §8 の契約を満たす雛形です。契約の正本は `SKILL.md`、雛形の正本はこの file。

worker が完了して packet を更新した場合:

```text
Status: DONE | REVIEW
Packet: #<issue> — 結果 "### <日付> worker/codex" を追記 / 次の入口を更新 / state: <open|review> / 起動の記録 (run / tab) を消して run dir を last_run に移した
PR: #<number> (REVIEW のとき。author=codex、review は Claude route)
Run dir: <path>
Commits: <n> (すべて Codex trailer)
```

worker は完了したが、受け入れ条件を満たさない場合 (転記の後。`SKILL.md` §7):

```text
Status: DONE
Packet: #<issue> — 結果 "### <日付> worker/codex" を追記 / 依頼に「修正 round N」を追記 / 次の入口を「修正 round N を実装する」に更新 / state: open / 起動の記録は転記で last_run に移した
Run dir: <path>
Next step: 修正 round N で再起動するか (§1 の authorization) を決める
```

RUNNING の場合 (実行中、待つ上限、または人手実行の完了待ち):

```text
Status: RUNNING
Tab: #<issue> / Pane: <pane id> / Run dir: <path> / Elapsed: <分> (分かるときだけ)
Next step: 生存は status だけでは確定しない。run script を再実行せず、人が tab、pane、process を確かめて続行か中断かを決める。
続行なら pane を監視して done.txt を待つ。中断なら worker の process を止めてから collect で停止を記録する (LAUNCH §10)。完了記録が無ければ LAUNCH §3 で記録の破棄を判断する
```

`Elapsed` は分かるとき (hard cap まで自分で待ったとき) だけ書き、`SKILL.md` §1 で見つけた run では推測で埋めない。

停止した場合 (転記の前。verdict は作らない):

```text
Status: BLOCKED
Blocked at: authorization | launch-record | preflight | launch-path | clone | executor-exit | executor-result | limit | transcription
Reason: <public-safe な停止理由>
Packet: #<issue> — <state の扱い (下記)> / 結果 "### <日付> orchestrator/claude" (書いた場合) / 起動の記録は残す (§1 で起動を見送ったときは、この Issue の記録はまだ無い)
Run dir: <path> / 退避: <path> (あれば)
Next step: docs/codex-worker-run.md の「停止後の state と回復 (正本)」の該当行から、人の次の手を書く。
launch-record: 人が生存と記録を確かめ、回収か破棄を判断する。open の破棄は理由を entry に書き worker-update stop、続いて launch。
clone: 人が停止の原因を確かめる。照合失敗なら変更を保存して clone 全体を退避する。終了後の open / run は破棄の判断後に stop、launch。既に blocked なら許可を確認して launch。退避の失敗だけなら原因を直して collect。
transcription: 人が診断 file を確かめる。更新済みなら再転記しない。本文を返却に写さない。
launch-path: 記録の有無と未起動を確認して hand-off、または人が tab と process を確かめる。
limit: reset を待ち、人が再開を判断する。
```

state は script の `packet.written` と、読み直した packet で確かめる。
`collect` が照合・退避・stop を終えた停止と、質問を stop で転記した場合は `state: blocked`。
1回目の空の結果 (`retryable: true`) は state と起動記録を保持する。
transcription、終了後の snapshot 照合、退避の失敗では、その停止を理由に state を変更しない。
書き込み後の読み直しで止まる場合もあるので、packet を確認して済んだ範囲を返す。
記録前の停止、人手実行待ち、生存を確かめられない停止も state を保持する。
run-start 後の停止なら open と新しい run が残る。branch の保存は packet.written に含まれない。
JSON と exit の対応は `SKILL.md` §8、停止後の state と回復は `docs/codex-worker-run.md` の正本の表を参照する。

開始時に `GH_REPO` が空でなければ、`Blocked at: preflight`、`Reason: GH_REPO が空でない`、
`Next step: GH_REPO を外して起動し直す` と返す。packet は書かず、今回は run dir と clone を作っていないと明記する。

転記の後に止まった場合 (回収・trailer 検査・公開する内容の gate・公開先の確認。`SKILL.md` §7):

```text
Status: BLOCKED
Blocked at: fetch | trailer | public-safety
Reason: <public-safe な停止理由>
Packet: #<issue> — 結果 "### <日付> worker/codex" を転記済み / stop は記録せず state: open (既に review なら保持) / 次の入口は触らない / 起動の記録は転記で last_run に移した
Run dir: <path>
Next step: <停止区分と理由、人の次の手、修正後に check をやり直すことを書く。fetch の失敗を人が調べる | fetch の前の照合が止めた .git の entry を、clone に git を実行する前に人が調べる | author が交代するなら新 branch + 新 PR に分ける | origin/main を人が確かめる | gate が止めた行を直す、または警告を人が確かめる>
```

公開先の slug の取得・検証や origin の push URL との照合が失敗したときは `Blocked at: public-safety`。
`Reason` は「公開先を確かめられない」、`Next step` は main の repo と origin の push URL を人が確かめること。

後始末モードでは、開始時の `GH_REPO` が空でない場合と、公開先を確かめられない場合も `Blocked at: cleanup`。
前者の `Reason` と `Next step` は開始時の停止と同じ。後者は main の repo と origin の push URL を人が確かめる。
packet や PR の確認より前に止まった場合、その状態は「確かめていない」と書く。

後始末モード (`SKILL.md` §9。人が明示したときだけ。packet は書かない):

```text
Status: CLEANED | BLOCKED
Blocked at: cleanup (BLOCKED のとき)
Reason: <確かめられなかったものとその理由 (BLOCKED のとき)>
Packet: #<issue> — state: <読んだ state (done / review / open / blocked) | packet を読めない> / PR #<number>: <読んだ状態 (MERGED / OPEN / CLOSED) と head の branch の一致 | 読めない | 確かめていない (packet の前提で止まった)> / packet は書かない (last_run は残す)
Tab: #<issue> — 閉じた | 無かった | 残した (<所有を確かめられない | codex が動いている | 一覧・process-info で判定できない | 2 件以上 | 前提か clone の確認が通らない | close の失敗>)
Clone: <clone path> — <退避先> に移した | 無かった | 残した (<置き場の path を確かめられない (lstat の失敗・symlink・directory でない) | last_run の preflight.json を読めない | 置き場の path の実体と clone_root が一致しない | .cleaned が directory でない | 退避先が既に在る・確かめられない | codex が動いている・判定できない | 前提か tab の確認が通らない | tab を閉じられなかった | rename の失敗>)
Next step: <退避先を人が確かめて消す (中で git を実行する前に .git を確かめる) | 残した理由に応じて人が確かめてから後始末をやり直す>
```

`CLEANED` は、前提・tab・clone の確認がすべて通り、tab を閉じて clone を退避先へ移した (無かったものは飛ばした)
とき。clone は消さない (退避先を消すのは人)。どれかの確認が通らなければ、tab にも clone にも触らず `BLOCKED`
(`Blocked at: cleanup`)。確認の後の close / rename が失敗したときも `BLOCKED` で、何が済んだかを Tab / Clone に書く。

worker の本文 (最終 message / diff / commit message) を停止結果へ転記しません。secret / 実 home
path / 外部 URL も同様です。この結果は委譲 process の判定であり、PR の merge readiness ではありません。
