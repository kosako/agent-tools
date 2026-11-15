# 参照先の note を人が書き換える (personal-context-note-apply)

repo の参照先の note (`.agent-context.local.md`) を、人が差分を確かめてから書き換える helper です (#677)。実体は
`shared/scripts/personal-context-note-apply.rb` で、配備先は `<tool home>/agent-tools/scripts/personal-context-note-apply`。

## 位置づけ

note は git 管理しないユーザー正本で、agent は書き換えません (運用 instruction の「参照先」)。今までは、更新が要るたびに
agent が使い捨ての script を書き、人が差分を見るために 1 回、当てるために 1 回実行していました。この helper で、差分の確認と
書き換えを 1 回の実行にまとめ、毎回の script を無くします。

- agent が行うのは、note の新しい全文を案の file に書き、helper を実行する 1 行の command を人に渡すところまでです。helper を
  自分では実行しません。手順は `personal-session-handoff` の手順 4 が持ちます。
- 人は、その command を自分の terminal で直接実行し、差分を見て答えます。
- agent が note を書かない決まりは変えません。helper は、人が書き換えるための道具です。

## 使い方

```text
personal-context-note-apply [-C <dir>] <案の file>
```

- 対象の note は、`<dir>` (省くと今の directory) を含む git の作業 tree の root にある `.agent-context.local.md` です。
- 案の file は、note の新しい全文です。差分 (patch) ではありません。regular file で、空でなく、1 MiB 以下で、UTF-8 として
  読めることが要ります。標準入力からは読みません (標準入力は確認の答えに使う)。
- option は `-C` だけです。2 回渡す、値が無い、知らない option、案の file が 1 つでないときは usage (exit 2) です。

## 書くまでの流れ

順に確かめ、前の段で止まったら後ろの段は行いません。

1. agent の session の目印 (env の `CLAUDECODE`・`CODEX_THREAD_ID`・`CODEX_SANDBOX`・`AGENT_TOOLS_OPENCODE`) のどれかが空で
   なければ、書きません (`agent-session`)。目印は personal-ai-trailer-gate と同じです。
2. 標準入力と標準出力の両方が端末でなければ、書きません (`no-tty`)。agent の Bash の tool から起動したとき (Claude Code では
   標準入力と標準出力が端末でなく、`/dev/tty` も開けないことを実測した)、出力を溜める wrapper を通したときに当たります。
3. repository や index を選ぶ git の env (`GIT_DIR`・`GIT_WORK_TREE`・`GIT_INDEX_FILE`・`GIT_COMMON_DIR`・
   `GIT_OBJECT_DIRECTORY`・`GIT_ALTERNATE_OBJECT_DIRECTORIES`・`GIT_NAMESPACE`) を 1 つでも継承していれば (値が空でも)、
   tracked かを判定できないので止めます (`undetermined`)。resume の検査と personal-packet と同じ 7 つです。
4. git の作業 tree の root を `git rev-parse --show-toplevel` で決め (外すのは出力の末尾の改行だけ。名前の末尾の CR は残す)、
   案の file を読みます。
5. note を確かめます。無ければ新しく作ります。symlink (`symlink`)、regular file でないもの (`not-regular`)、git で tracked の
   もの (`tracked`) には書きません。tracked かは `git --no-literal-pathspecs ls-files --error-unmatch -- ':(icase).agent-context.local.md'`
   の exit 1 だけを「追跡なし」として見ます。大文字小文字だけ違う名前で tracked なときも、note が無いときも同じです。
6. 案が今の note と同じなら、確認を聞かずに終わります (`unchanged`)。
7. 差分を `diff -u` の形で見せます。`diff` には `-a` を付け、NUL を含む中身も binary とみなさずに行の差分として出させます。
   出力が差分の形 (見出しの 2 行と hunk) でなければ、確認に進まずに止まります (`undetermined`)。制御文字と書式の文字
   (Unicode の Cc と Cf。tab だけを除き、改行・CR・NUL を含む) は、差分の行と path のどちらでも `<U+XXXX>` の形で見せます。
   端末の escape sequence、向きを変える文字、path の中の改行で、表示の中身を隠したり偽の差分の行を作ったりできないように
   するためです。差分の行は、行の区切りの改行を外してから見せます。書く中身は案のままです。
8. `[y/N]` を聞きます。`y` か `yes` (大文字も) のときだけ進みます。それ以外の答え、EOF、Ctrl-C では書きません (`declined`)。
9. 書く直前に、5 の条件を確かめ直します。差分を見せた時から note の中身・権限・inode が変わっていれば、書きません
   (`changed`)。symlink に替わった、tracked になったときは、5 と同じ label で止まります。
10. 同じ directory の一時 file に書いてから、rename で置き換えます。今の note の権限を保ち、新しく作るときは 0600 にします。
    一時 file の作成や rename に失敗したら、一時 file を消して止まります (`write-failed`)。note は前のままです。

## 出力と exit

説明の行を出し、最後の行は stdout の `context-note-apply: <label>` です。止まった理由の行は stderr に出します。

| exit | label | 意味 |
| --- | --- | --- |
| 0 | `written` | 書いた |
| 0 | `unchanged` | 案が今の note と同じで、書いていない |
| 1 | `declined` | 人が断った、または中断した |
| 1 | `agent-session` / `no-tty` | agent の session の中か、端末でない |
| 1 | `symlink` / `not-regular` / `tracked` | note が書いてよい条件を満たさない |
| 1 | `changed` | 差分を見せた後に note が変わった |
| 2 | `usage` / `input` | 引数の誤り、案の file の誤り (無い、regular file でない、空、1 MiB を越える、UTF-8 でない) |
| 2 | `undetermined` | 判定できない (git の env の継承、git の作業 tree でない、index を読めない、note を読めない、差分を差分の形で作れない) |
| 2 | `write-failed` | 書けなかった (note は前のまま) |

## 強度

手順の守りであって境界ではありません。

- env の目印と端末の検査は、agent が意図すれば外せます。例えば、端末を持つ pane に command と答えを打ち込めば通ります。
  目印は観測された事実で、両 CLI の公開の契約ではありません。
- 確かめ直してから rename するまでの短い窓は残ります。
- agent が note を書かない決まりは、運用 instruction が持ちます。

## 使い方の例

agent は案を repo の外 (scratchpad など) に書き、placeholder の無い完成形の 1 行を人に渡します。

```sh
~/.claude/agent-tools/scripts/personal-context-note-apply -C '/path/to/repo' '/path/to/scratchpad/context-note.md'
```

Codex の配備先は `~/.codex/agent-tools/scripts/` です。人はこの行を、`!` や出力を溜める wrapper を通さずに、自分の terminal で
直接実行します。

## 組み込み先

- `personal-session-handoff` の手順 4 (正本ファイルへの反映をサジェストする)。
- 確かめ方は `scripts/tests/context-note-apply-test.sh` (端末は Ruby の標準の pty で作る)。
