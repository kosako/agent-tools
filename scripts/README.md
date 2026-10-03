# Scripts

pipeline scripts (build / register / connect / sync / status / doctor と各種 check) は
network access なしで実行できます。実装は macOS 標準の Ruby (YAML stdlib) で、追加 gem は
不要です (status / doctor は repo 状態の確認に `git` 実行ファイルを使う。無い環境でも
crash せず該当項目が degrade するだけ)。**例外は `probe-credential-isolation.sh` と
`probe-skill-routing.sh` と `probe-opencode-plugin.sh`**: 1 つ目は credential 隔離の実機検証
harness で `gh` / `git` / `curl` と network に、2 つ目は skill routing の実機観測で `claude` /
`codex` CLI と network に、3 つ目は OpenCode plugin の前提の実機観測で `opencode` CLI と network
(起動時の npm install) に依存します (いずれも CI では実行しない。下記該当節)。

`tests/` の self-tests と repository checks は CI (`.github/workflows/test.yml`) で
PR / push ごとに実行されます。

pipeline scripts の `--root` を省略したときの root は、その script が属する repo (`scripts/` の親)
です。cwd には依存しないので、repo 外の cwd から絶対パスで起動しても同じ repo を対象にします。
`shared/` を持たない root を `--root` に渡すと、build / register は致命 gate で非 0 終了し、
`generated/` と catalog を書きません (setup もそこで止まる)。self-test: `tests/root-default-test.sh`
(#305)。

## 実装済み

- `setup.sh`: `build → register → connect → sync` を一括実行する一発 setup。
  初回 install と更新の両方に使える。詳細は
  [Install & Usage](../docs/install-and-usage.md)。

```text
usage: setup.sh [--apply] [--root DIR] [--codex-home DIR] [--claude-home DIR] [--opencode-home DIR] [--quiet]
```

- **既定は dry-run**(connect / sync は plan 表示のみ・tool home に書き込まない。
  build / register は dry-run でも `generated/` と catalog を更新する)。`--apply` を
  付けたときだけ connect / sync に `--apply` を渡す。
- build の gate fail / connect・sync の conflict では停止する。register の human review
  待ち(exit 3)は非致命として継続し、note を出す(sync は registered のものだけ配置)。
- 引数は各 sub-script へ forward する(`--root` / `--quiet` は全段、`--codex-home` /
  `--claude-home` は connect / sync、`--opencode-home` は sync だけ。connect は instruction を
  配らない opencode を扱わないので渡さない)。
- self-test: `tests/setup-test.sh`

- `check-manifests.sh`: sidecar asset manifests の static validation。
  [Asset Manifest Schema](../docs/asset-manifest-schema.md) v1 に従って検証する。

```text
usage: check-manifests.sh [--root DIR] [--quiet]
```

- error は `path: message` の line 単位で出力され、error があれば exit 1。
- manifest を持たない asset source も検出する。
- tool と artifact_kind の組 (`ArtifactTargets::TOOL_KINDS`) を検査し、build 対応 kind なのに
  表に無い組 (plugin → codex / claude-code、skill・instruction・script → opencode) を error にする。
  build 非対応 kind (agent) は従来どおり error にしない (register が unsupported にする)。
  `compatibility.<tool>.artifact_kind` の `script` / `plugin` への上書きは禁止
  (`CheckManifests::NON_OVERRIDABLE_KINDS`)。plugin の source は単一の `.js` / UTF-8 / 先頭が `#!` と
  marker prefix でないことを検査する (文言は
  [Asset Manifest Schema](../docs/asset-manifest-schema.md)「plugin source の制約」)。
- self-test: `tests/check-manifests-test.sh`

- `check-injection.sh`: shared assets への static prompt injection checks。
  [Prompt Injection Check 方針](../docs/prompt-injection-check.md) に従う。

```text
usage: check-injection.sh [--root DIR] [--quiet]
```

- findings は `path:line: [risk] category: message` 形式で出力される。
- exit code: high findings は 1 (registration fail)、medium のみは 3
  (human review 必須)、findings なしまたは low のみは 0。
- 対象は `shared/` 配下の text files のみ。policy docs は対象外。
- self-test: `tests/check-injection-test.sh`

- `check-credential-isolation.sh`: credential 隔離 acceptance harness の判定コア。probe 結果
  (JSON) を受け、隔離が破れていないか判定する (probe の実機実行は `probe-credential-isolation.sh`)。
  [Credential Isolation Acceptance](../docs/credential-isolation-acceptance.md) に従う。

```text
usage: check-credential-isolation.sh --judge <results.json>
```

- required チャネル (`gh` / `git-https`。一覧の正本は lib の `REQUIRED_CHANNELS` / `--help`) に
  同一 operation の negative/positive ペアを 1 組以上要求し、credential leak・空振り緑・チャネル
  欠落を弾く。`git-ssh` / `curl` は ambient 認証源がセッション依存のため opt-in (含めれば完全ペア
  必須、無くても欠落扱いしない)。さらに各チャネルに reachability control (隔離 session 内の
  認証なし到達確認) をちょうど 1 本要求し、到達不能 (`reachable=false`) は indeterminate
  (緑に数えない) に倒す (#185)。
- exit code: 隔離確認は 0、観測された破れ (leak / false-green) は 1、usage / 入力・構造エラー
  (チャネル欠落・ペア不成立・重複・reachability 欠落) と indeterminate (到達不能) は 2。
  破れと同居したら 1 を優先し全件報告する。
- self-test: `tests/check-credential-isolation-test.sh`

- `probe-credential-isolation.sh`: credential 隔離 acceptance harness の probe runner (実機)。
  required チャネル (gh / git-https) + opt-in (git-ssh / curl) を private target に隔離 / 非隔離で
  叩き、認証成否を `results.json` (judge 入力) として出力する。各チャネルでは隔離 session 内の
  認証なし同一ホストアクセス (reachability control) も 1 回観測する (#185)。隔離 recipe の SSOT は
  `lib/credential_isolation_recipe.sh`。

```text
usage: probe-credential-isolation.sh [--config PATH] [--out FILE] [--dry-run]
```

- probe target は local config 由来 (既定 `~/.config/dotfiles/github-isolation-probe.local`、
  `GITHUB_ISOLATION_PROBE_CONFIG` / `--config` で上書き)。public repo にハードコードしない・
  不在時は明示 fail。`--dry-run` は credential に触れず組み立てを表示する。
- **CI では実行しない** (credential 不在)。hard 保証は実機ログ (PR 添付) が正本で、CI 緑を
  根拠にしない ([Credential Isolation Acceptance](../docs/credential-isolation-acceptance.md))。
- self-test: `tests/probe-credential-isolation-test.sh` (実 credential に触れず recipe の env
  構造 / config 不在 fail / dry-run を検証)。

- `check-skill-routing.sh`: skill routing acceptance harness の判定コア。case set と probe 結果
  (JSON) を受け、coverage / primary hit / must_not violation / token を判定・報告する。
  `--baseline` で before / after を比較する。
  [Skill Routing Acceptance](../docs/skill-routing-acceptance.md) に従う。

```text
usage: check-skill-routing.sh --cases <cases.json> --results <results.json> [--baseline <results.json>]
```

- exit code: pass は 0、観測された破れ (must_not violation / baseline からの回帰) は 1、
  usage / 入力・構造エラー (coverage 欠落・error run・比較条件不一致) は 2。token は gate にせず
  delta を報告するだけ。
- case set の正本は `lib/skill_routing_cases.json`。
- self-test: `tests/check-skill-routing-test.sh`

- `probe-skill-routing.sh`: skill routing acceptance harness の probe runner (実機)。候補 skill
  だけを project scope に置いた隔離 project で `claude -p` / `codex exec` を headless 実行し、
  発火した skill と token 使用量を `results.json` (judge 入力) に書く。実 tool home には
  書き込まない。Codex は監査 / review と同じ境界 (`--ignore-user-config` / `--ignore-rules` /
  `--disable apps` 等) で起動し、起動の前に flag と feature の在否を確かめる (#372)。

```text
usage: probe-skill-routing.sh --tool <claude-code|codex> --out <results.json>
         [--source DIR] [--cases FILE] [--variant LABEL] [--model MODEL] [--repeat N]
         [--only ID[,ID...]] [--max-turns N] [--timeout SEC] [--dry-run] [--smoke]
```

- **CI では実行しない** (CLI 認証と network が要る)。証跡は raw log (`<out>.raw/`) と judge の
  summary。`--smoke` で隔離と event 形式を先に確認する (実測した版: Claude Code 2.1.277 /
  Codex CLI 0.153.4、境界つきの起動は 0.159.3)。
- self-test: `tests/probe-skill-routing-test.sh` は Codex の起動の境界 (argv と、起動の前の flag と
  feature の確認) だけを偽の `codex` で確かめる。event の解析と CLI の実起動は対象外 (実機で
  `--smoke`)。`--dry-run` / `--help` の引数契約は `tests/cli-args-test.sh` の対象外。

- `probe-opencode-plugin.sh`: OpenCode plugin probe の runner (実機・#295)。HOME / XDG / DB /
  git config を tmp に向けた隔離環境で `opencode` を起動し、計測用 plugin と 127.0.0.1 の mock
  provider で plugin の前提 (M1〜M20) を観測して、raw の記録と summary を `--out` に書く。
  実物の OpenCode の config / DB / auth は読ませない。Spec: [docs/opencode-plugin-probe.md](../docs/opencode-plugin-probe.md)。

```text
usage: probe-opencode-plugin.sh --stage <isolation|serve|mock|real|tui-plan|all> --out DIR
         [--real] [--model provider/model] [--pass-env NAME]... [--shell sh|user]
         [--timeout SEC] [--keep] [--dry-run]
```

- **CI では実行しない** (`opencode` CLI と、起動時の npm install の network が要る)。`--out` は
  git の worktree の外に限る。docs に写すのは summary だけ。
- self-test: `tests/probe-opencode-plugin-test.sh` (opencode も外部の network も使わない。T2 / T6 は
  偽の `opencode` で runner を通しで動かす。node が要る)。

- `build.sh`: shared source assets から tool 別 artifacts を `generated/` に生成する。
  adapter spec は [adapters/](../adapters/README.md) を参照。

```text
usage: build.sh [--root DIR] [--prune] [--quiet]
```

- 生成前に register と共有の致命 gate (`lib/gate.rb`) を通す。fail なら何も生成しない。
  medium finding では止めず生成する (中間物。配置は sync が catalog を見て止める)。
- management marker を埋め込む。skill は directory 直下の `.agent-tools-managed.yml`、
  instruction は本体先頭の 1 行 HTML コメント marker、script は本体の隣の sidecar
  `.agent-tools-managed.yml`、plugin は本体先頭の 1 行 JS ブロックコメント marker
  (`lib/plugin_marker.rb`。mode 0644、2 行目以降は source の bytes)。`build_id` は source
  content の sha256 なので build は決定的 (plugin の marker 行は build_id に含めない)。
- 生成と prune は `ArtifactTargets::TOOL_KINDS` の組だけを回す (codex / claude-code は skill /
  instruction / script、opencode は plugin)。表に無い組は `unsupported artifact_kind` として skip
  し、`generated/opencode/skills/` などは走査しない。
- 書き込み先は `generated/` のみ。tool directories には書き込まない。
- `--prune` で manifest に対応しなくなった generated artifact を削除する。対象は
  agent-tools marker を持つ skill directory / instruction file / script (本体 + sidecar) /
  plugin file のみで、marker のない directory / file は警告して残す。
- self-test: `tests/build-test.sh`

- `connect.sh`: instruction の所有ファイルを確立し、人間の instruction ファイルから
  繋ぎ込む。[Instruction Artifact Kind](../docs/instruction-artifact-kind.md) に従う。

```text
usage: connect.sh [--root DIR] [--apply] [--codex-home DIR] [--claude-home DIR] [--quiet]
```

- default は dry-run。書き込みには `--apply` が必須。冪等(再実行しても安全)。
- **claude-code**: `<claude home>/agent-tools/CLAUDE.md` を所有ファイルとして作成し、
  人間の `<claude home>/CLAUDE.md` に `@agent-tools/CLAUDE.md` の import 1 行を足す
  (既にあれば no-op)。
- **codex**: import 非対応のため `<codex home>/AGENTS.md` を直接所有する
  (空ファイルのみ claim 可)。
- symlink / dir / 特殊ファイルは触らない。所有先に unmanaged な中身があれば
  conflict で停止し、何も書き込まない。先に `build.sh` で generated instruction が
  必要。instruction を配らない構成なら不要。
- self-test: `tests/connect-test.sh`

- `sync.sh`: `generated/` の personal assets を tool directories へ反映する。
  [Sync Policy](../docs/sync-policy.md) を enforce する。

```text
usage: sync.sh [--root DIR] [--apply] [--prune] [--codex-home DIR] [--claude-home DIR] [--opencode-home DIR] [--quiet]
```

- default は dry-run。書き込みには `--apply` が必須。
- **catalog (`generated/catalog.json`) を尊重する。`registration: registered` の
  artifact だけを配置する。** `human_review_required` / catalog 不在は理由つきで skip。
  先に `register.sh` を実行する必要がある。
- plan は `create` / `update` / `skip` / `conflict` (と `--prune` 時の `delete`) で表示される。
- `--prune` で catalog に載らなくなった deployed asset を撤去する (`build --prune` の
  sync 版)。削除は marker 一致 + catalog 不在の orphan のみで、unmanaged / symlink は
  触らず skip 表示。実削除には `--apply` が必須。instruction は対象外
  ([sync-policy](../docs/sync-policy.md) の「撤去」)。
- 更新するのは agent-tools management marker を持つ target のみ。
  unmanaged な同名 target / symlink は conflict として exit 1 で停止し、何も書き込まない。
- 書き込み先は skill が `<tool home>/skills/personal-*`、instruction が connect 確立済みの
  所有ファイル (`~/.codex/AGENTS.md` / `~/.claude/agent-tools/CLAUDE.md`)、script が
  `<tool home>/agent-tools/scripts/personal-*` (単一実行ファイル + sidecar marker)、plugin が
  `<opencode home>/plugins/personal-*.js` (単一 file、mode 0644、先頭 1 行 marker)。
  それ以外の path は構成しない。plan と prune が走査する tool と kind の組は
  `ArtifactTargets::TOOL_KINDS` に従い、opencode home の `skills/` と `agent-tools/scripts/` は
  走査しない ([sync-policy](../docs/sync-policy.md) の「v1 OpenCode targets」)。
- `--codex-home` / `--claude-home` / `--opencode-home` は inspection / test 用の override
  (opencode の既定は `~/.config/opencode`。`XDG_CONFIG_HOME` は見ない)。
- self-test: `tests/sync-test.sh` (fake home のみを使い、実際の tool homes には触れない)

- `status.sh`: report-only status。
  [Status / Manifest Contract](../docs/status-manifest-contract.md) の JSON を出力する。

```text
usage: status.sh [--root DIR] [--json] [--codex-home DIR] [--claude-home DIR] [--opencode-home DIR]
```

- `--json` で contract_version 3 の JSON、省略時は human-readable summary。
- manifest validation / injection check の結果、generated の stale 数、
  sync target state (managed / stale / conflict / missing / deployed_but_inactive) を含む。
  generated の列挙は `ArtifactTargets::TOOL_KINDS` の組だけを回し、plugin の鮮度は先頭行 marker の
  `build_id` と `Build.build_id_for` の比較で判定する。`sync_targets[].tool` に `opencode` が入る。
- read-only。いかなる state も変更しない。
- 出力に absolute local paths / secrets を含めない。
- self-test: `tests/status-test.sh`

- `doctor.sh`: state を変更せず、local environment assumptions を inspect する。

```text
usage: doctor.sh [--root DIR] [--codex-home DIR] [--claude-home DIR] [--opencode-home DIR] [--agents-home DIR]
```

- ruby / git、status report の統合、tool homes、禁止 targets への marker
  誤存在、catalog の存在と鮮度を check する。
- tool home の表示は `ArtifactTargets::TOOL_KINDS` に従う。opencode は
  `[opencode] <label> present, N personal plugin(s)` で、数えるのは `plugins/personal-*.js` のうち
  先頭行 marker が `target=opencode` で name が file 名と同じもの (`PluginMarker.managed?`。sync の
  所有判定と同じ条件)。custom home は
  label に置き換え、生の path を出さない。`--opencode-home` を省いて既定 home を使い、かつ
  `$XDG_CONFIG_HOME/opencode` が既定と食い違うときだけ warn を出す。禁止 targets の検査 (sidecar
  marker を探す方式) に `<opencode home>/node_modules` は足さない (file 先頭 marker の plugin は
  この方式で検出できないため)。OpenCode が plugin を読み込んだかや二重読込の判定は dotfiles の
  doctor が持つ ([boundary-with-dotfiles](../docs/boundary-with-dotfiles.md)「OpenCode home の所有」)。
- 出力は `level: area: message` 形式 (ok / info / warn / fail)。fail があれば exit 1。
- read-only。paths は tilde 表記で出力し、secrets を含めない。
- self-test: `tests/doctor-test.sh`

- `register.sh`: assets を検証し、`generated/catalog.json` に登録状態を記録する。
  [Register / Catalog](../docs/register-catalog.md) に従う。

```text
usage: register.sh [--root DIR] [--quiet]
```

- gate は build と同じ。manifest error / high finding で fail し、catalog を更新しない。
- medium finding は manifest の `review.human_review` と asset 単位で突き合わせる。承認は
  `review.approved_build_id` が現在の build_id と一致し、かつ `review.approved_artifact_kind`
  が target の resolve 済み artifact_kind と一致するときだけ効く (内容と配布形態に紐づく
  承認, #148 #184)。
- exit code: 0 (human_review_required なし) / 3 (human_review_required あり) / 1 (gate fail)。
  unsupported は exit code に影響しない。
- resolve 後の artifact_kind が `script` / `plugin` の asset は、risk / finding によらず常に human
  review 必須 (`Register::Runner#review_needed?`。実行コードの配布)。catalog_version は 4 のまま
  ([Register / Catalog](../docs/register-catalog.md))。
- 書き込みは `generated/catalog.json` のみ。
- self-test: `tests/register-test.sh`

## artifact_kind / tool を追加するときのチェックリスト

kind / tool の知識は `lib/artifact_targets.rb` に集約されているが (#152)、追加時に
触る場所は 1 箇所ではない。取り残しが docs drift・サイレント断裂の原因になるので、
追加 PR ではここを順に確認する。

**artifact_kind を追加するとき**:

1. `lib/artifact_targets.rb`: `SUPPORTED_KINDS` / `DEFAULT_BY_KIND` /
   `GENERATED_SUBDIRS` / `generated_path` / `target_path` / `buildable?`、そして `TOOL_KINDS`
   (どの tool に配れる kind か。表に無い組は生成も配置も列挙もされない)。
2. `lib/check_manifests.rb`: asset kind の列挙 `KINDS` と置き場所 `ASSET_CATEGORIES` (manifest の
   `kind` と artifact_kind は別物。後者の検証は `ArtifactTargets.supported?` を参照済み)。実行コードの
   配布形態なら `NON_OVERRIDABLE_KINDS` に足して `compatibility.*.artifact_kind` での上書きを禁じる。
   tool / kind の組の検査 (`check_target_kinds`) は `TOOL_KINDS` を参照するので追加不要。source の
   形式に制約があるなら `check_<kind>_source` を足す。
3. `lib/build.rb`: `build_<kind>` の実装と `run` の分岐、`prune_<kind>` と `prune` の期待リスト
   (`TOOL_KINDS` の組で回す。builder が無い kind は ArgumentError)。
   marker 戦略は [Status / Manifest Contract](../docs/status-manifest-contract.md)
   (directory = 直下 marker / 単一ファイル = sidecar / 本文コメント) に従う。本文コメント marker
   なら `lib/<kind>_marker.rb` を分けて作り、既存 marker と相互に拒否させる。
4. `lib/register.rb`: 実行コードの配布形態なら `review_needed?` に足して常に human review 必須にする。
   entry の key の順は変えない。
5. `lib/sync.rb`: `plan_<kind>` の実装 (所有 / stale / symlink 防御を既存 kind と
   対称に)、`apply` / `delete_target` の分岐、`prune_plans` の kind 別の走査。
6. `lib/status.rb`: `generated_state` の鮮度判定が新 kind の marker を読めるか (列挙は `TOOL_KINDS`)。
7. `lib/doctor.rb`: home の表示 (`check_tool_homes`) が新 kind を数えるか。
8. docs: この README の該当 script 節 / [adapters/](../adapters/README.md) /
   [Asset Manifest Schema](../docs/asset-manifest-schema.md) /
   [Register / Catalog](../docs/register-catalog.md) /
   [Sync Policy](../docs/sync-policy.md) / [Status / Manifest Contract](../docs/status-manifest-contract.md) /
   [onboarding](../docs/onboarding.md) / [Install & Usage](../docs/install-and-usage.md)。
9. tests: `tests/check-manifests-test.sh` / `build-test.sh` / `sync-test.sh` / `status-test.sh` /
   `register-test.sh` / `doctor-test.sh` に既存 kind と対称のケースを足す。

**tool を追加するとき** (tool 語彙と home 既定値は #192 で一元化済み。#295 で opencode を足した):

1. tool 一覧と home 既定値: `lib/artifact_targets.rb` の `TOOLS` と `default_homes`、そして
   `TOOL_KINDS` にその tool が受け取る kind の列 (build / sync / check-manifests / status / doctor は
   ここを参照する)。生成・prune・plan・列挙・表示は `TOOLS` × 全 kind ではなく `TOOL_KINDS` の
   組で回す (他 tool の home の `skills/` などを走査して消さないため)。
2. CLI flag: `sync` / `status` / `doctor` の `main` と `setup.sh` の forward に `--<tool>-home` を
   足す。`connect` に足すのは instruction を配る tool だけ (配らない tool では connect は flag を
   受け付けず exit 2 のままにする)。
3. instruction を配るなら `ArtifactTargets::INSTRUCTION_FILENAMES` と connect の
   所有戦略 (import 対応可否)。
4. `lib/check_manifests.rb`: `TARGETS` の列挙は `ArtifactTargets::TOOLS` 参照なので追加不要だが、
   tool / kind の組の error 文言 (`<tool> accepts: ...`) が docs と一致するか確かめる。
5. `lib/doctor.rb`: `check_tool_homes` の表示と、custom home の label 化。`forbidden_paths` は
   sidecar marker 方式で検出できる dir だけを足す。
6. tests と CI: sync / status / doctor / setup を呼ぶ**すべての** test の call site に `--<tool>-home`
   を足し (実物の home を読み書きしない)、静的な検査と home の canary で漏れを確かめる。
   `.github/workflows/test.yml` の status / doctor にも空の home を渡す。
7. docs: [tool-compatibility](../docs/tool-compatibility.md) の表と「配らない理由」、
   [adapters/<tool>/README.md](../adapters/README.md)、[Sync Policy](../docs/sync-policy.md) の
   許可 / 禁止 target、[boundary-with-dotfiles](../docs/boundary-with-dotfiles.md) の home の所有、
   [Install & Usage](../docs/install-and-usage.md) の配置先の表。

## 予定している scripts

- `check-injection.sh` への追加: optional LLM review (privacy preflight つき)。

scripts の実装は、対応する GitHub Issue で scope されるまで行いません。
