# Onboarding / Architecture

このドキュメントは、`agent-tools` に新しく参加する人 / AI agent が、
**全体像・設計・現在地・今後の予定**を一度に把握するための入口です。

詳細な個別仕様は各 docs にリンクします。コードは `file` (`Module.method`) 形式で
参照します (行番号は陳腐化しやすいので使いません)。

## 1. このプロジェクトは何か

`agent-tools` は、再利用可能な AI agent asset (skills / prompts / workflows /
agent definitions / instruction templates) を **管理・運用するフレームワーク**です。
asset を量産することが目的ではなく、**asset を安全に検証・生成・配置する仕組み**が本体です。

- Codex と Claude Code の共通 source repository。
- `shared/` の source asset から、tool 別 artifact を生成して各 tool home に配置する。
- public repository 前提。secrets / private planning 情報は tracked file に入れない。
- `dotfiles` とは別 repository。境界は [boundary-with-dotfiles](boundary-with-dotfiles.md)。

## 2. 全体像 (pipeline)

asset は左から右へ流れる。各段は依存ゼロ・network 不要の Ruby script。

```text
shared/<category>/personal-*        ← source asset + sidecar manifest (.asset.yml)
        │
        ▼  check-manifests.sh       schema 検証 (CheckManifests::Runner)
        │
        ▼  check-injection.sh       static prompt injection 検査 (CheckInjection::Runner)
        │
        ▼  build.sh                 generated/<tool>/skills/<name>/ に生成 + marker 埋め込み
        │
        ▼  register.sh              generated/catalog.json に「配ってよいか」を記録
        │
        ▼  connect.sh               instruction のみ: 所有ファイルを確立し CLAUDE.md に
        │  (--apply, 初回のみ)        import を繋ぐ (skill は不要 / sync が直接 create)
        │
        ▼  sync.sh                  catalog を見て registered のものだけ tool home に配置
                                    (default dry-run / --apply で実書き込み)

  status.sh / doctor.sh             pipeline の状態を read-only で観測
```

実行は手動。典型的には `build.sh && register.sh && sync.sh`
(dry-run で確認 → `sync.sh --apply`)。instruction を初めて配るときは sync の前に
`connect.sh --apply` で所有を確立する(冪等・初回のみ)。`register` と `connect` は
build 後・sync 前であればよく相互依存しない(図は直列に見えるが推奨順)。CI が PR ごとに
全 self-test + 上記一周を回す。新環境への install / update 手順は
[install-and-usage](install-and-usage.md)。

## 3. コンポーネントとコードの場所

| 役割 | entrypoint | 実装 (module / 主要 method) |
| --- | --- | --- |
| asset の発見・読み込み (共通基盤) | — | `scripts/lib/assets.rb` (`Assets.load_all` / `manifest_paths` / `sources_by_name`) |
| 致命 gate (安全判定の source of truth) | — | `scripts/lib/gate.rb` (`Gate.fatal_errors`) |
| manifest schema 検証 | `check-manifests.sh` | `scripts/lib/check_manifests.rb` (`CheckManifests::Runner#run`) |
| static prompt injection 検査 | `check-injection.sh` | `scripts/lib/check_injection.rb` (`CheckInjection::Runner#run`, `PATTERNS`) |
| build (生成 + marker) | `build.sh` | `scripts/lib/build.rb` (`Build::Runner#run`, `Build.build_id_for`, `Build.run_gates`) |
| register (catalog 生成) | `register.sh` | `scripts/lib/register.rb` (`Register::Runner#run`, `catalog_entry`) |
| sync (配置) | `sync.sh` | `scripts/lib/sync.rb` (`Sync::Runner#plan` / `plan_for` / `apply`) |
| status (観測) | `status.sh` | `scripts/lib/status.rb` (`Status::Runner#report`, `target_state`) |
| doctor (環境点検) | `doctor.sh` | `scripts/lib/doctor.rb` (`Doctor::Runner#run`, `check_catalog`) |
| psych 3/4 両対応 YAML loader | — | `scripts/lib/yaml_util.rb` (`YamlUtil.load`) |

self-test は `scripts/tests/*-test.sh`。各 entrypoint に 1 対 1 で対応する。

## 4. 安全モデル (このフレームワークの核心)

### 4.1 致命 gate を一箇所に集約

安全判定の唯一の真実は `scripts/lib/gate.rb` の `Gate.fatal_errors`。
**build と register が同じ gate を呼ぶ**ので、同じ asset への合否は必ず一致する。

致命 gate (どれか 1 つでも該当すれば fail):

- manifest validation error (`CheckManifests`)
- static injection の high finding (`CheckInjection`)
- manifest 宣言 risk が `high` (prompt_injection / privacy)
- `review.human_review: rejected`

medium の扱いは段階で異なる:

- **build** (`Build.run_gates`): medium で止めない。artifact は中間物として生成する。
- **register** (`Register::Runner#run`): medium を `review.human_review` と
  突き合わせ、catalog に `registered` / `human_review_required` を記録する。
