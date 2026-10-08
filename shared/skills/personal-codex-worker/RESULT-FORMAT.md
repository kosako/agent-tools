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

worker がまだ走っている (hard cap) 場合:

```text
Status: RUNNING
Tab: #<issue> / Pane: <pane id> / Run dir: <path> / Elapsed: <分>
Next step: worker はまだ生きている (run script を再実行しない)。tab #<issue> の pane を見て続行か中断かを決める。
続行なら pane を監視して done.txt を待つ。中断なら worker の process を止めてから退避 (LAUNCH §8)
```

停止した場合 (転記の前。verdict は作らない):

```text
Status: BLOCKED
Blocked at: authorization | launch-record | preflight | launch-path | clone | executor-exit | executor-result | limit | transcription
Reason: <public-safe な停止理由>
Packet: #<issue> — <state の扱い (下記)> / 結果 "### <日付> orchestrator/claude" (書いた場合) / 起動の記録は残す
Run dir: <path> / 退避: <path> (あれば)
Next step: <人が実行する run script の shell literal と run dir | 依頼の更新 | limit の reset 待ち (reset 時刻) | 記録された run の worker が動いているか・run dir を人が確かめ、回収するか記録を破棄するかを決める (launch-record)>
```

state の扱い (#412): 止まったことを確かめた停止 (`executor-exit` / `executor-result` / `limit` / `transcription`) は
`state: blocked`。起動の前の停止 (`authorization` / `preflight` / `clone`、記録を書けなかった `launch-record`) と、
記録を書いた後の人手実行待ち (`launch-path`)・生存を確かめられない (`launch-record`) は **state を変えない**
(人が外で起動した worker や、動いているかもしれない worker を「停止中」にしないため)。

転記の後に止まった場合 (回収・trailer 検査。`SKILL.md` §7):

```text
Status: BLOCKED
Blocked at: fetch | trailer
Reason: <public-safe な停止理由>
Packet: #<issue> — 結果 "### <日付> worker/codex" を転記済み / 結果 "### <日付> orchestrator/claude" に停止を追記 / state: blocked / 次の入口は触らない / 起動の記録は転記で last_run に移した
Run dir: <path>
Next step: <fetch の失敗を人が調べる | author が交代するなら新 branch + 新 PR に分ける | origin/main を人が確かめる>
```

worker の本文 (最終 message / diff / commit message) を停止結果へ転記しません。secret / 実 home
path / 外部 URL も同様です。この結果は委譲 process の判定であり、PR の merge readiness ではありません。
