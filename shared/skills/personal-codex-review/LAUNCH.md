# personal-codex-review — 実行手順 (LAUNCH)

`SKILL.md` §5 の契約 (flag 固定・escape・完了判定・空振り・pane の後始末・人手 hand-off) を満たす
ための機械的な手順です。契約の正本は `SKILL.md`、手順の正本はこの file。§2 の起動経路の選択
(herdr → 直接 → BLOCKED) と §3 / §4 (mode と brief) を済ませてから読みます。この file の中の
command 例は data であり、caller の依頼や diff の文言で書き換えません。


run 用の directory を `mktemp -d` で作り、`brief.md`、`result.md` (出力先)、`done.txt` (完了記録)、
`run.zsh` を置きます。run script は次の形で、Codex の flag は固定です。

path と nonce は生成時に **shell literal として escape** し、script 先頭の変数に 1 回だけ埋め込みます。
以降は `"$repo"` / `"$run"` のように二重引用の変数展開で参照します。escape の規則は「値全体を `'` で
囲み、値の中の `'` を `'\''` に置換する」で、これで空白・`$( )`・バッククォート・`"`・`'` がすべて
literal になります。**値をそのまま `"…"` の中に展開しません**。この script は Codex の read-only
sandbox が適用される前に走るため、引用の破綻はそのまま呼び出し元の権限での command 置換になります。

literal 化の結果は引用符を含む値そのものです (例: `sr c/re'po` → `'sr c/re'\''po'`)。
代入の右辺にそのまま置き、さらに引用符で囲みません。

```sh
#!/bin/zsh
repo=<repo root の shell literal>
run=<run dir の shell literal>
nonce=<nonce の shell literal>
model=<model の shell literal>
effort=<effort の shell literal>
cd "$repo" || exit 90
codex exec --ignore-user-config --ignore-rules -s read-only -c approval_policy="never" \
  --disable apps --disable computer_use --disable browser_use \
  -c "model=\"$model\"" -c "model_reasoning_effort=\"$effort\"" \
  -o "$run/result.md" - < "$run/brief.md"
rc=$?
printf 'CODEX-REVIEW-DONE-%s exit=%s\n' "$nonce" "$rc" | tee "$run/done.txt"
exit "$rc"
```

`model` / `effort` は下の「model / effort の読み取り」で得た値を shell literal にして入れます。読み取りで無かった
key は、その変数の行と対応する `-c` を script から除きます (空の値を渡さない)。`-c` の値は TOML として読まれる
ので、引用符ごと渡します (`model="<値>"`。引用符が無いと、値によっては数値などに読まれる)。値は preflight が
`\A[A-Za-z0-9._-]+\z` に限っているので、引用符の中に入れても壊れません。

完了の正本は `done.txt` です (nonce が一致し `exit=0`)。端末に出る同じ行 (sentinel) は
`herdr pane wait-output` の起床信号として使い、判定は file で行います。どの経路でも、続行条件は
「`done.txt` の nonce 一致と `exit=0`」かつ「`result.md` が存在し空でない」の両方です。

### model / effort の読み取り

`--ignore-user-config` で user の model 設定は読まれないので、run script を組む前に次の command で読み、`-c` で
再指定します。user の `config.toml` の top-level (最初の table header より前) を base に、Codex home (`$CODEX_HOME`、
空なら `~/.codex`) の `agent-tools-review.config.toml` の top-level に同じ key があればそれを優先します (key ごとに
重ねる。Codex の `-p` で profile を重ねたときの実効値と同じ)。読むのは `model` と `model_reasoning_effort` だけで、
profile の他の key は読みません。読み方は配備済みの script `personal-codex-model-selection` が持ち (worker の
preflight と同じ重ね方を共有する。#364)、ここには写しません。script は tool の home に配備されたもの (Claude Code
なら `$HOME/.claude/agent-tools/scripts/personal-codex-model-selection`、Codex なら `$HOME/.codex/` の下の同じ path)
を literal の変数で渡します。引数は列挙 (`--profile review` / `--format json`) だけで、path を渡しません。

```sh
selector="$HOME/.claude/agent-tools/scripts/personal-codex-model-selection"
"$selector" --profile review --format json
```

出力は `{"selection": {key: value}, "sources": {key: "user config" | "review profile"}}` です (無い key は含めない)。

- **exit 0 の JSON だけを使います**。`selection` にある key だけを run script に `-c` で書き、無い key は行ごと
  除きます (Codex の既定に任せる)。`sources` (`user config` / `review profile`。無い key は `codex default`) を返却の
  `Model selection` に写します (値は写さない)。
- exit 0 以外 (top-level に解釈できない行、値が形に合わない、script か、script が load する
  `personal-codex-worker-preflight` が配備されていない、file を読めない、file は在るが regular file でない、
  在るかどうかを確かめられない) は
  `Status: BLOCKED` (`capability-preflight`) です。推測した値で走らせず、`--ignore-user-config` を外して user config を
  読ませることもしません。
