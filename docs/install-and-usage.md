# Install & Usage(運用ガイド)

`agent-tools` を新しい環境に入れて、更新しながら使うための運用者向けランブックです。
フレームワークの設計や pipeline の中身は [onboarding.md](onboarding.md) を参照してください。

## 前提条件

- **Ruby**: macOS 標準の Ruby で動きます(YAML stdlib のみ使用)。追加 gem は不要。
- **git**: clone / pull に使います。
- **pipeline scripts**(build / register / connect / sync / status / doctor と各種 check)は
  ネットワーク不要・追加 gem 不要で、手元だけで完結します(status / doctor は repo 状態の
  確認に `git` 実行ファイルを使う。無い環境でも crash せず該当項目が degrade するだけ)。
  例外は実機の probe 3 本と、`personal-safe-gh` など一部の配布 script(`gh` / `codex` CLI や、`personal-usage-reader` の設定した実行ファイルに依存)です。probe は
  `scripts/probe-credential-isolation.sh`(credential 隔離の実機検証 harness。`gh` / `git` / `curl` と
  network に依存)、`scripts/probe-skill-routing.sh`(skill routing の実機観測。`claude` / `codex` CLI と
  network に依存)、`scripts/probe-opencode-plugin.sh`(OpenCode plugin の前提の実機観測。`opencode` CLI と
  起動時の npm install の network に依存)で、どれも CI では実行しません
  ([scripts/README.md](../scripts/README.md) の冒頭が正本)。配布 script のうち `gh` を起動するのは
  `personal-safe-gh`・`personal-packet` (publish / pull)・`personal-review-routing-preflight`・`personal-dependabot-pin-check`・`personal-repo-baseline`・`personal-ci-check` (`--since` のときだけ)・`personal-upstream-pin-check`・`personal-merged-branch-cleanup`、`codex` を起動するのは
  `personal-codex-worker-preflight` です。`personal-usage-reader` は、設定 file (`usage-reader.json`) に書かれた実行ファイルを
  起動します (依存はその実行ファイル次第。設定 file を置かない machine では読み取り口なしになる。[boundary-with-dotfiles.md](boundary-with-dotfiles.md)
  「残量の読み取り口の設定 (#385)」)。
- `gh`(GitHub CLI)は repository へ変更を出す (Issue / PR)とき、および `probe-credential-isolation.sh` と、
  上の `gh` を起動する配布 script を使うときだけ使います。
- [herdr](https://herdr.dev)(任意)は Codex を起動する skill の launcher です。
  - `personal-codex-review` と、`personal-repo-audit` の Codex の監査 (`personal-maintenance-sweep` の監査・反証を
    含む) は herdr の pane を primary に使います。無い環境では、呼び出し元が sandbox の外にいると確かめられた
    ときだけ直接起動し、それ以外は BLOCKED で人手へ渡します。背景と経路の選び方は
    [codex-review-launch.md](codex-review-launch.md) と
    [personal-repo-audit の CODEX-LAUNCH.md](../shared/skills/personal-repo-audit/CODEX-LAUNCH.md)。
  - `personal-codex-worker` は herdr の pane からしか worker を起動しません。無い環境では常に、人が自分の
    terminal で run script を実行する hand-off になります
    ([personal-codex-worker の LAUNCH.md](../shared/skills/personal-codex-worker/LAUNCH.md))。
- この repo に commit / push する場合、配置先ディレクトリに応じた git identity の出し分けは
  各自の git 設定(`dotfiles` 等)側で行います(本 repo の管理対象外)。

配置先となる tool home(既定):

- Codex: `~/.codex`
- Claude Code: `~/.claude`
- OpenCode: `~/.config/opencode`(`XDG_CONFIG_HOME` は見ません。食い違いは `doctor` が warn)

## 何がどこに置かれるか

| asset | 配置先 | 確立する操作 |
| --- | --- | --- |
| skill | `~/.codex/skills/personal-*` / `~/.claude/skills/personal-*` | `sync`(直接 create) |
| instruction | `~/.codex/AGENTS.md` / `~/.claude/agent-tools/CLAUDE.md`(人間の `~/.claude/CLAUDE.md` から `@agent-tools/CLAUDE.md` で import) | `connect`(初回所有)→ `sync`(更新) |
| script | `~/.codex/agent-tools/scripts/personal-*` / `~/.claude/agent-tools/scripts/personal-*`(sidecar marker つき) | `sync`(直接 create) |
| plugin(OpenCode のみ) | `~/.config/opencode/plugins/personal-*.js`(先頭 1 行が marker) | `sync`(直接 create。置くこと自体が OpenCode への登録) |

skill は隔離 directory なので `sync` が直接置けますが、instruction は共有ファイル
(`CLAUDE.md` / `AGENTS.md`)に載るため、**先に `connect` で所有を確立**してから
`sync` が更新します。

公開の repo に置けない手元だけの指示は、`${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/instructions.local.md` に
書きます (#689)。在れば `sync` が両方の tool の instruction の末尾に足し、無ければ配る instruction は変わりません。
書くのは人だけで、直したら `./scripts/setup.sh --apply` で配り直します (効くのは新しい session から)。symlink にしない、
UTF-8 で書く、8 KiB 以下にする、の 3 つを満たさないと、instruction の `sync` は conflict で止まります。詳細は
[instruction-artifact-kind.md](instruction-artifact-kind.md) の「local の断片」。

OpenCode には skill / instruction / script を配りません(OpenCode は `~/.claude/skills` と
`~/.claude/CLAUDE.md` を直接読むため。[tool-compatibility.md](tool-compatibility.md))。plugin は
Claude Code 側に配った `~/.claude/agent-tools/scripts/personal-*` を呼ぶので、OpenCode で効かせる
には Claude Code target の `sync` も済んでいる必要があります。plugin を一時的に外すには `opencode --pure`
で起動します。恒久に撤去するには、`shared/plugins/` の source と manifest を消して `register` し (catalog から
消える)、`sync --prune --apply` で orphan として撤去します (`sync --prune` は catalog に残る現役の plugin を消さず、
既定は dry-run です)。

## 初回インストール

**配置先(推奨)**: `~/src/agent/agent-tools`。これは `dotfiles` の directory convention
(`~/src/agent/<repo>`)と `dotfiles` doctor の既定期待パスに一致する**配置先の正本**です
([boundary-with-dotfiles.md](boundary-with-dotfiles.md) で定義)。任意のパスでも動作しますが、
`dotfiles` 連携(presence / health の report-only check)を使うなら、このパスに置くか
`AGENT_TOOLS` env で実際の場所を指定してください。

### 一発で通す(推奨)

```sh
git clone <this-repo> ~/src/agent/agent-tools
cd ~/src/agent/agent-tools

./scripts/setup.sh           # dry-run: connect/sync の plan を確認 (build/register は実行される)
./scripts/setup.sh --apply   # 確認できたら実環境へ反映
```

`setup.sh` は `build → register → connect → sync` を順に実行します。**既定は dry-run**で、
`--apply` を付けたときだけ connect / sync が実環境 (tool home) へ書き込みます。dry-run でも
build / register は毎回実行するため、repo 内の中間物 (`generated/` と
`generated/catalog.json`) は**更新されます** (どちらも gitignore 済み・tool home には
触れない)。build は `--prune` で回るので、`shared/` から消えた asset の generated/ の残骸も消えます。初回 install と更新の両方に使えます(connect は冪等なので毎回通して無害)。

### 個別に実行する場合

中で何が起きるかを段階で確認したいときは、個別 script を順に実行します。

```sh
./scripts/build.sh              # 1. 生成(generated/ のみ。tool home には触れない)
./scripts/register.sh           # 2. 登録(配ってよい asset を catalog に記録)
./scripts/connect.sh            #    instruction の所有確立: まず dry-run で確認
./scripts/connect.sh --apply    # 3. 所有ファイルを作り、CLAUDE.md に import 1 行を足す
./scripts/sync.sh               #    まず dry-run で plan を確認
./scripts/sync.sh --apply       # 4. tool home に配置
```

- `connect` は冪等です。既に import 行があれば no-op。symlink / 既存の手書き内容が
  ある所有先は触らず conflict で停止します(何も書きません)。
- instruction を配らない(skill だけの)構成なら connect は不要です。
- `connect` は `register` の後に実行します。catalog に registered な instruction entry が
  無いと、connect は理由つきで skip して何も書きません(`no catalog; run scripts/register.sh first` など)。
  `sync` は両者(catalog と所有確立)の後です。`setup.sh` の順序(build → register → connect → sync)が
  必須の順です。
- `shared/` から asset を消したときは `sync --prune`(dry-run)→ `sync --prune --apply`
  で deployed コピーを撤去できます(管理 marker が一致する orphan のみ削除。詳細は
  [sync-policy](sync-policy.md) の「撤去」)。

## アップデート

```sh
cd agent-tools
git pull

./scripts/setup.sh           # dry-run で差分確認
./scripts/setup.sh --apply   # 反映
```

- `setup.sh` は冪等な connect を含むので、更新でもそのまま使えます。個別に回すなら
  `build → register → sync --apply`(connect は所有確立済みなら不要)。
- source asset を編集したときも同じ流れです(`build` が source の sha256 で
  `build_id` を再計算し、`sync` が差分のある target だけ `update` します)。
- ただし script / plugin に解決される asset と、宣言 risk が `medium` / `unknown` か medium finding を持つ asset は、
  承認が `review.approved_build_id` に紐づきます。source を変えたら review のうえ `approved_build_id` を
  新しい build_id に焼き直してから `register` します。焼き直すまでは register が exit 3 を返し、sync が
  `human_review_required` で skip して旧版が配置されたまま残ります(下の「トラブルシュート」と
  [register-catalog.md](register-catalog.md) の「承認は内容と配布形態に紐づく」)。
- 運用 instruction を変えた配備は、配備の前から続いている Claude Code の session には、次の compaction か起動し直しまで
  届きません (#688)。`sync` は instruction を書き換えるときに、変わった節を note の行で出します
  ([sync-policy.md](sync-policy.md) の「配備の報告」)。配備済みの hook `personal-instruction-update-notice` を Claude Code に登録しておくと、続いている session が
  次の入力で、変わった節と読み直しの促しを受け取ります ([instruction-update-notice.md](instruction-update-notice.md))。
- upstream で asset が消えた・改名されたときは、`setup.sh` だけでは tool home から片付きません。`setup.sh` の build は
  `--prune` で回るので、generated/ の残骸 (git ignore の生成物) は消えます。一方、tool home に配置済みのコピーは
  消さず、使える状態のまま残ります (tool home から消すのは明示の操作だけ)。残ったものは `status` と `doctor` が
  orphan として出します (`orphan: [<tool>] <name>`、doctor では warn)。出たら、次の順で撤去します (管理 marker が
  一致するものだけを消す。詳細は [sync-policy](sync-policy.md) の「撤去」)。

  ```sh
  ./scripts/sync.sh --prune           # dry-run: 撤去の候補を確認
  ./scripts/sync.sh --prune --apply   # 撤去
  ```

  instruction は prune の対象外です。instruction の asset の改名は、下の「トラブルシュート」の
  `owned file belongs to another instruction asset` の行の手順で直します (#424)。

## 日常の使い方

### 状態を見る

```sh
./scripts/status.sh         # human-readable サマリ(--json で機械可読)
./scripts/doctor.sh         # 環境点検(ruby/git、tool home、catalog の鮮度、配備した body のずれなど)
```

どちらも read-only で、state を一切変更しません。

status の `managed` は、管理 marker が一致するという意味です。skill・script・plugin では marker の `build_id` だけを見るので、
marker を変えずに body だけが変わっても `managed` のままです (instruction は byte で比べるので `stale` になります)。
doctor は、`managed` の target を、source から一時 directory に作り直した artifact と比べ、結果を target の行に載せます (#722)。
status の人向けの出力は、`managed` が 1 つでもあれば、最後にこの意味を `note:` の 1 行で示します。client が読み込んだ版は、
status も doctor も見ません。

`deployed_but_inactive` は、登録されていない (承認を外した、承認の後に source を変えた、など) のに、target の path に何かが
残っている状態です。sync は置き直しも削除もしないので、残ったものを client が読み込み、実行することがあります。止まったことを
示す state ではありません。status と doctor は、その行に
`(not registered, so sync leaves the target path as it is; whether it is still loaded or run is not checked)` を足します。
見るのは path の有無だけなので、手書きの同名 file や dangling な symlink でも同じ行になります。

- `ok: target: [<tool>] <name> managed (body matches a fresh build)`: 名前の集合、種類 (file・directory・symlink)、
  file の byte、通常の file の所有者の実行 bit、symlink の行き先が同じ。instruction は今の local の断片を足した本文と
  byte で比べ、mode は比べません (所有 file の mode は人の file から引き継ぐため)。
- `warn: target: … managed but the body differs from a fresh build (<相対 path>: <違い>)`: 最初の違いを 1 つ出します。
  違いは `content`・`exec bit`・`missing`・`extra`・`type`・`link target` のどれかです。UTF-8 として読めない名前や制御文字を
  含む名前は escape して 1 行に収めます。exit は 0 のままです。
- `info: target: … managed (body not verified: <理由>)`: 一致ともずれとも言えないとき。例えば、配備の後に source が
  変わった (`source changed since the deployed build`)、作り直しや読み取りに失敗した、一時 directory の置き場が無い、です。
  理由に例外の文言は出さず、class の名前だけを出します。

一時 directory は、`TMPDIR`、system の一時 directory、`/tmp` の順に、repo・tool home・agents home の外にあるものだけを
使い、終わると消します。`generated/` は作り直しません。`build_id` は source の通常の file の相対 path と byte から作るので、
source の実行 bit や空の directory だけを変えたとき、manifest の `source.path` だけを変えたとき、build の変換が変わった
ときは、`build_id` が同じまま作り直しが変わり、ずれと出ます。この検査は偶発的なずれと取り違えを見つけるためのもので、
同じ OS user による改ざんの防御ではありません (doctor を走らせる前に戻せます)。

ずれが出たら、次の手順で置き直します。sync は marker が同じ target を置き直さないので、写しを消してから配備します。
`sync.sh --apply` だけでなく `setup.sh --apply` を使うのは、`generated/` が変えられていたときに source から作り直すためです。

```sh
rm -r ~/.claude/skills/<name>                  # skill (tool ごとの home の skills/<name>)
rm ~/.claude/agent-tools/scripts/<name>         # script (本体だけを消せば足りる。sidecar は残してよい)
rm ~/.config/opencode/plugins/<name>.js         # plugin
./scripts/setup.sh --apply
```

instruction は所有 file を消さず、`setup.sh --apply` だけで直ります (sync が byte で比べて書き直す)。

### 配った asset を止める (取り消し)

配った skill・script・plugin を 1 つだけ止め、後で戻す手順です (#723)。ほかの asset の配置、instruction の所有 file、
人の file は変えません。instruction はこの手順の対象外です (この節の最後)。

下では、止める asset を `personal-x` と書きます。配置先は上の「何がどこに置かれるか」の表のとおりで、tool ごとに
あります。tool home を既定から変えているときは、command の `~/.claude` などをその home に読み替え、script には
`--codex-home` などを付けます。

1. 呼び手を確かめます。`git grep -n personal-x -- shared` で、ほかの skill・script・plugin が呼んでいないかを見ます。
   dotfiles が hook として登録していないかを、dotfiles の doctor で見ます (hook は、本体が agent-tools、登録が dotfiles。
   [boundary-with-dotfiles](boundary-with-dotfiles.md))。分かるのは、この 2 つで確かめられた範囲だけです。作業ツリーの
   外の呼び手と、続いている session の参照は確かめられません。
2. 今の状態を、repo の外の file に控えます (`./scripts/status.sh --json > <控えの file>`)。
3. 配布を止めます。kind で道を選びます。
   - 承認を外す (script・plugin・human review の要る skill)。manifest の `review` を `human_review: pending` の 1 行だけに
     し、`approved_build_id` と `approved_artifact_kind` の行を消します (消す前に、2 つの行を repo の外に控える)。
     `./scripts/register.sh` が exit 3 で終わり、status のその asset の行が `deployed_but_inactive` になったことを
     見ます。exit 1 なら manifest の検査が落ちていて、catalog は前のままです (status は `stale` と出すことがある)。
     manifest を直してやり直します。
   - `targets` から外す (危険度の低い skill、1 つの tool だけを止めるとき)。危険度の低い skill は、承認を外しても
     登録されたままだからです (register はこの skill の `review` を見ない)。`targets` が 1 つしかないときは、asset
     (manifest と source) を消します。`./scripts/build.sh --prune` と `./scripts/register.sh` をかけ、status に
     その tool の `orphan:` の行が出たことを見ます。repo の最後の asset を消したときは、catalog が空になり、status は
     orphan を判断しないので、行は出ません。そのときは手順 5 の marker の確かめで進めます。
4. hook の登録を外します。手順 1 で hook と分かったときだけで、dotfiles の側の手順で行います。本体を動かす前に
   済ませます。登録が残ったまま本体が無くなると、hook は起動のたびに失敗するからです (多くは fail-open で止めないが、
   git hook の gate は commit を止める)。
5. 配置を、tool home の外の隔離の置き場へ動かします。`targets` から外した道では、外した tool の写しだけを動かします。
   `sync --prune --apply` は使いません。prune は対象の 1 件だけでなく、通常の sync の plan と、すべての orphan を適用する
   からです。動かす前に、marker が `personal-x` と
   その tool を指すことを確かめます (skill は dir の中の `.agent-tools-managed.yml`、script は sidecar、plugin は
   先頭の 1 行)。marker が無いものは agent-tools の写しではないので、中身を見てから扱いを決めます。

   ```sh
   q=~/.local/share/agent-tools/quarantine/$(date +%Y%m%d-%H%M%S)-personal-x
   mkdir -p ~/.local/share/agent-tools/quarantine && mkdir "$q" && mkdir "$q/codex" "$q/claude-code" \
     "$q/opencode" && (cd "$q" && pwd -P)
   ```

   2 行目は、最後に、symlink を辿った置き場の実際の場所を出します。その場所が tool home と repo の外にあることを見て
   から、次の block で動かします。内側なら、作った置き場を消して別の場所を選びます。何も出ずに error で終わったら
   (同じ名前の directory が在る、など)、次の block に進まず、1 行目から少し待ってかけ直します。

   ```sh
   mv ~/.claude/skills/personal-x "$q/claude-code/"                    # skill (dir ごと)
   mv ~/.claude/agent-tools/scripts/personal-x \
      ~/.claude/agent-tools/scripts/personal-x.agent-tools-managed.yml "$q/claude-code/"   # script (本体と sidecar)
   mv ~/.config/opencode/plugins/personal-x.js "$q/opencode/"          # plugin
   ```

   codex は `~/.codex` の下の同じ場所です。
6. 確かめます。
   - 配置先の path が無いこと。script は本体と sidecar の両方を見ます (sidecar だけが残ると、prune の候補にも出ない)。
   - status のその asset の行が `missing` になった (承認を外した道) か、その tool の行と `orphan:` の行が消えた
     (`targets` から外した道) こと。ほかの行が、手順 2 の控えと同じこと。
   - `./scripts/doctor.sh` に、その asset の warn が残らないこと。
   - 続いている session は、起動のときに読んだもの (skill の一覧、hook の登録) を持ち続けることがあります。止めたい
     session は終えて、新しく起動します。

戻すときは、次の順です。`setup.sh` は使いません。中の connect が、人の `CLAUDE.md` に import の行を足すことがある
からです。

1. 承認か `targets` を戻します。承認は、`human_review: pending` を `human_review: approved` に戻し、その下に 2 つの行を
   書きます。source を変えていなければ、控えた 2 つの行をそのまま戻します。止めている間に source を変えたときは、
   先に pending のまま `./scripts/build.sh --prune` と `./scripts/register.sh` をかけ、catalog を今の source に合わせます。
   review のうえで、そのとき `generated/catalog.json` のその asset の entry に書かれた `build_id` を `approved_build_id`
   に書き、`approved_artifact_kind` も書きます (pending では register の警告が build_id を出さない)。asset を消したときは、
   git で戻します。
2. `./scripts/build.sh --prune` と `./scripts/register.sh` をかけます。
3. `./scripts/sync.sh` を dry-run でかけ、plan の行のうち `skip:` でないもの (`create:`・`update:`・`conflict:`) が、
   戻す asset の `create:` だけであることを見ます。ほかの行があるうちは `--apply` をかけず、先にそれを片付けます
   (変えた source を戻す、戻す先の手書きの同名 file を退ける、など)。sync は手書きの同名 file を上書きしません
   (`conflict:` で止まる)。
4. `./scripts/sync.sh --apply` をかけます。隔離した写しは戻さず、generated/ から作り直します。script の sidecar
   だけが残っていても、create で置き直されます。
5. status が `managed`、doctor が `managed (body matches a fresh build)` になったことを見ます。
6. hook の登録を戻します (本体が先、登録が後)。効くのは新しい session からです。隔離した写しは、調べ終えたら消します。

instruction はこの手順の対象外です。prune は所有 file を消さず、所有 file は人の `CLAUDE.md` の import と組だから
です。止めたいときは source を戻し、上の 2〜4 (build・register・sync) で書き直します。

### dotfiles から参照する(report-only)

`dotfiles` は `agent-tools` を自動 clone / pull / sync せず、agent-tools の state を書き換えません。
dotfiles が担う連携は次のとおりです (各項目の link 先が正本)。

- status の読み取り: **`status.sh --json` を read-only で読む**(presence + health の表示)。読んでよい
  情報・読まない情報の境界は [status-manifest-contract.md](status-manifest-contract.md) と
  [boundary-with-dotfiles.md](boundary-with-dotfiles.md) が正本です。下の参照例はこの連携だけを扱います。
- hook の配線: sync が配った hook の script (実体) を、git の hooks dir の shim や tool の hook 宣言から
  呼ぶよう登録する ([git-hook-gates.md](git-hook-gates.md)「構成と配線(所有分界)」、
  [boundary-with-dotfiles.md](boundary-with-dotfiles.md)「runtime GitHub injection 防御の分担」)。
- Codex の review / worker 用 profile file の配置 ([boundary-with-dotfiles.md](boundary-with-dotfiles.md)
  「Codex の review / worker 用 profile file (#339)」。下の「Codex の review / worker だけを軽くする」)。
- 残量の読み取り口の設定 file (`usage-reader.json`) の配置と、`personal-usage-reader --check` による設定の検証
  ([boundary-with-dotfiles.md](boundary-with-dotfiles.md)「残量の読み取り口の設定 (#385)」)。
- OpenCode plugin の init の目印の読み取り (dotfiles の doctor が OpenCode の log を読む。
  [boundary-with-dotfiles.md](boundary-with-dotfiles.md)「OpenCode plugin の init の目印 (#343)」)。

最小の参照例(dotfiles 側に置く想定。illustrative):

```sh
# 1. expected path に agent-tools があるか(presence)
AGENT_TOOLS="${AGENT_TOOLS:-$HOME/src/agent/agent-tools}"
[ -d "$AGENT_TOOLS" ] || { echo "agent-tools: absent"; exit 0; }

# 2. status を read-only で読む(health)
status_json=$("$AGENT_TOOLS/scripts/status.sh" --json) \
  || { echo "agent-tools: status unavailable"; exit 0; }

# 3. contract が許可した field だけ拾って表示(例: jq)
echo "$status_json" | jq -r '
  "agent-tools: " +
  (if .repo.clean then "clean" else "dirty" end) +
  " / injection=" + .checks.prompt_injection_static +
  " / stale=" + (.generated.stale | tostring)'
```

- 読むのは contract が許可した field(`repo` / `checks` / 各 target の `state` など)だけ。
- agent-tools の state は変更しない(書き込み・`sync` をしない)。
- agent-tools が無い環境は `absent` を report して正常終了する(報告のみで、呼び出し側を
  止めない)。

### Codex の review / worker だけを軽くする (profile file)

`personal-codex-review` と `personal-codex-worker` は Codex の model / reasoning effort を skill で固定せず、
user の Codex の設定を使います。既定のままだと、機械的な review と worker も対話と同じ model・effort で
動きます。review と worker だけを軽くしたいときは、Codex home (`$CODEX_HOME`、空なら `~/.codex`) に
次の file を置きます (#339)。置くのは **dotfiles** で (machine ごとの値。手で置いてもよい)、agent-tools は
これらを作らず、書き換えず、sync の対象にもしません。file が無ければ今までどおりです。file 名は dotfiles
との公開契約です ([dotfiles との境界](boundary-with-dotfiles.md))。

| file | 効く先 | 読まれ方 |
| --- | --- | --- |
| `agent-tools-review.config.toml` | personal-codex-review。`model` は personal-maintenance-sweep の Codex の監査・反証と grill の事前相談にも効く (effort はそれらには効かない。[dotfiles との境界](boundary-with-dotfiles.md)) | top-level の `model` / `model_reasoning_effort` を、`config.toml` の top-level の上に key ごとに重ねて `-c` で再指定する (#358)。選ばれたプロバイダがあれば、`model_provider` とその aws の `profile` / `region` も同じ重ね方で引き継ぐ (#543。下の補足) |
| `agent-tools-worker.config.toml` | personal-codex-worker | preflight が top-level の `model` / `model_reasoning_effort` を読み、`-c` で再指定する。選ばれたプロバイダがあれば、`model_provider` とその aws の `profile` / `region` も引き継ぐ (#543。下の補足) |

例 (値は dotfiles 側で machine ごとに決める。fast を外す値は未実測なので、まず effort だけ):

```toml
# ~/.codex/agent-tools-review.config.toml
model_reasoning_effort = "high"

# ~/.codex/agent-tools-worker.config.toml
model_reasoning_effort = "high"
```

- 出所の優先順は、review が review 用 profile → `config.toml` の top-level、worker が preflight の `--model` / `--effort` の
  明示 → worker 用 profile → `config.toml` の top-level です。review は返却の `Model selection` (出所だけ)、worker は
  preflight の出力 (`model_source` / `model_reasoning_effort_source`) で確かめられます。
- model / effort のほかに読むのは、選ばれたプロバイダの設定だけです (#543)。`--ignore-user-config` は provider の設定と
  認証も外すので、`model_provider` と、そのプロバイダの `[model_providers.<id>.aws]` の `profile` / `region` を同じ重ね方で
  読んで `-c` で渡します。それ以外の provider の設定 (`base_url`・`env_key`・`http_headers` など) があれば起動しません。
  command で資格情報を取る table (`credential_export` / `auth_refresh`) は、`aws.profile` があれば引き継がずに無視します
  (#548)。許可する key と認証の command の扱いの正本は [Codex review の起動経路](codex-review-launch.md) の「model の選択」です。
  profile の `service_tier` など、model / effort と provider 以外の key はどちらも読みません。
- telemetry の設定は、user の `config.toml` の `[otel]` だけを読みます (#652)。送り先が loopback の exporter と
  `environment` を `-c` で渡し、中身を出す key は `false`、tool の出力の抜粋の上限 (`tool_result.max_bytes`) は `0` に固定します。profile file の `[otel]` は読みません。外部の
  backend へは、127.0.0.1 で受ける Collector で項目を絞ってから送ります (正本は
  [Codex review の起動経路](codex-review-launch.md) の「telemetry ([otel]) の引き継ぎ」)。
- **Fast mode (`service_tier = "fast"`)**: 公式 docs によると、GPT-6 (Astra / Sol / Luna) の Fast mode は速度が
  1.5 倍になる代わりに Standard の 2.5 倍の credit を使い、plan の included limits も同じ割合で早く減ります
  ([Speed](https://learn.chatgpt.com/docs/agent-configuration/speed)、[Pricing](https://learn.chatgpt.com/docs/pricing)。
  2026-09-28 確認)。`[features].fast_mode` は stable で既定 on です。review も worker も `--ignore-user-config` で
  起動して `service_tier` を再指定しないので、user config や profile の `service_tier = "fast"` は review / worker
  には効きません (Codex の既定の tier になる。#358。review 用 profile に `service_tier` を書いても読まれない)。
  対話の Codex には user config の値がそのまま効きます。
- model の単価も大きく違います (Pricing の input は Astra 250 / Sol 50 / Luna 2.5 credits per 1M tokens)。
  ただし credit の単価だけで plan の included usage は決まらないので、変えた後は usage の dashboard か
  session rollout で消費を見ます。

### asset を追加する

1. `shared/<category>/` に source と manifest を置く。単一 file の source は sidecar manifest
   (`<name>.asset.yml`)、directory 形式の skill(`shared/skills/<name>/`)は `<dir>/asset.yml` で宣言する
   (directory 形式は `asset.yml` でしか宣言できない)。manifest の書式と置き方は
   [asset-manifest-schema.md](asset-manifest-schema.md)。
   name は `personal-` 始まりが必須。
2. `./scripts/check-manifests.sh` と `./scripts/check-injection.sh` で検証。`evals/evals.json` を持つ
   skill では `ruby scripts/lib/check_evals.rb` も通す(check-manifests には入らず、CI では self-test が通す。
   形式は [asset-manifest-schema.md](asset-manifest-schema.md) の「evals の形式」)。
3. `build` → `register` → `sync --apply` で配置(上の「アップデート」と同じ)。
   script / plugin に解決される asset と、宣言 risk が `medium` / `unknown` か medium finding を持つ asset は、
   review のうえ manifest に承認(`review.human_review: approved`・
   `review.approved_build_id`・`review.approved_artifact_kind`)を書いてから `register` します(下の
   「トラブルシュート」の `human_review_required` の行と [register-catalog.md](register-catalog.md))。

## トラブルシュート

| 症状(plan / 出力) | 意味 | 対処 |
| --- | --- | --- |
| `skip ... (run build first)` | generated が無い / 古い | `./scripts/build.sh` を実行 |
| `skip ... (run connect first)` | instruction の所有先が未確立(未接続 / 空ファイル) | `./scripts/connect.sh --apply` |
| `skip ... (human_review_required)` | catalog で human review 待ち | manifest の `review.human_review: approved` と `review.approved_build_id`(現在の build_id)・`review.approved_artifact_kind`(配布形態)を設定して `register` し直す。止めたままにするなら、残った配置を「配った asset を止める (取り消し)」の手順で動かす |
| `skip ... (manifest changed; run scripts/register.sh first)` | register 後に manifest を変更した(登録判断が古い) | `./scripts/register.sh` で catalog を再生成 |
| `conflict ... (existing target is unmanaged)` | 同名の手書き / 別管理ファイルがある | 中身を確認。agent-tools に委ねてよいなら退避してから再実行(無断上書きはしない) |
| `conflict ... (owned file belongs to another instruction asset (<旧名>); ...)` | instruction の asset を改名した後で、所有ファイルに旧名の marker が残っている | 所有ファイル (`<claude home>/agent-tools/CLAUDE.md` / `<codex home>/AGENTS.md`) を空にして `./scripts/connect.sh --apply` をやり直す ([instruction-artifact-kind.md](instruction-artifact-kind.md)) |
| `conflict ... (existing target is a symlink)` | 所有先 / 親が symlink | symlink を解消するか、別 home を指定 |
| `conflict ... (local instructions file is invalid: ...)` | local の断片 (`instructions.local.md`) が symlink・regular file でない・UTF-8 でない・8 KiB を超える | 断片を regular file の UTF-8 で 8 KiB 以下に直す (所有ファイルは変わっていない。[instruction-artifact-kind.md](instruction-artifact-kind.md)) |
| `conflict ... (existing target is not a regular file)` | plugin の配置先が directory など regular file でない | 実体を確認し、agent-tools に委ねてよいなら退避してから再実行(無断削除はしない) |
| `no catalog; run scripts/register.sh first` | catalog 未生成 | `./scripts/register.sh` |

`--codex-home` / `--claude-home` / `--opencode-home` で home を上書きできます(検証用。
`--opencode-home` は sync / status / doctor / setup が受け付け、connect は受け付けません)。
doctor はさらに `--agents-home`(既定 `~/.agents`。禁止 target の `skills/*/{db,teams}` の検査先)も
受け付けます。

## 関連ドキュメント

- pipeline と各 script の役割: [onboarding.md](onboarding.md)
- コマンド別の詳細 usage: [../scripts/README.md](../scripts/README.md)
- 配置の安全則: [sync-policy.md](sync-policy.md)
- instruction の所有モデル: [instruction-artifact-kind.md](instruction-artifact-kind.md)
- dotfiles との境界・status 参照契約: [boundary-with-dotfiles.md](boundary-with-dotfiles.md) / [status-manifest-contract.md](status-manifest-contract.md)
