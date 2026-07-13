# Git Hook Gates(dispatcher / public-safety / AI trailer)

commit 境界の機械的規律を git hook として決定的に実行するための 3 script の契約。
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
  personal-public-safety-gate    … pre-commit stage の gate
  personal-ai-trailer-gate       … commit-msg stage の gate
```

- dispatcher は gate を**自分と同じ directory** から解決する。gate が欠けていれば
  fail-closed (exit 2) で commit を止める (配備欠損を黙って素通りさせない)。
- shim がどちらの tool home の deploy を指すかは dotfiles 側の裁定 (両 home に同一
  byte が配備される)。
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
3. chain 先が dispatcher 自身に解決される誤設定は検出して skip する (無限 chain 防止)。

`git rev-parse --git-path hooks` は core.hooksPath を返すため使わない (自分に戻る)。

## personal-public-safety-gate(pre-commit)

staged diff の**追加行**を scan する。読むのは `git diff --cached` / staged file 一覧 /
local pattern file のみ。network なし・値そのものは出力しない (file:line と種別のみ)。

| クラス | 対象 | 挙動 |
|---|---|---|
| definite | private key block / 既知 token 形 (GitHub・AWS・Slack・Anthropic・OpenAI・Stripe) / 実 `$HOME` path の literal / `*.local` `*.local.md` の staged 追加 / local pattern 一致 | exit 1 で block |
| suspicious | 汎用 credential 代入ヒューリスティック | 警告のみ (block しない) |

- **escape (明示確認)**: レビュー済みの誤検知は該当行に `public-safety: allow` を書く。
- **local pattern file**: `~/.config/agent-tools/public-safety-patterns.local`
  (1 行 1 Ruby regex、`#` コメント可・untracked のユーザー正本)。planning tool の
  domain 等、**public repo に書けないパターンはここに置く** (tracked な gate 本体には
  持たない)。不在は追加パターンなし。regex が壊れていれば exit 2 で止める。
- 実 `$HOME` の判定は `$HOME` が `/Users/<name>` / `/home/<name>` 形のときだけ有効
  (汎用の `/Users/...` 例示は検出しない)。
- exit: 0 = pass / 1 = definite finding / 2 = 入力・構成エラー (git 失敗・regex 壊れ)。

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
  (実機 smoke。実施記録は #202)。
