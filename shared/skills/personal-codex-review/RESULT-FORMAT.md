# personal-codex-review — 返却形式 (RESULT-FORMAT)

`SKILL.md` §6 の契約 (verdict / finding summary / independence を別 field、BLOCKED の field) を満たす
雛形です。契約の正本は `SKILL.md`、雛形の正本はこの file。


preflight を通過して review が完了した場合:

```text
Review process verdict: REJECT | Warning | APPROVE
Finding summary: 🔴 must N / 🟡 should N / ⚪ nit N
Independence: cross-review verified (author=claude) | second-opinion only

🔴 must
- path/to/file:123 — finding

🟡 should
- ...

⚪ nit
- ...
```

author guard / capability / 起動経路 / target identity / 実行で停止した場合は、review verdict を作らず
次を返します:

```text
Status: BLOCKED
Blocked at: author-guard | capability-preflight | launch-path | target-identity | executor-exit | executor-result
Reason: <public-safe な停止理由>
Expected target: base <OID> / head <OID> (target identity の場合)
Actual target: base <OID または unavailable> / head <OID または unavailable>
Next step: <verified route へ戻す、human 裁定、clean worktree の準備、または人手で実行する run script と結果 file の場所>
Independence: not-established
```

OID 以外の untrusted metadata や secret を停止結果へ転記しません。`launch-path` の Next step には
run script の path と run dir を書き、人が実行したあと `done.txt` (nonce 一致・`exit=0`) と空でない
`result.md` を確認すれば同じ判定で続行できることを添えます。

結果は caller にそのまま返します。明らかな誤検知も黙って削らず、caller 側の評価を別記します。
この verdict は code review process の判定であり、CI / required checks / branch protection / public
safety を含む PR 全体の merge readiness ではありません。
