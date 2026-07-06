# Runtime GitHub Injection 防御 (Phase 3)

agent が実行時に読み込む **untrusted な GitHub 入力** (Issue / PR / comment 等) に第三者が混入
させた指示で agent が誤誘導され、意図しない GitHub 書き込み・コード変更・secret 漏洩・外部送信を
起こす runtime / consumption-side の prompt injection を防ぐための、**agent-tools 側 body の正本**
です。後続の Phase 3 実装 PR (隔離 reader / credential 隔離床 / safe-gh / hook / provenance /
Codex parity) はこの文書の強度ラベル・配置先・provenance 定義・検証境界を参照します。

設計 spec の正本は外部 planning tool の設計メモ (確定オーナーシップ地図)。この文書はそれを
public-safe な範囲で repo 内に固定したものです。具体参照先 (URL / path) はここに書きません。

## supply-side との区別 (別レイヤー)

この防御は、配布する asset 自体に injection が無いか検査する supply-side の
[Prompt Injection Check](prompt-injection-check.md) (`check-injection`) とは **別レイヤー**です。
同じ "prompt injection" でも攻撃面が逆向き — supply-side は「配布物の中身」、runtime は「実行時に
流入するデータ」。混同しません。境界の分担は
[dotfiles との境界](boundary-with-dotfiles.md)「runtime GitHub injection 防御の分担」を参照。

## Threat model (trifecta)

攻撃が成立するには 3 つの脚が同時に揃う必要があります (trifecta):

1. **untrusted input** — 第三者が制御する GitHub content が agent の context に入る。
2. **privileged action** — その session が secret 参照 / GitHub write / 任意コマンド実行を持つ。
3. **egress** — 盗んだ情報を外部へ出す経路がある。

防ぎたい経路:
`untrusted GitHub content → agent context → 命令として誤解 → tool call → GitHub write / code change /
secret access / external send`。

**断ち方の原則**: trifecta は **脚を 1 本でも構造的に外せば崩れる**。本 Phase の本命は脚 1+2 を
同時に外す **隔離** — untrusted content を読む session を「secret を持たない・write できない」
別 session に隔離し、構造化 metadata のみ親へ渡す。読む側に**盗む対象も privileged action も
無い**ので、injection が刺さっても成立しない。

## 防御層と強度ラベル (hard / best-effort / steering を偽らない)

> **最重要テーゼ**: command-string allowlist / hook / provenance は **steering** であって
> enforcement boundary では**ない**。`$()` / 等価 read path (`gh` を `--comments` 無し / `gh api` /
> graphql / fork を `git fetch` + `git show` / `curl` / `python` / base64) / MCP github tool は
> Bash matcher を素通りし、WebFetch も逃げ道、PreToolUse は subagent に不発 (Claude Code の
> 既知の制約)、全失敗
> モードで fail-open。出口 (push / commit message / branch / PR title / gist / DNS exfil) も
> 列挙し切れない。**列挙非依存の hard 防御だけが本命**。

| 層 / deliverable | 強度 | 本 Phase | 置き場 |
|---|---|---|---|
| **credential 隔離 (P0-B)** | **hard** | ✅ | agent-tools (harness) / dotfiles (control plane) |
| 隔離 reader (P0-A) | steering | ✅ | agent-tools (body) |
| safe-gh wrapper | steering | ✅ | agent-tools (body) |
| PreToolUse hook (raw gh read steer) | steering (fail-open) | ✅ | agent-tools (script body) / dotfiles (settings 宣言) |
| provenance (is_self / is_bot / association) | best-effort | ✅ | agent-tools (body) |
| policy data single source | best-effort (infra) | ✅ | agent-tools |
| `script` artifact kind / 配布機構 | n/a (infra) | ✅ | agent-tools |
| Codex parity | (各層の強度を踏襲) | ✅ | agent-tools (body) / dotfiles (control plane) |
| OS egress firewall (P0-C) | hard は L3/L4 のみ | ❌ 別 tier | 将来 opt-in tier |

**hard 層は 2 つだけ**: (1) credential 隔離 (P0-B)、(2) egress の L3/L4 IP/port 遮断 (= P0-C の
hard 部分・本 Phase スコープ外)。それ以外 — 隔離 reader・safe-gh・hook・provenance・
command-string allowlist — は **steering**、hostname allowlist は **best-effort**。

### P0-B credential 隔離 (hard) の acceptance

「untrusted を読む間 `GH_TOKEN` を env から外す」だけでは **不十分** (偽の安心)。実機の `gh` /
`git` は env を外しても **keychain / credential helper 等から認証を取り直す**ため、private access が
成功し得る。よって acceptance は **認証源の構造的不在**を検証する:

