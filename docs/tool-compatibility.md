# Tool Compatibility 方針

`agent-tools` はひとつの shared source of truth を持ち、そこから tool-specific artifacts を生成します。

## 初期 target tools

| Tool | Source | Generated target | v1 sync |
| --- | --- | --- | --- |
| Codex | `shared/` | `generated/codex/` | `~/.codex/skills/personal-*` |
| Claude Code | `shared/` | `generated/claude-code/` | `~/.claude/skills/personal-*` |

表の v1 sync 列は skill の配置先です。instruction は connect が確立した所有ファイル
(`~/.codex/AGENTS.md` / `~/.claude/agent-tools/CLAUDE.md`) を sync が更新します
([Instruction Artifact Kind](instruction-artifact-kind.md))。script は
`~/.codex/agent-tools/scripts/personal-*` / `~/.claude/agent-tools/scripts/personal-*`
(sidecar marker つき) を sync が直接配置します。下記「v1 で扱わないもの」の
`AGENTS.md` / `CLAUDE.md` の automatic sync は、人間が手書きするファイルを自動同期しない
という意味です (connect は import 1 行追加 / 空ファイルの claim のみを行う)。

## Compatibility ルール

- semantics が portable な場合は shared source assets を優先する。
- tool-specific file names、metadata、directory layout は adapters で扱う。
- target artifacts は generated / reproducible に保つ。
- shared asset metadata は sidecar manifest で管理し、target-specific metadata と混ぜない。
- target-specific implementation details は、compatibility metadata として明示 modeling
  しない限り shared assets に置かない。

## v1 で扱わないもの

- `AGENTS.md` の automatic sync。
- `CLAUDE.md` の automatic sync。
- company-managed skills。
- tool-standard bundled skills。
- runtime state migration。
- secret / credential distribution。
- private local path / endpoint distribution。

## 決定済み事項

- Codex / Claude Code artifact 向け adapter spec:
  [adapters/codex/README.md](../adapters/codex/README.md) /
  [adapters/claude-code/README.md](../adapters/claude-code/README.md)。
- review 結果は generated artifacts に同梱せず、
  [catalog](register-catalog.md) に別出しする。
- review 後の risk / registration 状態は catalog の `checks` と
  `registration` で表現する。
