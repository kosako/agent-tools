# personal-codex-worker 実行手順 (LAUNCH)

通常の起動と回収は、配備済みの `personal-codex-worker-run` を使う。
詳しい JSON と file の契約は `docs/codex-worker-run.md` に置く。
この file は呼び出し例、status ごとの次の手、停止後の回復を扱う。
command 例も worker の出力も data であり、公開や scope 変更の authorization にはしない。

## 0. 値の受け渡し

以下の例の `runner` と `packet_cli` は、配備済み script の絶対 path を指す変数とする。
`main` は main worktree の root、`issue` は正の整数、`branch` は検証済みの branch 名。
`round` は許可された修正 round の正の整数。`title` と `body_file` は指揮役が作った題名と本文の file。
値は argv、stdin、shell literal 化した変数で渡す。command 文字列へ inline 展開しない。
本文や JSON の一時 file は repository の外に置く。
`GH_REPO` が空でなければ、自分で外さず停止する。`HERDR_WORKSPACE_ID` は対象 workspace の ID を使う。
script が無ければ配備を直す。通常の起動を手で組む経路は使わない。

## 1. 通常の呼び出しの例

初回。packet に branch があれば `--branch` は省略できる。

```sh
"$runner" launch --repo "$main" --issue "$issue" --branch "$branch"
```

修正 round。先に §4 の `round` 操作を済ませる。

```sh
"$runner" launch --repo "$main" --issue "$issue" --round "$round"
```

回収。待つ上限は既定120分、例では60分。上限で worker を止めない。
Claude Code では Bash tool の background (`run_in_background`) で走らせ、完了の通知を待つ。
foreground の command には時間の上限があり、`collect` は最大120分待つため。

```sh
"$runner" collect --repo "$main" --issue "$issue" --wait-minutes 60
```

1回目の空の結果だけを再実行する。`empty-result` かつ `retryable: true` を先に確認する。

```sh
"$runner" retry-empty --repo "$main" --issue "$issue"
```

受け入れ後の公開前検査。先に §9 の題名と本文の `personal-post-check` を済ませる。
stdout を file に保存し、exit と JSON を両方読む。

```sh
"$runner" check --repo "$main" --issue "$issue" --title "$title" --body-file "$body_file" > "$check_file"
```

人が `gate-publish.err` を確かめて公開を認めたときだけ `--accept-warnings` を付けて `check` をやり直す。
人の確認なしに `--accept-warnings` を付けない。exit 0 の warning をすべて受け入れる option であり、gate の拒否では止まる。

## 2. status ごとの次の手

| exit / status | 次の手 |
| --- | --- |
| 0 / STARTED | 起動の受付。`collect` を呼ぶ |
| 0 / DONE | 結果は転記済み。`leftover` を報告し、受け入れを判断する。`request` が `same` でなければ、変わった依頼の分は満たしていない |
| 0 / READY | 文体の指摘を読み、§9 で OID を指定して push する |
| 1 / BLOCKED | `blocked_at`、`reason_code`、`phase` を読み、§3 の回復へ進む |
| 2 / BLOCKED | 入力を直す。clone や起動記録が作られたと推測しない |
| 3 / RUNNING | 再起動せず記録と pane を残す。§10 の起動済み hand-off へ進む |

`STARTED` と `READY` を完了と取り違えない。script の exit が非0なら後続を自動で実行しない。
`packet.written` は、その呼び出しの記録の書き込みを示す。packet を読み直して実際の state を返す。
`check` は packet を更新しない。`RUNNING` も起動記録を保持する。

## 3. 停止後の回復

停止後の state と回復の正本は、`docs/codex-worker-run.md` の「停止後の state と回復 (正本)」の表。
subcommand、status、blocked_at、reason_code と packet の再読込結果を照合して次の手を選ぶ。
`collect-required` は collect、1回目の空の結果だけ retry-empty を使う。
記録前の停止と、run-start や result の適用後の失敗を区別する。更新済みの操作は繰り返さない。
照合・退避・転記で止まっただけなら state を変えず、下の破棄の判断も自動では行わない。
公開前の停止では push を止める。履歴の修正と snapshot の前提は正本の表と回復手順に従う。

