# Project Tracking 方針

`agent-tools` は `dotfiles` とは別に tracking します。

## 現在の決定

- GitHub repository: `https://github.com/kosako/agent-tools`
- local repository path: developer-specific。ここでは固定しない。
- Notion project: `dotfiles` project とは分離する。
- GitHub issues: `dotfiles` issues とは分離する。

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
