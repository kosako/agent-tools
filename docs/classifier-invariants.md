# Classifier Invariants (分類器の不変条件の試行)

挙動の評価の分類器 (`scripts/lib/skill_behavior_classifier.rb`) は、command を読んで区分を決める
([skill-behavior-eval](skill-behavior-eval.md) の「区分」)。その test は、形と区分を並べた表である。

この試行 (#754) は、表の代わりにルールを 1 つ決め、それを機械に確かめさせる。
ルールは「`read` と区分した command は、書かず、起動しない」。
`read` と区分した command を、隔離した一時 dir の中で実際に走らせ、前後を比べる。

command は生成器が作る。seed と件数が同じなら、同じ列になる。
入口は、列を分類し、`read` と区分された command だけを隔離の中で走らせる。
生成した command を多数走らせる試行は、手元で走らせる。CI では走らせない。

| 部品 | path | 役割 |
| --- | --- | --- |
| 入口 | `scripts/probe-classifier-invariants.sh` (`scripts/lib/probe_classifier_invariants.rb`) | 引数、順序、走らせる対象の選び方、結果の file、exit code |
| 隔離 | `scripts/lib/probe_classifier/isolation.rb` | 一時 dir、道具の表、canary、profile、環境、起動、guard、preflight |
| 判定 | `scripts/lib/probe_classifier/judge.rb` | snapshot、差分、終わり方、違反と人に出すものの分け方、確かめ直し |
| 生成器 | `scripts/lib/probe_classifier/generator.rb` | 系統とずらしの表、cell、門の外の形の表、列の作り方 |
| 変異の表 | `scripts/lib/probe_classifier/mutations.rb` | 陽性の対照のための変異 12 個と、source への当て方 |
| self-test | `scripts/tests/probe-classifier-invariants-test.sh` | T1 から T7。CI で走る |

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
- 狙いごとの dir (scene) が 4 つある (下の表)。最初の commit に入っている。
- commit が 2 つあり、`README.md` に未 commit の変更がある。
- canary の file は `cat`、`bin/grep`、`canary_begin.rb`。template を写した後に書くので、git からは追跡していない file に見える。

| scene | file | 狙い |
| --- | --- | --- |
| `pair` | `a.txt`、`b.txt` | ちょうど 2 つの file。glob が展開されて `uniq` に渡ると、2 つ目が出力の file になる |
| `sortopt` | `-oplanted.txt`、`in.txt` | `sort` の `-o` と値が 1 語になった名前。glob の展開で option になる |
| `pre` | `--pre=canary`、`a.txt` | `rg` の `--pre` と値が 1 語になった名前。値は `PATH` の canary を指す |
| `plain` | `-n`、`a.txt` | 読むだけの command の option になる名前 |

`-` で始まる名前は repo に置かない。fixture を作るときに、隔離の表から書く。

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
  受ける `$` は、下の閉じた表の 3 つだけ。括弧は、zsh の glob の修飾子を含む (`x(:A:h)` は親の dir を指す)。
- `&&` のほかの `&` (後ろで走らせる形、`|&`、`>&3`) と、`coproc`。
- 前が名前の字でない `/` (絶対 path、`>/x`、`{x,}/etc` など)。短い option に付いた path (`-o/x`) も拒む。
- 前が名前の字でない `=` (zsh の `=name` と `={a,b}`)。
- brace が `..` を作る形、名前や option につないだ brace、入れ子の brace。`.` で始まる glob。
- `gh`、`git remote`、`kill` の類、追従する `tail`、`find -ok`、`xargs -p` と `-o`。
- `while` と `until` (終わりを条件に任せる loop)。`for` は、並べた語の数だけ回るので受ける。
- awk の program の中の `|`。awk は pipe で command を起動でき、その文字列は program の中でつないで作れる
  (`"ru" "by -e …" | getline` で ruby が走った。実測)。`system` は括弧の規則が拒む。
- `ruby` に code を渡す形。受けるのは、`-c` と file、単独の `-v` と `--version`、option の無い file の並びだけ。
  `-e`、`-r`、語の無い `ruby` (stdin の script) は拒む。前に `=` や `!` が付いた名前 (`X=ruby`、git の alias の `!ruby`) も ruby として見る。
- 引数が 2 つの `cd`、`chdir`、`pushd`、`popd`。
- shell の設定を変える形。`set`、`setopt`、`unsetopt`、`shopt`、`emulate`、`SHELLOPTS` と `BASHOPTS`。
  入れ子の shell (`sh`、`bash`、`zsh`) に渡す option は、`-c` と `-lc` だけを受ける。
- ASCII でない字と制御の字、行の継続、閉じない引用。

shell の設定は、変種の表だけが決める。sh と bash は、job control を立てると子を別の process group に移す
(`set -m` と `SHELLOPTS=monitor` で実測)。その子は、止める対象から外れて残った。
ruby の code も、`Process.setsid` で同じことができる。

引用か `\` を含む語は、組み立てた後の中身を、入れ子の command として同じ規則で見る。
引用の断片ごとに見ると、`'tail '"-f x"` や `set\ -m` のように、つないで出来る command を漏らす。

受ける `$` の形は、生成器が門の外の形として出す文字列だけである。

| 形 | guard が置き換える先 |
| --- | --- |
| `$'-o'` | `-o` (閉じた環境で展開した後の語) |
| `"${zz:--o}"` | `-o` (閉じた環境で展開した後の語) |
| `RANDOM='a[$(sort -o out.txt in.txt)1]'` | `sort -o out.txt in.txt` (中で走る command) |

guard は、形を表の右の文字列に置き換えてから、ほかの規則を当てる。
消すと、`xargs "${zz:--o}" cat` の `-o` のように、展開で出来る option を見逃す。
変数を読む形 (`"${zz:--o}"`) は、その変数の名前が command のほかの所に出ないときだけ受ける。
`zz=-f` を先に置くと、同じ形が `-f` に展開されるため。

3 つ目の形は、語には展開されない。zsh は、整数の変数 (`RANDOM`) への代入で、添字の中の置き換えを走らせる。
走るのは、変数 `a` が設定済みのときだけだった (`a=1;` を前に置いた形で実測。bash と sh では走らない)。
形は、代入の語の全体で持つ。中の `$(…)` だけを受けると、ほかの位置の置き換えまで通るため。

例外は 2 つ。分類器の門が通す安全な redirect の 7 つ (`2>/dev/null` など) は、絶対 path と `&` の規則から外す。
外すのは、後ろが空白か区切り (`;`、`|`、`&`、`)`) か、文字列の終わりのときだけ。
入れ子の command の引用の終わりに付いた形 (`sh -c 'cat x 2>&1'`) は外さない (`>/dev/null'x'` は `/dev/nullx` を指す)。
sed と awk の script は、人が中身を確かめたものだけを表に持ち、単一引用の語の完全一致で外す。
今は 2 つ。K2 の形 (`/a\/,/w lib/p`) と、番地の範囲を表示するだけの形 (`/apple/,/banana/p`)。
表の語は、ほかの command の引数でも外れる。番地で始まる script は、字面の上では絶対 path になる。
足すのは、人が中身を確かめた literal だけにする。
字面の path が、どの machine にも在りそうな場所 (`/etc/…`、`/tmp/…` など) を指す script は足さない。
その path への書き込みが guard を通っても、一時 dir の外なので profile が拒む。

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
| `timeout` | 期限で止めた回。見たのは期限までの変化だけ |
| `unmeasured` | 測れなかった回がある |
| `guard-rejected` | 生成した command を guard が拒んだ。走らせていない (生成の入口だけ) |

`denied-exec` は、`read` の command が表に無い program を起動しようとした印である。
stderr と stdout の行から拾う (`2>&1` を付けた起動は、字面が stdout に回る)。最後の終了 code が 0 でも拾う。

拾う字面は、`operation not permitted`、`command not found`、`exec` の `not found`、git の `cannot run`。
shell と起動の道具 (`env`、`xargs` など) が出す `permission denied` と `no such file or directory` も拾う。
shell の行は、path の形の名前 (`./x`、`lib/x`) のものだけを拾う (`/` の無い名前の同じ字面は、redirect の失敗)。

stderr を捨てた起動 (`2>/dev/null`) は、最後の終了 code が 126 か 127 のときだけ拾う (名前は空になる)。
表の道具がこの machine に無いだけの回 (`rg` など) は、この枠から外す。`/` を含む名前は、表の道具に数えない。

次の回は「未測定」にする。未測定の回は、差分が無くても「違反なし」に数えない。

- `sandbox-exec` 自体が失敗した回 (`sandbox-error`)。
- 止めた後に、子の group が空になったと確かめられない回 (`group-not-empty`)。
- 止めた後も、子の出力の pipe を誰かが開いたままだった回 (`output-open`)。group を抜けた子が残っているときに起きる。

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

## 生成器

生成器 (`generator.rb`) は、seed と件数から command の列を作る。文字列を作るだけで、分類も実行もしない。
分類器の定数は読まない。同じ列を、今の版、変異した版、過去の版に当てるため。
系統の語は、25a12ed の分類器を読んで決め、生成器の表に写してある。

### 系統とずらし

列は、系統 (どの command か) とずらし (どう崩すか) の組を回して作る。この組を cell と呼ぶ。

系統は 11 で、分類器 (25a12ed) の次の定数と関数に当たる。`gate` は門の外の形で、11 の系統とは別枠にする。

| 系統 | 分類器の定数と関数 |
| --- | --- |
| `plain` | `PLAIN_READ`、`classify_by_name` |
| `sort` | `SORT_SPEC`、`parse_options`、`read_with_args` |
| `uniq` | `UNIQ_SPEC`、`parse_options`、`read_with_args` |
| `diff` | `read_with_args` (diff の短い option の allowlist) |
| `sed` | `SED_ADDRESS`、`SED_PRINT`、`SED_LONG_FLAGS`、`sed_call` |
| `awk` | `awk_call` |
| `find` | `find_call`、`injected_call` |
| `xargs` | `XARGS_VALUE_OPTIONS`、`xargs_call`、`injected_call` |
| `rg` | `RG_SPEC`、`RG_GLOB_WORD`、`rg_positional_globs?`、`masked_words`、`parse_options` |
| `ruby` | `RUBY_VERSION_ARGS`、`ruby_syntax_check?`、`script_file?`、`interpreter_call` |
| `git` | `GIT_READ`、`GIT_WRITE`、`GIT_GLOBAL_VALUES`、`GIT_GLOBAL_FLAGS`、`GIT_PROGRAM_OPTIONS`、`GIT_LISTING`、`classify_git`、`git_subcommand`、`git_read_option_class`、`git_listing`、`git_config` |
| `gate` | `SIMPLE_CHAR`、`DQ_ESCAPES`、`simple_command?`、`dq_end`、`scan_step` (`$'…'`)、`classify_split` (代入だけの部分) |

`plain` は、`PLAIN_READ` の 38 語のうち、`cd` を除く 37 語を基本形に持つ。`cd` は、包みと手で置いた形から出る。

ずらしは 12 ある。

| ずらし | 中身 | 系統 | 分類器の定数と関数 |
| --- | --- | --- | --- |
| `opt-after` | option を位置引数の後ろに置く | `ruby` を除く 10 | `parse_options` (位置引数の後ろの option も読む) |
| `dashdash` | `--` を挟む。4 回に 1 回は option の前に置く | `ruby` を除く 10 | `parse_options` の `--`、`sed_call`、`awk_call`、`git_listing` |
| `bundle` | option の束と、option につないだ値 | 11 の全部 | `parse_options` (束と、束の残りの値) |
| `value-next` | 値をとる option に、次の語を値として取らせる | `sort` `uniq` `sed` `awk` `find` `xargs` `rg` `git` | `parse_options` (次の語を値に取る)、`git_listing`、`xargs_call` |
| `write-form` | 書き込みの形。`read` にならない見込みの対照 | `plain` `sort` `uniq` `sed` `awk` `find` `xargs` `git` | `read_with_args`、`sed_call`、`find_call`、`git_read_option_class`、`redirect_spans` |
| `brace` | brace の展開 | 11 の全部 | `BRACE_ELEMENT`、`brace_list_at`、`expand_braces`、`classify_segment` |
| `glob` | glob の語 (`^x` を含む) | 11 の全部 | `GLOB_CHAR`、`classify_split`、`rg_positional_globs?` |
| `quote` | 名前、option、位置引数の引用 | 11 の全部 | `scan`、`Shellwords.split`、`simple_command?` |
| `prefix` | 前置き (`env`、`command` など)、引用した予約語、代入 | 11 の全部 | `PREFIX_WORDS`、`ASSIGNMENT`、`classify_split` (`}` `fi` `done`) |
| `name` | 名前の位置の path (`./cat`、`bin/grep`) | `plain` `find` `xargs` | `STANDARD_BIN_DIRS`、`classify_words` |
| `script` | sed と awk の script (手で置いた表) | `sed` `awk` | `SED_PRINT`、`awk_call` |
| `git-form` | git の subcommand と、前に置く option | `git` | `classify_git`、`git_subcommand` |

cell は 101 個ある。系統とずらしの組のうち、中身のある 97 個と、門の外の 4 個。
cell の中身は 2 種類ある。手で置いた形 (表の 1 行が 1 つの command) と、基本形 (名前、option、位置引数) を機械的に崩す形。

### 回し方

- 番号 `i` の行の cell は、cell の並びの `i mod 101` 番目。並びは、ずらしの順、その中で系統の順。門の外の 4 つは最後に置く。
- 件数が 101 以上なら、全部の cell が 1 回以上出る。
- cell の中の形は、seed と系統で決まる所から、順に回して選ぶ。件数が増えれば、表の全部の形に届く。
- 手で置いた形と基本形の両方を持つ cell は、交互に出す。同じ系統の cell は、回り始めを 5 つずつずらす。
- 行は seed と番号だけで決まり、件数には依らない (300 件の列の先頭 150 行は、150 件の列と同じ)。

operand、option、2 つ目のずらし、包みは、乱数で選ぶ。
2 つ目のずらしは、100 回のうち 36 回に足す。内訳は、前置き 8、名前の引用 8、operand の引用 7、glob 7、brace 6。
包みは、100 回のうち 60 回に足す。当たる分類器の所は、`separator_at?`、`SAFE_REDIRECTS`、`redirect_spans`、`shell_call`、
`xargs_call`、`find_call`、`injected_call`。

| 包み | 重み | 形 |
| --- | --- | --- |
| 2 つ目の部分 | 16 | `;`、`&&`、pipe、`\|\| true` で、読むだけの command をつなぐ |
| `cd DIR &&` | 8 | fixture の dir に移ってから走らせる (下の「移った先の operand」) |
| 安全な redirect | 12 | 分類器の門が通す 7 つ (`2>/dev/null` など) を後ろに付ける |
| 入れ子の shell | 14 | `sh -c`、`bash -c`、`zsh -lc`、`zsh -c` |
| xargs | 5 | `echo FILE \| xargs` の後ろに置く |
| find -exec | 5 | `find . -name FILE -exec` と `{} +` の間に置く |

operand は、fixture の中の相対 path だけ。guard が拒む語 (`set`、`kill`、`gh`、`while` など) は、名前にも pattern にも使わない。
生成した全件が guard を通ることは、self-test が 4 つの seed の 4040 行で確かめる。

### 移った先の operand

包みの `cd DIR &&` の DIR は、`.` か、fixture の下の dir (`lib`、`pair`、`plain`、`sortopt`、`pre`)。7 回のうち 5 回が下の dir になる。
root からの名前 (`README.md`、`lib/median.rb`) は、移った先には無い。そのまま包むと、中の command は file を開けずに終わる。
そこで、下の dir に移る行は、operand を、その dir に在る名前で埋める。

- file を指す所は、その dir の file (`pair` なら `a.txt` と `b.txt`)。dir を指す所は `.`。
- glob は `*`、`./*`、`^x`、`?*`、`[a-z]*`。`-` で始まる名前は字では出さず、glob の展開でだけ届かせる。
- 表の形が字で持つ、`/` の無い glob (`*.txt` など) は、そのまま移った先で展開させる。

表の形が、root からの名前を字で持つときは、移さずに `cd . &&` にする。
当たるのは、`/` を含む語 (`lib/x`、`./cat`、sed の番地)、root の file と dir の名前 (`x`、`lib` など)、`cd` で始まる形。
rb の file を指す所を持つ形も移さない (rb の file は、root からの名前で指す)。
決めるのは、埋める前の表の形と、移る先だけ。出来た command の文字列は見ない。

seed 754 の 2000 件では、包みが下の dir を引く行は 121 行で、102 行が移り、19 行が `cd . &&` になる。
手で置いた `cd DIR && …` の形の後ろには、fixture の名前を持つ部分 (`cat x`、`echo in.txt`) をつながない。前に回す。
self-test は、`cd DIR &&` で始まる行の後ろに、その dir に無い fixture の名前が残らないことを見る。

### 門の外の形

分類器の門 (`simple_command?`) が閉じる形と、代入だけの部分は、閉じた表の文字列をそのまま出す。
2 つ目のずらしも包みも足さない。門の変異 (`dq-dollar`、`assignment-only-read`) の対照に使う。

| cell | 文字列 |
| --- | --- |
| `gate/ansi-dollar` | `sort $'-o' out.txt in.txt`、`sort in.txt $'-o' out.txt` |
| `gate/dq-dollar` | `sort "${zz:--o}" out.txt in.txt`、`sort in.txt "${zz:--o}" out.txt` |
| `gate/assignment` | `n=1`、`cat in.txt; n=1`、`n=1; cat in.txt`、`n=1; m=2` |
| `gate/substitution` | `a=1; RANDOM='a[$(sort -o out.txt in.txt)1]'`、`RANDOM='a[$(sort -o out.txt in.txt)1]'` |

`$` を含む形は、guard の表にある形だけ。環境の変数の参照は出さない。
門の外の形は、101 行に 4 行 (約 4%) の割合で出る。設計の見込み (約 5%) より少ない。
cell として回す順番に入れたためで、件数が 101 以上なら 4 つとも出る。

### 乱数と digest

乱数は、SHA-256 から取る整数だけを使う。入力は、seed、行の番号、札 (何を選ぶか)、その札を引いた回数。
hash の先頭の 12 桁 (48 bit) を整数にし、候補の数で割った余りで選ぶ。
`shuffle`、`sample`、`rand`、`Object#hash`、時刻、pid は使わない。
同じ seed と件数なら、Ruby の版に依らず、byte まで同じ列になる。

列の digest は、command を 1 行ずつ並べた text の SHA-256 で、`results.json` の `digest` に出る。
self-test は、seed 754 の 150 件と 2000 件の digest を、固定値と比べる (CI の 2 つの Ruby で同じ値になることを見る)。
seed 755 の 150 件の digest も固定する。seed が、cell の中の回り始めと、行ごとの乱数の両方に届くことを見るため。
表か選び方を変えると、この値も変わる。

## 陽性の対照

「反例 0 件」は、判定や生成器が足りないだけでも起きる。
そこで、分類器をわざと壊した版を調べ、試行が違反を見つけるかを見る。対照は 2 種類ある。

- 変異。分類器の source の 1 か所を置き換え、過去に塞いだ穴の型を 1 つ開け直す (`--mutation NAME`)。
- 過去の版。穴を塞ぐ前の commit の file を調べ、試行の対象の版を比べる相手にする (`--baseline FILE`)。

どちらも、走らせるのは差分の組だけ。
差分の組は、壊した版が `read` と区分し、比べる相手が `read` と区分しない command である。
両方が `read` と言う command は、壊したこととは関係が無いので走らせない。

対照は 2 段で確かめる。

1. witness を `--command` で直接走らせる。違反が出なければ、判定か fixture が足りない。
2. 同じ seed と件数の生成で走らせる。差分の組が 0 件か、どれも違反にならなければ、生成器が足りない。

### 変異の表

変異の表 (`mutations.rb`) は、試行で固定した版 (25a12ed) の source に当てる。
置き換える文字列が source に 1 回だけ出るときに限って当てる。0 回や 2 回以上なら、exit 2 で止まる。
repo の今の分類器に当たるかどうかは、CI では見ない。分類器を直す PR が、この表の保守を負わないようにするため。

次の表は、試行を走らせる前の見込みである。
witness は、25a12ed の file に変異を当て、`--command` と `--mutation` で走らせて確かめた。
確かめた環境は、macOS 26.7.3、zsh 5.9、bash 3.2.57、git 2.54.0、ripgrep 15.2.0。道具の版が変われば、測り直す。
どの witness も、変異を当てる前の版では `read` にならず、走らない。

| 変異 | 置き換えの要旨 | 不変条件 | 要る道具 | 見る変種 | 出方の見込み | witness |
| --- | --- | --- | --- | --- | --- | --- |
| `plain-read-sort` | `PLAIN_READ` に `sort` を足す。書き込みの option を持つ command が、名前だけで `read` になる | I1 | なし | `zsh` | 反例 (exit 1) | `sort -o out.txt in.txt`、`sort in.txt -o out.txt` |
| `uniq-output-operand` | uniq の 2 つ目の位置引数 (出力の file) を見ない | I1 | なし | `zsh` | 反例 (exit 1) | `uniq in.txt out.txt`、`uniq - out.txt` |
| `uniq-spec-drift` | `UNIQ_SPEC` で、値をとらない `-c` を、値をとる字に取り違える | I1 | なし | `zsh` | 反例 (exit 1) | `uniq -c in.txt out.txt` |
| `find-delete` | find の `-delete` を見ない | I1 | なし | `zsh` | 反例 (exit 1) | `find . -name x -delete`、`find lib -name median.rb -delete` |
| `git-output-option` | git の読み取りの subcommand の `--output` を見ない | I1 | なし | `zsh` | 反例 (exit 1) | `git log --output=out.txt`、`git diff --output=out.txt` |
| `brace-expansion-off` | brace を展開せずに区分する | I1 | なし | `zsh` | 反例 (exit 1) | `sort {-o,out.txt} in.txt`、`uniq {in.txt,out.txt}` |
| `glob-floor-off` | 引用の外の glob を、展開の前の語のまま区分する | I1 | なし | `zsh` | 反例 (exit 1) | `uniq pair/*`、`cd sortopt && sort *` |
| `dq-dollar` | 門が、二重引用の中の `$` を通す | I1 | なし | `zsh` | 反例 (exit 1) | `sort "${zz:--o}" out.txt in.txt` |
| `assignment-only-read` | 代入だけの部分を `read` にする | I1 | なし | `zsh` | 反例 (exit 1)。zsh だけで出る | `a=1; RANDOM='a[$(sort -o out.txt in.txt)1]'` |
| `custom-path-floor-off` | 標準の bin の外の path の command を、名前で区分する | I2 | なし | `zsh` | 反例 (exit 1) | `./cat x`、`bin/grep apple in.txt` |
| `rg-glob-word-any` | rg の位置引数の glob の語の、先頭の字の絞りを外す | I2 | `rg` | `zsh` | 反例 (exit 1) | `cd pre && rg median *` |
| `caret-not-glob` | 引用の外の `^` を、glob の字として扱わない (#751 の穴) | I1 | なし | `zsh-extendedglob` | 人に出す (`non-default-variant`、exit 3) | `cd pair && uniq ^x`、`cd sortopt && sort ^x` |

`assignment-only-read` の witness は、bash と sh では走らない (同じ代入で、置き換えを走らせないため)。
`caret-not-glob` の witness は、既定の変種 (`zsh`、`bash`、`sh`) では何も変えない。
`rg-glob-word-any` は、`rg` がこの machine に無ければ「測れない」になる。

### 対照の結果

対照の run は、`results.json` の `control` に結果を書く。

| `result` | 意味 |
| --- | --- |
| `found` | 差分の組に、確かめた反例が 1 つ以上ある。既定でない変種の run では、その変種だけで確かめた違反も数える |
| `missed` | 差分の組が 0 件か、どの組も違反にならなかった |
| `unmeasurable` | 変異が要る道具がこの machine に無い。または、差分の組が在るのに、測れた組が 1 つも無い |

既定でない変種だけで出る違反は、反例に数えずに人に出す (exit 3)。対照の結果では `found` に数える。
`caret-not-glob` のように、既定でない変種で見る変異を「見つけた」と言えるようにするため。
exit code の意味は、対照の run でも同じにする。`found` でも、既定の変種で確かめた反例が無ければ 1 にはならない。
dry-run では走らせていないので、`result` は `null` で、差分の組の件数だけを出す。

変異の見込み (`expected`) と違う変種で走らせると、差分の組が在っても違反は出ず、`missed` になりうる。
結果を読むときは、`variant` と `expected` の `variant` を見比べる。

`found` は、差分の組に違反が 1 つでもあれば付く。違反の原因が、当てた変異かどうかは見ない。
command が差分の組に入るのは変異のためでも、書き込みは別の穴から起きることがある
(`glob-floor-off` の差分の組に、下の K2 と同じ `fx/lib/p` の作成が入っていた)。
結果を読むときは、束の path が、変異の狙い (上の表の witness が変える所) と合うかも見る。

### 対照に要る件数

対照には件数が要る。差分の組は列の一部で、違反になる形は、そのまた一部にしか出ない。
件数が足りないと、差分の組が 0 件か、書かない形だけになり、`missed` になる。
行は seed と番号だけで決まるので、最初の違反の行の番号より多い件数なら、`found` になる。

次の表は、seed 754 で測った数。変種は、変異の表の「見る変種」。

| 変異 | 2000 件の差分の組 | `found` になる最小の件数 |
| --- | --- | --- |
| `plain-read-sort` | 88 | 22 |
| `uniq-output-operand` | 63 | 42 |
| `uniq-spec-drift` | 11 | 50 |
| `find-delete` | 15 | 146 |
| `git-output-option` | 14 | 47 |
| `brace-expansion-off` | 35 | 50 |
| `glob-floor-off` | 172 | 161 |
| `dq-dollar` | 19 | 99 |
| `assignment-only-read` | 38 | 101 |
| `custom-path-floor-off` | 56 | 92 |
| `rg-glob-word-any` | 9 | 168 |
| `caret-not-glob` | 23 | 363 |

12 個とも `found` になるのは、363 件から。既定の 200 件では、`caret-not-glob` が `missed` になる。
150 件では、`glob-floor-off` と `rg-glob-word-any` も `missed` になる。
過去の版の対照 (cace62e を調べ、25a12ed と比べる) は、差分の組が 2000 件で 23。
`zsh-extendedglob` では 363 件から `found` になり、`zsh` では 2000 件でも `missed` だった (既定の変種では出ない穴のため)。
対照は、2000 件で走らせる。走るのは差分の組だけなので、変異 1 個が 6 秒から 50 秒で終わった。

測った条件。分類器は 25a12ed の file (SHA-256 の先頭は `48f88ba5380ca216`)。
生成器は、seed 754 の 2000 件の digest が `7cca8420b41387eb…` の版。道具の版は、上の「変異の表」と同じ。
表か選び方を変えると列が変わるので、この数も測り直す。

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
K1 から K3 は、試行の後に分類器の版 9 で直した (#755 から #757)。今の分類器では、どれも `read` にならない。
判定は `.git/index` を特別に扱わない。用意した fixture で index の中身が変われば、I1 になる。
fixture の側で、index の書き直しが起きる原因 (古い stat と、index と同じ秒の mtime) を除いてある。
K5 の lock を作って消す跡は、`dir-mtime` として人に出る。
この扱いは試行の前提の 1 つとして結果に書き、続けるかを決めるときに人が見直す。

## 使い方

全体の memory と時間の上限は、呼ぶ側が `personal-safe-run` ([safe-run](safe-run.md)) で付ける。入口の中では包まない。

```text
usage: probe-classifier-invariants.sh --preflight [--out DIR]
       probe-classifier-invariants.sh --out DIR --command STRING [--variant NAME] [--classifier FILE] [--mutation NAME]
       probe-classifier-invariants.sh --out DIR [--seed N] [--count N] [--variant NAME] [--classifier FILE]
                                      [--baseline FILE | --mutation NAME] [--run]
```

入口は 3 つある。`--preflight` は、隔離の検査だけをかける。`--command` は、1 件の command を調べる。
どちらも無ければ生成の入口で、seed と件数から列を作って調べる。

| 引数 | 意味 |
| --- | --- |
| `--seed N` | 生成の seed。既定は 754。0 から 999999999 の整数 |
| `--count N` | 生成する件数。既定は 200。1 から 5000 の整数 |
| `--run` | 走らせる対象の command を、隔離の中で走らせる。無ければ dry-run で、何も走らせない |
| `--variant NAME` | 走らせる shell の変種。既定は `zsh` |
| `--classifier FILE` | 調べる分類器。省くと、repo の今の分類器 |
| `--baseline FILE` | 比べる相手の分類器。渡すと、差分の組だけを走らせる |
| `--mutation NAME` | 調べる分類器の source に変異を 1 つ当てた版を調べる。比べる相手は、当てる前の版 |
| `--out DIR` | 結果を書く dir。git の worktree の外で、無いか空の dir。書けない所は受けない |

`--baseline` と `--mutation` は、同時には渡せない。
`--command` に足せるのは、`--variant`、`--classifier`、`--mutation` だけ。

### 例

`work` は、worktree の外の dir。分類器の file は、`git show` でそこに取り出す。

```sh
# 隔離の検査だけ (約 3 秒)。
personal-safe-run --max-footprint-mb 2048 --max-seconds 120 -- \
  scripts/probe-classifier-invariants.sh --preflight

# 試行の対象の分類器を取り出す。
git show 25a12ed:scripts/lib/skill_behavior_classifier.rb > "$work/classifier.rb"

# 1 件の command を調べる。
personal-safe-run --max-footprint-mb 2048 --max-seconds 120 -- \
  scripts/probe-classifier-invariants.sh --out "$work/k1" \
  --classifier "$work/classifier.rb" --command 'uniq in.txt -c'

# dry-run。生成して分類し、件数と cell の表を書く。何も走らせない。
scripts/probe-classifier-invariants.sh --out "$work/dry" \
  --classifier "$work/classifier.rb" --seed 754 --count 150

# run。read と区分された command を、全部走らせる。
personal-safe-run --max-footprint-mb 2048 --max-seconds 300 -- \
  scripts/probe-classifier-invariants.sh --out "$work/run" \
  --classifier "$work/classifier.rb" --seed 754 --count 150 --run

# 変異の対照。差分の組だけを走らせる。件数は 2000 にする (少ないと missed になる。上の「対照に要る件数」)。
personal-safe-run --max-footprint-mb 2048 --max-seconds 300 -- \
  scripts/probe-classifier-invariants.sh --out "$work/m1" \
  --classifier "$work/classifier.rb" --mutation plain-read-sort --seed 754 --count 2000 --run

# 過去の版の対照。調べるのは過去の版で、比べる相手は試行の対象の版。
git show cace62e:scripts/lib/skill_behavior_classifier.rb > "$work/old.rb"
personal-safe-run --max-footprint-mb 2048 --max-seconds 300 -- \
  scripts/probe-classifier-invariants.sh --out "$work/old" \
  --classifier "$work/old.rb" --baseline "$work/classifier.rb" \
  --variant zsh-extendedglob --seed 754 --count 2000 --run

# witness を直接確かめる。変異した版で分類し、read なら走らせる。
personal-safe-run --max-footprint-mb 2048 --max-seconds 120 -- \
  scripts/probe-classifier-invariants.sh --out "$work/w1" \
  --classifier "$work/classifier.rb" --mutation plain-read-sort --command 'sort -o out.txt in.txt'
```

### 1 件の command の順序

1. `--out` を確かめる。git の worktree の外で、無いか空の dir に限る。
   書けない所も、ここで exit 2 にする (下の「出力先の検査」)。
2. command を分類する。分類は別の process で行う (分類器の file を取り替えて調べるため)。
   `--classifier` を省くと、repo の今の分類器を使う。`--mutation` があれば、変異を当てた版で分類する。
3. `read` でなければ、走らせずに exit 0 で終わる。
4. guard に通す。拒まれたら exit 2 で、走らせない。
5. preflight をかける。通らなければ exit 2 で、走らせない。
6. 走らせて判定し、`results.json` を書く。

### 生成の入口の順序

1. `--out` を確かめる。
2. seed と件数から列を作る。
3. `--mutation` があれば、調べる分類器の source に変異を当て、worktree の外の一時 dir に書く。終わりに消す。
4. 列を分類する。分類器の file ごとに 1 つの子 process を起こし、全件を分類する。
   子が失敗した、知らない区分を返した、件数が合わない、のどれかなら exit 2。
5. 走らせる対象を選ぶ。相手が無ければ、`read` と区分された全件。相手が在れば、差分の組だけ。
6. 対象を guard に通す。拒まれた command は走らせず、`guard-rejected` として人に出す。
   生成器は guard を通る形だけを出すので、拒まれた件は生成器の不具合の印になる (stderr にも 1 行出す)。
7. `--run` が無ければ、ここで 2 つの file を書いて終わる (dry-run)。sandbox は要らない。
8. `--run` があれば、preflight を 1 回かける。通らなければ exit 2 で、何も走らせず、file も書かない。
9. 対象を 1 件ずつ走らせて判定する。確かめ直しと、既定でない変種の確認は、1 件の command と同じ。
10. `corpus.jsonl` と `results.json` を書く。

command を走らせる道は、guard と profile の両方がかかる 1 つだけにしてある。dry-run は、隔離の session を開かない。

### 出力先の検査

`--out` は、どの入口でも、何かを読んだり走らせたりする前に確かめる。

- git の worktree と `.git` の外であること。結果を tracked にしないため。
- 無いか、空の dir であること。
- 書けること。今ある最も近い dir (`--out` 自身か、その祖先) が、書ける dir であること。

結果の file を書くのは、走らせた後である。書けない出力先を先に止めないと、走らせた分が残らない
(2000 件の run は、約 100 秒かかる)。
検査は権限を見るだけで、dir は作らない。止まる道では、何も書かない。
後から変わった権限や、容量の不足は、書く所で分かる (exit 2)。

走らせている間の途中経過は、stderr に出す (10 行ほど)。
stdout には、件数、区分ごとの件数、対照の結果、行の coverage、束ねた反例と人に出すものを出す。
束は、cell、不変条件か理由、差分の種類、path が同じ行をまとめたもの。
代表は最も短い command で、行に件数 (`x3`)、番号 (`#21`)、cell を付ける。
stdout に出す束は、反例と人に出すもののそれぞれ 30 個まで。残りは `results.json` にある。

### exit code

| code | 意味 |
| --- | --- |
| 0 | 確かめた反例なし。`read` でないので走らせなかったときも、dry-run で人に出すものが無いときも 0 |
| 1 | 既定の変種で確かめた反例あり |
| 2 | 使い方の誤り、guard の拒否 (1 件の command)、分類の失敗、当たらない変異、preflight の失敗、中断 |
| 3 | 人に出すものだけがある (未測定、期限で止めた回、guard が拒んだ生成の command を含む) |

期限で止めた回は、違反が無くても `timeout` として人に出し、3 になる (見たのは期限までの変化だけのため)。
想定していない失敗も 2 で、理由を 1 行出す。1 は反例のときだけ。

生成の run も、1 件の command と同じ意味にする。未測定や `timeout` が 1 件でもあれば、反例が無くても 3 になる。
対照の run も同じ意味で、`control` の `result` は exit code を変えない。
dry-run は何も走らせないので、1 にはならない。guard が拒んだ生成の command があれば 3、無ければ 0。

### results.json

`--out` の dir に `results.json` を書く。一時 dir と HOME の絶対 path は、置き換えてから書く
(`<T>`、`<R>`、`<HOME>`)。stderr と stdout も同じ。command の出力そのものは書かない。
引数で渡した場所も、同じように置き換える。`--out` は `<OUT>`、`--classifier` と `--baseline` の file は `<classifier>` と
`<baseline>`、その file のある dir は `<classifier-dir>` と `<baseline-dir>` になる。
走らせない command は guard を通らないまま `results.json` に写るので、絶対 path を持ちうる。
表に無い場所の絶対 path (command に自分で書いたもの) は、そのまま残る。

置き換えは、字の並びで行う近似である。表の path の直後が次のどれかのときに、名前に替える。

- `/`、文字列の終わり、名前の字でない字 (空白、引用、shell の区切り、ASCII でない字など)。
- `.` の並びの後ろが、文字列の終わりか、名前の字でも `/` でもない字 (文の終わりの `.`)。

名前の字は、英数字と `_ + @ % ~ -` と `.`。これが続く path は、別の名前とみなして残す
(`--out` が `/t/out` のときの `/t/out-other` や `/t/out./x`)。
漏らさない側に寄せてあるので、別の path の一部が替わることがある。

- 引用と `\` は読まない。空白を含む別の名前 (`'/t/out x'`) は、前の部分が替わる。
- 前の側は見ない。別の path の途中に表の path と同じ並びがあれば、その部分が替わる。

表に無い書き方 (`/t/./out`、大文字と小文字だけが違う形) は見分けない。
`--out` の dir と、分類器の file の場所も、どこにも書かない (分類器は、版と hash で残す)。

| key | 入口 | 中身 |
| --- | --- | --- |
| `mode` | 全部 | `dry-run`、`run`、`command`、`preflight` のどれか |
| `variant` | command、生成 | 変種の名前 |
| `command` | command | 渡した command |
| `seed`、`count` | 生成 | 生成の seed と件数 |
| `digest` | 生成 | 列の digest (上の「乱数と digest」) |
| `timeout` | 生成 | 1 回の起動の期限 (秒) |
| `classifier` | command、生成 | `version` (整数) と `sha256`。`--mutation` のときの `sha256` は、変異を当てる前の file のもの |
| `baseline` | 生成 | `--baseline` のときだけ。`version` と `sha256` |
| `mutation`、`mutated_sha256` | command、生成 | `--mutation` のときだけ。変異の名前と、変異を当てた source の SHA-256 |
| `counts` | command、生成 | `generated`、`by_class` (区分から件数)、`executed`、`unmeasured`。生成は `selected` と `guard_rejected` も持つ |
| `control` | 生成 | `--baseline` か `--mutation` のときだけ (下の表) |
| `violations` | command、生成 | 反例。`invariant`、`command`、`variant`、`kinds`、`paths`。I2 は `canaries` も持つ。生成は `index` と `cell` も持つ |
| `human` | command、生成 | 人に出すもの。`reason`、`command`、`variant` と、reason ごとの中身 (`paths`、`kinds`、`zone`、`names`、`why`)。生成は `index` と `cell` も持つ |
| `violation_groups`、`human_groups` | 生成 | 束ねた行。束の代表の行に、件数の `count` を足した形 |
| `cells` | 生成 | cell ごとの表 (下の表)。101 行で、生成していない cell の行も持つ |
| `coverage` | 生成 | 分類器の行の coverage (下の表) |
| `runs` | command、生成 | 起動ごとの `variant`、`ending`、`exit_code`、`timed_out`、`unmeasured`。生成は `index` も持つ |
| `tools_missing` | 生成 | run のときだけ。この machine で足せなかった道具の名前から理由 |
| `preflight` | preflight | `ok`、`unavailable`、検査ごとの `name` と `ok`、`reasons` |

`paths` は一時 dir からの相対で書く (`fx/-c`)。`counts.executed` は command の件数で、確かめ直しの起動は数えない。
`--preflight` の file が持つ key は、`mode` と `preflight` の 2 つだけ。
`violations` と `human` の `variant` は、既定の変種の回で見たものでは、既定の変種の名前になる。
`counts.by_class` は、調べる版の区分で数える (`--mutation` のときは、変異を当てた版)。
`counts.selected` は走らせる対象の件数で、`guard_rejected` は、そのうち guard が拒んだ件数。

`control` の key。

| key | 中身 |
| --- | --- |
| `pairs` | 差分の組の件数 |
| `result` | `found`、`missed`、`unmeasurable` のどれか (上の「対照の結果」)。dry-run では `null` |
| `confirmed` | 差分の組のうち、反例になった command の件数 |
| `variant_only` | 差分の組のうち、既定でない変種だけで違反になった command の件数 |
| `indexes` | 差分の組の番号 |
| `expected` | `--mutation` のときだけ。変異の見込み (`invariant`、`variant`、`expect`、`needs`) |
| `needs_missing` | `--mutation` の run のときだけ。`needs` の道具のうち、この machine に無いもの |

`cells` の行の key。届いた範囲を見るための表である。

| key | 中身 |
| --- | --- |
| `cell` | cell の名前 (`系統/ずらし`) |
| `generated` | 生成した件数 |
| `read` | 調べる版が `read` と区分した件数 |
| `selected` | 走らせる対象になった件数 |
| `executed` | 走らせた件数 |
| `effective` | 最初の起動が `ok` か `nonzero` で終わった件数 (効いた read) |
| `endings` | 最初の起動の終わり方から件数 |
| `violations` | 反例のあった command の件数 |
| `human` | 人に出すもののあった command の件数 |

`coverage` の key。分類だけを行う子 process が、標準の `Coverage` で、分類器の file の行ごとの回数を取る。

| key | 中身 |
| --- | --- |
| `lines` | 実行できる行の数 |
| `load` | file の読み込みで通った行 (`def` と定数の行) |
| `all` | 全件の分類で通った行 (読み込みの後に回数が増えた行) |
| `read` | `read` と区分した command の分類で通った行 |

行の数え方は Ruby の版で違うので、同じ版の中で比べる。`--mutation` のときは、変異を当てた file の行を数える。
`Coverage` が file を追えなかったときは `null` になる。

### corpus.jsonl

生成の入口は、`--out` の dir に `corpus.jsonl` も書く。dry-run でも run でも書く。
1 行が 1 件で、key は `index`、`command`、`cell`、`class` の順。
`class` は、調べる版の区分 (`--mutation` のときは、変異を当てた版)。
同じ seed、件数、分類器なら、byte まで同じ file になる。1 件の command と `--preflight` では書かない。

## 限界

先に、見えないものを書いておく。

- 一時 dir の外への書き込みは profile が拒み、command は失敗に見える。差分に出るのは一時 dir の中だけ。
  拒まれた字面が stderr に残れば `denied-exec` の枠に出る。字面を捨てた形は素通りする。
- `sort --compress-program` が program を起動するのは、入力が大きいときだけ。fixture の入力は小さい。
- pager と `nohup.out` の形は、端末があるときだけ起きる。ここでは端末なしで走らせる。
- group を抜けた子 (`setsid` など) と、その子が後から書く変化は、追う手段が無い。その子も sandbox の中には留まる。
  出力を開いたまま残った子は、その回を未測定 (`output-open`) にして拾う。出力を閉じてから残る子は拾えない。
  ruby に code を渡す形は guard が拒むが、file に書かれた code を `ruby FILE` で走らせる形は通る。
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

生成と対照の限界。

- 生成器が出すのは、表にある形と、その機械的な崩しだけ。表に無い command と option には届かない。
- 系統の語は、25a12ed の分類器から写した。分類器に語を足しても、生成器の表には入らない。
- 変異の対照が見るのは、差分の組だけ。壊した版と比べる相手が同じ区分を返す command は、対照からは見えない。
- 差分の組が違反にならない理由は、対照からは分からない (書かない形、変種の違い、fixture の不足のどれもありうる)。
- 変異の witness と見込みは、上に書いた道具の版で確かめた。版が変われば、出方が変わりうる。
- 行の coverage は行の単位で、分岐は見ない。通った行が、正しく区分したことまでは言わない。
- 前置きの cell は、`env builtin cat` のように、表に無い名前を起動する形も出す。
  その回は `denied-exec` として人に出る (K4 と同じ原因)。`read` の全件を走らせる run は、exit 0 になりにくい。
- 生成の件数の上限は 5000。子の出力の取り込みの上限は、生成の run でも足していない。
  生成器の operand は、fixture の小さい file だけを指す。
- 生成の run が途中で止まると (中断、想定外の失敗)、file を書かない。走らせ直す。
- 出力先の検査が見るのは、権限だけ。容量の不足などで書けない出力先は、走らせた後の、書く所で初めて分かる。
- 包みの `cd` で移った先でも、名前の付いた glob (`*.md` など) は、合う file が無ければ展開されない。
  その行は、`nomatch` か、file が無い失敗で終わる。

範囲の外。

- `exec` の区分、gh と network に出る形。
- 設定や hook が program を指す git の fixture と、`GIT_OPTIONAL_LOCKS` を外した回。
- 端末に依る挙動、外側の `zsh -lc`、dash、GNU の道具、Ruby 3.4 の `ruby -c`。
- 自動の起票と、反例の最小化。

sandbox の中の session では走らない。Seatbelt は入れ子に適用できないためで、reviewer の sandbox の中や、
Bash の sandbox が有効な session が当たる ([codex-review-launch](codex-review-launch.md) の「問題: sandbox の入れ子」)。
そこでは `--preflight` が exit 2 で理由を出し、self-test は sandbox の要る部分 (T2・T4・T6) を skip して 1 行出す。
CI では skip せず、適用できなければ失敗にする。
dry-run は sandbox を使わないので、そこでも動く。`--run` と、`read` と区分された 1 件の command は、exit 2 で走らない。

## 試行の結果

2026-11-23 に走らせた。走らせたのは、PR #759 の最終の版 (commit `5e8caf8`。merge した `956c901` と tree が同じ)。
続けるかは、この結果を見て人が決める。

### 仮定

| 項目 | 値 |
| --- | --- |
| machine | macOS 26.7.3 (arm64) |
| 道具 | zsh 5.9、bash 3.2.57、ruby 2.6.10、git 2.54.0、ripgrep 15.2.0。ほかは macOS の標準 |
| 環境 | `GIT_OPTIONAL_LOCKS=0`、端末なし、network なし、閉じた環境 |
| fixture | 上の「一時 dir と fixture」の初期状態。index は揃えてある |
| 期限 | 1 件 5 秒 |
| 表に無い道具 | `shasum` (perl の script のため) |

### 探索の境界

seed は 754、件数は変種ごとに 2000、cell は 101 個。変種は 6 つで、列はどれも同じ。
列の digest は `7cca8420b41387eb804267c73c5822bf9d14c505b9225b760bc54b192efcc9df`。
調べた分類器は 25a12ed (版 8)。file の SHA-256 は `48f88ba5380ca2160bd48f3bd22f7af3b46be906d94bfc54043955c7f228a124`。

区分は read 1107、unknown 632、file-write 232、exec 15、git-write 14。
read の 1107 件を、変種ごとに全部走らせた。guard の拒否も、未測定も 0 件だった。

### 届いた範囲

系統ごとの、read の件数と、効いた件数 (終わり方が `ok` か `nonzero`。`zsh` の run)。source との対応は、上の「系統」の表。

| 系統 | 生成 | read | 効いた | 反例 |
| --- | --- | --- | --- | --- |
| plain | 179 | 133 | 116 | 0 |
| sort | 179 | 96 | 96 | 0 |
| uniq | 179 | 73 | 64 | 6 |
| diff | 139 | 76 | 67 | 0 |
| sed | 198 | 87 | 85 | 13 |
| awk | 198 | 107 | 104 | 0 |
| find | 198 | 120 | 120 | 0 |
| xargs | 198 | 127 | 124 | 0 |
| rg | 159 | 128 | 128 | 0 |
| git | 198 | 130 | 130 | 4 |
| ruby | 99 | 30 | 30 | 0 |
| 門の外 | 76 | 0 | 0 | 0 |

101 個の cell のうち、74 個で read の行が走った。残りの 27 個は、25a12ed が read と区分する行が無い cell
(書き込みの形、引用の外の glob、名前の位置、門の外の形など)。変異の対照は、ここの行を使う。
分類器の行は 771 行。読み込みだけで通るのは 127 行。分類で通ったのは 429 行で、そのうち read の command だけで通ったのは 348 行。
`ok` と `nonzero` の内訳は、変種の間と、前の下見の run との間で 1 件ずつずれた (理由は調べていない。反例には関わらない)。

### 反例

6 つの変種とも 23 件だった。行の番号、差分の種類、変わった path の 3 つの組は、6 つの `results.json` で一致した
(script で照合した)。仕分けの規則は、走らせる前に script に書いて固定した。

| 分類 | 件数 | 中身 |
| --- | --- | --- |
| K1 の再発見 | 6 | `uniq` の位置引数の後ろの option。`fx/--count` などを作る |
| K2 の再発見 | 13 | sed の番地の `\/`。`fx/lib/p` を作る |
| K3 の再発見 | 4 | `git branch` と `git tag` の `--format` か `--sort` の後ろの `--list` か `-l`。ref を作る |
| 同じ原因で、作用が違うもの | 0 | |
| 新しい反例 | 0 | |

K1 から K3 の形は、生成器の語彙に入れてある。再発見は、判定と語彙がつながっていることの確かめで、発見ではない。

### 人に出すもの

`zsh` の run で 93 件。bash と sh では 94 件。

| 理由 | 件数 | 中身 |
| --- | --- | --- |
| `reserved-canary` (K4) | 88 | 予約語の名前の canary。前置きの cell だけで出た |
| `dir-mtime` (K5) | 1 | `git describe --always --dirty` |
| `dir-mtime` (一覧に無い) | 2 | `sort -S 1 -T .`。`-T` の dir に一時 file を作って消す |
| `denied-exec` (一覧に無い) | 1 | `xargs -- -I {} cat {}`。`--` の後ろの `-I` を program の名前として起動しようとする |
| `denied-exec` (K4 と同じ原因) | 1 (bash と sh では 2) | `env exec awk …`。前置きの後ろの `exec` を読み飛ばす |

一覧に無い 2 つは、I1 と I2 の反例には当たらない (走らせた前後の tree は同じで、canary も走っていない)。
`-T` は、`-S` が小さいときにだけ一時 file を作った。`-T` の無い形では、`TMPDIR` に作った。
`xargs` の形は、`-I` という名前の program が `PATH` に在れば走る (K4 と同じ性質)。

### 陽性の対照

変異 12 個は、見込みの変種で全部 `found` だった。差分の組の数は、上の「対照に要る件数」の表と同じ。
最初に違反が出た行の番号 (0 から) に 1 を足した数も、表の「最小の件数」と同じ。
過去の版 (cace62e を調べ、25a12ed と比べる) は、差分の組 23 件。`zsh-extendedglob` では `found` (4 件)、`zsh` では `missed`。
その穴 (#751) は、`EXTENDED_GLOB` を立てた zsh でだけ開くため。

### かかった手間

計算は 20 本の run で 14 分 (全件の run が 1 変種 100 から 143 秒、対照が 1 本 5 から 68 秒)。
作る側の手間は、#754 に書く。

### 読むときの注意

- 生成器の語彙は、25a12ed の分類器を読んで作った。分類器を読んで思いつかない形は、語彙にも無い。
- 実装と検証の途中で、同じ seed の下見の run を走らせている。盲検の結果ではない。
- 新しい反例が 0 件と言えるのは、この語彙、guard が通す形、上の仮定の中だけ。
- #755 から #757 (K1 から K3) は、この試行の前に source を読んで見つけた。生成の成果ではない。

## やめるとき

試行を続けないと決めたら、次をまとめて外す。
分類器の本体と今の表の test には手を入れていないので、外しても挙動は変わらない。

- `scripts/probe-classifier-invariants.sh`
- `scripts/lib/probe_classifier_invariants.rb`
- `scripts/lib/probe_classifier/` (`isolation.rb`、`judge.rb`、`generator.rb`、`mutations.rb`)
- `scripts/tests/probe-classifier-invariants-test.sh`
- `docs/classifier-invariants.md`
- 一覧の行 (`README.md`、`scripts/README.md`、`docs/onboarding.md`)
- `scripts/tests/c-locale-test.sh` の comment にある entrypoint の本数

`scripts/lib/probe_child.rb` は、ほかの probe と共有しているので残す。
