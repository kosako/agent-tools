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
- どちらも登録 (+ Codex は trust) が済むまで無警告で不活性 (fail-open の帰結)。
  配線は dotfiles 所有 (boundary-with-dotfiles)。

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

## personal-fast-edit-check(PostToolUse / `Edit|Write`)

- payload の `tool_input.file_path` から対象ファイルを取り、その repo の `edit_checks` の
  うち `pattern` (Ruby regex) がファイル名に一致するものを実行する。
- 失敗時のみ `hookSpecificOutput.additionalContext` で失敗要約 (上限 2000 文字 /
  非 UTF-8 は scrub) をモデルに返す。成功は無言 (ノイズ規律)。
- 設定ファイルが壊れているときは無言で握り潰さず、設定エラーを additionalContext で
  1 行知らせる (それでも exit 0)。
- **Codex parity の honest-label**: Claude Code の payload 形 (`tool_input.file_path`) は
  #201 実測済み。Codex (apply_patch) の payload 形は未実測で、file_path が取れなければ
  無言 no-op に倒れる。配備時に実測して追従する。

## personal-changed-scope-qa(Stop)

- **検査対象の帰属 (#203 裁定)**: agent の変更とユーザーの手元変更を区別せず、working
  tree の **dirty scope 全体** (tracked の変更 + untracked) を対象にする。ユーザー自身の
  書きかけ変更も検査対象になる (明記)。
- dirty かつ宣言 repo なら `qa_checks` を実行。全 pass → scope 指紋 (status + diff の
  sha256) と結果を state に cache して無言 pass。失敗 → **exit 2 + stderr 要約で block**
  (モデルに修正の続行を促す)。
- **無限ループ対策 (仕様)**:
  - `stop_hook_active: true` (この turn で既に継続済み) では**絶対に block しない**
    (check は走らせ、結果は additionalContext の警告で返す)。
  - 同一 scope 指紋の再 Stop は check を**再実行しない** (pass 済み = 無言 / fail 済み =
    非ブロッキング警告のみ。block は新しい scope に 1 回だけ → 直せない失敗は人間に戻る)。
  - check コマンド不在・spawn 失敗は「警告に降格」して block しない (cache もしないので
    環境が直れば次の Stop で再試行)。
- state: `~/.cache/agent-tools/changed-scope-qa/<repo path の sha256>.json`。
  test 用 override: `AGENT_TOOLS_QA_STATE_DIR` / 設定は `AGENT_TOOLS_CHECKS_CONFIG`。
- Codex 側は Stop の matcher が無視される点 (#201) 以外は同型を期待。`stop_hook_active` /
  block 挙動の Codex 実測は配備時 (#201 からの carry-over)。

## 検証境界

- 純粋ロジックと git 連携・cache・ループ対策は `scripts/tests/quality-loop-hooks-test.sh`
  が CI で検証する (設定 / state / HOME / git config を隔離・fake check 使用)。
- 実配線 (settings.json / hooks.json への登録・Codex payload / Stop の実測) は CI 外
  (dotfiles 側 issue + 実機 smoke。実施記録は #203)。
