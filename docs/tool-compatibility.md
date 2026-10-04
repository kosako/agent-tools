# Tool Compatibility 方針

`agent-tools` はひとつの shared source of truth を持ち、そこから tool-specific artifacts を生成します。

## 初期 target tools

| Tool | Source | Generated target | v1 sync |
| --- | --- | --- | --- |
| Codex | `shared/` | `generated/codex/` | `~/.codex/skills/personal-*` |
| Claude Code | `shared/` | `generated/claude-code/` | `~/.claude/skills/personal-*` |
| OpenCode | `shared/` | `generated/opencode/` | `~/.config/opencode/plugins/personal-*.js` (plugin のみ) |

表の v1 sync 列は Codex / Claude Code では skill の配置先、OpenCode では plugin の配置先です。
instruction は connect が確立した所有ファイル
(`~/.codex/AGENTS.md` / `~/.claude/agent-tools/CLAUDE.md`) を sync が更新します
([Instruction Artifact Kind](instruction-artifact-kind.md))。script は
`~/.codex/agent-tools/scripts/personal-*` / `~/.claude/agent-tools/scripts/personal-*`
(sidecar marker つき) を sync が直接配置します。下記「v1 で扱わないもの」の
`AGENTS.md` / `CLAUDE.md` の automatic sync は、人間が手書きするファイルを自動同期しない
という意味です (connect は import 1 行追加 / 空ファイルの claim のみを行う)。

### tool と artifact_kind の組

どの tool にどの artifact_kind を配れるかは `scripts/lib/artifact_targets.rb` の `TOOL_KINDS`
が正本です (#295)。build の生成と prune、sync の plan と prune、status の generated の列挙、
doctor の home の表示は、TOOLS 全体 × 全 kind ではなくこの表の組だけを回します。

| tool | 配る artifact_kind | 配らないもの |
| --- | --- | --- |
| `codex` | `skill` / `instruction` / `script` | `plugin` |
| `claude-code` | `skill` / `instruction` / `script` | `plugin` |
| `opencode` | `plugin` | `skill` / `instruction` / `script` |

OpenCode に skill と instruction を配らない理由: OpenCode は `~/.claude/skills/<name>/SKILL.md` を
global の skill として、`~/.claude/CLAUDE.md` を global の rules として直接読みます
(`~/.config/opencode/AGENTS.md` が無いとき。2026-09-26 に OpenCode 1.18.30 で実測、
[opencode-plugin-probe](opencode-plugin-probe.md) の M15)。Claude Code target に配った skill と、
dotfiles の `opencode.json` の instructions から参照される `~/.claude/agent-tools/CLAUDE.md` が
そのまま OpenCode にも届くので、同じ内容を `<opencode home>/skills/` に二重配布すると二重読込に
なります。script も配りません: `<home>/agent-tools/scripts/<name>` は dotfiles が参照する
公開契約で tool ごとに置き場を変えられず、OpenCode 向けの plugin は Claude Code target に配った
script を `~/.claude/agent-tools/scripts/` から呼びます
([dotfiles との境界](boundary-with-dotfiles.md)「OpenCode home の所有」)。
表に無い組 (plugin → codex、skill → opencode 等) は register の `unsupported` ではなく
check-manifests の manifest error になります ([Asset Manifest Schema](asset-manifest-schema.md))。

## Compatibility ルール

- semantics が portable な場合は shared source assets を優先する。
- tool-specific file names、metadata、directory layout は adapters で扱う。
- target artifacts は generated / reproducible に保つ。
- shared asset metadata は sidecar manifest で管理し、target-specific metadata と混ぜない。
- target-specific implementation details は、compatibility metadata として明示 modeling
  しない限り shared assets に置かない。

## 時点依存の記述

host (Claude Code / Codex / OpenCode) の版で変わりうる事実 (hook や plugin の挙動、CLI の flag、
読み込み先) を docs に書くときの規則です。

- 観測日と host の版を添え、根拠が実測 / 公式 docs の確認 / 未確認のどれかを書き分ける。
- 過去の実測を現行の保証として書かない。確かめ直していない古い観測は日付と版つきの履歴として、
  現行の記述と分けて残す。
- 起動 (flag・sandbox・完了判定) は docs に写さず、起動の正本へのリンクを 1 つだけ置く。正本は
  Codex review の起動が `shared/skills/personal-codex-review/LAUNCH.md`、worker の起動が
  `shared/skills/personal-codex-worker/LAUNCH.md`、監査の起動が
  `shared/skills/personal-repo-audit/CODEX-LAUNCH.md` (review と worker の `LAUNCH.md` は手順の正本で、
  それぞれ冒頭で契約の正本の `SKILL.md` を指す)。[Codex review の起動経路](codex-review-launch.md) と
  [herdr 前提の運用](herdr-operations.md) は背景の説明で、起動の正本ではない。

実践の例: [Runtime GitHub Injection 防御](runtime-injection-defense.md) の「PreToolUse hook」の節
(「履歴 (2026-07-07 調査)」と「現行仕様 (2026-09-05 確認)」を分け、OpenCode の verdict を
「1.18.30 のこの環境で観測した」の意味に限り、未実測の点は公式 docs の記述と明記する)。この文書の
「tool と artifact_kind の組」も、OpenCode の読み込み先を観測日・版・probe の項目つきで書いている。

## v1 で扱わないもの

- `AGENTS.md` の automatic sync。
- `CLAUDE.md` の automatic sync。
- company-managed skills。
- tool-standard bundled skills。
- runtime state migration。
- secret / credential distribution。
- private local path / endpoint distribution。

## 決定済み事項

- Codex / Claude Code / OpenCode artifact 向け adapter spec:
  [adapters/codex/README.md](../adapters/codex/README.md) /
  [adapters/claude-code/README.md](../adapters/claude-code/README.md) /
  [adapters/opencode/README.md](../adapters/opencode/README.md)。
- review 結果は generated artifacts に同梱せず、
  [catalog](register-catalog.md) に別出しする。
- review 後の risk / registration 状態は catalog の `checks` と
  `registration` で表現する。