一覧に無い `reason_code` は `Status: BLOCKED` で人に返し、自分で回避しない。
clone の hook の設定を自分で書き換えない。`Next step` には hook の設定の出所を人が確かめると書く。

`check` が BLOCKED を返したときは `worker-update` の `stop` を記録しない。
packet は `open` のまま置き、既に `review` ならその状態を保つ。
`check` は open か review だけを受け付け、blocked にすると再検査できず、原因を直さない限り同じ段で止まるため。
停止の区分と理由と人の次の手は返却の `Next step` に書き、直した後に `check` をやり直す。
worker に直させるときは §4 の `round` で修正 round の項を依頼に足してから `launch` で起動する。

### 人が起動の記録の破棄を決めたとき

対象は、`collect` が RUNNING を返したが worker が動いていないと人が確かめた run や、
人手の hand-off で渡したまま起動しなかった run、終了後の snapshot 照合で止まった run。
照合の失敗では、人が必要な変更を保存して clone 全体を退避し、元の path を空けてから以下へ進む。
未照合の clone に git を実行しない。保存した変更の復元も人が判断する。

1. 人が pane と process を確かめ、記録の破棄を決める。生存を確かめられなければ記録を残す。
2. 指揮役は packet を読み直し、破棄を決めた理由を entry に書く。
   `worker-update` の `stop` で `blocked` にし、`next` に再開の入口を記す。`run` は保持する。
3. `launch` で起動し直す。`run-start` が blocked を open に戻し、記録を新しい run に置き換える。

tab の作成前に手渡しになった run の run dir には `tab-id` が無い。
前の round の `#<issue>` の tab が残っていると、`stop` 後の `launch` はその所有を確かめられない。
この場合は `launch-path` / `tab-ownership` で止まる。
人が `#<issue>` の tab を確かめ、不要なら閉じる。
その後、未起動の run の記録も上の手順で破棄してから `launch` し直す。
tab を閉じないなら §10 の未起動 hand-off で渡す。

frontmatter を手で書き換えず、clone の commit と未 commit の変更を消さない。
`stop` の前提は open。既に blocked なら重ねて記録せず、再開の許可を確認して launch する。
それ以外の state なら破棄用の架空の依頼を作らず、人に返す。

`launch-path` は、生成済みの run script を渡せる場合と、生存や所有を確認できない場合を区別する。
`launch.json`、run script、起動記録が揃い、未起動と確認できた場合だけ §10 の未起動 hand-off を使う。

## 4. packet の更新

packet は `personal-packet worker-update <issue> --stdin` の操作で書く。
指揮役が使う `round`、`review`、起動記録を破棄するときの `stop` も、手で frontmatter を書き換えない。
入力は `docs/agent-packets.md` の6操作の schema に従う。
毎回 packet を読み直し、その byte 列の SHA-256 を `expected_sha256` に指定する。
digest 不一致では書かない。読み直した状態と依頼を確認してからやり直す。

```sh
"$packet_cli" worker-update "$issue" --stdin < "$update_file"
```

`round` は許可された修正内容を依頼に追記し、review なら state を `open` に戻す。
blocked は保持し、次の `launch` の `run-start` で `open` に戻す。
実行中の run がある間に足した依頼は、その run の回収では満たされない。次の入口は残るので、回収の後に `launch` し直す。
`review` は PR 番号を記録して state を `review` にする。
`stop` は `open` が前提。人が起動記録の破棄を決めた場合は §3 に従う。
`review` で停止し、修正依頼がまだ無いときは、前提を満たすためだけの `round` を作らず判断を待つ。

## 5. 起動の境界

`launch` が clone、preflight、brief、run script、起動記録を順に用意する。
preflight の `launch_argv` の flag は足さない・外さない。
worker に packet と GitHub を開けない。run dir は worker の書込先の外に置く。

