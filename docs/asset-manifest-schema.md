# Asset Manifest Schema

shared asset を register / build / sync する前に読む machine-readable metadata の
schema 方針です。

この document は設計です。parser、validator、build、sync の実装は含めません。

## 目的

- shared asset の種類、公開可否、target tool、risk、source を明示する。
- public repository に載せてよい asset と載せない asset を分ける。
- `personal-` prefix rule を machine-readable metadata でも検査できるようにする。
- prompt injection check、build adapter、sync、status / doctor の入力にできる形にする。

## Manifest の置き方

v1 では sidecar manifest を使います。

single-file asset:

```text
shared/workflows/personal-example.md
shared/workflows/personal-example.asset.yml
```

directory asset:

```text
shared/skills/personal-example/
  asset.yml
  SKILL.md
  references/      # 任意。実行時リソースとして配置先に載る
  assets/          # 任意。実行時リソースとして配置先に載る
  evals/           # 任意。source として版管理するが配置先には載せない
```

### directory skill の Phase 1 制約

skill を directory 形式で持つときの配置・安全ルール (Phase 1):

- `SKILL.md` / `references/` / `assets/` は配置先 (`<tool home>/skills/personal-<name>/`)
  に載せる (ランタイム skill の一部)。
- `evals/` は **source として版管理するが配置先には載せない**。skill-creator 等の
  テスト材料であり、ランタイム skill の一部ではない。build はコピーから除外し、
  build_id にも含めない (eval 編集だけでは配置成果物は変わらない)。テストプロンプトは
  意図的に攻撃的な文字列を含みうるため、injection check の scan 対象からも外す。
