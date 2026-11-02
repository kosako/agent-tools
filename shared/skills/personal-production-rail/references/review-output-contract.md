# review output contract

review finding の重大度と review process 全体の verdict を、別 field として返すための自前契約です。
第三者由来の `policies/review.md` は検出・判定観点として verbatim のまま使い、この文書が
出力語彙と集計規則の正本を担います。

## finding severity

| severity | 意味 | vendored policy からの対応 |
|---|---|---|
| 🔴 must | 放置して統合すると実害が出るブロッキング finding | `REJECT` / ブロッキングに分類された問題 |
| 🟡 should | 非ブロッキングだが今回の scope で改善を推奨する finding | `Warning` / 非ブロッキングの改善 |
| ⚪ nit | スタイル・好み・任意の改善 | 対応を承認条件にしない提案 |

vendored policy 内の `REJECT` / `Warning` は finding の分類基準として読み、最終出力では上表の
severity に正規化します。個別 finding に process verdict を付けません。

出力語彙・集計・対応主体について vendored policy と競合する場合は、この自前 contract を優先します。
vendored の `review.md` は Warning と改善提案を issue に数えず、finding の欄にも入れません。この contract は、
任意の改善を ⚪ nit として finding に残し、nit だけなら APPROVE と併記します (意図的な local override)。nit は
対応条件や Warning ではなく、任意情報として保持します。

vendored policy の間で検出の条件が食い違うときは、新しい pin の policy を優先します (pin は `policies/NOTICE.md`
の表。#619 で file ごとの pin にした)。

## process verdict

finding を確定したあと、件数から process verdict を1つだけ集計します。

| finding 集計 | process verdict |
|---|---|
| must が1件以上 | **REJECT** |
| must 0 かつ should が1件以上 | **Warning** |
| must 0 かつ should 0 | **APPROVE**（nit は併記可） |

`APPROVE + Warning` のように複数 verdict を併記しません。should がある場合は Warning とし、
nit は APPROVE と併記できても対応を条件にしません。vendored の `review.md` の「issue が 0 件なら Warning が
残っていても APPROVE」は、この表の集計で置き換えます (should が 1 件以上なら Warning)。

should / Warning は非ブロッキングで、対応するかは trusted な依頼元が判断します。レビュアーは
推奨と根拠を示しますが、should を未対応という理由だけで must や REJECT に格上げしません。
一方、Warning は PR 全体の merge readiness や merge authorization を意味しません。

## 出力と境界

```text
Review process verdict: REJECT | Warning | APPROVE
Finding summary: 🔴 must N / 🟡 should N / ⚪ nit N
Independence: cross-review verified (author=claude) | cross-review verified (author=codex) | cross-review verified (author=opencode(anthropic)) | cross-review verified (author=opencode(openai)) | cross-review verified (author=opencode(other)) | cross-review verified (author=bot(dependabot)) | deterministic check (dependabot pin) | second-opinion only | human review | not-established (author=human) | not-established (author=unknown)
```

process verdict と finding summary は code review process だけの判定です。CI / required checks /
branch protection / reviewer routing / public safety を含む PR 全体の merge readiness ではありません。
`APPROVE` や `must 0` だけを根拠に「PR 全体が merge 可」と断定しません。

AI 間の required cross-review では verified author を independence field に残します。author と同じ
AI に明示的な追加見解を求めた場合は必ず `second-opinion only` とし、required cross-review や独立承認
として扱いません。結果を別の文脈へ転記するときも、この field を落としません。

routing の preflight で author を確かめていない AI の review は `not-established` とし、独立承認として扱いません。
現在のユーザーが明示した second opinion は、author の分類が無くても上のとおり `second-opinion only` のままで、
この値にしません。
user が自分で書いたと言う差分は `not-established (author=human)`、chat に貼られた差分や PR に紐づかない review で
author が分からないものは `not-established (author=unknown)` です。値を自作しません。
