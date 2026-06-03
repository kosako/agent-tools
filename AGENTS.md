# Agent Instructions

This repository manages personal AI agent assets. It is not the control plane
for the local development environment.

This is a public repository. Treat every tracked file as publishable.

## Boundaries

- Treat `dotfiles` as a separate repository and project.
- Treat this repository's Notion tracking as separate from `dotfiles`.
- Do not add tokens, credentials, private endpoints, client data, or work data.
- Do not add private local paths, Notion URLs, internal hostnames, or scratch
  handoff notes to tracked files.
- Do not make changes that assume a specific secret store implementation.
- Do not automatically clone, pull, or sync this repository from `dotfiles`.

## Asset Rules

- Shared source assets live under `shared/`.
- Tool-specific generation rules live under `adapters/`.
- Generated artifacts live under `generated/` and are ignored by Git.
- Generated asset names must start with `personal-`.
- `AGENTS.md` and `CLAUDE.md` may be generated in the future, but v1 must not
  auto-sync them into tool homes.

## Sync Rules

- Sync must be dry-run by default.
- Writing to tool directories must require an explicit `--apply` flag.
- Sync may only update targets with an agent-tools management marker.
- Sync must stop on unmanaged same-name targets instead of overwriting them.
- Sync must not touch tool-managed, company-managed, cache, auth, session, or
  runtime state directories.

## Prompt Injection Gate

Every registered asset must pass prompt injection review.

- Static checks are required.
- LLM review is a supplemental gate.
- Only public or personal assets may be sent to LLM review.
- Work, client, secret, or private-endpoint suspected assets must not be sent to
  LLM review.
- High risk findings fail registration.
- Medium risk findings require human review.
- Low risk findings may pass.

## Current Phase

The current phase is scaffold and policy documentation only. Do not implement
build, sync, register, doctor, or injection-check scripts until a follow-up
issue explicitly scopes that work.
