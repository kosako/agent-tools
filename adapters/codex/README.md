# Codex Adapter

shared assets を Codex 向け artifacts に変換する spec です。
実装は `scripts/lib/build.rb` にあります。

## v1 で生成する artifact kind

- `skill` / `instruction` / `script`。

manifest の `compatibility.codex.artifact_kind` で明示できます。
未指定の場合、`kind` が `skill` / `prompt` / `workflow` / `template` の asset は
`skill`、`kind: instruction` は `instruction`、`kind: script` は `script` として
生成します。`agent` は v1 では生成しません。

## 出力 layout

```text
generated/codex/skills/<name>/
  SKILL.md
  .agent-tools-managed.yml
generated/codex/instructions/
  AGENTS.md              (kind: instruction。先頭に 1 行コメント marker)
generated/codex/scripts/
  personal-<name>                         (単一実行ファイル。mode 0755)
  personal-<name>.agent-tools-managed.yml (sidecar marker)
```

- **skill**: single-file asset は source content を `SKILL.md` の body にする。source が
  YAML frontmatter を持たない場合のみ、manifest の `name` と `summary` から frontmatter を
  生成する。directory asset は `asset.yml` と source-only dir (現状 `evals/`) を除く
  全 files を copy する (非配置 dir は build_id にも含めない)。
- **instruction**: 単一ファイルを `AGENTS.md` に生成し、本体先頭に 1 行コメント marker を
  付ける。directory 形式の instruction は非対応。
- **script**: 単一実行ファイルを byte 保持で copy し (mode 0755)、隣に sidecar marker を
  出力する。directory 形式の script は非対応 (単一ファイルのみ buildable)。
- marker: skill は directory 直下の `.agent-tools-managed.yml`、instruction は本体先頭の
  1 行 HTML コメント、script は本体の隣の sidecar `.agent-tools-managed.yml`。format は
  [Status / Manifest Contract](../../docs/status-manifest-contract.md)。`build_id` は
  source content の sha256 から作る。

## Sync 先 (参照)

- skill: [Sync Policy](../../docs/sync-policy.md) の許可 pattern `~/.codex/skills/personal-*`。
- instruction: connect が確立した所有ファイル `~/.codex/AGENTS.md` を sync が更新する。
- script: `~/.codex/agent-tools/scripts/personal-*` (sidecar marker つき) を sync が直接配置する。

build は `generated/` にのみ書き込み、tool directories には書き込みません。
