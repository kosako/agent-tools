# Prompt Injection Check 方針

registered asset は、register / sync される前に prompt injection review を通します。
review 対象 asset の metadata は [Asset Manifest Schema](asset-manifest-schema.md) に従います。

## 適用範囲 (supply-side のみ)

この gate が守るのは **配布する asset の supply-side** です。register / sync される前に、
asset 自体 (skill / instruction など) に injection が仕込まれていないかを静的検査します。

agent が **実行時に読み込む外部入力** (GitHub の Issue / PR / comment、外部 URL、貼られた
ログや添付など) に第三者が混入させた指示で agent が誤誘導される runtime injection は、
**別レイヤー**の防御で、この `check-injection` gate の対象外です。攻撃面が逆向き
(配布物の中身 ⇔ 実行時に流入するデータ) なので混同しません。runtime 防御自体は
agent-tools の scope 外ではなく、**body (safe reader / hook script / token 隔離 / 隔離 reader /
trust 判定) は agent-tools、control plane (settings deny 床 / capability / 規約 / doctor) は
dotfiles** という分担です (この gate がそれを担うわけではない)。詳細は
[dotfiles との境界](boundary-with-dotfiles.md) の「runtime GitHub injection 防御の分担」と
[Runtime GitHub Injection 防御 (Phase 3)](runtime-injection-defense.md)。

## 対象範囲

以下の registered asset types をすべて check します。

- skills
- prompts
- agents
- templates
- workflows
- instructions
- scripts

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

NUL byte を含むファイルは pattern scan できないため、**fail-closed で high** とします
(silent skip すると NUL 1 byte で scanner 全体を回避できる)。shared/ の asset は text が
前提で、binary を置く正当な用途は現状ありません。

**script asset の限界 (honest-label)**: static check が実行コードに当てられるのは上記の
injection **文言** pattern のみで、コードの悪性 (外部送信・破壊的操作など) は検査できません。
script artifact のコード安全性は author≠reviewer の PR レビューと、register の human review
必須ゲート ([register-catalog.md](register-catalog.md)) に依存します。

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
- Medium risk: human review 必須。`review.human_review: approved` **かつ**
  `review.approved_build_id` が現在の build_id と一致すると `registered` になり配置される
  (medium↔承認の照合は register が担う)。承認は内容に紐づくので、source を変えたら
  再レビューして `approved_build_id` を更新する (#148)。read-only でログを読む等、参照が
  設計上正当な skill (例 `personal-asset-miner` の runtime-state) はこの経路で通す。詳細は
  [register-catalog](register-catalog.md)。
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
