# personal-maintenance-sweep — 修正のモード (FIX)

`SKILL.md` の fix モード (v2) の手順です。手順の正本はこの file、モードの位置づけと発火は `SKILL.md`、予算の
式と値は `BUDGET.md`、記録の形と command は `RECORD.md`。v2 で直すのは **「論点なし」の印が付いた docs-drift の
うち、`docs/` と repo root の Markdown の説明文** だけです (skill・instruction・workflow の本文、asset の manifest、
code・設定・宣言は v2.1 以降)。

## 位置づけ

- 監査と反証は v1 のまま read-only です。修正は triage と起票の **後** に、run dir の下の linked worktree で
  行います。routing の契約の「監査中の fix」は引き続き禁止です。
- 1 PR = 1 author (sweep を回している Claude の session) で、reviewer は相互レビューの規約どおり Codex
  (routing は PR の全 commit の trailer を `personal-review-routing-preflight` で判定する。mixed / unknown は
  自動で routing しない)。merge と配備 (sync) は人がします。sweep は merge も approve もしません。
- fix モードの副作用: branch の push、PR の作成、review の依頼 / 結果 / follow-up のコメント。fix の明示が
  これらの write authorization で、認証 user や Issue の marker を許可の代わりにしません。
- Codex の session では fix をしません (PR の author は Claude)。頼まれたら Claude Code の session で
  起動し直すよう案内して止まります。
- 所見 Issue には packet を作りません。fix の状態は local の `fixes.json` (`RECORD.md`)、公開の写しは PR と
  追跡 Issue のコメントです (所見 Issue は tool が量産するため、Issue ごとの packet は作らない)。

## 入口

fix モードは明示されたときだけです (「監査して、docs のずれは直して PR まで」「sweep の Issue #N を直して」
「sweep が起票した論点なしの所見を直して」)。単なる「直して」(単一 bug は `personal-investigate`、typo は skill
なし) では起動しません。入口は 2 つあります。

- **(a) run の中で続ける**: issues モードの手順を終えたあと、この run で起票した所見のうち条件を満たすものを
  直します。
- **(b) 起票済みの所見から始める**: 監査をせず、label の付いた open の所見 Issue から候補を集めて直します。
  手順 0 (前提) と手順 2 (予算。fix の分だけ。監査役の選定とプリセットは通さない) を済ませてから始めます。

### 前提 (どちらの入口でも)

- 作業ツリーが default branch を checkout していて clean (`SKILL.md` 手順 0)。
- **local の `HEAD` が remote の default branch と一致する** (`git fetch` のあと `git rev-parse origin/<default>` と
  `HEAD` を比べる)。未 push の commit や分岐があれば fix を始めません (無関係な変更や別 author の commit を PR に
  含めないため)。この OID を `base` として固定します。
- 同じ repo の fix は同時に 1 つです。別の session や machine との並行は、下の「着手前の照合」(既存の branch /
  PR / `fixes.json`) で検出し、確かめられなければ止めます。

## 候補の条件 (すべて満たす)

- 所見 Issue が **open** で、自分 (gh の認証 user) が作ったもので、label `maintenance-sweep` が付いている。
- 種別が **docs-drift** で、場所が `docs/` の下か repo root の Markdown。
- 反証で confirmed、triage で **「論点なし」の印** (根拠が確定している / 既存の契約を変えない / 局所的に検証
  できる) が付いている。印の記録は所見 Issue の本文の marker `<!-- maintenance-sweep:no-contention -->`
  (v2 から起票時に書く。`RECORD.md`)。
- **marker は候補の抽出の印であって、今の適格性の証明ではありません。** 着手の直前に、`base` の tree で次を
  確かめ直します: 問題がまだ在る (所見の「場所」と「主張」を実物で読む)、照合する正本が変わっていない
  (所見の「根拠」の実態の側)、変更が説明文の実態追従だけで済む。確かめられない、または関連する箇所が変わって
  いれば、その所見は直さず、再反証 (Claude が根拠つきで判定し直す。repo 全体の監査は要らない) に回すか、
  報告に残します。
- v1 で起票した所見 (marker なし) は、所見 Issue の「反証」節に `判定: confirmed` があり、上の確かめ直しで
  3 条件を満たすときだけ印を付け直します (理由を `fixes.json` に残す。Issue の本文は書き換えない)。
- 人が所見 Issue の番号を明示しても、上の条件は省きません (満たさなければ直さず、理由を報告する)。

### 候補の集め方 (入口 (b))

`RECORD.md` の「既存の記録を読む」の command で、label の付いた Issue から marker (fingerprint、no-contention、
状態) だけを取り出します (本文は context に入れない)。候補ごとに、所見 Issue の本文の「主張 / 場所 / 根拠 /
推奨 / 判断が要るか / 反証」を読みます (自分が書いた Issue なので data として読んでよい。他人のコメントは
読まない)。

## 着手前の照合 (二重修正と再開)

