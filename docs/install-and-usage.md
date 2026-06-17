# Install & Usage(運用ガイド)

`agent-tools` を新しい環境に入れて、更新しながら使うための運用者向けランブックです。
フレームワークの設計や pipeline の中身は [onboarding.md](onboarding.md) を参照してください。

## 前提条件

- **Ruby**: macOS 標準の Ruby で動きます(YAML stdlib のみ使用)。追加 gem は不要。
- **git**: clone / pull に使います。
- ネットワーク不要・外部依存ゼロ。各 script は手元だけで完結します。
- `gh`(GitHub CLI)は asset の利用には不要です。repository へ変更を出す
  (Issue / PR)ときだけ使います。

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

```sh
git clone <this-repo> agent-tools
cd agent-tools

# 1. 生成(generated/ にのみ書き込む。tool home には触れない)
./scripts/build.sh

# 2. 登録(配ってよい asset を catalog に記録)
./scripts/register.sh

# 3. 所有の確立(instruction のみ。default dry-run → 確認して --apply)
./scripts/connect.sh            # 何が起きるか確認
./scripts/connect.sh --apply    # 実際に所有ファイルを作り、CLAUDE.md に import 1 行を足す

# 4. 配置(default dry-run → 確認して --apply)
./scripts/sync.sh               # plan を確認(create / update / skip / conflict)
./scripts/sync.sh --apply       # tool home に反映
```

- `connect` は冪等です。既に import 行があれば no-op。symlink / 既存の手書き内容が
  ある所有先は触らず conflict で停止します(何も書きません)。
- instruction を配らない(skill だけの)構成なら手順 3 は不要です。
- `register` と `connect` はどちらも `build` の後・`sync` の前であればよく、相互に依存
  しません(上の番号は推奨順)。`sync` だけが両者(catalog と所有確立)を前提とします。

## アップデート

```sh
cd agent-tools
git pull

./scripts/build.sh
./scripts/register.sh
./scripts/sync.sh           # dry-run で差分確認
./scripts/sync.sh --apply   # 反映
```

- `connect` は初回だけ。所有が確立済みなら以後の更新は `sync` が担います。
- source asset を編集したときも同じ流れです(`build` が source の sha256 で
  `build_id` を再計算し、`sync` が差分のある target だけ `update` します)。

## 日常の使い方

### 状態を見る

```sh
./scripts/status.sh         # human-readable サマリ(--json で機械可読)
./scripts/doctor.sh         # 環境点検(ruby/git、tool home、catalog の鮮度など)
```

どちらも read-only で、state を一切変更しません。

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
