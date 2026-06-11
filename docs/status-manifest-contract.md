# Status / Manifest Contract

`dotfiles` と `agent-tools` が将来連携するための contract 設計です。

この document は設計です。`status` / `doctor` の実装、build / sync の実装、
dotfiles 側の実装は含めません。

## 目的

- `dotfiles` が report-only で読める最小情報を定義する。
- generated artifact の management marker format を定義する。
- conflict / stale / unmanaged target の表現を統一する。
- secret や private path を出力しない方針を contract に含める。

## 連携の方向

- `agent-tools` が status を生成し、`dotfiles` はそれを読むだけにする。
- `dotfiles` は agent-tools の state を変更しない。
- `agent-tools` は dotfiles を clone / pull / sync しない。

## Status output contract

`scripts/status.sh --json` は、以下の JSON を stdout に出力します。

```json
{
  "contract_version": 1,
  "repo": {
    "present": true,
    "clean": true
  },
  "assets": {
    "total": 1,
    "manifest_errors": 0
  },
  "checks": {
    "manifest_validation": "pass",
    "prompt_injection_static": "pass"
  },
  "generated": {
    "total": 0,
    "stale": 0
  },
  "sync_targets": [
    {
      "tool": "claude-code",
      "name": "personal-example",
      "state": "managed"
    }
  ]
}
```

### Fields

- `contract_version`: この contract の version。v1 は `1`。
- `repo.present`: agent-tools repository が存在するか。
- `repo.clean`: working tree が clean か。
- `assets.total`: tracked manifest の数。
- `assets.manifest_errors`: manifest validation error の数。
- `checks.*`: 各 check の最新結果。`pass`, `fail`, `human_review`, `not_run`。
- `generated.total`: 生成済み artifact の数。
- `generated.stale`: source より古い artifact の数。
- `sync_targets[].state`: 後述の target state。

### Target state

| state | 意味 |
| --- | --- |
| `managed` | agent-tools marker を持ち、最新の generated artifact と一致する。 |
| `stale` | agent-tools marker を持つが、generated artifact より古い。 |
| `conflict` | 同名 target が存在するが marker を持たない (unmanaged)。 |
| `missing` | generated artifact はあるが、target がまだ存在しない。 |

`conflict` の target は sync が変更してはいけません。

## Management marker format

generated artifact が agent-tools 管理であることを示す marker です。
[Sync Policy](sync-policy.md) の enforcement は、この marker を前提にします。

### Single-file artifact (markdown / text)

file 先頭に comment block を埋め込みます。markdown の場合:

```markdown
<!-- agent-tools-managed
repo: agent-tools
name: personal-example
target: claude-code
source: shared/workflows/personal-example.md
build_id: 20260611T000000Z
-->
```

comment 記法を持たない format (json など) では、sidecar marker file を使います。

### Directory artifact

directory 直下に `.agent-tools-managed.yml` を置きます。

```yaml
repo: agent-tools
name: personal-example
target: claude-code
source: shared/skills/personal-example
build_id: 20260611T000000Z
```

### Marker rules

- `repo` は固定で `agent-tools`。
- `name` は manifest の `name` と一致させる。
- `target` は manifest の `targets` のいずれかと一致させる。
- `source` は repository root からの relative path。absolute path は禁止。
- `build_id` は UTC timestamp または build hash。stale 判定に使う。
- marker を持たない同名 target は `conflict` とし、sync は停止する。

## dotfiles が読んでよい情報

- status output contract の JSON 全体。
- 各 target の state (`managed` / `stale` / `conflict` / `missing`)。
- checks の結果 (`pass` / `fail` / `human_review` / `not_run`)。

## dotfiles が読まない・status に含めない情報

- secrets、tokens、credentials、private keys、private endpoints。
- absolute local paths。target は `~/` 始まりの tilde 表記に正規化する。
- private planning tool の種類、URL、document list。
- work / client / customer / third-party confidential material。
- asset 本体の content。status は metadata と state のみを扱う。

## 実装状態

- `scripts/status.sh`: 実装済み (report-only、書き込みなし)。
- build adapters での marker 埋め込み: `scripts/build.sh` で実装済み。
- sync での marker enforcement: `scripts/sync.sh` で実装済み。

## 後続実装

- `doctor` への status 統合。
