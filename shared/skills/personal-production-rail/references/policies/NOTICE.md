# Vendored policies — provenance & license

このディレクトリの policy 文書は第三者リポジトリから **import(一回限りの fetch)して vendor** したもの。
配備(sync)はオフラインで行い、実行時に外部取得はしない。更新は import を再実行し、injection gate +
human review を通したうえで commit pin を更新する。

出典・取得方法・license は共通 (下記)。pin はファイルごとに表の列に書く (#619 から。それまでは全ファイル共通の pin)。
各ファイルの追加経緯は記載 Issue 参照。

| ファイル | 取得元 (`nrslib/takt` 配下) | pin commit | 追加 Issue |
|---|---|---|---|
| `ai-antipattern.md` | `builtins/ja/facets/policies/ai-antipattern.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #93 |
| `coding.md` | `builtins/ja/facets/policies/coding.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |
| `review.md` | `builtins/ja/facets/policies/review.md` | `b71586640f5a59e3f009bf033532a79fd643677f` | #97 |
| `existing-system-respect.md` | `builtins/ja/facets/policies/existing-system-respect.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |
| `design-planning.md` | `builtins/ja/facets/policies/design-planning.md` | `7247bb81296569814354e6b72cb4eb1db718f3d6` | #97 |

pin の commit の日付: `b71586640f5a…` は 2026-06-14、`7247bb81296569…` は 2026-11-01。

共通:

- 取得方法: GitHub Contents API(`?ref=<pin>`、verbatim、本文は無改変)
- license: MIT(下記。`7247bb8` の LICENSE も同一であることを確認した)
- 取得日: 初回は 5 本とも 2026-06-19。#619 で `review.md` 以外の 4 本を 2026-11-02 に取り直した。
- import review: 静的 injection スキャン clean(絶対パス/URL/PII/injection 文言なし)を確認 (#619 の取り直しでも clean)。
  manifest の `review.human_review: not_needed`(medium finding が出たら register が `human_review_required` へ倒す方式。approved にしない理由は asset.yml 参照)。

`review.md` を古い pin に据え置く理由 (#619): `7247bb8` の `review.md` は本文を持たず、`{{include:policies/review-common}}` の
1 行だけになった。本文は `builtins/ja/facets/partials/policies/review-common.md` に移り、そこからさらに 4 つの partial を
include する。同じ path の file を無改変で写すこの dir の規則では取り込めない。include を展開した写しを作るか、partial を
別の file として vendor するかは、索引と `review-output-contract.md` への影響と合わせて別の Issue で決める。

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
