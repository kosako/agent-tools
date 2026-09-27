# Status / Manifest Contract

`dotfiles` と `agent-tools` が将来連携するための contract 設計です。

この document は設計です。`status` / `doctor` の実装コード、build / sync の実装、
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
  "contract_version": 3,
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
  "register": {
    "catalog_present": true,
    "registered": 1,
    "human_review_required": 0,
    "unsupported": 0
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

- `contract_version`: この contract の version。現行は `3`
  (v2 で `register` を追加、v3 で target state に `deployed_but_inactive` を追加 #186)。
  `plugin` kind と `opencode` target (#295) では上げていない: field の集合も値の意味も変わらず、
  `sync_targets[].tool` の値に `opencode` が増えるだけで、旧 reader (dotfiles の doctor) の解釈が
  壊れないため (version を上げると dotfiles の doctor が status を解釈しなくなる。
  [Register / Catalog](register-catalog.md)「catalog_version は上げない」と同じ判断)。
- `repo.present`: agent-tools repository が存在するか。
- `repo.clean`: working tree が clean か。
- `assets.total`: tracked manifest の数。
- `assets.manifest_errors`: manifest validation error の数。
- `checks.*`: 各 check の最新結果。`pass`, `fail`, `human_review`, `not_run`。
- `generated.total`: 生成済み artifact の数。
- `generated.stale`: source より古い artifact の数。
- `register.*`: [catalog](register-catalog.md) の summary。target-artifact 単位の
  `registered` / `human_review_required` / `unsupported` のカウント。catalog 不在時や
  `catalog_version` 不一致時は `catalog_present: false` と zero counts。
- `sync_targets[].tool`: `codex` / `claude-code` / `opencode` (`ArtifactTargets::TOOLS`)。opencode の
  行は plugin (`plugins/personal-<name>.js`) を指す。
- `sync_targets[].state`: 後述の target state。

### Target state

| state | 意味 |
| --- | --- |
| `managed` | agent-tools marker を持ち、最新の generated artifact と一致する。 |
| `stale` | agent-tools marker を持つが、generated artifact より古い。 |
| `conflict` | 同名 target が存在するが marker を持たない (unmanaged)。 |
| `missing` | generated artifact はあるが、target がまだ存在しない。 |
| `deployed_but_inactive` | catalog entry が registered でない (human_review_required / unsupported) のに、target 実体がディスクに残っている (一度承認して配布 → 後で gate がかかった等)。sync は配置も削除もしないため、手動掃除か再承認まで居座る (#186)。 |

`conflict` の target は sync が変更してはいけません。

## Management marker format

generated artifact が agent-tools 管理であることを示す marker です。
[Sync Policy](sync-policy.md) の enforcement は、この marker を前提にします。

### Single-file artifact (instruction: markdown / text)

file 先頭に 1 行の HTML コメント marker を埋め込みます。markdown の場合:

```markdown
<!-- agent-tools:managed v=1 repo=agent-tools name=personal-example target=claude-code artifact_kind=instruction source=shared/instructions/personal-example.md build_id=sha256:... -->
```

生成・解析は `scripts/lib/instruction_marker.rb` に集約し、build (生成) と
connect / sync (所有判定) が同じ format を共有します。

### Single-file artifact (script): sidecar marker

script のように本体を改変できない (任意の interpreter / shebang を壊さない) 単一ファイルは、
本体の隣に `<artifact name>.agent-tools-managed.yml` を置きます。本体は byte 単位で保持し、
所有情報は sidecar file 側に持たせます。中身は directory artifact の marker と同じ YAML です。

```yaml
repo: agent-tools
name: personal-example
target: claude-code
source: shared/scripts/personal-example.sh
build_id: sha256:...
```

配置先は `<tool home>/agent-tools/scripts/<name>` (本体) と同 `<name>.agent-tools-managed.yml`
(sidecar)。本体は実行可能 (mode 0755) で配置します。

### Single-file artifact (plugin): 先頭 1 行の JS ブロックコメント marker (#295)

OpenCode の plugin (`plugins/personal-<name>.js`) は、file 先頭の 1 行に JS ブロックコメントの
marker を埋め込みます。OpenCode は `plugins/*.js` を import するので sidecar を置くと別 file と
して読まれうるため、本体側に持たせます (instruction と同じ「本体先頭 1 行」戦略。ただし export に
はしない)。2 行目以降は source の bytes をそのまま保ちます。

```javascript
/* agent-tools:managed v=1 repo=agent-tools name=personal-example target=opencode artifact_kind=plugin source=shared/plugins/personal-example.js build_id=sha256:... */
```

生成・解析は `scripts/lib/plugin_marker.rb` (`PluginMarker.render` / `parse` / `managed?` /
`matches?`) に集約し、build (生成) と sync / status / doctor (所有・鮮度判定) が共有します。
instruction の `InstructionMarker` とは module を分け、互いの marker を拒否します
(`InstructionMarker.parse` は plugin marker に nil、`PluginMarker.parse` は instruction marker に
nil)。InstructionMarker の挙動 (先頭行の strip / CRLF 受容 / 非 UTF-8 の scrub) は変えません。

解析は先頭行 (最初の `\n` の手前) だけを厳密に読み、次のどれかに当たれば marker 無し
(unmanaged = sync では conflict、prune では skip) と判定します: 先頭行が `/* agent-tools:managed ` で
始まらない / ` */` で終わらない、先頭行に制御文字 (`\r` / `\t` を含む) がある、先頭行が UTF-8 と
して不正、token が単一空白区切りでない、`key=value` の形でない・value が空、key の重複、key の
集合が `v repo name target artifact_kind source build_id` と完全一致しない (余分な key を含む)、
`v` が `1` でない、`repo` が `agent-tools` でない、`artifact_kind` が `plugin` でない、`build_id` が
`sha256:` で始まらない、`source` が `/` で始まる。2 行目以降にある marker は見ません。

### Directory artifact

directory 直下に `.agent-tools-managed.yml` を置きます。

```yaml
repo: agent-tools
name: personal-example
target: claude-code
source: shared/skills/personal-example
build_id: sha256:...
```

### Marker rules

- `repo` は固定で `agent-tools`。
- `name` は manifest の `name` と一致させる。
- `target` は manifest の `targets` のいずれかと一致させる (plugin は `opencode` のみ)。
- `source` は repository root からの relative path。absolute path は禁止。
- `build_id` は source content の sha256。stale 判定に使う。
- marker を持たない同名 target は `conflict` とし、sync は停止する。

## dotfiles が読んでよい情報

- status output contract の JSON 全体。
- 各 target の state (`managed` / `stale` / `conflict` / `missing` / `deployed_but_inactive`)。
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
- `doctor` への status 統合: `scripts/doctor.sh` (`Doctor::Runner#check_repo_and_assets`) で実装済み。
