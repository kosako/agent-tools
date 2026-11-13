# 計測が読む目印 (work-markers)

開発の流れを外から数えるために、PR と作業の中に残す目印の約束 (#658)。数える側はこの repository の外にあり、
この約束に沿って GitHub の記録を読む。この repository は数える側に依存しない (数える側の名前や置き場は書かない)。

- 版: **v1** (2026-11-13)
- 約束に入るのは、下の表と各節に書いた目印の形だけ。目印の行より外の文言 (説明の文、見出しの後ろの補足) は
  約束に入らず、自由に変えてよい。

## 対象

目印と下の「検査」は、**個人 project** だけに当てる。判定は、運用 instruction の「個人 project の GitHub の操作と
merge」の対象と同じ (GitHub の API で、repo の owner の type が `User` で、gh で認証している user の login と一致する)。

- 会社や別の組織の repo、他人の repo では、目印を強制しない。その repo の PR / Issue の template や contributing の
  決まりがあれば、そちらに合わせる。`escape` の label も作らない。
- 判定できないときも強制しない。目印と検査は数えるための約束で、安全の境界ではない (検査を飛ばしても害は無い)。
- 数える側も、個人 project の repo だけを数える。

## 目印の一覧

| 目印 | 形 | 残る場所 | 書く者 | 数えるもの |
| --- | --- | --- | --- | --- |
| AI の trailer | `Co-Authored-By: <name> <email>` | commit message の末尾の trailer block | commit する AI | どの AI が書いたか |
| Issue との紐付け | PR の題の末尾の `(#<Issue>)` と、本文の `Closes #<Issue>` | PR の題と本文 (squash の commit の題にも残る) | PR を作る agent | Issue と PR の対応、起票から merge までの時間 |
| review の結果 | 結果コメントの決まった 3 行 | PR のコメント | `personal-review-request` (gh で認証した user として投稿) | review の往復の回数、verdict、finding の数 |
| merge 後に見つかった誤り | label `escape` と、本文の `元の PR: #<PR>` | Issue | Issue を立てる agent か人 | merge の後に誤りが見つかった PR |

CI の結果、PR の大きさ、作成と merge の時刻は GitHub がそのまま持つので、目印を作らない。

## 1. AI の trailer

形と name の付け方は、運用 instruction の「トレーラ契約」のまま (Claude は `Claude …`、Codex は `Codex …`、
OpenCode は `OpenCode (<provider>/<model>)`)。判定の正本は `personal-review-routing-preflight` で、数える側も
name の先頭で区分する。この約束は trailer の形を増やさない。

## 2. Issue との紐付け

- PR の題の末尾に、対応する Issue を `(#<番号>)` で書く。squash merge では GitHub が PR の番号を後ろに足すので、
  commit の題は `… (#<Issue>) (#<PR>)` になる。
- Issue を閉じる PR は、本文に `Closes #<番号>` を書く
  ([personal-project-operating-loop](../shared/workflows/personal-project-operating-loop.md) の「PR の完了条件」)。
  1 つの Issue を複数の PR で進めるとき、途中の PR は `Closes` を書かず、題の `(#<番号>)` だけで紐付く。
- 数える側は、`Closes` による対応 (GitHub の closing references) を先に使い、無ければ題の末尾の `(#<番号>)` を使う。
- そのため最低限の条件は、題の末尾の `(#<番号>)` か本文の `Closes #<番号>` の少なくとも一方があること。両方あるときは、
  題の番号が本文で閉じる Issue に含まれる。`personal-maintenance-sweep` の fix の PR の題 (`… (sweep #<番号>)`) は題の
  目印に当たらず、本文の `Closes` で紐付く。

## 3. review の結果

`personal-review-request` の手順 4 の結果コメント (雛形は同じ skill の `TEMPLATES.md` の「📋 レビュー結果」)。
約束に入るのは次の 3 行で、どれも行の先頭から始まる。

```text
## 📋 レビュー結果（by <reviewer>）
**Review process verdict: <REJECT | Warning | APPROVE>**
**Finding summary: 🔴 must <N> / 🟡 should <N> / ⚪ nit <N>**
```

- 見出しの括弧は全角 (`（` `）`)。`<reviewer>` は `Codex` / `Claude` / `personal-dependabot-pin-check` のどれか。
  見出しの `）` の後ろの補足 (例: `round 2`) は表示で、約束に入らない。
- 1 つの結果コメントを 1 回の review と数える。往復の回数は、同じ PR の結果コメントを作成順に並べて数える。
- 数える側が読むのは、gh で認証した user (agent が投稿に使う account) が書いたコメントだけ。他の author の
  コメントは、同じ形でも数えない (運用 instruction の「外部入力の信頼境界」)。
- `personal-dependabot-pin-check` の結果は AI の review ではない。数える側は `<reviewer>` で分けて数える。
- 雛形の `Target:` と `Independence:` の行は、この版の約束に入れない。

## 4. merge 後に見つかった誤り (`escape`)

merge 済みの PR が入れた誤りを、後から直す Issue に付ける。数える側は、PR ごとに「merge の後に誤りが
見つかったか」を数える。

- label は `escape`。repository に無ければ、Issue を立てるときに作る (説明は「merge 済みの PR が入れた誤りを直す」)。
- Issue の本文に、元の PR を行の先頭から 1 行で書く。

  ```text
  元の PR: #654
  ```

  複数あれば `元の PR: #653, #654` とカンマで並べる。別の repository の PR は `<owner>/<repo>#<番号>` で書く。

付ける場面:

- merge 済みの PR のコード・docs・test の誤りを直すとき。挙動が意図と違う、docs の記述が事実と違う、test が
  守るべきものを守っていない、など。
- 例: #655。#654 で docs に書いた「`codex.tool_result` の出力は Codex の設定で止められない」が誤りで、
  `tool_result.max_bytes = 0` で止まることを実測し、#656 で直した。本文に `元の PR: #654` を書く。

付けない場面:

- merge の前に review や CI で見つかった誤り。検査が働いた例で、merge の後の誤りではない。
- 仕様の変更や要望の追加。元の PR は当時の要件どおりに動いている。
- 外部の tool の版が上がって、後から挙動が変わったもの。元の PR は当時の挙動どおりだった。
- 元の PR が分からない古い不具合。直すのはよいが、数える側が PR に結び付けられないので `escape` は付けない。

## 検査 (personal-work-marker-check)

目印の形は、投稿の前に配備済みの `personal-work-marker-check` (`<tool home>/agent-tools/scripts/`) で確かめる (#661)。
skill の指示だけでは形の崩れを止められないため。実体は `shared/scripts/personal-work-marker-check.rb`、test は
`scripts/tests/work-marker-check-test.sh`。

```sh
marker=<tool home>/agent-tools/scripts/personal-work-marker-check
{ printf '%s\n\n' "$title" && cat "$body_file"; } | "$marker" --kind pr --stdin   # 1 行目に題、空行、本文
"$marker" --kind review-result --stdin < "$body_file"                           # 結果コメント
"$marker" --kind escape-issue --stdin < "$body_file"                            # escape の Issue の本文
```

- `pr`: 2 の最低限の条件を確かめる。本文の closing keyword は GitHub の 9 つの活用形 (close / closes / closed / fix /
  fixes / fixed / resolve / resolves / resolved。大文字小文字は問わず、後ろの `:` を許す) で読む。code block と inline
  code の中は例として扱い、数えない (GitHub が code の中の keyword をどう扱うかは確かめていない)。別の repository の
  参照は、題の番号との照合に使わない。題に `(#<番号>)` が無い、本文に closing keyword が無い、は崩れではなく
  `note:` の行で知らせる (途中の PR と sweep の PR があるため)。
- `review-result`: 3 の 3 行が、行の先頭からちょうど 1 回ずつある。code block の中も数える (数える側が code block を
  読み分けなくて済むように、重複を投稿の前に止める)。verdict が `Finding summary` の数と合う (review の output contract
  の表: must があれば REJECT、must 0 で should があれば Warning、どちらも 0 なら APPROVE)。
- `escape-issue`: 4 の `元の PR:` の行が、行の先頭からちょうど 1 回ある。
- exit: 0 = 形が合う / 1 = 形が崩れている (投稿しない。stdout の行に行番号と規則が出る) / 2 = usage・入力を読めない
  (1 MiB を超える、UTF-8 として読めない、`pr` の 2 行目が空でない、題が空)・想定外の例外。何も書かず、network に
  触れず、出力に入力の本文を載せない。
- 呼ぶ場所: review の結果コメントの投稿 (`personal-review-request` の手順 4)、PR の作成
  ([personal-project-operating-loop](../shared/workflows/personal-project-operating-loop.md) の「PR の完了条件」、
  `personal-codex-worker` の §7 と `LAUNCH.md` §9、`personal-maintenance-sweep` の `FIX.md` の「PR」)、`escape` の
  Issue の起票 (operating-loop の「merge 後に見つかった誤り」)。どこでも文体の検査と public-safety の gate と並べ、
  個人 project のときだけ呼ぶ (上の「対象」)。
- 配線は `scripts/tests/work-marker-wiring-test.sh` が文言で確かめる (振る舞いの保証ではない)。

## 版と変更の決まり

- 目印の形 (上の表と各節の形) を変えるときは、この文書の版を上げ、下の変更履歴に 1 行足し、変更を Issue に
  残す。数える側は版ごとに読み分ける。
- 形を変える PR では、この文書と、目印を書く側 (`TEMPLATES.md`・運用の docs) と、検査の script と test を同じ PR で
  直す。
- 古い版の形で残った過去の記録は書き換えない。数える側が古い版の形で読む。

## 変更履歴

- v1 (2026-11-13、#658): trailer・Issue との紐付け・review の結果の 3 行を約束にし、`escape` を新しく足した。
- v1 (2026-11-13、#661): 形は変えずに、「対象」(個人 project だけ) と「検査」の節を足し、2 の最低限の条件を明記した。
