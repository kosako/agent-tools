# Prompt Injection Check

Every registered asset must pass prompt injection review before it can be
registered or synced.

## Coverage

Check all registered asset types:

- skills
- prompts
- agents
- templates
- workflows
- instructions

## Static Checks

Static checks are required for every asset. They should detect:

- Attempts to override system or developer instructions.
- Requests to reveal or collect secrets, tokens, credentials, or private keys.
- Hidden instruction patterns such as "ignore previous instructions".
- Tool permission or approval policy bypass attempts.
- External exfiltration, network tunnel, or production access requests.
- Instructions to modify tool-managed, company-managed, auth, cache, session,
  or runtime state.

## LLM Review

LLM review is a supplemental gate.

Allowed for LLM review:

- public assets
- personal assets

Not allowed for LLM review:

- work assets
- client assets
- secret-like assets
- assets containing private endpoints
- assets with unclear ownership or confidentiality

When ownership or confidentiality is unclear, the asset must stay out of LLM
review and require human review instead.

## Risk Outcomes

- High risk: fail registration.
- Medium risk: require human review.
- Low risk: registration may proceed.

## Follow-up Implementation Notes

The static checker should be deterministic and runnable without network access.
The LLM review step should be optional and explicitly configured, with a privacy
gate that runs before any content is sent out.
