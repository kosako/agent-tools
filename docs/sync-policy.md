# Sync Policy

sync は、この repository で生成した personal assets を local tool directories に反映します。
default は必ず conservative にします。

## Default 方針

- sync は default dry-run。
- 実際の書き込みには `--apply` を必須にする。
- sync が扱うのは、名前が `personal-` で始まる generated assets のみ。
- sync が更新してよいのは、agent-tools management marker を含む targets のみ。
- 同名の unmanaged targets は conflict として扱い、sync を停止する。

## v1 Codex targets

許可する target pattern:

```text
~/.codex/skills/personal-*
```

禁止する targets:

```text
~/.codex/skills/.system
~/.codex/plugins
~/.codex/cache
~/.codex/auth.json
~/.codex/config.toml
~/.codex/*.sqlite
```

## v1 Claude Code targets

許可する target pattern:

```text
~/.claude/skills/personal-*
```

禁止する targets:

```text
~/.claude/cache
~/.claude/sessions
~/.claude/projects
```

## その他の禁止 runtime state

```text
~/.agents/skills/*/db
~/.agents/skills/*/teams
```

## Management Marker

正確な marker format はまだ実装しません。
follow-up issue で、少なくとも以下を含む marker を定義します。

- repository name: `agent-tools`
- generated asset name
- target tool
- source path
- generation timestamp または build id

sync は marker を持たない files / directories の変更を拒否します。

## v1 exclusions

`AGENTS.md` と `CLAUDE.md` は inspection 用 artifact として生成してもよいですが、
v1 では tool homes へ auto-sync しません。
