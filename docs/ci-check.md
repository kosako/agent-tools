# CI の workflow の検査 (personal-ci-check)

GitHub Actions の workflow の file を決まった規則で検査し、所見を `personal-repo-audit` と同じ形
(`findings.schema.json`) の JSON で出す script です (#541)。実体は `shared/scripts/personal-ci-check.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-ci-check`。

AI を使いません。GitHub にも network にも触れず (git で手元の commit を読むだけ)、何も書きません。git は
`--no-lazy-fetch` で起動するので、partial clone で取得していない object があっても promisor の remote から取りに
行かず (object database にも書かず)、git の失敗として止まります。

## 運用

- sweep (`personal-maintenance-sweep`) が run ごとに今の repo にかけ、所見を通常の流れ (反証 → triage → 重複の照合 →
  起票) に乗せる予定です (#541 の 2 番目の PR でつなぐ)。それまでは人が repo で直接かけて、出力を読みます。
- 所見は Issue にしてよいものとして扱います。`personal-repo-baseline` (#539) が Issue にしないのは守り (alerts・secret
  scanning・branch の保護) の抜けで、timeout や concurrency は資源の使い方の問題だからです。攻撃の手順が分かる所見は、
  sweep の security の扱い (公開しない) に従います。
- 意図した例外 (timeout を付けない job など) は、sweep が起票した Issue を not planned で close して表します。sweep の
  重複の照合は、not planned で close した Issue と同じ fingerprint を却下として扱います。repo ごとの例外の設定 file は
  ありません。

## 使い方

```text
usage: personal-ci-check [--help|-h]
```

引数は取りません。今の directory の git repo の HEAD の commit にある `.github/workflows/` の直下の `*.yml` /
`*.yaml` (GitHub が workflow として読む場所) を読みます。

- 作業ツリーの未 commit の変更は読みません (sweep が監査する commit と揃えるため)。repo の中の subdirectory から
  起動しても、repo の root の `.github/workflows/` を読みます (git は今の directory で動かし、tree は pathspec を
  使わずに名前の完全一致で辿り、`ls-tree` は `--full-tree` で cwd に絞らせない。repo の root の path は経由しない)。
- `.github/workflows/` の subdirectory と、`*.yml` / `*.yaml` でない file は見ません (GitHub も workflow として読まない)。
- repo を選ぶ git の環境変数 (`GIT_DIR`・`GIT_WORK_TREE`・`GIT_INDEX_FILE`・`GIT_COMMON_DIR`・`GIT_OBJECT_DIRECTORY`・
  `GIT_ALTERNATE_OBJECT_DIRECTORIES`・`GIT_NAMESPACE`) を 1 つでも継承していれば (値が空でも)、別の repo を読みうるので
  止めます (`personal-packet` と同じ集合)。

## 規則

| topic | 種別 / 深刻度 | 当てはまるとき | 当てはまらないとき |
|---|---|---|---|
| `timeout-missing` | debt / medium | job に `timeout-minutes` が無い (値が空のときも無いとみなす) | 値がある (式 `${{ … }}` を含む)。reusable workflow を呼ぶ job (`uses:`) |
| `concurrency-missing` | proposal / low (判断が要る) | `on` に `pull_request` があり、workflow の top level にも、すべての job にも `concurrency` が無い | top level にある、またはすべての job にある。`pull_request` で起動しない |

- **timeout-missing**: GitHub の job の timeout の既定は 360 分なので、止まらなくなった job が 6 時間 runner を使い続け
  ます。reusable workflow を呼ぶ job には `timeout-minutes` を書けない (書ける keyword は `name`・`uses`・`with`・
  `secrets`・`strategy`・`needs`・`if`・`concurrency`・`permissions` など。GitHub の docs の reusable workflow の節) ので
  所見にせず、`not_problems` に出します。呼ばれる側の workflow が同じ repo にあれば、その file の job で見ます。repo の
  外にあれば、この検査では見ません。
- **concurrency-missing**: 同じ PR に続けて push すると、古い commit の run も最後まで走り、runner の枠を使って新しい
  run を待たせます。取り消してよいかは workflow による (検証だけの CI は取り消してよいが、release や deploy は途中で
  止めると困る) ので、判断が要るものとして `decisions` にも出します。`pull_request_target` は見ません。
- v1 では見ないもの: `schedule` の頻度 (今は使う workflow が無い)、`timeout-minutes` の上限、`cancel-in-progress` の
  値、concurrency の group の中身。

## 出力と exit

stdout に `findings.schema.json` に適合する JSON を 1 つ出します。

- `findings[]`: 所見。`id` は深刻度順 (同じ深刻度なら fingerprint 順) に `F01`, `F02`, … と振ります。`dimension` は
  `ci`、`confidence` は `確証` (決まった規則で file から確かめたもの)。
- `fingerprint`: `timeout-missing` は `<path>@<job>#timeout-missing` (例 `.github/workflows/test.yml@self-tests#timeout-missing`)、
  `concurrency-missing` は `<path>#concurrency-missing`。job ごとに分けるので、1 つの job だけを not planned で close
  できます。
- `locations[]`: `timeout-missing` は job の key の行 (`<path>:<line>`)、`concurrency-missing` は file (`<path>`)。
- `not_problems[]`: reusable workflow を呼ぶ job。
- `decisions[]`: 判断が要る所見 (`concurrency-missing`) ごとに 1 つ。
- `scope`: `seen` は確かめた file、`not_seen` は確かめられない file と理由。`partial` は空、`uncommitted` は `なし`
  (未 commit の変更を読まないため)、`prescan` は未実施。

出力に載せるのは、規則の形に合う file の名前 (英数字で始まり、英数字と `.` `_` `-` だけ) と job の名前 (GitHub の
規則: 文字か `_` で始まり、英数字と `-` と `_` だけ)、決まった文言だけです。`uses:` の値など、repo の中の他の文字列は
出しません (所見は public な Issue の材料になるため)。

| exit | 意味 |
|---|---|
| 0 | 所見なし (workflow の file が無いときを含む) |
| 1 | 所見あり (proposal を含む) |
| 2 | usage、repo を選ぶ git の環境変数を継承している、今の directory の repo や HEAD を解決できない、git の失敗 (取得していない object を含む)、確かめられない file がある、想定外の例外 |

- **確かめられない file**: YAML として読めない (stream のどこかの構文の誤りを含む)、文書が 1 つでない、key が
  書かれたとおりに読めない (同じ key を 2 度書く、YAML の解決で衝突する (`on` と `true` など)、merge key `<<`、
  scalar でない key)、workflow の形でない (top level・`jobs`・各 job が mapping でない、job の名前が規則の外、`on` が
  無い、`on` として読める key が 2 つある (引用した `"on"` と plain の `yes` など)、`on` の event が文字列でない)、通常の
  file でない (symlink・submodule)、1 MiB を超える、名前が規則の外 (名前は出さず件数だけ)。`.github` や
  `.github/workflows` が directory でないときも同じです。確かめられない file があっても、残りの file は確かめて出し
  (`scope.not_seen` に理由)、exit 2 にします (ずれ無しに倒さない)。
- **run 全体の失敗** (usage、環境変数、repo や HEAD を解決できない、git の失敗、想定外の例外): stdout に何も出さず、
  stderr に 1 行出します。想定外の例外も exit 2 にし、Ruby の既定の exit 1 (所見あり と同じ値) にしません。

## YAML の読み方

- 先に `Psych.parse_stream` で stream 全体を parse し (`YAML.safe_load` は先頭の文書しか読まないので、後ろの文書の
  構文の誤りや 2 つ目の文書を見落とす)、文書が 1 つであることを求めます。
- 値は `YAML.safe_load` で読みます (psych 3 / 4 の両方)。anchor と alias は GitHub が workflow で受け付けるので許し、
  値の型は日付の literal (Date / Time) まで許します。
- AST と load した値を並べて辿り、どの mapping でも書かれた key と load 後の key が 1 対 1 であることを確かめます
  (`scripts/lib/yaml_util.rb` と同じ考え方。配布する script は単体の file なので写している)。同じ key を 2 度書くと
  `safe_load` は後の値で黙って上書きし (`on: pull_request` の後の `on: push` で pull_request が消える)、plain の key は
  YAML の解決で衝突するので、そのままでは GitHub と違う値を見うるためです。merge key (`<<`) は、GitHub が受け付けるか
  を docs で確かめられず、load 後の key の並びも書かれた順と揃わないので読みません。
- YAML 1.1 の規則で、引用しない key の `on` は `true` に読まれます。`on` と `true` の両方を `on` として見ます。
- 行番号は、同じ AST の `jobs` の key の行です。

## 限界

- 読むのは HEAD の commit だけです。default branch の最新と違う commit を checkout していれば、その commit の workflow を
  見ます (sweep は default branch の clean な checkout を前提にしている)。
- 規則は key の有無だけを見ます。`timeout-minutes` の値の大きさ、`concurrency` の group が何を同じ run とみなすかは
  確かめません。
- run の記録 (timeout に当たった job・deprecation・やり直しで通った run) の点検は、#541 の 3 番目の PR で足します。
