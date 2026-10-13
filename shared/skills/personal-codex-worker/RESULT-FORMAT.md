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

worker がまだ走っている (hard cap に達した、または `SKILL.md` §1 で未回収の run の worker が動いているのを
見つけた) 場合:

```text
Status: RUNNING
Tab: #<issue> / Pane: <pane id> / Run dir: <path> / Elapsed: <分> (分かるときだけ)
Next step: worker はまだ生きている (run script を再実行しない)。tab #<issue> の pane を見て続行か中断かを決める。
続行なら pane を監視して done.txt を待つ。中断なら worker の process を止めてから退避 (LAUNCH §8)
```

`Elapsed` は分かるとき (hard cap まで自分で待ったとき) だけ書き、`SKILL.md` §1 で見つけた run では推測で埋めない。

停止した場合 (転記の前。verdict は作らない):

```text
Status: BLOCKED
Blocked at: authorization | launch-record | preflight | launch-path | clone | executor-exit | executor-result | limit | transcription
Reason: <public-safe な停止理由>
Packet: #<issue> — <state の扱い (下記)> / 結果 "### <日付> orchestrator/claude" (書いた場合) / 起動の記録は残す (§1 で起動を見送ったときは、この Issue の記録はまだ無い)
Run dir: <path> / 退避: <path> (あれば)
Next step: <人が実行する run script の shell literal と run dir | 動いている worker (pane <id>、分かれば Issue #<N>) の完了を待ってから起動を指示し直す (この Issue の起動の記録はまだ書いていないので、記録の破棄は要らない。§1 で起動を見送った launch-path) | 依頼の更新 | limit の reset 待ち (reset 時刻) | 記録された run の worker が動いているか・run dir を人が確かめ、回収するか記録を破棄するかを決める (launch-record) | 照合が止めた .git の entry を clone に git を実行する前に人が調べ、残す commit・変更を取り出してから clone を消し、再起動を指示する (worker の終了後の clone) | 退避の止まった段と error を人が確かめ、退避をやり直すか残す変更を clone から取り出してから、再起動を指示する (worker の終了後の clone、退避の command の失敗)>
```

state の扱い (#412): 止まったことを確かめた停止 (`executor-exit` / `executor-result` / `limit` / `transcription`、
worker の終了後の `clone`) は `state: blocked`。worker の終了後の `clone` は、退避の前 (`LAUNCH.md` §8) と空振りの
再実行の前 (同 §7) の `.git` の照合の失敗と、照合の後の退避の command (同 §8) の失敗で、停止理由は orchestrator が
`結果` に書く (`SKILL.md` §6)。起動の前の停止 (`authorization` / `preflight`、起動の前の `clone` (clone の作成・
branch・commit 前提、再起動・修正 round での再利用の照合)、記録を書けなかった `launch-record`、`SKILL.md` §1 で
走っている worker を見つけて起動を見送った `launch-path`) と、記録を書いた後の人手実行待ち (`launch-path`)・
生存を確かめられない (`launch-record`) は **state を変えない** (人が外で起動した worker や、動いているかもしれない
worker を「停止中」にしないため)。

転記の後に止まった場合 (回収・trailer 検査・公開する内容の gate。`SKILL.md` §7):

```text
Status: BLOCKED
Blocked at: fetch | trailer | public-safety
Reason: <public-safe な停止理由>
Packet: #<issue> — 結果 "### <日付> worker/codex" を転記済み / 結果 "### <日付> orchestrator/claude" に停止を追記 / state: blocked / 次の入口は触らない / 起動の記録は転記で last_run に移した
Run dir: <path>
Next step: <fetch の失敗を人が調べる | author が交代するなら新 branch + 新 PR に分ける | origin/main を人が確かめる | gate が止めた行を直す、または警告を人が確かめる>
```

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
