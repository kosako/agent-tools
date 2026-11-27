# skill routing acceptance harness (#280)

skill の description / 本文を変えたとき、**routing (どの依頼でどの skill が発火するか) が壊れて
いないこと**と、**context / token 量がどう変わったか**を、Claude Code と Codex の両方で実測する
harness です。#216 の cross-skill routing suite の最小 slice で、
[Skill routing contracts](skill-routing-contracts.md) の Representative routing queries を機械 eval に
したものです。

構成は credential 隔離 harness ([credential-isolation-acceptance.md](credential-isolation-acceptance.md))
と同じ **probe (実機・観測) / judge (offline・判定) の分離**です。

| 部品 | path | 役割 | CI |
| --- | --- | --- | --- |
| case set | `scripts/lib/skill_routing_cases.json` | 依頼 prompt と期待 (primary / must_not) の正本 | schema を self-test で検証 |
| probe runner | `scripts/probe-skill-routing.sh` | 隔離 project で `claude -p` / `codex exec` を流し、発火した skill と token を観測して `results.json` を書く | probe は実行しない (CLI 認証と network が要る)。起動の argv・起動の前の flag の確認・event の解析は self-test (`scripts/tests/probe-skill-routing-test.sh`。偽の CLI と固定の JSONL) |
| judge | `scripts/check-skill-routing.sh` | case set と `results.json` から coverage / primary hit / must_not violation / token を判定・報告する。`--baseline` で before / after を比較する | self-test (`scripts/tests/check-skill-routing-test.sh`) |

## 何が hard で何が hard でないか (honest-label)

