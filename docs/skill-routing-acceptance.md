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
| probe runner | `scripts/probe-skill-routing.sh` | 隔離 project で `claude -p` / `codex exec` を流し、発火した skill と token を観測して `results.json` を書く | 実行しない (CLI 認証と network が要る) |
| judge | `scripts/check-skill-routing.sh` | case set と `results.json` から coverage / primary hit / must_not violation / token を判定・報告する。`--baseline` で before / after を比較する | self-test (`scripts/tests/check-skill-routing-test.sh`) |

## 何が hard で何が hard でないか (honest-label)

- **hard**: judge の判定は deterministic で、fixture で検証されている。coverage 欠落・error run・
  比較条件の不一致は緑に数えず exit 2 に倒す (偽の安心を作らない)。
- **hard でない**: probe の観測は CLI の headless 実行と event stream に依存する。単発 turn の
  headless 実行は対話 session の代理であって同一ではなく、同じ prompt でも model の揺れで結果が
  変わる。field 名が変わると observed が空になり、judge には primary MISS として現れる (緑には
  化けないが、原因は runner 側)。**probe の結果は「同条件の before / after を比べる」用途に限り、
  絶対値を品質の保証として読まない。**
- Codex は `first_prompt_tokens` を取れない (event に turn 合計の usage しか無い) ので、token の比較は
  `prompt_tokens` (turn 全体) と静的な `listing_chars` で見る。`--max-turns` 相当も無く、run は model が
  終えるか `--timeout` (既定 300 秒) で kill されるまで走る。

## 隔離 (実 home に触らない)

probe は一時 directory に project を作り、候補 skill を **project scope** に copy して実行する。

| tool | 候補 skill の置き場 | user scope の排除 | 確認した版 |
| --- | --- | --- | --- |
| claude-code | `<proj>/.claude/skills/<name>/` | `--setting-sources project` (user / local の settings と skill を読まない) | 2.1.277 (2026-09-20 smoke): `~/.claude/skills` の `personal-*` と plugin skill は listing から消え、project skill と bundled skill (dataviz / code-review 等) だけが残る。bundled は両 variant に等しく載る |
| codex | `<proj>/.agents/skills/<name>/` (公式 docs の repository-level path) | 候補と同名の `~/.codex/skills/<name>/SKILL.md` を `-c 'skills.config=[{path=...,enabled=false},...]'` で無効化 | 0.153.4 (2026-09-21 実測): project scope は読まれる。user scope の同名 skill は **両方 listing に並ぶ** (`--ignore-user-config` では消えない。plugin skill だけ消える)。`skills.config` で 12 本を無効化すると候補だけが残る。他の user / plugin skill は両 variant に等しく載る。0.159.3 (2026-10-03、下の起動の境界つき): listing は候補 14 本と、候補以外の skill 5 本 (system の imagegen / openai-docs / skill-creator / skill-installer と、user scope の migrate-to-codex) で、plugin skill は消える |

claude-code の観測に使う event (2.1.277 で実測): `system` / `init` の `model` と `skills` (listing)、
`assistant` の `tool_use` (`name: "Skill"`, `input.skill: "<name>"`)、`result` の `usage`
(`input_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` / `output_tokens`)。

codex の観測に使う event (0.153.4 で実測): `item.completed` の `item` (`type` が `command_execution` なら
`command` に読んだ path が出る)、`agent_message` の `text` (最終応答)、`turn.completed` の `usage`
(`input_tokens` / `cached_input_tokens` / `output_tokens` など。turn 内の全 API call の合計)。model は event に
出ないので `--model`、無ければ `$CODEX_HOME/config.toml` の top-level `model` を `-m` で渡し、その値を記録する。

codex の「起動」= **command 文字列に `/<name>/SKILL.md` が現れた読み取り** (読んだ順、重複なし)。scope は
問わない: listing から外した user scope (`~/.codex/skills/<name>/`) や `.system/../<name>/` を model が推測して
読む run が実測で多く (baseline 24 run 中 10 run 以上)、project path だけでは起動を取りこぼす。command の出力
(`aggregated_output`) は見ない (`ls` の結果に全 skill の path が並ぶと全件起動に化ける。初版で実際に起きた)。
1 run で inventory の半数 (6 本) 以上を読んだ run は **探索読み**とみなし、最初に読んだ skill だけを
`observed` にして残りを `note` に残す (Claude Code の `Skill` 呼び出しと違い、codex は file を読むだけなので
安価に全部読める run がある。baseline 24 run 中 1 run)。これは heuristic であり、raw log で確認できるように
しておく。

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
手順で測れる。実 home (`~/.claude` / `~/.codex`) には書き込まない。

## 観測契約 (probe → results.json)

```json
{ "schema_version": 1, "tool": "claude-code", "model": "<model id>", "variant": "baseline",
  "listing_chars": 4952,
  "runs": [ { "case": "<case id>", "observed": ["<skill name>", ...],
              "prompt_tokens": 1234, "output_tokens": 56, "first_prompt_tokens": 1000,
              "status": "ok" } ] }
```

- `observed`: その run で **起動された** skill 名。claude-code は stream-json の `Skill` tool_use、
  codex は `command_execution` の command 文字列に現れた `/<name>/SKILL.md` の読み取り (scope 不問、
  出力は見ない。詳細は下の「codex の起動」) から取る。listing に載っているだけの skill は含めない。
- `prompt_tokens`: claude-code は `result.usage` の input + cache_creation + cache_read の合計
  (skill listing は system prompt 側なので cache に現れる)。codex は usage の `input_tokens`。
  `output_tokens` は各 CLI の値。どちらも run 全体の合計で、turn 数 (model の振る舞い) に依存する。
