# Scripts

予定している scripts:

- `build.sh`: shared source assets から tool-specific artifacts を生成する。
- `check-injection.sh`: static prompt injection checks と optional LLM review を実行する。
- `register.sh`: assets を validate し、local catalog に register する。
- `sync.sh`: generated artifacts の tool directories への反映を dry-run または apply する。
- `doctor.sh`: state を変更せず、local environment assumptions を inspect する。

scaffold phase では runnable scripts は含めません。
sync behavior がすでに実装済み、または安全に実行可能であるかのように見えることを避けるためです。
