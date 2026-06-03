# Publication Safety 方針

`agent-tools` は public repository として公開する前提です。
tracked file はすべて publishable として扱います。

## 公開してよい内容

許可するもの:

- generic reusable skills。
- generic prompt templates。
- generic workflow descriptions。
- public documentation。
- private configuration を露出しない tool adapter logic。

許可しないもの:

- secrets、tokens、credentials、passwords、private keys、session data。
- 意図的に公開済みのものを超える personal data。
- work、client、customer、third-party の confidential material。
- private endpoints、internal hostnames、production URLs、access details。
- local-only handoff notes、scratch files、machine-specific paths。
- private local inputs から生成された assets。

## Review checklist

commit 前に確認すること:

- secret-like strings と private paths を text scan する。
- local handoff notes が ignore されていることを確認する。
- generated artifacts が ignore されていることを確認する。ただし `.gitkeep` や `README.md`
  のような意図的な documentation は例外。
- LLM review 対象の asset が public / personal で、local machine の外へ送って安全であることを確認する。

## Default decision

迷った場合、その asset は公開しません。review できるまで local に留めます。
