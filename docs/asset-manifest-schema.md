# Asset Manifest Schema

shared asset を register / build / sync する前に読む machine-readable metadata の
schema 方針です。

この document は設計です。parser、validator、build、sync の実装コードは含めません (実装状態は末尾の節)。

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

### skill source の制約

directory 形式の配置ルールと、両 source 形式に共通する frontmatter 契約 (Phase 1):

- `SKILL.md` / `references/` / `assets/` は配置先 (`<tool home>/skills/personal-<name>/`)
  に載せる (ランタイム skill の一部)。
- `evals/` は **source として版管理するが配置先には載せない**。skill-creator 等の
  テスト材料であり、ランタイム skill の一部ではない。build はコピーから除外し、
  build_id にも含めない (eval 編集だけでは配置成果物は変わらない)。テストプロンプトは
  「skill が転記/実行しないこと」を検証するため意図的に攻撃的な文字列 (injection 文字列・
  fake な絶対パス・email 等) を含みうるので、injection check はそれらを evals では抑止する。
  ただし inline の private key 本体だけは fixture で不要なため evals でも検知する。
- **実行コードを含む directory skill は fail-closed で拒否する** (#178)。配る前に実行コードを
  安全検査する能力がまだ無いため、check-manifests が error にして gate を止める (黙ってスキップ
  しない)。判定は **任意の深さを再帰**し、(1) `scripts/` 名の subdirectory (top-level に限らず
  `evals/scripts/` や `bin/` 配下も) と、(2) **実行ビットの立った regular file** を拒否する。
  evals/ (非配置) も除外しない (実行コードの持ち込み自体を止める)。対応は external scanner
  連携の後 (#43)。shebang / 内容ベースの実行形式検出は false-positive を避けるため #43 に defer。
- directory asset に **symlink / 特殊ファイル** (regular file・directory 以外: FIFO /
  socket / device 等) が含まれると **fail-closed** で拒否する。build の `cp_r` / build_id 計算が
  symlink を辿り `shared/` の外の内容を generated/ へ脱出させうるため、check-manifests が
  error にして gate を止める。
- **directory skill は `SKILL.md` を entrypoint として必須**にする (#187 M-01)。build は
  directory skill の `SKILL.md` を無改変でコピーする (単一ファイル skill と違い frontmatter を
  生成しない) ため、無いと entrypoint 欠落の inert skill が配布される。
- **skill の既存 frontmatter `name` は manifest name と一致必須** (#187 M-01, #234)。
  directory の `SKILL.md` と、既存 frontmatter を持つ単一 source に共通で適用する。
  frontmatter が在る (先頭が `---` 行) のに閉じ marker 欠落 / YAML parse 不能 (alias 等) /
  非 mapping / name 欠落・空・型不正なら **fail-closed** で拒否する。LF / CRLF に対応する。
- **Codex に skill として生成する場合、非空 string の `description` も必須** (#234)。
  [Codex の skill 契約](https://learn.chatgpt.com/docs/build-skills) に合わせ、frontmatter の無い
  directory skill は拒否する。frontmatter の無い単一 source は既存どおり build が manifest の
  name と summary (無ければ description、さらに無ければ name) から補完する。
  [Claude Code の省略規則](https://code.claude.com/docs/en/skills#frontmatter-reference) に沿い、
  Claude-only skill の frontmatter 不在・description 省略は許可する。判定は manifest の
  kind ではなく target ごとの解決済み artifact_kind に従い、instruction / script は対象外。
  build / register はこの静的検証を共有する。根拠は 2026-09-06 に確認した上記公式契約:
  Claude Code は全 frontmatter field が任意で、name の省略時は directory 名、description の
  省略時は本文の先頭段落を使う。runtime loader を起動した検証ではない。
- **Claude Code skill の native 実行・事前許可機能は未対応として拒否**する (#233)。
  検査対象は source entrypoint (directory の `SKILL.md` / 単一 source) に限る。
  実 frontmatter の `allowed-tools` / `hooks` は空値も含めて拒否し、本文の inline / fenced
  dynamic shell command は非空 command を含む場合に拒否する。理由は下記「Native skill 機能」。
- **asset source の入れ子・重複所有を禁止**する (#177 H-01)。directory asset の source dir 配下に
  その asset 自身の manifest 以外の manifest を置くと fail-closed で拒否する (子 asset が独立
  配布されつつ親の evals/ 抑止で injection check を回避する経路を断つ)。

manifest metadata を asset 本体の frontmatter と分ける理由:

- target tool が独自 frontmatter を持つ可能性がある。
- shared metadata と target-specific metadata を混ぜない。
- markdown 以外の asset にも同じ考え方を使える。

### Native skill 機能

`allowed-tools` は事前許可の grant であり、利用可能 tool の制限ではない。`hooks` と dynamic
shell command も host が実行する機能なので、通常の説明文と分けて検査する。これらを安全に
配布する機能は現段階で提供せず、`check-manifests` が拒否する。build / register は同じ gate で
停止し、`human_review: approved` でも未対応機能の拒否は解除しない。承認 schema は変更しない。

| 解決済み target artifact | この拒否 gate の扱い |
| --- | --- |
| `claude-code` の `skill` | `allowed-tools` / `hooks` / dynamic shell command を拒否 |
| `codex` のみの `skill` | Claude 固有の実行構文による拒否は適用しない。Codex の必須 frontmatter 検証は適用する |
| `instruction` / `script` | この skill 用検査の対象外。既存の kind 別 gate を適用する |

一つの source を両 target の skill に配る場合は、Claude Code 向けに拒否された時点で asset の
build / register 全体が停止する。片側だけ登録しない。これは host の permissions を変更したり、
Codex でこれらの機能の実行を承認したりする仕組みではない。

[Claude Code の dynamic context 契約](https://code.claude.com/docs/en/skills#inject-dynamic-context)
と 2.1.259 の静的 parser に基づき、inline は行頭または空白直後の bang + backtick 構文、fenced は
三連 backtick + bang で始まる構文を扱う (改行無しの fenced 形も含む)。空または空白だけの
command は実行形に数えない。通常の inline-code span に隠れた説明は除外するが、Markdown の
code fence 全体を一律には除外しない。コード例でも host が実行する形をそのまま載せれば拒否する。
`KEY=` 直後や backslash 直後の bang は inline command の開始にならない。

本文中の `allowed-tools` / `hooks` という説明や YAML コード例、frontmatter の `metadata` 内の
同名 key はこの検査の対象外。`references/` / `assets/` / 非配置の `evals/` の説明文も entrypoint
として解析しない。既存の injection / 実行 bit / symlink 検査の対象範囲は変更しない。

### plugin source の制約

`kind: plugin` の asset (OpenCode の `plugins/*.js` として配る実行コード, #295) の source は、
`shared/plugins/personal-<name>.js` と sidecar manifest `personal-<name>.asset.yml` の対です
(sidecar が無ければ既存どおり `asset source is missing sidecar manifest` の error)。
check-manifests は、`source` の通常の検査 (相対 path / `shared/` 配下 / symlink・不在・traversal の
拒否) が error を出さなかったときだけ、続けて次を検査します。いずれも fail-closed の error です。

| 条件 | error 文言 (`<manifest_path>: ` が前置される) |
| --- | --- |
| `source.format` が `directory` | `plugin asset must be a single .js file, not a directory format` |
| `source.path` が `.js` で終わらない (`.ts` / `.mjs` を含む) | `plugin source must be a .js file, got "<source.path>"` |
| source 全体が UTF-8 として不正 | `plugin source must be valid UTF-8: <source.path>` |
| source の先頭が `#!` | `plugin source must not start with "#!": <source.path>` |
| source の先頭が `/* agent-tools:managed` | `plugin source must not start with "/* agent-tools:managed": <source.path>` |

理由: OpenCode の loader は `plugins/*.{ts,js}` を import する (`.ts` は transpile しないので扱わない)。
shebang は import される module に意味が無く、marker の prefix は build が前置するもので、source
側にあると先頭行が二重になる。UTF-8 の検査を source 全体に当てるのは、配置後の所有判定
(`PluginMarker.parse`) が先頭行しか見ないため、file 全体の正しさをここで担保するためです。
形は ESM の単一 file で、export は `export default { id, server }` だけに限ります (名前付き export は
OpenCode の legacy loader がすべて plugin 関数として扱うため置かない。形の詳細は
[adapters/opencode/README.md](../adapters/opencode/README.md))。

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

manifest に書けるキーはこの schema が列挙するものに限ります。**top-level・入れ子を問わず
未知キーは check-manifests が error にします** (fail-closed。typo を silent に無視しない)。

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
下表の「配置挙動」のとおりで、配備対象は skill 系 (`skill` / `prompt` / `workflow`
→ skill target)、`instruction` (→ tool 別の `CLAUDE.md` / `AGENTS.md`)、
`script` (→ `<tool home>/agent-tools/scripts/personal-<name>` の単一実行ファイル)、
`plugin` (→ `<opencode home>/plugins/personal-<name>.js`。opencode 専用) の 4 系統です。
`agent` は現状どの target にも解決されず未対応 (unsupported) です。kind が
どの artifact に解決されるかの仕組みは [compatibility / artifact_kind](#compatibility)
を、tool ごとに配れる artifact_kind は下記 [`targets`](#targets) の表を参照してください。

| kind | 意味・用途 | 配置挙動 (artifact_kind) |
| --- | --- | --- |
| `skill` | モデルが必要時に参照する手順・能力のまとまり。`SKILL.md` 本体 + 任意の `references/` `assets/` `evals/`。 | `skill` |
| `prompt` | 定型のプロンプト断片やテンプレート的な指示。 | `skill` (skill として配置) |
| `workflow` | 複数ステップの再利用可能な作業手順。 | `skill` |
| `instruction` | 常時読まれる運用ルール。tool 別の `CLAUDE.md` / `AGENTS.md` として生成。詳細は [Instruction Artifact Kind](instruction-artifact-kind.md)。 | `instruction` |
| `script` | tool home に配る実行可能な script body (hook / wrapper 等)。単一ファイルのみ。 | `script` |
| `plugin` | OpenCode の process の中で動く plugin (ESM の単一 `.js`)。target は `opencode` のみ。常に human review 必須 ([Register / Catalog](register-catalog.md))。 | `plugin` |
| `agent` | サブエージェント定義。**現状は配備未対応** (各 tool の agent 形式へのマッピングが未設計)。register では `unsupported` になる。 | 未対応 |

補足:

- `prompt` / `workflow` は現状いずれも **skill として build・配置** されます
  (skill の意味別名)。意味のラベルとして使い分けつつ、配られ方は skill と同じです。
  必要なら `compatibility.<tool>.artifact_kind` で明示的に上書きできます。
  (旧 `template` kind は使用 asset ゼロ・skill 写像の別名として区別に消費者がいなかった
  ため撤去 (#153)。雛形は `prompt` か `skill` を使います。)
- `agent` kind は現状 build 対象外で、配備したい需要が出た時点で設計します
  (各 tool の agent 形式へのマッピングが論点)。
- `shared/` 配下のサブディレクトリ (`skills/` `prompts/` `workflows/` `agents/`
  `instructions/` `scripts/` `plugins/`) は **整理のための置き場所**で、kind を決定しません。asset の kind は
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
- `opencode` (#295)

empty list は不可です。target 未定の場合は register 対象にしません。

tool ごとに受け取れる artifact_kind は `scripts/lib/artifact_targets.rb` の `TOOL_KINDS` で
決まります。check-manifests は、targets の各 tool について resolve 後の artifact_kind がこの表に
あるかを検査し、**build 対応 kind なのに表に無い組だけを error** にします
(`artifact_kind <kind> cannot be distributed to <tool> (<tool> accepts: ...)`。
例: `artifact_kind plugin cannot be distributed to codex (codex accepts: skill, instruction, script)` /
`artifact_kind skill cannot be distributed to opencode (opencode accepts: plugin)`)。
`agent` のような build 非対応 kind は従来どおり error にせず、register が `unsupported` にします。

| tool | 受け取る artifact_kind | 表に無い組の扱い |
| --- | --- | --- |
| `codex` | `skill` / `instruction` / `script` | `plugin` → manifest error |
| `claude-code` | `skill` / `instruction` / `script` | `plugin` → manifest error |
| `opencode` | `plugin` | `skill` / `instruction` / `script` → manifest error |
| (すべて) | — | `agent` (build 非対応) → register の `unsupported` |

OpenCode に skill / instruction / script を配らない理由は
[Tool Compatibility 方針](tool-compatibility.md)「tool と artifact_kind の組」。

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
- skill に生成する source は、形式によらず上記の [skill source の制約](#skill-source-の制約) に従う。

## Optional fields

```yaml
summary: reusable operating loop for personal agent projects
description: public-safe workflow for deciding where project artifacts live
review:
  human_review: pending
compatibility:
  codex:
    artifact_kind: instruction
```

### `summary`

短い説明です。生成された catalog や status output に表示できます。

### `description`

長めの説明です。secret、private endpoint、local path、private planning tool の情報を含めません。

### `review`

人間が宣言する review 状態です。

allowed values:

- `human_review`: `pending`, `approved`, `rejected`, `not_needed`
- `approved_build_id`: build_id 文字列 (`sha256:` + full 64 hex, #184)。
  `human_review: approved` と対で使う (単独はエラー)。
- `approved_artifact_kind`: `skill` / `instruction` / `script` / `plugin`。`human_review: approved`
  と対で使う (単独はエラー)。

`human_review` は人間が宣言する値で、register が medium finding の解決に参照します。
承認 identity は **(内容, 配布形態) の対** です (#148, #184): `approved_build_id`
(承認時点の build_id) が現在の build_id と一致し、**かつ** `approved_artifact_kind` が
その target の解決済み artifact_kind と一致するときだけ効きます。内容が同じでも kind を
変えれば (例: skill → script = 実行ファイル配布) 承認は失効し、再レビューが要ります
([register-catalog.md](register-catalog.md) の #148 節)。
`human_review: approved` の asset は **全 targets が単一の artifact_kind に解決される**
必要があります (混在は scalar の `approved_artifact_kind` で承認を満たせないため
check-manifests が error にする。kind ごとに asset を分割する)。

機械計測の結果 (static check 等) は manifest に書かず [catalog](register-catalog.md) 側を
真実とします。旧 `static_check` / `llm_review` フィールドは消費者不在の informational
だったため撤去しました (#153)。LLM review 層 (外部送信前の privacy gate 含む) を作るときは
#43 の設計にあわせて宣言を再導入します。

### `compatibility`

target tool ごとの変換 hint です。

`compatibility.<tool>.artifact_kind` で、その tool 向けに生成する artifact の種類を
明示できます。未指定なら asset の `kind` から既定値が導出されます (`instruction` kind は
instruction、`script` kind は script、`plugin` kind は plugin、`skill` / `prompt` / `workflow` は
skill)。
**既定どおりの値は書きません** (既定値の重複宣言は導出 mapping との drift 面になるため、
kind から導出が変わるときだけ明示します, #153)。
**`artifact_kind: script` / `artifact_kind: plugin` への override は禁止です** (#184, #295):
実行コードの配布形態 (script = 実行ファイル、plugin = OpenCode の process 内で動く module) は
manifest の `kind: script` / `kind: plugin` でのみ宣言でき、override で他 kind の source を実行
コード配布に変えることはできません (check-manifests が
`compatibility.<tool>.artifact_kind: <kind> is not allowed; declare kind: <kind> in the manifest
instead (#184)` の error にする。kind で宣言すれば既定導出されるので override に正当用途が無い。
正本は `CheckManifests::NON_OVERRIDABLE_KINDS`)。
tool キーは `targets` と同じ語彙 (`codex` / `claude-code` / `opencode`)、`artifact_kind` は
build 対応 kind (`skill` / `instruction` / `script` / `plugin`) に限られ、check-manifests が
検証します (typo は silent に unsupported へ落とさず error にする)。tool と kind の組は
[`targets`](#targets) の表に従い、表に無い組は override で明示しても error になります。

build が対応する artifact_kind は `skill` / `instruction` / `script` / `plugin` です。いずれも
build → register → sync で配置されます (instruction の所有確立は connect が担当)。

- `skill`: `<tool home>/skills/personal-<name>/` に directory として配る。
- `instruction`: tool 別の単一ファイル (claude-code は `CLAUDE.md`、codex は `AGENTS.md`)
  として生成する。詳細は [Instruction Artifact Kind](instruction-artifact-kind.md)。
- `script`: `<tool home>/agent-tools/scripts/personal-<name>` に単一実行ファイル (mode 0755)
  + sidecar marker として配る。**単一ファイルのみ対応** (source.format が directory の script は
  unsupported)。本体は byte 単位で保持する。配置先と marker は
  [Sync Policy](sync-policy.md) / [Status / Manifest Contract](status-manifest-contract.md)。
- `plugin`: `<opencode home>/plugins/personal-<name>.js` に単一 file (mode 0644) として配る。
  marker は本体先頭の 1 行 JS ブロックコメント。**単一の `.js` のみ対応** (directory / `.ts` は
  上記「plugin source の制約」で manifest error)。2 行目以降は source を byte 単位で保持する。
  target は `opencode` だけで、配置先と marker は [Sync Policy](sync-policy.md) /
  [Status / Manifest Contract](status-manifest-contract.md)、adapter は
  [adapters/opencode/README.md](../adapters/opencode/README.md)。

`compatibility` に書けるのは上記のみです: tool キーは `codex` / `claude-code` / `opencode`、その下は
`artifact_kind` の 1 キーだけで、**未知の tool キー・未知の下位キーは check-manifests が
error にします** (fail-closed。「optional metadata は strict validation しない」という
旧記述は実装と乖離していたため是正, #176 Low)。

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
- status / doctor への露出は register summary として contract v2 で追加済み (現行の contract
  版は `docs/status-manifest-contract.md` が正本)。
