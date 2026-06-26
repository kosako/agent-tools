# Scripts

すべての scripts は外部依存ゼロ・network access なしで実行できます。
実装は macOS 標準の Ruby (YAML stdlib) を使います。

`tests/` の self-tests と repository checks は CI (`.github/workflows/test.yml`) で
PR / push ごとに実行されます。

## 実装済み

- `setup.sh`: `build → register → connect → sync` を一括実行する一発 setup。
  初回 install と更新の両方に使える。詳細は
  [Install & Usage](../docs/install-and-usage.md)。

```text
usage: setup.sh [--apply] [--root DIR] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- **既定は dry-run**(plan を表示するだけ・実環境に書き込まない)。`--apply` を付けた
  ときだけ connect / sync に `--apply` を渡す。
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

- `build.sh`: shared source assets から tool 別 artifacts を `generated/` に生成する。
  adapter spec は [adapters/](../adapters/README.md) を参照。

```text
usage: build.sh [--root DIR] [--prune] [--quiet]
```

- 生成前に register と共有の致命 gate (`lib/gate.rb`) を通す。fail なら何も生成しない。
  medium finding では止めず生成する (中間物。配置は sync が catalog を見て止める)。
- management marker を埋め込む。skill は directory 直下の `.agent-tools-managed.yml`、
  instruction は本体先頭の 1 行 HTML コメント marker。`build_id` は source content の
  sha256 なので build は決定的。
- 書き込み先は `generated/` のみ。tool directories には書き込まない。
- `--prune` で manifest に対応しなくなった generated artifact を削除する。対象は
  agent-tools marker を持つ skill directory と instruction file のみで、marker のない
  directory / file は警告して残す。
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
usage: sync.sh [--root DIR] [--apply] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- default は dry-run。書き込みには `--apply` が必須。
- **catalog (`generated/catalog.json`) を尊重する。`registration: registered` の
  artifact だけを配置する。** `human_review_required` / catalog 不在は理由つきで skip。
  先に `register.sh` を実行する必要がある。
- plan は `create` / `update` / `skip` / `conflict` で表示される。
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
- medium finding は manifest の `review.human_review` と asset 単位で突き合わせる。
- exit code: 0 (全 registered) / 3 (human_review_required あり) / 1 (gate fail)。
- 書き込みは `generated/catalog.json` のみ。
- self-test: `tests/register-test.sh`

## 予定している scripts

- `check-injection.sh` への追加: optional LLM review (privacy preflight つき)。

scripts の実装は、対応する GitHub Issue で scope されるまで行いません。
