# Tool Compatibility 方針

`agent-tools` はひとつの shared source of truth を持ち、そこから tool-specific artifacts を生成します。

## 初期 target tools

| Tool | Source | Generated target | v1 sync |
| --- | --- | --- | --- |
| Codex | `shared/` | `generated/codex/` | `~/.codex/skills/personal-*` |
| Claude Code | `shared/` | `generated/claude-code/` | `~/.claude/skills/personal-*` |

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

## 未決事項

- Codex skills 向け adapter schema。
- Claude Code skills 向け adapter schema。
- generated artifacts に review reports を同梱するか。
- review 後の prompt injection risk metadata をどう表現するか。
