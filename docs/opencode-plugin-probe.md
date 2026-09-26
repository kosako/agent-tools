# OpenCode plugin probe (#295 PR 0)

OpenCode 対応 Phase 2 (#295) の PR 1〜3 は、OpenCode の plugin の挙動を前提にしている (出力を
書き換えた注記が model に届くか、bash の env に目印を立てられるか、hook が throw したら何が起きるか
など)。前提の多くは upstream の source と型定義から予測したものなので、**実装に入る前に実機で
確かめる**ための harness がこの probe である。測る項目を M1〜M20 とし、結果を PR 1〜3 の入力にする。

| 部品 | path | 役割 | CI |
| --- | --- | --- | --- |
| runner | `scripts/probe-opencode-plugin.sh` (`scripts/lib/probe_opencode_plugin.rb`) | 隔離した tmp で `opencode` を stage ごとに起動し、raw の記録と summary を `--out` に書く | 実行しない (opencode CLI と network が要る) |
| 計測用 plugin | `scripts/lib/probe_opencode/probe-plugin.js` | v1 形 (`export default { id, server }`)。hook ごとの allowlist で記録する | T7 で allowlist を検証 |
| mock provider | `scripts/lib/probe_opencode/mock_openai.rb` | 127.0.0.1 の OpenAI 互換 SSE。prompt の `PROBE-SCENARIO:<name>` で tool call の列を返す | T4 で検証 |
| 判定 | `scripts/lib/probe_opencode/judge.rb` | 記録から M1〜M20 の observed と verdict を出す | T5 で検証 |
| self-test | `scripts/tests/probe-opencode-plugin-test.sh` | T1〜T7。opencode も外部の network も使わない (T2 / T6 は偽の `opencode` で runner を通す) | 実行する (Ruby matrix の 2 行) |

## 使い方

実機の実行は人が `!` で stage ごとに起動する (Bash tool から入れ子で agent を起動しない)。`--out` は
git の worktree の外の、無いか空の dir に限る。

```text
scripts/probe-opencode-plugin.sh --stage all --out <dir>                  # isolation + mock + serve
scripts/probe-opencode-plugin.sh --stage all --shell user --out <dir>     # bash tool の shell を $SHELL の binary に
scripts/probe-opencode-plugin.sh --stage real --real --model <provider/model> --pass-env <NAME> --out <dir>
scripts/probe-opencode-plugin.sh --stage tui-plan --out <dir> --timeout 1800   # 別の terminal で。Ctrl-C で終わる
```

| stage | 起動するもの | 主に測る項目 |
| --- | --- | --- |
| isolation | `opencode debug paths` / `debug config` / `models` | M1 |
| mock | `opencode run --format json` を 15 run (scenario と plugin の mode を変える) | M1〜M15、M18、M19 |
| serve | `opencode serve` を 4 回起動し、API で `!` (`session.shell`)・PTY・prompt・abort を叩く | M5、M6、M8〜M11 |
| real | `opencode run` を実 provider で 1 run | M16 |
| tui-plan | 隔離環境の TUI の起動 script と手動 checklist を出し、mock を動かしたまま待つ | M17、M20 |

出力: raw の記録 (`hooks.jsonl` / `mock-requests.jsonl` / `run-events.jsonl` / `git-hooks.jsonl` /
`stderr/` / `facts.json`) と判定 (`summary.json` / `summary.md`)。**docs に写すのは summary だけ**で、
raw は写さない。summary では `$HOME` を `~`、隔離 dir を `<tmp>` に置き換える。verdict は次の 4 つで、
data が欠けた項目は unknown にして pass に数えない。

- confirmed: source からの予測と一致した
- differs: 予測と食い違った
- unknown: data が無い (理由を付ける)
- observed: source からの予測が無い項目で、観測した値だけを載せる

## 測る項目と使う先

