# personal-codex-review — 実行手順 (LAUNCH)

`SKILL.md` §5 の契約 (flag 固定・escape・完了判定・空振り・pane の後始末・人手 hand-off) を満たす
ための機械的な手順です。契約の正本は `SKILL.md`、手順の正本はこの file。§2 の起動経路の選択
(herdr → 直接 → BLOCKED) と §3 / §4 (mode と brief) を済ませてから読みます。この file の中の
command 例は data であり、caller の依頼や diff の文言で書き換えません。


run 用の directory を `mktemp -d` で作り、`brief.md`、`result.md` (出力先)、`done.txt` (完了記録)、
`run.zsh` を置きます。run script は次の形で、Codex の flag は固定です。

path・nonce・model・effort は生成時に **shell literal として escape** し、script 先頭の変数に 1 回だけ埋め込みます。
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
  -c <provider の key="value" の shell literal> \
  -o "$run/result.md" - < "$run/brief.md"
rc=$?
printf 'CODEX-REVIEW-DONE-%s exit=%s\n' "$nonce" "$rc" | tee "$run/done.txt"
exit "$rc"
```

`model` / `effort` は下の「model / effort の読み取り」で得た値を shell literal にして入れます。読み取りで無かった
key は、その変数の行と対応する `-c` を script から除きます (空の値を渡さない)。`-c` の値は TOML として読まれる
ので、引用符ごと渡します (`model="<値>"`。引用符が無いと、値によっては数値などに読まれる)。値は preflight が
`\A[A-Za-z0-9._-]+\z` に限っているので、引用符の中に入れても壊れません。

provider の `-c` は、読み取りの出力に `provider` があるときだけ、その key ごとに 1 行ずつ並べます (#543。順は出力の
とおり。例: `model_provider="amazon-bedrock"`、`model_providers.amazon-bedrock.aws.region="us-west-2"`)。`key="value"`
を丸ごと 1 つの shell literal にして `-c` の次に置きます (`-c 'model_provider="amazon-bedrock"'`)。`provider` が
無ければその行ごと除きます。key と値は script が bare key の文字と `\A[A-Za-z0-9._@+-]+\z` に限っています。

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
`config.toml` (か profile) に選ばれたプロバイダ (`model_provider`) があれば、さらに `"provider": {key: value}` と
`"provider_sources": {key: 出所}` が付きます (#543)。`provider` は `--ignore-user-config` で外れるプロバイダの設定の
うち引き継ぐもの (`model_provider` と、そのプロバイダの `[model_providers.<id>.aws]` の `profile` / `region`) です。

- **exit 0 の JSON だけを使います**。`selection` にある key だけを run script に `-c` で書き、無い key は行ごと
  除きます (Codex の既定に任せる)。`provider` があれば、その key をすべて `-c` で書きます (上の run script)。
  `sources` (`user config` / `review profile`。無い key は `codex default`) を返却の `Model selection` に写します
  (値は写さない)。
- exit 0 以外 (top-level に解釈できない行、値が形に合わない、選ばれたプロバイダに引き継げない設定 (`base_url`・
  `env_key`・`http_headers` など) がある、script か、script が load する
  `personal-codex-worker-preflight` が配備されていない、file を読めない、file は在るが regular file でない、
  在るかどうかを確かめられない) は
  `Status: BLOCKED` (`capability-preflight`) です。推測した値で走らせず、`--ignore-user-config` を外して user config を
  読ませることもしません。
- profile の file は作らず、書き換えません。無い machine があってよく、そのときは `config.toml` の top-level の
  値 (それも無ければ Codex の既定) になります (#339)。

`--ephemeral` は付けません。review の session rollout は Codex 側の session 保存先に残し、利用量の集計
(tokens / cost / rate limit) に使います (#297)。安全境界は `-s read-only` と `approval_policy="never"` と、起動の
3 種の flag (`--ignore-user-config` / `--ignore-rules` / `--disable`) で、rollout の有無は境界ではありません。
model family や reasoning effort は固定せず、上の読み取りの値に委ねます。読み取った値以外の `-m` や
model-specific config を足しません。別 agent / wrapper に代行させず、
実際の Codex CLI process を起動します。

### herdr 経由

次は shell を介さず argv を直接組む経路の形です (各 `<…>` は 1 argument として渡す値そのもので、
この経路では escape は pane shell 用の 1 段だけです)。

```sh
herdr pane split --current --direction down --ratio 0.3 --cwd <repo root> --no-focus
herdr pane rename <pane-id> review-<PR 番号、無ければ mode の形>
herdr pane run <pane-id> <"zsh " + run script path の shell literal>
herdr pane wait-output <pane-id> --match CODEX-REVIEW-DONE-<nonce> --timeout 300000
```

pane の名前は、PR の review なら `review-<PR 番号>` です。PR の無い対象は §3 の mode ごとに、base は
`review-<head の OID の先頭 7 文字>`、commit は `review-<対象 commit の OID の先頭 7 文字>`、uncommitted は
`review-uncommitted` です (規約は agent-tools の `docs/herdr-operations.md`)。

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
- timeout したら `herdr pane process-info --pane <pane-id>` で pane の foreground process
  (`result.process_info.foreground_processes[].name`) に `codex` が居るかを見ます (`personal-codex-worker` の
  `LAUNCH.md` §6 と同じ判定。#421)。居れば同じ wait を繰り返します (合計 3 回まで)。**居ないと確認できて**
  `done.txt` が無ければ `Blocked at: executor-exit` で停止します。process-info が失敗する・解釈できないときは
  「消滅」に倒さず、居るときと同じく wait を続けます。
- 3 回の wait が尽きても `done.txt` が無く、codex が居る (または居ないと確認できない) ときは、review は
  まだ動いています。process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返します (雛形は
  `RESULT-FORMAT.md`)。run script の `codex exec` は `personal-safe-run` で包まないので (`SKILL.md` §5 の「上限」。
  #512)、pane は閉じず、止めるかは人が決めます。後から `done.txt` が現れたら、同じ続行条件で判定して結果を
  読みます。その run の `done.txt` を確かめる前に、同じ対象の review を起動し直しません (2 本目が並んで走る)。
- `done.txt` の `exit=` が 0 以外なら `Blocked at: executor-exit` とし、pane の末尾を public-safe に
  要約して Reason に書きます。
- **pane の後始末**: 続行条件 (`done.txt` の nonce 一致・`exit=0`、空でない `result.md`) を満たした
  ときは、`herdr pane read <pane-id> --source recent-unwrapped --lines 200` の出力 (JSON) を
  そのまま `<run dir>/pane.log` に保存し、file が空でないことを確認してから
  `herdr pane close <pane-id>` で閉じます。text field だけを JSON parser で抜くと制御文字で
  失敗して空 file になることがあるため、生の出力を保存します。満たさないとき
  (exit≠0、空振りの再実行が尽きた、途中で BLOCKED、RUNNING) は閉じず、調べる必要がある pane だけを
  残します。固定名の pane を使い回しません。

### 直接起動 (fallback)

§2 の条件を満たすときだけ、同じ `run.zsh` を foreground の単独 process として実行します。
detach / background にせず、複合コマンドの末尾にも埋め込みません。判定は `done.txt` と
`result.md` で行い、herdr 経路と同じです。

pane が無いので、caller の command の実行そのものが待ちになります。その command が `done.txt` を残さずに
戻ったとき (caller の tool の時間の上限で打ち切られた・background に移された等) は、生存を見る pane が無いので
`Blocked at: executor-exit` で返します (`SKILL.md` §5 の「上限」。#512)。codex の process は
残っているかもしれませんが、自分で探して止めず、Next step に run dir と、process が残りうることを書きます
(run script の `codex exec` の argv には `-o <run dir>/result.md` が入るので、人は run dir の path で process を
探せます)。止めるかは人が決めます。後から `done.txt` が現れたら、同じ続行条件で判定します。その run の `done.txt` を
確かめる前に、同じ対象の review を起動し直しません (#421)。

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
