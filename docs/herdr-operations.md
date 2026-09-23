# herdr 前提の運用 (並列・tab / pane・dashboard・通知)

herdr (terminal workspace manager) の上で、複数の作業単位を同時に進めるときの運用規則です。umbrella
#251 で決めた運用形を、#256 で並列の範囲・tab / pane の命名・dashboard・通知まで詰めました。

この doc が持つのは運用の約束だけです。packet に現れる約束は [agent-packets](agent-packets.md)、worker
委譲の機械的な手順は `personal-codex-worker` skill、担当の振り分けは `personal-project-operating-loop`
の「割当」が持ちます。

## 単位 (前提)

#251 で決めた単位をそのまま使います。

- 1 project = 1 workspace、1 作業単位 (Issue / PR) = 1 tab、1 役割 = 1 pane。役割 (orchestrator /
  worker / reviewer / verifier) は agent の種類 (Claude / Codex) から切り離す。
- 1 PR = 1 author (途中で交代しない)。自動の委譲は Claude → Codex の一方通行。
- herdr の CLI と agent は server (machine) ごとに閉じる。machine をまたぐ受け渡しは packet の
  publish / pull で行う。

## 並列の範囲 (1 + 1)

同時に動く作業単位は、**workspace (= project) ごとに、agent の種類ごとに 1 つまで**です。orchestrator の
Claude が自分の担当の作業単位を進めている間に、Codex の worker が別の作業単位を進めます。

