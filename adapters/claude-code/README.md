# Claude Code Adapter

shared assets を Claude Code 向け artifacts に変換する spec です。
実装は `scripts/lib/build.rb` にあります。

## v1 で生成する artifact kind

- `skill` のみ。

manifest の `compatibility.claude-code.artifact_kind` で明示できます。
未指定の場合、`kind` が `skill` / `prompt` / `workflow` / `instruction` /
`template` の asset は `skill` として生成します。`agent` は v1 では生成しません。

## 出力 layout

```text
generated/claude-code/skills/<name>/
  SKILL.md
  .agent-tools-managed.yml
```

- single-file asset は source content を `SKILL.md` の body にする。
- source が YAML frontmatter を持たない場合のみ、manifest の `name` と
  `summary` から frontmatter を生成する。
- directory asset は `asset.yml` を除く全 files を copy する。
- `.agent-tools-managed.yml` は
  [Status / Manifest Contract](../../docs/status-manifest-contract.md) の
  management marker。`build_id` は source content の sha256 から作る。

## Sync 先 (参照)

[Sync Policy](../../docs/sync-policy.md) の許可 pattern `~/.claude/skills/personal-*`。
build は `generated/` にのみ書き込み、tool directories には書き込みません。
