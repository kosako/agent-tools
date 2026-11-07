# 出典 / Provenance & License

この skill の security の観点 (`SECURITY-CLASSES.md` の類型と、`REPORT-FORMAT.md` の「security の所見」の条件と深刻度) は、
[cloudflare/security-audit-skill](https://github.com/cloudflare/security-audit-skill) の観点を選んで日本語で言い換えた
もの。本文と validator (`.cjs`) は取り込んでいない (vendor ではない)。upstream は MIT License であり、下記の copyright
notice と permission notice を保持する。

- 参照 commit: `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`
- 元にした file: `skills/security-audit/SKILL.md` (Core principles)、`skills/security-audit/HUNTING.md` (Candidate gate)、
  `skills/security-audit/AI-AND-LLM.md`、`skills/security-audit/SUPPLY-CHAIN-AND-RELEASE.md`
- 判断の Issue: #567 (全体は取り込まない)、#613 (観点を借りる)
- 参照元の更新の検査: repo の `.github/upstream-pins.json` (`security-audit-skill`)。参照 commit を上げたら、その pin と blob の
  hash も更新する (#623)

## MIT License (cloudflare/security-audit-skill)

```
MIT License

Copyright (c) 2025-2026 Cloudflare, Inc.

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
