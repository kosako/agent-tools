---
name: personal-codex-review
description: 別モデル (Codex / GPT-5.x) に diff や PR を実際にレビューさせ、安定して結果を得るための skill。「Codex にレビューさせて」「codex でこの差分/PR を見て」「second opinion を Codex で」「codex review が固まる/返ってこない」のときに使う。要点は codex exec の foreground 単独実行(background 化すると stall する)。レビューの依頼と結果を GitHub PR 上で完結させたいときは personal-review-request(役割が違う)。
---

# personal-codex-review

別モデルの目 (Codex / GPT-5.x) で diff や PR をレビューさせ、結果を安定して取得するための
手順。**この repo がどこにあっても**(任意の repository で)使える。

## いつ使うか

- 自分 (Claude) が書いたコードを相互レビューに出すとき。どちら側がレビュアーになるかは
  運用ルールの「AI エージェント間のコードレビュー (相互レビュー)」に従う
  (author ≠ reviewer、判定は commit の `Co-Authored-By:` トレーラ)。
- second opinion / 設計レビューを別モデルに求めたいとき。

## 安定した呼び方 (重要)

`codex exec` を直接呼ぶ。安定して返すために、次の2点を守る:

```sh
codex exec --skip-git-repo-check \
  -s read-only \
  -c approval_policy="never" \
  -c model_reasoning_effort="medium" \
  "$(cat /tmp/review-brief.md)"
```

- **foreground で実行する(detach / background しない)。** stall の主因はこれ。観測上、
  codex exec の呼び出しが background 化・detach されると返らなくなる(観測では
  16 分以上 stall した)。同じ呼び出しを foreground で実行すると数秒〜数分で返る。
  複合コマンドの末尾に埋めると wrapper に background 化されることがあるので、
  **`codex exec` は単独コマンドで呼ぶ**。
- **`-c approval_policy="never"` を付ける。** 併発要因の対策。ローカル設定が
  `approval_policy = "on-request"` だと、codex がファイル読取/コマンド実行で承認を要求し、
  非対話 / TTY なしでは誰も承認できず待ち続ける。`never` で override すると承認待ちで
  止まらない。
- `-s read-only`: repo を**読ませて**実装と突き合わせた検証レビューができる
  (書き込みはさせない)。
- `-c model_reasoning_effort="medium"`: 既定の `xhigh` は遅い。review 用途は medium で十分。
- グローバルの `approval_policy` は対話 codex の安全装置なので**変えない**。
  レビュー時にこの呼び出しで override する。

## 手順

1. **自己完結のブリーフを書く。** codex exec は会話文脈を持たないので、ファイル
   (例 `/tmp/review-brief.md`) に「役割・観点・出力形式・対象 diff」を全部入れる。
   diff は `git diff <base>...HEAD` や `gh pr diff <番号>` で取得して同梱する。
   実装と突き合わせてほしいなら「リポジトリ内の該当ファイルを読んで検証せよ」と明記する
   (`-s read-only` なので読める)。
   - production レール(本番反映・PR 前提)のコードをレビューするなら、`personal-production-rail`
     の **review lens**(索引が指すポリシー観点)も観点に含める。観点の実体は production-rail /
     索引が単一の正本なので、**ここに観点を書き写さず参照する**(コピーすると drift する)。
2. **出力形式を指定する。** 冒頭に判定 (merge 可 / 要対応)、各指摘に 3 段階ランクと
   `file:行` を付けさせる:
   - 🔴 must: 放置して merge すると実害が出るもの (バグ・データ破壊・セキュリティ・挙動退行)。
   - 🟡 should: 推奨だが必須でない。
   - ⚪ nit: スタイル・好み・任意。
   「念のため直しては」を must に格上げさせない。
3. **上の安定形で foreground 実行する**(単独コマンドで。複合コマンドに混ぜない)。
   普段の数倍返ってこないときは、まず background 化 / detach されていないかを疑い、次に
   `approval_policy="never"` が付いているかを確認する。固まったら kill して foreground で
   実行し直す。
4. **結果を評価して扱う。** 明らかな誤検知は黙って消さず、転記したうえで「採用しない理由」を
   併記する。must は対応するまで merge しない。
5. **やり取りの正本は PR に残す。** GitHub PR の文脈で使うときは、依頼・結果・再レビューを
   PR コメントとして残す (会話内だけで完結させない)。

## 落とし穴

- `codex:codex-rescue` サブエージェント経由だと、コード読み書きを伴わない分析タスクで
  **Codex に転送せず自分 (Claude) で答えてしまう**ことがある。確実に別モデルの目を入れたい
  なら上の `codex exec` 直叩きを使う。
- `service_tier` 設定が古い CLI/プラグインで解釈できず起動失敗することがある。起動自体が
  失敗するときは設定を疑う (内容は無断で書き換えず、ユーザーに確認)。
