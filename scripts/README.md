# Scripts

すべての scripts は外部依存ゼロ・network access なしで実行できます。
実装は macOS 標準の Ruby (YAML stdlib) を使います。

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

## 予定している scripts

- `check-injection.sh` への追加: optional LLM review (privacy preflight つき)。
- `register.sh`: assets を validate し、local catalog に register する。
- `sync.sh`: generated artifacts の tool directories への反映を dry-run または apply する。
- `doctor.sh`: state を変更せず、local environment assumptions を inspect する。

sync / build 系 scripts は、対応する GitHub Issue で scope されるまで実装しません。
