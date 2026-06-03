# Project Tracking 方針

`agent-tools` は `dotfiles` とは別に tracking します。

## 現在の決定

- GitHub repository: `https://github.com/kosako/agent-tools`
- local repository path: developer-specific。ここでは固定しない。
- Notion project: `dotfiles` project とは分離する。
- GitHub issues: `dotfiles` issues とは分離する。
- Notion page / database は project planning と knowledge management の正とする。
- 実作業は GitHub Issue と PR で管理する。
- public repository には private Notion URL を書かない。

## Notion に置くもの

Notion には、project を進めるための設計・計画・判断材料を集約します。

- 設計メモ。
- 計画。
- アイデア。
- 作業ログ。
- 方針の背景。
- issue に切る前の検討。
- issue / PR の結果を受けた project-level な更新。

Notion 側は随時最新化します。repository に残す docs は、public に共有してよい
policy、boundary、仕様、運用ルールに限定します。

## GitHub Issue / PR に置くもの

実際の作業単位は GitHub Issue に切り、変更は PR で管理します。

- 実装 task。
- docs 更新 task。
- bug fix。
- follow-up work。
- review 可能な成果物。

PR は対応する issue に紐づけます。小さなメンテナンスでも、原則として issue と
PR を使って履歴を残します。

## 共通 workflow

この進め方自体も repository 内の shared asset として管理します。

- [personal-project-operating-loop](../shared/workflows/personal-project-operating-loop.md)

agent が project を進めるときは、この workflow を参照して Notion / GitHub Issue /
PR / repository docs の置き場所を判断します。

## 最初の issue

タイトル:

```text
Scaffold agent-tools repository and document safety policies
```

scope:

- repository scaffold を作る。
- `dotfiles` との boundary を document にする。
- sync policy を document にする。
- prompt injection check policy を document にする。
- initial Codex / Claude Code compatibility assumptions を document にする。

out of scope:

- build script implementation。
- sync script implementation。
- registration script implementation。
- prompt injection checker implementation。
- automatic `AGENTS.md` / `CLAUDE.md` sync。

## Follow-up issues

1. shared asset manifest schema を定義する。
2. static prompt injection checker を実装する。
3. Codex / Claude Code 向け build adapters を実装する。
4. management marker enforcement つき dry-run sync を実装する。
5. privacy preflight つき optional LLM review を追加する。
