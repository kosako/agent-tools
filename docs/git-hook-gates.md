# Git Hook Gates(dispatcher / public-safety / git identity / AI trailer)

commit 境界の機械的規律を git hook として決定的に実行するための 4 script の契約。
skill (probabilistic な steering) が繰り返し宣言してきた規律のうち、条件とアクションが
機械判定できる部分だけを hook に切り出したもの (#200 §4.1-4.2 / #202)。判断が要る部分
(公開してよい意味内容か・レビュー運用) は従来どおり skill / 人間の領分に残る。

## 強度ラベル(偽らない)

これらはすべて**通常経路 (git commit) に対する best-effort guardrail** であって、
enforcement boundary ではない:

- `git commit --no-verify` は pre-commit / commit-msg をどちらも skip する (実測 #201)。`git merge --no-verify` は
  pre-merge-commit / commit-msg を skip する。prepare-commit-msg はどちらでも skip されないので、そこにつないだ
  git-identity の検査は走る (#449)。
- repo local の `core.hooksPath` (husky 等) は global 設定を上書きし、gate は黙って
  外れる (実測 #201)。
- 別 client / 他マシンからの commit・GitHub 上の操作 (squash merge 等) は対象外。
- `git commit` 以外で作る commit のうち、競合の無い自動の merge (pull を含む)・cherry-pick・revert と、merge backend
  (既定) の rebase (競合を解いた後の `--continue` を含む) では pre-commit が走らない (#414)。git-identity の検査は、
  pre-merge-commit (競合の無い自動の merge) と prepare-commit-msg (merge・cherry-pick・revert・merge backend の
  rebase。競合を解いた後の `--continue` を含む) にもつないで、これらの経路でも走らせる (#449)。差分の public-safety
  の検査はこの 2 stage には足さない (公開される内容は push の前の `--stdin` が見る。下の段落) ので、pre-commit の
  走らない上の経路では走らない。
- 競合を解いた後の merge・cherry-pick・revert の `--continue` は、内部で `git commit` と同じ hook を呼ぶので、既存の
  pre-commit (差分の public-safety と git-identity) と commit-msg が走る。commit-msg は競合の無い自動の merge でも
  走るので、そこでも message の public-safety の検査 (`--commit-msg`) と ai-trailer の検査は残る (競合の無い
  cherry-pick・revert・rebase と rebase の `--continue` では commit-msg は走らない)。
- `git am` と、apply backend の rebase (`git rebase --apply` や `rebase.backend=apply`。内部で `git am` を使う) では、
  pre-commit・prepare-commit-msg・pre-merge-commit・commit-msg のどれも走らず (走るのは applypatch-msg・
  pre-applypatch・post-applypatch)、どの gate も走らない。経路ごとに走る hook と、非 0 で止まるかの実測は #449
  (git 2.54.0。apply backend の rebase は #449 の review で確かめた)。

hard な床は従来どおりここに載せない (credential 隔離 / egress / CI)。公開する内容の検査は
公開の前に置く (#413): 差分は pre-commit、commit message は commit-msg (public-safety の
`--commit-msg`)、Issue / PR / コメントの題名と本文は投稿の前の public-safety の `--stdin` (各 skill と
運用 instruction)。push の前には、push で公開される累積差分・各 commit の差分と message・branch 名と、
その push で作る PR の題名と本文をまとめて `--stdin` に通す (#413。hook ではなく手順の側で、各 skill と
運用 instruction。pre-push の stage には gate を置かない)。CI には置かない (push した時点で public に
なるので、公開前の確認にならない)。トレーラ喪失 (squash / rebase) への対処は消費側 preflight (#202 の
routing-preflight) の領分。

## 構成と配線(所有分界)

実体 (script) = agent-tools、配線 (git config / shim) = dotfiles。既存の
[boundary-with-dotfiles](boundary-with-dotfiles.md) を踏襲する。

```text
global git config: core.hooksPath = <dotfiles 所有の hooks dir>
  <hooks dir>/pre-commit   →  exec <deploy>/personal-git-hook-dispatcher pre-commit "$@"
  <hooks dir>/commit-msg   →  exec <deploy>/personal-git-hook-dispatcher commit-msg "$@"
  <hooks dir>/pre-merge-commit   →  exec <deploy>/personal-git-hook-dispatcher pre-merge-commit "$@"     (#449)
  <hooks dir>/prepare-commit-msg →  exec <deploy>/personal-git-hook-dispatcher prepare-commit-msg "$@"   (#449)
  <hooks dir>/<他の stage> →  exec <deploy>/personal-git-hook-dispatcher <stage> "$@"   (gate なし。repo hook に chain するだけ。
                              push-to-checkout / proc-receive / fsmonitor-watchman には置かない)

<deploy> = <tool home>/agent-tools/scripts (sync の script 配備先。公開契約)
  personal-git-hook-dispatcher   … stage ごとの gate 実行 + repo hook への chain
  personal-public-safety-gate    … pre-commit stage の gate (1 本目) / commit-msg stage の gate (1 本目。#413)
  personal-git-identity-gate     … pre-commit stage の gate (2 本目。#281) / pre-merge-commit・prepare-commit-msg stage の
                                   gate (#449)
  personal-ai-trailer-gate       … commit-msg stage の gate (2 本目)
```

- dispatcher は gate を**自分と同じ directory** から解決する。gate が欠けていれば
  fail-closed (exit 2) で commit を止める (配備欠損を黙って素通りさせない)。
- shim がどちらの tool home の deploy を指すかは dotfiles 側の裁定 (両 home に同一
  byte が配備される)。
- 同じ stage の gate は配列順に実行し、最初に fail した gate の exit code で止まる (後続の
  gate は走らない)。pre-commit は public-safety → git-identity の順、commit-msg は public-safety
(`--commit-msg`) → ai-trailer の順 (#413)。pre-merge-commit と prepare-commit-msg は git-identity だけ (#449)。
- dotfiles 側の readiness probe / doctor は配備本数を数える。gate を増やしたら dotfiles 側も
  追随が要る (#281 で 3 本 → 4 本。follow-up は dotfiles 側の Issue)。#449 は既存の gate を stage に足しただけで
  本数は変わらない (pre-merge-commit と prepare-commit-msg の shim は dotfiles 側が置き済み)。
- **再入 sentinel の既知の副作用**: dispatcher は chain 実行時に stage 単位の env
  (`AGENT_TOOLS_GIT_HOOK_ACTIVE_<STAGE>`) を立て、再入を検出したら gate 済みとして
  warning を 1 行出して即 pass する (shim 経由の間接自己参照 loop 対策)。sentinel は gate の無い stage
  (pre-push など) の chain でも立つ (#430 の 3)。このため、chain 先の repo hook が
  **同じ stage の hook を呼ぶ git 操作 (commit・push など) を別の repository で行う**と、その内側の
  操作のその stage では gate も、その repository 自身の hook も走らない。

## dispatcher の chain 契約

global `core.hooksPath` は per-repo `.git/hooks` を**完全に置換**し、fallback もない
(実測 #201)。dispatcher はこれを合成に変える:

1. stage の personal gate を順に実行。fail したらその exit code で終了 (chain しない)。
2. 全 gate pass 後、`git rev-parse --git-common-dir` 直下の `hooks/<stage>` が実行可能
   なら `exec` で chain する (exit code はそのまま repo hook のもの)。worktree でも
   共有側 hooks が対象 (実測 #201 と同じ挙動)。
   gate の無い stage (git の既知の hook 名のうち、dispatcher の `GIT_HOOK_STAGES` にあるもの) は 1. を
   飛ばしてこの chain だけを行う (#430 の 3)。global `core.hooksPath` は shim の無い stage の repo hook を
   黙って無効にするので、repo hook を生かしたい stage には dotfiles 側が shim を置く (置かない stage の
   repo hook は走らない)。未知の名前 (typo) は exit 2。stdin を読む hook (pre-push / pre-receive /
   post-rewrite / reference-transaction など) は `exec` が stdin をそのまま渡す。
   **素通しに使えない stage** (`UNSUPPORTED_STAGES`。shim を置かず、呼ばれたら exit 2): `push-to-checkout`
   (hook が在ると git は既定の作業ツリーの更新を省くので、repo hook が無いまま 0 を返すと
   `receive.denyCurrentBranch=updateInstead` の push 後に ref と作業ツリーがずれる)、`proc-receive` (hook が
   在ると git は protocol で結果を返すことを前提にする)、`fsmonitor-watchman` (決まった形式の出力を返す契約)。
3. gate 起動と chain は、いずれも Ruby の `[cmdname, argv0]` 2 要素配列形で行う。Ruby は
   引数の **個数** で shell 経由かを決めるため、引数ゼロの pre-commit では path がそのまま
   shell 解釈される (#267。空白で word split、`$( )` で command 置換。`.gitmodules` の
   submodule 名経由で到達する経路を実測)。この形は冗長に見えるが回帰防止なので単純化
   しない。`exec` の env Hash は第 1 引数のまま置く。
4. chain 先が dispatcher 自身に解決される誤設定は検出して skip する (無限 chain 防止)。
5. dispatcher 自身の exit code は 0 / 1 / 2 に閉じる (#274): 0 = 全 gate pass (chain なし)、
   1 = gate の finding による block、2 = usage・構成エラー。途中の例外 (git 不在・chain 先の
   消失や実行 bit 喪失など) は捕捉して 2 に正規化し、backtrace は出さず原因を 1 行 warn
   する (Ruby 既定の例外終了は exit 1 で、1 の意味が壊れる)。gate の**起動自体**に失敗
   したとき (`executable?` 確認後の消失。Ruby の `system` は nil を返し `$?` は 127) も
   2 に正規化する。gate が**自分で返した** exit code は等値で伝播し (1. のとおり。契約外の
   値を返すのは gate 側の欠陥)、chain 先は `exec` で置き換わるため verbatim (2. のとおり)。

`git rev-parse --git-path hooks` は core.hooksPath を返すため使わない (自分に戻る)。

## personal-public-safety-gate(pre-commit / commit-msg / stdin)

staged diff の**追加行**を scan する。読むのは `git diff --cached` / staged file 一覧 /
local pattern file のみ。diff は `--text --no-textconv` で取る (#414): binary とみなす file (`-diff` / `binary`
属性、NUL を含む内容) も追加行として見て、textconv を設定した file は変換前の内容を見る (変換 command は起動しない)。network なし・値そのものは出力しない (file:line と種別のみ)。

| クラス | 対象 | 挙動 |
|---|---|---|
| definite | private key block (`-----BEGIN ... PRIVATE KEY-----` と PGP の `PRIVATE KEY BLOCK`) / 既知 token 形 (GitHub `ghp_` `gho_` `ghu_` `ghs_` `ghr_` `github_pat_`、AWS `AKIA`、Slack `xox[baprs]-`、Anthropic `sk-ant-`、OpenAI `sk-proj-` `sk-svcacct-` `sk-admin-` と旧形式の `sk-` + 英数字 48 文字、Stripe `sk_live_` `sk_test_`) / 実 `$HOME` path の literal / `*.local` `*.local.md` `.agent-packets/` 配下の staged 追加 / local pattern 一致 | exit 1 で block |
| suspicious | 汎用 credential 代入ヒューリスティック | 警告のみ (block しない) |

- **escape (明示確認)**: レビュー済みの誤検知は該当行に `public-safety: allow` を書く。
- **local pattern file**: `~/.config/agent-tools/public-safety-patterns.local`
  (1 行 1 Ruby regex、`#` コメント可・untracked のユーザー正本)。planning tool の
  domain 等、**public repo に書けないパターンはここに置く** (tracked な gate 本体には
  持たない)。不在 (lstat が ENOENT) は追加パターンなし。在るのに使えない (stat できない・symlink の
  先が無い・regular file でない・読めない) と、regex が壊れているときは exit 2 で止める
  (私物パターンが黙って外れた状態で通さない。#430)。
- diff は `--no-color --no-ext-diff` を付けて取る。parser は行頭の `+` と hunk header を読むので、
  `color.ui=always` や `diff.external` の設定から独立させるために必要 (外すと検出が黙って効かなくなる。
  test で固定。#430)。
- 実 `$HOME` の判定は `$HOME` が `/Users/<name>` / `/home/<name>` 形のときだけ有効
  (汎用の `/Users/...` 例示は検出しない)。
- `.agent-packets/` (作業単位の packet、[agent-packets](agent-packets.md)) は global
  gitignore が第一防衛。未設定の repo で `git add -A` に拾われた場合をここで止める
  (root でも nested でも対象。`*.local` と同じ `local-only-file` class)。
- exit: 0 = pass / 1 = definite finding / 2 = 入力・構成エラー (git 失敗・regex 壊れ・
  未知の引数)。引数ゼロが pre-commit mode。未知の引数では黙って pre-commit mode に倒さず
  usage + exit 2 (dispatcher は pre-commit に引数を渡さない)。

**stdin mode (`--stdin`)**: pre-commit mode と同じ pattern (definite + local pattern file +
実 `$HOME`、allow pragma も同じ) で stdin の text を行単位に scan する。git には触らず、
path 判定 (`local-only-file`) は対象外。finding は `stdin:<line>` で報告し、exit 契約も
同じ。公開する text を公開の前に通す検査口で、Issue / PR / コメントの題名と本文を投稿する前と、push で
公開される内容 (累積差分・各 commit の差分と message・branch 名・その push で作る PR の題名と本文) を push
する前に使う (#413)。packet の public 写しを Issue コメントへ投稿する前もここを通す (#253)。呼び出し側は
text を stdin で渡し、exit 0 で、stderr に `public-safety-gate: warning:` で始まる行が無いときだけ公開 (投稿・push)
へ進む (1 = definite あり、2 = 検査できていない。どちらも公開しない。exit 0 でも警告の行 (suspicious) があれば
公開せず、本文と結果を人に見せる。#413)。この接頭辞は、呼び出し側が警告の有無を判定するのに使う出力の契約である
(変えるときは、警告の行で止める呼び出し側も合わせて直す)。

**commit-msg mode (`--commit-msg <file>`)** (#413): commit-msg stage で dispatcher が message の file を
渡す。pre-commit mode と同じ pattern で、message の file **全体**を scan する。comment 行 (`#` 始まり) や
scissors 行より後 (`git commit -v` の差分) も除かない。commit に残る行は cleanup の mode で変わり
(`-m` / `-F` の既定の whitespace や `--cleanup=verbatim` では `#` 行も残る)、CLI の `--cleanup` は hook から
確かめられないため、過検出の側に倒す。止まったときは、該当行を直すか allow pragma を書く。既知の過検出:
`git commit -v` の差分は削除行と文脈行も含む (pre-commit が見るのは追加行だけ) ので、既存の token や home path を
**消す** commit を `-v` で行うと、その削除行で止まる。そのときは `-v` を付けずに (`--no-verbose`) commit するか、
editor で scissors 行より下を消してから保存する。finding は `commit-msg:<line>` で報告し、
exit 契約も同じ。有効な trailer があっても、message に definite があれば commit-msg stage で止まる。

## personal-git-identity-gate(pre-commit / pre-merge-commit / prepare-commit-msg)

commit に使われる author / committer の identity が name / email とも非空であることを
検証し、partial な identity の commit を止める (#281)。読むのは `git var GIT_AUTHOR_IDENT` /
`GIT_COMMITTER_IDENT` の解決結果だけ。network なし・引数は読まない (pre-commit と pre-merge-commit は引数ゼロ。
prepare-commit-msg では git の引数 (message の file・source・sha) が渡るが使わない)。

| 状態 | Git 単体の挙動 | gate |
|---|---|---|
| name / email とも非空 | commit 可 | pass (exit 0) |
| name あり・email 空 (partial) | **`Name <>` で commit が通る** (2.50.1 実測) | exit 1 で block |
| name 空 (email の有無を問わず) | git が pre-commit より前に拒否 (hook は走らない) | 直接呼ぶと unresolved として exit 1 |

- 背景: `user.useConfigOnly` は「未設定」を止めるだけで「明示的に空」は止められず、
  gitconfig の include 順や値でも表現できない。dotfiles の identity reset (非 personal
  context で空値を挟む設計) と、context の identity file が name だけの partial な状態が
  重なるとこの穴を踏む。可視化 (prompt / doctor) は既にあり、commit を作る経路で機械的に止めるのが
  この gate。
- **走る stage (#449)**: `git commit` では pre-commit と prepare-commit-msg (同じ検査が 2 回走る)。
  pre-commit の走らない経路では、競合の無い自動の merge (pull を含む) が pre-merge-commit と prepare-commit-msg、
  cherry-pick・revert・merge backend の rebase が prepare-commit-msg (競合を解いた後の `--continue` を含む。merge・
  cherry-pick・revert の `--continue` では pre-commit も走る)。止まったときは
  途中の状態と staged の変更が残る (merge は `MERGE_HEAD`、cherry-pick は `CHERRY_PICK_HEAD`、rebase は
  `rebase-merge`。競合の無い revert は `REVERT_HEAD` を残さず、変更だけが staged で残った。#449 の実測)。identity を
  直してから続けるか、各経路の `--abort` などで戻す。`git am` と apply backend の rebase では走らない (上の強度ラベル)。
  - cherry-pick・revert・rebase の hook から `git var` が返す author は、元の commit の author ではなく config の
    identity (git 2.54.0 で観察。`git commit --amend` と `--author` では、hook の env に渡る値になる)。他人の
    commit を取り込むときも、検査されるのは自分の identity。
  - `--no-verify` は prepare-commit-msg を skip しないので、`git commit --no-verify` でも partial な identity は
    止まる。identity を直してから commit する。
- **出力の規律**: identity の**値**は stdout / stderr に出さない。出すのは key 名 (author
  name / author email / committer name / committer email) と「空」であることだけ。git の
  stderr (`for <email>` を含みうる) も捨てる。
- **検査しないもの**: context 一致 (repo の場所と email の対応)。dotfiles 側の layout 規約に
  依存するため実体には持たない (必要なら別 Issue)。環境変数 / `git -c` による identity
  上書きは `git var` の解決結果に含まれるが、上書き自体の検出・拒否はしない。
- exit: 0 = pass / 1 = identity が不完全 (partial / git が解決不能) / 2 = usage・構成エラー
  (git 不在等の想定外)。

## personal-ai-trailer-gate(commit-msg)

AI agent セッション由来の commit に相互レビュー routing の正本である
`Co-Authored-By:` トレーラを要求する。**opt-in 設計**で人間の commit を誤 block しない。

| セッション判定 (env marker) | 要求 |
|---|---|
| marker なし (人間・他 tool) | 無言 pass |
| `CLAUDECODE` のみ | name が `Claude` 始まりのトレーラ 1 本以上 |
| `CODEX_THREAD_ID` / `CODEX_SANDBOX` のみ | name が `Codex` 始まりのトレーラ 1 本以上 |
| `AGENT_TOOLS_OPENCODE` のみ (#295。OpenCode の plugin が model の bash に立てる) | name が `OpenCode (<provider>/<model>)` のトレーラ 1 本以上 |
| 複数 (nested 実行: Claude → codex exec 等) | env にある agent のどれかの有効なトレーラ 1 本以上 (env に無い agent のトレーラだけでは通さない) |

- **どの agent の session かの判定では、env marker を repo 全体で「非空なら立っている」と読む** (#431)。空の値は
  無い扱いで、key の有無では判定しない。この読み方は、この gate、`personal-tool-call-record-hook`、
  `personal-codex-worker-preflight` (Codex の session 内からの起動を止める asymmetry の判定)、skill の session
  判定 (`personal-review-request` / `personal-grill-me` の相談) で共通。理由は、OpenCode の plugin が model の bash
  で他の agent の marker を空文字にして消した扱いにするため (下の「漏れ対策」。`shell.env` では変数を消せない)。
  key の有無で読む箇所が 1 つでもあると、その箇所は OpenCode の session を Claude / Codex の session と誤判定する。
  session を判定する skill は OpenCode の marker (`OPENCODE` / `AGENT_TOOLS_OPENCODE`) を先に見る。
  - 例外: sandbox の内外の判定 (Codex を直接起動してよいか。`personal-codex-review` と `personal-repo-audit` の
    起動経路) は session の判定ではないので、この契約に含めない。そこでは `CODEX_SANDBOX` の値が空でも
    「設定あり = sandbox の中」とみなす。plugin は model の bash で `CODEX_SANDBOX` を空文字にするので、Codex の
    sandbox の中から起動した OpenCode でも値は空になる。非空で読むと sandbox の中を外と取り違えて直接起動を
    選び、入れ子の sandbox で Codex が command を実行できなくなる。空も「設定あり」と読むのは、直接起動を
    選ばない側 (fail-closed) に倒すため。
- AI トレーラの email は no-reply 形式 (`no-?reply` を含む) のみ許可。この regex が
  「email は公開してよい no-reply / bot 用に限る」(operating-rules) の機械判定可能な
  床であり、**許可 email 形式の policy source はこの gate が SSOT**。
- Codex の trailer の email (`codex@users.noreply.github.com`) の紐づき先 (#335):
  - 観測 (2026-09-26、GraphQL の `Commit.authors` の解決結果): この email は GitHub の `codex` の account に
    解決される。OpenAI 自身の Codex が使う trailer `Codex <noreply@openai.com>` も、同じ `codex` の account に
    解決される。
  - 判断: OpenAI 自身が使う email が同じ account に解決されるので、OpenAI の Codex の account とみなし、
    今の email を維持する。email の verified 状態や account の管理主体は、直接は確かめていない。
  - この形の no-reply は login で紐づくので、login が変わると紐づき先も動きうる。
- 1 commit に複数の AI (Claude / Codex / OpenCode) のトレーラが混在したら fail-closed (routing 判定不能)。
- **AI 名**は name が `Claude` / `Codex` / `OpenCode` で始まるもの (#295 で OpenCode を追加)。`OpenCode` で
  始まるトレーラは形を問わず OpenCode のものとして拾い、形 `OpenCode (<provider>/<model>)` を検査する
  (`<provider>/<model>` は OpenCode の model 指定の文字列そのままで、model は `/` を含みうる)。形が不正なら
  fail で、形が不正でも混在の検出にはかける。1 commit に model の異なる OpenCode トレーラがあれば fail
  (1 commit に 1 model。reviewer は model の系列で決まるため)。
- OpenCode のトレーラの email は `noreply@opencode.invalid` (RFC 2606 の予約 domain で、どの account にも
  紐づかない) を使う。gate は OpenCode の email を固定せず、上の no-reply の床を Claude / Codex と共通に保つ。
- 人間の co-author トレーラ (AI 名以外) は自由 (検査対象外)。
- **merge commit (MERGE_HEAD あり) も、agent の session なら対象** (#415)。競合の解消は authored な変更で、PR の
  routing-preflight も trailer の無い merge commit を fail-closed にするので、そろえる。人間の merge は「marker なし」
  として今までどおり pass する。PR の branch は rebase で更新すると、merge commit 自体が入らない。
- commit message の comment 除去は既定 `commentChar` (`#`) と scissors 行のみ対応。
- env marker は**観測された事実であって両 CLI の公開契約ではない** (#201 実測,
  Claude Code 2.1.207 / codex 0.144.1)。CLI 更新で消えた場合、gate は人間 commit と
  同じ扱い (無言 pass) に fail-open で倒れる。CLI 更新時の smoke test で生存確認する。
- **OpenCode の marker は agent-tools の plugin が立てる** (#295)。OpenCode には session を示す env が無く
  (`OPENCODE_SESSION_ID` は無い)、組み込みの `OPENCODE=1` は人が打つ `!` / PTY / OpenCode 内部の git にも
  載るので、目印にしない (人の commit を AI の commit として block してしまう)。plugin
  (`~/.config/opencode/plugins/personal-agent-tools.js`) は、記録専用の `tool.execute.before` で model の
  bash の callID を覚え、`shell.env` で callID が一致したときだけ `AGENT_TOOLS_OPENCODE=1` を立てる (`!` にも
  callID が付くので callID の有無では絞れない。PTY は callID を持たない)。実測は OpenCode 1.18.30
  (2026-09-26、[opencode-plugin-probe](opencode-plugin-probe.md) の M5)。
  - honest-label: plugin が読まれない (`opencode --pure`・読込失敗・撤去) と marker は立たず、gate は
    人間の commit として通す。その場合の床は PR 単位の routing-preflight (trailer の無い commit は
    fail-closed。bot の PR だけは trailer ではなく GitHub の API の印で判定する。#553)。OpenCode を更新したら、probe で marker がまだ立つかを確かめる。
  - 漏れ対策: herdr の pane や Claude の session の中から起動した OpenCode では、他の agent の marker
    (`CLAUDECODE` / `CODEX_THREAD_ID` / `CODEX_SANDBOX`) が model の bash に漏れうる。漏れると gate は
    nested と判定して Claude のトレーラを通してしまうので、plugin は model の bash でこれらを空文字にする
    (`shell.env` では変数を消せない。gate は空の値を marker とみなさない)。plugin が読まれないときは
    この対策も効かない。
- exit: 0 = pass / 1 = 検証 fail / 2 = usage・入力エラー。

## 検証境界

- 純粋ロジックと git 連携 (hooksPath 経由の commit / chain / 隔離 env) は
  `scripts/tests/git-hook-gates-test.sh` が CI で検証する (OpenCode の marker の commit を含む)。
- OpenCode の plugin が marker を model の bash にだけ立て、他の agent の marker を空にすることは
  `scripts/tests/opencode-plugin-test.sh` (node) が CI で検証する (`!` / PTY に相当する入力には立たない)。
- 実環境の配線 (dotfiles の shim + global git config・Codex 側 marker の生存) は CI 外
  (実機 smoke。実施記録は #202)。この実測以降 CLI は更新されており (2026-09-17 時点で
  Claude Code 2.1.273 / codex 0.153.4)、marker 挙動の再検証は未実施。
