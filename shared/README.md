# Shared Assets

This directory contains source-of-truth assets that can be adapted for multiple
agent tools.

All asset names that may be registered or synced must start with `personal-`.

Recommended asset metadata for future implementation:

- `name`
- `kind`
- `audience`
- `visibility`
- `risk`
- `targets`

The first scaffold phase does not define a strict schema yet. A follow-up issue
should introduce a machine-readable manifest before registration scripts are
implemented.
