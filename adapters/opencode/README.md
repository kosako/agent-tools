# OpenCode Adapter

shared assets を OpenCode 向け artifacts に変換する spec です。
実装は `scripts/lib/build.rb` にあります (#295)。

## v1 で生成する artifact kind

- `plugin` だけ。

`kind: plugin` の asset が `plugin` として生成されます。`compatibility.opencode.artifact_kind`
での上書きは受け付けません: `artifact_kind: plugin` への override は script と同じく禁止
(#184 の原則) で、opencode に配れる kind は plugin だけなので、上書きに正当用途がありません
(check-manifests が error にする)。`skill` / `instruction` / `script` は OpenCode には配りません
(理由は [Tool Compatibility 方針](../../docs/tool-compatibility.md)「tool と artifact_kind の組」)。
tool と kind の組の正本は `scripts/lib/artifact_targets.rb` の `TOOL_KINDS` です。

## 出力 layout

```text
generated/opencode/plugins/
  personal-<name>.js     (単一 file。先頭 1 行が JS ブロックコメント marker。mode 0644)
```

- **plugin**: source (`shared/plugins/personal-<name>.js`。ESM、外部依存ゼロの単一 `.js`) を
  byte 保持で copy し、先頭に marker 行 1 行 + `"\n"` を前置する。2 行目以降は source の bytes と
  一致する。実行 bit は付けない (OpenCode が import する module で、単独で実行するものではない)。
  directory 形式と `.ts` は非対応 (check-manifests が error にし、build は
  `plugin must be a single .js file, not a directory` で skip する)。
- marker: 本体先頭の 1 行 JS ブロックコメント。生成と解析は `scripts/lib/plugin_marker.rb`
  (`PluginMarker.render` / `parse`) に集約し、instruction の HTML コメント marker
  (`InstructionMarker`) とは module を分ける (互いの marker を拒否する)。format は
  [Status / Manifest Contract](../../docs/status-manifest-contract.md)。`build_id` は
  source content の sha256 から作り、marker 行自体は build_id に含めない。
- source 側の制約 (check-manifests が検証): UTF-8 として正しいこと、先頭が `#!` でも
  `/* agent-tools:managed` でもないこと (前者は import される module に意味が無く、後者は build が
  前置する marker と二重になる)。詳細は
  [Asset Manifest Schema](../../docs/asset-manifest-schema.md)「plugin source の制約」。
- `build --prune` は `generated/opencode/plugins/` の regular file のうち、manifest に対応せず
  かつ先頭行の marker を parse できるものだけを削除し、marker の無い file は
  `kept (unmanaged, no agent-tools marker)` で残す。`generated/opencode/skills/` や
  `generated/codex/plugins/` は走査しない (`TOOL_KINDS` の組だけを回す)。

## Sync 先 (参照)

- plugin: [Sync Policy](../../docs/sync-policy.md) の許可 pattern
  `~/.config/opencode/plugins/personal-*.js` を sync が直接配置する (connect 不要。mode 0644)。
  OpenCode では plugins/ に file を置くこと自体が plugin の登録になる (`opencode.json` への登録は
  不要。`--pure` で起動すると読まれない)。

build は `generated/` にのみ書き込み、tool directories には書き込みません。
