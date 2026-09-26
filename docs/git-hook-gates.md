# Git Hook Gates(dispatcher / public-safety / git identity / AI trailer)

commit 境界の機械的規律を git hook として決定的に実行するための 4 script の契約。
skill (probabilistic な steering) が繰り返し宣言してきた規律のうち、条件とアクションが
機械判定できる部分だけを hook に切り出したもの (#200 §4.1-4.2 / #202)。判断が要る部分
(公開してよい意味内容か・レビュー運用) は従来どおり skill / 人間の領分に残る。

## 強度ラベル(偽らない)

これらはすべて**通常経路 (git commit) に対する best-effort guardrail** であって、
enforcement boundary ではない:

- `git commit --no-verify` は pre-commit / commit-msg をどちらも skip する (実測 #201)。
- repo local の `core.hooksPath` (husky 等) は global 設定を上書きし、gate は黙って
  外れる (実測 #201)。
- 別 client / 他マシンからの commit・GitHub 上の操作 (squash merge 等) は対象外。

hard な床は従来どおりここに載せない (credential 隔離 / egress / CI)。公開前の最終
確認点は push / CI 側に置く (follow-up は #202)。トレーラ喪失 (squash / rebase) への
対処は消費側 preflight (#202 の routing-preflight) の領分。

## 構成と配線(所有分界)

実体 (script) = agent-tools、配線 (git config / shim) = dotfiles。既存の
[boundary-with-dotfiles](boundary-with-dotfiles.md) を踏襲する。

```text
global git config: core.hooksPath = <dotfiles 所有の hooks dir>
  <hooks dir>/pre-commit   →  exec <deploy>/personal-git-hook-dispatcher pre-commit "$@"
  <hooks dir>/commit-msg   →  exec <deploy>/personal-git-hook-dispatcher commit-msg "$@"

<deploy> = <tool home>/agent-tools/scripts (sync の script 配備先。公開契約)
  personal-git-hook-dispatcher   … stage ごとの gate 実行 + repo hook への chain
  personal-public-safety-gate    … pre-commit stage の gate (1 本目)
  personal-git-identity-gate     … pre-commit stage の gate (2 本目。#281)
  personal-ai-trailer-gate       … commit-msg stage の gate
```

- dispatcher は gate を**自分と同じ directory** から解決する。gate が欠けていれば
  fail-closed (exit 2) で commit を止める (配備欠損を黙って素通りさせない)。
- shim がどちらの tool home の deploy を指すかは dotfiles 側の裁定 (両 home に同一
  byte が配備される)。
- 同じ stage の gate は配列順に実行し、最初に fail した gate の exit code で止まる (後続の
  gate は走らない)。pre-commit は public-safety → git-identity の順。
- dotfiles 側の readiness probe / doctor は配備本数を数える。gate を増やしたら dotfiles 側も
  追随が要る (#281 で 3 本 → 4 本。follow-up は dotfiles 側の Issue)。
- **再入 sentinel の既知の副作用**: dispatcher は chain 実行時に stage 単位の env
  (`AGENT_TOOLS_GIT_HOOK_ACTIVE_<STAGE>`) を立て、再入を検出したら gate 済みとして
  即 pass する (shim 経由の間接自己参照 loop 対策)。このため、chain 先の repo hook が
  **別 repository へ同じ stage の commit を行う**場合、その内側の commit は gate を
  通らない。

## dispatcher の chain 契約

global `core.hooksPath` は per-repo `.git/hooks` を**完全に置換**し、fallback もない
(実測 #201)。dispatcher はこれを合成に変える:

1. stage の personal gate を順に実行。fail したらその exit code で終了 (chain しない)。
2. 全 gate pass 後、`git rev-parse --git-common-dir` 直下の `hooks/<stage>` が実行可能
   なら `exec` で chain する (exit code はそのまま repo hook のもの)。worktree でも
   共有側 hooks が対象 (実測 #201 と同じ挙動)。
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

## personal-public-safety-gate(pre-commit)

staged diff の**追加行**を scan する。読むのは `git diff --cached` / staged file 一覧 /
local pattern file のみ。network なし・値そのものは出力しない (file:line と種別のみ)。

| クラス | 対象 | 挙動 |
|---|---|---|
| definite | private key block / 既知 token 形 (GitHub・AWS・Slack・Anthropic・OpenAI・Stripe) / 実 `$HOME` path の literal / `*.local` `*.local.md` `.agent-packets/` 配下の staged 追加 / local pattern 一致 | exit 1 で block |
| suspicious | 汎用 credential 代入ヒューリスティック | 警告のみ (block しない) |

- **escape (明示確認)**: レビュー済みの誤検知は該当行に `public-safety: allow` を書く。
- **local pattern file**: `~/.config/agent-tools/public-safety-patterns.local`
  (1 行 1 Ruby regex、`#` コメント可・untracked のユーザー正本)。planning tool の
  domain 等、**public repo に書けないパターンはここに置く** (tracked な gate 本体には
  持たない)。不在は追加パターンなし。regex が壊れていれば exit 2 で止める。
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
同じ。packet の public 写しを Issue コメントへ投稿する前の検査口 (#253)。呼び出し側は
text を stdin で渡し、exit 0 のときだけ投稿へ進む (1 = definite あり、2 = 検査できていない。
どちらも投稿しない)。

## personal-git-identity-gate(pre-commit)

commit に使われる author / committer の identity が name / email とも非空であることを
検証し、partial な identity の commit を止める (#281)。読むのは `git var GIT_AUTHOR_IDENT` /
`GIT_COMMITTER_IDENT` の解決結果だけ。network なし・引数なし (pre-commit は引数ゼロ)。

| 状態 | Git 単体の挙動 | gate |
|---|---|---|
| name / email とも非空 | commit 可 | pass (exit 0) |
| name あり・email 空 (partial) | **`Name <>` で commit が通る** (2.50.1 実測) | exit 1 で block |
| name 空 (email の有無を問わず) | git が pre-commit より前に拒否 (hook は走らない) | 直接呼ぶと unresolved として exit 1 |

- 背景: `user.useConfigOnly` は「未設定」を止めるだけで「明示的に空」は止められず、
  gitconfig の include 順や値でも表現できない。dotfiles の identity reset (非 personal
  context で空値を挟む設計) と、context の identity file が name だけの partial な状態が
  重なるとこの穴を踏む。可視化 (prompt / doctor) は既にあり、機械的に止める最後の 1 段が
  この gate。
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
| 両方 (nested 実行: Claude → codex exec 等) | いずれかの有効な AI トレーラ 1 本以上 |

- AI トレーラの email は no-reply 形式 (`no-?reply` を含む) のみ許可。この regex が
  「email は公開してよい no-reply / bot 用に限る」(operating-rules) の機械判定可能な
  床であり、**許可 email 形式の policy source はこの gate が SSOT**。
- Codex の trailer の email (`codex@users.noreply.github.com`) は、GitHub 上で `codex` の account に
  紐づく。この account は OpenAI 公式の Codex の account で、第三者ではない (OpenAI 自身が使う trailer
  `Codex <noreply@openai.com>` も同じ account に解決される。2026-09-26 に GraphQL の `Commit.authors` の
  解決結果で確認。#335)。この形の no-reply は login で紐づくので、login が変わると紐づき先も動きうる。
- 1 commit に Claude 系と Codex 系のトレーラが混在したら fail-closed (routing 判定不能)。
- 人間の co-author トレーラ (AI 名以外) は自由 (検査対象外)。
- **merge commit (MERGE_HEAD あり) は対象外** (authored commit の契約。merge は
  レビュー済み作業の合成)。
- commit message の comment 除去は既定 `commentChar` (`#`) と scissors 行のみ対応。
- env marker は**観測された事実であって両 CLI の公開契約ではない** (#201 実測,
  Claude Code 2.1.207 / codex 0.144.1)。CLI 更新で消えた場合、gate は人間 commit と
  同じ扱い (無言 pass) に fail-open で倒れる。CLI 更新時の smoke test で生存確認する。
- exit: 0 = pass / 1 = 検証 fail / 2 = usage・入力エラー。

## 検証境界

- 純粋ロジックと git 連携 (hooksPath 経由の commit / chain / 隔離 env) は
  `scripts/tests/git-hook-gates-test.sh` が CI で検証する。
- 実環境の配線 (dotfiles の shim + global git config・Codex 側 marker の生存) は CI 外
  (実機 smoke。実施記録は #202)。この実測以降 CLI は更新されており (2026-09-17 時点で
  Claude Code 2.1.273 / codex 0.153.4)、marker 挙動の再検証は未実施。
