# 投稿の前の検査をまとめてかける (personal-post-check)

投稿や記録の前にかける 3 つの検査 (文体・目印・public-safety の gate) を順にかけ、結果を 1 つにまとめて返す script です
(#676)。実体は `shared/scripts/personal-post-check.rb` で、配備先は `<tool home>/agent-tools/scripts/personal-post-check`。
投稿はしません。何も書かず、network に触れません。

3 つの検査を 1 つずつ呼ぶと、投稿のたびに 3〜4 回の呼び出しになります。この script は検査を 1 回の呼び出しにまとめ、gate の
判定 (exit 0 で警告の行が無い) も中で行って、投稿してよいかを exit code で返します。投稿は別の呼び出しのままにします
(検査の指摘を読む前に投稿しないため)。

```text
usage: personal-post-check --body-file <file> [--title <題名>] [--marker-kind <pr|review-result|escape-issue>] [--style-reviewed]
```

## かける検査

この script と同じ directory の 3 つを、次の順に起動します。それぞれの規則と出力は変えません。

| 順 | 検査 | 起動の形 | 渡す入力 |
| --- | --- | --- | --- |
| 1 | 文体 ([ja-style-check](ja-style-check.md)) | `personal-ja-style-check --stdin` | 題名があれば「題名、空行、本文」。無ければ本文 |
| 2 | 目印 ([work-markers](work-markers.md)) | `personal-work-marker-check --kind <kind> --stdin` | `pr` は「題名、空行、本文」。`review-result` と `escape-issue` は本文だけ |
| 3 | gate ([publication-safety](publication-safety.md)) | `personal-public-safety-gate --stdin` | 文体と同じ |

- 3 つは、途中で止めずにすべてかけます。1 つが止まっても、残りの結果を 1 回で読めます。
- 目印の検査は `--marker-kind` を渡したときだけかけます。目印は個人 project だけに当てる決まりなので、渡すかどうかは
  呼び出し側が決めます ([work-markers](work-markers.md) の「対象」)。
- 検査は argv で起動し、shell を通しません。symlink から起動しても、検査は実体の隣から探します。

## 引数

- `--body-file`: 本文の file。regular file で、UTF-8、1 MiB まで。空や空白だけの file は受けません。
- `--title`: 題名。1 行で、空でないこと。渡すと、題名と本文を合わせて 1 MiB までになります。
- `--marker-kind`: 目印の検査の種類。`pr` には `--title` が要ります。
- `--style-reviewed`: 文体の指摘を読んだうえで、そのままにすると決めた印です。

## 出力

stdout に、検査ごとの見出しの行と、その下に検査が出した行 (各行の頭に空白 2 文字) を出し、最後に判定の行を出します。

```text
style: 1 finding(s)
  -:3: [bold-label] …
  ja-style-check: 1 finding(s) in 1 input(s)
marker: ok
  work-marker-check: pr: ok (markers v4)
gate: ok
post-check: style-findings (1 件。読んで直すか、--style-reviewed を付けてかけ直す)
```

| 行 | 値 |
| --- | --- |
| `style:` | `<件数> finding(s)` / `unavailable` |
| `marker:` | `ok` / `<N> error(s)` / `stop (exit <N>)` / `stop (signal)` / `skipped` / `unavailable` |
| `gate:` | `ok` / `warning` / `stop (exit <N>)` / `stop (signal)` / `unavailable` |
| `post-check:` | `ok` / `stop (<理由>)` / `style-findings (…)` |

- 止める理由は `gate` (gate が exit 0 でない)、`gate-warning` (gate の stderr に、行の先頭から
  `public-safety-gate: warning:` の行がある)、`marker` (目印の検査が exit 0 でない)、`unavailable` (検査を使えない) で、
  当てはまるものをこの順に並べます。
- `unavailable` は、検査の file が無い・起動できないとき、文体の検査が exit 0 で終わらないとき、件数の行を読めないときです。
- gate の行は、stderr、stdout の順に出します。3 つの検査が出す行のほかに、題名や本文を出力に足しません。
- exit 0・1・3 のとき、stderr には何も出しません (検査の stderr も stdout の中に並べます)。

## exit

| exit | 意味 |
| --- | --- |
| 0 | 投稿してよい |
| 1 | 止める。gate が exit 0 でない、gate の警告、目印が exit 0 でない、検査を使えない、のどれか |
| 3 | gate と目印は通っているが、文体の指摘をまだ読んでいない |
| 2 | usage の誤り、入力を読めない、形が外れる、想定外の例外。stderr に 1 行で、stdout は空 |

- exit 3 は、指摘を読む前に投稿しないための区切りです。文体の検査は指摘だけで、投稿を止める gate ではありません
  ([ja-style-check](ja-style-check.md))。指摘を読み、直してかけ直すか、そのままにする理由を持って `--style-reviewed` を
  付けてかけ直します。
- `--style-reviewed` は exit 3 だけを exit 0 に変えます。exit 1 と exit 2 は変わりません。
- exit 1 で gate が止めた・警告を出したときは、投稿せず、本文と出力を人に見せて確認を取ります (運用 instruction の
  「public safety」)。

## 使い方の例

```sh
body=<本文の file の shell literal>
check=<tool home>/agent-tools/scripts/personal-post-check
"$check" --body-file "$body" --title "$title" --marker-kind pr
```

exit 0 を確かめてから、別の呼び出しで投稿します。検査と投稿を 1 つの command に連ねません。

## 持たないもの

- 投稿、file の書き込み、network への接続。
- 検査の規則。規則は 3 つの検査がそれぞれ持ちます。
- 検査の時間の上限。3 つの検査は、1 MiB までの入力を読んで終わる local の処理です。

self-test は `scripts/tests/post-check-test.sh` です。本物の 3 つの検査を一時 directory に置いて、外から起動して確かめます。
