# Security

This is a public repository. Do not commit confidential or personal material.

## Do Not Commit

- API keys, tokens, passwords, private keys, or credentials.
- Private endpoints, internal hostnames, or production access details.
- Work, client, customer, or third-party confidential material.
- Local machine paths that reveal private environment details.
- Runtime state from Codex, Claude Code, or other agent tools.
- Generated artifacts that were built from private local inputs.

## Before Publishing Assets

Every asset should pass a publication review:

- It is safe to publish publicly.
- It does not contain secrets or personal data.
- It does not include prompt injection patterns.
- It does not request unsafe tool permission escalation.
- It does not rely on private local configuration.

If ownership or confidentiality is unclear, keep the asset out of this
repository until it has been reviewed.

## Reporting

If sensitive material is committed accidentally, rotate any affected secrets
first, then rewrite history or remove the content as appropriate.
