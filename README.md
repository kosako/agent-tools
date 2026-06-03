# agent-tools

`agent-tools` is a personal AI agent asset repository for reusable skills,
prompts, workflows, agent definitions, and instruction templates.

This repository is intentionally separate from `dotfiles`.
It is intended to be public, so tracked content must be safe to publish.

```text
dotfiles
  policy / capabilities / directory conventions / safety gates

agent-tools
  skills / prompts / AGENTS.md templates / agent definitions / evals

secret store / local private config
  tokens / credentials / private endpoints
```

## Principles

- Keep Codex and Claude Code assets in one shared source repository.
- Generate tool-specific artifacts from shared source assets.
- Sync generated artifacts explicitly; do not rely on symlinks in v1.
- Default every sync command to dry-run.
- Require an explicit `--apply` flag before writing to tool directories.
- Only manage generated assets whose names start with `personal-`.
- Only update targets that contain an agent-tools management marker.
- Stop on conflicts when a same-name target is unmanaged.
- Never store secrets, credentials, private endpoints, or client/work material.
- Keep project tracking separate from the `dotfiles` Notion project.

## Public Repository Safety

Do not commit secrets, credentials, private endpoints, work/client material,
private local paths, runtime state, or generated artifacts derived from private
inputs. See [SECURITY.md](SECURITY.md) and
[docs/publication-safety.md](docs/publication-safety.md).

## Repository Layout

```text
shared/
  skills/         Shared source skills.
  prompts/        Shared source prompts.
  workflows/      Shared reusable workflows.
  agents/         Shared agent definitions.
  instructions/   Shared instruction templates.

adapters/
  codex/          Codex-specific build adapter specs.
  claude-code/    Claude Code-specific build adapter specs.

generated/
  codex/          Generated Codex artifacts. Ignored except .gitkeep.
  claude-code/    Generated Claude Code artifacts. Ignored except .gitkeep.

scripts/          Planned build, check, register, sync, and doctor scripts.
docs/             Boundary and policy documents.
```

## Initial Scope

The first issue for this repository is deliberately narrow:

1. Establish the repository scaffold.
2. Document the boundary with `dotfiles`.
3. Document sync policy and forbidden targets.
4. Document prompt injection check policy.
5. Document Codex / Claude Code compatibility assumptions.

Build, sync, registration, and prompt injection checker implementations belong
in follow-up issues.

## License

MIT. See [LICENSE](LICENSE).
