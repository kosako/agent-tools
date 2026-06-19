# Vendored policies — provenance & license

このディレクトリの policy 文書は第三者リポジトリから **import(一回限りの fetch)して vendor** したもの。
配備(sync)はオフラインで行い、実行時に外部取得はしない。更新は import を再実行し、injection gate +
human review を通したうえで commit pin を更新する。

## ai-antipattern.md

- 取得元: `nrslib/takt` — `builtins/ja/facets/policies/ai-antipattern.md`
- pin commit: `b71586640f5a59e3f009bf033532a79fd643677f`(2026-06-14)
- 取得日: 2026-06-19
- 取得方法: GitHub Contents API(verbatim、本文は無改変)
- license: MIT(下記)
- import review: 静的 injection スキャン clean(絶対パス/URL/PII/injection 文言なし)を確認。
  manifest の `review.human_review: approved` で第三者 import を承認(Issue #93)。

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
