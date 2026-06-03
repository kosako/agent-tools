# agent-tools

`agent-tools` は、再利用可能な skills、prompts、workflows、agent definitions、
instruction templates を管理するための個人用 AI agent asset repository です。

この repository は `dotfiles` とは意図的に分離します。
public repository として公開する前提なので、追跡する内容はすべて公開可能なものに限定します。

```text
dotfiles
  policy / capabilities / directory convention / safety gates

agent-tools
  skills / prompts / AGENTS.md templates / agent definitions / evals

secret store / local private config
  tokens / credentials / private endpoints
```

## 原則

- Codex と Claude Code の資産は、ひとつの共通 source repository で管理する。
- 共通 source asset から tool 別 artifact を生成する。
- 生成 artifact の反映は明示 sync とし、v1 では symlink に依存しない。
- sync は default dry-run にする。
- tool directory へ書き込む場合は、明示的な `--apply` flag を必須にする。
- 管理対象は `personal-` で始まる生成 asset のみとする。
- agent-tools 管理 marker を持つ target だけを更新する。
- 同名 target が unmanaged の場合は、上書きせず conflict として停止する。
- secrets、credentials、private endpoints、client/work material は保存しない。
- project planning / management docs は `dotfiles` と分離して別管理する。
- 実作業は GitHub Issue / PR で管理する。
- 基本 workflow は [personal-project-operating-loop](shared/workflows/personal-project-operating-loop.md) で管理する。

## 公開 repository の安全方針

secrets、credentials、private endpoints、work/client material、private local
paths、runtime state、private input から生成した artifacts は commit しません。
詳細は [SECURITY.md](SECURITY.md) と
[docs/publication-safety.md](docs/publication-safety.md) を参照してください。

## Repository 構成

```text
shared/
  skills/         共通 source skills
  prompts/        共通 source prompts
  workflows/      共通 reusable workflows
  agents/         共通 agent definitions
  instructions/   共通 instruction templates

adapters/
  codex/          Codex 向け build adapter specs
  claude-code/    Claude Code 向け build adapter specs

generated/
  codex/          生成された Codex artifacts。README と .gitkeep 以外は ignored。
  claude-code/    生成された Claude Code artifacts。README と .gitkeep 以外は ignored。

scripts/          build / check / register / sync / doctor scripts の予定地。
docs/             boundary と policy documents。
```

## 初期 scope

この repository の最初の issue scope は、意図的に小さくします。

1. repository scaffold を作る。
2. `dotfiles` との boundary を document にする。
3. sync policy と forbidden targets を document にする。
4. prompt injection check policy を document にする。
5. Codex / Claude Code compatibility assumptions を document にする。

build、sync、registration、prompt injection checker の実装は follow-up issue で扱います。

## License

MIT. 詳細は [LICENSE](LICENSE) を参照してください。
