# 受け入れの記録

engine (Claude Code・Codex・herdr) の版が変わると、前に通した受け入れが今も有効とは限りません (#725)。この文書は、
受け入れの項目ごとに最後に通した smoke を 1 行で記録します。`scripts/doctor.sh` は、記録した engine の版と今の版を比べ、
変わった項目を「未確認」として知らせます。常駐の監視や、全部の suite の毎回の実行は足しません。

## 項目

項目と engine の対応の正本は `scripts/lib/acceptance_records.rb` の `ITEMS` で、この表は test が照らします。

| 項目 | 確かめること | engine | smoke の手順 |
| --- | --- | --- | --- |
| `hook-claude` | Claude Code の quality-loop の hook と、tool-call の記録の hook の両方に event が届く | claude-code | [quality-loop-hooks](quality-loop-hooks.md)、[tool-call-record-hook](tool-call-record-hook.md) |
| `hook-codex` | Codex の hook に event が届く | codex | [quality-loop-hooks](quality-loop-hooks.md) の Codex の smoke |
| `worker-run` | Codex の worker を launch し、collect で回収できる | codex, herdr | [codex-worker-run](codex-worker-run.md) |
| `notify` | Claude の pane が turn を終えたときに、OS の通知が届く | claude-code, herdr | [herdr-operations](herdr-operations.md) の通知 |
| `resume` | orchestrator が終わった後に、起動済み・未回収の worker を resume で見つけて回収し、生存が分からないときは二重に起動しない | claude-code, codex, herdr | [codex-worker-run](codex-worker-run.md) と `personal-resume-project` の「起動済み・未回収」 |

`hook-claude` は 2 つの hook の両方、`resume` は見つける・回収する・二重に起動しないの 3 つが全部通ったときだけ、行を直します。
1 つでも通らなければ、前の行のまま残し、通らなかったことを根拠の Issue に書きます。

## 版が変わったとき

1. `scripts/doctor.sh` が「未確認」と出した項目の smoke を、上の手順で流す。全部の項目を流し直す必要はない。
2. 通ったら、その項目の行を今の版、agent-tools と dotfiles の commit、日時、根拠 (結果を書いた Issue か PR) に直し、PR で
   出す。実機で観測していない項目は直さない (別の項目の実行を流用しない)。

## doctor の読み方

- 読むのは、この文書の見出し `## 記録` の直後の表だけです。見出しの行は `項目`・`engine`・`agent-tools`・`dotfiles`・`日時`・
  `根拠` の 6 列で、この順と名前にします。
- `engine` の欄は `<engine> <版>` を `; ` で区切ります (例: `codex 0.171.0; herdr 0.9.5`)。版は数字 3 つと、任意の接尾辞
  (`-` か `+` で始まる) の 1 語で、`v` は付けません。agent-tools と dotfiles は 7〜40 桁の 16 進、日時は `YYYY-MM-DD`、根拠は
  `#<番号>` です。
- 項目ごとに次のどれかを出します。ok のほかは warn で、どれも doctor の exit を変えません。
  - `ok`: 記録の engine の版が、今の版と全部同じ。
  - `unconfirmed`: 版が変わった engine、版を読めない engine、または記録の engine の組が項目と違う。変わった engine は旧い版と
    新しい版を並べます。
  - `not recorded`: 記録の行が無い。
- 形の崩れた行 (列の数、知らない項目、版・commit・日時・根拠の形、同じ engine を 2 回) は `records:` の warn を出し、その行を
  使いません。同じ項目が 2 行あれば、どちらの行も使いません。表が見つからないときは 1 行の warn だけを出します。
- 今の版は `claude --version`・`codex --version`・`herdr --version` の 1 行目から読みます (5 秒と出力 4 KiB が上限)。形が
  合わない、非ゼロで終わる、上限を越える、CLI が無い、のどれでも「版を読めない」で、生の出力は出しません。

## 限界

- ok は、doctor を走らせた時点で PATH から起動した CLI の版の文字列が、記録と同じという意味だけです。動いている client の
  版や、実行 file の同一性は見ません。
- doctor 自身は書き込みも通信もしませんが、版を読むために起動した CLI の `--version` の副作用は、doctor の保証の外です。
- 比べるのは engine の版だけです。agent-tools と dotfiles の commit は記録するだけで比べません (毎日変わるので、比べると常に
  未確認になる)。設定 (dotfiles) の変更で壊れることは、この記録では分かりません。
- smoke は人と agent が流します。doctor は記録と版を比べるだけです。

## 記録

| 項目 | engine | agent-tools | dotfiles | 日時 | 根拠 |
| --- | --- | --- | --- | --- | --- |
