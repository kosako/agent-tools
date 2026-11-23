# Classifier Invariants (分類器の不変条件の試行)

挙動の評価の分類器 (`scripts/lib/skill_behavior_classifier.rb`) は、command を読んで区分を決める
([skill-behavior-eval](skill-behavior-eval.md) の「区分」)。その test は、形と区分を並べた表である。

この試行 (#754) は、表の代わりにルールを 1 つ決め、それを機械に確かめさせる。
ルールは「`read` と区分した command は、書かず、起動しない」。
`read` と区分した command を、隔離した一時 dir の中で実際に走らせ、前後を比べる。

今あるのは、隔離、判定、1 件の command を調べる入口まで。
command の生成と試行の本体は、次の PR で足す。

| 部品 | path | 役割 |
| --- | --- | --- |
| 入口 | `scripts/probe-classifier-invariants.sh` (`scripts/lib/probe_classifier_invariants.rb`) | 引数、順序、結果の file、exit code |
| 隔離 | `scripts/lib/probe_classifier/isolation.rb` | 一時 dir、道具の表、canary、profile、環境、起動、guard、preflight |
| 判定 | `scripts/lib/probe_classifier/judge.rb` | snapshot、差分、終わり方、違反と人に出すものの分け方、確かめ直し |
| self-test | `scripts/tests/probe-classifier-invariants-test.sh` | T1 から T6。CI で走る |

依存は macOS 標準の Ruby、`sandbox-exec`、git (developer dir の中の `usr/bin/git`)。network は使わない。

## 不変条件

対象は、分類器が `read` と区分した command だけ。

- I1: fixture の tree を変えない。
- I2: canary を走らせない。

I1 は file system の差分で見る。I2 は、置いておいた program (canary) が走った印で見る。
`exec` の区分と、gh や network に出る形は対象にしない。

反例が出ても、I1 と I2 の定義や判定を弱めて通さない。定義を変えるのは人の判断にする。

## 隔離

分類器が誤っていれば、`read` と区分された command は書き込みや起動をしうる。
そこで、層を 2 つ重ねる。

1. 文字列の guard。command の文字列を見て、一時 dir の外を指しうる形と、終わらない形を走らせない。
2. `sandbox-exec` の profile と、閉じた環境。外への書き込み、network、HOME の読み取り、表に無い program の起動、
   外の process への signal を拒む。

guard が見るのは文字列だけである。実行のときに出来る path は見えない
(`which` の出力を `xargs` に渡す形や、`tr` で作った `..` など)。そこは profile が受ける。
command は必ず `sandbox-exec` を通して走らせる。sandbox を適用できなければ、command は走らない。

### 一時 dir と fixture

一時 dir は command ごとに新しく作り、本物の HOME の外に置く。中は 6 つの区画に分ける。

| 区画 | 中身 |
| --- | --- |
| `fx` | fixture。command の cwd |
| `home` | 子の `HOME` |
| `tmp` | 子の `TMPDIR` |
| `shim` | `PATH` の先頭。canary を置く |
| `tools` | 道具への symlink。`PATH` の 2 番目 |
| `marks` | canary が印を書く所 |

fixture は小さな git の repo である。

- file は `README.md`、`in.txt` (同じ行が続く所を含む)、`x`、`lib/median.rb`。
- commit が 2 つあり、`README.md` に未 commit の変更がある。
- canary の file は `cat`、`bin/grep`、`canary_begin.rb`。template を写した後に書くので、git からは追跡していない file に見える。

template は、run の初めに隔離の中で 1 回だけ作る (user の global の git の設定と hook を通さないため)。
`git init` が置く hook の見本は実行できる file なので、消してある。

template を写した直後の fixture では、`git diff` が `GIT_OPTIONAL_LOCKS=0` でも index を書き直した
(この machine の git 2.54.0 で実測)。写した file の stat が index と食い違うためと見ている。
`git update-index -q --refresh` で index を揃えた後は、`git diff` も `git status` も書き直さなかった。
fixture の用意の跡を command の書き込みと読み違えないように、走らせる前に index を揃える。

fixture の file の mtime は、過去の決まった時刻に揃えてある。
index と同じ秒の mtime が残ると、git は中身を比べ直して index を書き直す。
揃える前は、template を作ってからの時間で結果が変わった (`git describe --dirty` で実測。下の K5)。

### canary

canary は、走ると `marks` に `<id>.<pid>` という空の file を書く。数え方は種類で分ける。

| 種類 | 置く所 | 数え方 |
| --- | --- | --- |
| `path` | `shim/canary` | I2 |
| `cli` | `shim` の `codex`、`claude`、`gh`、`opencode`、`herdr` | I2 |
| `fixture` | `fx` の `cat`、`bin/grep`、`canary_begin.rb` | I2 |
| `reserved` | `shim` の `then`、`do`、`else`、`fi`、`done`、`!`、`{`、`}` | 人に出す |

予約語の名前の canary は、置いた名前に依る結果なので、違反に数えずに人に出す (下の K4)。
本物の `codex`、`claude`、`gh`、`opencode`、`herdr` は起動しない。その名前は canary に当たる。

### 環境

子に渡す環境は、次の表だけ。親の環境は引き継がない。

`HOME`、`PATH` (`shim` と `tools`)、`TMPDIR`、`LC_ALL=C`、`GIT_CONFIG_NOSYSTEM=1`、`GIT_CONFIG_GLOBAL=/dev/null`、
`GIT_OPTIONAL_LOCKS=0`。

`GIT_OPTIONAL_LOCKS=0` は、`git status` の index の書き直しを止める (`git diff` は上の「一時 dir と fixture」)。
子の stdin は `/dev/null` にする。

### profile

| 対象 | 規則 |
| --- | --- |
| 書き込み | 一時 dir と `/dev/null` だけを許す |
| network | 拒む |
| 読み取り | 本物の HOME を拒む。HOME の外は読める |
| program の起動 | allowlist。道具の表の実 path、`shim` の下、fixture の canary の file、git の developer dir、`path_helper` |
| signal | 同じ sandbox の中の process にだけ送れる |

一時 dir の全体には起動を許さない。fixture の中のほかの file が、canary にも拒否にも当たらずに走るのを防ぐため。
login の shell (`zsh -lc`) が `PATH` を組み直しても、表に無い program は起動できない。

### 道具の表

道具は、名前と実 path の組で持つ。必須は `sh`、`bash`、`zsh`、`env`、`cat`、`git`、`ruby`、`uname`、`sort`、`tail`。
欠けると preflight が失敗にする。

git は、developer dir (`xcode-select -p` の答え) の中の実体を直接置く。`/usr/bin/git` の入口は通さない。
developer dir が Xcode.app の下にある環境 (CI の runner) では、入口を通した `git status` と `git diff` が、
0 で終わったまま、拒否の字面を stderr に出した。入口が、git を探した結果を一時 dir の外に書き残そうとするためと見ている。
Command Line Tools だけの machine では、入口を通しても出なかった。

ほかの読み取りの道具 (`grep`、`uniq`、`sed`、`awk`、`find`、`xargs` など) は任意で、無ければ足さない。
`rg` は、決めた場所で解決できた実体だけを足す。

書き込みの道具 (`rm`、`touch`、`tee` など) は入れない。
`/bin/sh` のほかの interpreter が要る道具も足さない (`shasum` は perl の script なので入らない)。

### 変種

1 回の起動は 1 つの変種で行う。既定の変種は 3 つ。

| 名前 | 起動 | 既定 |
| --- | --- | --- |
| `zsh` | `/bin/zsh -f -c` | はい |
| `bash` | `/bin/bash -c` | はい |
| `sh` | `/bin/sh -c` | はい |
| `zsh-extendedglob` | `/bin/zsh -f -o extendedglob -c` | いいえ |
| `zsh-nullglob` | `/bin/zsh -f -o nullglob -c` | いいえ |
| `bash-nullglob` | `/bin/bash -O nullglob -c` | いいえ |

### guard

guard は分類器を読まない (分類器と同じ読み違いを持ち込まないため)。分類器より粗く、拒む側に寄せてある。
規則は、原文と、引用の記号を除いた写しの両方に当てる。拒む形は次のとおり。

- `..` を含む形と、`~` を含む形。位置に依らない。
- 走るときに文字列を作る形。表に無い `$`、backtick、`(` と `)`。位置に依らない。
  受ける `$` は `$'-o'` と `"${zz:--o}"` の 2 つだけ。括弧は、zsh の glob の修飾子を含む (`x(:A:h)` は親の dir を指す)。
- `&&` のほかの `&` (後ろで走らせる形、`|&`、`>&3`) と、`coproc`。
- 前が名前の字でない `/` (絶対 path、`>/x`、`{x,}/etc` など)。短い option に付いた path (`-o/x`) も拒む。
- 前が名前の字でない `=` (zsh の `=name` と `={a,b}`)。
- brace が `..` を作る形、名前や option につないだ brace、入れ子の brace。`.` で始まる glob。
- `gh`、`git remote`、`kill` の類、追従する `tail`、`find -ok`、`xargs -p` と `-o`。
- 引数が 2 つの `cd`、`chdir`、`pushd`、`popd`。
- shell の設定を変える形。`set`、`setopt`、`unsetopt`、`shopt`、`emulate`、`SHELLOPTS` と `BASHOPTS`。
  入れ子の shell (`sh`、`bash`、`zsh`) に渡す option は、`-c` と `-lc` だけを受ける。
- ASCII でない字と制御の字、行の継続、閉じない引用。

shell の設定は、変種の表だけが決める。sh と bash は、job control を立てると子を別の process group に移す
(`set -m` と `SHELLOPTS=monitor` で実測)。その子は、止める対象から外れて残った。

引用か `\` を含む語は、組み立てた後の中身を、入れ子の command として同じ規則で見る。
引用の断片ごとに見ると、`'tail '"-f x"` や `set\ -m` のように、つないで出来る command を漏らす。

例外は 2 つ。分類器の門が通す安全な redirect の 7 つ (`2>/dev/null` など) は、絶対 path と `&` の規則から外す。
外すのは、後ろが空白か区切り (`;`、`|`、`&`、`)`) か、文字列の終わりのときだけ。
入れ子の command の引用の終わりに付いた形 (`sh -c 'cat x 2>&1'`) は外さない (`>/dev/null'x'` は `/dev/nullx` を指す)。
sed と awk の script は、人が中身を確かめたものだけを表に持ち、単一引用の語の完全一致で外す (今は K2 の 1 つ)。
表の語は、ほかの command の引数でも外れる。実在しうる path になる script は足さない。

### preflight

preflight は、隔離が効いていることを走らせる前に確かめる。
否定の検査は、相手を許した profile で同じ probe が通る対照と組にする。
対照が無いと、probe が壊れていて何も起きなかった回を「拒まれた」と読み違える。

| 検査 | 否定 (拒まれること) | 対照 |
| --- | --- | --- |
| `write-outside` | 一時 dir の外への書き込み | その dir を許すと書ける |
| `read-home` | HOME の代役の dir の読み取り | 代役を外すと読める |
| `network` | 自分で開いた 127.0.0.1 の port への接続 | network を許すと届く |
| `exec-outside` | allowlist の外の偽の CLI (絶対 path と `PATH`) | その file を許すと走る |
| `exec-fixture` | fixture の中の、canary でない実行 file | その file を許すと走る |
| `exec-unlisted` | 表に無い program (`sh`、`bash`、`zsh`) | その program を許すと走る |
| `signal-outside` | 外の process への signal | signal を許すと届く |
| `env-closed` | 親の環境の変数 | 引き継ぎを許すと見える |
| `timeout-group` | 終わらない command (期限で止まり、group が残らない) | 終わる command。生きている group を「空」と読まないこと |

ほかに 2 つを見る。`guard-only-write` は、sandbox を外した profile で、語彙の中の書き込み (`sort -o`) の変化が
一時 dir に閉じること。`tools-work` は、表の道具が動き、canary が走ると印が書かれること。
`tools-work` は、道具が拒否の字面を stderr に出さないことも見る。出す道具があると、その道具を使う command が
毎回 `denied-exec` として人に出て、本物の拒否と見分けられなくなる。

guard だけの層が外に出ないと言えるのは、文字列で見える形に限る。
実行のときに組まれる文字列 (`printf` の出力を `xargs` や `sh` に渡す形など) は、guard からは見えない。

preflight が通らないとき、sandbox を適用できないときは、exit 2 で command を走らせない。素の実行には戻らない。

## 判定

### snapshot と差分

走らせる前と後に、一時 dir の全体 (`marks` を含む) の snapshot を取る。
entry ごとに、種類、mode、size、mtime (ナノ秒まで)、inode、中身の SHA-256、symlink の先を取る。
symlink はたどらない。中身を読むのは regular file だけ。

差分の種類は次のとおり。

| 種類 | 意味 |
| --- | --- |
| `created` | entry が増えた |
| `deleted` | entry が減った |
| `type` | 同じ名前で、種類が入れ替わった |
| `content` | 中身 (file) か、先 (symlink) が違う |
| `mode` | mode が違う |
| `rewrite` | 中身は同じで、mtime か inode が違う |
| `dir-mtime` | dir の mtime だけが違う |

dir の mtime だけの変化は、直下の entry の作成、削除、入れ替えで説明できれば、その変化に含める。
説明できないものは、作って消した跡かもしれないので、人に出す。

### 違反と、人に出すもの

違反は終わり方に依らず判定する。期限で止めた回も差分と印を見て、timeout を併記する。

- `fx` の変化 (dir の mtime だけの件を除く) は I1。変わった entry を 1 件ずつ `paths` に出す。
- `marks` に canary の印があれば I2。`paths` は canary の場所 (`fx/cat` など)。

人が見て決めるものは、違反に数えずに `human` に出す。

| reason | 中身 |
| --- | --- |
| `zone` | `fx` の外の区画 (`home`、`tmp`、`shim`、`tools`、`marks` の印でない entry、一時 dir の直下) の変化 |
| `dir-mtime` | 説明のつかない dir の mtime の変化 |
| `denied-exec` | 拒まれた起動と、表の道具でない名前の「見つからない」 |
| `reserved-canary` | 予約語の名前の canary が走った。数える canary と同じ回でも、I2 と並べて出す |
| `flaky` | 確かめ直しで、出た回と出ない回があった違反 |
| `non-default-variant` | 既定でない変種でだけ出た違反 |
| `unmeasured` | 測れなかった回がある |

`denied-exec` は、`read` の command が表に無い program を起動しようとした印である。
stderr と stdout の行から拾う (`2>&1` を付けた起動は、字面が stdout に回る)。最後の終了 code が 0 でも拾う。

拾う字面は、`operation not permitted`、`command not found`、`exec` の `not found`、git の `cannot run`。
shell と起動の道具 (`env`、`xargs` など) が出す `permission denied` と `no such file or directory` も拾う。
shell の行は、path の形の名前 (`./x`、`lib/x`) のものだけを拾う (`/` の無い名前の同じ字面は、redirect の失敗)。

stderr を捨てた起動 (`2>/dev/null`) は、最後の終了 code が 126 か 127 のときだけ拾う (名前は空になる)。
表の道具がこの machine に無いだけの回 (`rg` など) は、この枠から外す。`/` を含む名前は、表の道具に数えない。

止めた後に子の group が空になったと確かめられない回と、`sandbox-exec` 自体が失敗した回は「未測定」にする。
未測定の回は、差分が無くても「違反なし」に数えない。

### 終わり方

終わり方は、届いた範囲を集計するための区分で、違反の判定には使わない。stderr の照合は近似である。

`ok`、`nonzero`、`usage`、`127`、`126`、`nomatch`、`syntax`、`timeout`、`unknown` に分ける。
`ok` と `nonzero` だけを「効いた read」に数える。`unknown` は、終わりを確かめられなかった回と、signal で終わった回。

### 確かめ直し

違反の候補は、新しい一時 dir で単独にさらに 2 回走らせる。
3 回とも同じ種類 (不変条件と差分の種類の組) なら、反例に数える。違えば `flaky` として人に出す。
変わった path は比べない (pid を含む名前など、回ごとに変わりうるため)。

既定でない変種の反例は、同じ shell の既定の変種でも同じ手順で確かめる。
そこで出なければ `non-default-variant` として人に出す。

既定の変種の回で見たものは、`variant` に既定の変種の名前を付けて結果に足す。
別の種類の反例は、既定の変種で確かめた反例なので、`violations` に入り exit 1 になる。
`flaky` と、人に出すもの (`denied-exec` など) は `human` に入る。

## 数え方

「反例 0 件」も「反例 N 件」も、そのままでは結果にならない。試行を走らせる前に、次を決めておく。

- 対象の分類器は 25a12ed (版 8) に固定する。`git show` で worktree の外に取り出した file を `--classifier` で渡す。
  K1 から K3 を直しても、試行の対象は動かない。
- 既知の一覧は下の K1 から K5。原因、具体の形、期待する作用を、走らせる前に固定する。
- 実装の途中で読んで気付いた形は、走らせる前に一覧へ足す (出所は「読んで見つけた」)。
- 生成が出した反例のうち、原因が既知の一覧にあるものは「再発見」と数える。
- 原因が同じでも作用が違うもの (書き込みでなく起動、など) は、再発見と分けて報告する。
- 原因が一覧に無いものだけを「新しい反例」と数える。
- 続けるかの判断は、新しい反例の数と中身、かかった手間を見て、人が決める。

既知の一覧。K1 から K4 は、source を読んで見つけた。K5 は、検証の途中で手書きの command を走らせて見つけた。
どれも生成の結果ではない。

| 印 | command | 原因 | 期待する作用 |
| --- | --- | --- | --- |
| K1 (#755) | `uniq in.txt -c` | macOS の uniq は、最初の位置引数の後ろを option として読まない。分類器は読む | I1。`fx/-c` を作る |
| K2 (#756) | `sed -n '/a\/,/w lib/p' x` | 番地の形の照合が `\/` を区切りと読む。sed は `w lib/p` を書き込みと読む | I1。`fx/lib/p` を作る |
| K3 (#757) | `git branch --format --list x` | `--format` が次の語を値に取り、`--list` が効かなくなる (`git tag` も同じ) | I1。`fx/.git` の中に ref を作る。branch は `refs/heads/x` と `logs/refs/heads/x`、tag は `refs/tags/x` |
| K4 | `env done rm x`、`'fi' rm x` | 予約語の名前を、引用や前置きの後ろでも読み飛ばす | その名前の canary が走る。`reserved-canary` として人に出す |
| K5 | `git describe --always --dirty` | `GIT_OPTIONAL_LOCKS=0` でも index の lock を取る。index と同じ秒の mtime の file があると、index を書き直す | `fx/.git` の mtime だけが変わる (`dir-mtime` として人に出す)。file の mtime を揃える前は、I1 (`fx/.git/index`) にもなった |

K1 から K3 の形は、self-test が隔離の中で走らせ、I1 になることを確かめている (分類は通さない)。
判定は `.git/index` を特別に扱わない。用意した fixture で index の中身が変われば、I1 になる。
fixture の側で、index の書き直しが起きる原因 (古い stat と、index と同じ秒の mtime) を除いてある。
K5 の lock を作って消す跡は、`dir-mtime` として人に出る。
この扱いは試行の前提の 1 つとして結果に書き、続けるかを決めるときに人が見直す。

## 使い方

全体の memory と時間の上限は、呼ぶ側が `personal-safe-run` ([safe-run](safe-run.md)) で付ける。入口の中では包まない。

```sh
# 隔離の検査だけ (約 3 秒)。
personal-safe-run --max-footprint-mb 2048 --max-seconds 120 -- \
  scripts/probe-classifier-invariants.sh --preflight

