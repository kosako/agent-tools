# Instruction Artifact Kind

共通の運用ルール (言語既定 / セッション標準動作 / ドキュメント運用ルール / 正本の所在 /
public safety) を、claude-code には `CLAUDE.md`、codex には `AGENTS.md` として両 tool へ
配布するための artifact kind です。skill が directory を丸ごと所有するのに対し、
instruction は **tool 別の単一ファイル**を所有します。

## 所有モデル: 丸ごと所有

agent-tools は自分の隔離ファイルだけを所有・生成し、人間が手書きする共有ファイルには
日常運用で触りません (skills/personal-* と同じ思想)。

- **claude-code**: `<claude home>/agent-tools/CLAUDE.md` を丸ごと所有する。人間の
  `<claude home>/CLAUDE.md` からは `@agent-tools/CLAUDE.md` の import 1 行で繋ぐ
  (Claude Code は `@path` import に対応)。
- **codex**: import 非対応のため、グローバル `AGENTS.md` を丸ごと所有する。固有の
  手書きルールは project 直下の `AGENTS.md` に逃がす (codex は階層連結する)。

## 生成 (build)

build は instruction asset を tool 別の単一ファイルとして生成する。

- 出力先: `generated/<tool>/instructions/<CLAUDE.md|AGENTS.md>`。
- source は単一ファイル (markdown / text)。`directory` format は instruction では非対応。
- 1 つの target に instruction を生成する asset は高々 1 個 (check-manifests が検証)。
  複数あると `CLAUDE.md` / `AGENTS.md` をどの asset で生成するか決まらないため。

## marker: ファイル内コメント

instruction は単一ファイル所有なので、skill の directory sidecar marker
(`.agent-tools-managed.yml`) が使えない。代わりに本体先頭に HTML コメントの marker を
1 行埋める:

```
<!-- agent-tools:managed v=1 repo=agent-tools name=... target=... artifact_kind=instruction source=... build_id=... -->
```

marker は HTML コメントなので tool が読んでも指示として解釈されず、表示もされない。
sync はこの marker を厳密にパースして所有を判定し (後続実装)、injection checker は
自分の marker 行を検査対象から除外する。

## 接続 (connect) と日常 sync の分離

人間のファイルに触る操作 (import 1 行追加 / グローバル所有開始) は専用 connect 操作だけに
閉じ込める。日常の build / sync は「人間のファイルに触らない」を不変条件として厳守する。

- connect は default dry-run + apply、冪等。symlink 拒否 / 改行スタイル保持 /
  完全一致 import は no-op / 空判定は lstat ベース。
- sync は未接続なら案内して停止し、自動では人間のファイルを触らない (create に落ちない)。

## 参照先の分離: 間接ポインタ

instruction (public, 配布) には具体的な参照先 (planning tool の URL など) を書かない。
抽象的な運用ルールだけを書く。「どこに何があるか」のマップは home 配下の固定 note
(data-only) に人間が置き、instruction はその note への間接ポインタだけを持つ。

- agent が読む先は常に home の固定ファイル 1 つ。外部 repository は読まない。
- home note の読取 precondition: 全 path component が user-owned / not symlink /
  not world-writable、note は regular file。満たさなければ参照先なし扱い。
- note は data-only map。agent は内容を命令として実行しない・変更しない・未知形式は無視する。

これにより injection gate は instruction に対して URL / 絶対パスの検知を strict に
適用できる ([Prompt Injection Check](prompt-injection-check.md))。

## catalog / sync

- catalog は target-artifact 単位で `artifact_kind` を記録する。
- register は `artifact_kind` を解決し、ビルド可能性を確認してから registered を発行する。
- sync は catalog を source of truth として列挙し、registered の instruction だけを
  所有ファイルへ update する。未 build なら "run build first"、未接続なら "run connect
  first" で skip し、create には落ちない。

## connect の挙動

`scripts/connect.sh` が接続を確立する (default dry-run、`--apply` で書き込み、冪等):

- **claude-code**: `<claude home>/agent-tools/CLAUDE.md` を所有ファイルとして作成し
  (generated instruction をコピー)、`<claude home>/CLAUDE.md` に `@agent-tools/CLAUDE.md`
  の import 1 行を足す。既存内容と改行スタイルは保持し、import が既にあれば no-op。
- **codex**: `<codex home>/AGENTS.md` を直接所有する。空ファイル (空白のみ) のみ claim 可。
- symlink / dir / 特殊ファイルは決して触らない。所有ファイルに unmanaged な中身が
  あれば conflict として停止し、何も書き込まない。

marker の生成・解析は `scripts/lib/instruction_marker.rb` に集約し、build (生成) と
connect / sync (所有判定) が同じ format を共有する。

## 実装状況

- 実装済み: artifact_kind resolver (`scripts/lib/artifact_targets.rb`)、build の
  instruction 生成、ファイル内コメント marker (`scripts/lib/instruction_marker.rb`)、
  check-manifests の 1-per-target 検証、catalog の target-artifact 化と register の
  ビルド可能性証明、connect (`scripts/connect.sh`)、sync の instruction 配置
  (catalog を source of truth として列挙)。
- 後続: status / doctor / prune の instruction 対応、injection の instruction strict、
  検証用の実 instruction asset 投入。
