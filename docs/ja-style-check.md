# 日本語の文章の検査 (personal-ja-style-check)

AI (Claude / Codex) が書く日本語に残りやすい型を見つけて指摘する script です (#556)。文章を直さず、何も書かず、
network にも触れません。指摘の有無にかかわらず走り終えれば exit 0 で、**gate ではありません**: 止めるか、直すか、
理由を付けて残すかは、読んだ agent か人が決めます。

対象は、agent が書く文章のうち user が毎日読むもの: session の返答、Issue / PR の本文とコメント、commit message、
作業ログ。repo の docs と skill の本文は、仕様の条件を細かく書く文章なので対象にしていません (当てると書式の
決まりに当たる指摘が大半になる)。

## 運用

- 公開の前の検査 (`personal-public-safety-gate --stdin`) とは別の口です。並べて使い、文体の指摘で公開を止めません。
  gate の警告と混ぜないため、出力の名前も分けています (`ja-style-check:`)。
- 使う場面は、書いた文章を投稿・記録する前 (Issue / PR の本文とコメント、commit message、作業ログの下書き) と、
  自分の返答を見直すとき。agent が `--stdin` で通し、指摘を読んで直すか、そのままにする理由を持ちます。
- 自動では直しません。指摘に沿って機械的に書き換えると、別の定型 (短い文の羅列、言い換えの大げさな語) を生むためです。
  指摘をゼロにすることを目標にしません。

## 使い方

```sh
personal-ja-style-check --stdin < draft.md
personal-ja-style-check --json --stdin < draft.md
personal-ja-style-check docs-draft.md notes.md
```

- `--stdin`: 標準入力を 1 つの入力として見る。file と一緒には使えない。
- `<file>...`: UTF-8 の text file。1 file 1 MiB まで。複数可。
- `--json`: 入力ごとの findings と stats を JSON で出す。

## 規則

user が実際の文章 (下の「閾値の決め方」) を見て「直したい」と選んだ 4 つの型です。

| 規則 | severity | 見るもの | 直し方の目安 |
|---|---|---|---|
| `em-dash` | warn | ダッシュ (`—` U+2014、`―` U+2015、`–` U+2013、`─` U+2500) を文の区切りに使う | 読点か句点で区切るか、文を分ける |
| `bold-label` | warn | 太字の見出しに中身を続ける箇条書き (`- **見出し**: 中身`、`1. **見出し**: 中身`、`- **見出し** 中身`) と、行頭の `**見出し**: 中身` | 地の文で書くか、見出しを外す |
| `long-run` | warn | 空白を除いて 60 字以上の文が、同じ段落で 3 つ続く | 1 文を 2 つに分けるか、短い文を挟む |
| `long-sentence` | warn | 1 文が 120 字以上 | 2 つに分ける |
| `negation-run` | warn | 文末が打ち消し (「〜ない」「〜ません」「〜ぬ」) の文が、同じ段落で 3 つ続く | 肯定の言い方に変えられるか見る |
| `idiom` | info | 「〜側に倒す」「黙って無視する / 捨てる」「前提が崩れる」の慣用 | 平易な言い方にできるか見る |

1 行まるごと太字 (`**判定: APPROVE**`) は `bold-label` に当てません (太字の中にコロンがあるだけで、見出しに中身を
続ける形ではない)。見出し (`#`) と表の行は文として数えず、ダッシュだけ見ます。

## 出力と exit

既定の出力は 1 指摘 1 行で、最後に件数の行を出します:

```
-:3: [bold-label] 太字の見出しに中身を続ける箇条書き。地の文で書くか、見出しを外す | - **判断**: 中身。
ja-style-check: 1 finding(s) in 1 input(s)
```

`--json` では `{"tool": "personal-ja-style-check", "version": "1", "inputs": [{"name", "stats", "findings"}]}` を
1 行で出します。`findings` の要素は `rule` / `line` / `severity` / `message` / `snippet` (抜き出しは 40 字まで)、
`stats` は `lines` / `sentences` / `chars` / `mean_length` / `max_length` / `cv` / `long_sentences` /
`negation_endings` / `masked_spans` / `scrubbed` です (閾値を測り直すときに使う)。

- exit 0: 走り終えた (指摘の有無は問わない)。
- exit 2: usage (引数なし、`--stdin` と file の併用、知らない option)、入力を読めない (file が無い、通常の file でない、
  1 MiB を超える)、想定外の例外。stderr の message に入力の text は載せません。
- 壊れた UTF-8 の byte は置き換え文字にして検査し、`stats.scrubbed` を true にします。

## 読み方 (Markdown)

- fenced code block (` ``` ` / `~~~`) の中は見ません。
- 引用の印 (`>`) は、構造 (code block・見出し・表) を読む前に外します。引用の中の code block や見出しも、引用の外と
  同じに扱います。引用は、引用の印の無い行 (空行を含む) で終わり、引用の中で開いた code block もそこで終わります
  (引用の外で開いた code block は、引用の印の無い行でだけ閉じる)。
- inline code、`<code>`、URL は 1 文字の置き字 (〓) に置き換えてから見ます (中の記号や長さで判定しないため)。
  URL は空白 (全角空白を含む)、括弧の閉じ、日本語の句読点と括弧の開き (。、！？（「『) の前で終わります。1 行の
  HTML のコメント (`<!-- -->`) は外します。これらと link は、左から順に、先に始まったものを 1 つの区間として読みます
  (code span の中のコメント記号や、link の宛先の中の URL や括弧は、その区間の一部)。link の text の中の code span や
  URL も同じに読みます。`<b>` は Markdown の太字として読み、他の HTML の tag は外します。
- 箇条書きの印、太字の印、link の書き方 (`[text](宛先)` は宛先が URL でも相対 path でも、括弧を 1 段含んでも text だけ
  残す。画像 `![alt](src)` は alt だけ残す) は文の長さに含めません。
- 文は「。！？!?」か行末で切ります。行末は LF でも CRLF でも同じです。空白 (全角空白を含む) は長さに数えません。
- 空行・見出し・表・code block・区切り線 (`---` など) で段落が切れ、「続く」(`long-run` / `negation-run`) の数え方は
  そこで途切れます。見出し・表・区切り線・HTML のコメントは文として数えません。

## 閾値の決め方

agent-tools の実際の文章 (session の返答・Issue / PR の本文とコメント・commit message・作業ログの節。種類ごとに
200 件まで、計 1,354 件) で測り、user が実例を見て決めました (2026-10-23)。

- 文の長さ (空白を除く) の中央値は 31〜46 字、90 percentile は 59〜102 字。60 字以上の文は種類により 10〜33%、
  120 字以上は 0.1〜6.6%。60 字は「長い」と呼べる下限、120 字は上位数 % の明らかに長い文として選びました。
- `bold-label` は Claude の返答 200 件で 135 回、PR の本文 200 件で 362 回。`em-dash` は Codex の返答とコメントに
  偏り (200 件で 61 回と 219 回)、Claude の返答では 0。`long-run` は commit message と Issue / PR の本文に出ます。
- 公開されている lint (natural-japanese、yomiyasu。どちらも MIT) を同じ文章に当てた結果が出発点です。上位は
  この repo の書式の決まり (review の severity の絵文字、箇条書き中心の本文、起票の雛形の見出し) と用語
  (「正本」「版」) への誤検知で、AI の定型句の規則は AI の文章に 1 件も当たりませんでした。そのため規則の一覧や
  pattern は取り込まず、user が選んだ型だけを自前で書いています。

## 限界

- lint の指摘と、人が読んで感じる不自然さは一致しません。指摘は候補で、採否は読んだ人が決めます。
- 短い文章 (返答の多くは 200 字未満) では、長さの規則はほとんど当たりません。返答の型は主に `bold-label` で見ます。
- Markdown の構造の読み方は上の規則だけです。入れ子の code span、HTML の block、複数行にまたがる HTML のコメント、
  4 字下げの code block、表の中の文などは想定どおりに読めないことがあります。
- 慣用の一覧は、実際に出たものだけです。増やすときは実例と一緒に足します。
- 自動の修正、文章の種類ごとの閾値、session の返答への hook は持ちません (効き目を見てから決める)。
