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

## 予定している scripts

- `build.sh`: shared source assets から tool-specific artifacts を生成する。
- `check-injection.sh`: static prompt injection checks と optional LLM review を実行する。
- `register.sh`: assets を validate し、local catalog に register する。
- `sync.sh`: generated artifacts の tool directories への反映を dry-run または apply する。
- `doctor.sh`: state を変更せず、local environment assumptions を inspect する。

sync / build 系 scripts は、対応する GitHub Issue で scope されるまで実装しません。