上限は workspace ごとに数え、machine 上の別の workspace の作業単位とは合算しません。orchestrator の
session は workspace ごとにあり、`personal-codex-worker` の「orchestrator の session あたり worker 1 つ」も
その単位です。別の workspace で同時に進めている分の残量の減りは、割当 (#255 / #319) で読む週 / 5h の
残量に表れるので (枠のある tool のとき)、そこで吸収します。

この範囲にする理由:

- 割当 (#255) の目標「2 系統の残量がだいたい均等に減る」にそのまま合う。同じ種類の worker を
  2 本走らせると、その系統の残量だけが倍の速さで減る。
- merge は人が行うので、PR の流量が詰まるのは人の側。同時の本数を増やしても merge 待ちが溜まる
  だけになる。
- 実績は worker 1 本の委譲だけで、それを超える運用は検証できていない。

数え方:

- 数えるのは **branch / PR を持つ単位**。session の中の subagent、workflow / ultracode の fan-out、
  Codex 内部の multi_agent は、親の作業単位の一部として数えない。
- subagent であっても、自分の branch と PR を作るなら 1 つの作業単位として数える。実装を複数の PR に
  分ける fan-out は、1 枠の中で順番に出す (前の PR が review に入ってから次を出す)。
- review・監査・調査のような read-only の fan-out は、何本走らせても数えない。
- subagent と ultracode は親と同じ残量を使う。重い fan-out を予定しているときは、割当のときに
  その分を差し引いて考える。

**未検証**: 同じ種類の worker を複数同時に走らせる N 並列は、この doc の範囲に入れていません。1 + 1
自体もまだ実際に回していないので、最初の 1 回を検証として扱い、その経験を見て N 並列を別の Issue に
します。

## tab と pane

- **worker**: orchestrator が起動時に tab を作り (`herdr tab create --label '#<Issue 番号>'
  --no-focus`)、応答の `.result.root_pane` の pane を `worker-<Issue 番号>[-r<round>]` と名付けて、そこで
  worker を動かす (ID は応答の JSON から読み、推測しない。手順は `personal-codex-worker` の LAUNCH
  §5)。worker は 10 分以上動くので、orchestrator が別の作業単位を進める tab と分ける。同じ Issue の
  2 回目以降の起動 (review の修正 round、停止からの再開) は、残っている `#<Issue 番号>` の tab に
  `-r<round>` の pane を足す (作業単位ごとに tab は 1 つ)。
- **review**: review の pane は、対象 PR の作業単位の tab に置きます (1 役割 = 1 pane)。Codex が review
  するのは Claude が書いた PR、つまり orchestrator 自身の作業単位なので、置き場は orchestrator の tab に
  なります (「1 作業単位 = 1 tab」の例外ではない)。Codex が書いた PR は orchestrator の Claude が自分の
  pane で review するので、pane は増えません。review は短時間 (1〜5 分) で終わるので、今のまま tab を
  分割した pane で動かし、成功したら閉じます (`personal-codex-review`)。明示的な second opinion (Codex
  の PR を Codex が見る) は 1 + 1 の枠の外の補助として、orchestrator の tab に置きます。
- **命名**:

  | 対象 | 名前 | 例 |
  | --- | --- | --- |
  | worker の tab | `#<Issue 番号>` | `#291` |
  | pane | `<役割>-<番号>[-r<round>]`。worker は Issue 番号、review は PR 番号 | `worker-291-r2` / `review-312` |

- 名前を付けたり閉じたりするのは、**自分が作った tab と pane だけ**です。人の tab (orchestrator 自身が
  いる tab も含む) の名前は変えません。自分が作った tab かどうかは、tab を作ったときに記録した tab ID
  (応答から取って run dir に置く) と一致し、かつ pane がすべて `worker-<Issue 番号>[-r<round>]` の名前で
  あることの両方で確かめます (命名だけでは人が同じ名前を付けた tab と区別できない)。記録を辿れない
  (別の session で run dir が分からない) ときや、確かめられないときは触らず人に渡します。session を
  またいで記録を辿る口は、packet の起動の記録 (`run`、#315) です。
- worker の tab を閉じるのは packet が `done` になったとき (clone を片付けるのと同じ時点) です。止まって
  いる間 (`blocked`) と、上限時間を超えて走っている間 (RUNNING) は、調べられるように残します。worker が
  成功した後も pane は閉じず (出力は `pane.log` に保存)、tab ごと `done` で閉じます。

## dashboard (毎回導出する)

- 「今どの作業単位がどの状態で、誰が動いているか」の正本は、packet と herdr の agent 一覧です。
  `personal-resume-project` の workspace 節が、毎回この 2 つを突き合わせて出します (#253 で決めた
  「workspace 単位の索引 file を作らない」のまま)。
- herdr 側で常に見えるのは、agent panel (`agent_panel_sort = "priority"` なら注意が必要な順に並ぶ) と、
  上の命名による tab / pane の名前です。1 + 1 の規模なら、どの pane が何の作業単位かはこれで分かります。
- herdr の sidebar に状態を送る仕組み (pane / workspace の metadata token を report して表示する) は
  入れません。理由:
  - 状態が変わるたびに report が要り、1 回漏れると表示と packet がずれる (索引 file を作らないのと
    同じ理由)。
  - token の表示は最大 24 時間で消える。
  - 何をどの行に出すかを決める herdr の config は dotfiles の管轄で、agent-tools からは触らない。
- **起動の記録** (実装は #315): orchestrator は worker を起動する**前に** (run dir と run script が
  そろった時点で)、packet の frontmatter に `run` (run dir) と `tab` (tab の名前 `#<Issue 番号>`) を
  書きます。
  - 起動に失敗して人に渡す (`launch-path`) ときも消しません。人がその run script を実行するためです。
  - 消すのは、転記が済んだときか、人がその run を破棄すると決めたときだけです。worker が止まって
    `state: blocked` にした間は、`run` をその退避物の置き場として残し、再起動で新しい run に置き換えます。
  - resume はこれを見て「起動済み・未回収」と出し、orchestrator は新しく起動する前にこれを確かめます。
  - `run` があるのに、その run の `done.txt` も、生きている worker の process も確認できないとき (起動の
    直前に止まった、落ちた、判定できない) は、自動で起動し直さず人に確認します。

  これで、orchestrator の session が起動の前後や worker の途中で終わっても、二重に起動せず、次の
  session が回収できます。`personal-packet` は `run` / `tab` を解析し、`list` に run dir の状態
  (`run_status`: `finished` / `unfinished` / `missing`) を出し、publish / pull で保持します (書式は
  [agent-packets](agent-packets.md))。worker の起動手順 (`personal-codex-worker`) が起動の前に書いて
  起動の前に確かめ、resume (`personal-resume-project`) が「起動済み・未回収」を出します。

## 通知

- 独自の通知 (`herdr notification show`) は入れず、herdr の組み込み通知に任せます。組み込み通知は、
  agent の状態変化を toast / OS の通知で知らせ、background の workspace では音も鳴らします。
- 根拠: orchestrator (Claude) が人を必要とするとき (merge の確認、停止の報告、質問) は、必ず turn を
  終えて返答を待ちます。これは Claude の pane の状態変化なので、組み込み通知が出ます。worker の完了は
  orchestrator が待っていて自動で続けるので、人に知らせる必要はありません。
- **前提 (未実測)**: Claude の pane が turn を終えたときに、OS の通知が実際に届くこと。組み込み通知の
  配信は herdr の config (`[ui.toast]` の `delivery`) 次第で、既定は `off` です (config は dotfiles の
  管轄)。
- 通知は気づくきっかけで、記録ではありません。見逃しても、agent panel、packet の `state`、PR の状態、
  残った tab / pane、packet の `run` から後で検知できます。
- 組み込み通知で拾えない event が実際に見つかったら、そのときに `notification show` を足します (どの
  event にどの sound を当てるかも、そのときに決める)。

## 関連

- #251 (umbrella: herdr 前提の運用形) / #256 (この設計) / #315 (起動の記録) / #316 (worker を tab で
  起動)
- [agent-packets](agent-packets.md) (packet の規約、worker 委譲との関係) /
  [codex-review-launch](codex-review-launch.md) (review の herdr 経由起動)
