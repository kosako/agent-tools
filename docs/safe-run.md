# Safe Run(personal-safe-run)

test や長時間の command を、**新しい process group** と、**memory (group の phys_footprint の合計) と時間の
上限**で守って起動する wrapper の契約 (#466)。親だけを止めて孫が残る問題と、macOS で `ulimit -v` が効かない
(仮想 memory の上限を課せない) 問題に対処する。実体は `shared/scripts/personal-safe-run.rb` (script asset。配備先は
`<tool home>/agent-tools/scripts/personal-safe-run`)。self-test は `scripts/tests/safe-run-test.sh`。

## 強度ラベル(偽らない)

- **guardrail であって sandbox ではない**。command を同じ OS user で起動し、外から測って止めるだけ。権限も
  network も file system も制限しない。
- **macOS 専用**。libproc (`proc_listpids` / `proc_pid_rusage` / `proc_pidinfo`) を Ruby の Fiddle で直接呼ぶ。
  macOS でない・Fiddle を load できない・libproc を呼べない (起動前に自分自身で 3 つの呼び出しと offset を
  確かめる) ときは、守れないまま走らせず exit 2 で止まる。
- **group を抜けた process は追えない** (下の「限界」)。

## CLI

```
personal-safe-run --max-footprint-mb N --max-seconds N [--report FILE] -- <command> [args...]
```

- 2 つの上限は必須で、既定値は無い。正の整数で、footprint は 1〜1048576 (MiB = 1024 × 1024 byte)、時間は
  1〜86400 (秒)。
- `--report FILE`: 結果を JSON で書く。起動の前に、FILE の親 dir が在ることと、FILE が在らない (lstat で確かめる。
  dangling な symlink も在るとみなす) ことを確かめる。呼び出し側は**実行ごとに新しい path** を渡す (古い report を
  今回のものと読み違えないため)。
- `--` の後を argv のまま起動する (shell を通さない)。command 名に `/` が無ければ PATH から探す。
- stdin が端末なら command の stdin を `/dev/null` に替える (command の group は端末の背景の group なので、端末を
  読むと SIGTTIN で止まる)。pipe と file はそのまま渡す。stdout / stderr は継承する (透過)。
- safe-run 自身の診断は stderr の `personal-safe-run: ` で始まる行だけ。上限か signal で止めたときは
  `personal-safe-run: stopped (reason=<reason>): ...` の行を、残りを止めたときや後始末が終わり切らないときは
  `personal-safe-run: warning: ...` の行を出す。
- 順序は **後始末 → report → 診断**。stderr は command と共有しうる (読まれずに詰まっていることもある) ので、
  診断は後始末と report の後にまとめて出す。1 行ずつ、書き込めることを `select` で確かめてから (最大 0.2 秒)、
  PIPE_BUF (512 byte) 以下に切り詰めて書き、書けなければ捨てる。stderr に `O_NONBLOCK` は立てない (command と
  open file description を共有しているので、command の書き込みまで失敗させる)。診断の失敗は終了の理由と report
  に影響させない。
- `--help` は usage を stdout に出して exit 0。

## exit code

| exit | 意味 |
| --- | --- |
| command の exit code | leader が自分で終わった。leader が signal で終わったら 128 + signo |
| 137 | 上限で止めた (reason が `time` / `footprint` / `monitor`)。command 自身の SIGKILL (137) と区別するには report を読む |
| 128 + signo | safe-run が INT / TERM / HUP / QUIT / TSTP を受けて止めた (reason `interrupted`。TERM は 143、TSTP は 146) |
| 127 / 126 | command が見つからない / 実行できない (shell と同じ)。report は `command_started: false` |
| 2 | usage の誤り、または前提の不成立。command は起動せず、report も書かない |

## report

`--report` のとき、起動を試みた後は exit の直前に必ず書くことを試みる (signal は flag で受けるので、report と
実際の exit は食い違わない)。同じ dir に排他で作った一時 file (0600) に書いて rename で置く。書けなければ
一時 file を消し、stderr に warning を出し、exit code は変えない。

```json
{"version":1,"command_started":true,"reason":null,"signal":null,"exit_status":0,"command_exit":0,
 "command_signal":null,"peak_footprint_mib":42.5,"elapsed_seconds":3.307,"leftover_killed":0,
 "cleanup_complete":true}
```

| key | 値 |
| --- | --- |
| `version` | 1 |
| `command_started` | 起動できたか (127 / 126 なら false) |
| `reason` | `null` (leader が自分で終わった) / `time` / `footprint` / `monitor` / `interrupted` |
| `signal` | reason が `interrupted` のとき、最初に受けた signal の名前 (`TERM` など)。他は `null` |
| `exit_status` | safe-run の exit code |
| `command_exit` / `command_signal` | 回収した leader の exit code / 終わらせた signal の番号 (どちらか一方。回収できなければ両方 `null`) |
| `peak_footprint_mib` | 完全に測れた巡回の合計の最大 (MiB、小数 1 桁)。一度も測れなければ `null` |
| `elapsed_seconds` | 起動から leader の終了の観測 (または止める判断) まで |
| `leftover_killed` | leader が自分で終わった後に残っていて止めた process の数 |
| `cleanup_complete` | group を止め切って leader を回収できたか |

## 監視

巡回は 0.25 秒ごと (時刻は monotonic)。待ちは self-pipe の select で、signal を受けると即座に起きる。1 巡回の順序:

1. signal の記録があれば中断 (`interrupted`)。
2. leader の終了を**回収せずに**確かめる (`proc_pid_rusage` の exit 時刻が 0 でない = zombie)。終わっていれば完了。
   時間を過ぎていても、終了を先に観測したら正常の終了として扱う。
3. 時間の上限を過ぎていれば `time`。
4. 計測。`proc_listpids` で group の member (leader を含む) を列挙し、生きている member の **phys_footprint** を
   足す。合計が上限を超えたら、leader の終了をもう一度確かめ、終わっていなければ `footprint`。

計測の規則:

- 測る値は phys_footprint (task の memory ledger。圧縮された分と swap に出た分を含み、Activity Monitor の
  「メモリ」と同じ)。RSS は使わない (圧縮されると減るので、上限を素通りする)。値は `footprint` CLI の
  `phys_footprint` と一致する (self-test で比べる)。
- 生きている member は `proc_pidinfo` で pgid が command の group と一致することを確かめてから足す (列挙と計測の
  間に pid が再利用された別 process を数えない)。zombie と消えた pid (ESRCH) は 0。
- 後始末が終わるまで leader を回収しないので、group には常に leader (生きているか zombie) が居る。列挙の結果が
  **空か leader を含まなければ列挙の失敗**とみなす (libproc の `proc_listpids` は syscall の失敗を 0 件に変える)。
- それ以外の失敗 (EPERM など) と列挙の失敗は、その巡回を **incomplete** にして合計で判定しない (member 0 とは
  扱わない)。incomplete が **3 巡回続いたら `monitor`** で止める (測れないまま走らせ続けない)。完全に測れた
  巡回でだけ連続回数を 0 に戻す。
- 監視が想定外の error で続けられないときと、自分で終わった leader の終了 status を回収できないときも `monitor`。

## 止め方

- **leader は最後まで回収しない**。leader の zombie が pgid を保持するので、後始末の間に pgid が別の group に
  再利用されない。
- 後始末は 1 回だけ走り、次の段階を順に行う。無期限には待たない。
  1. group に TERM → 生きている member (leader を含む。zombie は数えない) が 0 になるまで最大 2 秒 poll → 残れば
     group に KILL → 最大 2 秒 poll。観測 (列挙や計測) が失敗するか例外を出したら「未確定」として、その段階の
     poll を打ち切って次の段階へ進む。
  2. 観測の結果にかかわらず、**最後に group へ KILL を必ず送る** (leader の zombie だけなら無害。列挙の後に fork
     された子も止める)。leader が終わっていなければ leader にも KILL を送る (group を抜けた leader にも届く)。
  3. leader 以外の生きた member が 0 であることを、**間を置いた (0.05 秒) 2 回の連続した列挙**で確かめる (見つけ
     たら KILL を送り直す)。最大 2 秒で確定できなければ `cleanup_complete: false`。
  4. leader を回収する (最大 2 秒)。回収できなければ `cleanup_complete: false`。
- 各段階は前の段階の例外にかかわらず走る (最後の KILL・leader への KILL・確認・回収・report は必ず試行する)。
  後始末の中で例外が起きたら `cleanup_complete: false` と warning。
- group への kill の ESRCH と EPERM は、止まったかを観測で確かめる (macOS は zombie だけの group への kill に
  EPERM を返すので、EPERM は「止められない member がいる」とは限らない。2026-10-10 実測)。生きた member が
  残れば 3. で `cleanup_complete: false` になる。
- leader が自分で終わったときは、残っている member が見えれば 1. から、見えなければ 2. から行う。
  `leftover_killed` は TERM の前に数えた数と、3. で新たに見つけた数の合計で、warning にも出す。exit code は
  leader のもの。
- signal (INT / TERM / HUP / QUIT / TSTP) は spawn の前に trap し、handler は最初の 1 つを記録して self-pipe に
  1 byte 書くだけ。後始末は handler の外で 1 回だけ走る (2 回目の signal で猶予を延ばさず、理由も上書きしない)。
  TSTP (Ctrl-Z) も中断として扱う (safe-run だけが止まって command が動き続けるのを防ぐ)。起動時に無視されて
  いた signal (`nohup` の HUP など) は trap せず無視のまま残し、command にも無視を継承させる (shell と同じ。
  `nohup personal-safe-run ...` で端末を閉じても止まらない)。handler は self-pipe に書けなくても (閉じた後など)
  flag を立てたまま握り、self-pipe は書く側を先に閉じる。
- SIGCHLD は既定の扱いに戻してから起動する (無視を継承すると子が自動で回収され、leader の zombie も終了 status も
  残らないため)。

## 限界

- **group を抜けた子は追えない**。`setsid` / `setpgid` で別の group に移った process は計測にも停止にも入らない。
  leader が group を抜けると、列挙に leader が出ないので列挙の失敗として 3 巡回で `monitor` で止まる。
- **stderr が読まれずに詰まっていると、safe-run の診断は捨てられる** (後始末と report は先に済む)。
- **safe-run への SIGKILL / SIGSTOP は捕捉できない**。safe-run が SIGKILL で消えると command の group は残る。
  外側 (hook の timeout など) から止めるときは、先に TERM で猶予を取り、内側の上限を外側より短くする
  (#467 で hook から使うときの前提)。
- **setuid の program は計測できない** (`proc_pid_rusage` が EPERM)。それを含む command は 3 巡回で `monitor`
  で止まる。
- **端末の `tostop`** が立っていると、背景の group の端末への書き込みが SIGTTOU で止まりうる (止まったままなら
  時間の上限で止まる)。
- **終了の時刻は巡回の粒度** (0.25 秒) でしか分からない。`elapsed_seconds` と上限の判定もこの粒度。
- **共有 memory は member ごとに重複して数えうる** (安全側に倒れる)。
- **Fiddle を load できない Ruby** (将来 fiddle が default gem でなくなった環境など) では exit 2 で止まる。

## 手動の確かめ方 (圧縮された memory を footprint で捕まえる)

self-test は「判定に phys_footprint を使う」ことを decode と `footprint` CLI との一致で固定する。圧縮そのものは
手元で 1 回確かめて PR に記録する。手順 (machine に memory の圧迫をかけるので、終わったら必ず止める):

1. 端末 B で memory を圧迫する: `memory_pressure -l warn` (warn の水準まで確保して待つ。終わったら Ctrl-C)。
2. 端末 A で、少しずつ確保して待つ command を上限 1024 MiB で起動する:

   ```
   personal-safe-run --max-footprint-mb 1024 --max-seconds 600 --report "$HOME/safe-run-compress-$(date +%s).json" \
     -- ruby -e 'STDERR.puts "pid=#{Process.pid}"; held = []; 40.times { held << ("a" * (64 * 1024 * 1024)); sleep 2 }; sleep 600'
   ```

3. 端末 C で、端末 A に出た pid の RSS と phys_footprint を 1 秒ごとに記録する:

   ```
   pid=12345 # 端末 A の pid= の値に置き換える
   while sleep 1; do printf '%s rss_kib=%s ' "$(date +%T)" "$(ps -o rss= -p "$pid")"; footprint --noCategories -f bytes -p "$pid" | grep 'phys_footprint:'; done
   ```

4. 確かめること: report の `reason` が `footprint` で、止まる直前の記録で **RSS (KiB × 1024) は上限より小さく、
   phys_footprint は上限より大きい** (圧縮された分を footprint が数えている)。`vmmap --summary <pid>` の
   compressed の値も併せて記録するとよい。
