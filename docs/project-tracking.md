# Project Tracking

`agent-tools` must be tracked separately from `dotfiles`.

## Current Decision

- GitHub repository: `https://github.com/kosako/agent-tools`
- Local repository path: developer-specific and intentionally not fixed here
- Notion project: separate from the `dotfiles` project
- GitHub issues: separate from `dotfiles` issues

## First Issue

Title:

```text
Scaffold agent-tools repository and document safety policies
```

Scope:

- Create repository scaffold.
- Document boundary with `dotfiles`.
- Document sync policy.
- Document prompt injection check policy.
- Document initial Codex / Claude Code compatibility assumptions.

Out of scope:

- Build script implementation.
- Sync script implementation.
- Registration script implementation.
- Prompt injection checker implementation.
- Automatic `AGENTS.md` or `CLAUDE.md` sync.

## Follow-up Issues

1. Define shared asset manifest schema.
2. Implement static prompt injection checker.
3. Implement build adapters for Codex and Claude Code.
4. Implement dry-run sync with management marker enforcement.
5. Add optional LLM review with privacy preflight.