- `first_prompt_tokens` (任意): 最初の API call の prompt 量 (claude-code は最初の `assistant`
  event の `message.usage` の合計)。turn 数に依存しないので、listing の大きさの差はこちらに
  素直に出る。judge は全 ok run が持つときだけ集計する。
- `--max-turns` (既定 2) の打ち切り (`result.subtype == "error_max_turns"`) は **観測完了**として
  `status: ok` にする。routing の判断 (Skill 起動) は最初の turn で出るので、skill が起動した後の
  作業は走らせない (baseline 24 case のうち 20 case がこの形で終わった)。
- `listing_chars`: 候補 skill の description の合計文字数 (毎 turn 載る静的な context 量の指標)。
  Claude Code は description を 1,536 文字で切り、Codex は listing 全体を context の 2% または
  8,000 文字に収める (2026-09-19 時点の公式 docs)。
- `status`: CLI が非ゼロで終わった / usage が取れなかった run は `error`。judge は緑に数えない。
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
- **baseline 比較**: 同じ tool・同じ model・同じ case 集合・同じ run 数の結果だけ比較する (違えば
  exit 2)。候補で primary hit が減る、または violation が増えたら回帰 (exit 1)。構造エラー (coverage 欠落・
  error run・比較条件の不一致) が baseline / candidate のどちらかにあると、比較 (delta の表示と回帰の判定) を
  しない。candidate 自身の must_not violation は、その場合も exit 1 として出る。
- **token は gate にしない**。delta (%) を報告するだけ。「減った」ことは受け入れ条件として
  Issue / PR に記録する。
- exit: `0` = pass、`1` = 破れ / 回帰、`2` = 入力・構造エラー。破れと構造不備が同居したら 1 を
  優先し、全件報告する。

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
受け入れ条件)。`--repeat N` で揺れを均せる (baseline と candidate で同じ N にする)。Codex で全 case を
流すと、case `audit-mine-session-logs` の error run で比較が飛びやすい (下の「既知の挙動」)。

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
  読んだ後の作業も打ち切りまで走る。打ち切られた run は CLI が正常に終わらないので error run になる
  (SKILL.md の読み取りが raw log に出ていても ok に数えない)。Claude Code は `--max-turns` の打ち切りで
  止まり、PR #300 の Claude Code 側ではこの case も ok だった。
- 観測: #302 の起票時 (PR #300 の before / after) は baseline / candidate の両方が error run だった。raw log
  では、asset-miner を読んだあと実際の採掘を始め (command 24 本)、1 run の上限 300 秒で打ち切られていた。
  その後の before / after でも、PR #304 では candidate、PR #363 では baseline が error run だった (この 3 PR の
  記録で 6 run 中 4 run)。
- error run は構造エラーなので、judge は exit 2 (must_not violation が同居すれば exit 1) になり、どちらでも
  baseline との比較 (delta の表示と回帰の判定) を飛ばす (上の「判定契約」。judge の self-test で固定して
  いる)。そのため、この case を含む Codex の run は judge の exit code で機械的に gate できない。次のどちらかで
  扱う。
  - **subset から外す**: case set の copy からこの case を除いた file を作り、before / after の両方で probe と
    judge の `--cases` に同じ file を渡す (judge はその範囲で gate できる)。Codex 側の asset-miner の routing は
    測っていないことを PR に書き、case を外して全体の coverage を満たしたことにしない。
  - **per-case で読む**: この case を含めて測り、before / after の結果をそれぞれ judge に通して (`--baseline`
    を付けると case ごとの行は candidate 側しか出ない)、case ごとの行を突き合わせる。他の case で primary hit の
    減少や must_not violation の増加が無いことを人が確かめ、この case の結果 (error run かどうか、読んだ skill)
    は件数で書く。`--only` で一部の case だけを流した結果も、正本の case set では coverage 欠落 (exit 2) に
    なるので、こちらで読む。
- 観測の完了で run を止める runner 側の対処は #302 で扱う (未実装)。

## case set の育て方

- 1 case = 1 依頼 prompt。`primary` は依頼の主目的を所有する skill (無ければ `null`)、`must_not` は
  発火してはいけない隣接 skill。secondary (gate / quality / placement の補助) は列挙しない。
- 新しい skill を足したら `inventory` と、その skill が primary になる case と near-miss の負例を
  足す。self-test が「production-rail 以外の全 inventory skill に primary case がある」ことを検査する。
- prompt は `-` で始めない (CLI の option と衝突する)。制御文字は入力エラー。
- case id は raw log の file 名 (`<out>.raw/<case>-<n>.jsonl`) に使うので、英数字と `._-` に限る (先頭は
  英数字)。外れたら入力エラー。

## 検証境界

- headless 単発 turn の観測であり、対話 session (履歴・CLAUDE.md / AGENTS.md の指示・ユーザーの
  訂正) を含まない。user scope の instruction が skill 名に触れる環境では、その影響は before /
  after の両方に等しく乗る。
- model を固定しても揺れはある。`--repeat` と「同条件比較」で扱い、絶対値を保証にしない。
- Codex の観測は skill file の読み取りで判定する。skill を読まずに listing の description だけで
  振る舞う run は observed に出ない (Claude Code の `Skill` tool_use と同じ意味の「起動」で揃えている)。
  探索読みの扱い (最初の 1 本だけを採る) は heuristic で、閾値は runner の定数。
- Codex は run ごとの揺れが Claude Code より大きい (同じ prompt でも skill を読む / 読まない、user scope
  の旧 body を読む、探索する)。`--repeat` を使い、1 run の差を回帰と読まない。
- CI では probe を実行しない。証跡は手元の raw log と、Issue / PR に貼る judge の summary (raw log は
  貼らない。上の「raw log の扱い」)。
