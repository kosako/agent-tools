# Vendored policies — provenance & license

このディレクトリの policy 文書は第三者リポジトリから **import(一回限りの fetch)して vendor** したもの。
配備(sync)はオフラインで行い、実行時に外部取得はしない。更新は import を再実行し、injection gate +
human review を通したうえで commit pin を更新する。pin を上げたら、repo の `.github/upstream-pins.json` の pin と blob の
hash も同じ commit のものにする (参照元の更新は sweep が `personal-upstream-pin-check` で見る。`docs/upstream-pin-check.md`)。

出典・取得方法・license は共通 (下記)。pin はファイルごとに表の列に書く (#619 から。それまでは全ファイル共通の pin)。
各ファイルの追加経緯は記載 Issue 参照。

| ファイル | 取得元 (`nrslib/takt` 配下) | pin commit | 追加 Issue |
|---|---|---|---|
| `ai-antipattern.md` | `builtins/ja/facets/policies/ai-antipattern.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #93 |
| `coding.md` | `builtins/ja/facets/policies/coding.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |
| `review.md` | `builtins/ja/facets/policies/review.md` (include を展開した写し。下記) | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |
| `existing-system-respect.md` | `builtins/ja/facets/policies/existing-system-respect.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |
| `design-planning.md` | `builtins/ja/facets/policies/design-planning.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |

pin の commit の日付: `b71586640f5a…` は 2026-06-14、`7247bb81296569…` は 2026-11-01。

共通:

- 取得方法: GitHub Contents API(`?ref=<pin>`、verbatim、本文は無改変)。`review.md` だけは include を展開した写し (下記)
- license: MIT(下記。`7247bb8` の LICENSE も同一であることを確認した)
- 取得日: 初回は 5 本とも 2026-06-19。#619 で `review.md` 以外の 4 本を、#622 で `review.md` を 2026-11-02 に取り直した。
- import review: 静的 injection スキャン clean(絶対パス/URL/PII/injection 文言なし)を確認 (#619 と #622 の取り直しでも clean)。
  manifest の `review.human_review: not_needed`(medium finding が出たら register が `human_review_required` へ倒す方式。approved にしない理由は asset.yml 参照)。

### `review.md` は include を展開した写し (#622)

`7247bb8` の `builtins/ja/facets/policies/review.md` は本文を持たず、`{{include:policies/review-common}}` の 1 行だけになった。
本文は partial に移り、partial がさらに partial を include する。この dir の他の file と同じく本文の文言は変えずに、
include の token だけを partial の本文で置き換えた写しを置く (takt の facet-includes と同じ規則。展開は
`scripts/expand-vendored-policy.sh`、規則の test は `scripts/tests/expand-vendored-policy-test.sh`)。

展開の元にした file (どれも `nrslib/takt` の `7247bb8`) と sha256:

| file | sha256 |
|---|---|
| `builtins/ja/facets/policies/review.md` | `e9c0764d3e62b6c8b41d3ca4cd8f99c59e5ae0c17d5f2ce14da8d48f082878ef` |
| `builtins/ja/facets/partials/policies/review-common.md` | `d1374cc4fae0524d09a635834b157e685fe137a640c9936ec5fc57b38c4c502e` |
| `builtins/ja/facets/partials/policies/applicable-inputs.md` | `6cdbc671a61878be42422e76918d9971d94102d6fd06e69861f7384719886c19` |
| `builtins/ja/facets/partials/policies/evidence-based-judgment.md` | `2f4cd2318bf3a543c05092bf944da80fe9043fc8ca8cca8354fbdc5ab4796165` |
| `builtins/ja/facets/partials/policies/finding-validity.md` | `8047898544e516892c55766e921c63b38edfff9bcfc2a2922ad9986d4a85b3be` |
| `builtins/ja/facets/partials/policies/reviewer-evidence.md` | `f07e8d86b7062c85cd5412fd75dfb1788e05844642a4e2c4a82daff50c4b4ff7` |

作り直しと照合の手順: 上の file を Contents API (`?ref=<pin>`) で一時 dir に同じ相対 path で取得し、sha256 が上の表と
合うことを確かめてから、`scripts/expand-vendored-policy.sh --root <一時 dir> --facets-root builtins/ja/facets
--entry builtins/ja/facets/policies/review.md --check <この dir の review.md>` を実行する (exit 0 で一致)。pin を
上げるときは、新しい pin で include の先を取り直し、`--check` を外して出力を置き、この表を更新する。

### MIT License (takt)

```
MIT License

Copyright (c) 2026 Masanobu Naruse

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
