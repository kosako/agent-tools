# Sync Policy

Sync moves generated personal assets from this repository into local tool
directories. It must be conservative by default.

## Defaults

- Sync is dry-run by default.
- Real writes require `--apply`.
- Sync only handles generated assets whose names start with `personal-`.
- Sync only updates targets containing an agent-tools management marker.
- Same-name unmanaged targets are conflicts and must stop the sync.

## v1 Codex Targets

Allowed target pattern:

```text
~/.codex/skills/personal-*
```

Forbidden targets:

```text
~/.codex/skills/.system
~/.codex/plugins
~/.codex/cache
~/.codex/auth.json
~/.codex/config.toml
~/.codex/*.sqlite
```

## v1 Claude Code Targets

Allowed target pattern:

```text
~/.claude/skills/personal-*
```

Forbidden targets:

```text
~/.claude/cache
~/.claude/sessions
~/.claude/projects
```

## Other Forbidden Runtime State

```text
~/.agents/skills/*/db
~/.agents/skills/*/teams
```

## Management Marker

The exact marker format is not implemented yet. A follow-up issue should define
a marker that includes:

- repository name: `agent-tools`
- generated asset name
- target tool
- source path
- generation timestamp or build id

Sync must refuse to modify files or directories that lack the marker.

## v1 Exclusions

`AGENTS.md` and `CLAUDE.md` may be generated as artifacts for inspection, but v1
must not auto-sync them into tool homes.
