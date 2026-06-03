# Boundary With dotfiles

`dotfiles` and `agent-tools` are separate repositories with separate project
tracking.

## dotfiles Owns

- AI execution environment policy.
- Capability declarations.
- Directory conventions.
- Safety gates for local machine setup.
- Report-only checks for the presence of optional companion repositories.

## agent-tools Owns

- Reusable personal skills.
- Prompt libraries.
- Workflow definitions.
- Agent definitions.
- Instruction templates.
- Tool-specific generated artifacts.
- Prompt injection review policy for registered assets.

## Neither Repository Owns

- Tokens.
- API keys.
- Credentials.
- Private endpoints.
- Client data.
- Work data.
- Runtime session state.

Those belong in a secret store or local private config that is explicitly out of
scope for this repository.

## Integration Rule

`dotfiles` must not automatically clone, pull, build, or sync `agent-tools`.

If `dotfiles` needs awareness of this repository, it may add report-only checks
that tell the user whether `agent-tools` exists at an expected path.
