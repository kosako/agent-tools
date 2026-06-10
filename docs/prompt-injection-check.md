# Prompt Injection Check 方針

registered asset は、register / sync される前に prompt injection review を通します。
review 対象 asset の metadata は [Asset Manifest Schema](asset-manifest-schema.md) に従います。

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
- tool-managed、company-managed、auth、cache、session、runtime state を変更する指示。

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
- Medium risk: human review 必須。
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