- 隔離 session から次の**shell env / config 由来の**認証源が**すべて参照不能**であること:
  keychain / git credential helper (`git-credential-osxkeychain` 等) / OAuth cache / `~/.netrc` /
  `gh` の `hosts.yml`。
- **MCP github server の token store は本 acceptance の射程外**: MCP token は shell env の認証源
  ではなく agent の MCP context 側にあり、env 隔離 harness では断てない。これは **P0-A (reader の
  tool surface 制限)** / OS sandbox tier の担当。以前この列挙に MCP token store を含めていたのは
  分界の誤りで、PR-2 (実機 harness) で env 隔離の射程に合わせて是正した
  ([credential-isolation-acceptance.md](credential-isolation-acceptance.md))。
- 検証は **negative test** (= 認証済み private access が**失敗**すれば合格)。テスト反転を明示する。
- **positive control** を必ず置く: credential が在る通常 session では同じ private access が
  **成功する**ことを確認し、「そもそも到達できていないだけ」の偽合格を排除する。
- **既知の限界 (honest-label)**: これは「列挙した認証源を塞ぐ」test なので、**新しい read path /
  認証源を追加すると test が黙って緑のまま隔離が破れる**。1 本でも未列挙が残れば隔離は破れる。
  だからこそ隔離は「別 HOME 等で認証源を**構造的に**断つ」実装にし、列挙に依存しない。
- **実装 harness のスコープ (honest-label)**: 実装
  ([credential-isolation-acceptance.md](credential-isolation-acceptance.md)) の env 隔離が hard に
  検証するのは、管理された `gh` / `git` / `curl` invocation の**既定 credential 探索が空**である
  ことまで。keychain 直読みや MCP token store は env 隔離の射程外 (P0-A の tool surface 制限 /
  OS sandbox tier の担当) で、harness の緑をこの節の認証源列挙すべての検証と読まない。
  上の認証源列挙は PR-2 で env 隔離の射程 (shell env / config 由来) に是正済み。

### P0-C OS egress firewall (本 Phase スコープ外・別 tier)

egress を OS レベル (sandbox-exec / Seatbelt / pf 等) で宛先制限する層。**本 Phase には含めない**
(将来の opt-in tier)。理由と 3 段ラベル:

1. **L3/L4 IP/port 遮断 = 構造 hard** (許可外 IP/port への接続を OS が止める)。
2. **hostname allowlist = best-effort** (IP 直打ち / DNS rebinding / domain fronting で回避可)。
3. **DNS exfil / SNI-Host 不一致 / 許可 host への書込 exfil = この層では原理的に防げない既知の穴**。
   例: api.github.com は仕事に必須で許可せざるを得ず、攻撃者は**許可された正規ドアに gist を書く**
   形で漏らせる。DNS は名前解決のため通すので、情報を DNS クエリに符号化して漏らせる。

→ 防ぎたい exfil レイヤーでは hard 部分が実質薄く、marginal protection が小さい。OS / dotfiles
依存で **CI で positive 検証できず実機手動のみ**。trifecta は隔離 (P0-A + P0-B) で構造的に断つので、
P0-C は「隔離が破れたときの最後の砦」= belt-and-suspenders。本当に必要になったとき別 tier で
opt-in する。

### 隔離 reader (P0-A) の位置づけ — steering であって hard ではない

隔離 reader は untrusted GitHub 入力を「data-only・埋め込み指示を実行しない・構造化 metadata
のみ親へ」読む **安全な読み方を steering する** body。ただし reader **自体**は hard 性に寄与しない:
`$(gh issue view ...)` を Bash で直接実行する / 生 `curl` で raw content を読む / subagent が
PreToolUse を発火させない / MCP github tool 経由、などで reader を**迂回できる**。

hard なのは **床** (credential 隔離 + egress)。reader を使えば hard、ではない。reader が hard に
近づくのは「reader が credential を持たない session で動き、迂回路 (生 gh / 生 curl) も床によって
一様に private access を奪われている」とき**だけ**で、それは reader ではなく床の hard 性。

## script body の配置先 (確定)

hook / safe-gh / 隔離 reader 等の **script body は tool home subdir に配る**:

- `~/.claude/agent-tools/scripts/<name>` (Claude Code)
- `~/.codex/agent-tools/scripts/<name>` (Codex)

これは connect が既に所有する `~/.claude/agent-tools/` 名前空間 (instruction の owner-subdir
パターン) を踏襲する。`sync` が既に管理する tool home 配下なので **新しい distribution surface を
作らない**。dotfiles control plane はこの**絶対 path を参照するだけ** (body 配布先の絶対 path
参照)。`~/.config/<tool>/` 案は採らない (sync に tool home 以外の path 解決機構を新設する必要が
あり、配布面が増えるため)。

