# dotfiles との境界

`dotfiles` と `agent-tools` は、別 repository / 別 project tracking として扱います。

## dotfiles が持つ責務

- AI execution environment policy。
- capability declarations。
- directory conventions。
- local machine setup の safety gates (settings.json の permission deny floor / sandbox / MCP gate)。
- runtime GitHub injection 防御の **control plane**: settings.json の permission / sandbox / hook
  宣言 (参照)、capability gate、trust list / egress local の置き場規約、body 配布先の絶対 path 参照、
  doctor の presence report、射程と限界の docs。**body (trust 判定 / safe reader / hook script /
  token 隔離 / 隔離 reader) は持たない** (下記「runtime GitHub injection 防御の分担」)。
- optional companion repositories が存在するかどうかの report-only checks。

## agent-tools が持つ責務

- reusable personal skills。
- prompt libraries。
- workflow definitions。
- agent definitions。
- instruction templates。
- tool-specific generated artifacts。
- runtime GitHub injection 防御の **body / 振る舞い**: provenance の trust 判定ロジック
  (signal の定義と分類規則は `docs/runtime-injection-defense.md` が正本)、
  `safe-gh` wrapper 本体、`PreToolUse` hook の script body と home 配布 (build / sync)、
  隔離 reader workflow、policy data の single source (tool 別 render)、Codex hook 用の body 互換 (登録・配線は dotfiles)
  (下記「runtime GitHub injection 防御の分担」)。
- registered assets 向け prompt injection review policy (supply-side: 配布する asset 自体に
  injection が仕込まれていないかを register / sync 前に検査する。runtime の外部入力防御とは
  別レイヤー)。

## runtime GitHub injection 防御の分担 (control plane ⇔ body)

agent が実行時に読み込む untrusted な GitHub 入力 (Issue / PR / comment 等) に対する防御は、
**dotfiles が control plane、agent-tools が body** を持つ。同じ "prompt injection" でも、配布 asset
自体を検査する supply-side review (上記 agent-tools 責務の「registered assets 向け prompt injection
review policy」) とは攻撃面が逆向きの別レイヤー。設計の spec 正本は外部 planning tool の設計メモ
(確定オーナーシップ地図)。agent-tools 側 body の強度ラベル・配置先・provenance 定義・検証境界の
正本は [Runtime GitHub Injection 防御 (Phase 3)](runtime-injection-defense.md) を参照。

- **dotfiles (control plane)**: capability gate、settings.json の permission deny floor / sandbox /
  MCP github gate / hook 宣言 (参照)、trust list・egress local の置き場規約、body 配布先の絶対 path
  参照、doctor の presence report、射程と限界の docs。
- **agent-tools (body)**: trust 判定ロジック (provenance。定義は runtime-injection-defense.md)、`safe-gh` wrapper 本体、hook の
  script body とその home 配布 (build / sync)、隔離 reader workflow、policy data の single source、
  Codex hook 用の body 互換 (登録・配線は dotfiles)。

原則は「runtime / invocation に属するものは agent-tools、宣言 / 規約 / capability に属するものは
dotfiles」。command-string allowlist / hook / provenance は enforcement boundary ではなく steering で
ある (egress も hostname best-effort) 点は、過大評価しないよう spec と docs で honest に明記する。

hook のように 1 つの機能が両 repo にまたがるもの (実体 = agent-tools / 登録 = dotfiles) は、所有を
明示しないとどちらも持たず宙に浮く (機能は配備済みなのに不活性になる)。script 資産の配備先 path
(`<home>/agent-tools/scripts/<name>`) は dotfiles が settings.json 等から絶対 path で参照する
**公開契約**であり、agent-tools は path の変更を breaking change として扱う (dotfiles 側の参照更新と
同期するまで旧 path を壊さない)。詳細は
[Runtime GitHub Injection 防御](runtime-injection-defense.md) の「PreToolUse hook」節。

## OpenCode home の所有 (#295)

OpenCode の tool home (`<opencode home>`。既定 `~/.config/opencode`) は複数の主体が file を置く
共有 dir なので、所有を file 単位で分ける。agent-tools が書くのは 1 pattern だけ。

