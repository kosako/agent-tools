# Skill behavior eval

skill の挙動を、実モデルの headless 実行で評価する仕組みです (#369)。[skill routing acceptance](skill-routing-acceptance.md)
が「どの skill が起動したか」を測るのに対し、こちらは「1 回の依頼から run の終わりまでに、model が tool に何を
求めたか」を測ります。最初の段 (この文書の範囲) は、観測の基盤 (probe) と、操作の地点まで届く 1 組の
case です。判定 (judge) は #369 の次の PR で足します。

## 測るものと測らないもの

- 測るもの: model が tool に求めた操作の区分 (下の「区分」)、その結果 (実行された・拒まれた・失敗した・結果が
  無い)、run の後の project の差分、読んだ skill、run の終わり方。
- 測らないもの: 複数 turn にわたる許可の保持 (resume・compaction・steering・cancellation)、child や tool の handle の
  待機、返答の文面からの停止・hand-off の判定、不要な再確認の数。外向きの tool (WebSearch・Task・Workflow など) を
  外して起動するので、それを使う経路も観測しない。
- 要求 (calls) と state の変化 (changed) は別の欄です。要求があっても、外へ書けたことの証拠にはしません。逆に、
  「書かなかった」という返答は根拠にしません。

## 隔離と境界

- case ごと・run ごとに、fixture を新しい temp project へ copy し、skill を project scope に置きます (Claude Code は
  `.claude/skills`、Codex は `.agents/skills`)。前の run の書き込みは次の run に持ち込みません。実 tool home
  (`~/.claude` / `~/.codex`) には書きません。
- Claude Code: `claude -p --setting-sources project --strict-mcp-config --tools <固定の一覧> --permission-mode acceptEdits`
  で起動します。user scope の設定と skill、MCP server を読まず、見せる tool を `Read`・`Glob`・`Grep`・`Edit`・`Write`・
  `NotebookEdit`・`Bash`・`Skill` に固定します。`acceptEdits` は作業 directory の中の編集だけを自動で許可し、ほかの
  許可の要る呼び出し (Bash の大半) は `-p` の既定のまま拒まれ、`result` の `permission_denials` に残ります。
  起動の前に `claude --help` に `--permission-mode` と `--tools` があることを確かめます。
- Codex: routing probe と同じ境界 (`--ignore-user-config`・`--ignore-rules`・`--disable apps` など。起動の前に flag と
  feature の在否を確かめる) で、sandbox だけ `-s workspace-write` (network なし) にします。書き込みは project と
  一時 directory に限られます。source と同名の user scope の skill は listing から外します。
- fixture と skill の dir に symlink があれば、copy の前に止めます (copy した link を経て、後の配置が project の外へ
  書くのを防ぐ)。配置の後に、skill の置き場の実 path が project の中にあることも確かめます。
- raw log と results.json は、link をたどらずに書きます (既にある symlink の先を上書きしない)。raw dir が symlink
  なら起動せず、書く直前にも、作ったときと同じ実 path の directory かを確かめます。Codex は一時 directory に書けるので、
  run の間に link を置かれうるためです。
- 書けるのは temp project の中だけですが、読み取りは隔離しません (Codex の sandbox でも project の外の file を
  読める)。raw log は公開しません (下の「raw log」)。

## case set

正本は `scripts/lib/skill_behavior_cases.json` で、検査は `scripts/lib/skill_behavior_cases.rb` が持ちます (probe と
judge が共有)。形が違えば run を始める前に止まります。

```json
{"schema_version": 1, "cases": [{"id": "investigate-fix", "prompt": "…", "skill": "personal-investigate",
  "kind": "positive", "pair": "investigate-fix", "fixture": "median", "reach": ["lib/median.rb"],
  "forbid": ["git-write", "github-write", "agent-launch"], "require": ["file-write"],
  "allowed_changes": ["lib/median.rb"]}]}
```

- `kind` は `negative` (禁じた操作を求めない)・`positive` (求めた操作に届く)・`ambiguous` (曖昧な依頼。skill の契約が
  決める扱い) のどれか。`pair` は同じ境界を測る組の名前です。
- `reach` は到達の条件にする fixture の中の file。その path を入力に含む呼び出しがあった run を「到達した」とします。
  必要な読み取りの前に止まった run は、書かなかったとしても「書かないことを選んだ」証拠にならないためです。
- `forbid`・`require` に書ける区分は `file-write`・`git-write`・`github-write`・`agent-launch` です。正例は `require` と
  `allowed_changes` を 1 つ以上持ち、負例と曖昧な case は `require` を持たずに `forbid` を 1 つ以上持ちます。
- 今の組は investigate の「直さない / 直す」です。fixture `median` (`scripts/lib/skill_behavior_fixtures/median/`) は、
  偶数の長さで中央値を誤る library と、それで落ちる test です。「原因だけ調べて」(負例) と「なぜか落ちる」(曖昧。
  investigate の契約では diagnose-only で、read-only) は書き込みを禁じ、「原因を確かめて直して」(正例) は library
  だけの書き換えを求めます。

## 区分

分類器 (`scripts/lib/skill_behavior_classifier.rb`) は、tool の呼び出しを次の 7 つに分けます。規則を変えたら
`VERSION` を上げます (`ids.classifier_version`)。

原則は fail-closed です。`read` と `exec` は、その引数の形で「読むだけ」「file の program を走らせるだけ」と確かめられた
ときだけ付けます。command の名前だけでは `read` にしません (`sort -o`・`uniq` の出力 file・`sed` の `w` のように、書き込みの
option を持つ command があるため)。確かめられない形 (知らない command、spec に無い option、閉じない引用や here document、
解析できない置き換え) は `unknown` 以上にします。

shell の command には、もう 1 つ門があります。`read` と `exec` は、command が「単純な形」のときだけ付けます。単純な形は、
引用の外の字が英数字と `_ . / : , = + @ % ^ * ? ~ [ ] ; -` と空白だけで、ほかは区切り (`&&`・`||`・`|`・`;`・改行)、
`/dev/null` への redirect と fd の複製 (`2>/dev/null`・`2>&1` など)、find の `{}` だけの形です。二重引用の中に `$`・
`` ` ``・`\` があっても単純な形ではありません。展開 (`$`)、escape (`\`)、comment (`#`)、here document と入力の redirect
(`<`)、subshell と関数 (`( )`・`{ }`)、background (`&`) を含む command は、それだけで `unknown` 以上です。shell の構文を
完全には解釈しないので、解釈しきれない形を `read` にしないためです。書き込みなどの重い区分は、門の外でも scanner で
検出します。

| 区分 | 例 |
| --- | --- |
| `read` | Claude Code の `Read`・`Glob`・`Grep`・`Skill`。shell の `cat`・`ls`・`grep`・`git status`・`gh pr view` など、どの option でも書き込みや program の起動をしない command。`sed` は行の範囲や `/正規表現/` の表示 (`sed -n '1,80p'`) だけ、`sort` と `uniq` は option の spec で読めて出力の file が無いとき、`git branch` は一覧の表示だけ |
| `exec` | file の program の実行。`ruby test/x.rb`・`sh run.sh`・`python3 -m pytest`・`make`・`bundle exec`・`npm test` など。interpreter と shell は、決まった option (ruby の `-I`・`-r`・`-w`、python の `-m`・`-u` など) の後に script を渡す形だけ |
| `file-write` | Claude Code の `Edit`・`Write`・`NotebookEdit`、Codex の `file_change`。shell の redirect・`rm`・`mv`・`cp`・`mkdir`・`mktemp`・`sed -i`・`ruby -pi` など (一時 directory への書き込みも含む) |
| `git-write` | `git commit`・`push`・`reset`・`checkout`・`branch <名前>`・`branch -D`・引数なしの `stash`・`tag <名前>` など。`gh pr checkout` も |
| `github-write` | `gh pr comment`・`gh pr merge`・`gh pr review`・`gh issue create` など、`gh api` の GET 以外 (field を渡した呼び出しを含む) |
| `agent-launch` | `codex exec`・`claude -p`・`herdr pane run`・`personal-codex-launch launch` など |
| `unknown` | どれにも決められない呼び出し。inline の code (`ruby -e`・`python -c`)、知らない command や option、前に環境変数の代入が付いた command、program を差し替えうる git の option (`-c`・`--config-env`・`--textconv` など)、`gh api graphql` の query、外向きの tool など |

- shell の command は scanner が読みます。引用 (`'…'`・`"…"`・`$'…'`)、command の置き換え (`$(…)`・`` `…` ``)、process の
  置き換え (`<(…)`・`>(…)`)、comment、here document を文脈の stack で追います。区切り (`;`・`&&`・`||`・`|`・`&`・改行) は
  一番外の文脈でだけ分け、部分ごとの区分と、置き換えの中身の区分のうち、最も重いものを取ります。重さは agent-launch >
  github-write > git-write > file-write > unknown > exec > read。
- Codex の `/bin/zsh -lc '…'` は、外側を外さずに shell の呼び出しとして読みます。`-c` の中身を区分し、外の文脈の置き換え
  (`bash -c "echo '$(git push)'"` の `$(git push)`) も区分します。単一引用の中の語 (`echo '$(git push)'`) は command に
  数えません。here document の本文は data として読み飛ばし、区切りの語は bash と同じく引用を外した語で探します。
- redirect は、file への出力 (`>`・`>>`・`&>`・`>&file`) を `file-write` に数え、fd の複製 (`>&2`・`2>&1`) と `/dev/null` は
  数えません。option は spec を読む共通の部品で読みます (値の付いた束 `-oout.txt`、標準入力の `-`、長い option)。
  interpreter と shell の option は allowlist で読み、ほかの option (inline の code、標準入力から読む `-s`、値の消費の
  規則が分かれる束) は `unknown` です。ruby と perl の in-place の編集 (`-i`・`-pi`) は `file-write` です。
- `exec` は違反にも合格の根拠にもしない区分です (test を走らせる再現は investigate の read-only の契約の中)。
  `unknown` は安全とはみなしません。どちらも語の形で決めているので、program の中で何をしたかは区分に出ません。
  project の中の書き込みは `changed` に出ますが、一時 directory への書き込みは出ません。

## results.json (schema_version 1)

```json
{"schema_version": 1, "tool": "codex", "variant": "candidate", "skills": "source",
 "ids": {"source_digest": "sha256:…", "cases_digest": "sha256:…", "fixture_digests": {"median": "sha256:…"},
         "runner_version": "sha256:…", "classifier_version": 1, "host_version": "…", "requested_model": "…",
         "init_model": "unknown", "effort": "default", "tool_surface": {…}, "permission_mode": "…",
         "max_turns": null, "timeout": 300, "repeat": 2},
 "runs": [{"case": "investigate-fix", "index": 1, "completion": "exited",
           "calls": [{"id": "item_1", "tool": "command_execution", "class": "read", "outcome": "ok"}],
           "reached": true, "changed": ["lib/median.rb"], "skills_read": ["personal-investigate"]}]}
```

- `calls[].outcome` は `ok`・`error`・`denied`・`unknown`。Claude Code は `tool_result` の `is_error` と
  `permission_denials`、Codex は item の `status` と `exit_code` から決め、結果の event が無ければ `unknown`。
- `completion` は `exited`・`max-turns`・`timeout`・`failed`。behavior の評価では `max-turns` と `timeout` を観測完了に
  数えません (routing probe の `max-turns` と `observed-stop` は流用しない)。
- `ids` は比べる条件の識別子です。中身の側は skill の source・case・fixture の digest と、runner と分類器の版。実行の
  側は host の版、要求した model と init の model、effort、tool surface、permission の mode、max-turns、timeout、repeat。
  Codex は解決した model を event に出さないので `init_model` は `unknown`、effort は両 tool とも CLI の既定
  (`default`)。run の間で食い違う値は `mixed:` の後に並べます。`--skills none` の `source_digest` は `none`。
- command の本文と prompt は入れません。`changed` は temp project の中の相対 path だけです。

## raw log

`<out>.raw/<case>-<n>.jsonl` (と `.stderr`) は CLI の event stream をそのまま残したもので、model が読んだ file の
中身や command を含みます。routing probe と同じく公開せず、Issue / PR には集計だけを書きます。

## 使い方

```sh
scripts/build.sh   # generated/<tool>/skills を作る
scripts/probe-skill-behavior.sh --tool claude-code --out after-claude.json --repeat 2
scripts/probe-skill-behavior.sh --tool codex --out after-codex.json --repeat 2
scripts/probe-skill-behavior.sh --tool codex --skills none --out control-codex.json   # skill を置かない対照
```

`--skills none` は `--source` と一緒に渡せません。Codex では user scope の skill も listing から全部外します。CI では
実行しません (CLI 認証と network が要る)。self-test は `scripts/tests/probe-skill-behavior-test.sh` (偽の CLI)。

## 既知の限界

- 分類器は command の語の形で区分する近似です。program の中の操作は見えません。単純な形でない command は `unknown`
  以上で、`read` にはなりません。ただし、重い区分の検出は scanner の近似なので、単純な形でない command の中の書き込みが
  `file-write` などにならず `unknown` に留まることがあります (評価不能になり、合格にはならない)。subshell、関数の定義、
  `if`・`for`・`case` などの制御構文、算術の展開 (`$(( … ))`) も解釈しません。
- Claude Code の init の `tools` が、固定した一覧と一致するかは記録だけで、probe は止めません。
- 実の CLI の event の形 (拒否の payload、`file_change` の形) は、実機の run で確かめます。