この決定が `target_path(tool, name, artifact_kind)` の設計を左右する (P3-03a で path 計算を集約し、
P3-03b で `script` kind の解決を足す)。

## provenance 3 軸 (best-effort)

agent に渡すデータの trust 判定は 3 軸で行う (spec の防御層表で定義済み):

- **`is_self`** — `gh api user` で取得する自分の login + numeric id と照合 (agent が改竄しにくい
  最堅信号なので最優先評価)。実値は dotfiles 側の非コミット local config に置く。
- **`is_bot`** — login 末尾 `[bot]` / `type == Bot`。`association` より**先に**評価する
  (bot は `association` が `NONE` に化けるため)。bot は全 untrusted。
- **`association`** — author association。ただし token scope 依存で揺れるので**単体の許可ソースに
  しない** (補助信号)。

**honest-label**: provenance は最終的に agent が読むフィールドであり、agent 制御フィールドなら
**捏造可能**。よって best-effort。hook が provenance 無しの書き込み系 tool call を拒否するのも
steering (fail-open で消える)。

## safe-gh wrapper (実装: steering)

`shared/scripts/personal-safe-gh.rb` が body。`script` artifact kind で build/sync が tool home
(`<home>/agent-tools/scripts/personal-safe-gh`) に配る。生の `gh ... --comments` を agent に
直接実行させる代わりにこれへ寄せ、untrusted content を data として扱わせる steering(迂回可・
boundary でない)。

- コマンド: `safe-gh [-R OWNER/REPO] <issue|pr> <view|comments> <number>`。出力は JSON。
- 上の provenance 3 軸で author を `self` / `bot` / `other` に分類し、self を確定できなければ
  全 `other` に倒す(fail-closed)。
- **self identity source の信頼境界 (honest-label)**: self identity は local の trust file /
  env override を最優先で読むため、それらを書ける主体は任意 author を self と詐称でき、
  その author の body withhold が外れる。local file / env の改変は本 wrapper の脅威モデル外
  (steering であり、床は実行環境側の責務)。
- **trust file の path 契約 (dotfiles 連携)**: 既定 path は
  `~/.config/dotfiles/github-trust.local`、env `SAFE_GH_TRUST_FILE` で上書き可
  (コード内定数 `DEFAULT_SELF_TRUST_FILE` / `SELF_TRUST_FILE_ENV` が正本)。この file は
  dotfiles 側が非コミットで置く local-only config で、実値 (login/id) はどちらの repo にも
  入れない。path を変えるときは dotfiles 側の置き場規約と同時に更新する。
- **他人の Issue/PR**: metadata (number/state/author/labels) のみ。**title も body も親へ渡さない**
  (title は attacker 制御の free-text = injection 面)。**自分の Issue/PR**: title/body を渡す。
- **他人コメント**: count + 固定理由のみ。著者名・プレビュー・untrusted 由来の文字列を出力に
  混ぜない。**自分のコメント**: body を渡す。
- I/O(gh 呼び出し)と純粋な trust/render ロジックを分離。ロジックは `scripts/tests/safe-gh-test.sh`
  で deterministic に検証し、gh の実挙動は実機手動(下記「検証境界」)。

## PreToolUse hook (実装: steering / fail-open)

`shared/scripts/personal-safe-gh-hook.rb` が body。`script` artifact kind で build/sync が tool home
(`<home>/agent-tools/scripts/personal-safe-gh-hook`)に配る。agent が raw な `gh` で Issue/PR/コメント
(untrusted content)を直接 context に取り込もうとしたとき、それを検出して safe-gh へ寄せる
**steering**(迂回可・block しない・boundary でない)。

- **検出 (best-effort)**: `gh issue|pr view`(既定で本文を含む)/ `--comments` / `--json` に
  `body`・`comments` を含む read / `gh api` の issues・pulls・comments path。`gh` を command word
  として持つ各 segment を見る純粋な文字列照合で、**network I/O も `gh` 呼び出しもしない**(PreToolUse は
  毎コマンド前に同期実行されるため)。author が self かは safe-gh 側が判定する。shell の厳密な構文解析は
  せず over/under-match を許容する(steering ゆえ honest-label)。