- **sync** (`Sync::Runner#plan_for`): catalog を読み、`registered` の artifact
  だけ配置する。`human_review_required` / catalog 不在は理由つきで skip。

「build は生成する、human review 未解決のものは sync が止める」という一貫した流れ。
詳細は [register-catalog](register-catalog.md)。

### 4.2 prompt injection 検査の二層構造

- **必須層**: 自前 static checker (`check-injection.sh`)。依存ゼロ・network 不要・常に動く。
- **opt-in 拡張層** (未実装): 外部 skill scanner (NVIDIA skillspector /
  Cisco skill-scanner)。SARIF 契約・有効時 fail-closed。設計は GitHub Issue #43。

詳細は [prompt-injection-check](prompt-injection-check.md)。

### 4.3 配置の安全則

- 生成・配置対象は `personal-` prefix の asset のみ。
- 配置先は `<tool home>/skills/personal-*` のみ。禁止 target (auth / cache /
  sessions / config 等) には構造的に到達しない。詳細は [sync-policy](sync-policy.md)。
- agent-tools management marker (`.agent-tools-managed.yml`) を持つ target だけ更新。
  unmanaged な同名 target / symlink は上書きせず conflict で停止。
- sync は default dry-run。書き込みは `--apply` 明示が必須。

### 4.4 一貫した identity

- asset name は repository 全体で一意 (`CheckManifests` が重複検出)。生成 artifact の
  path になるため。
- `build_id` = source content の sha256 (`Build.build_id_for`)。build の marker、
  catalog、doctor の鮮度判定すべてが同じ hash を使う。

## 5. データの流れ (何がどこに書かれるか)

| データ | 置き場所 | tracked? | 書く主体 |
| --- | --- | --- | --- |
| source asset + manifest | `shared/<category>/` | yes | 人間 |
| 生成 artifact + marker | `generated/<tool>/skills/` | no (ignored) | build |
| catalog (登録状態) | `generated/catalog.json` | no (ignored) | register |
| 配置済み skill | `~/.codex` `~/.claude` の `skills/personal-*` | — | sync (--apply) |
| status JSON | stdout のみ | — | status |

原則: **manifest = 人間が宣言する metadata、catalog = 機械が計測した結果**。
check 結果を manifest に書き戻さない (diff churn を避ける)。

## 6. ここまでの流れと現在地

設計を先に固めてから実装する方針で進めてきた。主な足跡:

1. scaffold + 方針 docs (boundary / sync-policy / injection-check / compatibility)。
2. asset manifest schema 設計 → manifest validator 実装。
3. static injection checker 実装。
4. dotfiles 連携用の status / manifest contract 設計。
5. build adapters → dry-run sync → status → doctor → register を順に実装。
6. CI 導入 + hardening (SHA pin / Dependabot)。
7. register / catalog 設計 (catalog 形式・check 結果の扱いを確定)。
8. 中間 review でバグ・設計乖離を洗い出し、A/B/C 群を修正。
9. **pipeline 統合 (#44/#45)**: gate を一箇所に集約し、build/register の判定一致 +
   sync が catalog を尊重するように再構成。asset discovery を `assets.rb` に集約。

**現在地**: check / build / sync / status / doctor / register の 7 script が揃い、
gate 一本化で安全判定が pipeline 全体で一貫した状態。self-test 7 本が CI で回る。

`shared/` の実 asset はまだ `personal-project-operating-loop` 1 個のみ。
フレームワークは出来ているが、多様な asset 形状での実証はこれから。

## 7. 今後の予定 (open issue)

- **検証用サンプル asset の投入** (issue 未作成): directory 形式 / 複数 target /
  human_review を踏むものを `shared/` に入れ、pipeline を実 asset で 1 周回す。
  中間 review での次の一手。
- **#43 external skill scanner 連携**: 設計確定済み、実装は需要待ち
  (script を含む skill を扱う時 or CI に pip 層を足す時)。
- **#24 skill 以外の artifact kind 対応**: 各 tool の agent 形式へのマッピング設計。
- **#5 dotfiles 連携機構**: 時期待ち。前提 (status contract / marker / status.sh) は完了済み。

## 8. 開発ワークフロー

この repository 自体の進め方は
[personal-project-operating-loop](../shared/workflows/personal-project-operating-loop.md)
に従う。要点:

- 作業単位は GitHub Issue に切り、変更は PR で管理する。
- Issue ごとに branch → 実装 → self-test → public safety check → PR → CI green → squash merge。
- project planning / management docs は repository 外で別管理 (tracked file に
  tool 名や URL を書かない)。
- commit / PR 前に public safety check: secrets / private path / planning tool の
  情報が tracked file に入っていないか確認する。

新しく入る AI agent はまず `AGENTS.md` (この repository での振る舞い) と
本ドキュメントを読むとよい。
