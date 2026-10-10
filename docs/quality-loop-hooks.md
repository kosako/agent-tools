# Quality Loop Hooks(fast-edit-check / changed-scope-qa)

編集直後の機械フィードバックと turn 終了時の QA gate を担う 2 つの lifecycle hook body の
契約 (#200 §4.4-4.5 / #203)。skill (production-rail の self-check) が「発火すれば」やる
品質確認のうち、機械判定できる部分を決定的実行に出したもの。品質の意味判断 (要求一致・
最小差分・何が十分な検証か) は従来どおり skill / モデルの領分に残る。

## 強度ラベル(偽らない)

- **fast-edit-check は steering / fail-open**。block しない・自動 fix しない。hook 内部の
  想定外はすべて exit 0 で透過し、編集操作を壊さない。
- **changed-scope-qa は best-effort gate**。hook 無効化・別経路で迂回できる。block は
  「新しい変更 scope に対して 1 回だけ」で、無限ループ対策 (下記) を仕様に含む。
- どちらも登録 (+ Codex は trust) が済むまで不活性 (fail-open の帰結)。
  未 trust 時の警告など時点付き仕様は [runtime 正本](runtime-injection-defense.md) を参照。
  配線は dotfiles 所有 (boundary-with-dotfiles)。例外は OpenCode で、agent-tools が配る plugin が
  両 script を呼ぶので、plugin の配置がそのまま配線になる (下の「OpenCode」節)。
- **OpenCode では changed-scope-qa は gate ではなく人向けの通知 (report-only)**。block も継続も
  しない。

## check コマンドの発見(自動推測しない・#203 裁定)

宣言の正本は**ユーザー所有の untracked 中央設定**:

```text
~/.config/agent-tools/checks.local.json   (JSON・ユーザーが手で管理)
```

```json
{
  "/Users/<you>/src/some-repo": {
    "edit_checks": [
      {"name": "ruby-syntax", "pattern": "\\.rb$", "command": ["ruby", "-c"]}
    ],
    "qa_checks": [
      {"name": "manifests", "command": ["scripts/check-manifests.sh", "--quiet"]}
    ]
  }
}
```

- キーは repo root の**実 path** (`File.realpath`)。宣言がある repo でだけ動き、無い repo
  では両 hook とも**無言 no-op** (opt-in 設計)。
- **repo 内の宣言ファイルは読まない**: clone した第三者 repo が「編集・終了のたびに実行
  される任意コマンド」を宣言できてしまうため。宣言の所有をユーザーに固定するのが
  この配置の主目的 (中央 local 設定は `.agent-context.local.md` と同じユーザー正本
  パターン)。
- JSON なのは standalone 配布 script に psych 3/4 分岐 (yaml_util の領分) を持ち込まない
  ため。
- `edit_checks.command` には対象ファイルの絶対 path が 1 引数として追記される。
  `qa_checks.command` は引数追記なし。どちらも **cwd = repo root** で実行される。
- 宣言する check の目安: edit_checks は「1 ファイル・数百 ms」(編集のたびに同期実行)、
  qa_checks は「repo 全体で数秒・決定的」(Stop のたびに走りうる。決定性は cache の前提)。
- check ごとに memory と時間の上限 (`max_footprint_mb` / `max_seconds`) を宣言できる (下の「check の起動」)。

## check の起動 (personal-safe-run 経由、#467)

両 hook は宣言された check を直接起動せず、配備先の同じ dir (`<tool home>/agent-tools/scripts/`) の
`personal-safe-run` ([safe-run](safe-run.md)) の子として、新しい process group と memory (phys_footprint の合計) と
時間の上限を付けて起動する。check の test runner が子 process ごと暴走しても、hook から孤児と memory の枯渇が
生まれないようにする (#466 の背景の事故)。

- **safe-run が無い・実行できない**ときは、check を走らせない (上限なしでは走らせない)。その check は起動の失敗
  (missing) として警告する。safe-run は PATH からは探さない。
- **上限**: check ごとに `max_footprint_mb` (MiB) と `max_seconds` (秒) を宣言できる。無ければ既定 (memory 4096
  MiB、時間は qa_checks 300 秒 / edit_checks 30 秒)。safe-run の範囲 (1〜1048576 / 1〜86400) の整数でなければ
  (bool・小数・文字列を含む) 不正な check 宣言として扱う (「不正な check 宣言を無視しました」の経路)。

  ```json
  {"name": "suite", "command": ["scripts/tests/run.sh"], "max_footprint_mb": 2048, "max_seconds": 120}
  ```

- **総予算**: hook 1 回の時間の総予算は changed-scope-qa 540 秒、fast-edit-check 120 秒 (Claude Code / Codex の
  hook の timeout の既定 600 秒より短い)。check の `--max-seconds` は min(上限, 残りの予算の切り捨て) で、残りが
  1 秒未満なら起動しない。総予算で短くした期限で止まった check は failure ではなく**予算切れ** (missing。
  changed-scope-qa は cache で確定させず次の Stop で再試行、fast-edit-check は「実行できません」として要約に出す)。
- **出力**: stdout と stderr をまとめて読み、先頭 64 KiB だけ保持して残りは読み捨てる (check を pipe の詰まりで
  止めない。要約の 2000 文字の打ち切りは別)。safe-run の終了は pipe の EOF と分けて観測し、終わったら pipe を最大
  0.5 秒だけ読んでから閉じる (group を抜けた子が書き込み側を持ち続けても待たない)。
- **safe-run の期限**: safe-run が `max_seconds` + 20 秒を過ぎても終わらなければ TERM (safe-run は check の group を
  止めてから終わる) → 10 秒 → KILL で止め、その check を missing にする。
- **結果の分類** (safe-run の report を検証してから、上から順に排他的に。safe-run の exit code は使わない。137 は
  command 自身の SIGKILL と区別できないため):

  | 条件 | 扱い |
  | --- | --- |
  | report が無い・読めない・不正 (version、必須 field の存在 (null を取りうる field も) と型、既知の reason、exit code と signal のちょうど一方) | missing |
  | `command_started: false` (check を起動できない: 不在・権限・不正形式・ENOTDIR など) | missing |
  | `reason: "interrupted"` | hook が中断中なら下の「中断」。そうでなければ missing |
  | `reason: "time"` で、総予算で `--max-seconds` を短くしていた | missing (予算切れ) |
  | `reason: "time"` / `"footprint"` / `"monitor"` | failure (「safe-run が止めました (時間の上限 N 秒 / memory の上限 N MiB / memory を監視できません)」) |
  | `reason: null` で `command_exit` が 0 | pass |
  | `reason: null` で `command_exit` が 0 以外 | failure (`exit N`。2 / 126 / 127 も command の exit) |
  | `reason: null` で `command_signal` | failure (`terminated by SIGxxx`。#373) |

  `cleanup_complete: false` (safe-run が check の group を止め切れなかった) は、上の扱いに加えて警告を出す。
  changed-scope-qa はその check を pass として cache せず、次の Stop で再実行する (警告が cache-hit で消えない
  ように)。
- **hook 自身の中断**: hook は INT / TERM / HUP を受けたら flag を立て、動いている safe-run に TERM を送り (safe-run
  が check の group を止める)、後続の check を起動しない。safe-run を上の期限の規則で回収し、一時 dir を消し、
  **state も出力も残さずに** exit 0 で終わる (次の Stop で同じ scope を検査し直す)。changed-scope-qa は state を
  一時 file に書いて rename で置き、書いている途中で中断されても今回の state を置かない (rename の前) か書く前の
  state に戻す (rename の後)。出力 (警告・block) の直前にも中断を確かめる。
- **限界**: hook の pid だけが SIGKILL されたときは、safe-run が自分の上限で check を止める。hook の group ごと
  SIGKILL されると safe-run も死に、safe-run が別 group で起動した check の group が残る。Claude Code / Codex の
  hook の timeout が送る signal と宛先 (pid か group か) は公式 docs に書かれておらず未確認なので、内側の総予算を
  外側の既定 600 秒より短く保つ。
- **配備の順序**: OpenCode の plugin は timeout で hook の group を止める。group への SIGKILL だけで止める旧い plugin
  のままこの変更を配ると、safe-run ごと殺されて check の group が残る。plugin の止め方を TERM → 猶予 → KILL に
  変えた版 (#467 の PR B) を先に配備し、**稼働中の OpenCode を起動し直して新しい plugin を読み込ませてから**、
  この変更 (hook が safe-run を使う) を配備する。

## personal-fast-edit-check(PostToolUse / `Edit|Write|apply_patch`)

- Claude Code は `tool_input.file_path`、Codex は `tool_name: "apply_patch"` の
  `tool_input.command` から対象を取る。Codex の成功判定は `PostToolUse` event に加え、
  `tool_response` 文字列の先頭が `Exit code: 0` の行であることを確認する。
- Codex の通常 patch (`*** Begin Patch` / `*** End Patch`) 全体を検査し、Add / Update の
  対象、Move の移動先を `cwd` 基準の絶対 path にする。1 patch 内の重複は除き、Delete と
  現存しないファイルは高速 check の対象外にする。各ファイルの repo の `edit_checks` の
  うち `pattern` (Ruby regex) が一致するものだけを実行する。
  1 patch の対象ファイルごとに check を直列・同期実行するため、全体の待ち時間は
  「対象ファイル数 × 一致する check の所要時間」に応じて増える。出力上限に達しても
  後続の check は省略しない。
- 失敗した tool result、`cwd` 不在、壊れた / 未対応 patch は無言 skip。
  shell wrapper や `*** Environment ID` による別環境指定を local path と推測しない。
- 失敗時のみ `hookSpecificOutput.additionalContext` で失敗要約 (上限 2000 文字 /
  非 UTF-8 は scrub) をモデルに返す。成功は無言 (ノイズ規律)。
  失敗の対象は常に repo 相対 path で識別し (1 ファイルの編集でも basename にしない。OpenCode
  plugin は file ごとの要約の同文を除くため、同名ファイルの失敗を区別する。payload の path が
  symlink 越しでも git が返す repo root 基準で相対にする)、不正な check 宣言の警告は
  同じ repo について 1 回だけ返す。
  失敗した check は `[名前] 理由` (`exit N` / `terminated by SIGxxx` / safe-run が止めた理由 / 実行できなかった
  理由) の後に出力を続ける (#467)。
- 設定ファイルが壊れているときは無言で握り潰さず、設定エラーを additionalContext で
  1 行知らせる (それでも exit 0)。
- **互換性の根拠**: [Codex Hooks](https://learn.chatgpt.com/docs/hooks#posttooluse)、
  Codex 0.153.4 の [patch parser](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/apply-patch/src/parser.rs)、
  [hook response](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/src/tools/context.rs)、
  [出力形式](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/src/tools/mod.rs) に基づく。
  Claude Code の payload は #201 実測済み。Codex の複数 file / Add / Update / Delete /
  Move / 不正 payload は stdin fixture で check 実行と additionalContext を検証する。
- **Codex native smoke (2026-09-06 / #239)**: Codex 0.153.4 (公式同版 Code Mode host) /
  `gpt-6-astra` で、1 ファイルへの実 `apply_patch` 2 回を観測した。最初の更新による
  Ruby 構文エラーで check が 1 回失敗し、その場で生成した識別子を含む additionalContext が
  モデルへ届いた。モデルが同じ識別子を返してファイルを修復し、次の check は 1 回成功して
  無出力だった。実 hook payload・check receipt・session trace を照合し、他の tool 呼出しや
  check / 観測 log の直接参照が無いことを確認した。
  一時 project / hook の信頼設定は撤回し、別 process の readback で当該 permission の不在と
  他設定・hooks の不変を確認した。実測はこの 1 ファイルの Update / repair に限る。
  複数 file・Add / Delete / Move の native 実測や、全配備環境・モデル性能の検証ではない。

## personal-changed-scope-qa(Stop)

- **検査対象の帰属 (#203 裁定)**: agent の変更とユーザーの手元変更を区別せず、working
  tree の **dirty scope 全体** (tracked の変更 + untracked) を対象にする。ユーザー自身の
  書きかけ変更も検査対象になる (明記)。
- dirty かつ宣言 repo なら `qa_checks` を実行。全 pass → scope 指紋 (HEAD / status / tracked diff /
  untracked 内容 / check 定義を含む sha256) と結果を state に cache して無言 pass。初回 commit 前 (HEAD が
  無い) は tracked diff の代わりに stage 済みと未 stage の diff を使う。指紋の材料の git が失敗したら判定
  不能として gate しない (check を走らせず cache もしない、#373)。
  失敗 → **exit 2 + stderr 要約で block**
  (モデルに修正の続行を促す)。
- **無限ループ対策 (仕様)**:
  - `stop_hook_active: true` (この turn で既に継続済み) では**絶対に block しない**
    (新しい scope なら check は走らせ、失敗は `systemMessage` のユーザー向け警告で返す)。
  - 同一 scope 指紋の再 Stop は check を**再実行しない** (pass 済み = 無言 / fail 済み =
    ユーザー向け警告のみ。block は新しい scope に 1 回だけ → 直せない失敗は人間に戻る)。
  - 実行できなかった check (missing: check コマンドの不在・権限・不正な実行形式のほか、path の途中が
    file や symlink の loop など起動の失敗全般 (#430)、safe-run を使えない・report が不正・予算切れ・safe-run が
    期限までに終わらない (#467)) はユーザー向け警告 (名前と理由) に降格して block しない。
    同じ repo の他の check は通常どおり走り、その結果 (失敗なら block) も出す。
    起動した check が signal で終わったのは spawn 失敗ではなく実 failure として扱い、block の要約に
    signal 名を出す (#373。hook の timeout や中断では hook 自身も止まって state を書かないので、ここで
    観測するのは check だけが crash や外からの kill で落ちたとき)。未実行の
    check は cache 内で `missing` として分離し、同一 scope でも次の Stop で再試行する。
    復旧して全 check が pass になれば無言になる。
- 警告は **exit 0 + `{"systemMessage":"..."}`** のみを出力する (本文は 2000 文字で打ち切り /
  非 UTF-8 は scrub)。構成エラーの警告も同じ経路を使う。モデルへの追加指示や継続要求は
  出さず、他の Stop hook の判断も上書きしない。
- 出力契約の一次情報 (2026-09-05 確認):
  [Claude Code](https://code.claude.com/docs/en/hooks#json-output) と
  [Codex](https://developers.openai.com/codex/hooks#common-output-fields) は `systemMessage` を
  ユーザー向け警告として扱う。Claude Code の
  [Stop `additionalContext`](https://code.claude.com/docs/en/hooks#stop-decision-control) は
  会話を継続させるため、この hook の警告経路には使わない。配線は同期 command hook を前提とする。
- state: `~/.cache/agent-tools/changed-scope-qa/<repo path の sha256>.json`。
  override: `AGENT_TOOLS_QA_STATE_DIR` (test と、OpenCode の plugin が使う。plugin が渡す値は下の
  「OpenCode」節の契約) / 設定は `AGENT_TOOLS_CHECKS_CONFIG`。
- Codex 側は Stop の matcher が無視される (#201)。`stop_hook_active` と exit 2 による
  継続要求は[公式 Stop 契約](https://developers.openai.com/codex/hooks#stop)にも記載されている。
  実機 smoke の確認範囲は下記。配備先ごとの登録・trust は別途必要。

## OpenCode (plugin 経由、#295)

OpenCode には PostToolUse / Stop に相当する hook 登録が無いので、agent-tools が `plugin` kind で配る
`~/.config/opencode/plugins/personal-agent-tools.js` が両 script を無改変で呼ぶ (safe-gh の注記と同じ
plugin。配布と fail-open の形は [runtime 正本](runtime-injection-defense.md)「OpenCode parity」)。
script は Claude Code target に配った `~/.claude/agent-tools/scripts/personal-*` を解決し、無ければ
何もしない。実測の根拠は [opencode-plugin-probe](opencode-plugin-probe.md) の M3 / M7 / M9 / M10 /
M13 / M14 / M17 (OpenCode 1.18.30)。

- **fast-edit-check** (`tool.execute.after`): 成功した `edit` / `write` / `apply_patch` の後に呼ぶ
  (失敗した編集では after が呼ばれない: M14)。対象の file は、edit / write が `args.filePath`
  (plugin の directory を基準に絶対 path にする)、apply_patch が after の `metadata.files` のうち
  delete 以外 (move は移動先の `movePath`) で、絶対 path のものだけ。metadata が無ければ patch の
  本文は parse しない。file ごとに `{"hook_event_name":"PostToolUse","tool_name":"Edit"|"Write",
  "tool_input":{"file_path":…}}` で直列に呼ぶ (apply_patch の file は `Edit` として渡す。Codex 形の
  `apply_patch` payload は渡さない)。失敗要約は tool 結果の**末尾**に `\n\n` で足す (safe-gh の注記は
  先頭。編集系の結果は短いので切り詰めで落ちにくく、元の結果を先に読ませる)。同じ文言は 1 回だけ。
- **総予算**: 1 回の after で 30 秒 (file ごとではない。Codex では 1 patch に起動も timeout も 1 回
  なのに合わせる)。使い切ったら残りの file は check せず、warn を出す。1 file の script の失敗は
  warn して次の file に進む。
- **changed-scope-qa** (`event` の `session.idle`): report-only。`{"hook_event_name":"Stop",
  "stop_hook_active":false}` を渡し、cwd は plugin の directory。exit 2 なら stderr を level `error`、
  exit 0 の `systemMessage` を level `warn` で `client.app.log` にだけ出す (service は
  `personal-agent-tools`)。log は OpenCode の log file (`~/.local/share/opencode/log/opencode.log`。
  `opencode serve --print-logs` では stderr にも出る) に level `ERROR` / `WARN` の行として出る。1.18.30 の
  行には service 名が出ないので、`changed-scope-qa:` で始まる message で探す (2026-09-30 の実機 smoke)。
  - task の子 session の idle も同じ directory に届く (M9) ので、`client.session.get` の `parentID`
    で除外する。親子を判定できない (lookup の失敗・data が無い) ときは起動せず warn を出す。
  - 実行中に来た idle は skip する (instance ごとに直列。親子の判定を待つ間も実行中に含めるので、判定の後で
    前の実行が終わっていても、後から起動しない)。
  - toast は使わない: 1.18.30 の TUI は `showToast` が成功を返しても描かない (M17)。
- **Stop の制約**: Stop のように、hook の戻り値で終了を止めて続けさせる仕組みは OpenCode に無い
  (`session.idle` は事後に届く fire-and-forget の event)。SDK で prompt を送れば続けさせられるが、
  採らない (#295 の決定)。plugin は `session.prompt` / `promptAsync` / `tui.appendPrompt` /
  `tui.submitPrompt` を呼ばない。継続させないので、上の無限ループ対策は該当しない。
- **exit 2 の文は人が読む**: script の文面は model 向け (「終了する前に修正してください」) だが、
  OpenCode では model には届かず、log を見た人が読む。
- **state dir を分ける (契約)**: plugin は子 process に
  `AGENT_TOOLS_QA_STATE_DIR=~/.cache/agent-tools/changed-scope-qa-opencode` を渡す (agent-tools の
  名前空間に置き、OpenCode の config / data / cache の dir には置かない)。理由: script は
  `stop_hook_active` にかかわらず fail を state に書き、「scope ごとに 1 回だけの block」を消費する。
  共有すると、model に届かない OpenCode の実行が Claude / Codex の block を先に使ってしまう。代償と
  して、同じ scope の check を agent ごとに 1 回ずつ実行する。
- **子 process の env は絞る**: plugin が渡すのは `PATH` / `HOME` / `LANG` / `LC_ALL` / `LC_CTYPE` /
  `AGENT_TOOLS_CHECKS_CONFIG` (と changed-scope-qa の state dir) だけ。宣言した check もこの env で
  動く (env をそのまま継承する Claude Code / Codex の hook との差。check が他の env に依存するなら
  OpenCode では動かないことがある)。
- **強度と honest-label**:
  - fast-edit-check の要約は model への steering で、人の目に入ることは期待しない。M4 / M17 で
    確かめたのは bash の結果の先頭の書き換え (model に届き、TUI には描き直されない)。編集系の結果の
    末尾への追記が model に届くことは、2026-09-30 の実機 smoke で確かめた (model が返答で、追記にしか
    無い check 名と失敗の中身に触れた)。
  - changed-scope-qa の結果は log にだけ出て、TUI には通知されないので、**OpenCode では変更範囲の
    検査の結果に人が気づけない**。後ろに git hook / CI / 相互レビューがある前提で割り切る (#295 の判断。OpenCode を
    主に使うようになったら通知の経路を見直す)。
  - `opencode run` では idle の後の非同期の処理が打ち切られうる (M10) ので、run では changed-scope-qa
    の結果が残らないことがある (TUI と serve では残る)。
  - fail-open: script が無い / 実行できない / 非 0 (changed-scope-qa の exit 2 を除く) / stdout が
    JSON でない / timeout (fast-edit-check は総予算、changed-scope-qa は 120 秒) のどれでも、tool 結果を
    変えず・何も報告せず、warn を script ごとに 1 回だけ log に出す。
  - timeout の止め方 (#467): script の process group に TERM を送り、group が空になるまで最大 10 秒待って
    (100 ms ごとに確かめる)、members が残っていれば KILL を送り、空になるのを最大 1 秒確かめる。script が
    TERM で終わっても、TERM を無視する子が stdio を閉じて残りうるので、終わりは script の終了ではなく group
    が空かどうかで決める。10 秒は、hook script の子 (#467 で hook が check の起動に使う safe-run) が check を
    止めて回収し終えられるように、safe-run の後始末の最悪 (約 8 秒) より長くした値。猶予と確認の時間は単調
    時計 (`performance.now`) で計る (system の時計の補正で猶予が縮んで後始末中の子を KILL したり、延びたり
    しない)。
    - timeout のときだけ、呼び出しは後始末が済むまで (最大で猶予の 10 秒 + 確認の 1 秒ぶん) 遅れて返る
      (safe-gh は 10 秒 + 最大 11 秒、fast-edit-check は総予算 + 最大 11 秒、changed-scope-qa は 120 秒 +
      最大 11 秒)。changed-scope-qa は後始末の間も実行中に含める (その間に来た idle は skip し、直列を保つ)。
    - 停止を確認できないとき: KILL の後も group に members が残る (TERM / KILL を送れない member が居る
      EPERM を含む) ときと、kill が想定外の理由で失敗したとき (後始末をやめる) は、timeout の warn に
      `; its process group may not have stopped (<理由>)` を足す。理由は送れなかった signal (`SIGKILL EPERM`
      など) と `members remained after SIGKILL`、または失敗した signal と code (`SIGTERM EINVAL` など)。TERM を
      送れなくても、KILL の後に group が空と確かめられれば通常の warn のまま (停止は確認できている)。
    - 限界: script (group の leader) は plugin の process が回収するので、pgid は members が居る間だけ有効。KILL は
      members が居ると確かめた直後に送るが、その間に group が空になって同じ番号が別の process group に
      再利用される窓は残る (番号の再利用には pid の一巡が要るので実害は小さい)。猶予の途中で OpenCode
      自身が終わると KILL は送られない。
  - 一時的に外すには `opencode --pure` で起動する。

## 検証境界

- 純粋ロジックと git 連携・cache・ループ対策は `scripts/tests/quality-loop-hooks-test.sh`
  が CI で検証する (設定 / state / HOME / git config を隔離・fake check 使用)。
- safe-run 経由の起動 (#467) は `scripts/tests/quality-loop-safe-run-test.sh` が検証する。report の分類・不正な
  report・予算 (`--max-seconds` の値)・cache・上限の上書き・safe-run の期限・出力の保持量は fake の safe-run と
  注入した時計で決定的に、memory と時間の上限で止まって group が空になること・safe-run が無い / 実行できない・
  pipe を持ち続ける子・hook への TERM は実物の safe-run で確かめる。
- OpenCode の plugin からの呼び出しは `scripts/tests/opencode-plugin-test.sh` (node) が CI で検証する。
  build した plugin を入口 (`server(ctx)` が返す hooks) 経由で動かし、実物の script を tmp の home に
  置いて、tmp の git repo と記録つきの fake check で確かめる (追記の位置、apply_patch の file の取り方、
  総予算、payload の形、state dir、子 session の除外と直列化、model を続けさせる API と toast を呼ばない
  こと、fail-open、timeout の止め方 (TERM → 猶予 → KILL と、後始末の間の直列))。OpenCode の実機での確認は CI 外の smoke (人 + Claude) で行う。2026-09-30 に
  OpenCode 1.18.30 (`opencode-go/kimi-k3`、`opencode serve` + `opencode run --attach`) で次を確かめた:
  構文エラーを入れた `edit` の結果の末尾に要約が載り model に届く / 直した `edit` には載らない /
  壊れた scope の `session.idle` で changed-scope-qa の `ERROR` が log に出て、直した後は何も出ない。根拠は
  項目ごとに分ける: 追記の有無と位置は DB に保存された tool の part、model に届いたことは返答 (追記にしか
  無い check 名と失敗の中身に触れた)、changed-scope-qa の報告は log (serve の stderr と log file)、直した後の
  結果は QA の state (`pass`)。`apply_patch` の経路 (gpt 系の model) は実機では確かめておらず、node の test
  だけで確かめている。TUI での表示は今回の smoke では確かめていない (node の test が確かめるのは、TUI の
  API を呼ばないことだけ)。
- Stop の回帰テストは warning JSON に `systemMessage` だけがあり、継続を要求する
  field がないことを検証する。fixture 検証は実 runner の継続回数や UI 表示の観測ではない。
- 実配線 (settings.json / hooks.json への登録・Codex payload / Stop の実測) は CI 外
  (dotfiles 側 issue + 実機 smoke。実施記録は #203 / #237 / #239)。

### Stop の実機確認 (2026-09-06 / #237)

Claude Code 2.1.259 (`claude-opus-5`) と Codex 0.153.4 (`gpt-6-astra`) で、
同じ候補 source と一時 Git fixture・専用 checks/state を使い、native runner が呼んだ
Stop と実際の応答を照合した。モデルからの tool 呼び出しはなく、synthetic stdin の
テストとは別に確認している。

| case | 両 host の Stop exit / active | 最終 text 応答数 | check 実行数 (Codex) |
|---|---|---|---|
| command 不在 | `0 / false` | 1 | 0 |
| 初回 failure → 同一 scope の再 Stop | `2 → 0 / false → true` | 2 | 1 |
| successful check | `0 / false` | 1 | 1 |

Claude は warning と再 Stop の後に `system/informational` の notice が各 1 回届き、
成功時は QA notice なしで終了した。Codex は上表を `exec --json` で確認したが、
`systemMessage` は JSON 出力にも通常の `exec` 出力にも現れなかった。別の TUI 実行で
command 不在と既存の失敗 scope cache による警告が `Hook` 通知として表示され、
各 1 応答・再 block なしで終了したことを確認した。Codex の `exec` による警告表示は
確認済みの機能とは扱わない。Claude の対話 UI 描画も検査範囲外。

Codex の検証環境には既存 plugin の timeout 調整と optional Code Mode host 不在の
起動診断があったため、strict な JSON verifier の初回判定は inconclusive だった。
hook receipt と対応 session の実 trace を照合して上表を確認し、元の evidence は保持した。
検証用に追加した Codex project / 単独 hook の信頼設定は公式 API で撤回し、別 process で
他の設定・hooks の不変を確認した。通常の配線や設定を更新した検証ではない。

成功時 cache、変更 scope、command 復旧時の再試行は regression / synthetic test の
確認範囲であり、上表の実機観測へ広げて主張しない。
