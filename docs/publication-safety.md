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
- private planning / knowledge tool の URL、document list、参照先 (具体は git 管理しない `.agent-context.local.md` に置く)。
- local-only handoff notes、scratch files、machine-specific paths。
- private local inputs から生成された assets。

## Review checklist

commit 前に確認すること:

- secret-like strings と private paths を text scan する。
- 差分と commit message は、hook の public-safety gate (pre-commit と commit-msg) が検査する。hook を通らない
  経路 (`--no-verify`、rebase など) があるので、[git-hook-gates](git-hook-gates.md) の強度ラベルを確認する。
- local-only file (`.agent-context.local.md` と `.agent-packets/`) が ignore されていることを確認する。
- generated artifacts が ignore されていることを確認する。ただし `.gitkeep` や `README.md`
  のような意図的な documentation は例外。
- LLM review 対象の asset が public / personal で、local machine の外へ送って安全であることを確認する。

投稿・push の前に確認すること:

- GitHub に出す text (Issue / PR の題名・本文・コメント、commit message、branch 名) は、投稿・push の前に
  `personal-public-safety-gate --stdin` に通し、exit 0 で警告が無いときだけ公開する。gate が無い・通らない・
  警告が出たときは公開せず、本文と結果を人に見せて確認を取る ([git-hook-gates](git-hook-gates.md) の stdin mode)。

## Default decision

迷った場合、その asset は公開しません。review できるまで local に留めます。
