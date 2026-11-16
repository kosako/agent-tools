# 配備した運用 instruction の更新を、続いている session に伝える hook (personal-instruction-update-notice)

`shared/scripts/personal-instruction-update-notice.rb` は Claude Code の `SessionStart` と `UserPromptSubmit` の hook の本体です
(#688)。配備済みの運用 instruction (`<claude home>/agent-tools/CLAUDE.md`) が、session が読み込んだ後に更新されたら、
変わった節と file の場所をその session に伝えて、読み直しを促します。

## なぜ要るか

配備で運用 instruction を変えても、配備の前から続いている session は、古い版のまま動きます。#675 の調査では、merge の条件を
script にする規則 (#662) を配備した後に、1 つの session が 6 回、script を通さずに merge していました。

Claude Code がいつ読み直すかを、docs と session の記録で確かめました (2026-11-16。Claude Code 2.1.296〜2.1.325)。

- docs は、CLAUDE.md と import 先を session の開始時に読むと書いています。途中で disk の file が変わったときに自動で読み直す
  とは書いていません。読み直させる command もありません。
- compaction の後は、instruction がもう一度 context に入ります。個人機の 90 session の記録では、compaction の後に作業が続いた
  127 回のすべてでそうなっていて、user-level の CLAUDE.md が import している file も対象でした。
- ただし、読む時点は一定ではありません。compaction と次の入力の間に配備が挟まった 12 回のうち、次の入力の時点の版が入ったのは
  5 回、compaction の時点の版のままだったのは 3 回でした (残りの 4 回は判定できない)。compaction の後の配備は、次の compaction
  まで届かないことがあります。

session が持っている版は、開始や compaction の時刻だけからは決められません。そこで、session が最後に読み込んだはずの時点より
後に file が変わったことを見て、読み直しを促します。

## すること

見る file は、script の実体と同じ配備先の `<claude home>/agent-tools/CLAUDE.md` です (script の実体の directory から見た
`../CLAUDE.md`。symlink から起動しても、実体の隣を見ます)。env や hook の入力では変えられません。

| event | すること |
| --- | --- |
| `SessionStart` (source は問わない) | 今の file の節ごとの hash を、その session の記録に書く。何も出さない |
| `UserPromptSubmit` で、記録が無い | 今の内容を記録する。何も出さない |
| `UserPromptSubmit` で、記録と今の file が同じ | 何もしない |
| `UserPromptSubmit` で、記録と今の file が違う | stdout に下の JSON を 1 行出し、記録を今の内容に更新する |

1 回の更新につき、促しは 1 回だけです (促した後は、記録が今の内容になる)。促しを出してから記録を更新するので、記録を
書けなかったときは、次の入力でもう一度促します。

### 記録する時点

`SessionStart` は、開始 (startup)・再開 (resume)・`/clear`・compaction の後・fork のどれでも走ります。compaction の時点で
記録すると、session が持つ版は、記録と同じか、それより新しくなります (上の調査のとおり、Claude Code が読むのは compaction の
時点か、その後)。古い版のまま気づかない見逃しを作らない代わりに、session が既に新しい版を持っているのに促すことがあります。
そのときに増えるのは、file 1 つの読み取りです。

### 出力

```json
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<下の 4 行>"},"systemMessage":"<下の 1 行>"}
```

`additionalContext` は model に届く text で、改行で区切った 4 行です。

```text
運用 instruction の file が、この session が読み込んだ後に配備で更新されています。
file: <見る file の絶対 path>
変わった節: 「待ちと判断の伝え方」、「public safety」、「新しい節」(追加)、「消えた節」(削除)
この session の context にある運用 instruction は、更新の前の版のことがあります。作業を続ける前にこの file を読み、違うところは file の版に従ってください。
```

`systemMessage` は人に見える 1 行です。

```text
運用 instruction が更新されています (変わった節: 「待ちと判断の伝え方」、「public safety」)。この session に読み直しを促しました。
```

節が 10 個を超えるときは、どちらの行も末尾に `、ほか <N> 個` を付けます。

## 節の分け方

実装は、この script の `InstructionUpdateNotice::Sections` です。配備の報告 (`scripts/sync.sh` の note。
[sync-policy](sync-policy.md) の「配備の報告」) も同じ分け方で、`scripts/lib/instruction_sections.rb` に同じ本文の module を
持ちます。配備される script は単独の file で `scripts/lib` を require できず、`scripts/` は `shared/` の特定の asset を
require できないためです。2 つの本文が一字一句同じであることは、`scripts/tests/instruction-sections-test.sh` が確かめます。

- file の先頭の行が agent-tools の marker (`<!-- agent-tools:managed` で始まる行) なら、その行を除きます。build_id だけが違う
  版は、同じ内容として扱います。
- fenced code block (行の頭が ```` ``` ```` か `~~~`) の外にある、`# ` か `## ` で始まる行を見出しとして区切ります。`###` より
  深い見出しは、上の節の中身です。
- 節の名前は、見出しの `#` と前後の空白を除いた text です。最初の見出しより前に空白以外の行があれば、`(preamble)` という節に
  します。同じ名前の節が複数あれば、中身を順につないで 1 つの節として比べます。
- 節の中身は、前後の空白と空行を除いてから比べます。
- local の断片の節 ([Instruction Artifact Kind](instruction-artifact-kind.md) の「local の断片」) は、見出しの行から末尾までを
  `local instructions` という 1 つの節にします。中の見出しは区切りにせず、出力にも記録にも出しません。
- 違いは、新しい版での出現の順に並べます。新しい版にだけある節には `(追加)`、古い版にだけある節には `(削除)` を付け、
  消えた節は最後に並べます。節の名前は 80 字で切り、制御文字は空白にします。

## 記録

- 場所は `${XDG_STATE_HOME:-$HOME/.local/state}/agent-tools/personal-instruction-update-notice/<session_id>.json` です。
  `AGENT_TOOLS_INSTRUCTION_NOTICE_DIR` (絶対 path) を渡すと、その directory を使います。相対の場所は使いません。
- 書くのは節の名前と hash、記録した時刻だけです。本文は書きません。directory は 0700、file は 0600 で作り、一時 file に書いて
  rename で入れ替えます。
- `session_id` は `[A-Za-z0-9_-]` の 1〜128 字だけを受けます (記録の directory の外に書かないため)。
- 記録が壊れている・形が外れる・symlink のときは、記録が無いときと同じに扱います。
- 記録を読む上限は、見る file の上限 (256 KiB) の 32 倍です。見る file の上限いっぱいまで節があっても、書いた記録を
  読み直せる大きさにしています (読めない記録は「記録が無い」と同じ扱いになり、以後の更新を見逃すため)。
- `SessionStart` のとき、30 日より古い記録を消します (1 回に 200 個まで。記録の名前の形に合う regular file だけ)。

## hook が失敗したとき

exit は常に 0 で、prompt を止めません。次のときは stdout に何も出さず、記録も変えません。

- 入力が JSON の object でない、1 MiB を超える。
- `hook_event_name` が上の 2 つ以外。`session_id` が無い、形が外れる。
- 見る file が無い、regular file でない、symlink、256 KiB を超える、UTF-8 でない、先頭の行が agent-tools の instruction の
  marker でない。
- 記録の directory を決められない (stderr に 1 行)。

記録を書けないとき (directory を作れない、権限が無い) と想定外の例外では、stderr に 1 行を出します。記録が既にあって file が
変わっているときは、促しを出した後に記録の更新が失敗するので、次の入力でもう一度促します (見逃しにしないため)。

この hook は読み直しを促す steering で、品質や安全の gate ではないので、hook の失敗で session を塞ぎません。`SessionStart` の
stdout は context に足されるので、`SessionStart` では何も出しません。

## 限界

- 促すだけで、読み直しを強制しません。
- hook を登録する前から続いている session は、最初の入力で記録を作るだけです。その時点で古い版を持っていても、次の配備
  までは促しません。
- Claude Code が file を読んでから hook が記録するまでの、ごく短い間に配備が入ると、見逃します。
- 見る file は agent-tools が配備した運用 instruction だけです。人が手で書く `<claude home>/CLAUDE.md` や、project の
  `CLAUDE.md` / `AGENTS.md` の変更は見ません。

## 対象にしないもの

- Codex。Codex は 0.156.0 から、global の `AGENTS.md` を model への request のたびに disk から読み直し、内容が変わると
  置き換えの断片を会話に足します (source で確認。公式 docs は「起動時に 1 回」のまま)。個人機の記録にも、配備の直後に
  置き換えの断片が入った session があります。manifest の target は claude-code だけです。
- `InstructionsLoaded` を使った記録。Claude Code が instruction を読み込んだ時点で発火する event ですが、発火が実際の読み取りの
  時点かを実機で確かめていません。確かめてから別に決めます。

## 登録 (dotfiles)

本体は agent-tools が `~/.claude/agent-tools/scripts/personal-instruction-update-notice` に配備し、登録は dotfiles が Claude Code の
settings.json で行います ([dotfiles との境界](boundary-with-dotfiles.md))。例:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/agent-tools/scripts/personal-instruction-update-notice", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "~/.claude/agent-tools/scripts/personal-instruction-update-notice", "timeout": 10 } ] }
    ]
  }
}
```

ほかの `SessionStart` / `UserPromptSubmit` の hook と並べてよいです。

## 出典

- Claude Code の docs (2026-11-16 に確認): [memory](https://code.claude.com/docs/en/memory.md)、
  [context window](https://code.claude.com/docs/en/context-window.md)、[hooks](https://code.claude.com/docs/en/hooks.md)。
  `UserPromptSubmit` の `additionalContext` は入力と一緒に model に届き、`systemMessage` は人に表示されます。どちらも
  10,000 字を超えると file に退避されるので、節の数と名前の長さに上限を置いています。
- 調査の数字は #688 のコメントにあります。

## Test

`scripts/tests/instruction-update-notice-test.sh`。節の分け方は module を require して直接、hook は一時 directory の配備先の形
(`<claude home>/agent-tools/scripts/` と、その隣の `CLAUDE.md`) に写して起動し、stdin の JSON と stdout・exit code・記録の file を
確かめます。