- **出力機構 (検証済み hook semantics)**: match 時に stdout へ PreToolUse の JSON
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"…(safe-gh を使え)"}}` を書く。
  `additionalContext` がモデル可視で非ブロッキングな steer 経路(exit 0 の **stderr はモデルに届かない**)。
  `permissionDecision` は **付けない**(許可フローを上書きせず他の gate を生かす。steering であって
  approve でもない)。**exit code は常に 0**(no-match / 内部例外 / 非 JSON / 非 Bash すべて透過 =
  fail-open を徹底)。
- **Codex の制約 (honest)**: Codex の PreToolUse は `additionalContext` 非対応で、返すと透過(fail-open)。
  よって Codex ではモデル可視 steer を出せず best-effort(block しない点・配線が dotfiles 側な点は同じ)。
  入力 `tool_input.command` は両 tool 共通。
- 純粋 match ロジックは `scripts/tests/safe-gh-hook-test.sh` で deterministic に検証。実 hook 配線
  (どの event に結ぶか)は dotfiles の settings.json = 実機(下記「検証境界」)。
- **登録の所有と配備先パス契約 (実体 = agent-tools / 登録 = dotfiles)**: hook script の実体と home
  配布は agent-tools が持ち、settings.json への hook 登録 (宣言) は dotfiles の settings template が
  持つ。所有を明示しないとどちらの repo も登録を持たず宙に浮く (実際に 2026-07-02 の監査まで未登録 =
  不活性だった)。**登録が無い間この hook は不活性**で steering は一切効かない (fail-open の帰結・
  honest-label)。dotfiles は配備先の絶対 path
  (`<home>/agent-tools/scripts/personal-safe-gh-hook`) を参照するため、この path は**公開契約**として
  安定を保証する: 配置規約 (`<home>/agent-tools/scripts/<name>`) や script name の変更は
  **breaking change** として扱い、dotfiles 側の hook 宣言の更新と同期するまで旧 path を壊さない。

## body ⇔ control plane 対応表

| 関心事 | agent-tools (body) | dotfiles (control plane) |
|---|---|---|
| trust 判定ロジック (provenance 3 軸) | ✅ 担当 | — |
| safe-gh wrapper 本体 | ✅ 担当 | 絶対 path 参照のみ |
| PreToolUse hook | ✅ script body + home 配布 | settings.json の hook 宣言 (参照) |
| 隔離 reader workflow | ✅ 担当 | capability gate + 置き場規約 |
| credential 隔離 session 機構 | ✅ acceptance harness | deny 床 / sandbox / token store 隔離 |
| policy data | ✅ single source (tool 別 render) | — |
| write / secret deny 床 | — | settings.json `permissions.deny` (deny-first 床。ただし列挙依存=等価経路は素通り) |
| Codex の write / secret 制限 | hook 配線のみ | `sandbox_mode` + `approval_policy` |
| egress (best-effort 宣言) | — | settings.json |
| doctor presence report / 限界 docs | — | ✅ |

> 注: この表は **誰が担うか** (ownership) を示すもので、強度ラベルは上の「防御層と強度ラベル」節が
> 正本。
> control plane の `permissions.deny` 床 / `sandbox_mode` は hook より硬い (deny-first /
> OS 強制) が、command-string matcher は列挙依存で等価経路を素通りさせるため、本文テーゼ
> 「列挙非依存の hard 防御だけが本命」の hard 2 層 (P0-B credential 隔離 + egress L3/L4) には
> 数えない。

**配布順序**: 機構 (artifact kind / path) → body (reader / wrapper / hook) → instruction 誘導。
dead-render を作らないため、成果物と消費者を同じ side (agent-tools) に置き、instruction での
tool 誘導は body が実在してから (existing tool 名を先に instruction へ書かない)。dotfiles の
control plane 責務を agent-tools 側で re-implement しない。

## 検証境界 (CI vs 実機手動)

CI (`.github/workflows/test.yml`) は `build` / `register` / `status` / `doctor` と
`scripts/tests/*.sh` の self-test を走らせるが、**`sync` / `connect` は走らせず、
`persist-credentials: false` で credential も存在しない**。よって各 PR の acceptance を二分する:

- **CI 機械検証可**: build / register が high/medium 0 で registered になる、catalog 整合、
  self-test (`scripts/tests/*.sh`)、`check-injection` (対象は `shared/**/*` のみ)。
- **実機手動検証 + 結果ログ PR 添付**: `sync` による実 home 配布 / credential 隔離の negative test /
  (将来の) firewall egress。これらは CI 範囲外。

**`CI 緑` を hard 保証 / 配布完了の根拠にしない**。credential 隔離 (P0-B) のような hard 層は
credential が在る実機でしか positive control を置けず、CI では trivially pass する (偽合格)。

## やってはいけないこと

- `CLAUDE.md` / `AGENTS.md` の注意書き **だけ**で守る (prompt 上の注意書きは補助。防御に数えない)。
- steering を hard と偽る / hostname allowlist を hard と呼ぶ / 隔離 reader を「使えば hard」と扱う。
- hard 保証を hook に通す (hook は fail-open steering)。
- 無い tool 名 (safe-gh 等) を instruction に**先に**書く (body 実在後の follow-up)。
- dead-render を作る (消費者が無い render)。dotfiles に新 bin 配布面を作る。
- secret / 具体参照先 (planning tool URL) / user-specific 絶対 path を tracked file に書く。
