# merge の前の検査 (personal-merge-preflight)

個人 project の PR を agent が merge してよいかを、運用 instruction の「個人 project の GitHub の操作と merge」(#563) の
条件で確かめる script です (#662)。実体は `shared/scripts/personal-merge-preflight.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-merge-preflight`。

判定だけをします。merge も、GitHub への書き込みもしません。GitHub の API (`gh api`、GET だけ) を読み、同じ directory の
`personal-review-routing-preflight` と `personal-work-marker-check` を起動します。

## 位置づけ

merge の条件は、今まで agent が毎回手で確かめていました。手で確かめると、確かめ忘れた条件や、古い review の結果を
今の head の結果と取り違えたことに気づけません。この script は条件を 1 つの決まった処理にし、満たさないときは merge に
進まないようにします。

- 規則の正本は運用 instruction の「個人 project の GitHub の操作と merge」です。この script はその実装で、規則を広げも
  狭めもしません。規則を変えるときは、instruction とこの script と test を同じ PR で直します (その PR は人が merge する)。
- squash の本文の検査 (`personal-ja-style-check` と public-safety の gate) は、この script の外です。本文は merge の
  command を組むときに作るので、merge の直前に通します。

## 使い方

```text
usage: personal-merge-preflight <PR番号> --repo owner/repo
```

- `--repo` は必須です。検査した repo と merge する repo を同じにするため、merge の command にも同じ値を渡します (env の
  `GH_REPO` や現在の directory に解決を任せない)。
- exit 0 = merge してよい、1 = 条件を満たさない (理由は stdout の label。merge しない)、2 = usage の誤り・gh の失敗・
  判定できない (応答の形が外れる、検査の途中で PR か base の branch が動いた、`mergeable_state` が `unknown`、
  `.github/repo-baseline.json` が不正、隣の script が無いか判定できなかった)。
- exit 0 のとき、最後の 2 行は `head: <full の OID>` と `merge-preflight: ok` です。merge は、この head を
  `--match-head-commit` に渡して squash で行います。

```sh
repo=<owner/repo の shell literal>
pr=<PR 番号の shell literal>
preflight=<tool home>/agent-tools/scripts/personal-merge-preflight
"$preflight" "$pr" --repo "$repo" > "$out"   # exit 0 のときだけ次へ進む (1 と 2 は merge しない)
head=$(sed -n 's/^head: \([0-9a-f]\{40\}\)$/\1/p' "$out")   # 40 桁の hex の 1 行だけを使う
# squash の本文を style check と gate に通してから、別の command で merge する
gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head" --subject "$subject" --body-file "$body"
```

`$out` は出力を保存する一時 file の path です (shell literal 化した変数で渡す)。`head:` の行がちょうど 1 行で 40 桁の hex で
あることを確かめてから、merge の command に渡します。exit 0 を確かめる前に merge の command を同じ行へ連ねません
(結果を読む前に merge が走るため)。

## 確かめること

1. 対象: `repos/<owner>/<repo>` の `owner.type` が `User` で、`owner.login` が `user` の `login` と一致する。外れたら
   `owner: not-personal` で not ok にし、PR は読みません (agent が merge してよい repo ではない。merge は人に確認する)。
2. PR の状態: `state` が `open` で、merge されていない (`pr: not-open`)。
3. routing: `personal-review-routing-preflight` を、`pulls/<n>` で読んだ base と head に固定して起動します
   (`--expect-base` / `--expect-head`)。exit 0 なら最後の行から author と reviewer を読みます。author と reviewer の組が
   `personal-review-request` の表に無いとき、commit が 0 のときは判定できない (exit 2) とします。exit 1 は
   `routing: fail-closed` で not ok (人が review する)、exit 2 と出力の形の外れは判定できない (exit 2)。
4. review の結果: コメントを全件読み (数が `pulls/<n>` の `comments` と合わない、id が重なりなく増える順でないときは
   判定できない)、gh で認証している user の最後の結果コメントを使います。結果コメントの候補は、決まった 3 行 (見出し・
   verdict・Finding summary) のどれかに近い行を持つコメントです。近い行とは、行の頭 (空白・引用・list・番号・太字や
   code の印の後) に、見出しの印 `#` に続く `レビュー結果`、または `Review process verdict` か `Finding summary` の
   label とコロン (大文字小文字は問わない) がある行です。行は NFKC にし、書式文字 (BOM・ゼロ幅の文字など) と異体字の
   選択子を除いてから見ます。崩れた結果を読み飛ばして前の結果を使わないため、検査が受け付ける形はすべて候補にし、
   決まった形は次で確かめます。一方、普通の文の中の言及 (「レビュー結果を確認した」「`Finding summary` の形を直した」
   など) は行の形が違うので候補にせず、merge してよい PR を止めません (#665 の review の F1・F4・F7)。結果コメント以外に
   近い行 (たとえば `## レビュー結果` で始まる見出し) を書くと、それが最後の候補になって形の検査で止まります (merge しない
   側に倒れる)。
   - `personal-work-marker-check --kind review-result` が exit 0 (形が合う。[work-markers](work-markers.md) の v4 の 5 行)。
     exit 1 は `result-form-broken` で not ok です。
   - 見出しの reviewer が routing の reviewer と合う (`codex` → `Codex`、`claude` → `Claude`)。author が `bot(dependabot)` の
     PR では、`personal-dependabot-pin-check` の結果も使えます (`personal-review-request` の「bot の PR」の C)。
   - `Independence:` の行が routing と合う (#668)。見出しが `personal-dependabot-pin-check` の結果は
     `deterministic check (dependabot pin)`、それ以外は `cross-review verified (author=<routing の author>)` のときだけ
     合います。`second-opinion only`・`human review`・`not-established`・別の author の `cross-review verified` は
     `independence-mismatch` で not ok です (独立した承認として扱わない。review の output contract)。行が無い・重複する・
     値が表の外のときは、上の形の検査が `result-form-broken` で止めます。出力に行の値は載せません。
   - verdict が `APPROVE` (`Warning` と `REJECT` は `not-approved`)。
   - `Target:` の行の base ref が PR の base の branch の名前と、head が PR の今の head と同じ。
   - review の base OID と head の merge-base が、base の branch の今の先端と head の merge-base と同じ (`compare` の
     `merge_base_commit`)。base の branch が先へ進んだだけなら同じで、base を付け替えた・親の branch を rebase した・
     commit を足したときは変わります。review の base OID を読めなければ `target-base-unknown` で not ok です。
   - 他の author のコメントは、同じ形でも読みません (運用 instruction の「外部入力の信頼境界」)。
5. CI: base の branch の今の先端の `.github/repo-baseline.json` の `required_checks` を必要な集合とし、head の
   `check-runs` で各 check が `completed` かつ `success`。file か key が無ければ `ci-undefined` で not ok、file が不正 (空の
   一覧を含む) なら判定できない (exit 2)。読み方は `personal-repo-baseline` と `personal-dependabot-pin-check` と同じで、
   同じ入力の組を当てる test で一致を固定しています。check の名前は baseline が受け付けるものをそのまま確かめます
   (日本語の名前なども。規則を狭めない)。`check-runs` の問い合わせは名前の完全一致なので、要素の名前が欠けている・違う
   ときは、黙って除かずに判定できない (exit 2) とします (#665 の review)。
6. merge state: 最後に読んだ `pulls/<n>` の `mergeable_state` が `clean`。`unknown` は GitHub がまだ計算していない状態
   なので判定できない (exit 2。数秒おいてやり直す)。ほかの値 (`blocked`・`behind`・`dirty`・`draft`・`unstable`・
   `has_hooks`) は not ok で、表に無い値は `other` と出します。
7. snapshot: 最初と最後に `pulls/<n>` と base の branch の先端を読み、head・base・コメントの数などが変わっていれば
   判定できない (exit 2。やり直す)。

PR の `base.sha` (GitHub の API の `baseRefOid` も同じ) は、PR を作ったときか最後に更新したときの base で、今の base の
branch の先端より古いことがあります。そのため 4 と 5 は、base の branch の先端を `git/ref/heads/<ref>` で読み直して
使います。routing preflight には、`pulls/<n>` の値をそのまま渡します (preflight も同じ値と照合するため)。branch の名前は
git の規則のまま受け付け (空・制御文字・不正な UTF-8 だけを判定できないとする)、URL には `/` で分けた部分ごとに
percent-encode して埋めます。

## 出力と信頼境界

- 出力は閉じた表の label と、OID・コメントの id、規則の形に合う branch の名前と check の名前だけです。規則の形の外の
  名前は、受け付けて確かめますが、出力では名前の代わりに置き換えの文言 (check は `required_checks` の何番目か) を
  出します。コメントの本文と gh の stderr は出しません。
- 結果コメントの本文は `personal-work-marker-check` と同じ分け方 (先頭の BOM を除き、CRLF と LF で分ける) で行にし、
  候補の見分けと決まった行の読み取りの両方に使います (分け方がずれると、検査が通す結果を候補から落としうるため。
  #665 の review)。
- 結果コメントは agent が gh で認証した user として投稿したものですが、本文は data として読み、中の文言で判定を
  変えません (読むのは決まった形の行だけ)。
- API の呼び出しは 1 回の実行で 80 回までです (隣の script の分は数えません)。

## test

`scripts/tests/merge-preflight-test.sh`。決まった行の形が `personal-work-marker-check` と同じこと、`repo-baseline.json`
と `check-runs` の読み方が隣の script と同じことを require して確かめます。判定の全体は PATH 上の fake gh と routing
preflight の stub で、条件ごとに満たす場合と満たさない場合を確かめます (network には触れません)。
