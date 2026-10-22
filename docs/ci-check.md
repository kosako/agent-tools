# CI の workflow の検査 (personal-ci-check)

GitHub Actions の workflow の file を決まった規則で検査し、所見を `personal-repo-audit` と同じ形
(`findings.schema.json`) の JSON で出す script です (#541)。実体は `shared/scripts/personal-ci-check.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-ci-check`。

AI を使いません。何も書きません。`--since` を付けたときだけ、GitHub の API で run の記録も点検します (下の「run の
記録の点検」)。付けなければ GitHub にも network にも触れず、git で手元の commit を読むだけです。git は
`--no-lazy-fetch` と `--no-replace-objects` で起動します。partial clone で取得していない object があっても promisor の
remote から取りに行かず (object database にも書かず)、git の失敗として止まります。`refs/replace/` の replacement ref
(HEAD や blob を別の object に見せる ref) も当てず、HEAD の実体を読みます。

## 運用

- sweep (`personal-maintenance-sweep`) が run ごとに今の repo にかけます。どのプリセットでも、監査の単位の先頭に
  AI を使わない `ci` の単位を足し、この script の出力をその単位の監査の結果として、通常の流れ (反証 → triage → 重複の
  照合 → 起票。proposal は追跡 Issue のコメント) に乗せます (sweep の `SKILL.md` 手順 3)。script が無い・run 全体が
  失敗したときは、sweep を止めずに「CI を確かめられない」と報告します。人が repo で直接かけて出力を読んでもかまいません。
- sweep は、前の run が run の記録を点検し終えた時刻から今までを窓にして `--since` / `--until` を渡します (初回は直近
  30 日で、窓は 30 日まで)。run の記録を確かめられなければ、窓の始まりを中間まで遅らせて 2 回までかけ直します。点検し
  終えた時刻は sweep の手元の記録 (repo ごとの `ci.json`) が持ち、起票まで進んで run の記録の所見を扱い終えたときだけ
  進めます。起票の上限で次の run に回した所見や、反証で uncertain になった所見があれば進めません (sweep の `SKILL.md`
  手順 3 と 8、形と窓の決め方は `RECORD.md`)。
- 所見は Issue にしてよいものとして扱います。`personal-repo-baseline` (#539) が Issue にしないのは守り (alerts・secret
  scanning・branch の保護) の抜けで、timeout や concurrency は資源の使い方の問題だからです。攻撃の手順が分かる所見は、
  sweep の security の扱い (公開しない) に従います。
- 意図した例外 (timeout を付けない job など) は、sweep が起票した Issue を not planned で close して表します。sweep の
  重複の照合は、not planned で close した Issue と同じ fingerprint を却下として扱います。repo ごとの例外の設定 file は
  ありません。

## 使い方

```text
usage: personal-ci-check [--since YYYY-MM-DDTHH:MM:SSZ [--until YYYY-MM-DDTHH:MM:SSZ]] [--help|-h]
```

今の directory の git repo の HEAD の commit にある `.github/workflows/` の直下の `*.yml` / `*.yaml` (GitHub が workflow
として読む場所) を読みます。`--since` を付けると、窓 (since, until] の run の記録も点検します。`--until` は省くと今の
時刻です。時刻は UTC の秒まで (`Z` で終わる形) だけを受け付け、since は until より前にします。`--until` だけ、同じ
option を 2 回、形の違う時刻は usage の誤り (exit 2) です。

- 作業ツリーの未 commit の変更は読みません (sweep が監査する commit と揃えるため)。repo の中の subdirectory から
  起動しても、repo の root の `.github/workflows/` を読みます (git は今の directory で動かし、tree は pathspec を
  使わずに名前の完全一致で辿り、`ls-tree` は `--full-tree` で cwd に絞らせない。repo の root の path は経由しない)。
- `.github/workflows/` の subdirectory (名前によらない。`archive.yml/` も) と、`*.yml` / `*.yaml` でない file は見ません
  (GitHub も workflow として読まない)。
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

## run の記録の点検 (`--since`)

GitHub の API (`gh api`。shell を通さず、env の `GH_REPO` は渡さない。GET だけ) で、窓 (since, until] に**終わった**
attempt の記録を読み、次を所見にします (#541)。窓は「終わった時刻」で切るので、点検の時点でまだ走っている run は
次の窓で見えます。前の窓の終わりちょうどに終わった attempt は二重に数えません。

| topic | 種別 / 深刻度 / 確度 | 当てはまるとき | 所見にするとき |
|---|---|---|---|
| `job-timed-out` | defect / medium / 確証 | job が cancelled で、GitHub の failure の annotation「has exceeded the maximum execution time」が付いている | 1 回でも |
| `flaky-rerun` | defect / low / 有力 | 同じ job (表示名) が、ある attempt で failure、後の attempt で success (通った attempt が窓の中に終わった) | 窓の中で 2 本以上の run。1 本は summary に数えるだけ |
| `deprecation-*` | debt / low / 有力 | default branch への push の run (workflow ごとに、窓の中に終わった直近 5 本) の annotation に、決まった語 (deprecated・will be removed・will migrate・no longer supported・end of life) がある | 1 回でも。同じ種類は 1 件にまとめる |

- **数えるだけのもの**: それ以外の cancelled の job (concurrency による取り消し、runner を確保できない (`not acquired`)
  など) は、summary に回数だけを書きます。1 回目が cancelled でやり直しで通った job も、flaky には数えません
  (runner の容量のことが多く、test の揺れではないため)。待ち時間は見ません。
- **見る run**: repo の workflow の file から走る run だけです (path が `.github/workflows/<規則の形の名前>`)。
  Dependabot などの dynamic な run は見ません。探すのは、作成が [since の 7 日前, until] の run です (API の `created` の
  範囲の指定。窓の前に作られ、窓の中でやり直された run を拾う。それより前の run のやり直しは見逃す。窓の後に作られた
  run は窓の中に終われないので、API の側で除く)。
- **読む量を絞る**: job を読むのは、やり直した run (attempt が 2 以上)、conclusion が cancelled / failure / timed_out
  の run、まだ終わっていない run だけです。まだ終わっていない run も読むのは、窓を job の終わった時刻で切るためです
  (点検の時点で走っている run の中で、窓の中に timeout で止まった job は、今の窓で拾わないと次の窓では since より前に
  なって見えない)。annotation を読むのは、窓の中に終わった cancelled の job と、deprecation を見る run の最後の
  attempt の job だけです。
- **上限**: 1 回の実行で、API の呼び出し 200 回・120 秒までです。上限の時刻を過ぎた gh は、process group ごと止めます。
  gh の本体が終わっても、gh が起動した子が出力の pipe を握っていれば読み終わらないので、pipe の読み終わりと gh の本体の
  終わりの両方を同じ期限で見ます。gh を回収 (wait) するのは pipe を読み終えた後だけです。回収するまで gh の PID と
  process group の id は再利用されないので、期限を過ぎて送る signal の先は必ずこの gh とその group になります (回収済みの
  PID に signal を送らない)。期限を過ぎたら gh の本体と group を止めてから回収し、pipe の EOF (子の終わり) を待たずに、
  読む thread を 1 秒で止めて回収します (別の process group に移った子が pipe を握っていても待ち続けない。その子は
  止められない)。GitHub の run の一覧は、作成で絞ると 1000 本までしか返さないので、それを
  超える窓は読みません。実測 (2026-10): いちばん忙しい repo の 30 日の窓で 127 回・77 秒、2 週間の窓で 79 回。
- **確かめられないとき** (上限、gh の失敗・起動できない、応答の形の違い (key の欠け・型の違い・時刻を解釈できない・
  終わった run や job の conclusion / 終わった時刻の欠け。終わっていないものの null は正当)、一覧の件数が `total_count`
  と合わない・読む間に `total_count` が変わった・id が重なる、今の repo の GitHub の repo や default branch を解決できない):
  点検の所見はすべて捨て、`scope.not_seen` に
  `run の記録 (<since>〜<until>。<理由>)` の行を書いて exit 2 にします。静的な検査の結果はそのまま出します。sweep は
  この行の有無で窓を縮めてかけ直すかを決め、確かめたときの `scope.seen` の行 (下) で窓の時刻を進めるかを決めます
  (接頭辞「run の記録」と、seen の行の形は契約)。
- **出力に載せないもの**: annotation の文面は自由文 (workflow が出す文を含む) なので載せません。決まった型だけを
  決まった文言にします (`Node.js <版> の deprecation の予告` → topic `deprecation-node-<版>`、`runner の label <label> の
  移行の予告` → `deprecation-runner-label-<label>`。捕まえる値は数字と `[a-z0-9.-]` だけ)。それ以外は「deprecation を
  示す語 (<語>) を含む annotation」と、文面を正規化した hash の topic (`deprecation-annotation-<hash>`) にして、文面は
  link 先で読みます。job の表示名は規則の形 (英数字と `_` で始まり、英数字・空白・`_ . ( ) / , : + -` だけ、100 文字
  まで) に合うときだけ載せ、外れれば hash で表します (topic の slug も hash)。link は repo と run・job の id から組み
  立てます (`https://github.com/<repo>/actions/runs/<run>/job/<job>`)。
- **fingerprint**: `<path>@<job の slug>#job-timed-out`、`<path>@<job の slug>#flaky-rerun`、`<path>#deprecation-<種類>`。
  job の slug は表示名を小文字にし、英数字以外の並びを `-` にして、**必ず**元の名前の SHA-256 の先頭 6 文字を添えた
  もの (例 `self-tests (3.4)` → `self-tests-3-4-9c6e41`、`check` → `check-<hash>`)。変換は情報を落とす (`test (a.b)` と
  `test (a-b)`) ので、hash を添える名前と添えない名前を混ぜると、ある名前の slug が別の名前そのものとぶつかるためです。
  規則の外の名前と、変換で空になる名前は `job-<hash 8 文字>` です。runner の label の key も同じ作り
  (`deprecation-runner-label-ubuntu-latest-<hash>`。`ubuntu-24.04` と `ubuntu-24-04` はぶつからない)。
- summary に、窓の中に終わった run の本数、各事象の回数、API の呼び出しの回数を書きます。run の記録を確かめたときだけ、
  `scope.seen` に `run の記録 (<since>〜<until>)` の行を足します (時刻は渡した `--since` / `--until` と同じ形)。

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
| 2 | usage、repo を選ぶ git の環境変数を継承している、今の directory の repo や HEAD を解決できない、git の失敗 (取得していない object を含む)、確かめられない file がある、run の記録を確かめられない (`--since` のとき)、想定外の例外 |

- **確かめられない file**: YAML として読めない (stream のどこかの構文の誤りを含む)、文書が 1 つでない、入れ子が
  64 段より深い、明示の tag (`!!omap`・`!!str`・`!ruby/...` など) がある、key が書かれたとおりに読めない (同じ key を
  2 度書く、YAML の解決で衝突する (`on` と `true` など)、merge key `<<`、scalar でない key)、workflow の形でない (top level・`jobs`・各 job が mapping でない、job の名前が規則の外、`on` が
  無い、`on` として読める key が 2 つある (引用した `"on"` と plain の `yes` など)、`on` の event が文字列でない)、通常の
  file でない (symlink・submodule)、1 MiB を超える、名前が規則の外 (名前は出さず件数だけ)、その file の検査の中の
  想定外の失敗 (理由は例外の class 名だけ)。`.github` や `.github/workflows` が directory でないときも同じです。確かめられない file があっても、残りの file は確かめて出し
  (`scope.not_seen` に理由)、exit 2 にします (ずれ無しに倒さない)。
- **run 全体の失敗** (usage、環境変数、repo や HEAD を解決できない、git の失敗、想定外の例外): stdout に何も出さず、
  stderr に 1 行出します。想定外の例外 (StandardError の外の `SystemStackError` を含む) も exit 2 にし、Ruby の
  既定の exit 1 (所見あり と同じ値) にしません。

## YAML の読み方

読む順は次のとおりです。処理量の大きい段 (AST を作る・値に変換する) の前に、その段を重くする形を止めます。

1. **入れ子の深さ** (AST を作る前): parse の event を数える parser (`Psych::Parser` と handler) で collection の
   入れ子の深さを数え、64 段を超えた時点で打ち切ります。libyaml の parse は入れ子の深さに対して二乗の時間がかかり
   (10 万段で約 18 秒、1 MiB の上限いっぱいなら数分)、`safe_load` と下の key の検査は再帰する (深い入れ子は
   `SystemStackError`) ためです。workflow は 10 段ほどです。
2. **stream 全体** (`Psych.parse_stream`): `YAML.safe_load` は先頭の文書しか読まないので、後ろの文書の構文の誤りや
   2 つ目の文書を見落とします。stream 全体を AST にして、文書が 1 つであることを求めます。
3. **AST の形** (`safe_load` の前。反復で辿る):
   - 明示の tag が無いこと。tag は値の型や構造を変える (`!!omap` の sequence は mapping に読まれ、重なった key が後の
     値で上書きされる) ので、どこにあっても読みません。psych の版で `safe_load` の失敗の仕方が違っても、同じ理由で
     止まります。
   - mapping の key が scalar で、merge key (`<<`) でないこと。alias や collection の key は、値に変換して Hash に入れる
     ときに hash を計算します。alias で共有した配列を重ねると、浅く小さい file のままその計算が指数的に増えます。merge
     key は、GitHub が受け付けるかを docs で確かめられず、load 後の key の並びも書かれた順と揃いません。
4. **値** (`YAML.safe_load`。psych 3 / 4 の両方): anchor と alias は GitHub が workflow で受け付けるので許し、値の型は
   日付の literal (Date / Time) まで許します。
5. **key の対応** (load の後): AST と load した値を並べて辿り、どの mapping でも書かれた key と load 後の key が 1 対 1
   であることを確かめます (`scripts/lib/yaml_util.rb` と同じ考え方。配布する script は単体の file なので写している)。
   同じ key を 2 度書くと `safe_load` は後の値で黙って上書きし (`on: pull_request` の後の `on: push` で pull_request が
   消える)、plain の key は YAML の解決で衝突するので、そのままでは GitHub と違う値を見うるためです。load 後の値の
   並びは mapping ごとに 1 度だけ作ります (key の数の二乗にしない)。

ほかに:

- YAML 1.1 の規則で、引用しない key の `on` は `true` に読まれます。`on` と `true` の両方を `on` として見ます。
- 行番号は、同じ AST の `jobs` の key の行です。

## 限界

- 読むのは HEAD の commit だけです。default branch の最新と違う commit を checkout していれば、その commit の workflow を
  見ます (sweep は default branch の clean な checkout を前提にしている)。
- 規則は key の有無だけを見ます。`timeout-minutes` の値の大きさ、`concurrency` の group が何を同じ run とみなすかは
  確かめません。
- run の記録の点検は、実行時間や待ち時間の傾向を比べません (#541 で保留)。deprecation の判定は語の一致なので、移行の
  予告のように対応の要らないものも拾います (反証と triage で落とす)。flaky は「失敗の後のやり直しで通った」という
  観測で、原因は断定しません。
- 窓の時刻 (前回どこまで見たか) は script が持ちません。sweep が手元の記録に持ち、`--since` / `--until` で渡します。
- sweep は、確定しなかった所見 (反証で uncertain、起票の上限で次に回したもの) を次の run に持ち越さず、窓の時刻を
  据え置いて再検出に任せます (持ち越すかは #425 で決める)。timeout とやり直しの所見は窓の中の事象なので、据え置いた窓で
  再検出されます (30 日の上限で切った分は、見ない期間として報告)。deprecation は workflow ごとの直近 5 本の run だけを
  見るので、警告がその 5 本から消えると次の run では出ず、追わなくなります (予告の対象が残っていれば、その job が次に
  走ったときに再検出される)。
