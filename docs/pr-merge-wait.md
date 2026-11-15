# 人が merge する PR を待つ (personal-pr-merge-wait)

人が merge する PR を agent が待つための script です (#675)。実体は `shared/scripts/personal-pr-merge-wait.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-pr-merge-wait`。

PR の状態を決まった間隔で読み、merge されたか、別の終わり方をしたか、上限に達したかを exit code で返します。merge も
配備もしません。GitHub に書きません。

## 位置づけ

agent が PR を出して止まり、人が merge した後に「merge した」と伝えに来る往復がありました。この script で agent が merge を
検知し、人が伝えなくても後片付け (main の更新、配備、branch の整理、記録) に進めるようにします。

- 対象は、人が merge する PR (許可の規則を変えるもの) と、agent が merge する条件を満たさずに人に merge を頼んだ PR です。
  agent が merge してよい PR は、今までどおり [merge-preflight](merge-preflight.md) で確かめて agent が merge します。
- この script は検知だけを受け持ちます。merge の後に何をするかと、どの session でどう待つかの手順は operating-loop が
  持ちます (#675 の 2 本目)。
- 待つ間の上限を必ず持ち、上限に達したら exit 3 で人に返します。待つ process を残したままにしません。

## 使い方

```text
personal-pr-merge-wait <PR 番号> --expect-head <40 桁> [--repo <owner/repo>] [--interval <秒>] [--timeout <秒>]
```

- `<PR 番号>` は数字だけです。
- `--expect-head` は、人に merge を頼んだ head の OID です (review と CI を通した head)。40 桁の小文字の hex で渡します。
- `--repo` は `owner/repo` の形です。省くと gh が解決する repo を見ます。
- `--interval` は確認の間隔で、1〜600 秒 (既定 60)。`--timeout` は待つ上限で、1〜43200 秒 (既定 7200、つまり 2 時間)。
- 同じ option を 2 回渡す、知らない option、値の無い option は、入力の誤り (exit 2) です。

## 確かめ方

- 確認には `gh pr view <番号> [--repo <repo>] --json state,headRefOid,mergeCommit` だけを使います。題名・本文・コメントは
  読みません。gh は PATH の `gh` で、gh の stderr は捨てます。
- 起動の直後に 1 回確かめ、その後は間隔ごとに確かめます。間隔は、前の確認が終わった時点から数えます。次の間隔が上限を
  越えるときは、上限の時刻に最後の確認をします。merge の検知は、最大で間隔の長さだけ遅れます。
- script が終わるまでの最長の時間は、通常は `--timeout` に約 65 秒を足した長さです。上限の時刻の最後の確認の gh に最大
  60 秒、それを越えたときの後始末 (TERM の後に最大 2 秒、KILL の後に最大 2 秒) がかかるためです。KILL の後も gh を回収
  できない (止まれない状態の) ときは、回収を待つ分だけ延びます。外から時間の上限をかけるときは、この分に余裕を見ます。
  足りないと、外の上限で script が止められ、gh が残ることがあります。
- gh は自分の process group で起動し、1 回 60 秒で打ち切ります。期限は、stdout を読み終えるまでと、gh の group に生きて
  いる process が無くなるまでの両方に当てます。gh が stdout を閉じた後も動き続けるとき、gh の子が group に残るときも、
  期限で止めて確認の失敗に数えます。出力が 1 MiB を超えたときも止めます。
- 止めるときは、gh の group に TERM を送り、group に生きている process が無くなるまで最大 2 秒待ちます。残れば KILL を
  送ります。gh は group の leader なので、group に送れば gh 自身にも届きます。
- gh を回収 (wait) するのは、group に生きている process が無くなった後だけです。回収するまで gh の PID と group の id は
  再利用されないので、signal を送る先を取り違えません。group の外へ移った gh の子孫 (自分で別の session や group を作った
  もの) は追いません。
- 応答は、`state` が `OPEN` / `CLOSED` / `MERGED` のどれかで、`headRefOid` が 40 桁の小文字の hex のときだけ使います。
  `MERGED` のときは、`mergeCommit.oid` も 40 桁の小文字の hex であることを求めます。
- merge された PR の `headRefOid` は、GitHub が持つ merge の時の head です。これを `--expect-head` と比べます。

## 判定と exit

| 状態 | 最後の行 (stdout) | exit |
| --- | --- | --- |
| merge された。merge の時の head が `--expect-head` と同じ | `merge-wait: merged` | 0 |
| merge された。head が `--expect-head` と違う | `merge-wait: merged-other-head` | 1 |
| merge されずに close された | `merge-wait: closed` | 1 |
| open のまま、head が `--expect-head` から動いた | `merge-wait: head-moved` | 1 |
| 上限に達して、まだ open (head は同じ) | `merge-wait: timeout` | 3 |
| 入力の誤り。gh の確認が 3 回続けて失敗した。上限の時刻の確認が失敗した。止められた (SIGINT / SIGTERM)。想定外の例外 | 無し (stderr に 1 行) | 2 |

- gh の確認の失敗は、gh が exit 0 でない、60 秒を越えた (gh の group に process が残っている間を含む)、出力が大きすぎる、
  応答の形が外れる、gh を起動できない、のどれかです。成功した確認で数え直し、3 回続いたら exit 2 にします。
- 上限の時刻の確認が失敗したときは、PR の状態を確かめられないので、timeout にせず exit 2 にします。
- exit 1 は、頼んだ head のまま merge されたとは言えない終わり方です。merge の後の手順に進まず、人に伝えます。

## 出力

- 起動の直後に `merge-wait: waiting (PR #<番号>、上限 <秒> 秒)` の 1 行を出します。入力の誤りでは出しません。
- 待っている間は、何も出しません。
- 終わるとき、exit 0 は `merge-commit: <40 桁>` と `head: <40 桁>` の行を、exit 1 と 3 は `state: <OPEN|CLOSED|MERGED>` と
  `head: <40 桁>` の行を出し、最後の行に結果を出します。
- exit 2 では、stdout は waiting の行だけ (入力の誤りでは空) で、stderr に理由を 1 行出します。

```text
merge-wait: waiting (PR #675、上限 7200 秒)
merge-commit: 0123456789abcdef0123456789abcdef01234567
head: 89abcdef0123456789abcdef0123456789abcdef
merge-wait: merged
```

## 止められたとき

- SIGINT か SIGTERM を受けると、走っている gh の group を止めて回収し、exit 2 で終わります。確認と確認の間の待ちの最中なら、
  待ちを切り上げて、新しい gh を起動せずに終わります。確かめている最中に届いたときは、確かめた結果 (merge されたなど) より
  signal を優先し、結果の行を出さずに exit 2 で終わります (止めた呼び出し元が、merge の後の手順に進まないため)。
- 結果を確定する点は、結果の行を出す直前の 1 か所です。そこまでに届いた signal は結果より優先し、その後に届いた signal は
  確かめずに、確定した結果のまま終わります。どの瞬間に届いた signal も、どちらか一方になります。
- signal の handler は、届いた signal を記録するだけです。止めるのは、gh を起動して PID を覚えた後か、確かめる処理の区切り
  だけです。gh を起動した直後や回収した直後に signal が届いても、gh を見失ったり、回収した後の group に signal を送ったり
  しません。
- gh を止めている最中に 2 回目の signal が届いても (Ctrl-C を 2 回押したときなど)、止める処理を途中で抜けません。
- SIGKILL では後始末ができません。gh は自分の process group で動くので、そのときは gh が残ることがあります (起動した側が
  確かめる)。

## 使い方の例

```sh
wait=<tool home>/agent-tools/scripts/personal-pr-merge-wait
"$wait" "$pr" --expect-head "$head" --repo "$repo"
```

`$pr` と `$head` と `$repo` は、shell literal にした値で渡します (command の文字列へ inline に展開しない)。`$head` は、人に
merge を頼んだ時点の PR の head です。

## 組み込み先

- 運用 instruction の「待ちと判断の伝え方」が、人に merge を頼んだ PR はこの script で merge を待ち、merge を確かめたら
  後片付けに進む、と宣言します (#675 の 2 本目)。
- 手順の正本は、operating-loop の「人が merge する PR を待つ」です。Claude Code の session では background で走らせ、
  終わりの通知で結果を読みます。Codex の session には background の通知が無いので、上限を短くして foreground で走らせ、
  上限に達したら人に返します (上限は、上の「確かめ方」の最長の時間を見込んで決める)。exit code ごとの扱い (0 は merge の
  後の手順に進む、1・2・3 は人に伝える) も、そちらにあります。
