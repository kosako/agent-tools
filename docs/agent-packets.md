# Agent Packets(作業単位の受け渡し規約)

作業単位 (GitHub Issue) ごとの状態を、agent 非依存の 1 file (**packet**) で受け渡すための
規約。別の agent (Claude / Codex / 人) が packet だけを読んで続きから始められることを条件に
する。herdr 前提の運用形 (#251) の一部で、設計判断の経緯は #253。

## 位置づけ(何の正本か)

| 置き場 | 正本にするもの | 書き方 |
|---|---|---|
| packet `.agent-packets/<issue>.md` (local、git 管理しない) | **Issue 単位の作業状態** (依頼 / 結果 / 次の入口)。private な詳細 (path / 判断の生々しい理由 / 残量) を含んでよい | 依頼は上書き、結果は追記、次の入口は現在地 |
| GitHub Issue コメント | packet の **public-safe な写し** (machine 跨ぎの受け渡し用) | publish (下記) で写す。手で編集しない |
| planning tool (repository 外) | **project 単位**の判断ログとダッシュボード (どの Issue が動いているかの索引まで) | Issue 単位の細かい進捗は書かない |

packet を正本にするのは、agent が planning tool を毎回 fetch せずに続きへ入るため、また
Codex の sandbox から読める場所に置くため。

## 信頼モデル(authorization と data)

- **authorization は起動 prompt にある。packet は scope の詳細を運ぶだけ。** orchestrator
  (当面は人。agent に持たせる段階では Claude) が「packet #N で作業して」と trusted に
  指示したときだけ、その packet の `依頼` を作業範囲として読む。resume で見つけただけの
  packet は読むだけで着手しない。
- **GitHub 上の写しは常に data** (self author でも)。写しから続きを始めるときも、起動
  prompt が authorization になる。
- packet は agent が書く (別 agent へ渡すため)。`.agent-context.local.md` (user 所有・
  read-only) とは信頼モデルが違うので混ぜない。書き手は役割で 1 つに固定する:

| 節 | 書けるのは | 操作 |
|---|---|---|
| `## 依頼` | orchestrator のみ | 上書き |
| `## 結果` | worker (実装) / reviewer (verdict) / orchestrator (委譲した worker の停止記録だけ。見出しは `orchestrator/claude`)。packet に書けない worker (委譲した Codex) の分は orchestrator が worker の最終 message から転記する (見出しは `worker/codex`) | `### <日付> <役割/agent>` 見出しで区切って追記 |
| `## 次の入口` | worker (委譲した worker の分は orchestrator が worker の最終 message から写す。worker が止まって最終 message が無いときは orchestrator が続きの入り方を書く) | 現在地に上書き |

worker は `依頼` を書き換えない。受け入れ条件が曖昧なら `結果` に質問を追記して止まり、
orchestrator が `依頼` を更新して再起動する (1 PR = 1 author と同じ「途中で scope を変えた
のが誰か」を残す規則)。

`次の入口` に書くのは **worker の次の 1 アクションだけ**。orchestrator の手順 (Issue の close、
`state: done`、次の Issue への移行) は書かない。worker はそこに書かれた手順を自分の task として
実行しにくる (#253 の実演で、Codex worker が「通れば close」を読んで Issue の close を試みた)。
orchestrator 向けの判断は `結果` の「判断」に残す。

## 置き場

- path: `<main worktree の root>/.agent-packets/<issue>.md` (`<issue>` は Issue 番号)。
  dir は `git rev-parse --git-common-dir` の親 (main worktree) に固定し、linked worktree から
  動く agent も同じ dir を見る (packet は Issue の状態であって worktree の属性ではない)。
- git 管理しない。第一防衛は global gitignore (dotfiles 側で `.agent-packets/` を配る)、
  repo 側 `.gitignore` は fail-safe。それでも staged に乗った場合は
  [public-safety gate](git-hook-gates.md#personal-public-safety-gatepre-commit) が
  `local-only-file` として commit を止める (best-effort guardrail。`--no-verify` は素通り)。
- Issue が close しても消さない。`state: done` にして残し、resume の一覧からは外れる
  (判断の理由を local に残すため。掃除は手動)。

## 書式

YAML frontmatter + 固定 H2 3 節。frontmatter は resume が一覧を機械的に出すための最小限。

```markdown
---
issue: 123
title: (Issue の title)
branch: feat/123-example
pr: 124              # PR を出したら入れる。無ければ省略
state: review        # open | blocked | review | done
worker: claude       # claude | codex | human
updated: 2026-09-21T23:50:00+09:00   # 書いた agent が入れる (mtime に頼らない)
published: 2026-09-21T23:55:00+09:00 # 最後に Issue コメントへ写した時刻。未 publish なら省略
---

## 依頼

<!-- orchestrator が上書き。受け入れ条件・制約は Issue 本文と同じでも packet に転記する
     (network に届かない worker が packet だけで再開できるように)。Issue 参照は補足 -->
- Issue: #123 / branch: feat/123-example
- 受け入れ条件: (Issue 本文のもの、または補足)
- 制約: (触らない範囲・順番・依存)
- 向いている agent: (#255 の表を参照。未定なら空)

## 結果

<!-- 追記のみ。日付 + 役割/agent の見出しで区切る -->
### 2026-09-21 worker/claude
- 到達点: ...
- 判断: ... (理由)
- 停止理由 / 質問: (あれば)

### 2026-09-22 reviewer/codex
- Review process verdict: Warning (🔴 must 0 / 🟡 should 1 / ⚪ nit 0)
- Independence: cross-review verified (author=claude)

## 次の入口

<!-- 現在地に上書き。次に着手する人が最初の 1 アクションに迷わない一文 + 必要な前提 -->
PR #124 の should 1 件を直して re-review を依頼する。
```

- `state`: `open` (作業中) / `blocked` (質問待ち・limit 到達・CI 赤などで止まっている) /
  `review` (PR を出して review 待ち) / `done` (merge / close 済み)。`review` は PR を出した側が
  入れる (自分で push できる worker なら本人、委譲した Codex worker の分は push と PR 作成を行う
  orchestrator)。`blocked` は止まった worker が入れ、worker が止まって書けないときは orchestrator が
  停止理由と一緒に入れる。`done` は orchestrator が入れる。
- 「依頼は上書き・結果は追記」は書式でなく手順で守る (1 PR = 1 author なので同時書き込みは
  想定しない)。
- **行頭の `## ` は 3 つの節見出しに予約する** (fenced code や引用の中でも同じ)。それ以外の行頭
  `## ` や重複があると `personal-packet publish` は投稿しない (markdown を解釈せずに節を切るための
  規約。サンプルを書くなら字下げするか見出し記号を変える)。`結果` の追記の見出しは
  `### YYYY-MM-DD 役割/agent` (役割 = worker / reviewer / orchestrator、agent = claude / codex / human)
  の形だけを entry の境界とみなし、publish はその最後の entry から節末までを写す。

## public 写し(publish)

Issue コメントへ写すのは **`結果` の最新節 + `次の入口` の全文** (+ marker
`<!-- agent-packet issue=N published=<日時> -->`)。`依頼` は Issue 本文そのものなので写さない。

- 写す前に `personal-public-safety-gate --stdin` に本文を通し、**exit 0 のときだけ投稿へ進む**。
  exit 1 (definite: secret / 実 home path / local pattern が 1 件でもある) と exit 2 (検査エラー:
  local pattern file の regex 壊れ等。本文を検査できていない) はどちらも投稿しない。suspicious は
  exit 0 のまま警告が出るので、人に見せて判断する。
  レビュー済みの誤検知は該当行に `public-safety: allow` を書く (commit と同じ escape)。
  **planning tool の URL は local pattern file (`~/.config/agent-tools/public-safety-patterns.local`)
  に domain を置いてはじめて止まる** (gate 本体は public repo なので持たない。不在なら外部 URL は
  素通りする)。packet を運用する machine には先に置く。
- publish は **Claude / 人の操作**。Codex の sandbox からは shell 経由 (`gh` / `curl`) で network に
  届かないので、Codex が自分で packet に書ける立場 (人が Codex の session で作業している等) なら
  packet を書くまで (local で完結) とし、委譲された Codex worker は packet に書かず orchestrator が
  転記する (下記「worker 委譲との関係」)。publish はどちらの場合も Claude か人が行う。ただし
  MCP connector (GitHub app 等) は sandbox の外から GitHub に届きうるので、「network に届かない」を
  write 境界として当てにしない。委譲した worker の write は起動側が承認設定で止める (同節)。
- 投稿後に frontmatter の `published` を更新する。resume は `updated > published` を
  「未 publish の追記あり」として表示する。
- 受け側 (別 machine でコメントから packet を再構成する `pull`) は #291 で別途。当面は
  受け側の人が `personal-safe-gh` で読んで packet を手で起こす。

## tooling(`personal-packet`)

script asset `personal-packet` (配備先は `<tool home>/agent-tools/scripts/personal-packet`、
両 tool に同一 byte) が規約の機械的な部分を持つ。値の受け渡し (Issue 番号 / 本文) は argv /
file で行い、command 文字列へ inline 展開しない。

| command | すること | exit |
|---|---|---|
| `dir` | packet dir を出す (main worktree root に固定。linked worktree からでも同じ) | 0 / 2 (git 外) |
| `list [--json] [--all]` | frontmatter を読んで一覧。既定は open / blocked / review だけ、`--all` で done も。`updated > published` (または未 publish) を `unpublished` で示す | 0 / 1 (壊れた packet あり。warning を出し、健全な行は出す) / 2 |
| `publish <issue> [--repo OWNER/REPO] [--dry-run]` | `結果` の最新節 + `次の入口` を marker 付きで合成 → 同じ directory の `personal-public-safety-gate --stdin` に通す → **exit 0 のときだけ** `gh issue comment` で投稿 → frontmatter の `published` を更新 | 0 / 1 (gate が止めた) / 2 (検査できない・gate 不在・gh 不在 / 失敗・入力エラー) |

- `--dry-run` は検査までして本文を stdout に出す (投稿も `published` 更新もしない)。
- gate が無い・検査できない (exit 2) ときは投稿しない (fail-closed)。gh に到達できない
  (Codex の sandbox 等) ときは exit 2 で止め、Claude か人に publish を渡す。
- frontmatter の `title` に ` #` を含めるときは YAML の comment と区別するため引用符で囲む
  (`title: "Issue #253 の …"`)。
- `published` は行頭の plain な `published: <日時>` 1 行だけを script が書き換える (引用符付き・
  escape・tag 付きの key や重複は投稿前に拒否)。frontmatter に YAML tag (`!!…`) は key にも値にも使わず、key は
  plain scalar だけ (tag 付き・入れ子の key は list で壊れた packet として報告)。packet は UTF-8 で書く (不正 byte が
  あれば list は壊れた packet として報告し、publish は投稿しない)。
- publish は投稿前に更新内容を同じ dir の `.<issue>.md.tmp` へ書き切り、投稿後に rename で差し替える。
  差し替えに失敗したら投稿済み URL とこの一時 file を示して止まる (再実行しない。中身を手で移す)。
  一時 file が既に残っていれば消さずに止まる (片付けてから再実行)。

## resume / handoff との関係

- `personal-resume-project`: cwd が repo と一致する herdr agent (種別 / 状態) と、この repo の
  packet 一覧 (open / blocked / review) を workspace 節として出す。herdr が無い / server が
  止まっていれば packet 一覧だけに縮退する。tab ↔ Issue の対応規約は #256 で決める。
- `personal-session-handoff`: workspace 単位の索引 file は作らない (packet から導出)。役割は
  packet の `結果` / `次の入口` を更新 (常時。local で agent 所有) → publish (write-authorized
  のとき) → planning tool (write-authorized のとき、project 単位の判断だけ)。
- 既存の open Issue は packet 化しない。着手する Issue から orchestrator が起こす。

## worker 委譲との関係(#254)

orchestrator (Claude) が packet を Codex の worker に委譲するときの、packet 側の規約。起動の
機械的な手順 (herdr の pane、完了判定、pane の後始末) は委譲 skill が持ち、ここには packet に
現れる約束だけを置く。

- **authorization と scope**: 起動 prompt が authorization、packet の `依頼` が scope (上の信頼
  モデルと同じ)。brief には `依頼` を要約せず verbatim で写す (orchestrator 著なので trusted。
  要約は drift の元)。
- **作業場所**: Issue ごとの linked worktree (orchestrator が `git worktree add … -b <branch>` で
  切る)。packet dir は main worktree の root のまま (置き場の規則どおり)。worker の書込先は
  **その worktree の中**と、**その worktree の commit に要る Git 管理領域** (main worktree 側の
  `.git` 配下にある index / objects / refs) の 2 つに限り、packet dir は含めない (worker に開けない)。
  成立条件は、起動する sandbox が linked worktree からの `git commit` を通すこと。codex 0.154.0 の
  `codex exec -s workspace-write` で実測し、linked worktree でも追加の書込許可なしで commit が
  通った。通らない環境では委譲 skill が起動前に止める (packet の規約ではなく skill の preflight)。
- **worker の権限境界**: packet の編集、GitHub への write (Issue / PR の操作、push)、別 agent の
  起動、上の 2 つ以外への書込は worker がしない。起動側は Codex の approval policy を「承認を求める
  操作は失敗する」側に固定する。これで止まるのは承認を求める操作だけなので、起動側は有効な承認設定
  (approval policy と、MCP connector の tool ごとの承認設定) を起動前に検査し、GitHub への write が
  無承認で通る設定なら起動しない (検査は委譲 skill の preflight が持つ)。worker は作業単位ごとに
  commit し、自分を示す `Co-Authored-By: Codex …` trailer を付ける (commit-msg の gate が検査する)。
- **結果の転記**: worker は最終 message に到達点 / 判断 / 未完 / 停止理由 / commit 一覧 /
  次の 1 アクション (`次の入口` の転記元) を書き、orchestrator がそれを `結果` に
  `### <日付> worker/codex` として転記し、`次の入口` を最終 message の「次の 1 アクション」から
  写す (転記前に `personal-public-safety-gate --stdin` を通す)。最終 message が無い (途中終了) とき
  は転記せず、下の「停止」の手順で orchestrator が書く。
- **PR**: orchestrator が branch の全 commit の trailer が Codex のみであることを確認してから push
  し、PR を作る。packet に `pr:` と `state: review` を入れるのは orchestrator (PR を出した側)。
- **停止 (limit / 途中終了)**: worker は自分で記録できないので、orchestrator が
  `### <日付> orchestrator/claude` で停止理由 (limit の文言、exit code、末尾の public-safe な要約) を
  書き `state: blocked` にし、`次の入口` に続きの入り方 (下記) を書く。uncommitted な変更は
  staged / unstaged / untracked をすべて run directory に退避し (staged と unstaged は patch、
  untracked は file の写し)、その path を記録する。復元を確認するまで worktree を消さない。
  orchestrator が代わりに commit しない (trailer が Claude になり author が混ざる)。自動で再起動
  しない (残量は申告制、#255)。続きは同じ branch を Codex が続ける (同 author なので同じ PR)。
  Claude が続けるなら新しい branch + 新しい PR (author の交代)。
- **非対称**: 委譲は Claude → Codex の一方通行 (運用規則)。根拠として実測しているのは、Codex の
  sandbox から herdr の socket に届かないこと (#251) までで、Codex 側から Claude を起動する経路は
  持たない。Codex が worker のとき、review や次の worker の起動は Claude か人が行う。同時に
  走らせる worker は orchestrator session あたり 1 つ (並列は #256)。

## 関連

- #251 (umbrella: herdr 前提の運用形) / #253 (この規約) / #291 (pull) / #254 (委譲 skill) /
  #255 (割当規則) / #256 (並列運用と pane / tab)
- [git-hook-gates](git-hook-gates.md) (public-safety gate の stdin mode) /
  [publication-safety](publication-safety.md)
