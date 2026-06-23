# Prompt Injection Check 方針

registered asset は、register / sync される前に prompt injection review を通します。
review 対象 asset の metadata は [Asset Manifest Schema](asset-manifest-schema.md) に従います。

## 適用範囲 (supply-side のみ)

この gate が守るのは **配布する asset の supply-side** です。register / sync される前に、
asset 自体 (skill / instruction など) に injection が仕込まれていないかを静的検査します。

agent が **実行時に読み込む外部入力** (GitHub の Issue / PR / comment、外部 URL、貼られた
ログや添付など) に第三者が混入させた指示で agent が誤誘導される runtime injection は、
**別レイヤー**の防御です。攻撃面が逆向き (配布物の中身 ⇔ 実行時に流入するデータ) なので
混同しません。runtime 入力の防御 (safe reader / `PreToolUse` hook / scoped token) は
実行環境の責務で、この repository の scope には含めません
([dotfiles との境界](boundary-with-dotfiles.md))。

## 対象範囲

以下の registered asset types をすべて check します。

- skills
- prompts
- agents
- templates
- workflows
- instructions

## Static Checks

static checks はすべての asset で必須です。少なくとも以下を検出します。

- system / developer instructions を override しようとする内容。
- secrets、tokens、credentials、private keys の開示または収集要求。
- "ignore previous instructions" などの hidden instruction patterns。
- tool permission または approval policy の bypass attempts。
- external exfiltration、network tunnel、production access requests。
- tool-managed、company-managed、auth、cache、session、runtime state を変更する指示、
  またはそれらの runtime state path (`~/.codex/...` `~/.claude/...` の sessions / projects /
  auth / config / cache / plugins) を参照する内容 (medium)。
- user-specific な absolute path (例 `/Users/<name>` `/home/<name>` `C:\Users\<name>`) の混入。
- email address など PII の混入。
- external URL の混入。

absolute path と email は asset 種別によらず high とします。
external URL は **artifact kind 別**に扱います。instruction asset の source では strict
(high) に昇格します (instruction は具体参照先を書かない方針なので、URL 混入は方針違反と
して止める)。skill / workflow など他の asset では low (検知のみ、gate は通す) です。

directory skill の `evals/` (adversarial なテスト材料) は例外です。eval prompt は「skill が
転記/実行しないこと」を検証するため、injection 文字列・fake な絶対パス・email を意図的に
含むので、evals ではそれらを抑止します。ただし inline の private key 本体
(`-----BEGIN ... PRIVATE KEY-----`) だけは fixture で不要なため、evals でも high で検知します。

## LLM Review

LLM review は supplemental gate です。

LLM review に送ってよいもの:

- public assets。
- personal assets。

LLM review に送ってはいけないもの:

- work assets。
- client assets。
- secret-like assets。
- private endpoints を含む assets。
- ownership または confidentiality が不明な assets。

ownership または confidentiality が不明な場合、その asset は LLM review に送らず、
human review 必須にします。

## Risk Outcomes

- High risk: registration fail。
- Medium risk: human review 必須。`review.human_review: approved` を manifest で宣言すると
  `registered` になり配置される (medium↔承認の照合は register が担う)。read-only でログを
  読む等、参照が設計上正当な skill (例 `personal-asset-miner` の runtime-state) はこの経路で
  通す。詳細は [register-catalog](register-catalog.md)。
- Low risk: registration 可。

## Static checker 実装

static checks は `scripts/check-injection.sh` として実装済みです。

- deterministic で、外部依存ゼロ・network access なしで実行できる。
- 対象は `shared/` 配下の asset files のみ。policy docs は対象外。
- findings は `path:line: [risk] category: message` 形式で出力する。
- exit code は risk outcome に対応する: high は 1 (registration fail)、
  medium のみは 3 (human review 必須)、findings なしまたは low のみは 0。

## Follow-up 実装メモ

LLM review step は optional かつ明示設定とし、content を外部に送る前に privacy gate を実行します。
