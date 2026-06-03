# Security 方針

この repository は public です。機密情報や個人情報を commit しないでください。

## Commit してはいけないもの

- API keys、tokens、passwords、private keys、credentials。
- private endpoints、internal hostnames、production access details。
- work、client、customer、third-party の confidential material。
- private environment details を示す local machine paths。
- Codex、Claude Code、その他 agent tools の runtime state。
- private local inputs から build された generated artifacts。

## Asset を公開する前に

すべての asset は publication review を通してください。

- public に公開して安全である。
- secrets や personal data を含まない。
- prompt injection patterns を含まない。
- unsafe な tool permission escalation を要求しない。
- private local configuration に依存しない。

ownership や confidentiality が不明な場合は、review が完了するまでこの repository に入れないでください。

## 誤 commit 時の対応

sensitive material を誤って commit した場合は、まず影響を受ける secrets を rotate し、
その後に必要に応じて history rewrite または content removal を行ってください。
