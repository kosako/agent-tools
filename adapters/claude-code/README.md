# Claude Code Adapter

shared assets を Claude Code 向け artifacts に変換する spec です。
実装は `scripts/lib/build.rb` にあります。

## v1 で生成する artifact kind

- `skill` と `instruction`。

manifest の `compatibility.claude-code.artifact_kind` で明示できます。
未指定の場合、`kind` が `skill` / `prompt` / `workflow` / `template` の asset は
`skill`、`kind: instruction` は `instruction` として生成します。`agent` は v1 では
生成しません。

## 出力 layout

```text
generated/claude-code/skills/<name>/
  SKILL.md
  .agent-tools-managed.yml
generated/claude-code/instructions/
  CLAUDE.md              (kind: instruction。先頭に 1 行コメント marker)
```

- **skill**: single-file asset は source content を `SKILL.md` の body にする。source が
  YAML frontmatter を持たない場合のみ、manifest の `name` と `summary` から frontmatter を
  生成する。directory asset は `asset.yml` を除く全 files を copy する。
- **instruction**: 単一ファイルを `CLAUDE.md` に生成し、本体先頭に 1 行コメント marker を
  付ける。directory 形式の instruction は非対応。
- marker: skill は directory 直下の `.agent-tools-managed.yml`、instruction は本体先頭の
  1 行 HTML コメント。format は
  [Status / Manifest Contract](../../docs/status-manifest-contract.md)。`build_id` は
  source content の sha256 から作る。

## Sync 先 (参照)

- skill: [Sync Policy](../../docs/sync-policy.md) の許可 pattern `~/.claude/skills/personal-*`。
- instruction: connect が確立した所有ファイル `~/.claude/agent-tools/CLAUDE.md` を sync が更新する。

build は `generated/` にのみ書き込み、tool directories には書き込みません。
