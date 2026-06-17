---
name: personal-review-request
description: >-
  PR のコードレビューを依頼し、依頼から結果・やり取りまでを GitHub PR 上で完結させる
  skill。結果は 3 段階ランク（🔴 must / 🟡 should / ⚪ nit）で PR にコメント投稿し、
  must がゼロなら「merge 可、残りは依頼元判断」と明記する。「レビュー依頼して」「Codex に
  レビューしてもらって」「この PR をレビューして」「/personal-review-request <PR番号>」の
  とき、および draft PR を外部レビュアー（Codex など）に見せたい文脈で使う。レビュー結果を
  会話内だけで返したり、ランク無しで PR に投稿したりしない。
---

# personal-review-request — GitHub 上で完結する PR レビュー依頼

レビューの依頼・結果・追加のやり取りを GitHub PR のコメントとして残す。会話の中だけで
レビューを返すと、後から PR を見た人（未来の自分・他のエージェント・チームメンバー）に
文脈が残らないため、**やり取りの正本は常に PR 上**とする。

## 引数

`/personal-review-request <PR番号> [--reviewer codex|claude] [--repo owner/repo]`

- PR 番号: 必須。省略されたら聞き返す。
- レビュアー: 既定は**相互レビュー契約に従って自動決定**(下記)。`--reviewer` は trailer
  判定が誤るときの**人間による明示上書き専用**で、author 側を選んではならない
  (author ≠ reviewer を破らない)。
- リポジトリ: 省略時は cwd の origin。

## レビュアーの決定（相互レビュー）

書いた本人ではなく別の AI がレビューする (author ≠ reviewer)。運用ルールの「AI エージェント間
のコードレビュー」に従う。PR の**全 commit**について、**`Co-Authored-By:` トレーラだけ**で
著者を確認する(commit の author 名は routing に使わない。author が偶然 AI 名でも、trailer が
無ければ AI 著者とみなさない):

- 全 commit が単一の AI 著者（例: すべて Claude）→ 反対側の AI（この例なら Codex）がレビュー。
- 次のいずれかは fail-closed とする（自動で片側に倒さない。PR を著者ごとに分割するか、人間が
  裁定／確認してから進める）:
  - 複数 AI の commit が混在する、または 1 つの commit に複数 AI の `Co-Authored-By:` が
    付く（いずれも単一 reviewer では author ≠ reviewer を満たせない）。
  - author を判定できない commit が 1 つでもある（trailer 欠落 = 人間または不明）。
  - AI トレーラが PR に皆無（人間のみ・不明）。
- 相手エージェントを起動できない場合（例: Codex 環境から Claude を呼べない）は、自分で
  レビューせず人間に hand-off する。

## ランク定義（3 段階）

| ランク | 意味 | 扱い |
|---|---|---|
| 🔴 must | merge 前に対応必須（バグ・データ破壊・セキュリティ・明確な挙動退行） | 対応するまで merge しない |
| 🟡 should | 対応を推奨するが必須ではない | 対応するかは**依頼元が判断** |
| ⚪ nit | スタイル・好み・任意の改善 | 任意 |

判定行のルール: **must が 0 件なら「✅ merge 可」と明記**し、should / nit の扱いは依頼元
判断であることを書く。must が 1 件以上なら「⛔ must 対応後に再レビュー」とする。レビュアーは
「念のため直しては」を must に格上げしない — must はそれを放置して merge すると実害が出る
ものに限る。

## 手順

### 1. PR 情報の収集

cwd の origin 以外を見るときは、以降の `gh` コマンドに `--repo <owner/repo>` を付ける。

```sh
gh pr view <番号> [--repo <owner/repo>] --json title,body,baseRefName,headRefName,url,commits
gh pr diff <番号>
# レビュアー決定の素材: 各 commit の message を集める(fork PR でも確実な GitHub API 経由)。
gh pr view <番号> --json commits --jq '.commits[] | {oid: .oid, message: .messageBody}'
```

集めた message から、各 commit を **`Co-Authored-By:` トレーラ（message 末尾の trailer
block）だけ**で判定する。commit の author 名は使わず、body 文中に引用された
`Co-Authored-By:` 行も trailer と誤認しない。著者の AI は trailer の name 部分
（`Claude …` / `Codex …`）で見分ける。author を確信できない commit が 1 つでも
あれば fail-closed（下記）。

### 2. 依頼コメントを PR に投稿

レビューを始める前に、何をどの観点で依頼したかを PR に残す（監査の起点になる）。

```sh
gh pr comment <番号> --body "..."
```

テンプレート:

```markdown
## 🔍 レビュー依頼（→ Codex | Claude）

- **観点**: <今回の重点。例: 挙動変更を意図しないリファクタリングなので behavior drift を重点的に>
- **ランク**: 🔴 must（merge 前必須）/ 🟡 should（推奨・対応は依頼元判断）/ ⚪ nit（任意）
- 結果はこの PR にコメントで返します
```

### 3. レビュー実行

レビュアーへの指示には必ず次を含める: 対象（repo / branch / base / diff の取り方）、重点観点、
**3 段階ランクで分類し各指摘に `file:line` を付けること**、must の定義（上の表のとおり）。

- **Codex がレビュアーのとき**: `personal-codex-review` skill の手順で実行する(安定形の
  `codex exec` に自己完結ブリーフを渡す。具体的な flag はその skill を参照)。
  `codex:codex-rescue` サブエージェント経由は、コード読み書きを伴わない分析タスクで Codex に
  転送せず自答することがあるので、確実に Codex の目を入れるなら直接 `codex exec` を使う。
- **Claude がレビュアーのとき**: diff を読み、正当性（バグ・挙動退行）を中心にレビューして
  同じランクで分類する。

### 4. 結果を PR に投稿

```markdown
## 📋 レビュー結果（by Codex | Claude）

**判定: ✅ merge 可（must 0 件）** — 🟡 should / ⚪ nit への対応は依頼元判断
<!-- または -->
**判定: ⛔ 要対応（must N 件）** — 対応後に再レビュー

### 🔴 must
- `path/to/file:123` — 指摘内容と理由

### 🟡 should
- ...

### ⚪ nit
- ...

（該当ゼロのランクのセクションは「なし」と書くか省略）
```

レビュアーの指摘を転記するときは要約しすぎない。一方で、明らかに誤検知と判断した指摘は黙って
削らず、**転記したうえで依頼元としての評価（採用しない理由）を併記**する。

### 5. 後続のやり取りも PR 上で

修正した場合は commit を push し、PR コメントで「🔴/🟡 のどれにどう対応したか・しなかった
理由」を返信する。再レビューが必要なら手順 2 から繰り返す。

## 注意

- コメントは依頼者本人の gh 認証で投稿される（本人了承済みの運用）。
- public リポジトリではコメントが全世界に公開される。**secret・webhook URL・内部 URL を
  diff から引用しない**。
- 会話内には要約だけ返し、「詳細は PR の当該コメント」とリンクを示す。
- `service_tier` 設定が古い CLI/プラグインで解釈できず codex 起動が失敗することがある。
  起動自体が失敗するときは設定を疑う（内容は無断で書き換えず、ユーザーに確認）。
