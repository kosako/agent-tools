# Install & Usage(運用ガイド)

`agent-tools` を新しい環境に入れて、更新しながら使うための運用者向けランブックです。
フレームワークの設計や pipeline の中身は [onboarding.md](onboarding.md) を参照してください。

## 前提条件

- **Ruby**: macOS 標準の Ruby で動きます(YAML stdlib のみ使用)。追加 gem は不要。
- **git**: clone / pull に使います。
- **pipeline scripts**(build / register / connect / sync / status / doctor と各種 check)は
  ネットワーク不要・追加 gem 不要で、手元だけで完結します(status / doctor は repo 状態の
  確認に `git` 実行ファイルを使う。無い環境でも crash せず該当項目が degrade するだけ)。
  例外は `scripts/probe-credential-isolation.sh`(credential 隔離の実機検証 harness。
  `gh` / `git` / `curl` と network に依存)と、配布 asset の `personal-safe-gh`
  (`gh` CLI 依存)。
- `gh`(GitHub CLI)は asset の利用には不要です。repository へ変更を出す
  (Issue / PR)とき、および上記 probe / `personal-safe-gh` を使うときだけ使います。
- [herdr](https://herdr.dev)(任意)は `personal-codex-review` が Codex を起動する launcher です。
  無い環境では、呼び出し元の Bash sandbox が無効なときだけ直接起動し、それ以外は BLOCKED で
  人手へ渡します。背景と経路の選び方は [codex-review-launch.md](codex-review-launch.md)。
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
- `register` と `connect` はどちらも `build` の後・`sync` の前であればよく、相互に依存
  しません。`sync` だけが両者(catalog と所有確立)を前提とします。`setup.sh` はこの
  順序で通します。
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

## 日常の使い方

### 状態を見る

```sh
./scripts/status.sh         # human-readable サマリ(--json で機械可読)
./scripts/doctor.sh         # 環境点検(ruby/git、tool home、catalog の鮮度など)
```

どちらも read-only で、state を一切変更しません。

### dotfiles から参照する(report-only)

`dotfiles` は `agent-tools` を自動 clone / pull / sync しません。連携は
**`status.sh --json` を read-only で読むだけ**(presence + health の表示)です。
読んでよい情報・読まない情報の境界は
[status-manifest-contract.md](status-manifest-contract.md) と
[boundary-with-dotfiles.md](boundary-with-dotfiles.md) が正本です。

最小の参照例(dotfiles 側に置く想定。illustrative):

```sh
# 1. expected path に agent-tools があるか(presence)
AGENT_TOOLS="${AGENT_TOOLS:-$HOME/src/agent/agent-tools}"
[ -d "$AGENT_TOOLS" ] || { echo "agent-tools: absent"; exit 0; }

# 2. status を read-only で読む(health)
status=$("$AGENT_TOOLS/scripts/status.sh" --json) \
  || { echo "agent-tools: status unavailable"; exit 0; }

# 3. contract が許可した field だけ拾って表示(例: jq)
echo "$status" | jq -r '
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
次の file を **user が** 置きます (#339)。agent-tools はこれらを作らず、書き換えず、sync の対象にもしません。
file が無ければ今までどおりです。

| file | 効く先 | 読まれ方 |
| --- | --- | --- |
| `agent-tools-review.config.toml` | personal-codex-review | `codex exec -p agent-tools-review` で、base の user config の上に丸ごと重なる (Codex の profile) |
| `agent-tools-worker.config.toml` | personal-codex-worker | preflight が top-level の `model` / `model_reasoning_effort` だけを読み、`-c` で再指定する (`--ignore-user-config` の起動に他の key を持ち込まない) |

例 (値は user の判断):

```toml
# ~/.codex/agent-tools-review.config.toml
model_reasoning_effort = "high"

# ~/.codex/agent-tools-worker.config.toml
model_reasoning_effort = "high"
```

- worker の出所の優先順は、preflight の `--model` / `--effort` の明示 → worker 用 profile → `config.toml` の
  top-level です。preflight の出力 (`model_source` / `model_reasoning_effort_source`) で確かめられます。
- **Fast mode (`service_tier = "fast"`)**: 公式 docs によると、GPT-6 (Astra / Sol / Luna) の Fast mode は速度が
  1.5 倍になる代わりに Standard の 2.5 倍の credit を使い、plan の included limits も同じ割合で早く減ります
  ([Speed](https://learn.chatgpt.com/docs/agent-configuration/speed)、[Pricing](https://learn.chatgpt.com/docs/pricing)。
  2026-09-28 確認)。`[features].fast_mode` は stable で既定 on です。user config の top-level に
  `service_tier = "fast"` があると review にも効きます (profile は base の上に重なるので引き継がれる)。worker は
  `service_tier` を再指定しないので効きません。review で外すには profile 側で上書きしますが、受け付ける値は
  Codex の版で変わってきたので (新しい版は標準の意味で `"default"` を書く。旧版は `fast` / `flex` だけを受け付けた)、
  使っている版で request が通ることを確かめてから置いてください。
- model の単価も大きく違います (Pricing の input は Astra 250 / Sol 50 / Luna 2.5 credits per 1M tokens)。
  ただし credit の単価だけで plan の included usage は決まらないので、変えた後は usage の dashboard か
  session rollout で消費を見ます。

### asset を追加する

1. `shared/<category>/` に source と sidecar manifest(`<name>.asset.yml`)を置く。
   manifest の書式は [asset-manifest-schema.md](asset-manifest-schema.md)。
   name は `personal-` 始まりが必須。
2. `./scripts/check-manifests.sh` と `./scripts/check-injection.sh` で検証。
3. `build` → `register` → `sync --apply` で配置(上の「アップデート」と同じ)。

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

## 関連ドキュメント

- pipeline と各 script の役割: [onboarding.md](onboarding.md)
- コマンド別の詳細 usage: [../scripts/README.md](../scripts/README.md)
- 配置の安全則: [sync-policy.md](sync-policy.md)
- instruction の所有モデル: [instruction-artifact-kind.md](instruction-artifact-kind.md)
- dotfiles との境界・status 参照契約: [boundary-with-dotfiles.md](boundary-with-dotfiles.md) / [status-manifest-contract.md](status-manifest-contract.md)
