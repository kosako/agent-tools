# Project Tracking 方針

`agent-tools` は `dotfiles` とは別に tracking します。

## 現在の決定

- GitHub repository: `https://github.com/kosako/agent-tools`
- local repository path: developer-specific。ここでは固定しない。
- project planning / management docs は `dotfiles` project とは分離し、repository 外で別管理する。
- GitHub issues: `dotfiles` issues とは分離する。
- 実作業は GitHub Issue と PR で管理する。
- public repository には private planning tool の種類、URL、document list を書かない。
- 具体的な参照先は ignored local note にだけ書く。

## 別管理の planning docs

project を進めるための planning / management docs は repository 外で管理します。
tracked docs には、何の document があるか、どの tool を使うか、どこを見ればよいかは書きません。

repository に残す docs は、public に共有してよい policy、boundary、仕様、運用ルールに限定します。
private な参照先や project-specific な planning index は local-only note に置きます。

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

agent が project を進めるときは、この workflow を参照して external planning docs /
GitHub Issue / PR / repository docs の置き場所を判断します。

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

> これは初期計画時点の記録です。現在地は [onboarding](onboarding.md) を参照。
> 1-4 は実装・テスト済み (manifest schema / injection checker / build adapters /
> dry-run sync)。5 (optional LLM review) のみ未着手で、#43 の external scanner の
> LLM mode に統合する方針。

1. shared asset manifest schema を定義する。
2. static prompt injection checker を実装する。
3. Codex / Claude Code 向け build adapters を実装する。
4. management marker enforcement つき dry-run sync を実装する。
5. privacy preflight つき optional LLM review を追加する。
