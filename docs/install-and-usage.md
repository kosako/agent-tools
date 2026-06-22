# Install & Usage(運用ガイド)

`agent-tools` を新しい環境に入れて、更新しながら使うための運用者向けランブックです。
フレームワークの設計や pipeline の中身は [onboarding.md](onboarding.md) を参照してください。

## 前提条件

- **Ruby**: macOS 標準の Ruby で動きます(YAML stdlib のみ使用)。追加 gem は不要。
- **git**: clone / pull に使います。
- 各 script はネットワーク不要・外部依存ゼロで、手元だけで完結します。
- `gh`(GitHub CLI)は asset の利用には不要です。repository へ変更を出す
  (Issue / PR)ときだけ使います。
- この repo に commit / push する場合、配置先ディレクトリに応じた git identity の出し分けは
  各自の git 設定(`dotfiles` 等)側で行います(本 repo の管理対象外)。

配置先となる tool home(既定):

- Codex: `~/.codex`
- Claude Code: `~/.claude`

## 何がどこに置かれるか

| asset | 配置先 | 確立する操作 |
| --- | --- | --- |
| skill | `~/.codex/skills/personal-*` / `~/.claude/skills/personal-*` | `sync`(直接 create) |
| instruction | `~/.codex/AGENTS.md` / `~/.claude/agent-tools/CLAUDE.md`(人間の `~/.claude/CLAUDE.md` から `@agent-tools/CLAUDE.md` で import) | `connect`(初回所有)→ `sync`(更新) |

skill は隔離 directory なので `sync` が直接置けますが、instruction は共有ファイル
(`CLAUDE.md` / `AGENTS.md`)に載るため、**先に `connect` で所有を確立**してから
`sync` が更新します。

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

./scripts/setup.sh           # dry-run: build → register → connect → sync の plan を表示
./scripts/setup.sh --apply   # 確認できたら実環境へ反映
```

`setup.sh` は `build → register → connect → sync` を順に実行します。**既定は dry-run**
(何も書き込まない)で、`--apply` を付けたときだけ connect / sync が実環境へ書き込みます。
初回 install と更新の両方に使えます(connect は冪等なので毎回通して無害)。

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
| `skip ... (human_review_required)` | catalog で human review 待ち | manifest の `review.human_review` を解決して `register` し直す |
| `conflict ... (existing target is unmanaged)` | 同名の手書き / 別管理ファイルがある | 中身を確認。agent-tools に委ねてよいなら退避してから再実行(無断上書きはしない) |
| `conflict ... (existing target is a symlink)` | 所有先 / 親が symlink | symlink を解消するか、別 home を指定 |
| `no catalog; run register first` | catalog 未生成 | `./scripts/register.sh` |

`--codex-home` / `--claude-home` で home を上書きできます(検証用)。

## 関連ドキュメント

- pipeline と各 script の役割: [onboarding.md](onboarding.md)
- コマンド別の詳細 usage: [../scripts/README.md](../scripts/README.md)
- 配置の安全則: [sync-policy.md](sync-policy.md)
- instruction の所有モデル: [instruction-artifact-kind.md](instruction-artifact-kind.md)
- dotfiles との境界・status 参照契約: [boundary-with-dotfiles.md](boundary-with-dotfiles.md) / [status-manifest-contract.md](status-manifest-contract.md)
