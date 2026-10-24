# Dependabot の pin の bump の検査 (personal-dependabot-pin-check)

Dependabot の PR のうち、GitHub Actions の pin (`uses: owner/repo@<sha> # <tag>`) の bump だけを決まった処理で確かめる
script です (#553 の C)。実体は `shared/scripts/personal-dependabot-pin-check.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-dependabot-pin-check`。

AI を使いません。何も書きません。GitHub の API (`gh api`、GET だけ) を読みます。

## 位置づけ

相互レビューの routing では、Dependabot の PR は `personal-review-routing-preflight` が GitHub の API の印で `bot(dependabot)`
と判定し、reviewer は Claude です (`personal-review-request` の「bot の PR」)。この script は、その PR の変更が GitHub Actions
の pin の bump だけで、pin が宣言した tag の commit と一致し、必要な CI が通っていることを確かめます。preflight が
`bot(dependabot)` を返したのと同じ head で ok なら、AI の review を省いて人が merge してよい、というのが C の規則です
(規範の正本は `personal-review-request`)。

- routing (PR の author が bot か) はこの script では再判定しません。preflight の結果と、この script の出力の `target:` の
  head を人 (または caller) が照合します。pin-check の ok を別の PR や別の head に当てません。
- この検査は参照の整合性 (sha が tag の commit と一致する) と変更の範囲 (pin の行だけ) の確認です。依存先 (action の中身)
  の安全の証明ではありません。侵害された upstream が悪意ある commit に新しい tag を付けても、この検査は通ります。tag は
  動かせるので、結果は観測時点のものです。
- npm や gem など他の ecosystem の bump は対象外です (`.github/workflows/` の外の file が変わっていれば not ok)。それらは
  通常の bot の route (Claude の review) で扱います。

## 使い方

```text
usage: personal-dependabot-pin-check <PR番号> [--repo owner/repo]
```

- PR 番号は数字だけ。`--repo` は `owner/repo` の形。省くと gh が現在の directory の repository に解決します (env の
  `GH_REPO` が効く点も preflight と同じ)。
- exit 0 = ok、1 = not ok (理由は stdout の label)、2 = usage の誤り・gh の失敗・判定できない (head が動いた、応答の形が
  外れる、file が 50 を超える)。

## 確かめること

1. 変更の範囲: PR の全 file が `.github/workflows/` 直下の `*.yml` / `*.yaml` の `modified` で (added / removed / renamed と
   外の file は not ok。status は GitHub の閉じた表の値だけを出し、表に無い値は `unknown`)、変わった行が `uses` の pin の行だけ。旧 file の変わった `uses` の行を新 file の行に置き換えると、
   新 file と byte 単位で一致することで「それ以外の変更が無い」を確かめます。job と step の構造 (`jobs.<id>.uses` と
   `jobs.<id>.steps[<i>].uses` の位置) は前後で同じで、各 `uses` の owner/repo/path も同じ。sha か tag の変わる行が
   1 つ以上あること。
2. pin の整合: 新しい sha が、その action の repository の tag (`# <tag>` のコメントの版) の commit と一致する。tag は
   `git/ref/tags/<tag>` で解き、annotated tag (type が `tag`) は `git/tags/<sha>` で type が `commit` になるまで解きます
   (tag object の解決は 3 回まで。3 段の tag の先の commit は確かめ、4 段目の tag は `tag-not-commit`)。tag が無ければ `tag-not-found`、commit に解けなければ `tag-not-commit`、一致しなければ `pin-mismatch`。
   版は `v` を除いた数値の tuple で比べ、前に進まなければ `version-not-forward` (同じ版で sha だけが変わるものを含む)。
3. CI: base の `.github/repo-baseline.json` の `required_checks` を必要な集合とします (file が無い・key が無い・空は
   `ci-undefined` で not ok。空の一覧を成功にしない)。head の `check-runs` を check の名前ごとに page 単位で読み (1 page が
   gh の 1 回で、回数の上限は呼ぶ前に数える。page ごとの `total_count` が一致し、件数が合わなければ判定しない = exit 2)、
   すべて `completed` かつ `success` なら `success`、1 つでも終わっていなければ `pending`、1 つでも success でなければ
   `failure`、無ければ `missing`。
4. snapshot: 最初と最後に `pulls/<n>` を読み、head と base が動いていなければ結果の `target:` に OID を載せます。動いて
   いれば判定できない (exit 2)。

### 読み方の限界

- `uses` の行の形は `owner/repo[/path]@<40 桁の sha> # <tag>` (tag は `v` の有無と数字と点だけ) に限ります。`@v4` のような
  tag への pin、`docker://`、`./local`、prerelease の版は、変わっていれば `non-pin-change` (not ok)、変わっていなければ
  見ません。
- YAML は `personal-ci-check` と同じ読み方です (stream 全体を parse して文書が 1 つ、入れ子の深さは 64 まで、明示の tag と
  scalar でない key と merge key を拒む、書かれた key と load 後の key が 1 対 1 でなければ拒む)。`uses` は AST の 1 行の
  scalar だけを見るので、`run: |` の中の `uses:` という文字列は見ません。複数行の scalar は `uses-not-scalar` (not ok)。
- file は 1 MiB まで、PR の file は 50 まで (1 page で読み、`changed_files` と数を照合する)、API の呼び出しは 1 回の実行で
  80 回まで (check-runs の page も 1 回ずつ数える。`--paginate` は使わない)。
- YAML (libyaml) が改行とみなす LF 以外の文字 (CR・NEL・LS・PS) を含む file は `line-endings-unsupported` (not ok)。行の
  添字と AST の行番号がずれ、別の行を `uses` の行として検査しうるため。CRLF の workflow は通常の bot の route で扱う。

## 出力

stdout は閉じた label と、規則の形に合う path:line・tag・check の名前だけです。patch、file の本文、PR の title / body、
gh の stderr は出しません (gh の stderr は捕捉して捨て、失敗は定型の文言だけ)。規則の外の名前の file は名前を出さずに
`not-workflow-file` と数えます。

```text
target: base <base の sha> / head <head の sha>
.github/workflows/test.yml: pin-only-change (1 line(s))
.github/workflows/test.yml:37: pin-ok (v1.329.0 -> v1.331.0)
ci self-tests (3.4): success
ci self-tests (system): success
pin-check: ok (1 pin(s), 2 check(s))
```

not ok のときは最後の行が `pin-check: not ok` で、理由は各行の label (`pin-mismatch` / `tag-not-found` / `tag-not-commit` /
`version-not-forward` / `ref-changed` / `non-pin-change` / `structure-changed` / `no-pin-bump` / `not-workflow-file` /
`not-modified (<status>)` / `yaml-unreadable` / `yaml-not-workflow` / `uses-not-scalar` / `file-missing` / `file-too-large` /
`content-unreadable` / `ci <名前>: pending|failure|missing` / `ci-undefined`) に出ます。

## test

`scripts/tests/dependabot-pin-check-test.sh`。fixture は `scripts/tests/lib/dependabot_pin_check_fixtures.rb` が作り、fake gh
が endpoint ごとに返します (期待する repository と PR 番号を argv 全体で照合し、想定外の argv は失敗。stderr には常に canary
を出し、出力に出ないことを固定する)。ok、annotated tag (1 段と 3 段)、4 段の tag、tag の不在・不一致・commit に解けない、
版の後退・同じ版、owner/repo の変化、pin 以外の変更、`run` の中の文字列の変化、構造の変化、変更なし、外の file、added、
表に無い status、規則の外の名前、明示の tag、複数行の scalar、CRLF、CI の failure / pending / missing / 同名の混在 / 2 page /
件数の不一致 / 空の page で件数が足りない / page ごとの total_count の違い / baseline なし / 空、head の移動、数の不一致、
file の上限、1 MiB の上限、gh の失敗、usage を確かめます。
