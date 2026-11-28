# private の repo の CI を手元で走らせる (personal-ci-runner)

個人 project の private の repo では、GitHub の runner の Actions に費用がかかります。`personal-ci-runner` は、その CI を手元の
machine の self-hosted runner で走らせる本体です (#803)。1 job ごとに GitHub の just-in-time (JIT) の runner を作り、新しい
container で動かし、終わったら登録を消します。実体は `shared/scripts/personal-ci-runner.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-ci-runner` です。

置き場所は、hook と同じく分けています。本体は agent-tools、runner 専用の colima の profile と login のときの自動起動は dotfiles
(dotfiles#656)、各 repo の workflow の `runs-on` はその repo です。public の repo には使いません (公開に切り替えたら GitHub の
runner に戻す)。

## 強度ラベル (偽らない)

手順の守りであって、境界ではありません。守るのは次のことです。

- public の repo には runner を登録しない。起動のたびに API で private を確かめ、private と確かめられなければ起動しない。
- 人が設定に書いた repo だけを扱う。
- container に、host の mount・docker の socket・gh の token を渡さない。CPU・memory・process の数に上限を付ける。
- JIT の設定を、host の argv・env・log・state・`docker inspect`・`docker top` に残さない。

## 使い方

```text
personal-ci-runner check | once <owner/repo> | cleanup
```

- `check`: 設定を検査し、repo ごとに公開範囲 (`private` / `public` / `unknown`) を 1 行ずつ出します。runner は作りません。
- `once <owner/repo>`: 1 job の runner を 1 つ動かし、container が終わるまで待ちます。終わったら登録を消します。
- `cleanup`: state に記録した runner のうち、container が動いていないものの登録を消します (前の起動が途中で止まったときの
  後片付け)。

| exit | 意味 |
| --- | --- |
| 0 | 成功 (`once` は container が終わり後片付けもできた。job の成否は GitHub の側の結果) |
| 1 | private でない・判定できない・起動や後片付けの失敗 (`cleanup` は消せない記録が残った) |
| 2 | 使い方・設定の誤り、`GH_REPO` か `GH_HOST` が立っている |
| 3 | 同じ repo の `once` が動いている (repo ごとの lock を取れない) |

常駐の loop (repo ごとに待機の runner を保つ) は、次の PR で足します。それまでは、`once` を人が shell の loop で回して使えます。

## 設定 (`~/.config/agent-tools/ci-runner.json`)

人が手で書く file です。agent は読むだけで、repo ごとに人が認めた記録を兼ねます。

```json
{
  "docker_context": "colima-ci",
  "image": "ghcr.io/actions/actions-runner@sha256:<64 桁>",
  "cpus": 2,
  "memory_mb": 4096,
  "pids": 1024,
  "repos": ["kosako/prism"]
}
```

- key は上の 6 つだけで、全部が要ります。知らない key、JSON の key の重なりは誤りです。
- `docker_context` は `[A-Za-z0-9][A-Za-z0-9._-]{0,62}`。`image` は `ghcr.io/actions/actions-runner@sha256:<64 桁の小文字の hex>` の形
  だけを受けます (tag は受けない)。
- `cpus` は 1〜16、`memory_mb` は 512〜65536、`pids` は 64〜65536 の整数です (境界を含む。bool・小数・文字列は受けない)。
- `repos` は 1〜20 個の `owner/name` で、大文字小文字を除いて重ねません。
- file は、symlink でない regular file で、自分の持ち物で、group と other が書けないこと。親の directory も、group と other が
  書けないこと。64 KiB まで。「無い」と扱うのは `lstat` の `ENOENT` だけで、無いときは exit 2 です。
- 場所は env の `AGENT_TOOLS_CI_RUNNER_CONFIG` (絶対 path) で替えられます (test 用)。

## once の段

1. repo が設定の `repos` にあることを確かめます (大文字小文字を除いて比べ、以降は設定の綴りを使う)。無ければ exit 2。
2. repo ごとの lock を取ります。取れなければ exit 3。lock の file を用意できなければ exit 1。
3. API で private を確かめます。`private` が `true`、`visibility` が `"private"`、`full_name` が設定の名前と大文字小文字を除いて
   一致する、の 3 つがそろったときだけ private です。ほかは `unknown` で (rename や redirect で名前が違うときを含む)、何も作らずに
   exit 1。gh の error の本文は出しません。
4. runner の名前 (`agent-tools-ci-<16 桁の hex>`) を決め、記録 (repo・名前・container の名前・作った時刻) を state に書きます。記録を
   書くのはこの 1 回だけで、以後は書き換えません。書けなければ、API を呼ばずに exit 1。
5. JIT の runner を作ります (`POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`。group は 1、label は `self-hosted`・
   `linux`・`arm64`)。返事からは JIT の設定だけを使い、runner の id は使いません (runner の同一性は名前だけで決める)。
6. もう一度 private を確かめます。そうでなければ、container を起動せずに後片付けをして exit 1。JIT の設定が無い (作成の失敗、gh を
   止めた)、base64 の 1 行 (64 KiB まで) でないときも同じです。
7. container を起動します。

   ```text
   docker --context <docker_context> run --rm -i --name <名前> --label agent-tools.ci-runner=<owner/repo>
     --cpus <cpus> --memory <memory_mb>m --memory-swap <memory_mb>m --pids-limit <pids>
     --security-opt no-new-privileges --cap-drop ALL <image> sh -c '<中の shell>'
   ```

   中の shell は、stdin の 1 行を `ACTIONS_RUNNER_INPUT_JITCONFIG` に入れて、`run.sh` を引数なしで起動します (runner は値を読んだ
   後で、自分の env から消す)。JIT の設定は container の stdin で渡すので、host の docker の argv と env に載りません。container の
   stdout と stderr は捨てます (job の log は GitHub の側で見る)。
8. container が動いている間、40 秒ごとに private を確かめます (その gh の期限は 20 秒。env の `AGENT_TOOLS_CI_RUNNER_POLL_SECONDS` で
   1〜40 秒に縮められ、範囲の外の値は 40 秒)。公開範囲の変化を検知するまで、最大 60 秒です。private と確かめられなくなったとき
   (public か判定できない)、signal を受けたとき、docker の client だけが終わったとき (container を見張れなくなる) は、
   規則 2 で止めます。
9. 終わったら、規則 1 で後片付けをします。後片付けが済まなければ、記録を残して exit 1 にし、後で `cleanup` が続きをします。

### 規則 1: 記録を外してよいとき

登録を消すときは、一覧を名前で引き、見つかった runner を DELETE します。DELETE が 404 なら、名前で一覧を引き直し、無いと確かめ
られたときだけ消せたとみなします。記録を外すのは、次のどちらかのときだけです。`once` と `cleanup` は同じ関数を使います。

- 名前で見つかり、消せた。
- 名前で見つからず、次のどちらかが成り立つ。この process が起動した container が、終わったと確かめられた (JIT の作成は
  成功していて、job を終えた JIT の runner は GitHub の側で消える)。または、記録を作ってから 10 分たっている (作成の途中で止めた
  POST が後から効く場合に備えて、それまでは残す)。

それ以外では記録を残します。一覧の失敗、DELETE の失敗や期限切れ、container が動いているかもしれないとき、想定外の例外の後が
当たります。container が動いているかもしれないのは、止まったと確かめられないまま、止めるのをあきらめたときです。記録を
消せなかったときも、登録は消したまま記録が残ります (`cleanup` が後で消す)。

### 規則 2: 止めるときの時間

検知 (signal を受けた、private と確かめられない、docker の client だけが終わった) の時点で、期限を「検知 + 60 秒」に決めます。

- 登録を消す (別の thread) のと、container を止めるのを、同時に始めます。止めるのは `docker stop` (失敗したら `docker kill`) で、
  container が終わるまで 5 秒ごとに繰り返します。
- 後の gh と docker の全部の呼び出しに、期限までの残りを渡します (`docker stop --time` もその内に収める)。
- 期限の 5 秒前になっても container が終わらなければ、docker の client を止め (TERM、残りで KILL)、container の名前を出して
  「手で止めてください」と知らせます。
- docker の client が終わったら (動いている間でも、止めている途中でも)、終わり方によらず、`docker ps` で container が動いて
  いないことを確かめます。signal で終わった、daemon との接続が切れた、のように client だけが終わり、container が残ることが
  あるためです (接続が切れたときの exit code は、起動の失敗と見分けられない)。動いている、または問い合わせられないときは、
  名前で `docker stop` (失敗したら `docker kill`) を 5 秒ごとに繰り返し、`docker ps` で止まったと確かめます。期限の 5 秒前
  までに確かめられなければ、同じく名前を出して知らせます。
- 期限までに終わらなかった登録の削除は、その gh を止めて終わらせます。期限の後は、残った子を止める猶予 (1 秒ほど) だけ待つ
  ので、`once` は検知から約 60 秒で戻ります。
- JIT を作る前と作る段の gh (private の確かめと JIT の作成) は、signal を受けた時点で止めます。JIT を作る前の signal なら、
  runner を作りません。job の途中なら、その job は取り消しになります。
- 想定外の例外の受け口でも、container が動いていれば同じ形で止め、規則 1 で後片付けをします。

gh と docker の子 process は、検知が無いときも 60 秒の期限で待ちます (`docker stop` は 30 秒)。期限を過ぎたら子を止め (TERM →
5 秒 → KILL。検知の後は、この 5 秒も期限までの残りで切り、下限は 1 秒)、失敗として扱います。`once` の終わりには、残った子を
止めます (TERM → 1 秒 → KILL)。子が終わった後も出力が閉じないとき (孫の process が pipe を持ち続ける) は、2 秒で読み切りを
やめ、失敗として扱います。

## state

`${XDG_STATE_HOME:-~/.local/state}/agent-tools/ci-runner/` (env の `AGENT_TOOLS_CI_RUNNER_STATE_DIR` で替えられる) に、runner ごとに
1 つの記録 (`<名前>.json`: repo・名前・container の名前・作った時刻の 4 つだけ) と、repo ごとの lock の file を置きます。dir は
0700 で、自分の持ち物で、group と other が使えないことを確かめます。記録は一時 file に書いて rename で置きます (0600)。JIT の設定と
token は書きません。4 つの key のほかを持つ記録は、読めない記録として扱います (消さずに知らせる)。

`cleanup` は、記録の repo の lock を取れたものだけを見ます (`once` の途中の記録を消さない)。動いている container (名前と label で
探す。docker に問い合わせられなければ、動いているとみなす) の記録は残します。ほかの記録は、規則 1 の関数に渡します。container の
終わりは確かめていないので、名前で見つからない記録は、作ってから 10 分たつまで残します。設定の `repos` から外した repo の記録も
扱います (公開に切り替える手順で、外した後に片付けるため)。

## 限界

- private の確かめと runner の作成・起動の間、動いている間の確かめの間 (検知まで最大 60 秒) には時差があります。repo を公開に切り替える
  前に、設定の `repos` から外し、動いている `once` を止めてください (下の「公開に切り替えるとき」)。
- 動いている間の確かめで判定できない (GitHub の API の一時的な失敗など) ときも、container を止めます。その job は取り消しになります。
- `docker stop` も `docker kill` も 60 秒のうちに効かないときは、container が残りえます (名前を出して知らせる)。
- 同じ container の job は、runner の process の初めの env (`/proc/<pid>/environ`) から JIT の設定を読みえます。その 1 job の
  runner の資格に限られます。host の gh の token は container に渡しません。
- `no-new-privileges` と `--cap-drop ALL` のため、job の中で `sudo` は使えません。apt などが要る repo は、道具を入れた image を別に
  用意します (今は公式の image だけを受ける)。
- GitHub の runner は x64 の Ubuntu で、手元は arm64 の Linux です。x64 にしか無い道具は、repo の workflow の側で代わりを用意します。
- container は、GitHub への通信のために外へ出られます。2026-11-28 の実機の smoke (colima の default の profile) では、container から
  lima の host の gateway (`host.lima.internal`) を通して、host の loopback で待ち受ける service (4318 番の otel-lgtm) に届きました
  (HTTP 404 が返った)。docker の bridge の gateway (`172.17.0.1:4318`) には届きませんでした。CI の job から host の loopback の
  service に届かないよう、runner 専用の colima の profile (dotfiles#656) の側で、container から host の gateway への通信を塞ぎます。
  塞ぐまでは、この限界があります。
- `docker_context` の名前から、接続先が専用の VM であることまでは確かめられません。
- `cleanup` は、今の設定の `docker_context` で container を探します (記録には context を書かない)。`docker_context` を変える前に、
  動いている `once` を止め、`cleanup` で記録を無くしてください。
- 一覧を引けない間 (権限が無い、repo を消した・名前を変えた) は、記録が残り、`cleanup` は exit 1 を返し続けます。repo がもう
  無いときは、state の記録の file を手で消します。
- machine が眠っている間は CI が進まず、merge も待ちになります。

## 公開に切り替えるとき

1. 設定の `repos` から、その repo を外します。
2. 動いている `once` を止め (INT か TERM)、`personal-ci-runner cleanup` で残った登録を消します。`cleanup` は、名前で見つからない
   記録を作ってから 10 分は残し、exit 0 のまま「残します」と出します。state の記録が無くなるまで、時間をおいて繰り返します。
3. repo の settings の runner の一覧に、`agent-tools-ci-` で始まる runner が残っていないことを確かめます。
4. repo を公開に切り替え、workflow が GitHub の runner を選ぶこと (`runs-on` の式) と、CI が通ることを確かめます。

## 検証

`scripts/tests/ci-runner-test.sh` が、偽の `gh` と `docker` で確かめます。偽の gh と docker は、呼び出しごとに結果を指定できます。

- POST: 成功、500 で作られない、500 だが作られる、作ってから返らない、止められた後で作られる、404
- 一覧: 成功、失敗、返らない、遅い、孫の process が出力を持ち続ける
- DELETE: 成功、404 で消えている、404 なのに残っている、失敗、1 回だけ失敗、1 回だけ返らない、遅い
- gh の process: TERM で止まる、TERM を無視する (KILL でだけ止まる)
- docker run: すぐ終わる、125、長く動く
- docker stop・kill: 成功、何度か失敗してから成功、返らない
- docker run の client: 動いている間に KILL される、止めている途中で KILL される、signal でなく終わって container が残る
- docker ps: 成功、失敗
- 動いている間の確かめ: private、public、失敗、形の違う返事、返らない
- 作った直後の確かめ: public、途中で TERM
- 記録と lock: 記録を書けない、記録を消せない、lock の file を用意できない

「組の表」の case (M01〜M25 と T3〜T13) では、どの case の後にも同じ検査をかけます。遅れて効く偽の子が終わるのを待ってから、次を
見ます。

- 偽の GitHub に `agent-tools-ci-` の runner が残っていれば、その名前の記録も残っている。
- 動いているように見える偽の container が残っていれば、その名前の記録も残っている。
- 偽の gh と docker の process が残っていない。
- TERM を送った case では、`once` が期限のうちに戻った。
- 全部の呼び出しを成功にし、残った container を人が止めたことにし、記録を 10 分より前に作ったことにして `cleanup` を流すと、
  runner も記録も残らない。

T3〜T8・T10・T12・T13 は、期限を 10 秒・あきらめを 4 秒にした `once` を、返らない偽の gh と docker で流します (helper は差し替え
ない)。T1 は短い上限で、container を待つ helper を直接呼びます。想定外の例外 (T2) は helper の差し替えで起こし、T9 はその後の
出力も失敗させて、出力より先に container を止めることを見ます。T11 は、止める段の例外と返らない DELETE を重ね、`once` の
終わりに gh の process が残らないことを見ます。

ほかに、設定の検査 (形・範囲・境界・key の重なり・symlink・権限・大きさ)、公開範囲の判定、JIT の設定が stdin の 1 行で届き、
出力・docker の引数・state に出ないこと、docker の引数 (付ける option と付けない option)、記録の形、同じ repo の lock、`cleanup` の
個別の場合 (動いている container、docker に問い合わせられない、ほかの名前の runner、同じ名前の 2 つ、0 の id、若い記録と古い記録、
壊れた記録) を見ます。

実機の smoke は、合格の条件を先に #803 に書き、人が 1 回流します。
