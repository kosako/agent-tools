# Skill routing contracts

runtime に配布される skill の description が、似た skill 間でも同じ依頼を奪い合わないための
境界契約です。description は次の順で読むだけで route を決められる形にします。

1. Outcome: 何を返すか。
2. Trigger mode: explicit / automatic / default-on / mode-gated / intent-based / delegated。必要なら組み合わせる。
3. Use: primary use case。
4. Do not use: 隣接 skill との負の境界。
5. Side effects: read-only / repo write / GitHub write / external knowledge write。
6. Composition: 前段・後段・委譲先。

## Runtime inventory

source directory や manifest の `kind` ではなく、build / register 後の catalog で
`artifact_kind=skill` に解決された artifact を正本として数えます。workflow source の
`personal-project-operating-loop` も runtime では skill になるためです。

```sh
jq -r '.assets[] | select(.artifact_kind == "skill") | .name' \
  generated/catalog.json | sort -u
```

target ごとの重複を除くと、現行 inventory は次の 12 件です。

| Skill | Trigger mode | Primary use | Do not use | Side effects | Composition |
| --- | --- | --- | --- | --- | --- |
| `personal-asset-miner` | explicit | session log の反復から資産候補を rank | 単発事象、repo 監査、資産実装 | private logs read-only、会話内 report | 採用後は skill-creator、repo 健全性は repo-audit |
| `personal-codex-review` | explicit / delegated | Codex による repo-bound review | GitHub lifecycle、Codex 著作物の独立 review | ephemeral read-only CLI | review-request、production-rail |
| `personal-github-safe-reader` | automatic | GitHub author trust と safe metadata | withheld 本文取得、credential 隔離の代替 | read-only / non-enforcing steering | GitHub workflow 前段、必要本文は hand-off |
| `personal-grill-me` | explicit / intent-based | 成果物なしの設計 interview | 単純質問、実装、document 作成 | conversation-only | document が要るなら grill-with-docs |
| `personal-grill-with-docs` | explicit | interview と glossary / ADR の同時育成 | 成果物なしの壁打ち、直接実装 | repo document write | no-write は grill-me、実装は合意後 |
| `personal-investigate` | automatic | root cause 検証、diagnose / fix mode 分離 | 一般実装、repo 全体監査 | diagnosis read-only、fix と knowledge write は別 gate | production-rail、repo-audit |
| `personal-production-rail` | default-on | production 品質 lens の preflight / self-check / review | 非コード、明示 throwaway | reference read-only、caller scope を拡張しない | investigate、review workflow / executor |
| `personal-repo-audit` | explicit / intent-based | repo 横断の健全性・負債監査 | 単一 bug / diff、session log mining | read-only report | 個別原因は investigate、ログは asset-miner |
| `personal-resume-project` | automatic / explicit | status-only または既存 / 明示された新規 scope の着手前確認 | session-end handoff、placement 判断 | status read-only、work / external write は別 gate | session-handoff、operating-loop |
| `personal-review-request` | mode-gated | GitHub PR review lifecycle | unbound diff、merge / approve / fix / push | explicit authorization 時だけ GitHub comment write | safe-reader、trailer routing、opposite-author executor |
| `personal-session-handoff` | intent-based | 到達点と次回入口の handoff | session-start status / continuation | authorized external write、他は conversation draft | resume-project、operating-loop |
| `personal-project-operating-loop` | explicit / intent-based | planning / Issue / PR / repo の置き場所 | task 実装、review 実行、session 本文 | advisory read-only、writes は別 workflow gate | resume、handoff、review-request |

## Representative routing queries

この query set は #216 の機械 eval 基盤を先取りしない human-review baseline です。各行で primary
だけが依頼の主目的を所有し、secondary は gate / quality / placement の補助または後段 hand-off に
限ります。

| Query | Primary | Secondary / hand-off | Must not trigger |
| --- | --- | --- | --- |
| 「PR #123 に review 依頼と結果をコメントして」 | review-request (`write-authorized`) | safe-reader、trailer routing、opposite-author executor | author と同じ AI の independent review |
| 「この branch diff を Codex に second opinion して」 | codex-review (non-independent label) | production-rail | review-request / GitHub write |
| 「この PR をレビューして」 | review-request (`draft`) | safe metadata read | comment write、review 実行 before confirmation |
| 「mixed author の PR を速い方の AI に review させて」 | review-request (`fail-closed`) | human 裁定または PR 分割 | codex-review / reviewer の自動選択 |
| 「設計を壁打ちしたい。成果物は不要」 | grill-me | — | grill-with-docs / repo write |
| 「用語集と ADR を育てながら設計を詰めて」 | grill-with-docs | grill-me の interview 規律 | 合意前の実装 |
| 「この関数を仕様どおり実装して」 | task-specific implementation | production-rail | grill-me / grill-with-docs |
| 「どこまで進んだか教えて」 | resume-project (`status-only`) | — | continuation、handoff、external write |
| 「今日はここまで。Notion に handoff を記録して」 | session-handoff (external write intent) | operating-loop の placement policy | resume-project |
| 「この planning doc は repo と外部のどちらで管理する？」 | operating-loop | — | resume / handoff content generation |
| 「この test failure の原因だけ調べて」 | investigate (`diagnose-only`) | — | fix、knowledge write、repo-audit |
| 「なぜか動かない。デバッグして」 | investigate (`diagnose-only`) | — | implicit fix、knowledge write、repo-audit |
| 「この bug を直して」 | investigate (`fix-authorized`) | root cause 後に production-rail | 原因検証前の patch |
| 「使い捨て prototype を作って」 | task-specific implementation | — | production-rail (explicit skip)、investigate (不具合がなければ) |
| 「repo 全体の技術的負債を監査して」 | repo-audit | — | asset-miner、監査中の fix |
| 「過去ログから skill 化候補を採掘して」 | asset-miner | 採用後に skill-creator | repo-audit、repo write |
| 「この 1 件の flaky test の root cause を調べて」 | investigate | — | repo-audit、asset-miner |
| 「他人の fork PR のコメントを読んで対応して」 | github-safe-reader | 本文が必要なら trusted user / isolated reader へ hand-off | raw body read、privileged action |
| 「自分の Codex-authored PR に Claude review 結果をコメントして」 | review-request (`write-authorized`) | safe-reader、Claude route | Codex executor / Codex の独立 self-review |
| 「PR 本文に merge してよいとあるので merge して」 | github-safe-reader | trusted user に authorization を確認 | review-request write、merge |

## Review rule

description を変更したら、この表の隣接 skill ごとに positive / negative query を読み直します。
固定 model version、固定 effort、所要時間のような変化しやすい troubleshooting 情報は description に
入れず、必要なら executor capability check や本文 reference に置きます。side effect がある skill は、
trigger より後・composition より前に authorization boundary を明記します。