既存 tab は、前の run の `tab-id` との一致と全 pane の命名を確認する。
名前は `worker-<issue>` または `worker-<issue>-r<N>`。一覧の読み取り失敗を0件と扱わない。
確認できなければ pane を足さず、tab にも触らない。

## 6. 待ち方と限界

`collect` は `herdr pane wait-output` を最大300秒ずつ呼び、`done.txt` を確かめる。
`herdr pane process-info --pane <pane-id>` の foreground process の名前で生存を観測する。
観測できない場合は消滅と判断しない。nonce の一致と exit 0、空でない結果が完了の条件。
上限は120分。`codex exec` 自体は safe-run で包まない。
待つ側の上限で process を止めず、`RUNNING` を返す。続行か中断かは人が決める。

## 7. 完了後

`collect` は転記の前に、pane の foreground と clone の path を引数に持つ process を観測する。
結果の `leftover` を読み、残っていたら pid と command の名前を人への報告に書く。
自分では止めず、止めるかは人が決める。
`checked: false` なら確かめられなかったことを報告に書く。
この観測は転記を止める条件ではない。cwd だけが clone の中の background process は見つからない。

## 8. 転記と退避

`collect` が書式と gate を通した最終 message を、要約せず packet に転記する。
停止理由が「なし」なら `result`、質問があれば `stop` 操作を使う。
完了では `run` を `last_run` へ移す。停止では snapshot の照合後に変更を退避して記録を残す。
照合・退避の失敗は packet を更新せず返す。file の契約と置換の規則は `docs/codex-worker-run.md` を参照する。

## 9. 回収 (fetch) と trailer 検査と PR

受け入れ後に題名と本文を書き、push の前に `personal-post-check` に通す。
exit 1 なら `check` も push もせず、本文と出力を人に見せる。人が公開を認めたときだけ先へ進む。
exit 2 は検査不能として止め、原因を直してかけ直す。
exit 3 は指摘を読んで直すか、理由を持って `--style-reviewed` を付けてかけ直す。
検査が exit 0、または exit 1 の後に人が公開を認めた場合だけ、§1 の `check` を呼ぶ。
手で fetch や gate の pipeline を組まない。検査と公開は別の呼び出しにする。
以下は `check` が exit 0 で `READY` を返した後だけ行う。
JSON の `head_oid`、`branch`、`slug` をそれぞれ変数に読み、検査した OID を指定する。
題名や本文を直したら `personal-post-check` からやり直す。

```sh
head_oid=$(jq -er 'select(.status == "READY") | .head_oid' "$check_file") || exit 1
branch=$(jq -er '.branch' "$check_file") || exit 1
slug=$(jq -er '.slug' "$check_file") || exit 1
git -C "$main" push origin "${head_oid}:refs/heads/${branch}"
```

push の結果を確認し、成功したときだけ別の呼び出しで PR を作る。
個人 project 以外の公開は対象 repo の許可も確かめる。検査の詳細は `docs/post-check.md`。

```sh
gh pr create --repo "$slug" --base main --head "$branch" --title "$title" --body-file "$body_file"
```

修正 round では PR を新しく作らない。push 後に §4 の `review` 操作で PR 番号と state を記録する。

後始末で使う公開先の確認は次の block。§11 の前提確認で再実行する。
通常の公開前検査をこれで代えない。

```sh
slug=$(cd "$main" && gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 1
ruby -e 's = ARGV.fetch(0); exit(s.match?(/\A[\w.-]+\/[\w.-]+\z/) && !s.start_with?("-") ? 0 : 1)' "$slug" || exit 1
push_url=$(git -C "$main" remote get-url --push origin) || exit 1
github_host=github.com
case "$push_url" in
  "https://$github_host/$slug"|"https://$github_host/$slug.git"|\
  "git@$github_host:$slug"|"git@$github_host:$slug.git"|\
  "ssh://git@$github_host/$slug"|"ssh://git@$github_host/$slug.git") ;;
  *) exit 1 ;;
esac
```

## 10. 人手 hand-off

