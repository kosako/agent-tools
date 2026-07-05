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
- register 後に manifest が変わった entry (catalog の `manifest_digest` と現在の manifest
  が不一致) は、登録判断ごと stale なので配置せず `manifest changed; run
  scripts/register.sh first` で skip する (fail-closed, #148)。
- sync が更新してよいのは agent-tools management marker を含む targets のみ。
  同名の unmanaged targets は conflict として扱い、sync を停止する。
- artifact_kind ごとに配置先が異なる:
  - skill: `<tool home>/skills/personal-<name>/` (directory)。
  - instruction: connect が確立した所有ファイル。instruction の所有確立は connect の
    役割で、sync は create に落ちず未接続なら connect を促す
    ([Instruction Artifact Kind](instruction-artifact-kind.md))。
  - script: `<tool home>/agent-tools/scripts/personal-<name>` (単一実行ファイル) と
    その隣の `<name>.agent-tools-managed.yml` (sidecar marker)。本体は byte 保持・mode 0755。
    instruction と違い人間ファイルを介さないため connect 不要で、未配置なら sync が直接
    create する。配置先本体・sidecar marker・`agent-tools/scripts`・`agent-tools` のいずれかが
    symlink なら conflict として停止する。

## v1 Codex targets

許可する target:

```text
~/.codex/skills/personal-*
~/.codex/AGENTS.md                       (instruction、connect が所有を確立)
~/.codex/agent-tools/scripts/personal-*  (script、sync が直接配置)
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
~/.claude/agent-tools/CLAUDE.md            (instruction、connect が所有を確立)
~/.claude/agent-tools/scripts/personal-*   (script、sync が直接配置)
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

補足: `scripts/doctor.sh` の forbidden target 検査は、上記禁止リストのうち directory の
部分集合だけを見る (directory 直下の marker file の有無で判定するため、file 型の
`auth.json` / `config.toml` / `*.sqlite` はこの検査方式の対象外)。

## 撤去 (sync --prune)

`sync --prune` は、catalog に載らなくなった (= `shared/` から消えた) asset の deployed
コピーを tool home から撤去します。`build --prune` (generated/ の orphan 削除) の sync 版
です (#154)。

- 削除も dry-run が既定で、実削除には `--apply` が必須。
- 削除するのは次の 3 条件をすべて満たすものだけ (marker-gated delete):
  1. 許可 namespace 内 (`<tool home>/skills/personal-*` / `<tool home>/agent-tools/scripts/personal-*`)
  2. agent-tools management marker が tool / name と一致
  3. catalog に同 target + name + artifact_kind の entry が無い
- 照合は artifact_kind 単位。kind を変更した asset の旧配置物は保護されず撤去される
  (`build --prune` と同じ判断)。
- catalog の entry は registration 状態を問わず asset の実在とみなす
  (`human_review_required` でも撤去しない)。catalog が無い / version 不一致 / entry ゼロ
  (valid な空 catalog) なら何も判断せず撤去しない (fail-closed。空 catalog は manifest
  ゼロの repo で register しても生成できるため、全 deployed が orphan に見える誤爆を塞ぐ)。
- 条件を満たさない orphan (unmanaged / symlink) は削除せず skip として可視化するだけで、
  conflict にしない (書き込みと違い「触らない」が常に安全なため、prune は停止しない)。
- script は本体と sidecar marker を対で撤去する。
- instruction は prune 対象外。所有ファイルは人間の instruction ファイルと絡めて connect
  が管理しており、撤去 (所有解除) は人間の判断で行う。

## Management Marker

marker format は [Status / Manifest Contract](status-manifest-contract.md) で定義します。

- repository name: `agent-tools`
- generated asset name
- target tool
- source path
- source content の sha256 build_id

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

## 既知の限界 (TOCTOU)

symlink / unmanaged の検査は plan 時に行い、apply は配置先を再検証しません。
plan→apply 間に配置先を差し替えられると検査を通過した plan のまま書き込みます。

これを意図的に突ける主体は、同一ユーザー権限で任意のファイルを書き換えられる攻撃者に
限られます。その主体は apply 直前の再検証も同様に無効化できるため、再検証を足しても
防御になりません (実装しない判断, #149)。同時実行による事故は、個人ツールとして同時
実行の前提が薄いこと、書き込み先が marker-gated な managed target に限定されることで
被害が限定されます。
