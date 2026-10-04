# Codex review の起動経路と sandbox

`personal-codex-review` が Codex CLI (`codex exec`) をどう起動し、呼び出し元の Bash sandbox と
どう共存するかを説明します。skill 本体の契約は
`shared/skills/personal-codex-review/SKILL.md` が正本 (起動の機械的な手順は同 directory の
`LAUNCH.md`、返却の雛形は `RESULT-FORMAT.md`) で、この文書は運用者向けの背景と前提です。

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
   `herdr pane split --current --direction down --no-focus` で作り、`run.zsh` を `herdr pane run` で
   実行する。
2. **直接起動 (fallback)**: herdr が使えず、かつ自分が sandbox の外にいると設定と環境変数で確認
   できたときだけ (Claude Code: user / project / managed の全 scope の settings に
   `sandbox.enabled: true` が無い。managed settings は file のほか MDM や claude.ai console からも
   配布されるので、組織管理された環境や managed settings を読めない環境では直接起動しない。
   Codex: `CODEX_SANDBOX` 未設定)。`sandbox-exec` などの probe は打ちません。strict な環境では回避操作と
   判定されるためです。
3. **BLOCKED + 人手**: どちらも使えないとき。run script と run dir の場所を提示し、人が terminal で
   実行したあと `done.txt` と `result.md` を caller が確認すれば続行できます。

Codex 側の境界は経路によらず固定です: `-s read-only -c approval_policy="never"`。`--ephemeral` は付けず、
session rollout を Codex 側に残して利用量の集計に使います (#297。rollout の有無は安全境界ではありません)。
`-s danger-full-access` や `--dangerously-bypass-approvals-and-sandbox`、呼び出し元 sandbox の
無効化で入れ子を回避することはしません。herdr 経由は「codex を呼び出し元 sandbox の外で走らせる」
点で Claude Code の `sandbox.excludedCommands` と同等ですが、Claude の設定を触らず、実行が pane
として可視化される点が異なります。

## 完了判定と結果

run script は run dir と repo root と nonce を shell literal として script 先頭の変数に 1 回だけ
埋め込み、以降は `"$run"` のように参照します (値を command 行へ直接展開しません。契約の正本は
SKILL.md)。実行するのは `codex exec … -o "$run/result.md" - < "$run/brief.md"` で、その exit code を
`CODEX-REVIEW-DONE-<nonce> exit=<rc>` の形で端末と `"$run/done.txt"` の両方に書きます。
`herdr pane wait-output --match` は端末側の行を起床信号として待つだけで、完了の正本は `done.txt`
(nonce 一致・`exit=0`) と空でない `result.md` です。人手 hand-off で人が terminal から実行した場合も
同じ file で確認するので、経路によらず判定は同じです。`result.md` が欠落または空なら空振りとして
1 回だけ再実行し、2 回目も空なら `Status: BLOCKED` (`executor-result`) で停止します。続行条件を
満たした pane は `herdr pane read` の生出力を `pane.log` として run dir に保存し、空でないことを
確認してから閉じ、満たさなかった pane (exit≠0、空振り、BLOCKED、`pane.log` が空) だけを一次情報として
残します。review のたびに pane が溜まらないようにするためです。

## brief と target

`codex exec review` の target selector (`--base` / `--commit` / `--uncommitted`) は custom brief と
排他なので使いません。代わりに `codex exec -` の custom prompt に、検証済みの base / head OID
(または commit OID) と `git diff` の取得コマンドを書き、diff と周辺コードは Codex に read-only
sandbox の中で読ませます。brief は file 経由で渡し、diff 本文を埋め込みません。
commit mode では周辺コードも検証済み commit OID の tree から読ませ (`git show <oid>:<path>` など)、現在の HEAD や
worktree の file は根拠にしません (#356。tree に無い file・読めない object の扱いを含む規則の正本は SKILL.md §3)。

## 起動の境界 (#358)

review は PR の diff という untrusted な内容を Codex に読ませるので、`personal-repo-audit` の `CODEX-LAUNCH.md`
(監査の起動) と同じ境界で起動します: `--ignore-user-config` (user の `config.toml` と、そこに足される bootstrap の
MCP server を読まない)、`--ignore-rules` (execpolicy の `.rules` を読まない)、`--disable apps` /
`--disable computer_use` / `--disable browser_use` (account 側の connector と sandbox の外へ届く tool を外す)。
read-only の sandbox は MCP の tool の呼び出しを止めないため、sandbox と approval policy だけでは diff の中の文言から
外部へ書き込める経路が残るからです。`-p` は使いません (profile の他の key、例えば MCP server を持ち込まないため)。
capability preflight は `codex exec --help` の flag に加えて `codex features list` の 3 行を確かめ、無ければ起動しません。

## model の選択

model family / reasoning effort は skill で固定せず、user の Codex の設定を再指定します (`--ignore-user-config` で
読まれなくなる分)。user の `config.toml` の top-level を base に、Codex home の `agent-tools-review.config.toml` の
top-level に同じ key があればそれを優先し (key ごとに重ねる)、`-c model="…"` / `-c model_reasoning_effort="…"` で
渡します。読むのは `model` と `model_reasoning_effort` だけで (worker の preflight と同じ規則で、配備済みの
`personal-codex-model-selection` が読む。#364)、
profile の他の key (例: `service_tier`) は読みません。読めなければ (top-level に解釈できない行など) 推測せず
BLOCKED です。置き方と Fast mode の消費は [Install & Usage](install-and-usage.md) の「Codex の review / worker
だけを軽くする」。

## 使う herdr subcommand

`status` / `pane current` / `pane split` / `pane rename` / `pane run` / `pane wait-output` / `pane read` /
`pane close` に限定し、socket path や version 固有の flag に依存しません (0.9.0 で確認)。

渡す値の escape は 2 段あります。`pane run` の command は **pane の shell** が解釈するので script path を
shell literal 化し、その command 文字列を自分の shell 経由で `herdr` へ渡すならもう一段 literal 化
します。`pane split --cwd` のように herdr へ直接渡る argv は 1 段です。shell を介さず argv を組む
経路なら外側は不要です。
top-level の `wait` command は herdr 0.7.5 で `pane wait-output` (と `agent wait`) に置き換えられており
(herdr 同梱の CHANGELOG)、0.9.0 では `unknown command: wait` になります。0.7.1 / 0.7.4 で確認した
旧記述はこの版で置き換えました。

## 受け入れ確認 (環境ごと)

- sandbox 無効環境: herdr 経由の `codex exec` が command 実行・`result.md` 出力・sentinel 検知まで
  通ること (2026-09-14 に probe で確認)。
- sandbox 有効環境: Claude の Bash から herdr 経由の review が実行でき、Codex が repo file を
  読めたことを command 実行の成否で確認すること。
- herdr が無く sandbox 有効: 実行前に理由つき BLOCKED と人手用コマンドが返ること。

関連 Issue: #244 (起動経路) / #230 (起動契約の CLI 追随) / #245 (空振り検知) / #246 (別原因の
起動失敗)。