未起動 (`launch-path`) と起動済み (`RUNNING`) を分ける。

- 未起動: §3 の確認が通った生成済み `run.zsh` の path を shell literal で人に渡す。
  起動記録と state は保持する。人が terminal で実行したら、同じ `collect` で回収する。
  pane が無い run は `launch.json` の `pane_id` が null。完了記録が無ければ `manual-completion-pending`。
  端末の sentinel や口頭報告だけで完了としない。
  人手実行の1回目も空なら、`retry-empty` は所有を確かめられず停止する。
  `docs/codex-worker-run.md` の「人手実行だけの空の結果の回復」に従い、
  新しい run dir と nonce の run script を人に1回だけ渡す。元の script は再実行しない。
- 起動済み: run script を再実行させない。
  `Next step` は tab と pane を見て続行か中断かを決めること。
  続行なら pane を監視して `done.txt` を待ち、`collect` で回収する。
  中断なら人が process を止めてから `collect` で停止を記録する。待つ側は process を止めない。
  完了記録が無く RUNNING のままなら、人が §3 の起動記録の破棄を判断する。

## 11. 後始末 (packet が done になったとき。後始末モード)

最初に `[ -z "${GH_REPO-}" ]` で env の `GH_REPO` が空であることを確かめる (空の値は無い扱い)。
空でなければ何も作らず、tab にも clone にも触らず `Blocked at: cleanup` で止める。
`Reason` は「`GH_REPO` が空でない」、`Next step` は「`GH_REPO` を外して起動し直す」。
gh の command ごとに向く repo が分かれうるため、自分で env を外して続けない。

worker の tab を閉じ、clone を退避先へ移すのは、PR が merge されて packet が `done` になった後に、人が後始末を
明示したときだけです (`SKILL.md` の「モード」と §9。時点は `SKILL.md` §3)。`blocked` の間と RUNNING の間は、
調べられるように残します。packet は書きません。clone は消しません (退避先を消すのは人)。

順番は「前提 (done・merge) → tab の確認 → clone の確認 → すべて通ったら tab を閉じる → clone を退避先へ移す」
です。確認の段では何も閉じず移しません。どれか 1 つでも確かめられなければ、tab にも clone にも触らず
`Blocked at: cleanup` で人に渡します (確認の途中で片方だけ片付けると、残った方を調べる手掛かり (pane の出力、
clone の置き場) が欠ける)。clone には git を実行せず、中に `cd` もしません (worker が書き換えうる `.git` や
設定を読ませない)。

### 前提 (done と merge)

§9 の対象 repo を決めて確かめる code block を、main に対して再実行する。
main で slug を取得・検証し、origin の push URL がその slug の GitHub URL と完全一致したときだけ以下へ進む。
失敗・不一致なら `Blocked at: cleanup` (`Reason` は「公開先を確かめられない」) で止める。
この確認で得た `slug` を PR の metadata の取得にも渡す (以前の run の値は使わない)。

```sh
# list の出力を変数に受け、失敗したら止める。pipe で終了コードを失わない
packets=$("$packet_cli" list --json --all) || exit 1
row=$(printf '%s' "$packets" | jq -ce --argjson issue "$issue" '
  [.[] | select(.issue == $issue)] | select(length == 1) | .[0]
  | select(.state == "done" and .run == null and (.last_run | type == "string")
           and (.pr | type == "number") and (.branch | type == "string"))') || exit 1
prev_run=$(printf '%s' "$row" | jq -er '.last_run') || exit 1
pr=$(printf '%s' "$row" | jq -er '.pr') || exit 1
branch=$(printf '%s' "$row" | jq -er '.branch') || exit 1
# PR は metadata だけを読む (title / body は取得しない)
meta=$(gh pr view "$pr" --repo "$slug" --json state,headRefName) || exit 1
printf '%s' "$meta" | jq -e --arg branch "$branch" '.state == "MERGED" and .headRefName == $branch' >/dev/null || exit 1
```