| M | 測ること | 使う先 |
| --- | --- | --- |
| M1 | 隔離 (debug paths / config が tmp だけを指し、probe の provider だけが見える。mock に実 HOME の path が届かない。実物の config dir と DB の mtime が変わらない。起動時の install と通信) | PR 0 全体の前提 |
| M2 | plugin の読込 (global に 2 つ・project に 1 つ置いた v1 形の init の順と回数、1 行目が marker 形の file が 1 回だけ読まれるか、`--pure` で 0 件か、init で throw したとき) | PR 1 の plugin の形と marker 行 |
| M3 | 編集系 tool の名前と args (claude 系と gpt 系の model 名で比べる。apply_patch の `metadata.files`) | PR 2 の対象 tool と path の取り方 |
| M4 | `tool.execute.after` で書き換えた出力が、次の request の tool message に載るか | Q2 / Q3 の前提 (PR 1 / PR 2) |
| M5 | bash の子 process の env (経路 = model の bash / `!` / PTY × plugin の有無 × shell)。shell.env の input の sessionID / callID | PR 3a の目印と絞り方 |
| M6 | shell.env が throw したとき、bash / `!` / PTY が失敗するか | PR 3a の fail-open |
| M7 | before の throw / after の throw / after が遅いとき、tool の実行・part の status・model に届くもの・所要時間 | PR 1 / PR 2 の fail-open と timeout |
| M8 | event hook が reject したとき、run / serve / TUI の process が落ちるか | PR 2 の fail-open |
| M9 | session.idle が出る時点 (1 turn の回数、`!` / abort / permission の自動拒否の後、task の子 session) | PR 2 の直列化と子 session の除外 |
| M10 | idle の 500ms 後に書く記録が、run では欠けて serve では残るか | PR 2 の docs |
| M11 | 人に見える経路 (showToast の戻り値、app.log の出力先、TUI の表示) | PR 2、PR 1 の docs |
| M12 | plugin から見える model の識別子 (chat.params の providerID / modelID / api.id)、chat.params と shell.env を sessionID で突き合わせられるか | PR 3a の regex と系列表の fixture |
| M13 | after の中から ruby を spawn する時間、detached の子を負の pid で SIGKILL したとき子と孫が残るか | PR 1 / PR 2 の timeout と kill の方法 |
| M14 | after が呼ばれない条件 (edit の失敗、bash の非 0 終了) | PR 2 と docs |
| M15 | `~/.claude` の互換読込 (tmp の HOME に置いた canary の CLAUDE.md と skill が request に載るか、`OPENCODE_DISABLE_CLAUDE_CODE=1` で消えるか) | PR 1 (skill と instruction を配らない根拠) / PR 3b |
| M16 | 実 model の smoke (after で足した nonce が、実 provider の変換を経て model に届くか) | PR 1 の Q2 の実効性 |
| M17 | TUI の手動 checklist (注記の表示、toast、`!` の結果、PTY の目印、event の reject で落ちないか) | PR 2 の toast / PR 3a の目印 |
| M18 | OpenCode 内部の git (snapshot) が hook を踏むか、そのときの env の目印 | PR 3a |
| M19 | mock が受けた system message に `provider/model` の正確な ID があるか | PR 3b (PR 3a の前に判断) |
| M20 | 普段の起動経路 (herdr の pane、Claude の session の中の terminal) から起動した OpenCode の `!` で、CLAUDECODE / CODEX_THREAD_ID / CODEX_SANDBOX が立っているか (有無だけ) | PR 3a の漏れ対策の記録 |

## 隔離の方法と限界 (honest-label)

- HOME を tmp に向け、XDG_{CONFIG,DATA,CACHE,STATE}_HOME・TMPDIR・OPENCODE_DB・ZDOTDIR も tmp にする。
  HOME が実物のままだと、tmp の config dir に AGENTS.md が無いので OpenCode は実物の
  `~/.claude/CLAUDE.md` と `~/.claude/skills` を読んで system message に載せ (M15 で確認)、mock の記録や
  実 provider に届く。git も実物の `~/.gitconfig` の hooksPath を踏む。
- git には GIT_CONFIG_GLOBAL (tmp の gitconfig。identity と M18 用の記録 hook の hooksPath) と
  GIT_CONFIG_NOSYSTEM=1 を渡す。
- 子 process は argv 配列で起動し、`unsetenv_others: true` と allowlist の env だけを渡す。
  CLAUDECODE / CODEX_* / OPENCODE_CONFIG* / GH_TOKEN などは渡らない (T2)。起動時の通信を減らすため
  OPENCODE_DISABLE_AUTOUPDATE=1 と OPENCODE_DISABLE_MODELS_FETCH=1 を立てる (models は同梱の snapshot を使う)。
