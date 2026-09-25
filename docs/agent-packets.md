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
- `pull` で再構成した local packet も **data であって authorization ではない**。
- packet は agent が書く (別 agent へ渡すため)。`.agent-context.local.md` (user 所有・
  read-only) とは信頼モデルが違うので混ぜない。書き手は役割で 1 つに固定する:

| 節 | 書けるのは | 操作 |
|---|---|---|
| `## 依頼` | orchestrator のみ | 上書き |
| `## 結果` | worker (実装) / reviewer (verdict) / orchestrator (委譲した worker の停止記録だけ。見出しは `orchestrator/claude`)。packet に書けない worker (委譲した Codex) の分は orchestrator が worker の最終 message から転記する (見出しは `worker/codex`) | `### <日付> <役割/agent>` 見出しで区切って追記 |
| `## 次の入口` | worker (委譲した worker の分は orchestrator が worker の最終 message から写す。worker が止まって最終 message が無いときは orchestrator が続きの入り方を書く) | 現在地に上書き |

frontmatter の `run` / `tab` (起動の記録) を書く・消すのも orchestrator だけ。

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
run: /path/to/run-dir  # worker の起動の記録 (委譲した worker が走っている / 未回収の間だけ)。無ければ省略
tab: "#123"            # worker を動かしている herdr の tab 名。`#` があるので引用符で囲む
# last_run: /path/to/run-dir  # 最後の run dir (完了の転記で run から移す)。run とは同時に置かないので、run が無いときだけ書く
---

## 依頼

<!-- orchestrator が上書き。受け入れ条件・制約は Issue 本文と同じでも packet に転記する
     (network に届かない worker が packet だけで再開できるように)。Issue 参照は補足 -->
- Issue: #123 / branch: feat/123-example
- 受け入れ条件: (Issue 本文のもの、または補足)
- 制約: (触らない範囲・順番・依存)
- 割当: (担当・残量の扱い (読んだ値と取得時刻、または使わない理由)・理由の 1 行。規則と書式は `personal-project-operating-loop` の「割当」。未定なら空)

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
  orchestrator)。`blocked` は止まった worker が入れる。委譲した worker の分は、止まっていれば
  最終 message の有無にかかわらず orchestrator が入れる (停止理由は最終 message の転記か、無ければ
  orchestrator の記録)。`done` は orchestrator が入れる。