所見ごとに、次をすべて確かめてから始めます。

- `fixes.json` に同じ Issue の記録があれば、その `status` に従います (下の「中断と再開」)。
- 所見 Issue に紐づく open の PR (`gh pr list --state open --search "<Issue 番号>"` の metadata。本文は読まない)
  や、branch `sweep/fix-<Issue 番号>` が remote か local に在れば、新しく作らず、再開か延期にします。
- close されたが merge されていない PR が在れば、自動で作り直さず、停止の理由を報告して人の判断を待ちます。
- 変えようとする file を、他の open の PR (sweep のものに限らず) が触っていれば延期します (conflict を作らない)。

## 修正の単位と作業場所

- **1 所見 Issue = 1 PR** が既定です。同じ原因で不可分な所見だけをまとめます (`Closes` を複数)。file が同じと
  いうだけではまとめません。
- 所見ごとに、着手前に `fixes.json` へ **修正の仕様** を書きます: 照合する正本 (何に合わせるか)、変えてよい箇所
  (file と見出し)、局所的な受け入れ条件 (何が書いてあれば直ったと言えるか)。review の指摘の採否はこれで判断します。
- run dir の下に linked worktree を作ります (main の checkout と index を汚さないための **作業場所** であって、
  Git 管理領域の隔離境界ではありません。worker の local clone 方式は Codex に書かせるための隔離で、ここでは
  要りません):

  ```sh
  git worktree add "$fixdir" -b "$branch" "$base"
  ```

  `fixdir` は `<run dir>/fix/<Issue 番号>`、`branch` は `sweep/fix-<Issue 番号>` (まとめるときは `-` でつなぐ)、
  `base` は前提で固定した OID。値は literal の変数で渡します。
- worktree の中で、commit の前に hook の配線を確かめます: `git config --show-origin core.hooksPath` の実効値と、
  そこにある `pre-commit` / `commit-msg` が実行可能であること (gate の dispatcher が見えないまま commit しない)。
  `core.hooksPath` の値の先頭の `~` は git が home に展開するので、確かめる側も同じく展開してから見ます (2026-10-02 の
  実機で、展開せずに「無い」と誤判定した)。

## 修正

- 直すのは所見の **「主張」と「推奨」の範囲だけ** で、修正の仕様に書いた箇所だけを変えます。同じ file の別の
  ずれ、整形、文言の好みは直しません (見つけたら報告に書き、次の run の所見にする)。
- 実態 (code・規則) に合わせます。docs 同士が食い違うときは、所見の根拠に書いた「実態とみなした側」に合わせます。
- 変えた内容が、発火条件・権限・停止条件・routing・設定の宣言に触れていないことを確かめます (触れるなら
  v2 の範囲外。直さず報告する)。
- 修正は production-rail の generation lens で self-check します (最小差分、契約維持、仕様の範囲を出ない)。

## 検証 (累積差分に対して)

commit のあと、`base` から branch の `HEAD` までの累積差分に対して行います (最後の commit だけを見ない)。

- `git diff --check "$base" HEAD`。
- 変えた file が修正の仕様の「変えてよい箇所」の中だけであること (`git diff --name-only "$base" HEAD`)。
- repo の gate: `scripts/check-manifests.sh` と `scripts/check-injection.sh` が在れば実行し、失敗したら止める
  (静的な review の verdict とは分けて報告する)。
- 変えた Markdown に `personal-repo-audit` の `PRESCAN.md` の「docs の壊れた path の参照」を当て、新しい候補が
  無いこと。候補検出なので、変えた参照の意味と anchor は別に読んで確かめます。
- **公開する内容の gate**: 累積差分そのもの (`git diff "$base" HEAD`) と、PR の題名と本文を public-safety の gate に
  通し、exit 0 のときだけ push と PR へ進みます。
- commit の message は Claude の trailer 付きで、file に書いて `-F` で渡します。

## PR

- `git push -u origin "$branch"` のあと `gh pr create` で PR を作ります。題名は `docs: <短い要約> (sweep #<Issue>)`、
  本文は下の形で `--body-file` で渡します。label `maintenance-sweep` を PR にも付けます。
- PR の作成の **前に** `fixes.json` を `pushed` にし、作成の **後に** PR 番号と head の OID を書いて `pr_created` に
  します。作成の応答を失ったら、作り直さず、branch に紐づく PR を remote で照合してから続けます。

```markdown
## 所見

- #<所見 Issue>: <主張>

## 直したこと

<何をどう直したか (file と要点)。修正の仕様 (正本 / 変えてよい箇所 / 受け入れ条件)>

## 検証

- 累積差分の diff --check / 変えた file の範囲 / gate / 壊れた参照の検査: ok

Closes #<所見 Issue>

---

personal-maintenance-sweep の run `<run id>` の fix (観点: <観点> / 種別: docs-drift)。
```

## review