- **限界**:
  - system の managed config は env では外せない (隔離の外に残る)。
  - mock / serve の stage でも外部通信は起きる。OpenCode は config dir ごとに `@opencode-ai/plugin` を npm
    install する (M1 で install を確認)。通信先は OpenCode の log には出ず、この probe では記録できていない。
  - 実物の config dir と DB の mtime の比較は、同じ時間に人が普段の OpenCode を使っていると崩れる。
  - `--shell user` は user の shell の binary を使うが、rc は tmp の HOME のもの (空) になる。実物の rc を
    通した env は M20 (手動) で見る。
  - TUI / PTY の表示は人が確かめる (M17)。serve の PTY は API で起動した PTY で、TUI の terminal と同じ
    handler を通る。
  - 記録は hook ごとの allowlist で固定し、args の値・tool の出力本文・provider / options /
    model.api.url / headers は書かない (T7)。mock は header と body の本文を記録しない (T4)。

## 結果

OpenCode 1.18.30 (Homebrew)、macOS (arm64)。2026-09-26 に `--stage all` を 2 回 (bash tool の shell =
`/bin/sh` と `$SHELL` の zsh) 実行し、`--stage real` を 1 回実行した。2 回の verdict は同じだったので 1 行に
まとめ、数値が違うものは両方を書く。予測は source からのもので、根拠は #295 の packet の「既知の事実」。