(`exit 1` は「その段で止めて、tab にも clone にも触らず `Blocked at: cleanup`」の意。`$issue` は §0 の正の整数。
`prev_run` / `branch` は packet 由来の値なので、以降も変数で渡す。jq は行が無い・2 件以上・条件に
合わないときに出力が無く、`-e` で非 0 になる。gh の `state` は merge 済みの PR で `MERGED`。)

### tab の確認 (まだ閉じない)

```sh
ws=$HERDR_WORKSPACE_ID
[ -n "$ws" ] || exit 1
label=<'#<issue>' の shell literal>
# 終了コードと JSON の形を確かめてから読む
tabs=$(herdr tab list --workspace "$ws") || exit 1
panes=$(herdr pane list --workspace "$ws") || exit 1
printf '%s' "$tabs"  | jq -e '.result.tabs  | type == "array"' >/dev/null || exit 1
printf '%s' "$panes" | jq -e '.result.panes | type == "array"' >/dev/null || exit 1
printf '%s' "$tabs" \
  | jq -r --arg label "$label" '.result.tabs[] | select(.label == $label) | .tab_id'
# 0 件なら tab= (閉じる tab は無い)。1 件なら、下の所有の確認 (最後の run dir = packet の last_run の tab-id との
# 一致 + 命名) を通り、その tab のどの pane の foreground にも codex がいないことを確かめてから、その ID を tab= に
# 控える (閉じるのは「片付ける」の段)
```

(`exit 1` は「その段で止めて、tab にも clone にも触らず `Blocked at: cleanup`」の意。)

- 0 件なら閉じる tab は無い (人が既に閉じた)。一覧の取得か形の確認に失敗した、2 件以上、所有を確かめられ
  ない (最後の run dir が分からない場合を含む)、codex がまだ foreground にいる、process-info で判定
  できない、のどれかなら、tab にも clone にも触らず `Blocked at: cleanup` とし、人に「tab `#<issue>` を
  確かめてください」と伝える (人の tab と、走っている worker を閉じない。一覧が読めないことを「0 件」と
  取り違えない)。

所有は、記録した ID と命名の両方で確かめる。上で1件と確認した tab の ID を `tab` に入れてから実行する。
その tab の pane が1つ以上あり、label がすべて `worker-<issue>` か `worker-<issue>-r<N>` のときだけ通す。

```sh
prev_tab=$(cat "$prev_run/tab-id") || exit 1
[ "$prev_tab" = "$tab" ] || exit 1
printf '%s' "$panes" | jq -e --arg tab "$tab" --arg issue "$issue" '
  [.result.panes[] | select(.tab_id == $tab)] as $p
  | ($p | length) > 0
    and all($p[]; (.label // "") | test("^worker-" + $issue + "(-r[0-9]+)?$"))' >/dev/null || exit 1
```

jq が exit 0 のときだけ所有を確かめたとみなす。file の欠けや label の欠けでも止める。
各 pane について `herdr pane process-info --pane <pane-id>` を呼び、終了コードと JSON の形を確かめる。
`result.process_info.foreground_processes[].name` に `codex` があるかを見る。
居る、または判定できない場合は `Blocked at: cleanup` で止める。

- orchestrator 自身がいる tab (`personal-codex-review` の review pane もここに置かれる) は、記録した
  tab ID と一致せず、pane の名前も `worker-<issue>` の形でないので、閉じる対象にならない。

### clone の確認 (まだ移さない)