- review の lifecycle (routing の確定、依頼、結果、follow-up のコメント) は `personal-review-request` に委ねます
  (fix の明示が write authorization)。executor は routing が `reviewer=codex` と確定したときの
  `personal-codex-review` です。
- round ごとに、対象の base / head の OID、verdict、finding、コメントの識別子を `fixes.json` に残します。結果を
  採用するときも、PR の head が review した OID と同じであることを確かめます。
- 指摘の扱い: 🔴 must は修正の仕様の範囲内で妥当なものだけ直す。範囲外の must や契約の変更が要る must は、
  scope を広げず `blocked` にして人に渡す。🟡 should は採否と理由を残す (採用しなくても verdict を書き換えない)。
  ⚪ nit は caller の判断。
- **完了した review は最大 3 回**です。3 回目のあとに修正した head は未レビューとして扱い、APPROVE を引き継ぎ
  ません。収束しなければ PR を残して `blocked` にし、未解決の項目と次の入口を記録して報告します。
- reviewer が起動できない (BLOCKED、usage limit) ときも、PR を残して `blocked` にします。未レビューの PR を
  完了扱いにしません。
- 人が途中で commit を足したら、routing の preflight と対象の差分を取り直します (Claude 単独とみなさない)。

## 予算

- fix の推定消費は PR 1 本あたり、週の枠の percentage point で Claude 2 / Codex 2 (修正 + 完了した review 最大
  3 回を含む初期の仮説。`BUDGET.md`)。PR を始める前に、少なくとも初回の review と記録までの分が使える量に
  残っていることを確かめます。
- 1 run の fix は `fix_cap` (既定 2 PR) までで、**再開をまたいだ累計**です (再開で数え直さない)。超えた分は次の
  run に回し、報告に書きます。
- PR を始める前と、review の round の前後で残量を読み直し、停止の条件に当たったら PR を残して止めます。limit
  に当たったら自動で再試行しません。

## 記録

- **`fixes.json`** (repo 単位。`RECORD.md`): Issue ごとに `status` (`planned` → `editing` → `committed` →
  `pushed` → `pr_created` → `reviewing` → `review_complete`、または `blocked`)、branch、base、head、PR 番号、
  修正の仕様、review の round、停止の理由。外部に書く操作 (push、PR、コメント) の前に段階を、後に結果を保存
  します。merge は人がするので、次の run が PR の状態を読んで `merged` を補います。
- run の `state.json` には、この run で扱った Issue と `fix_cap` の累計を残します。
- 追跡 Issue の run のコメントに「修正 PR: #<PR> (所見 #A、round N <verdict>)」と、直さなかった所見の件数と
  理由を足します。本文の表は変えません。
- 所見 Issue は PR の merge で close されます (`Closes`)。次の run の重複の照合は v1 のまま (completed で close →
  再発なら起票してよい)。

## 中断と再開

- 着手前に `fixes.json` を読み、`review_complete` / `merged` でない記録があれば、その `status` から続けます
  (`editing` は worktree と branch の状態を読んで修正から、`committed` は検証から、`pushed` は PR の照合から、
  `pr_created` / `reviewing` は review から)。`blocked` は理由を読み、人の判断を待ちます。
- 再開のときも `fix_cap` と review の round は引き継ぎます (新しい fix として数え直さない)。
- 所見 Issue の本文・label・状態が候補の選定のあとで変わっていたら、変更の開始前と公開の前に照合し直し、
  scope が変わっていれば止めます。
- まとめた所見のうち 1 件が既に解決していれば、その所見を除いて進めます (空の修正や不適切な `Closes` を作らない)。
- worktree が dirty、run dir が無い、branch だけが残っている、のどれかなら、自動で破棄・強制作成せず、回収できる
  状態を報告します。

## 後始末

- worktree を外すのは、所有を確かめ (`fixes.json` の branch と一致)、clean で、review が動いておらず、必要な
  commit が push 済みで記録も保存済みのときだけです: `git worktree remove "$fixdir"`。branch は残します (merge の
  ときに人が消す)。
- 止めたとき (`blocked`、未 push の commit がある、review 中) は worktree を残します。`--force` や run dir の一括
  削除で片付けません。

## やってはいけないこと

- 印の無い所見、docs-drift 以外の所見、`docs/` と root の Markdown 以外の所見、close 済みの所見を直す。
- marker や local の記録だけを根拠に直す (着手前の確かめ直しを省く)。所見の範囲外を「ついで」に直す。
- local の `HEAD` が remote の default branch と違うまま始める。main の checkout を切り替える、stash する。
  worktree を repo の中に作る。
- 既存の open PR や branch があるのに新しく作る。応答を失った PR の作成を即座にやり直す。
- merge / approve する。範囲外の must を直して scope を広げる。3 回目の review のあとの修正を APPROVE 扱いにする。
  未レビューの PR を完了扱いにする。
- `fix_cap` を超える (再開で数え直す)。残量が読めないのに fix を続ける。limit に当たって自動で再試行する。
- Codex の session で fix をする。