| M | stage | source からの予測 | observed | verdict |
| --- | --- | --- | --- | --- |
| M1 | isolation / mock | debug paths / config が tmp だけを指し、probe の provider だけが見える。mock に実 HOME の path が届かない。実物の config dir と DB の mtime が変わらない | 4 つとも予測どおり。起動時に global と project の config dir の両方へ `@opencode-ai/plugin` が npm install された。通信先の host は OpenCode の log に出ない (記録できない) | confirmed |
| M2 | mock | global の plugins dir → project の順に各 1 回。1 行目が marker 形の file も 1 回。`--pure` で 0 件。init の throw は隔離され、他の plugin は読まれる | 予測どおり。同じ dir の中の順は global-b → global-a で、名前順ではない (source に定めが無いので予測しない)。init の throw は stderr にも error event にも出ず、user には見えない | confirmed |
| M3 | mock | claude 系の名前: edit / write / bash。`gpt-` を含む名前: apply_patch / bash。multiedit と patch は無い | 予測どおり。claude 系の tool は bash / edit / glob / grep / read / skill / task / todowrite / webfetch / write、gpt 系は edit と write の代わりに apply_patch。apply_patch の after の `metadata.files[]` に type (add / update) と filePath がある。args の key は bash = command、write = content / filePath、edit = filePath / newString / oldString | confirmed |
| M4 | mock | after で先頭に足した nonce が、次の request の tool message と run の event の output の先頭に載る | 予測どおり。plugin に渡る callID は provider の tool call の id と同じ値 | confirmed |
| M5 | mock / serve | model の bash / `!` / PTY とも OPENCODE / AGENT / OPENCODE_PID が立ち、OPENCODE_SESSION_ID は立たない。plugin の目印は plugin ありで立ち、`--pure` で立たない。子 process (`sh -c`) に継承される。shell.env の input は、model の bash = sessionID と callID (before と一致)、`!` = sessionID と callID (before とは不一致)、PTY = どちらも無し | 予測どおり (sh / zsh の両方)。隔離しているので、OpenCode の process に他の agent の目印 (CLAUDECODE など) は無い (普段の起動経路は M20) | confirmed |
| M6 | mock / serve | hook に try/catch が無いので、model の bash / `!` / PTY とも失敗する | 3 経路とも失敗し、model の bash は実行もされない | confirmed |
| M7 | mock | before の throw: 実行されず error。after の throw: 実行されるが error。after が遅い: 完了し、待つ (timeout 無し) | 予測どおり。after が throw すると、実行済みでも model に届くのは error で、tool の出力は届かない。after で 3 秒待つと part は 3.0〜3.3 秒 | confirmed |
| M8 | mock / serve | (予測なし。unhandled rejection の handler は TUI の worker にしか無い) | run は stack trace を stderr に出すが、落ちずに最後まで進んで exit 0。serve も落ちない。TUI は M17 | observed |
| M9 | mock / serve | 1 turn に 1 回。`!` / abort / permission の自動拒否の後にも出る。task の子 session の idle も同じ directory に届き、`client.session.get` で parentID が取れる | 予測どおり | confirmed |
| M10 | mock / serve | idle の 500ms 後の記録は run では欠け、serve では残る | 予測どおり | confirmed |
| M11 | mock / serve | (予測なし) | showToast は TUI が attach していない run / serve でも `data: true` を返す (表示された証拠にはならない)。app.log は `<data>/opencode/log/opencode.log` に出る。TUI の表示は M17 | observed |
| M12 | mock | chat.params の providerID = probe、modelID と api.id = claude-probe。chat.params と shell.env は sessionID で突き合わせられる | 予測どおり。chat.message の model も同じ文字列 | confirmed |
| M13 | mock | detached で起動した子の process group を負の pid で SIGKILL すると、子も孫も消える | 予測どおり。after の中からの ruby の spawn は 61ms (sh) / 44ms (zsh) | confirmed |
| M14 | mock | edit の失敗では after が呼ばれず、bash の非 0 終了では呼ばれる | 予測どおり。失敗した edit の part の status は error | confirmed |
| M15 | mock | tmp の HOME の `~/.claude/CLAUDE.md` と `~/.claude/skills` が request に載り、`OPENCODE_DISABLE_CLAUDE_CODE=1` で消える | 予測どおり | confirmed |
| M16 | real | after で足した nonce が、実 provider の変換を経ても model に届く | `opencode-go/kimi-k3` で 1 run (auth は env の OPENCODE_API_KEY を `--pass-env` で渡した)。model の返答に、after で足した nonce (run ごとの乱数) がそのまま含まれていた。実物の config dir と DB の mtime は変わらない | confirmed |
| M17 | tui-plan (手動) | — | 未測。TUI の表示 (注記・toast・PTY の目印・event の reject) は、PR 2 の実機 smoke で人が確かめる。自動で測れる部分は M5 / M8 / M11 (serve の PTY と `!` を含む) で確認済み | unknown |
| M18 | mock (snapshot) | (予測なし) | snapshot を on にした run で踏む hook は post-index-change (15 回) と reference-transaction (2 回)。commit 系 (pre-commit / commit-msg / post-commit) は踏まない。hook の env の目印は OPENCODE / AGENT / OPENCODE_PID だけで、plugin が shell.env で立てた目印は届かない。harness 自身の `git init` も reference-transaction を 1 回踏む (run の label が空の記録) | observed |
| M19 | mock | (予測なし) | mock が受けた system message に `probe/claude-probe` の形の ID がある | observed |
| M20 | 手動 | 普段の起動経路で、他の agent の目印が OpenCode に漏れうる | herdr の pane (Claude Code と同じ tab を分割した pane) から起動した OpenCode: CLAUDECODE / CODEX_THREAD_ID / CODEX_SANDBOX はどれも立っていない (model の bash で確認。`!` と同じく OpenCode の process の env を継ぐ経路。`env` / `printenv` は user の permission 設定で deny されていたので、model が `${VAR+x}` の展開で存在だけを確かめた)。Claude の session の中の terminal から起動する経路は未測 (Claude Code の `!` / Bash からは TUI を起動できず、入れ子の agent の起動も避ける)。子 process は親の env を継ぐので、その経路では CLAUDECODE が立つと予測する | unknown (1 経路のみ) |

## PR 1〜3 への入力

PR 0 の merge の後、orchestrator がこの表に従って #295 の PR 1〜3 の項を更新する。

