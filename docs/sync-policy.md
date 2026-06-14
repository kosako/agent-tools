# Sync Policy

sync は、この repository で生成した personal assets を local tool directories に反映します。
default は必ず conservative にします。

実装は `scripts/sync.sh` です。usage は [scripts/README.md](../scripts/README.md) を
参照してください。

## Default 方針

- sync は default dry-run。実際の書き込みには `--apply` を必須にする。
- sync は catalog (`generated/catalog.json`) を source of truth として列挙し、
  `registration: registered` の target-artifact だけを配置する。registered でない
  (`human_review_required` / `unsupported`) ものは理由つきで skip する。
- catalog が無い / version 不一致なら何も配置せず register を促す。
- sync が更新してよいのは agent-tools management marker を含む targets のみ。
  同名の unmanaged targets は conflict として扱い、sync を停止する。
- artifact_kind ごとに配置先が異なる:
  - skill: `<tool home>/skills/personal-<name>/` (directory)。
  - instruction: connect が確立した所有ファイル。instruction の所有確立は connect の
    役割で、sync は create に落ちず未接続なら connect を促す
    ([Instruction Artifact Kind](instruction-artifact-kind.md))。

## v1 Codex targets

許可する target:

```text
~/.codex/skills/personal-*
~/.codex/AGENTS.md          (instruction、connect が所有を確立)
```

禁止する targets:

```text
~/.codex/skills/.system
~/.codex/plugins
~/.codex/cache
~/.codex/auth.json
~/.codex/config.toml
~/.codex/*.sqlite
```

## v1 Claude Code targets

許可する target:

```text
~/.claude/skills/personal-*
~/.claude/agent-tools/CLAUDE.md   (instruction、connect が所有を確立)
```

禁止する targets:

```text
~/.claude/cache
~/.claude/sessions
~/.claude/projects
```

## その他の禁止 runtime state

```text
~/.agents/skills/*/db
~/.agents/skills/*/teams
```

## Management Marker

marker format は [Status / Manifest Contract](status-manifest-contract.md) で定義します。

- repository name: `agent-tools`
- generated asset name
- target tool
- source path
- generation timestamp または build id

sync は marker を持たない files / directories の変更を拒否します。
同名の unmanaged target は `conflict` として停止します。

## instruction の所有ファイル

instruction artifact は connect が所有を確立し、sync が更新する。

- claude-code: `<claude home>/agent-tools/CLAUDE.md` (人間の `CLAUDE.md` からは import で
  取り込む)。
- codex: `<codex home>/AGENTS.md` (空ファイルのみ claim)。

これらは日常 sync では create せず、connect だけが所有を開始する。symlink / 非通常
ファイル / unmanaged な所有先は conflict として停止する。詳細は
[Instruction Artifact Kind](instruction-artifact-kind.md)。