- `scripts/` (実行コード) を含む directory skill は **fail-closed** で拒否する。
  配る前に実行コードを安全検査する能力がまだ無いため、check-manifests が error にして
  gate を止める (黙ってスキップしない)。対応は external scanner 連携の後 (#43)。

asset 本体に frontmatter を埋め込まない理由:

- target tool が独自 frontmatter を持つ可能性がある。
- shared metadata と target-specific metadata を混ぜない。
- markdown 以外の asset にも同じ考え方を使える。

## Required fields

```yaml
schema_version: 1
name: personal-example
kind: workflow
visibility: public
targets:
  - codex
  - claude-code
risk:
  prompt_injection: low
  privacy: low
source:
  path: shared/workflows/personal-example.md
  format: markdown
```

### `schema_version`

manifest schema の version です。v1 は `1` です。

### `name`

asset name です。

rules:

- `personal-` で始める。
- lower kebab-case にする。
- target tool へ生成される artifact name の base に使える名前にする。

### `kind`

asset の種類を表す意味ラベルです。**用途に応じて選びます**。配置のされ方は kind ごとに
下表の「配置挙動」のとおりで、配備対象は skill 系 (`skill` / `prompt` / `workflow` /
`template` → skill target) と `instruction` (→ tool 別の `CLAUDE.md` / `AGENTS.md`) の
2 系統です。`agent` は現状どの target にも解決されず未対応 (unsupported) です。kind が
どの artifact に解決されるかの仕組みは [compatibility / artifact_kind](#compatibility)
を参照してください。

| kind | 意味・用途 | 配置挙動 (artifact_kind) |
| --- | --- | --- |
| `skill` | モデルが必要時に参照する手順・能力のまとまり。`SKILL.md` 本体 + 任意の `references/` `assets/` `evals/`。 | `skill` |
| `prompt` | 定型のプロンプト断片やテンプレート的な指示。 | `skill` (skill として配置) |
| `workflow` | 複数ステップの再利用可能な作業手順。 | `skill` |
| `template` | 出力フォーマットなどの雛形。 | `skill` |
| `instruction` | 常時読まれる運用ルール。tool 別の `CLAUDE.md` / `AGENTS.md` として生成。詳細は [Instruction Artifact Kind](instruction-artifact-kind.md)。 | `instruction` |
| `agent` | サブエージェント定義。**現状は配備未対応** (各 tool の agent 形式へのマッピングが未設計)。register では `unsupported` になる。 | 未対応 |

補足:

- `prompt` / `workflow` / `template` は現状いずれも **skill として build・配置** されます
  (skill の意味別名)。意味のラベルとして使い分けつつ、配られ方は skill と同じです。
  必要なら `compatibility.<tool>.artifact_kind` で明示的に上書きできます。
- `agent` kind は現状 build 対象外で、配備したい需要が出た時点で設計します
  (各 tool の agent 形式へのマッピングが論点)。
- `shared/` 配下のサブディレクトリ (`skills/` `prompts/` `workflows/` `agents/`
  `instructions/`) は **整理のための置き場所**で、kind を決定しません。asset の kind は
  必ず manifest の `kind` フィールドで決まります (discovery は sidecar manifest
  `shared/**/*.asset.yml` と directory manifest `shared/**/asset.yml` の両方)。
  例: `personal-project-operating-loop` は `workflows/` 配下にありつつ `kind: workflow`
  → skill として配置されます。

### `visibility`

asset の公開・送信可否を表します。

tracked files に置いてよい values:

- `public`: public repository に載せてよい汎用 asset。LLM review 可。
- `personal`: 個人用途だが、機密情報や個人情報を含まず public repository に載せてよい
  asset。LLM review 可。

tracked files に置かない values:

- `private`: private local config や非公開情報に依存する asset。
- `work`: 会社管理情報や業務固有情報を含む asset。
- `client`: client / customer / third-party confidential material を含む asset。
- `secret`: secret、credential、private endpoint、token、key を含む asset。

`private`、`work`、`client`、`secret` の asset は、この public repository に commit しません。

### `targets`

生成・同期の対象 tool です。

v1 allowed values:

- `codex`
- `claude-code`

empty list は不可です。target 未定の場合は register 対象にしません。

### `risk`

asset の review risk です。

required keys:

- `prompt_injection`: `low`, `medium`, `high`, `unknown`
- `privacy`: `low`, `medium`, `high`, `unknown`

rules:

- `high` は register fail。
- `medium` は human review 必須。
- `unknown` は register 前に review 必須。
- `low` は registration 可。

### `source`

source-of-truth の場所です。

required keys:

- `path`: repository root からの relative path。
- `format`: `markdown`, `yaml`, `json`, `toml`, `text`, `directory` のいずれか。

rules:

- absolute path は禁止。
- private planning tool の URL は書かない。
- source path は `shared/` 配下に置く。

## Optional fields

```yaml
summary: reusable operating loop for personal agent projects
description: public-safe workflow for deciding where project artifacts live
review:
  static_check: pending
  llm_review: allowed
  human_review: pending
compatibility:
  codex:
    artifact_kind: skill
  claude-code:
    artifact_kind: skill
```

### `summary`

短い説明です。生成された catalog や status output に表示できます。

### `description`

長めの説明です。secret、private endpoint、local path、private planning tool の情報を含めません。

### `review`

review 状態です。

allowed values:

- `static_check`: `pending`, `pass`, `fail`
- `llm_review`: `allowed`, `blocked`, `not_needed`
- `human_review`: `pending`, `approved`, `rejected`, `not_needed`

`human_review` は人間が宣言する値で、register が medium finding の解決に参照します。
`static_check` / `llm_review` は informational で、自動 check の結果は
[catalog](register-catalog.md) 側を真実とします。

### `compatibility`

target tool ごとの変換 hint です。

`compatibility.<tool>.artifact_kind` で、その tool 向けに生成する artifact の種類を
明示できます。未指定なら asset の `kind` から既定値が導出されます (`instruction` kind は
instruction、`skill` / `prompt` / `workflow` / `template` は skill)。

build が対応する artifact_kind は `skill` と `instruction` です。どちらも build →
register → sync で配置されます (instruction の所有確立は connect が担当)。

- `skill`: `<tool home>/skills/personal-<name>/` に directory として配る。
- `instruction`: tool 別の単一ファイル (claude-code は `CLAUDE.md`、codex は `AGENTS.md`)
  として生成する。詳細は [Instruction Artifact Kind](instruction-artifact-kind.md)。

この field の他の用途は adapter 実装が読むための optional metadata で、strict validation
しません。

## Public repository rule

tracked manifest は public-safe でなければなりません。

manifest に書かないもの:

- private planning tool の種類や URL。
- absolute local path。
- token、credential、secret、private key。
- private endpoint。
- work / client / customer / third-party confidential material。
- LLM review に送れない private content。

## Sample

sample manifest:

- [personal-project-operating-loop.asset.yml](../shared/workflows/personal-project-operating-loop.asset.yml)

source asset:

- [personal-project-operating-loop.md](../shared/workflows/personal-project-operating-loop.md)

## 実装で決めたこと

validator は `scripts/check-manifests.sh` として実装済みです。

- 実装言語: Ruby (macOS 標準、YAML stdlib)。外部依存ゼロ、network access なし。
- manifest discovery: `shared/**/*.asset.yml` と `shared/**/asset.yml`。
- validation error format: `path: message` の line 単位。error があれば exit 1。
- `shared/<category>/` 直下の asset source に manifest が無い場合も error にする。

残りの論点は [Register / Catalog](register-catalog.md) で設計済みです。

- generated catalog: JSON、`generated/catalog.json`、commit しない。
- check result は manifest に書き戻さず、catalog に出す。
- status / doctor への露出は register summary として contract v2 で追加する。
