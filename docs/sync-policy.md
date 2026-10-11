# Sync Policy

sync は、この repository で生成した personal assets を local tool directories に反映します。
default は必ず conservative にします。

実装は `scripts/sync.sh` です。usage は [scripts/README.md](../scripts/README.md) を
参照してください。

## Default 方針

- sync は default dry-run。実際の書き込みには `--apply` を必須にする。
- sync は catalog (`generated/catalog.json`) を source of truth として列挙し、
  `registration: registered` の target-artifact だけを配置する。registered でない
  (`human_review_required` / `unsupported`) ものは理由つきで skip する。
- catalog が無い / version 不一致なら何も配置せず register を促す。
- register 後に manifest が変わった entry (catalog の `manifest_digest` と現在の manifest
  が不一致) は、登録判断ごと stale なので配置せず `manifest changed; run
  scripts/register.sh first` で skip する (fail-closed, #148)。
- sync が更新してよいのは agent-tools management marker を含む targets のみ。
  同名の unmanaged targets は conflict として扱い、sync を停止する。
- artifact_kind ごとに配置先が異なる:
  - skill: `<tool home>/skills/personal-<name>/` (directory)。
  - instruction: connect が確立した所有ファイル。instruction の所有確立は connect の
    役割で、sync は create に落ちず未接続なら connect を促す
    ([Instruction Artifact Kind](instruction-artifact-kind.md))。
  - script: `<tool home>/agent-tools/scripts/personal-<name>` (単一実行ファイル) と
    その隣の `<name>.agent-tools-managed.yml` (sidecar marker)。本体は byte 保持・mode 0755。
    instruction と違い人間ファイルを介さないため connect 不要で、未配置なら sync が直接
    create する。配置先本体・sidecar marker・`agent-tools/scripts`・`agent-tools` のいずれかが
    symlink なら conflict として停止する。
  - plugin: `<opencode home>/plugins/personal-<name>.js` (単一 file、mode 0644)。marker は
    本体先頭の 1 行 JS ブロックコメントで、sidecar は無い。connect 不要で、未配置なら sync が
    `plugins/` を mkdir_p して直接 create する。詳細は下記「v1 OpenCode targets」。
- apply の書き込み (skill / script / instruction / plugin)。skill は generated を配置先と同じ親 dir の一時 dir
  (`.agent-tools-staging-personal-<name>`) に copy し、旧 dir を `.agent-tools-old-personal-<name>` に rename で退避してから
  一時 dir を rename で配置先に置き、最後に退避した旧 dir を消す (退避 → 配置 → 削除。配置先が無い時間は
  2 つの rename の間だけで、marker は一時 dir の中にあり rename で初めて有効になる)。copy の途中で止まれば
  旧版はそのまま。配置の rename に失敗したら退避した旧版を戻して `fail:` で止める (例外でも割り込みでも戻す。
  SIGKILL は除く)。戻すかどうかは退避先と配置先の実在で判断する (退避の rename の直後の割り込みでも戻す)。
  前回の中断で配置先が無く退避した旧 dir だけがあれば、消さずに配置先へ戻してから進める。
  前回の残り (一時 dir / 戻した後の退避 dir) を消せなければ何も書かずに `fail:` で止める (exit 1)。退避した
  旧 dir を消し残したら、新版は配置済みのまま `fail:` で止め、旧の写しの path を出す (手で消す。次の sync は
  新版を up-to-date と見る)。配置の rename の直後に割り込まれたときは、退避した旧 dir はその path を出さずに残る。
  up-to-date の間は消えず、その skill の次の create / update の冒頭で消える。
  script は本体 → sidecar marker の順に、それぞれ一時 file (同じ dir の `.agent-tools-staging-<file 名>`) に書いて
  rename する (一時 file の path に directory や消せない file があれば止める)。
  create の途中で止まると marker の無い本体が残り、次の sync は unmanaged の conflict で止まる (fail-closed)。
  instruction と plugin も、script と同じく一時 file に書いて rename する。どちらも先頭行の marker の build_id だけで
  up-to-date を決めるので、配置先へ直接書いて途中で止まると、新しい marker を持つ切れた file を次の sync が
  up-to-date と見てしまうため (#482)。instruction は所有ファイルの mode を引き継ぎ、plugin は 0644 にする。
  connect の書き込みも同じ形にする。所有ファイルの作成 (空ファイルの claim を含む) は一時 file に書いて rename し、
  claim する空ファイルの mode は引き継ぐ。人間の `CLAUDE.md` への import 1 行は、file を作り直さずに追記で末尾に
  足す (inode と mode を変えない。途中で止まっても既存の内容を切り詰めない)。
  `fail:` で止めた時点で、同じ run の後続の plan は適用しない。
- 走査する tool と kind の組は `ArtifactTargets::TOOL_KINDS` に従う (plan も prune も)。
  codex / claude-code は skill / instruction / script、opencode は plugin だけで、opencode home の
  `skills/` と `agent-tools/scripts/` は一切走査しない (#295)。

## v1 Codex targets

許可する target:

```text
~/.codex/skills/personal-*
~/.codex/AGENTS.md                       (instruction、connect が所有を確立)
~/.codex/agent-tools/scripts/personal-*  (script、sync が直接配置)
```

禁止する targets:

```text
~/.codex/skills/.system
~/.codex/plugins
~/.codex/cache
~/.codex/auth.json
~/.codex/config.toml
~/.codex/*.sqlite
```

## v1 Claude Code targets

許可する target:

```text
~/.claude/skills/personal-*
~/.claude/agent-tools/CLAUDE.md            (instruction、connect が所有を確立)
~/.claude/agent-tools/scripts/personal-*   (script、sync が直接配置)
```

禁止する targets:

```text
~/.claude/cache
~/.claude/sessions
~/.claude/projects
```

## v1 OpenCode targets (#295)

許可する target (これだけ):

```text
~/.config/opencode/plugins/personal-*.js   (plugin、sync が直接配置。mode 0644)
```

opencode home の既定は `~/.config/opencode` に固定し (`XDG_CONFIG_HOME` は見ない。食い違いの
検出は doctor の warn)、`--opencode-home` で上書きする。OpenCode が未 install の machine でも、
既存の tool と同じく sync は `<opencode home>/plugins/` を作って置く。

触らないもの (OpenCode / dotfiles / local が管理する):

```text
~/.config/opencode/opencode.json           (dotfiles)
~/.config/opencode/opencode.jsonc          (dotfiles)
~/.config/opencode/opencode.local.json     (local)
~/.config/opencode/config.json
~/.config/opencode/package.json            (OpenCode 本体が書く)
~/.config/opencode/package-lock.json
~/.config/opencode/bun.lock
~/.config/opencode/node_modules            (OpenCode 本体が npm install する)
~/.config/opencode/.gitignore              (OpenCode 本体が書く)
~/.config/opencode/skills                  (走査もしない)
~/.config/opencode/agent-tools             (走査もしない)
~/.config/opencode/plugins/<personal- で始まらない file>  (herdr-agent-state.js 等。plan にも prune にも出さない)
OpenCode の data / cache dir (XDG_DATA_HOME / XDG_CACHE_HOME 配下)
```

plugin の plan の判定順 (既存 kind と対称):

1. name が `personal-` で始まること。
2. generated 側の先頭行 marker が catalog の target / name / build_id と一致すること
   (`PluginMarker.matches?`。一致しなければ `run build first` で skip)。
3. target か `plugins/` が symlink なら conflict。
4. target が無ければ `create`。
5. target が regular file でなければ conflict。
6. 先頭行の marker が `target=opencode` かつ同じ name でなければ、`existing target is unmanaged` の
   conflict (marker 無し / 別 name / instruction の HTML コメント marker / `target=claude-code` の
   marker はすべてここで止まる。判定は `PluginMarker.owned` = `parse` + target + name の一致で、prune と
   共有する。doctor が数える plugin も同じ判定 (`PluginMarker.managed?`、name は file 名) を使う)。
7. build_id が同じなら up-to-date、違えば `update`。

apply は mkdir_p してから、一時 file に copy して 0644 にし、rename で置く (上記「apply の書き込み」)。`--prune` は
`plugins/personal-*.js` だけを見て、marker が一致し catalog に無い orphan を撤去し、symlink と unmanaged は skip する
(`.ts` は見ない)。

`~/.codex/plugins` を禁止しつつ OpenCode の `plugins/` を許可する理由: 前者は Codex 本体が管理する
dir (tool-managed) で、後者は user が plugin を置く dir (OpenCode は `plugins/*.js` を読むだけで、
中身を管理しない)。OpenCode では `plugins/` に file を置くこと自体が登録になり、`opencode.json` への
登録は要らない。plugin の読込を止めるには `opencode --pure` で起動する (外部 plugin なし)。

## その他の禁止 runtime state

```text
~/.agents/skills/*/db
~/.agents/skills/*/teams
```

補足: `scripts/doctor.sh` の forbidden target 検査は、上記禁止リストのうち directory の
部分集合だけを見る (directory 直下の marker file の有無で判定するため、file 型の
`auth.json` / `config.toml` / `*.sqlite` はこの検査方式の対象外)。

## 撤去 (sync --prune)

`sync --prune` は、catalog に載らなくなった (= `shared/` から消えた) asset の deployed
コピーを tool home から撤去します。`build --prune` (generated/ の orphan 削除) の sync 版
です (#154)。

- 削除も dry-run が既定で、実削除には `--apply` が必須。
- 削除するのは次の 3 条件をすべて満たすものだけ (marker-gated delete):
  1. 許可 namespace 内 (`<tool home>/skills/personal-*` / `<tool home>/agent-tools/scripts/personal-*` /
     `<opencode home>/plugins/personal-*.js`。走査する組は `TOOL_KINDS` に従う)
  2. agent-tools management marker が tool / name と一致 (skill は、撤去の途中で退避した marker も含む。下記)
  3. catalog に同 target + name + artifact_kind の entry が無い
- 照合は artifact_kind 単位。kind を変更した asset の旧配置物は保護されず撤去される
  (`build --prune` と同じ判断)。
- catalog の entry は registration 状態を問わず asset の実在とみなす
  (`human_review_required` でも撤去しない)。catalog が無い / version 不一致 / entry ゼロ
  (valid な空 catalog) なら何も判断せず撤去しない (fail-closed。空 catalog は manifest
  ゼロの repo で register しても生成できるため、全 deployed が orphan に見える誤爆を塞ぐ)。
- 条件を満たさない orphan (unmanaged / symlink) は削除せず skip として可視化するだけで、
  conflict にしない (書き込みと違い「触らない」が常に安全なため、prune は停止しない)。
- script は本体と sidecar marker を対で撤去する。plugin は本体 1 file を撤去する。
- 削除の後に消えたことを確かめ、消し残したら `fail:` で止める (exit 1。rm_f / rm_rf は削除の失敗を握りつぶす
  ため。同じ run の後続の plan は適用しない)。marker は本体が消えたのを確かめてから最後に消すので、消し残しても
  marker が残り、次の prune がまた撤去の対象にする (marker が先に消えると、残りは unmanaged の skip になる, #482)。
  - skill は、dir の中の marker が symlink なら管理外として skip する (sync が置く marker は通常の file。相対 symlink の
    marker は退避するとリンク切れになり、戻せなくなる)。
  - skill は marker 以外を先に消す (dir の中を列挙できなければ、marker を残して止める)。marker だけになったら、
    marker を同じ親 dir の `.agent-tools-marker-personal-<name>` に rename で退避してから空の dir を消し、最後に
    退避した marker を消す。親 dir に書けなければ退避の時点で止まり、marker は dir の中に残る。退避の後・dir の削除の
    前で止まったら (空の dir を消せない例外も、割り込みも。SIGKILL は除く)、marker を dir の中へ戻して止める。戻す
    かどうかは退避先と dir の実在 (symlink ならリンク自体) で判断する (退避の rename の直後の割り込みでも戻す)。dir を
    消した後に退避した marker を消せなければ、その path を出して止める (手で消す)。
  - marker を dir の中へ戻す rename も失敗したら、dir と退避先の両方の path を出して止める。次の prune は、**空の** skill
    の dir の隣 (同じ親 dir) に、同じ name の退避した marker (`.agent-tools-marker-personal-<name>`) があり、それが
    symlink でない file で、dir の中の marker と同じ検査 (tool と name の一致) を通れば、その dir を撤去の対象にする
    (`not in catalog; resumes an interrupted removal`)。退避した時点で dir には marker しか無かったので、中断の続きなら
    dir は空のはず。空でない dir は、同じ名前で作り直されたものかもしれないので unmanaged の skip にする。apply は
    中身を消さず、marker も dir の中へ戻さずに rmdir (非再帰) だけを行う (plan の後に dir へ file が置かれていれば
    止まり、中身も退避した marker も残る)。dry-run では何も書かない。退避した marker が別の name を示す / symlink /
    読めない、または dir を列挙できないなら、その dir は unmanaged の skip で、他の対象の plan は続ける。
  - 撤去の経路 (通常か続きか) は plan で決め、apply の時点の marker の有無で切り替えない。続きの plan の後に marker と
    同じ名前の file が置かれても rmdir だけで止まり、通常の撤去の plan の後に marker が消えていれば、何も消さずに止める。
  - script は本体 → sidecar marker の順に消す。sidecar marker だけを消し残したときは、その path を出して止める
    (sidecar 単体は prune が列挙しないので、手で消す)。
  - 単一 file の kind (script の本体と sidecar marker、plugin) は非再帰に消す (unlink)。directory に置き換わって
    いれば中身ごと消さず、marker を残して止める。
  - plugin は marker が本体の先頭行にあるので、消し残せば marker ごと残る。
- instruction は prune 対象外。所有ファイルは人間の instruction ファイルと絡めて connect
  が管理しており、撤去 (所有解除) は人間の判断で行う。

## Management Marker

marker format は [Status / Manifest Contract](status-manifest-contract.md) で定義します。

- repository name: `agent-tools`
- generated asset name
- target tool
- source path
- source content の sha256 build_id

sync は marker を持たない files / directories の変更を拒否します。
同名の unmanaged target は `conflict` として停止します。

## instruction の所有ファイル

instruction artifact は connect が所有を確立し、sync が更新する。

- claude-code: `<claude home>/agent-tools/CLAUDE.md` (人間の `CLAUDE.md` からは import で
  取り込む)。
- codex: `<codex home>/AGENTS.md` (空ファイルのみ claim)。

これらは日常 sync では create せず、connect だけが所有を開始する。symlink / 非通常
ファイル / unmanaged な所有先は conflict として停止する。詳細は
[Instruction Artifact Kind](instruction-artifact-kind.md)。

## 既知の限界 (TOCTOU)

symlink / unmanaged の検査は plan 時に行い、apply は配置先を再検証しません。
plan→apply 間に配置先を差し替えられると検査を通過した plan のまま書き込みます。

これを意図的に突ける主体は、同一ユーザー権限で任意のファイルを書き換えられる攻撃者に
限られます。その主体は apply 直前の再検証も同様に無効化できるため、再検証を足しても
防御になりません (実装しない判断, #149)。同時実行による事故は、個人ツールとして同時
実行の前提が薄いこと、書き込み先が marker-gated な managed target に限定されることで
被害が限定されます。

## 既知の限界 (tool home symlink)

sync / connect の symlink 検査は配置先 target とその近接 parent (script は本体・sidecar・
`agent-tools/scripts`・`agent-tools` の 4 経路、plugin は本体と `plugins/` の 2 経路) を対象とし、
**tool home (`~/.claude` / `~/.codex` / `~/.config/opencode`) 自体が symlink かは検査しません**。home が symlink なら、その先へ書き込みが
向かいます。

これは意図した won't-fix です (#176 M-03 裁定):

- home の symlink 化は dotfile manager による**正当な構成**で、conflict で弾くと正当な
  ユーザー環境を壊す。
- この経路を悪用して書き込み先を外部へ向けられる主体は、home symlink を張り替えられる =
  同一ユーザー権限の攻撃者に限られ、上記 TOCTOU と同じく脅威モデル外 (守る相手は配布物に
  紛れ込む外部由来の悪性コンテンツであり、home symlink はその経路でない)。
