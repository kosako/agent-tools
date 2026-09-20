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
- Codex adapter は **Codex CLI 0.153.4 で未検証** (project scope `.agents/skills` の読み込み、
  user scope の skill の排除、event の形)。`--smoke` で「見えている skill の一覧」と event 形式を
  確認してから使う。確認結果はこの doc に追記する。

## 隔離 (実 home に触らない)

probe は一時 directory に project を作り、候補 skill を **project scope** に copy して実行する。

| tool | 候補 skill の置き場 | user scope の排除 | 確認した版 |
| --- | --- | --- | --- |
| claude-code | `<proj>/.claude/skills/<name>/` | `--setting-sources project` (user / local の settings と skill を読まない) | 2.1.277 (2026-09-20 smoke): `~/.claude/skills` の `personal-*` と plugin skill は listing から消え、project skill と bundled skill (dataviz / code-review 等) だけが残る。bundled は両 variant に等しく載る |
| codex | `<proj>/.agents/skills/<name>/` (公式 docs の repository-level path) | 未確認 (`~/.codex/skills` の skill が同名で並ぶ可能性がある) | 未確認 |

claude-code の観測に使う event (2.1.277 で実測): `system` / `init` の `model` と `skills` (listing)、
`assistant` の `tool_use` (`name: "Skill"`, `input.skill: "<name>"`)、`result` の `usage`
(`input_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` / `output_tokens`)。

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
  codex は event 本文に現れた project scope の `SKILL.md` path から取る。listing に載っているだけの
  skill は含めない。
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
  (judge は runner の観測を信頼する。信頼境界は judge の冒頭コメント参照)。

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
  exit 2)。候補で primary hit が減る、または violation が増えたら回帰 (exit 1)。
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
受け入れ条件)。`--repeat N` で揺れを均せる (baseline と candidate で同じ N にする)。

## case set の育て方

- 1 case = 1 依頼 prompt。`primary` は依頼の主目的を所有する skill (無ければ `null`)、`must_not` は
  発火してはいけない隣接 skill。secondary (gate / quality / placement の補助) は列挙しない。
- 新しい skill を足したら `inventory` と、その skill が primary になる case と near-miss の負例を
  足す。self-test が「production-rail 以外の全 inventory skill に primary case がある」ことを検査する。
- prompt は `-` で始めない (CLI の option と衝突する)。制御文字は入力エラー。

## 検証境界

- headless 単発 turn の観測であり、対話 session (履歴・CLAUDE.md / AGENTS.md の指示・ユーザーの
  訂正) を含まない。user scope の instruction が skill 名に触れる環境では、その影響は before /
  after の両方に等しく乗る。
- model を固定しても揺れはある。`--repeat` と「同条件比較」で扱い、絶対値を保証にしない。
- Codex adapter の観測契約は未検証 (上記)。検証したら「確認した版」を埋める。
- CI では probe を実行しない。証跡は raw log と、Issue / PR に貼る judge の summary。
