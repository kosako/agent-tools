# Scripts

すべての scripts は外部依存ゼロ・network access なしで実行できます。
実装は macOS 標準の Ruby (YAML stdlib) を使います。

`tests/` の self-tests と repository checks は CI (`.github/workflows/test.yml`) で
PR / push ごとに実行されます。

## 実装済み

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

- `build.sh`: shared source assets から tool 別 artifacts を `generated/` に生成する。
  adapter spec は [adapters/](../adapters/README.md) を参照。

```text
usage: build.sh [--root DIR] [--quiet]
```

- 生成前に manifest validation と static injection check を必ず通す。
  gate が fail のときは何も生成しない。
- 各 artifact に management marker (`.agent-tools-managed.yml`) を埋め込む。
  `build_id` は source content の sha256 なので build は決定的。
- 書き込み先は `generated/` のみ。tool directories には書き込まない。
- self-test: `tests/build-test.sh`

- `sync.sh`: `generated/` の personal assets を tool directories へ反映する。
  [Sync Policy](../docs/sync-policy.md) を enforce する。

```text
usage: sync.sh [--root DIR] [--apply] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- default は dry-run。書き込みには `--apply` が必須。
- plan は `create` / `update` / `skip (up-to-date)` / `conflict` で表示される。
- 更新するのは agent-tools management marker を持つ target のみ。
  unmanaged な同名 target は conflict として exit 1 で停止し、何も書き込まない。
- 書き込み先は `<tool home>/skills/personal-*` のみ。それ以外の path は構成しない。
- `--codex-home` / `--claude-home` は inspection / test 用の override。
- self-test: `tests/sync-test.sh` (fake home のみを使い、実際の tool homes には触れない)
- 残課題: `stale` / `missing` state の status 連携は `status.sh` 実装時に扱う。

- `status.sh`: report-only status。
  [Status / Manifest Contract](../docs/status-manifest-contract.md) の JSON を出力する。

```text
usage: status.sh [--root DIR] [--json] [--codex-home DIR] [--claude-home DIR]
```

- `--json` で contract_version 1 の JSON、省略時は human-readable summary。
- manifest validation / injection check の結果、generated の stale 数、
  sync target state (managed / stale / conflict / missing) を含む。
- read-only。いかなる state も変更しない。
- 出力に absolute local paths / secrets を含めない。
- self-test: `tests/status-test.sh`

## 予定している scripts

- `check-injection.sh` への追加: optional LLM review (privacy preflight つき)。
- `register.sh`: assets を validate し、local catalog に register する。
  設計は [Register / Catalog](../docs/register-catalog.md) で確定済み。
- `sync.sh`: generated artifacts の tool directories への反映を dry-run または apply する。
- `doctor.sh`: state を変更せず、local environment assumptions を inspect する。

sync / build 系 scripts は、対応する GitHub Issue で scope されるまで実装しません。