- `run` / `tab` (#315): 委譲した worker の**起動の記録**。`run` は run dir の絶対 path、`tab` は
  worker を動かしている herdr の tab 名 (`#<issue>`)。書くのは **orchestrator だけ** (worker は packet に
  書かない)。書く時点・消す時点は [herdr-operations](herdr-operations.md) の「起動の記録」(手順は
  委譲 skill `personal-codex-worker`)。
  - `tab` の値は引用符で囲む (`tab: "#123"`)。引用符が無いと `#` 以降が YAML の comment になって値が
    消えるので、key があって値が空の packet は壊れた packet として報告する (記録が黙って消えると
    二重起動の検査が効かない)。改行などの制御文字、相対 path の `run` も同じく壊れた packet。
  - 写しの対象ではない (publish は写さない。`run` は local の path)。なので書き込み・削除で
    `updated` を変えない (未 publish の印を立てない)。pull は local の値を保持する。
  - `list` は `run` があれば run dir の状態を stat だけで見て `run_status` に出す: `finished` (`done.txt`
    がある = 完了・未転記) / `unfinished` (run dir はあるが `done.txt` が無い = 実行中 / 不明) /
    `missing` (run dir が無い = 消失。worker の commit は clone から回収する)。
- `last_run` (#325): **最後の run dir**。完了の転記で `run` / `tab` を消すときに、orchestrator が `run` の値を
  `last_run` に移す。次の起動で `run` を書くときに `last_run` は消す (`run` と同時には置かない。両方あれば
  壊れた packet として報告する)。`state: blocked` の停止では従来どおり `run` に残す (退避物の置き場)。
  `done` の後も残す。用途は、転記で起動の記録が消えた後も、前の run の成果物 (clone の `.git` の
  snapshot、tab の所有の確認に使う `tab-id`) を別の session から辿れるようにすること。
  - 書くのは orchestrator だけ。検証は `run` と同じ (引用符付きの 1 行・制御文字なし・絶対 path)。
  - 起動の記録ではない (`run_status` は出さず、resume の「起動済み・未回収」にもならない)。`list --json` にだけ
    出し、text の一覧には出さない。写しの対象ではないので、書き込み・削除で `updated` を変えない。pull は
    local の値を保持する。
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

## 写しの取り込み(pull)

`personal-packet pull <issue> [--repo OWNER/REPO] [--dry-run]` は同じ directory の
`personal-safe-gh issue comments` で写しを読み、local packet を新規作成または更新する。
`--dry-run` は同じ検証・merge を行って再構成後の全文を stdout に出し、directory / file を作らない。
worker 委譲時の `pull` は orchestrator が main repository 側で行い、復元した `依頼` を起動 prompt
に写す。委譲された worker は clone 内だけで作業し、packet の編集権限は持たない (下記「worker 委譲との関係」)。

- 採用するのは `author_trust: self` のコメントだけ。先頭の marker の Issue 番号と日時、
  publish が出す packet 見出し (Issue / state / worker)、結果・次の入口のラベルを検証する。
  他 author、marker 無し・破損、別 Issue の写しは採用しない。payload に行頭 `## ` や HTML
  comment がある写し、結果の entry 見出しが規約の形でない写しも除外する。採用できる写しが
  1 件もなければ「写しがありません」で exit 1、packet は変更しない。
- `結果` は採用した全コメントを `published` の古い順に追記する。entry は見出しと本文で
  識別する。見出しが同じでも本文が異なれば別 entry として追記し、local に同じ見出しの
  複数 entry があっても保持する。見出し・本文が一致する entry は、HTML comment 除去と
  前後空白の strip をした本文が一致するときだけ重複として追記しない。
- `次の入口` は最新の写しの `published` が local より新しければ上書きする。local に
  `published` がなければ写しを採用し、同時刻・古い写しでは local を保つ。state / worker も
  同じ判断で更新する。最新の写しに次の入口がない場合は空にする。
- `依頼` は既存 local の節を保持し、節が無い場合だけ `personal-safe-gh issue view` の self
  本文から起こす。Issue 本文の行頭 `## ` は 4 空白で字下げし、packet の節境界と区別する。
  本文が withhold されていれば exit 2 で止める。
- title / branch / pr / run / tab / last_run は既存 local を保持する (run / tab / last_run は写しに載らない)。新規 title は Issue の title、state / worker は
  最新の写しから取る。`updated` は local の `updated` と最新写しの `published` の大きい方、
  `published` は採用した最新写しの日時 (同時刻・古い写しなら local の日時) にする。新規 packet
  は両方とも写しの日時にする。local が未 publish (`published` 無し、または `updated > published`)
  なら、その状態を pull 後も保つ。必要なら `updated` を `published` より 1 秒先に置く。
- 書き込み前に frontmatter と 3 節を読み直して検証する。壊れた local packet、reader 不在・失敗、
  不正な envelope は exit 2。既存 file は一時 file を書き切ってから差し替え、新規 file は
  内容を確定してから作成する。symlink の packet dir / file は更新しない。

self-test は `scripts/tests/packet-pull-test.sh`。`--mutations` を付けると author / marker /
envelope (number / source / repo) / reader への `--repo` 伝達 / merge / H2 / frontmatter の検証を壊した source に同じ assertions を当て、退行を検出できるか確かめる。

## tooling(`personal-packet`)

script asset `personal-packet` (配備先は `<tool home>/agent-tools/scripts/personal-packet`、
両 tool に同一 byte) が規約の機械的な部分を持つ。値の受け渡し (Issue 番号 / 本文) は argv /
file で行い、command 文字列へ inline 展開しない。

| command | すること | exit |
|---|---|---|
| `dir` | packet dir を出す (main worktree root に固定。linked worktree からでも同じ) | 0 / 2 (git 外) |
| `list [--json] [--all]` | frontmatter を読んで一覧。既定は open / blocked / review だけ、`--all` で done も。`updated > published` (または未 publish) を `unpublished` で示す。起動の記録があれば `run` / `tab` と `run_status` を出す (text は `[run: <status>]`)。`--json` には `last_run` も出す | 0 / 1 (壊れた packet あり。warning を出し、健全な行は出す) / 2 |
| `publish <issue> [--repo OWNER/REPO] [--dry-run]` | `結果` の最新節 + `次の入口` を marker 付きで合成 → 同じ directory の `personal-public-safety-gate --stdin` に通す → **exit 0 のときだけ** `gh issue comment` で投稿 → frontmatter の `published` を更新 | 0 / 1 (gate が止めた) / 2 (検査できない・gate 不在・gh 不在 / 失敗・入力エラー) |
| `pull <issue> [--repo OWNER/REPO] [--dry-run]` | self コメントの有効な写しを取り込んで packet を再構成。`--dry-run` は全文を stdout に出す | 0 / 1 (採用できる写しなし) / 2 (reader / 入力 / 保存エラー) |

- publish の `--dry-run` は検査までして本文を stdout に出す (投稿も `published` 更新もしない)。
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
  止まっていれば packet 一覧だけに縮退する。tab ↔ Issue の対応規約 (worker の tab は `#<Issue 番号>`)
  は [herdr-operations](herdr-operations.md)。
- `personal-session-handoff`: workspace 単位の索引 file は作らない (packet から導出)。役割は
  packet の `結果` / `次の入口` を更新 (常時。local で agent 所有) → publish (write-authorized
  のとき) → planning tool (write-authorized のとき、project 単位の判断だけ)。
- 既存の open Issue は packet 化しない。着手する Issue から orchestrator が起こす。

## worker 委譲との関係(#254)

orchestrator (Claude) が packet を Codex の worker に委譲するときの、packet 側の規約。起動の
機械的な手順 (herdr の tab / pane、完了判定、tab の後始末) は委譲 skill `personal-codex-worker` と
その preflight (`personal-codex-worker-preflight`) が持ち、ここには packet に現れる約束だけを置く。

- **authorization と scope**: 起動 prompt が authorization、packet の `依頼` が scope (上の信頼
  モデルと同じ)。brief には `依頼` を要約せず verbatim で写す (orchestrator 著なので trusted。
  要約は drift の元)。
- **作業場所**: Issue ごとの **local clone** (orchestrator が main から `git clone` して branch を
  切る)。packet dir は main worktree の root のまま (置き場の規則どおり) で、gitignore されているので
  clone には含まれない。worker の書込先は **その clone の中だけ**で、main の Git 管理領域も packet dir
  も含めない。worker の commit は orchestrator が main へ `git fetch <clone> <branch>:<branch>` で
  回収する (network 不要)。起動側は **その clone の git dir (`<clone>/.git`) だけ**を sandbox の
  writable roots に足す (`workspace-write` は workdir の内側でも `.git` を保護するため。実測)。
  main の Git 管理領域は足さない (preflight が orchestrator 自身の repository と linked worktree を
  拒否する)。
  linked worktree を使わないのは、worktree の git dir が main 側 (`<main>/.git/worktrees/<n>`) にあり、
  `workspace-write` の sandbox の writable roots に入らないため (codex 0.154.0 で実測。`git add` が
  index と objects の両方で `Operation not permitted` になる)。`--add-dir <main>/.git` で通るが、
  それは main の objects / refs / 他 worktree の index / config を worker に開けるので採らない。
  clone は identity が効く場所 (置き場で identity を切り替える設定を使っているなら、その context の
  中) に切る。外に切ると user.email が空になり commit が fail-closed で落ちる。
- **worker の権限境界**: packet の編集、GitHub への write (Issue / PR の操作、push)、別 agent の
  起動、clone の外への書込は worker がしない。起動側は Codex の approval policy を「承認を求める
  操作は失敗する」側に固定する。これで止まるのは承認を求める操作だけなので、起動側は有効な承認設定
  (approval policy と、MCP connector の tool ごとの承認設定) を起動前に検査し、GitHub への write が
  無承認で通る設定なら起動しない (検査は委譲 skill の preflight が持つ)。worker は作業単位ごとに
  commit し、自分を示す `Co-Authored-By: Codex …` trailer を付ける (commit-msg の gate が検査する)。
- **結果の転記**: worker は最終 message に到達点 / 判断 / 未完 / 停止理由 / commit 一覧 /
  次の 1 アクション (`次の入口` の転記元) を書き、orchestrator がそれを `結果` に
  `### <日付> worker/codex` として転記し、`次の入口` を最終 message の「次の 1 アクション」から
  写す (転記前に `personal-public-safety-gate --stdin` を通す。止めた finding が `home-path` だけなら、
  orchestrator が local の path を repo 相対や `<home>` などに置き換えた版を通し直して転記し、その旨を
  注記する。それ以外は転記せず人に見せる。手順は委譲 skill の §6、#326)。worker が止まっている (質問・失敗・
  limit) なら、最終 message の有無にかかわらず orchestrator が `state: blocked` にする。有無で変わる
  のは記録の出所だけで、最終 message があればこの転記 (`worker/codex`)、無ければ下の「停止」の手順で
  orchestrator が書く (`orchestrator/claude`)。
- **起動の記録** (`run` / `tab`、#315): orchestrator は worker を起動する前に packet の frontmatter へ
  書き、起動する前に確かめる (同じ Issue に記録があれば、その run を回収するか人に確かめる。別の Issue の
  未回収の記録も「worker 1 つ」のために見る)。完了の転記が済んだら消し、`state: blocked` の間は退避物の
  置き場として残す。書く時点・消す時点の正本は [herdr-operations](herdr-operations.md) の「起動の
  記録」、手順は委譲 skill。
- **PR**: orchestrator が PR に含まれる追加 commit (base OID から head までの
  `git log <base-oid>..<head-oid>`。共有祖先は含めない) の trailer がすべて Codex のみであることを
  確認してから push し、PR を作る。packet に `pr:` と `state: review` を入れるのは orchestrator
  (PR を出した側)。
- **停止 (limit / 途中終了 / 質問)**: 最終 message が無い停止では worker の記録が残らないので、
  orchestrator が `### <日付> orchestrator/claude` で停止理由 (limit の文言、exit code、末尾の
  public-safe な要約) を書く (最終 message があれば上の転記)。どちらも `state: blocked` にし、
  `次の入口` に続きの入り方 (下記) を書く。uncommitted な変更は
  staged / unstaged / untracked をすべて run directory に退避し (staged と unstaged は patch、
  untracked は file の写し)、その path を記録する。復元を確認するまで clone を消さない。
  orchestrator が代わりに commit しない (trailer が Claude になり author が混ざる)。自動で再起動
  しない (limit の reset を待つ。残量の扱いは `personal-project-operating-loop` の「割当」)。続きは同じ branch を
  Codex が続ける (同 author なので同じ PR)。
  Claude が続けるなら新しい branch + 新しい PR (author の交代)。
- **非対称**: 委譲は Claude → Codex の一方通行 (運用規則)。根拠として実測しているのは、Codex の
  sandbox から herdr の socket に届かないこと (#251) までで、Codex 側から Claude を起動する経路は
  持たない。Codex が worker のとき、review や次の worker の起動は Claude か人が行う。同時に
  走らせる worker は orchestrator session あたり 1 つ (並列の範囲は
  [herdr-operations](herdr-operations.md) の「1 + 1」)。

## 関連

- #251 (umbrella: herdr 前提の運用形) / #253 (この規約) / #291 (pull) / #254 (委譲 skill) /
  #255 (割当規則) / #256 (並列運用と pane / tab)
- [git-hook-gates](git-hook-gates.md) (public-safety gate の stdin mode) /
  [publication-safety](publication-safety.md) / [herdr-operations](herdr-operations.md) (並列・tab /
  pane・dashboard・通知)