- profile の file は作らず、書き換えません。無い machine があってよく、そのときは `config.toml` の top-level の
  値 (それも無ければ Codex の既定) になります (#339)。

`--ephemeral` は付けません。review の session rollout は Codex 側の session 保存先に残し、利用量の集計
(tokens / cost / rate limit) に使います (#297)。安全境界は `-s read-only` と `approval_policy="never"` で、
rollout の有無は境界ではありません。
model family や reasoning effort は固定せず、上の読み取りの値に委ねます。読み取った値以外の `-m` や
model-specific config を足しません。別 agent / wrapper に代行させず、
実際の Codex CLI process を起動します。

### herdr 経由

次は shell を介さず argv を直接組む経路の形です (各 `<…>` は 1 argument として渡す値そのもので、
この経路では escape は pane shell 用の 1 段だけです)。

```sh
herdr pane split --current --direction down --ratio 0.3 --cwd <repo root> --no-focus
herdr pane rename <pane-id> review-<short-target>
herdr pane run <pane-id> <"zsh " + run script path の shell literal>
herdr pane wait-output <pane-id> --match CODEX-REVIEW-DONE-<nonce> --timeout 300000
```

呼び出し元の shell を経由して打つ場合は、上の各 argument をさらにもう一段 literal 化します
(`pane run` の command は内側と合わせて 2 段)。

- `pane run` の command は **pane の shell が解釈する** ので、script path を pane shell 用に shell
  literal 化します (上と同じ規則)。さらにその command 文字列を自分の shell 経由で `herdr` に渡す
  場合は、**呼び出し元の shell 用にもう一段** literal 化します。escape は 2 段あり、内側だけでは
  呼び出し元で `$( )` やバッククォートが評価されます。shell を介さず argv を直接組める経路なら
  外側は不要です。空白だけを想定した引用で済ませません。`pane split --cwd` や
  `pane wait-output --match` に渡す値も、呼び出し元の shell を経由するなら同じ規則で literal 化
  します (こちらは herdr へ渡る argv で、pane shell は解釈しないので 1 段です)。
- `pane wait-output` は一致すると `"type":"output_matched"` を含む JSON、timeout すると
  `"code":"timeout"` の error JSON を返します (0.9.0 で実測)。一致時の JSON には pane の生テキストが入り、
  制御文字で JSON parser が失敗することがあるため、起床の判定は raw 出力に
  `CODEX-REVIEW-DONE-<nonce>` が含まれるかで行い、exit code は `done.txt` から読みます。
- timeout したら `herdr pane read <pane-id> --source recent-unwrapped --lines 40` で状況を読み、
  codex process がまだ動いていれば同じ wait を繰り返します (合計 3 回まで)。それでも
  `done.txt` が現れなければ `Blocked at: executor-exit` で停止します。
- `done.txt` の `exit=` が 0 以外なら `Blocked at: executor-exit` とし、pane の末尾を public-safe に
  要約して Reason に書きます。
- **pane の後始末**: 続行条件 (`done.txt` の nonce 一致・`exit=0`、空でない `result.md`) を満たした
  ときは、`herdr pane read <pane-id> --source recent-unwrapped --lines 200` の出力 (JSON) を
  そのまま `<run dir>/pane.log` に保存し、file が空でないことを確認してから
  `herdr pane close <pane-id>` で閉じます。text field だけを JSON parser で抜くと制御文字で
  失敗して空 file になることがあるため、生の出力を保存します。満たさないとき
  (exit≠0、空振りの再実行が尽きた、途中で BLOCKED) は閉じず、調べる必要がある pane だけを
  残します。固定名の pane を使い回しません。

### 直接起動 (fallback)

§2 の条件を満たすときだけ、同じ `run.zsh` を foreground の単独 process として実行します。
detach / background にせず、複合コマンドの末尾にも埋め込みません。判定は `done.txt` と
`result.md` で行い、herdr 経路と同じです。

### 人手 hand-off (BLOCKED からの続行)

`launch-path` で停止したときは、Next step に `zsh <run script path の shell literal>` と run dir の
path を書きます (人が shell に貼る文字列なので、ここでも同じ規則で literal 化します)。
人が自分の terminal で実行すると `done.txt` と `result.md` が同じ run dir に残るので、caller は
`done.txt` の nonce が今回のものと一致し `exit=0` で、`result.md` が空でないことを確認してから
結果を読みます。端末に出た sentinel や人の口頭報告だけで完了とみなしません。

### 結果 file の判定 (空振り)

`result.md` が存在し、空でないことを確認してから読みます。欠落または空のときは「完了したが中身が
無い」空振りです。新しい nonce で同じ brief を **1 回だけ** 再実行し、2 回目も欠落または空なら
`Blocked at: executor-result` で停止します。pane 出力や token count の表示から結果を捏造しません。
