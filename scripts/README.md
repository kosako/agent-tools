# Scripts

Planned scripts:

- `build.sh`: generate tool-specific artifacts from shared source assets.
- `check-injection.sh`: run static prompt injection checks and optional LLM
  review.
- `register.sh`: validate and register assets into the local catalog.
- `sync.sh`: dry-run or apply generated artifacts into tool directories.
- `doctor.sh`: inspect local environment assumptions without modifying state.

No runnable scripts are included in the scaffold phase. This avoids implying
that sync behavior is already implemented or safe to run.
