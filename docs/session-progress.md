# session の途中の状態を残す (personal-session-progress)

`personal-session-progress` は、session の目的、段、短い結果、未解決の判断を JSON に保存します (#682)。
記録は agent の自己申告です。承認、実行、回収、review、merge の根拠にはしません。
実体は `shared/scripts/personal-session-progress.rb`。Codex と Claude Code の script として配備します。
Ruby 2.6 と標準 library、git、同じ directory の `personal-public-safety-gate` を使います。
常駐の service、hook、MCP、herdr の呼び出し、session の対応表は持ちません。

## CLI

```text
personal-session-progress update --client CLIENT [--session-id ID] [--dir DIR] --stdin
personal-session-progress show   [--client CLIENT] [--session-id ID | --latest] [--dir DIR] [--json] [--watch SECONDS]
personal-session-progress list   [--dir DIR] [--json]
personal-session-progress locate --client CLIENT [--session-id ID] [--dir DIR]
personal-session-progress --help
```

`update` と `locate` の `--client` は必須です。`codex` か `claude-code` を毎回指定します。
`--session-id` があればそれを使い、省略時は client に対応する env を使います。
Codex は `CODEX_THREAD_ID`、Claude Code は `CLAUDE_CODE_SESSION_ID` です。
両方の env があっても client で選びます。ID が無ければ exit 1。PID や時刻からは作りません。

`show` は明示 ID、env の session、`--latest` のどれかを表示します。
client を省いて env から選ぶ場合、片方の client の env だけがある必要があります。
明示 ID だけなら、その directory で ID が一致する記録を探します。
複数 client に同じ ID があれば exit 2 です。`--latest` は client をまたいで選び、
`--client` もあればその client だけを対象にします。

`locate` は記録の path を 1 行で返します。file の存在は要求せず、directory も作りません。
`--help` は入力の形と例を表示します。各 subcommand の `--help` も同じ説明です。

### 更新の入力

最初の入力の例です。

```json
{"purpose":"session の途中の状態を残す","steps":[{"id":"inspect","title":"既存の規約を確かめる","state":"active"}],"decisions":[]}
```

次の更新では、変える項目だけを渡します。

```json
{"steps":[{"id":"inspect","state":"done","result":"packet と handoff の分担を確かめた"},{"id":"design","title":"記録の形を決める","state":"active"}]}
```

`purpose` は渡したときに置き換え、新規作成では必須です。
`steps` は id で照合し、既存の段は渡した項目だけを置き換えます。
新しい段は末尾に追加し、`title` が必須です。省略した `state` は `pending`、`result` は空文字です。
段を消す口はありません。やめた段は `skipped` にし、理由を `result` に書きます。
`active` は複数あって構いません。

`decisions` は渡したときに全体を置き換えます。解決した判断は一覧から外します。
判断の 4 項目はすべて必須です。選択肢が無ければ `options: []`、推奨が無ければ `recommended: null` にします。

```json
{"decisions":[{"id":"place","question":"記録の置き場をどこにするか","options":["作業ツリーの中","別の場所"],"recommended":0}]}
```

時刻、revision、履歴を入力から変更する口はありません。
空の更新も revision と更新時刻を進めます。段の内容が変わらなければ履歴は増えません。

### exit と出力

| exit | 意味 |
| --- | --- |
| 0 | 成功 |
| 1 | 入力・置き場・中身の検査による拒否 |
| 2 | usage、I/O の失敗、想定外の例外 |
| 3 | lock を 2 秒待っても取得できない |
| 4 | `show` の対象の記録が無い |
| 130 | watch 以外の command が SIGINT で中断された |

`update` の成功時は `{"ok":true,"revision":3,"updated_at":"…"}` を stdout に 1 行出します。
失敗時は stdout を空にし、stderr には種別と項目名だけを出します。
入力値、本文、parser や OS の例外本文、gate の出力は転記しません。
watch では、それまでの成功した表示は残ります。Ctrl-C で exit 0 により停止します。

## 記録の形

session ごとに 1 file です。最新の状態と、上限つきの段の変更履歴を持ちます。

```json
{
  "schema_version": 1,
  "client": "claude-code",
  "session_id": "example-session",
  "revision": 3,
  "created_at": "2026-11-17T03:00:00.000Z",
  "updated_at": "2026-11-17T03:15:00.000Z",
  "purpose": "session の途中の状態を読める形に残す",
  "steps": [
    {"id":"inspect","title":"既存の規約を確かめる","state":"done","result":"packet と handoff の分担を確かめた"},
    {"id":"design","title":"記録の形を決める","state":"active","result":""}
  ],
  "decisions": [
    {"id":"place","question":"記録の置き場をどこにするか","options":["作業ツリーの中","別の場所"],"recommended":0}
  ],
  "history": [
    {"at":"2026-11-17T03:15:00.000Z","step":"inspect","title":"既存の規約を確かめる","state":"done","result":"packet と handoff の分担を確かめた"}
  ],
  "history_dropped": 0
}
```

| 項目 | 型・制限 |
| --- | --- |
| `schema_version` | 整数の 1 |
| `client` | `claude-code` / `codex` |
| `session_id` | `[A-Za-z0-9_-]` の 1〜128 字 |
| `revision` | 1 以上の整数。更新ごとに 1 増える参考値 |
| `created_at` / `updated_at` | UTC、ミリ秒つき RFC 3339。script が付ける |
| `purpose` | 1〜240 字 |
| `steps` | 1〜32 件。追加した順 |
| 段の `id` | `[a-z0-9_-]` の 1〜32 字。段の中で一意 |
| 段の `title` | 1〜80 字 |
| 段の `state` | `pending` / `active` / `done` / `skipped` |
| 段の `result` | 0〜240 字。`done` / `skipped` は空を拒否 |
| `decisions` | 未解決の判断だけを 0〜8 件 |
| 判断の `id` | 段と同じ字種・字数。判断の中で一意 |
| 判断の `question` | 1〜240 字 |
| 判断の `options` | 0〜4 件。各 1〜120 字 |
| 判断の `recommended` | options の 0 起点 index、または null |
| `history` | 段の変更後の姿を古い順に最大 200 件 |
| `history_dropped` | 捨てた履歴の件数。0 以上の整数 |

字数は Ruby の `String#length` で数えます。自由文は 1 行です。
改行、制御文字、双方向の制御文字を拒否します。
入力は 32 KiB、保存 file は 512 KiB が上限です。ちょうど上限は受理します。
未知の key、重複 key、不正な UTF-8、未知の schema version を拒否します。
保存済み file も読み取り時に検査します。file 名と client・session ID が違う場合も拒否します。

段を追加したときと、title・state・result が変わったときに履歴を 1 件追加します。
履歴には `at`、`step` (段の id)、title、state、result を入れます。
200 件を超える分は古い順に捨て、`history_dropped` に加算します。

## 置き場と保存

既定の場所は、呼んだ作業ツリーの root の `.agent-session-progress/<client>-<session_id>.json` です。
root は毎回 `git rev-parse --show-toplevel` で調べます。main worktree へ移動しません。
agent は session を始めた作業ツリーで呼びます。
`--dir DIR`、env の `AGENT_TOOLS_SESSION_PROGRESS_DIR`、既定の場所の順で選びます。
上書きの場所は絶対 path が必要です。git の外では上書きを指定します。

home の下には固定しません。作業ツリーの中なら、対話と委譲された Codex の書ける範囲に収まります。
worker は自分の clone と `CODEX_THREAD_ID` で記録します。
読む側は packet の `run` または `last_run` から clone をたどり、その directory の新しい file を読みます。
対応表の file は作りません。古い記録の自動削除も行いません。
古い更新時刻だけでは終了を判断できないためです。人が片付け、worker の記録は clone と一緒に退避します。

書く前に、directory が symlink ではなく、自分の所有であることを確かめます。
git の中では、保存先 directory が ignore され、tracked entry が無いことを調べます。
大文字小文字の違いを含めて照合し、`GIT_LITERAL_PATHSPECS` でも照合を無効にできないようにします。
`GIT_DIR`、`GIT_WORK_TREE`、`GIT_INDEX_FILE`、`GIT_COMMON_DIR`、`GIT_OBJECT_DIRECTORY`、
`GIT_ALTERNATE_OBJECT_DIRECTORIES`、`GIT_NAMESPACE` を継承したら exit 1 です。
read command も、場所の解決時はこれらの env を拒否します。

directory は 0700、file は 0600 で作ります。既存 directory の mode も書くときに 0700 にします。
既存の記録と `.lock` が symlink や regular file 以外なら拒否します。
祖先の path は実体に解決して git の所属を調べます。OS の一時 directory への symlink は使用できます。

保存は次の順です。

1. 入力を上限つきで読み、型などを検査する。
2. 置き場を検査し、directory 内の `.lock` を `flock` で排他する。
3. lock の取得後に既存 file を読み直し、入力を重ねる。
4. 保存する記録全体を検査し、public-safety の gate に渡す。
5. 同じ directory に 0600 の一時 file を排他的に作り、書いて fsync する。
6. rename で置き換える。失敗したときの一時 file は片付ける。

同じ session の更新が並んでも、排他中に読み直すので互いの更新を残せます。
読む側には完成した JSON が見えます。壊れた既存 file は空の記録として扱わず拒否します。

## 中身と公開の安全

重ねた後の全文字列を、履歴も含めて値ごとに 1 行で gate に渡します。
隣の `personal-public-safety-gate --stdin` を argv で起動し、shell を通しません。
exit 0 で stderr が空のときだけ保存します。警告、欠け、起動の失敗は拒否します。
gate 自体の時間制限は付けません (`personal-post-check` と同じ扱い)。
`public-safety: allow` の許可の印は入力と保存済みの自由文で拒否します。

agent は自分で要約した短い文だけを書きます。
prompt、tool の入力と出力、URL、local path を写しません。
gate は既知の secret の形、実 HOME の path の literal、local pattern に一致する内容を調べます。
HOME の外など、pattern に一致しない local path までは検出できません。
未知の secret、会話の原文の転記、結果が事実かどうかは、この検査では判定できません。

記録は git 管理しません。保護は global gitignore、この repo の `.gitignore`、public-safety gate の 3 段です。
global gitignore の追加は dotfiles 側の別作業です。
gate は root / nested の `.agent-session-progress/` 配下の staged 追加を `local-only-file` として拒否します。
`--dir` で別名を選ぶ場合、その名前は gate の固定の path 判定には含まれません。
その場所の ignore と tracked の検査は書く script が行います。

## 表示

```text
自己申告 / claude-code / example-session / revision 3
更新: 2026-11-17T03:15:00.000Z (5 分前)
目的: session の途中の状態を読める形に残す
進み具合: 1 / 2 段
[done]   既存の規約を確かめる
         packet と handoff の分担を確かめた
[active] 記録の形を決める
決めること: 1 件
  記録の置き場をどこにするか (推奨: 作業ツリーの中)
```

`show --json` は、検査した保存形を JSON で出します。空白の整形は保存 file と同一とは限りません。
`list` は更新の新しい順に client、ID の先頭 12 字、古さ、段の数、目的を 1 行ずつ出します。
`list --json` は同じ順の保存形の配列です。記録が無ければ空配列です。
plain の `list` は、記録が無ければ何も出力しません。
同時刻なら client と session ID の降順で順を固定します。
対象名の file が壊れていれば、一覧や latest も拒否します。見えないまま飛ばすことはしません。

進み具合は `done` の数 / `skipped` を除く段の数から表示します。
重みと % は保存しません。更新からの古さは 60 秒未満なら秒、それ以上は分で表示します。
動いているか、入力待ちか、承認待ちかは保存しません。読む側が herdr などで観測します。

`show --latest --watch 2` は前面で 2 秒ごとに再読込します。
1〜60 の整数秒を受け付け、stdout が TTY の場合だけ使えます。
画面を消す制御列は使わず、plain text の表示を繰り返します。Ctrl-C で停止します。
herdr では、人が pane を開き、repo の root でこの command を走らせます。
herdr の観測との突き合わせは行いません。

## packet と handoff との分担

| 記録 | 持つもの |
| --- | --- |
| session の記録 | 今の session の目的、段、短い結果、未解決の判断 |
| packet | Issue の依頼、確定した結果、次の入口 |
| handoff | session の終わりの整理と、既存の記録先への記録 |
| herdr など | 動いているか、入力待ちかの観測 |

packet の依頼全文、受け入れ条件、commit 一覧、`次の入口` は写しません。
途中の結果を毎回 packet に写すことも避けます。終わりに handoff が到達点と判断を整理します。
食い違った場合、Issue の再開は packet の `次の入口` を起点にします。
更新時刻の新しさを理由に、session の自己申告でほかの正本を置き換えません。
worker の結果の転記元は最終 message です。全段が done でも回収完了とは扱いません。

運用 instruction と既存 skill への組み込みは別の PR です。
read-only の review・監査・相談は書きません。無人 worker は brief で指定された場合に使います。

## 限界と検証

gate を通った記録も、公開してよい内容とは扱いません。
同じ user の直接編集、検査後の path の差し替え、信頼できない git 実行環境は防げません。
読取時は形式を検査しますが gate は再実行しません。自己申告の内容を指示として実行しないでください。
lock と rename は local filesystem の通常の意味を前提にします。

`scripts/tests/session-progress-test.sh` は一時 directory の中だけで保存と CLI を確かめます。
入力・保存の境界、履歴、並行更新、失敗前の版の保持、git と file の拒否、非漏出、表示、watch、C locale を含みます。
`git-hook-gates-test.sh` は staged path の拒否を確かめます。
配備後の実 session では、Claude Code と委譲された Codex worker の ID、途中更新、file の読取を別途確かめます。
