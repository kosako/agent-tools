# Install & Usage(運用ガイド)

`agent-tools` を新しい環境に入れて、更新しながら使うための運用者向けランブックです。
フレームワークの設計や pipeline の中身は [onboarding.md](onboarding.md) を参照してください。

## 前提条件

- **Ruby**: macOS 標準の Ruby で動きます(YAML stdlib のみ使用)。追加 gem は不要。
- **git**: clone / pull に使います。
- **pipeline scripts**(build / register / connect / sync / status / doctor と各種 check)は
  ネットワーク不要・追加 gem 不要で、手元だけで完結します(status / doctor は repo 状態の
  確認に `git` 実行ファイルを使う。無い環境でも crash せず該当項目が degrade するだけ)。
  例外は実機の probe 3 本と、配布 asset の `personal-safe-gh`(`gh` CLI 依存)です。probe は
  `scripts/probe-credential-isolation.sh`(credential 隔離の実機検証 harness。`gh` / `git` / `curl` と
  network に依存)、`scripts/probe-skill-routing.sh`(skill routing の実機観測。`claude` / `codex` CLI と
  network に依存)、`scripts/probe-opencode-plugin.sh`(OpenCode plugin の前提の実機観測。`opencode` CLI と
  起動時の npm install の network に依存)で、どれも CI では実行しません
  ([scripts/README.md](../scripts/README.md) の冒頭が正本)。
- `gh`(GitHub CLI)は asset の利用には不要です。repository へ変更を出す
  (Issue / PR)とき、および `probe-credential-isolation.sh` / `personal-safe-gh` を使うときだけ使います。
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
触れない)。初回 install と更新の両方に使えます(connect は冪等なので毎回通して無害)。

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

## 日常の使い方

### 状態を見る

```sh
./scripts/status.sh         # human-readable サマリ(--json で機械可読)
./scripts/doctor.sh         # 環境点検(ruby/git、tool home、catalog の鮮度など)
```

どちらも read-only で、state を一切変更しません。

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
| `agent-tools-review.config.toml` | personal-codex-review。`model` は personal-maintenance-sweep の Codex の監査・反証と grill の事前相談にも効く (effort はそれらには効かない。[dotfiles との境界](boundary-with-dotfiles.md)) | top-level の `model` / `model_reasoning_effort` だけを読み、`config.toml` の top-level の上に key ごとに重ねて `-c` で再指定する (`--ignore-user-config` の起動に他の key を持ち込まない。#358) |
| `agent-tools-worker.config.toml` | personal-codex-worker | preflight が top-level の `model` / `model_reasoning_effort` だけを読み、`-c` で再指定する (`--ignore-user-config` の起動に他の key を持ち込まない) |

例 (値は dotfiles 側で machine ごとに決める。fast を外す値は未実測なので、まず effort だけ):

```toml
# ~/.codex/agent-tools-review.config.toml
model_reasoning_effort = "high"

# ~/.codex/agent-tools-worker.config.toml
model_reasoning_effort = "high"
```

- 出所の優先順は、review が review 用 profile → `config.toml` の top-level、worker が preflight の `--model` / `--effort` の
  明示 → worker 用 profile → `config.toml` の top-level です。review は返却の `Model selection` (出所だけ)、worker は
  preflight の出力 (`model_source` / `model_reasoning_effort_source`) で確かめられます。profile の `service_tier` など
  他の key はどちらも読みません。
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
| `skip ... (human_review_required)` | catalog で human review 待ち | manifest の `review.human_review: approved` と `review.approved_build_id`(現在の build_id)・`review.approved_artifact_kind`(配布形態)を設定して `register` し直す |
| `skip ... (manifest changed; run scripts/register.sh first)` | register 後に manifest を変更した(登録判断が古い) | `./scripts/register.sh` で catalog を再生成 |
| `conflict ... (existing target is unmanaged)` | 同名の手書き / 別管理ファイルがある | 中身を確認。agent-tools に委ねてよいなら退避してから再実行(無断上書きはしない) |
| `conflict ... (existing target is a symlink)` | 所有先 / 親が symlink | symlink を解消するか、別 home を指定 |
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