| M | 影響する PR の項 | differs / unknown のときの扱い (事前に決めたもの) | 今回の結果と扱い |
| --- | --- | --- | --- |
| M2 | PR 1 の plugin の形と marker 行 | marker 行が付いた file が読まれなければ、PR 1 に着手せず user に報告する | 読まれた (1 回)。PR 1 に着手してよい |
| M3 | PR 2 の対象 tool と path の取り方 | orchestrator が PR 2 の項を実物に合わせて更新する | 予測どおり。edit / write は args.filePath、apply_patch は after の `metadata.files[].filePath` から取る |
| M4 | Q2 と Q3 の前提 | 届かなければ、PR 1 に着手せず user の判断を待つ | 届いた (mock と、M16 の実 provider の両方)。PR 1 に着手してよい |
| M5 | PR 3a の目印と絞り方 | 既定の分岐に従う。shell.env が model の bash で効かなければ、Q4 の前提が崩れるので PR 3a に着手せず user の判断を待つ | OPENCODE_SESSION_ID は無いので、plugin の shell.env で目印を立てる。shell.env は model の bash で効く (Q4 の前提は保たれる)。`!` にも callID が付くので「callID の有無で絞る」は使えず、既定の分岐のとおり、記録専用の tool.execute.before で model の bash の callID を覚えて突き合わせる。PR 1 の test「hooks に tool.execute.before が無い」は「before は throw せず、args を書き換えない」に置き換える。PTY は sessionID も callID も持たないので、目印は立たない |
| M6 / M7 / M8 | plugin の fail-open | 落ちなくても try/catch は外さない | M6 / M7 で、hook の throw は tool を失敗させる (after の throw では、実行済みでも出力が model に届かない)。try/catch は必須。M8 は run / serve では落ちないが、stack trace が出るので包む。after には timeout が無いので、plugin の定数の timeout が要る |
| M9 | PR 2 の直列化と子 session の除外 | 子 session の idle が届くなら、`client.session.get` の parentID で除外する | 届いた。parentID は取れるので、その方法で除外する |
| M10 / M11 | PR 2 の docs | — | run では idle の後の非同期の処理が打ち切られる。showToast の戻り値は表示の証拠にならない。app.log は log file に出る。どちらも docs に書く |
| M12 | PR 3a の regex と系列表の fixture | 実物の文字列を fixture に足す。regex に合わなければ PR 3a の項を更新する | M16 の run の chat.params で providerID = `opencode-go`、modelID = api.id = `kimi-k3`。この文字列を fixture に足す (mock では `probe` / `claude-probe`) |
| M13 | timeout と kill の方法 | 負の pid の kill が効かなければ、子だけを kill して、孫が残りうることを honest-label する | 効いた。detached の spawn と負の pid への SIGKILL を採る。timeout の起点の値 (10 / 30 / 120 秒) は、spawn の 44〜61ms に対して十分 |
| M15 | PR 1 と PR 3b の前提 | 読まれなければ、orchestrator が PR 3b の OpenCode session の規則を見直す | 読まれた。skill と instruction は OpenCode に配らない (OpenCode が `~/.claude` を読む)。`~/.claude/skills` の personal-* は OpenCode からも発火しうるので、PR 3b の規則 (OpenCode の session での review は人に渡す) はそのまま要る |
| M18 | PR 3a | 内部の git が目印つきの env で commit-msg を踏むなら、user の判断を待つ | 踏まない。snapshot は commit 系の hook を踏まず、shell.env の目印も届かない。組み込みの OPENCODE=1 は内部の git にも載る (gate の目印にしない、という既定のとおり) |
| M19 | PR 3b | ID が載っていなければ、PR 3a の着手前に user に方式を諮る | 載っている。model は trailer の `<provider>/<model>` を system message から書ける (mock での観測) |
| M20 | 漏れ対策 | 漏れ対策は既定で入れる。結果は有無だけを記録する | herdr の pane の経路では漏れていない。Claude の session の中から起動する経路では漏れると予測する。漏れ対策 (shell.env で空文字に上書き) は既定どおり入れる。あわせて、user の permission の `env` / `printenv` の deny は、model が別の command で env を調べるのを止めなかった (deny は command 名での steering で、境界ではない) |

## 強度のラベル

- 目印 (M5 / M18) は観測した事実であって、OpenCode の公開の契約ではない。CLI を更新したら、この probe で
  測り直す。
- 予測は OpenCode 1.18.30 の source と、`@opencode-ai/plugin`・`@opencode-ai/sdk` 1.18.30 の型定義から
  立てた。verdict の confirmed は「この version のこの環境で、予測どおりに観測した」という意味に限る。
