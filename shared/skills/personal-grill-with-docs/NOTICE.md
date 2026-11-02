# 出典 / Provenance & License

この skill は [mattpocock/skills](https://github.com/mattpocock/skills) の
`grill-with-docs`(= `grilling` + `domain-modeling`)を土台に、日本語化・運用ルール整合・
repo ローカル方針で翻案した derivative work(書式 CONTEXT-FORMAT.md / ADR-FORMAT.md も
同 upstream 由来)。upstream は MIT License であり、下記の copyright notice と
permission notice を保持する。

- 参照 commit: `4ae2317ddb22b046e26455e4f9c9b3aaaf62212d`(2026-10-31。`grilling` の問い方と fact の調査に追随)
- 前の参照 commit(`grilling` v1.2.0 round-by-round frontier 追随時): `6654f6b60cd9d5be8b54c6fafe44346dabeb3b76`(2026-08-24)
- 未追随: `domain-modeling` の CONTEXT.md → GLOSSARY.md (と CONTEXT-MAP.md、CONTEXT-FORMAT.md) の改名。利用者の repo に既にある CONTEXT.md と用語集が割れないよう、名前を維持する (#619)
- 追随 Issue: #226、#619
- 参照元の更新の検査: repo の `.github/upstream-pins.json` (`grill-with-docs`)。参照 commit を上げたら、その pin と blob の hash も更新する (#623)

## MIT License (mattpocock/skills)

```
MIT License

Copyright (c) 2026 Matt Pocock

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
