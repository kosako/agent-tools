# Scripts

pipeline scripts (build / register / connect / sync / status / doctor と各種 check) は
network access なしで実行できます。実装は macOS 標準の Ruby (YAML stdlib) で、追加 gem は
不要です (status / doctor は repo 状態の確認に `git` 実行ファイルを使う。無い環境でも
crash せず該当項目が degrade するだけ)。**例外は `probe-credential-isolation.sh`**:
credential 隔離の実機検証 harness で、`gh` / `git` / `curl` と network に依存します
(CI では実行しない。下記該当節)。

`tests/` の self-tests と repository checks は CI (`.github/workflows/test.yml`) で
PR / push ごとに実行されます。

## 実装済み

- `setup.sh`: `build → register → connect → sync` を一括実行する一発 setup。
  初回 install と更新の両方に使える。詳細は
  [Install & Usage](../docs/install-and-usage.md)。

```text
usage: setup.sh [--apply] [--root DIR] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- **既定は dry-run**(connect / sync は plan 表示のみ・tool home に書き込まない。
  build / register は dry-run でも `generated/` と catalog を更新する)。`--apply` を
  付けたときだけ connect / sync に `--apply` を渡す。
- build の gate fail / connect・sync の conflict では停止する。register の human review
  待ち(exit 3)は非致命として継続し、note を出す(sync は registered のものだけ配置)。
- 引数は各 sub-script へ forward する(`--root` / `--quiet` は全段、`--codex-home` /
  `--claude-home` は connect / sync)。
- self-test: `tests/setup-test.sh`

- `check-manifests.sh`: sidecar asset manifests の static validation。
  [Asset Manifest Schema](../docs/asset-manifest-schema.md) v1 に従って検証する。

```text
usage: check-manifests.sh [--root DIR] [--quiet]
```

- error は `path: message` の line 単位で出力され、error があれば exit 1。
- manifest を持たない asset source も検出する。
- self-test: `tests/check-manifests-test.sh`

- `check-injection.sh`: shared assets への static prompt injection checks。
  [Prompt Injection Check 方針](../docs/prompt-injection-check.md) に従う。

```text
usage: check-injection.sh [--root DIR] [--quiet]
```

- findings は `path:line: [risk] category: message` 形式で出力される。
- exit code: high findings は 1 (registration fail)、medium のみは 3
  (human review 必須)、findings なしまたは low のみは 0。
- 対象は `shared/` 配下の text files のみ。policy docs は対象外。
- self-test: `tests/check-injection-test.sh`

- `check-credential-isolation.sh`: credential 隔離 acceptance harness の判定コア。probe 結果
  (JSON) を受け、隔離が破れていないか判定する (probe の実機実行は `probe-credential-isolation.sh`)。
  [Credential Isolation Acceptance](../docs/credential-isolation-acceptance.md) に従う。

```text
usage: check-credential-isolation.sh --judge <results.json>
```

- required チャネル (`gh` / `git-https`。一覧の正本は lib の `REQUIRED_CHANNELS` / `--help`) に
  同一 operation の negative/positive ペアを 1 組以上要求し、credential leak・空振り緑・チャネル
  欠落を弾く。`git-ssh` / `curl` は ambient 認証源がセッション依存のため opt-in (含めれば完全ペア
  必須、無くても欠落扱いしない)。
- exit code: 隔離確認は 0、観測された破れ (leak / false-green) は 1、usage / 入力・構造エラー
  (チャネル欠落・ペア不成立・重複) は 2。破れと構造不備が同居したら 1 を優先し全件報告する。
- self-test: `tests/check-credential-isolation-test.sh`

- `probe-credential-isolation.sh`: credential 隔離 acceptance harness の probe runner (実機)。
  required チャネル (gh / git-https) + opt-in (git-ssh / curl) を private target に隔離 / 非隔離で
  叩き、認証成否を `results.json` (judge 入力) として出力する。隔離 recipe の SSOT は
  `lib/credential_isolation_recipe.sh`。

```text
usage: probe-credential-isolation.sh [--config PATH] [--out FILE] [--dry-run]
```

- probe target は local config 由来 (既定 `~/.config/dotfiles/github-isolation-probe.local`、
  `GITHUB_ISOLATION_PROBE_CONFIG` / `--config` で上書き)。public repo にハードコードしない・
  不在時は明示 fail。`--dry-run` は credential に触れず組み立てを表示する。
- **CI では実行しない** (credential 不在)。hard 保証は実機ログ (PR 添付) が正本で、CI 緑を
  根拠にしない ([Credential Isolation Acceptance](../docs/credential-isolation-acceptance.md))。
- self-test: `tests/probe-credential-isolation-test.sh` (実 credential に触れず recipe の env
  構造 / config 不在 fail / dry-run を検証)。

- `build.sh`: shared source assets から tool 別 artifacts を `generated/` に生成する。
  adapter spec は [adapters/](../adapters/README.md) を参照。

```text
usage: build.sh [--root DIR] [--prune] [--quiet]
```

- 生成前に register と共有の致命 gate (`lib/gate.rb`) を通す。fail なら何も生成しない。
  medium finding では止めず生成する (中間物。配置は sync が catalog を見て止める)。
- management marker を埋め込む。skill は directory 直下の `.agent-tools-managed.yml`、
  instruction は本体先頭の 1 行 HTML コメント marker、script は本体の隣の sidecar
  `.agent-tools-managed.yml`。`build_id` は source content の sha256 なので build は決定的。
- 書き込み先は `generated/` のみ。tool directories には書き込まない。
- `--prune` で manifest に対応しなくなった generated artifact を削除する。対象は
  agent-tools marker を持つ skill directory / instruction file / script (本体 + sidecar) の
  みで、marker のない directory / file は警告して残す。
- self-test: `tests/build-test.sh`

- `connect.sh`: instruction の所有ファイルを確立し、人間の instruction ファイルから
  繋ぎ込む。[Instruction Artifact Kind](../docs/instruction-artifact-kind.md) に従う。

```text
usage: connect.sh [--root DIR] [--apply] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- default は dry-run。書き込みには `--apply` が必須。冪等(再実行しても安全)。
- **claude-code**: `<claude home>/agent-tools/CLAUDE.md` を所有ファイルとして作成し、
  人間の `<claude home>/CLAUDE.md` に `@agent-tools/CLAUDE.md` の import 1 行を足す
  (既にあれば no-op)。