# 1 件の command を調べる。work は worktree の外の dir。
git show 25a12ed:scripts/lib/skill_behavior_classifier.rb > "$work/classifier.rb"
personal-safe-run --max-footprint-mb 2048 --max-seconds 120 -- \
  scripts/probe-classifier-invariants.sh --out "$work/k1" \
  --classifier "$work/classifier.rb" --command 'uniq in.txt -c'
```

```text
usage: probe-classifier-invariants.sh --preflight [--out DIR]
       probe-classifier-invariants.sh --out DIR --command STRING [--variant NAME] [--classifier FILE]
```

`--command` の順序は次のとおり。

1. `--out` を確かめる。git の worktree の外で、無いか空の dir に限る。
2. command を分類する。分類は別の process で行う (分類器の file を取り替えて調べるため)。
   `--classifier` を省くと、repo の今の分類器を使う。
3. `read` でなければ、走らせずに exit 0 で終わる。
4. guard に通す。拒まれたら exit 2 で、走らせない。
5. preflight をかける。通らなければ exit 2 で、走らせない。
6. 走らせて判定し、`results.json` を書く。

`--seed`、`--count`、`--run`、`--baseline`、`--mutation` は、生成の入口と一緒に次の PR で足す。今は exit 2。

### exit code

| code | 意味 |
| --- | --- |
| 0 | 確かめた反例なし。`read` でないので走らせなかったときも 0 |
| 1 | 既定の変種で確かめた反例あり |
| 2 | 使い方の誤り、guard の拒否、分類の失敗、preflight の失敗、中断 |
| 3 | 人に出すものだけがある (未測定を含む) |

期限で止めた回も、差分と印が無ければ 0 に入る (終わり方は `runs` の `ending` に `timeout` と出る)。
想定していない失敗も 2 で、理由を 1 行出す。1 は反例のときだけ。

### results.json

`--out` の dir に `results.json` を書く。一時 dir と HOME の絶対 path は、置き換えてから書く
(`<T>`、`<R>`、`<HOME>`)。stderr と stdout も同じ。command の出力そのものは書かない。

| key | 中身 |
| --- | --- |
| `mode` | `command` か `preflight` |
| `variant` | 変種の名前 |
| `command` | 渡した command |
| `classifier` | `version` (整数) と `sha256` |
| `counts` | `generated`、`by_class` (区分から件数)、`executed`、`unmeasured` |
| `violations` | 反例。`invariant`、`command`、`variant`、`kinds`、`paths`。I2 は `canaries` も持つ |
| `human` | 人に出すもの。`reason`、`command`、`variant` と、reason ごとの中身 (`paths`、`kinds`、`zone`、`names`、`why`) |
| `runs` | 起動ごとの `variant`、`ending`、`exit_code`、`timed_out`、`unmeasured` |
| `preflight` | `--preflight` のときだけ。`ok`、`unavailable`、検査ごとの `name` と `ok`、`reasons` |

`paths` は一時 dir からの相対で書く (`fx/-c`)。`counts.executed` は command の件数で、確かめ直しの起動は数えない。
`--preflight` の file が持つ key は、`mode` と `preflight` の 2 つだけ。ほかの key は `--command` のときに書く。
`violations` と `human` の `variant` は、既定の変種の回で見たものでは、既定の変種の名前になる。

## 限界

先に、見えないものを書いておく。

- 一時 dir の外への書き込みは profile が拒み、command は失敗に見える。差分に出るのは一時 dir の中だけ。
  拒まれた字面が stderr に残れば `denied-exec` の枠に出る。字面を捨てた形は素通りする。
- `sort --compress-program` が program を起動するのは、入力が大きいときだけ。fixture の入力は小さい。
- pager と `nohup.out` の形は、端末があるときだけ起きる。ここでは端末なしで走らせる。
- group を抜けた子 (`setsid` など) と、その子が後から書く変化は、追う手段が無い。その子も sandbox の中には留まる。
  sh と bash の job control (`set -m` など) は、文字列で見える形だけを guard が拒む。
  実行のときに組まれた command から起きた回は、気付けない。その回は「測れた、違反なし」に数えられる。
- shell が終わった時点で、同じ group に残っている子は止める。その子の、後の書き込みは見えない。
  `&` と `coproc` の形は guard が拒むので、走らせない。
- 見るのは、期限の 5 秒までに起きた変化だけ。
- 子の出力は、全部を memory に取り込む。上限は、呼ぶ側が `personal-safe-run` で付ける。
- 比べる属性は、種類、mode、size、mtime、inode、中身、symlink の先まで。
  atime、ctime、xattr、ACL、flag、所有者は、比べる対象の外にある。
- fixture の index は、走らせる前に揃えてある。stat が古い index で `git diff` が行う書き直しは、測る対象から外れる。
- 読み取りを拒むのは HOME の下だけ。HOME の外の file は command から読める (network を拒むので、外へは出ない)。
- guard が拒む形は走らせないので、測る対象の外になる。
  絶対 path の command 名、`~`、`=name`、backtick、括弧、`&`、shell の設定を変える形などが当たる。
- canary が当たるのは、置いた名前だけ。
- 出力の行の照合は近似。`find` は、探す先が無いときも起動の失敗と同じ字面を出すので、`denied-exec` の枠に出る。
  `/` を含む redirect の先が無いとき (`cat < lib/nofile`) も、同じ枠に出る。
- `2>/dev/null` を付けた起動の失敗は、後ろに別の command が続くと、字面も終了 code も残らない。

範囲の外。

- `exec` の区分、gh と network に出る形。
- 設定や hook が program を指す git の fixture と、`GIT_OPTIONAL_LOCKS` を外した回。
- 端末に依る挙動、外側の `zsh -lc`、dash、GNU の道具、Ruby 3.4 の `ruby -c`。
- 自動の起票と、反例の最小化。

sandbox の中の session では走らない。Seatbelt は入れ子に適用できないためで、reviewer の sandbox の中や、
Bash の sandbox が有効な session が当たる ([codex-review-launch](codex-review-launch.md) の「問題: sandbox の入れ子」)。
そこでは `--preflight` が exit 2 で理由を出し、self-test は sandbox の要る部分 (T2・T4・T6) を skip して 1 行出す。
CI では skip せず、適用できなければ失敗にする。

## 試行の結果

生成した command での試行の結果 (件数、反例の内訳、壊した版での検出) は、次の PR でここに足す。

## やめるとき

試行を続けないと決めたら、次をまとめて外す。
分類器の本体と今の表の test には手を入れていないので、外しても挙動は変わらない。

- `scripts/probe-classifier-invariants.sh`
- `scripts/lib/probe_classifier_invariants.rb`
- `scripts/lib/probe_classifier/` (`isolation.rb`、`judge.rb`)
- `scripts/tests/probe-classifier-invariants-test.sh`
- `docs/classifier-invariants.md`
- 一覧の行 (`README.md`、`scripts/README.md`、`docs/onboarding.md`)
- `scripts/tests/c-locale-test.sh` の comment にある entrypoint の本数

`scripts/lib/probe_child.rb` は、ほかの probe と共有しているので残す。