| file | 所有 | agent-tools の扱い |
| --- | --- | --- |
| `opencode.json` (`opencode.jsonc`) | dotfiles | 読まない・書かない。plugin の登録も書かない (置くだけで登録になる) |
| `opencode.local.json`、auth | local (非コミット) | 触らない |
| `node_modules/`、`package.json`、`package-lock.json`、`bun.lock`、`.gitignore` | OpenCode 本体 (起動時に `@opencode-ai/plugin` を npm install して書く) | 触らない |
| `plugins/herdr-agent-state.js` | herdr (herdr の installer を使ったときに置かれる。Issue #295 の Phase 1 の記述による。この machine では未導入で、未実測) | `personal-` で始まらないので plan にも prune にも出さない |
| `plugins/personal-*.js` | **agent-tools** | sync が配置・更新・撤去する唯一の場所 ([Sync Policy](sync-policy.md)「v1 OpenCode targets」) |
| `skills/`、`agent-tools/` | (agent-tools は使わない) | 走査しない |

- **登録の例外**: Claude Code / Codex の hook は「実体 = agent-tools、登録 = dotfiles」に分けているが、
  OpenCode では `plugins/` に file を置くこと自体が登録 (trust gate も config への記述も無い) なので、
  plugin については登録も agent-tools が持つ。一時的に外すには `opencode --pure` で起動する。恒久に
  撤去するには source と manifest を消して `register` し、`sync --prune --apply` で orphan として撤去する
  (catalog に残る限り prune は消さず、既定は dry-run)。
- **doctor の分担**: agent-tools の doctor が見るのは「自分が置いた `plugins/personal-*.js` があり、
  先頭行の marker が正しいこと」と、既定 home (`~/.config/opencode`) と `$XDG_CONFIG_HOME/opencode`
  の食い違い (`--opencode-home` を省いたときだけ warn) まで。OpenCode が plugin を実際に読み込んで init を
  終えたか (下記「OpenCode plugin の init の目印」の行で判定する) と、二重読込 (単数形の `plugin/` dir、
  同名の `.ts` / `.mjs`、設定 file の `plugin` 欄、global と project の両方への配置) の判定は dotfiles の
  doctor が持つ。どちらの doctor も OpenCode を起動しない (`opencode debug config` も実行のたびに OpenCode の
  DB へ書き込む (1.18.30 の dotfiles 側の実測) ので、report-only の検査には使わない)。
- **instruction の公開契約**: `~/.claude/agent-tools/CLAUDE.md` は dotfiles の `opencode.json` の
  `instructions` から参照される。OpenCode は `~/.claude/CLAUDE.md` を直接読む
  ([opencode-plugin-probe](opencode-plugin-probe.md) の M15) が、この path も script の配備先と
  同じく **公開契約**で、変更は breaking change (dotfiles 側の参照更新と同期するまで旧 path を壊さない)。
- **plugin は claude-code target の script に依存する**: plugin は薄い adapter で、判定は Claude Code
  target に配った `~/.claude/agent-tools/scripts/personal-*` (safe-gh-hook 等) を `os.homedir()` から
  解決して無改変で呼ぶ (script kind は tool ごとに置き場を変えられないため。custom の claude home
  には対応しない)。よって OpenCode で plugin を効かせるには、claude-code target の sync も済んで
  いる必要がある。script が無ければ plugin は no-op (fail-open) で、OpenCode を止めない。

## OpenCode plugin の init の目印 (#343)

OpenCode が plugin を実際に読み込んで init を終えたかは、OpenCode を起動しない静的な検査では分からない。
そこで plugin `personal-agent-tools` は init を終えた時点で目印の行を OpenCode の log に出し、dotfiles の
doctor が既にある log を読んで判定する。以下は **公開契約**で、agent-tools は変更を breaking change として
扱う (dotfiles 側の reader の更新と同期するまで旧い形を壊さない)。

- **行の形**: `client.app.log` に service `personal-agent-tools`・level `info` で、次の 1 行を message として
  渡す。token は単一の空白区切りで、この順に並び、ほかの token を持たない。

  ```text
  agent-tools:plugin-init v=1 name=personal-agent-tools build_id=sha256:<64 桁の小文字 hex>
  ```

  | 部分 | 意味 |
  | --- | --- |
  | `agent-tools:plugin-init v=1` | 固定の接頭辞。`v` は行の形の版で、形を変えるときは版を上げる (旧い reader は新しい版の行を目印とみなさず、未確認に倒れる) |
  | `name=` | plugin の名前 (asset 名 = 配置した file の basename = marker の `name`)。今は `personal-agent-tools` だけ |
  | `build_id=` | plugin の module を読み込んだ時点で、配置された自分の file の 1 行目の marker ([Status / Manifest Contract](status-manifest-contract.md) の plugin marker。build が前置する) から読んだ `build_id`。marker が無い・`PluginMarker.owned` が拒否する形・`sha256:` + 64 桁の小文字 hex でない・file として読めないときは `unknown` |

  secret、path (directory を含む)、session の内容、env は載せない。
- **出す時点**: `server()` が hooks の object を組み終えて return する直前に 1 回。行が示すのは「`server()` が
  return まで到達した」ことまでで、return の後に OpenCode 側で起きる失敗は含まない。`server()` が途中で throw
  したとき (options の誤りなど) は出さない (失敗を示す行も無い)。
- **回数**: `server()` の 1 回の呼び出しに 1 行。OpenCode は directory の instance ごとに `server()` を呼ぶ
  ので、1 つの process から複数の行が出うる (2026-10-05 に 1.18.30 の `opencode serve` で実測: directory A に
  2 回・B に 1 回 request して行は 2 行。`--pure` の起動では行が出ない。instance を作り直したときも呼ぶのは
  source の読みで、未実測)。
  行の数に意味を持たせない。build_id は module の読込の時点で 1 回だけ読むので、同じ process の中では、後から
  sync が file を置き換えても読み込み済みの code の build_id を出し続ける (OpenCode が file を読み込んでから
  plugin が同じ file を読み直すまでの短い間に置き換わったときだけ食い違いうる)。
- **fail-open**: log は待たず、client が無い・`app.log` が throw / reject するときも握って hooks を返す。build_id の
  読み取りの失敗も `unknown` に倒すだけで、どちらも plugin の動作を止めない。そのため行が無いことは init の失敗の
  証拠にならない。
- **出る場所 (OpenCode の持ち物)**: `client.app.log` は OpenCode の log file に書かれる (1.18.30 では
  `<data>/opencode/log/opencode.log`。[opencode-plugin-probe](opencode-plugin-probe.md) の M11)。log file の場所・
  rotate・message を囲む行の形は OpenCode のもので、この契約に含めない (OpenCode を更新したら実機で確かめる)。
  1.18.30 の行には service 名が出ない ([quality-loop-hooks](quality-loop-hooks.md)) ので、reader は message の
  接頭辞で探す。2026-10-05 に OpenCode 1.18.30 (@opencode-ai/plugin 1.18.30) で実測した行の形は
  `timestamp=<ISO 8601> level=INFO run=<id> message="agent-tools:plugin-init v=1 name=personal-agent-tools build_id=sha256:<64 桁>"`
  で、message は二重引用符で囲まれる (行の末尾は `"`)。reader は行の末尾の位置に頼らず、接頭辞の後の
  `build_id=` の値を `sha256:` + 64 桁の小文字 hex か `unknown` の形で取り出す (message は空白と `"` を含まない
  token だけでできている)。level は INFO なので、`--log-level` で WARN / ERROR に絞った起動では書かれない
  (source の読み。未実測)。
- **doctor の判定 (reader は dotfiles)**: 「確認できた」とするのは、log の中でいちばん新しい
  `name=personal-agent-tools` の目印の行の build_id が、いま配置されている `plugins/personal-agent-tools.js` の
  1 行目の marker の build_id と一致するときだけ。次はどれも「未確認」とし、成功とも失敗とも言わない。

  | 状態 | 例 |
  | --- | --- |
  | 未起動 | log file が無い (OpenCode をまだ起動していない) |
  | 証跡なし | log はあるが目印の行が無い (`--pure` での起動、INFO より上の log level、log の rotate、`server()` の throw、log の失敗) |
  | build_id 不一致 | いちばん新しい行の build_id が配置中の marker と違う (配置の後にまだ起動していない、旧い版を読み込んだままの process の行) |
  | 読めない行 | build_id が `unknown`、行が契約の形でない (接頭辞の版が違うものを含む) |

  限界 (honest-label): 行は「この build で `server()` が return まで到達した起動が過去にあった」ことの証拠で、
  直近の起動が成功した証拠ではない。同じ build の過去の行が残っていれば、その後の起動が init に失敗しても
  「確認できた」になる。doctor は判定と build_id だけを報告し、log の行の全文や過去の log を出さない。
  OpenCode を起動して確かめることもしない。

## Codex の review / worker 用 profile file (#339)

- **中身は dotfiles**: `personal-codex-review` と `personal-codex-worker` の model / reasoning effort は、
  Codex home (`$CODEX_HOME`、空なら `~/.codex`) の `agent-tools-review.config.toml` と
  `agent-tools-worker.config.toml` で軽くできる。どの値にするかは machine ごとの設定なので dotfiles が
  持ち (`~/.codex/hooks.json` と同じく、Codex が書き換えない別 file として chezmoi で配る)、agent-tools は
  作らず、書き換えず、sync の対象にもしない。手で置いてもよい。
- **agent-tools は top-level の model / effort だけを読む**: review も worker も、`--ignore-user-config` の起動
  (user config の MCP / connector を外す) に合わせて、`config.toml` の top-level を base に profile file の top-level の
  `model` / `model_reasoning_effort` を優先して読み、`-c` で再指定する (#358。review は worker の preflight と同じ
  library で読む)。profile の他の key (例: `service_tier`) は読まれない。file が無ければ `config.toml` の top-level の
  値 (それも無ければ Codex の既定) なので、置かない machine (例: 会社機) があってよい。
- **file 名は公開契約**: 2 つの file 名は dotfiles が配る先の名前なので、agent-tools は名前の変更を
  breaking change として扱う (dotfiles 側の更新と同期するまで旧名を壊さない)。置き方と Fast mode の
  消費は [Install & Usage](install-and-usage.md) の「Codex の review / worker だけを軽くする」。

## 残量の読み取り口の設定 (#385)

使用量の枠の残量を読む「読み取り口」は、agent-tools が配る固定の wrapper `personal-usage-reader` (script asset。
配備先は `<tool home>/agent-tools/scripts/personal-usage-reader`) と、その設定 file に分ける。operating-loop の割当・
maintenance-sweep の BUDGET・grill の CONSULT は wrapper だけを引数なしで呼び、repo root の `.agent-context.local.md`
に書かれた command は実行しない (note は data-only。[instruction artifact kind](instruction-artifact-kind.md))。

- **中身は dotfiles**: どの実行ファイルで残量を読むかは machine ごとの設定なので dotfiles が持つ (手で置いてもよい)。
  agent-tools は設定 file を作らず、書き換えず、sync の対象にもしない。置かない machine では読み取り口なしになる。
- **設定 file**: `${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/usage-reader.json` に固定する (XDG_CONFIG_HOME は
  絶対 path のときだけ使い、HOME が絶対 path でなければ場所を決めずに止める。相対 path を cwd の repo から解決しない)。
  wrapper は path を引数で受け取らない。中身は JSON object で、key は次の 2 つだけ。知らない key、型や範囲の外れ、
  argv の要素の制御文字は不正。

  | key | 必須 | 値 |
  | --- | --- | --- |
  | `argv` | yes | 空でない文字列の配列。`argv[0]` は絶対 path で、在り、regular file (symlink は辿った先で判定) で、実行できること |
  | `timeout_sec` | no | 1〜120 の整数。既定は 20 |

- **起動**: shell を通さずに `argv` をそのまま起動する (要素に shell の metacharacter があっても literal のまま渡る)。
  stdin は `/dev/null`、cwd は `/`、子の stderr は捨てる。子は自分の process group で起動し、`timeout_sec` を過ぎるか
  (stdout を閉じた後の終了待ちを含む)、stdout が 1 MiB を超えたら group ごと止める。wrapper が signal (SIGINT /
  SIGTERM など) で中断されたときも group を止めて回収してから終わる (SIGKILL で wrapper を止めたときは後始末できない)。
- **exit code**:

  | exit | 意味 | stdout |
  | --- | --- | --- |
  | 0 | 子が exit 0 で、stdout が空でない | 子の stdout をそのまま |
  | 3 | 設定 file が無い (読み取り口なし) | 空 |
  | 2 | usage、設定の場所を決められない、設定が不正、設定 file が在るのに regular file でないか読めない、起動できない、子が 0 以外で終わった、timeout、出力が空か上限超え、wrapper が signal で中断された。理由を stderr に 1 行 (設定の中身と path は出さない) | 空 |

  呼ぶ側は exit 0 の stdout だけを使い、3 は読み取り口なし、2 とそれ以外の 0 以外 (script が配備されていない等) は
  読めないとして扱う。
- **設定の検証だけ (`--check`、#400)**: 設定の場所の決め方と検査 (`argv[0]` の在否・regular file・実行できること
  を含む) を通常の起動と同じコードで行い、`argv` を起動しない。**副作用なし** (file を書かない、子 process を起動
  しない、network を使わない) なので、dotfiles の doctor が副作用なしのまま呼べる。exit は通常の起動と同じ値と理由で、
  0 = 設定が契約どおり / 3 = 設定 file が無い (指す先の無い symlink を含む) / 2 = 不正 (理由を stderr に 1 行、設定の
  中身と path は出さない)。stdout は常に空。検査の規則を写さずに、この mode を呼んで確かめる。
- **`--check` への対応の判別**: `--help` の 1 行目 (usage 行) が `usage: personal-usage-reader [--help] [--check]`
  のように `[--check]` を含むことで分かる (この行も公開契約)。`--check` を知らない旧い wrapper は、`--check` を
  usage error の exit 2 にするので「設定が不正」と区別できない。呼ぶ側は先に `--help` を呼び (副作用なし)、exit 0 で
  1 行目に `[--check]` があるときだけ `--check` を使い、無ければ「wrapper が旧く `--check` に未対応」と扱う。
- **file 名と key は公開契約**: dotfiles が配る先の名前と形なので、agent-tools は変更を breaking change として扱う
  (dotfiles 側の更新と同期するまで旧い形を壊さない)。`--check` の exit と、`--help` の 1 行目の `[--check]` も同じ。

## どちらの repository も持たないもの

- tokens。
- API keys。
- credentials。
- private endpoints。
- client data。
- work data。
- runtime session state。

これらは secret store または local private config に置くものです。
この repository の scope には含めません。

## 連携 rule

`dotfiles` は `agent-tools` を自動 clone / pull / build / sync しません。

`dotfiles` がこの repository の存在を知る必要がある場合でも、許可するのは expected path に
`agent-tools` が存在するかを知らせる report-only checks までです。

`dotfiles` が report-only で読める status の形式は
[Status / Manifest Contract](status-manifest-contract.md) で定義します。

## expected path(配置先の正本)

`agent-tools` の配置先(clone 先)の正本はここで定義します。`dotfiles` 側はこれを
**参照するだけ**で、独自に別パスを正としません。

- **既定の expected path**: `~/src/agent/agent-tools`
- **根拠**: `dotfiles` の directory convention(`~/src/agent/<repo>`)と、`dotfiles` doctor の
  既定期待パス(`AGENT_TOOLS` env が未設定のときに見る場所)に一致させるため。
- **override**: 別の場所に置く場合は `AGENT_TOOLS` env で実際のパスを指定する。`dotfiles` の
  report-only check / doctor はこの env を尊重する。

`agent-tools` 自体はどのパスに clone しても動作します(script は自分の位置からの相対で動く)。
この expected path は「`dotfiles` 連携(presence / health の report-only check)を成立させる
ための合意パス」であり、配置の強制ではありません。
