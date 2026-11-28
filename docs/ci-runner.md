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
2. repo ごとの lock を取ります。取れなければ exit 3。
3. API で private を確かめます。`private` が `true`、`visibility` が `"private"`、`full_name` が設定の名前と大文字小文字を除いて
   一致する、の 3 つがそろったときだけ private です。ほかは `unknown` で (rename や redirect で名前が違うときを含む)、何も作らずに
   exit 1。gh の error の本文は出しません。
4. runner の名前 (`agent-tools-ci-<16 桁の hex>`) を先に決め、「作りかけ」の記録 (repo・名前・container の名前) を state に書きます。
   書けなければ、API を呼ばずに exit 1。
5. JIT の runner を作ります (`POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`。group は 1、label は `self-hosted`・
   `linux`・`arm64`)。返ってきた id を記録に足します。
6. もう一度 private を確かめます。そうでなければ、登録を消して exit 1。JIT の設定が base64 の 1 行 (64 KiB まで) でないとき、返事に
   id か設定が無いときも、container を起動せずに登録を消します。
7. container を起動します。

   ```text
   docker --context <docker_context> run --rm -i --name <名前> --label agent-tools.ci-runner=<owner/repo>
     --cpus <cpus> --memory <memory_mb>m --memory-swap <memory_mb>m --pids-limit <pids>
     --security-opt no-new-privileges --cap-drop ALL <image> sh -c '<中の shell>'
   ```

   中の shell は、stdin の 1 行を `ACTIONS_RUNNER_INPUT_JITCONFIG` に入れて、`run.sh` を引数なしで起動します (runner は値を読んだ
   後で、自分の env から消す)。JIT の設定は container の stdin で渡すので、host の docker の argv と env に載りません。container の
   stdout と stderr は捨てます (job の log は GitHub の側で見る)。
8. container が動いている間、60 秒ごとに private を確かめます (env の `AGENT_TOOLS_CI_RUNNER_POLL_SECONDS` で 1〜60 秒に縮められる。
   範囲の外の値は 60 秒)。private と確かめられなくなったら (public か判定できない)、先に runner の登録を消して新しい job を
   取らせないようにし、container を止めます。止めるのは `docker stop` (失敗したら `docker kill`) で、container が終わるまで 5 秒ごとに
   繰り返します。60 秒たっても終わらなければ、docker の client を止め、container の名前を出して「手で止めてください」と知らせ、
   exit 1 にします。
9. 終わったら、登録が残っていれば消し (API の runner の名前が記録と一致するときだけ)、消せたら (もう無ければ) 記録を外します。
   消せなければ記録を残して exit 1 にし、後で `cleanup` が消します。

INT・TERM・HUP は、どの段で受けても、container を止めて登録を消します (止め方は 8 と同じ)。JIT を作る前なら作りません。job の途中
なら、その job は取り消しになります。

gh と docker の子 process は、60 秒の期限で待ちます (`docker stop` は 30 秒)。期限を過ぎたら子を止め (TERM → 5 秒 → KILL)、失敗として
扱います。JIT を作る前と作る段の gh (private の確かめと JIT の作成) は、signal を受けた時点でも止めて、後片付けに進みます。作成の
途中で止めた runner は、名前で探して消します。後片付けの gh (登録の確かめと削除) は、signal では止めません。記録を書いた後の段で
想定外の例外が起きたときも、登録を消す後片付けに進みます。

## state

`${XDG_STATE_HOME:-~/.local/state}/agent-tools/ci-runner/` (env の `AGENT_TOOLS_CI_RUNNER_STATE_DIR` で替えられる) に、runner ごとに
1 つの記録 (`<名前>.json`: repo・名前・container・id) と、repo ごとの lock の file を置きます。dir は 0700 で、自分の持ち物で、
group と other が使えないことを確かめます。記録は一時 file に書いて rename で置きます (0600)。JIT の設定と token は書きません。

`cleanup` は、記録の repo の lock を取れたものだけを見ます (`once` の途中の記録を消さない)。動いている container (名前と label で
探す。docker に問い合わせられなければ、動いているとみなす) の記録は残します。id のある記録は、API の runner の名前が記録と一致して
接頭辞を持つときだけ消し、404 ならもう無いとして記録を外します。id の無い記録は、名前で API の一覧から探します。

## 限界

- private の確かめと runner の作成・起動の間、動いている間の確かめの間 (最大 60 秒) には時差があります。repo を公開に切り替える
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
- machine が眠っている間は CI が進まず、merge も待ちになります。

## 公開に切り替えるとき

1. 設定の `repos` から、その repo を外します。
2. 動いている `once` を止め (INT か TERM)、`personal-ci-runner cleanup` で残った登録を消します。
3. repo の settings の runner の一覧に、`agent-tools-ci-` で始まる runner が残っていないことを確かめます。
4. repo を公開に切り替え、workflow が GitHub の runner を選ぶこと (`runs-on` の式) と、CI が通ることを確かめます。

## 検証

`scripts/tests/ci-runner-test.sh` が、偽の `gh` と `docker` で確かめます。設定の検査 (形・範囲・境界・key の重なり・symlink・
権限・大きさ)、公開範囲の判定 (public・形の違う返事・失敗・名前の違い)、作った直後と動いている間の確かめ、JIT の設定が
stdin の 1 行で届き出力・docker の引数・state に出ないこと、docker の引数 (付ける option と付けない option)、作った後の失敗の
後片付け、`cleanup` の照合、signal、同じ repo の lock を見ます。review の round 1 (#818) の後に、監視の間隔の上限、`docker stop` と
`kill` の失敗の繰り返しと、止める前に登録を消すこと、形の違う JIT の返事、返らない POST の間の TERM、子の待ちの期限を足しました。
60 秒たっても止められないときのあきらめの段は、test では見ていません (待ちが長くなるため)。実機の smoke は、合格の条件を先に #803 に書き、人が 1 回流します。
