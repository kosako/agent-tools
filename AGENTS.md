# Agent 向け指示

この repository は個人用 AI agent assets を管理します。
local development environment の control plane ではありません。

この repository は public です。tracked file はすべて publishable として扱ってください。

## 境界

- `dotfiles` は別 repository / 別 project として扱う。
- project planning / management docs は `dotfiles` と分離して別管理する。
- 具体的な管理 tool や参照先は tracked files に書かず、local-only note を参照する。
- 実作業は GitHub Issue に切り、変更は PR で管理する。
- 基本 workflow は `shared/workflows/personal-project-operating-loop.md` を参照する。
- tokens、credentials、private endpoints、client data、work data を追加しない。
- private local paths、private planning URLs、internal hostnames、scratch handoff notes を
  tracked files に追加しない。
- 特定の secret store 実装を前提にした変更を入れない。
- `dotfiles` からこの repository を自動 clone / pull / sync しない。

## Asset ルール

- shared source assets は `shared/` に置く。
- tool-specific generation rules は `adapters/` に置く。
- generated artifacts は `generated/` に置き、Git では ignore する。
- generated asset names は `personal-` で始める。
- `AGENTS.md` と `CLAUDE.md` は将来生成してもよいが、v1 では tool homes へ
  auto-sync しない。

## Sync ルール

- sync は default dry-run にする。
- tool directories へ書き込む場合は、明示的な `--apply` flag を必須にする。
- sync が更新してよいのは agent-tools management marker を持つ target のみ。
- unmanaged な同名 target は上書きせず、conflict として停止する。
- tool-managed、company-managed、cache、auth、session、runtime state directories は触らない。

## Prompt Injection Gate

登録する asset はすべて prompt injection review を通す。

- static checks は必須。
- LLM review は補助 gate。
- LLM review に送ってよいのは public / personal assets のみ。
- work、client、secret、private-endpoint の疑いがある assets は LLM review に送らない。
- high risk findings は registration fail。
- medium risk findings は human review 必須。
- low risk findings は pass 可。

## 現在の phase

scaffold と policy documentation は完了し、check scripts の実装 phase に入っています。

- 実装済み: manifest validation (`scripts/check-manifests.sh`)、
  static prompt injection checks (`scripts/check-injection.sh`)、
  build adapters (`scripts/build.sh`)、dry-run sync (`scripts/sync.sh`)、
  report-only status (`scripts/status.sh`)。
- script の実装は、対応する GitHub Issue で明示的に scope された範囲だけで行う。
- issue で scope されていない build、sync、register、doctor scripts を
  先回りで実装しない。
