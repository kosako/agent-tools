# Publication Safety

`agent-tools` is intended to be public. Treat every tracked file as publishable.

## Public-Safe Content

Allowed:

- Generic reusable skills.
- Generic prompt templates.
- Generic workflow descriptions.
- Public documentation.
- Tool adapter logic that does not expose private configuration.

Not allowed:

- Secrets, tokens, credentials, passwords, private keys, or session data.
- Personal data beyond what is already intentionally public.
- Work, client, customer, or third-party confidential material.
- Private endpoints, internal hostnames, production URLs, or access details.
- Local-only handoff notes, scratch files, or machine-specific paths.
- Generated assets produced from private local inputs.

## Review Checklist

Before committing:

- Run a text scan for secret-like strings and private paths.
- Confirm that local handoff notes are ignored.
- Confirm that generated artifacts are ignored unless they are intentional
  documentation such as `.gitkeep` or `README.md`.
- Confirm that any asset marked for LLM review is public or personal and safe
  to send outside the local machine.

## Default Decision

When in doubt, do not publish the asset. Keep it local until it can be reviewed.
