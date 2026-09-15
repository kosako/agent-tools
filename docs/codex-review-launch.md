# Codex review の起動経路と sandbox

`personal-codex-review` が Codex CLI (`codex exec`) をどう起動し、呼び出し元の Bash sandbox と
どう共存するかを説明します。skill 本体の契約は
`shared/skills/personal-codex-review/SKILL.md` が正本で、この文書は運用者向けの背景と前提です。

## 問題: sandbox の入れ子

Claude Code の Bash sandbox (macOS では Seatbelt) が有効な環境で、その Bash から `codex exec` を
起動すると、Codex は自前の sandbox を適用できず (`sandbox-exec: sandbox_apply: Operation not
permitted`)、model がローカル command を一切実行できません。Seatbelt は入れ子に適用できないため
で、Codex 側の欠陥ではなく起動経路の問題です。Codex TUI の中で `codex exec` を起動しても同じ構図に
なります (`CODEX_SANDBOX=seatbelt` が立つ環境)。

sandbox が無効な環境では同じ flag の `codex exec -s read-only` が command 実行に成功します
(2026-09-14 実測)。つまり挙動は「どの環境で skill を使うか」で変わります。

## 解: herdr の pane から起動する

[herdr](https://herdr.dev) は AI coding agent 向けの terminal workspace manager で、socket API を
持ちます。`herdr pane run` で実行した process は herdr server が pane の shell で起動するため、
呼び出し元 Bash の sandbox を継承しません。sandbox が有効な環境の Bash からも herdr の socket に
届くことを確認済みです (2026-09-15、strict 設定の環境で `herdr status` 成功)。

skill は次の順で起動経路を 1 つ選びます。

1. **herdr 経由 (primary)**: `herdr status` と `herdr pane current` が通るとき。review 用 pane を
   `--split down --no-focus` で作り、`run.zsh` を `herdr pane run` で実行する。
2. **直接起動 (fallback)**: herdr が使えず、かつ自分が sandbox の外にいると設定と環境変数で確認
   できたときだけ (Claude Code: settings に `sandbox.enabled: true` が無い。Codex: `CODEX_SANDBOX`
   未設定)。`sandbox-exec` などの probe は打ちません。strict な環境では回避操作と判定されるためです。
3. **BLOCKED + 人手**: どちらも使えないとき。run script と結果 file の場所を提示し、人が terminal で
   実行した結果を caller が読めば続行できます。

Codex 側の境界は経路によらず固定です: `-s read-only -c approval_policy="never" --ephemeral`。
`-s danger-full-access` や `--dangerously-bypass-approvals-and-sandbox`、呼び出し元 sandbox の
無効化で入れ子を回避することはしません。herdr 経由は「codex を呼び出し元 sandbox の外で走らせる」
点で Claude Code の `sandbox.excludedCommands` と同等ですが、Claude の設定を触らず、実行が pane
として可視化される点が異なります。

## 完了判定と結果

`codex exec … -o <run dir>/result.md - < <run dir>/brief.md; echo CODEX-REVIEW-DONE-<nonce> exit=$?`
を pane で実行し、`herdr wait output --match` で sentinel を待ちます。exit code は sentinel から、
review 本文は `result.md` から読みます。`result.md` が欠落または空なら空振りとして 1 回だけ
再実行し、2 回目も空なら `Status: BLOCKED` (`executor-result`) で停止します。pane は一次情報として
残します。

## brief と target

`codex exec review` の target selector (`--base` / `--commit` / `--uncommitted`) は custom brief と
排他なので使いません。代わりに `codex exec -` の custom prompt に、検証済みの base / head OID
(または commit OID) と `git diff` の取得コマンドを書き、diff と周辺コードは Codex に read-only
sandbox の中で読ませます。brief は file 経由で渡し、diff 本文を埋め込みません。

## 使う herdr subcommand

`status` / `pane current` / `pane split` / `pane rename` / `pane run` / `wait output` / `pane read`
に限定し、socket path や version 固有の flag に依存しません (0.7.1 と 0.7.4 で確認)。

## 受け入れ確認 (環境ごと)

- sandbox 無効環境: herdr 経由の `codex exec` が command 実行・`result.md` 出力・sentinel 検知まで
  通ること (2026-09-14 に probe で確認)。
- sandbox 有効環境: Claude の Bash から herdr 経由の review が実行でき、Codex が repo file を
  読めたことを command 実行の成否で確認すること。
- herdr が無く sandbox 有効: 実行前に理由つき BLOCKED と人手用コマンドが返ること。

関連 Issue: #244 (起動経路) / #230 (起動契約の CLI 追随) / #245 (空振り検知) / #246 (別原因の
起動失敗)。