- **codex**: import 非対応のため `<codex home>/AGENTS.md` を直接所有する
  (空ファイルのみ claim 可)。
- symlink / dir / 特殊ファイルは触らない。所有先に unmanaged な中身があれば
  conflict で停止し、何も書き込まない。先に `build.sh` で generated instruction が
  必要。instruction を配らない構成なら不要。
- self-test: `tests/connect-test.sh`

- `sync.sh`: `generated/` の personal assets を tool directories へ反映する。
  [Sync Policy](../docs/sync-policy.md) を enforce する。

```text
usage: sync.sh [--root DIR] [--apply] [--prune] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- default は dry-run。書き込みには `--apply` が必須。
- **catalog (`generated/catalog.json`) を尊重する。`registration: registered` の
  artifact だけを配置する。** `human_review_required` / catalog 不在は理由つきで skip。
  先に `register.sh` を実行する必要がある。
- plan は `create` / `update` / `skip` / `conflict` (と `--prune` 時の `delete`) で表示される。
- `--prune` で catalog に載らなくなった deployed asset を撤去する (`build --prune` の
  sync 版)。削除は marker 一致 + catalog 不在の orphan のみで、unmanaged / symlink は
  触らず skip 表示。実削除には `--apply` が必須。instruction は対象外
  ([sync-policy](../docs/sync-policy.md) の「撤去」)。
- 更新するのは agent-tools management marker を持つ target のみ。
  unmanaged な同名 target / symlink は conflict として exit 1 で停止し、何も書き込まない。
- 書き込み先は skill が `<tool home>/skills/personal-*`、instruction が connect 確立済みの
  所有ファイル (`~/.codex/AGENTS.md` / `~/.claude/agent-tools/CLAUDE.md`)、script が
  `<tool home>/agent-tools/scripts/personal-*` (単一実行ファイル + sidecar marker)。
  それ以外の path は構成しない。
- `--codex-home` / `--claude-home` は inspection / test 用の override。
- self-test: `tests/sync-test.sh` (fake home のみを使い、実際の tool homes には触れない)

- `status.sh`: report-only status。
  [Status / Manifest Contract](../docs/status-manifest-contract.md) の JSON を出力する。

```text
usage: status.sh [--root DIR] [--json] [--codex-home DIR] [--claude-home DIR]
```

- `--json` で contract_version 2 の JSON、省略時は human-readable summary。
- manifest validation / injection check の結果、generated の stale 数、
  sync target state (managed / stale / conflict / missing) を含む。
- read-only。いかなる state も変更しない。
- 出力に absolute local paths / secrets を含めない。
- self-test: `tests/status-test.sh`

- `doctor.sh`: state を変更せず、local environment assumptions を inspect する。

```text
usage: doctor.sh [--root DIR] [--codex-home DIR] [--claude-home DIR] [--agents-home DIR]
```

- ruby / git、status report の統合、tool homes、禁止 targets への marker
  誤存在、catalog の存在と鮮度を check する。
- 出力は `level: area: message` 形式 (ok / info / warn / fail)。fail があれば exit 1。
- read-only。paths は tilde 表記で出力し、secrets を含めない。
- self-test: `tests/doctor-test.sh`

- `register.sh`: assets を検証し、`generated/catalog.json` に登録状態を記録する。
  [Register / Catalog](../docs/register-catalog.md) に従う。

```text
usage: register.sh [--root DIR] [--quiet]
```

- gate は build と同じ。manifest error / high finding で fail し、catalog を更新しない。
- medium finding は manifest の `review.human_review` と asset 単位で突き合わせる。承認は
  `review.approved_build_id` が現在の build_id と一致し、かつ `review.approved_artifact_kind`
  が target の resolve 済み artifact_kind と一致するときだけ効く (内容と配布形態に紐づく
  承認, #148 #184)。
- exit code: 0 (human_review_required なし) / 3 (human_review_required あり) / 1 (gate fail)。
  unsupported は exit code に影響しない。
- 書き込みは `generated/catalog.json` のみ。
- self-test: `tests/register-test.sh`

## artifact_kind / tool を追加するときのチェックリスト

kind / tool の知識は `lib/artifact_targets.rb` に集約されているが (#152)、追加時に
触る場所は 1 箇所ではない。取り残しが docs drift・サイレント断裂の原因になるので、
追加 PR ではここを順に確認する。

**artifact_kind を追加するとき**:

1. `lib/artifact_targets.rb`: `SUPPORTED_KINDS` / `DEFAULT_BY_KIND` /
   `GENERATED_SUBDIRS` / `generated_path` / `target_path` / `buildable?`。
2. `lib/check_manifests.rb`: asset kind の列挙 `KINDS` (manifest の `kind` と
   artifact_kind は別物。後者の検証は `ArtifactTargets.supported?` を参照済み)。
3. `lib/build.rb`: `build_<kind>` の実装と `run` の分岐、`prune` の期待リスト。
   marker 戦略は [Status / Manifest Contract](../docs/status-manifest-contract.md)
   (directory = 直下 marker / 単一ファイル = sidecar / 本文コメント) に従う。
4. `lib/sync.rb`: `plan_<kind>` の実装 (所有 / stale / symlink 防御を既存 kind と
   対称に) と `apply` の分岐。
5. `lib/status.rb`: `generated_state` の鮮度判定が新 kind の marker を読めるか。
6. docs: この README の該当 script 節 /
   [Asset Manifest Schema](../docs/asset-manifest-schema.md) /
   [Register / Catalog](../docs/register-catalog.md) /
   [Sync Policy](../docs/sync-policy.md) / [onboarding](../docs/onboarding.md)。
7. tests: `tests/build-test.sh` / `sync-test.sh` / `status-test.sh` /
   `register-test.sh` に既存 kind と対称のケースを足す。

**tool を追加するとき** (v1 は 2 tool 固定。tool 語彙と home 既定値は #192 で一元化済み):

1. tool 一覧と home 既定値: `lib/artifact_targets.rb` の `TOOLS` と `default_homes`
   (build / sync / check-manifests / status / doctor はここを参照する)。
2. CLI flag: `sync` / `connect` / `status` / `doctor` の `main` に `--<tool>-home` を足す。
3. instruction を配るなら `ArtifactTargets::INSTRUCTION_FILENAMES` と connect の
   所有戦略 (import 対応可否)。

## 予定している scripts

- `check-injection.sh` への追加: optional LLM review (privacy preflight つき)。

scripts の実装は、対応する GitHub Issue で scope されるまで行いません。