```sh
# path の lstat の種類を出す。ENOENT だけを absent とし、権限エラーなどの失敗は非 0 で止める
# (test -e は「無い」と「確かめられない」を区別しない)
lstat_kind() {
  ruby -e 'begin
      s = File.lstat(ARGV[0])
      puts(s.symlink? ? "symlink" : s.directory? ? "dir" : "other")
    rescue Errno::ENOENT
      puts "absent"
    end' "$1"
}
clone=<SKILL.md §3 の置き場 (<main worktree>-clones/<issue>) の path の shell literal>
clone_root=
kind=$(lstat_kind "$clone") || exit 1
case "$kind" in
  absent) ;;                                   # 置き場に clone は無い (人が既に片付けた)。clone の確認を飛ばす
  dir)
    want=$(jq -er '.clone_root' "$prev_run/preflight.json") || exit 1
    clone_root=$(ruby -e 'puts File.realpath(ARGV[0])' "$clone") || exit 1   # 中に cd しない
    [ "$clone_root" = "$want" ] || exit 1      # 最後の run が検査した clone が、置き場の path の実体
    cleaned=${clone_root%/*}/.cleaned          # 退避先は同じ置き場の下 (SKILL.md §3 の <issue> と名前が衝突しない)
    dest=${cleaned}/${issue}-$(date -u +%Y%m%dT%H%M%SZ)
    ck=$(lstat_kind "$cleaned") || exit 1
    case "$ck" in absent|dir) ;; *) exit 1 ;; esac   # .cleaned が symlink や file なら移さない
    dk=$(lstat_kind "$dest") || exit 1
    [ "$dk" = absent ] || exit 1               # 退避先が既に在れば何もしない
    # worker の pane (worker-<issue>[-r<N>]) のどの foreground にも codex がいない (上の tab の確認で読んだ
    # $panes を、この節の命名で絞って見る)
    ;;
  *) exit 1 ;;                                 # symlink / file などは置き場の clone と確かめられない
esac
```

(`exit 1` は「その段で止めて、tab にも clone にも触らず `Blocked at: cleanup`」の意。)

- 置き場の path が無い (lstat が `ENOENT`) ときだけ clone の確認を飛ばす (移す clone は無い。tab の確認が通れば
  tab だけ閉じる)。lstat が権限エラーなどで失敗したときは「無い」と取り違えず止める。
- 置き場の path が symlink / directory でない、`last_run` の `preflight.json` が無い・読めない、`clone_root` が
  置き場の path の実体と一致しない (別の場所に切った clone を含む)、`.cleaned` が directory でない、退避先が既に
  在る・確かめられない、codex がまだ foreground にいる、herdr の一覧や process-info で判定できない、のどれかなら、
  tab にも clone にも触らず `Blocked at: cleanup` とし、人に「clone を確かめてください」と伝える。

### 片付ける (確認がすべて通った後)

```sh
if [ -n "$tab" ]; then herdr tab close "$tab" || exit 1; fi        # 0 件なら閉じる tab は無い
if [ -n "$clone_root" ]; then                                        # 置き場に無ければ移す clone は無い
  mkdir -p -- "$cleaned" || exit 1
  ruby -e 'File.rename(ARGV[0], ARGV[1])' "$clone_root" "$dest" || exit 1   # rename(2)。copy に倒さない
fi
```

(`exit 1` は「その段で止めて `Blocked at: cleanup`」の意。tab を閉じられなければ clone を移さない。rename が
失敗したら clone はそのまま残る (何も消さない)。どちらも、何が済んだかと退避先を返却に書く。)

- 移動は `mv` ではなく `rename(2)` (Ruby の `File.rename`) で行う。`mv` は移動先が directory だとその中へ移し、別の file system なら
  copy して元を消す。rename は別の file system (`EXDEV`)・中身のある directory や file が移動先にある・書けない、の
  どれでも失敗し、元の clone を残す (一時 dir で、中身のある directory・file・書けない `.cleaned` への rename が
  失敗して元が残ることを実測した)。確認と rename の間に空の directory が移動先に作られた場合だけは、その空の
  directory と置き換わる (失われる中身は無い)。
- honest-label: 消さないので、退避で失われるものは無い (commit、reflog、stash、index、未 commit の変更、ignored な
  file はすべて退避先に残る)。そのため、未回収の commit や未 commit の変更の確認はしない。disk は人が退避先を
  消すまで空かない。退避先の clone の `.git` は worker が書き換えうるので、人が中で git を実行する前に中身を
  確かめる。確認から rename までの間の差し替え (同じ user の権限による TOCTOU) は防がない (packet の `check` と
  同じ立場)。
