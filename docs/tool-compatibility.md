# Tool Compatibility

`agent-tools` keeps one shared source of truth and generates tool-specific
artifacts.

## Initial Target Tools

| Tool | Source | Generated target | v1 sync |
| --- | --- | --- | --- |
| Codex | `shared/` | `generated/codex/` | `~/.codex/skills/personal-*` |
| Claude Code | `shared/` | `generated/claude-code/` | `~/.claude/skills/personal-*` |

## Compatibility Rules

- Prefer shared source assets whenever semantics are portable.
- Use adapters for tool-specific file names, metadata, and directory layout.
- Keep target artifacts generated and reproducible.
- Do not place target-specific implementation details in shared assets unless
  they are explicitly modeled as compatibility metadata.

## Not In v1

- Automatic sync of `AGENTS.md`.
- Automatic sync of `CLAUDE.md`.
- Company-managed skills.
- Tool-standard bundled skills.
- Runtime state migration.
- Secret or credential distribution.
- Private local path or endpoint distribution.

## Open Questions

- Shared asset schema and manifest format.
- Adapter schema for Codex skills.
- Adapter schema for Claude Code skills.
- Whether generated artifacts should include review reports alongside outputs.
- How to represent prompt injection risk metadata after review.
