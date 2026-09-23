# personal-codex-worker — 返却形式 (RESULT-FORMAT)

`SKILL.md` §8 の契約を満たす雛形です。契約の正本は `SKILL.md`、雛形の正本はこの file。

worker が完了して packet を更新した場合:

```text
Status: DONE | REVIEW
Packet: #<issue> — 結果 "### <日付> worker/codex" を追記 / 次の入口を更新 / state: <open|review> / 起動の記録 (run / tab) を消した
PR: #<number> (REVIEW のとき。author=codex、review は Claude route)
Run dir: <path>
Commits: <n> (すべて Codex trailer)
```

worker がまだ走っている (hard cap) 場合:

```text
Status: RUNNING
Tab: #<issue> / Pane: <pane id> / Run dir: <path> / Elapsed: <分>
Next step: worker はまだ生きている (run script を再実行しない)。tab #<issue> の pane を見て続行か中断かを決める。
続行なら pane を監視して done.txt を待つ。中断なら worker の process を止めてから退避 (LAUNCH §8)
```

停止した場合 (verdict は作らない):

```text
Status: BLOCKED
Blocked at: authorization | launch-record | preflight | launch-path | clone | executor-exit | executor-result | limit | fetch | transcription | trailer
Reason: <public-safe な停止理由>
Packet: #<issue> — state: blocked / 結果 "### <日付> orchestrator/claude" (書いた場合) / 起動の記録は残す
Run dir: <path> / 退避: <path> (あれば)
Next step: <人が実行する run script の shell literal と run dir | 依頼の更新 | limit の reset 待ち (reset 時刻) | 新 branch + 新 PR | 記録された run の worker が動いているか・run dir を人が確かめ、回収するか記録を破棄するかを決める (launch-record)>
```

worker の本文 (最終 message / diff / commit message) を停止結果へ転記しません。secret / 実 home
path / 外部 URL も同様です。この結果は委譲 process の判定であり、PR の merge readiness ではありません。