- **hard**: judge の判定は deterministic で、fixture で検証されている。coverage 欠落・error run・
  比較条件の不一致は緑に数えず exit 2 に倒す (偽の安心を作らない)。primary を持つ case があるのに ok の run の
  observed がすべて空 (観測の全損) のときも exit 2 にする (#582)。probe runner の Codex の起動の境界
  (起動の argv と、起動の前の flag と feature の確認。欠けていれば起動せずに exit 2) と event の解析も、
  偽の CLI と固定の JSONL を使う offline の self-test (`scripts/tests/probe-skill-routing-test.sh`) で
  固定している (実際の CLI の event 形式との一致は対象外で、下の「hard でない」側)。
- **hard でない**: probe の観測は CLI の headless 実行と event stream に依存する。単発 turn の
  headless 実行は対話 session の代理であって同一ではなく、同じ prompt でも model の揺れで結果が
  変わる。field 名が変わると observed が空になる。全 run で空になれば judge は観測の全損として exit 2 で止めるが、
  一部の run だけが空になったときは primary MISS として現れるだけで、1 件ずつの MISS は exit に響かない (exit 0 の
  まま)。baseline と比べても、両方で同じ case の観測を失っていれば回帰にはならない。exit 0 を観測の健全性の証拠と
  読まない。**probe の結果は「同条件の before / after を比べる」用途に限り、
  絶対値を品質の保証として読まない。**
- Codex は `first_prompt_tokens` を取れない (event に turn 合計の usage しか無い) ので、token の比較は
  `prompt_tokens` (turn 全体) と静的な `listing_chars` で見る。`--max-turns` 相当も無く、run は model が
  終えるか `--timeout` (既定 300 秒) で kill されるまで走る。kill した run は、skill を読んでから作業に入った印が
  あれば観測完了 (`completion: observed-stop`) に数え、token は取らない (下の「観測契約」。#302)。

## 隔離

probe は一時 directory に project を作り、候補 skill を **project scope** に copy して実行する。probe 自身は tool home
(`~/.claude` / `~/.codex`) に書き込まない。CLI 自身が home に置く状態の file (認証・cache・log など) は見ていない。

Claude Code の子 process には `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` を渡し、自動の memory を止める (#770)。止めないと、run ごとに
`~/.claude/projects` の下に、temp project の名前の dir と空の `memory` ができ、model に memory の置き場が示される (2.1.331 で確かめた)。

| tool | 候補 skill の置き場 | user scope の排除 | 確認した版 |
| --- | --- | --- | --- |
| claude-code | `<proj>/.claude/skills/<name>/` | `--setting-sources project` (user / local の settings と skill を読まない) | 2.1.277 (2026-09-20 smoke): `~/.claude/skills` の `personal-*` と plugin skill は listing から消え、project skill と bundled skill (dataviz / code-review 等) だけが残る。bundled は両 variant に等しく載る |
| codex | `<proj>/.agents/skills/<name>/` (公式 docs の repository-level path) | 候補と同名の `~/.codex/skills/<name>/SKILL.md` を `-c 'skills.config=[{path=...,enabled=false},...]'` で無効化 | 0.153.4 (2026-09-21 実測): project scope は読まれる。user scope の同名 skill は **両方 listing に並ぶ** (`--ignore-user-config` では消えない。plugin skill だけ消える)。`skills.config` で 12 本を無効化すると候補だけが残る。他の user / plugin skill は両 variant に等しく載る。0.159.3 (2026-10-03、下の起動の境界つき): listing は候補 14 本と、候補以外の skill 5 本 (system の imagegen / openai-docs / skill-creator / skill-installer と、user scope の migrate-to-codex) で、plugin skill は消える |

claude-code の観測に使う event (2.1.277 で実測): `system` / `init` の `model`、`assistant` の `tool_use`
(`name: "Skill"`, `input.skill: "<name>"`)、`result` の `usage` (`input_tokens` /
`cache_creation_input_tokens` / `cache_read_input_tokens` / `output_tokens`)。listing は `system` / `init` の
`skills` に出る (2.1.277 で実測) が、runner はこの field を読まない。上の表の隔離 (user scope の skill が
listing から消えること) は、`--smoke` で model に見えている skill を列挙させ、その答えで確かめる。

codex の観測に使う event (0.153.4 で実測): `item.completed` の `item` (`type` が `command_execution` なら
`command` に読んだ path が出る)、`agent_message` の `text` (最終応答)、`turn.completed` の `usage`
(`input_tokens` / `cached_input_tokens` / `output_tokens` など。turn 内の全 API call の合計)。model は event に
出ないので `--model`、無ければ `$CODEX_HOME/config.toml` の top-level `model` を `-m` で渡し、その値を記録する。

codex の「起動」= **command 文字列に `/<name>/SKILL.md` が現れた読み取り** (読んだ順、重複なし)。scope は
問わない: listing から外した user scope (`~/.codex/skills/<name>/`) や `.system/../<name>/` を model が推測して
読む run が実測で多く (baseline 24 run 中 10 run 以上)、project path だけでは起動を取りこぼす。command の出力
(`aggregated_output`) は見ない (`ls` の結果に全 skill の path が並ぶと全件起動に化ける。初版で実際に起きた)。
1 run で 6 本 (runner の定数 `CODEX_SURVEY_THRESHOLD`。初版の inventory 12 本の半数で、inventory の数からは計算しない)
以上を読んだ run は **探索読み**とみなし、最初に読んだ skill だけを
`observed` にして残りを `note` に残す (Claude Code の `Skill` 呼び出しと違い、codex は file を読むだけなので
安価に全部読める run がある。baseline 24 run 中 1 run)。これは heuristic であり、raw log で確認できるように
しておく。探索読みの 1 本目が must_not なら、今までどおり `observed` に入って violation になる (heuristic は「最初に
読んだものを選んだ」とみなす)。2 本目以降は `observed` に入らないが、下の `reads` に残り、judge が要確認にする (#720)。

claude-code の MCP server は `--strict-mcp-config` で読まない。headless では MCP の起動が最初の API call に間に合う
かが run ごとに揺れ、baseline の実測 (2026-09-20) では 24 run が `tools=25 / mcp=0` と
`tools=72 / mcp=5` の 2 群に割れて `first_prompt_tokens` に ±2.7k token の差が出た (skill listing は
全 run で一定)。description 圧縮で期待する差 (1〜2k token) より大きいので、条件を固定する。

codex は監査 / review の起動と同じ境界で起動する (#372): `--ignore-user-config` (user の `config.toml` と、そこに
足される bootstrap の MCP server を読まない)、`--ignore-rules` (execpolicy の rules を読まない)、`--disable apps` /
`--disable computer_use` / `--disable browser_use` (account 側の connector と sandbox の外へ届く tool を外す)。
case の prompt には PR へのコメントや merge を頼むものがあり、read-only の sandbox は MCP / connector の tool の
呼び出しを止めないため。起動の前に `codex exec --help` に flag があり、`codex features list` に disable する
feature の行があることを確かめ、どちらかが欠ければ起動せずに exit 2 で止まる (`--dry-run` は CLI を起動しないので
確かめない)。user config を読まないので effort は Codex の既定になり、plugin skill は listing から消える。どちらも
baseline と candidate に等しく効くので、同じ版の probe で測った前後の比較は成り立つ (境界の無い版で測った
results とは比べない)。0.159.3 の smoke では、prompt は境界なしの約 20.2k token から約 17.2k token に減り、
2 case の実行で発火の観測 (SKILL.md の読み取り) は変わらず取れた。

候補 skill の既定の source は `generated/<tool>/skills` (build 済みの配布物)。`--source DIR` で
別の dir (例: 圧縮前の generated を退避したもの) を指せるので、baseline と candidate を同じ
手順で測れる。

## 観測契約 (probe → results.json)

```json
{ "schema_version": 2, "tool": "claude-code", "model": "<model id>", "variant": "baseline",
  "listing_chars": 4952,
  "runs": [ { "case": "<case id>", "observed": ["<skill name>", ...],
              "prompt_tokens": 1234, "output_tokens": 56, "first_prompt_tokens": 1000,
              "status": "ok", "completion": "exited",
              "reads": [ { "skill": "<skill name>", "path": ".agents/skills/<name>/SKILL.md", "via": "command",
                         "copy": "candidate", "sha256": "<64 桁の hex>" } ] } ],
  "auto_memory": { "requested": "off", "init": "not-listed" } }
```

- `observed`: その run で **起動された** skill 名。claude-code は stream-json の `Skill` tool_use、
  codex は `command_execution` の command 文字列に現れた `/<name>/SKILL.md` の読み取り (scope 不問、
  出力は見ない。詳細は上の「隔離」の節の codex の「起動」の段落) から取る。listing に載っているだけの
  skill は含めない。
- `reads` (任意。#720): その run の読み取りの **痕跡の全部** (読んだ順、重複を除かない)。`observed` は primary の推定
  (Codex は探索読みを圧縮する) なので、must_not の判定には `reads` も使う。要素は次の 5 つ。
  - `skill`: 読んだ skill の名前。`observed` と同じ規則 (直前が `/<name>/`) で決め、決められなければ null
    (`cd <dir> && cat SKILL.md` や `find -name SKILL.md`、glob の `*/SKILL.md`)。`observed` の名前は必ず `reads` に入る。
  - `path`: 入力に現れた path の表記 (local の絶対 path を含みうる)。`via`: `skill` (Claude Code の `Skill` の呼び出し)・
    `read` (Claude Code の `Read` の `file_path`)・`command` (Codex の command と Claude Code の Bash の command)。
  - `copy`: `candidate` (実体が候補の `SKILL.md`)・`same-content` (別の置き場で中身が同じ)・`other` (中身が違う。user の
    home の古い copy など)・`unknown` (file に解決できない、名前を決められない)・`listing` (`Skill` の呼び出し。listing の
    skill を呼んだもので、置き場は `--smoke` の隔離の確認による)。判定は、先頭の `~/`・`$HOME/`・`${HOME}/` を run の
    `HOME` で展開し、相対の path は作業 dir (proj) から解き、`realpath` (symlink と `..` を解く) の実体で行う。字面では
    決めない。`sha256` は解決できた file の中身の hash (run の直後、proj があるうちに取る)。
  - 痕跡は入力の文字列 (command・`Read` の `file_path`) に現れた `SKILL.md` だけで、出力 (`aggregated_output`) は見ない。
    痕跡が無いことは「読まなかった」証明ではない。
  - `reads` には local の path が入るので、results.json も raw log と同じく Issue / PR / comment には貼らない。
- `prompt_tokens`: claude-code は `result.usage` の input + cache_creation + cache_read の合計
  (skill listing は system prompt 側なので cache に現れる)。codex は usage の `input_tokens`。
  `output_tokens` は各 CLI の値。どちらも run 全体の合計で、turn 数 (model の振る舞い) に依存する。
  `completion: observed-stop` の run だけ、どちらも `null` (kill した run の usage は信用しない)。
- `first_prompt_tokens` (任意): 最初の API call の prompt 量 (claude-code は最初の `assistant`
  event の `message.usage` の合計)。turn 数に依存しないので、listing の大きさの差はこちらに
  素直に出る。judge は全 ok run が持つときだけ集計する。
- `--max-turns` (既定 2) の打ち切り (`result.subtype == "error_max_turns"`) は **観測完了**として
  `status: ok` にする。routing の判断 (Skill 起動) は最初の turn で出るので、skill が起動した後の
  作業は走らせない (baseline 24 case のうち 20 case がこの形で終わった)。
- `listing_chars`: 候補 skill の description の合計文字数 (毎 turn 載る静的な context 量の指標)。frontmatter を
  YAML として読んだ値で数える (#417。YAML のコメントで切れた description は、切れた後の長さになる)。
  Claude Code は description を 1,536 文字で切り、Codex は listing 全体を context の 2% または
  8,000 文字に収める (2026-09-19 時点の公式 docs)。
- `status`: CLI が非ゼロで終わった run (上の `--max-turns` の打ち切りを除く)、`--timeout` で kill した run、CLI が
  exit 0 で終わっても出力を最後まで読み切れなかった run (CLI が残した子 process が pipe を握ったまま、待つ上限の
  5 秒を過ぎた) は `error`。kill した run と読み切れなかった run は、打ち切りの result を出していても `error`。usage が
  取れなかった run (Claude Code は result の、Codex は turn.completed の usage が無い、または `input_tokens` /
  `output_tokens` が整数でない) も `error`。judge は緑に数えない。ただし下の `observed-stop` は、kill した run でも `ok`。
- `completion` (schema_version 2、#302): run の終わり方。`status` と次のように対応する (judge は食い違いを入力
  エラーにする)。
  - `exited` (`ok`): CLI が exit 0 で終わり、usage が取れた。
  - `max-turns` (`ok`): Claude Code の `--max-turns` の打ち切り (上)。
  - `observed-stop` (`ok`): Codex の run を `--timeout` で kill し、出力を読み切れていて、kill の前に「skill を読んで
    から作業に入った印」が立っていた。印は、候補 skill の `SKILL.md` を読んだ後に、`SKILL.md` を読まない tool の item
    (`item.completed` の type が `command_execution`・`file_change`・`mcp_tool_call`・`web_search`) が 2 つ続いたこと。
    `agent_message` などは数えず、`SKILL.md` を含む command (候補か否か、前に `/` があるかを問わない。
    `cd <dir> && cat SKILL.md` の形を含む) は数を 0 に戻し、知らない type は数えない。2026-09-21 の Codex の raw log (48 run) に当てると、observed が変わるのは作業の途中で skill を読み回した
    1 run だけだった。kill を待たずに印の時点で止める形は採らない (ほぼ全 run が印の後も作業を続け、Codex の token は
    `turn.completed` にしか出ないので、token の before / after を比べられなくなる)。
  - `timeout` (`error`): kill した run で、`observed-stop` の条件 (出力を読み切れた、印が立った) を満たさない。
    Claude Code の kill した run は、打ち切りの result があってもここに入る。
  - `failed` (`error`): 期限の中で終わった run で、`exited`・`max-turns` に当たらない (非ゼロ終了・usage が無い・
    出力を読み切れない)。CLI の失敗は、skill の読み取りが見えていても `ok` にしない。
  - 終わり方は、期限の中で終わった run (`exited`・`max-turns`・`failed`) と、kill した run (`observed-stop`・`timeout`)
    に分かれる。
  - judge は schema_version 1 の結果も読む (`completion` は無く、token は整数)。
- `auto_memory` (任意。claude-code だけ。#770): 自動の memory の記録。`requested` は渡した設定 (いつも `off`)、`init` は run の init の
  event に見えた状態 (`listed` / `not-listed` / `unknown`、run の間で違えば `mixed:` の後に並べる)。judge は `not-listed` のときだけ
  緑にする。`not-listed` の意味と限界は [Skill Behavior Eval](skill-behavior-eval.md) の「results.json」と同じ。
- raw log は `<out>.raw/<case>-<n>.jsonl` に残す。observed が正しいかはこの log で人が確認する
  (judge は runner の観測を信頼する。信頼境界は judge の冒頭コメント参照)。raw log は private な内容を
  含みうるので、Issue / PR / comment には貼らない (下の「raw log の扱い」)。

## 判定契約 (judge)

```sh
scripts/check-skill-routing.sh --cases scripts/lib/skill_routing_cases.json \
  --results after.json [--baseline before.json]
```

- **coverage**: case set の全 case に `ok` な run があること。欠落 / error run は構造エラー。
- **primary hit**: case の `primary` が `observed` に含まれる (`primary: null` の case は対象外)。
  MISS は報告するが、単独では破れにしない (headless 単発 turn の揺れがあるため)。
- **must_not violation**: `must_not` のいずれかが `observed` に含まれる = routing の破れ (exit 1)。
- **要確認** (#720): `reads` があり、`must_not` の skill が `reads` にあるのに `observed` に無い run、または `must_not` の
  ある case で名前を決められない `SKILL.md` の読み取りがある run。`review:` の行で、case、run、skill (決められなければ
  その旨)、`reads` の中の番号、`copy` を出し、case の行は `must_not=review(...)` にする。違反でも、禁じた動作が無かった
  証明でもないので、破れと構造エラーが無ければ exit 3 にし、`ok: skill routing verified` は出さない。run の status に
  よらず出す (error の run では exit 2 が優先する)。baseline の構造エラーがあっても、候補の `review:` の行は出す。
- **copy の報告** (#720): 候補と違う copy (`same-content`・`other`・`unknown`) の読み取りは `note:` の行で出す。報告だけで、
  exit と primary hit の数え方は変えない。
- **`reads` の形**: 在れば要素の 5 つの key の形を確かめ、`observed` の名前が `reads` の名前に全部含まれることを求める
  (違えば exit 2)。`reads` の無い古い結果 (schema_version 1・2) は、`observed` だけで今までどおり判定する。
- **自動の memory** (#770): `auto_memory` が在り、`init` が `not-listed` でなければ構造エラー。形が違うとき、Codex の結果に在るときは
  入力の誤り (どちらも exit 2)。
- **baseline 比較**: 同じ tool・同じ model・同じ case 集合・同じ run 数・同じ `auto_memory` (無いものどうしを含む) の結果だけ
  比較する (違えば exit 2)。primary は case ごとに比べ、baseline で半分以上の run が当たっていた case が、候補で一度も当たらなければ
  回帰 (exit 1。#417)。それより小さい減少は case ごとに `warn:` の行で出し、exit には響かない。合計の hit は比べない
  (ある case の回帰が別の case の改善で打ち消され、揺れだけの差が回帰になるため)。must_not は、候補で 1 回でも出れば
  baseline によらず case ごとに破れ (上)。構造エラー (coverage 欠落・
  error run・比較条件の不一致) が baseline / candidate のどちらかにあると、比較 (delta の表示と回帰の判定) を
  しない。candidate 自身の must_not violation は、その場合も exit 1 として出る。
- **token は gate にしない**。delta (%) を報告するだけ。「減った」ことは受け入れ条件として
  Issue / PR に記録する。token が `null` の run (`observed-stop`) は合算から外し、summary の末尾に
  `runs_without_tokens=<数>` を出す (平均の分母は token を持つ run の数)。delta は、両方の結果で全 run が token を
  持つ case だけで合計を取り直し、外した case があればその数を末尾に出す (#302)。
- exit: `0` = pass、`1` = 破れ / 回帰、`2` = 入力・構造エラー、`3` = 要確認 (#720)。優先は 1 > 2 > 3 > 0 で、
  候補の結果を読めないときは、その場で exit 2 にする。baseline を読めないときは `error:` の行で出し、候補の破れと
  要確認は捨てずに報告する (破れがあれば exit 1、無ければ 2)。
  同居したものは全件報告する。exit 3 では、`review:` の行の run の raw log を人が読んで、禁じた skill の手順で動いたかを確かめる。

## 使い方 (description を変える PR での before / after)

```sh
# 0. 隔離と event 形式の確認 (tool ごとに最初の 1 回)
scripts/probe-skill-routing.sh --tool claude-code --smoke

# 1. 変更前: build 済みの generated を baseline として観測する
scripts/build.sh
cp -R generated/claude-code/skills /tmp/skills-before
scripts/probe-skill-routing.sh --tool claude-code --variant baseline --model <model> \
  --source /tmp/skills-before --out before.json

# 2. description を変更して build し直し、同じ model で候補を観測する
scripts/build.sh
scripts/probe-skill-routing.sh --tool claude-code --variant candidate --model <model> --out after.json

# 3. 判定 (回帰なしで exit 0。delta に token の増減が出る)
scripts/check-skill-routing.sh --cases scripts/lib/skill_routing_cases.json \
  --results after.json --baseline before.json
```

codex は `--tool codex` で同じ手順。両 tool で回帰なしを確認したものだけ merge する (#280 の
受け入れ条件)。`--repeat N` で揺れを均せる (baseline と candidate で同じ N にする。repeat 1 では 1 回の外れが「一度も
当たらない」になり回帰になるので、gate にするなら 2 以上)。Codex の case `audit-mine-session-logs` は、
`--timeout` まで走ってから `observed-stop` になりやすい (下の「既知の挙動」)。

## raw log の扱い

- raw log (`<out>.raw/<case>-<n>.jsonl` と `.stderr`) は、CLI の event stream と stderr をそのまま保存したもので、
  model の応答と、model が実行した command や読んだ file の中身を含みうる (codex は `command_execution` の
  `aggregated_output` に command の出力がそのまま入る)。probe は project を隔離するが、file の読み取りは
  隔離しない (codex の read-only の sandbox でも project の外の file を読める)。例えば採掘の case
  (`audit-mine-session-logs`) で model が実際の採掘を始めると、実 home の session log の中身が raw log に
  入りうる (#302)。
- そのため raw log とその抜粋は Issue / PR / comment に貼らず、repo にも commit しない。貼るのは judge の
  summary (case ごとの判定と集計) だけにする。raw log で確かめたこと (読んだ skill、打ち切りの理由など) は、
  skill 名や件数の要約として書く。

## 既知の挙動: Codex の `audit-mine-session-logs` (#302)

- Codex では、case `audit-mine-session-logs` の run が `personal-asset-miner` の SKILL.md を読んだあと実際の
  採掘を始め、`--timeout` (既定 300 秒) で打ち切られやすい。Codex には `--max-turns` 相当が無いので、skill を
  読んだ後の作業も打ち切りまで走る。Claude Code は `--max-turns` の打ち切りで止まり、PR #300 の Claude Code 側では
  この case も ok だった。
- 観測: #302 の起票時 (PR #300 の before / after) は baseline / candidate の両方が error run だった。raw log
  では、asset-miner を読んだあと実際の採掘を始め (command 24 本)、1 run の上限 300 秒で打ち切られていた。
  その後の before / after でも、PR #304 では candidate、PR #363 では baseline が error run だった (この 3 PR の
  記録で 6 run 中 4 run)。
- #302 から、打ち切られた run は、skill を読んでから作業に入った印があれば `observed-stop` (`ok`) に数える (上の
  「観測契約」の `completion`)。採掘を始めた run は印が立つので、coverage を満たし、baseline との比較も飛ばない。
  token は取れないので、この case は token の delta から外れる (judge が外した case の数を出す)。
- 期限まで走る間の時間と Codex の枠は、今までどおり使う。model が実 home の session log を読みうることも変わらない
  (上の「raw log の扱い」)。
- 印が立たないまま打ち切られた run (`timeout`) は、今までどおり error run で、judge は exit 2 になり比較を飛ばす。
  そのときは、この case を除いた case set の copy を before / after の両方の `--cases` に渡すか、case ごとの行を
  突き合わせて読む。どちらでも、Codex 側の asset-miner の routing を測っていないことを PR に書き、case を外して
  全体の coverage を満たしたことにしない。
## case set の育て方

- 1 case = 1 依頼 prompt。`primary` は依頼の主目的を所有する skill (無ければ `null`)、`must_not` は
  発火してはいけない隣接 skill。secondary (gate / quality / placement の補助) は列挙しない。
- 新しい skill を足したら `inventory` と、その skill が primary になる case と near-miss の負例を
  足す。self-test が、`inventory` が配布する skill の集合 (shared/ の manifest のうち、どれかの target で
  artifact_kind が skill に解決されるもの。workflow から skill になる asset を含む) と一致することと、
  「production-rail 以外の全 inventory skill に primary case がある」ことを検査する (#582)。
- prompt は `-` で始めない (CLI の option と衝突する)。制御文字は入力エラー。
- case id は raw log の file 名 (`<out>.raw/<case>-<n>.jsonl`) に使うので、英数字と `._-` に限る (先頭は
  英数字)。外れたら入力エラー。
- `personal-resume-project` はどの case の `must_not` にも入れない (理由は下の「検証境界」。self-test が検査する)。

## 検証境界

- headless 単発 turn の観測であり、対話 session (履歴・CLAUDE.md / AGENTS.md の指示・ユーザーの
  訂正) を含まない。user scope の instruction が skill 名に触れる環境では、その影響は before /
  after の両方に等しく乗る。
- model を固定しても揺れはある。`--repeat` と「同条件比較」で扱い、絶対値を保証にしない。
- 単発 headless の probe は毎 run が session の冒頭にあたる。常時 instruction が session 開始時に resume を使うよう
  指示しているので、依頼の内容に関係なく `personal-resume-project` が読まれうる (Codex の `session-placement-question`
  では既存の drift として before / after の両方で観測された。#301)。これは依頼の routing ではなく session 冒頭の
  gate なので、production-rail と同じく secondary として扱い、resume の読み取りを `must_not` に入れない。harness が
  観測しているのは skill の読み取り / 起動であり、resume の内容 (status の報告や continuation) を生成したかではない。
- Codex の観測は skill file の読み取りで判定する。skill を読まずに listing の description だけで
  振る舞う run は observed に出ない (Claude Code の `Skill` tool_use と同じ意味の「起動」で揃えている)。
  探索読みの扱い (最初の 1 本だけを採る) は heuristic で、閾値は runner の定数。
- Codex は run ごとの揺れが Claude Code より大きい (同じ prompt でも skill を読む / 読まない、user scope
  の旧 body を読む、探索する)。`--repeat` を 2 以上にする (1 run の外れは警告で、回帰にはならない)。
- CI では probe を実行しない。証跡は手元の raw log と、Issue / PR に貼る judge の summary (raw log は
  貼らない。上の「raw log の扱い」)。
