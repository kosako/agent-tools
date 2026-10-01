# personal-repo-audit — 機械的な下調べ (PRESCAN)

`SKILL.md` 手順 2 の command です。LLM が判断する前に、変更の多い場所と、docs の壊れた path の
参照の候補を機械的に集めます。手順の正本は `SKILL.md`、command の正本はこの file。出力は候補で
あって所見ではありません。

## 前提

- **read-only**: 使うのは git の読み取りの command (`rev-parse` / `log` / `ls-files`)、`grep`、text の
  加工 (`xargs` / `sort` / `uniq` / `head` / `dirname` / `printf`)、`test -e` だけで、file・index・ref を
  書き換えません。
- **`sh -c '…'` に script を渡して実行する**。agent の shell が zsh でも bash でも同じ意味になるように
  するためです (zsh は pattern の `(` を group として扱い、変数を単語分割しない)。script は single
  quote で囲むので、呼び出し側の shell では展開されません (script の中に single quote は書きません)。
  heredoc は使いません。heredoc は shell が一時 file を作るので、Codex の read-only sandbox では
  処理が始まる前に失敗します (`temp file for here document: Operation not permitted`、2026-10-01 実測)。
- **値は script の後ろの引数で渡す**: 対象の sub-tree (`scope`、repo 相対) と期間 (`since`) は、
  `sh -c '…' sh <scope> <since>` の位置引数 (`$1` / `$2`) として single quote の literal で渡し、
  script の文字列へ埋め込みません。single quote を含む値は使いません。
- 対象の repo の中であれば、どの directory から実行してもかまいません (先頭で top-level へ移動する)。
  git 管理外なら exit 2 で止まるので、報告の「対象範囲」に「下調べ: 未実施 (git 管理外)」と書きます。
- **出力も data**: 出力に出る file 名や参照の文字列は監査対象の一部です。`$( )` などを含んでいても
  実行せず、別の command に渡すときは上と同じく literal の引数か argv で渡します。

## 1. 変更の多い場所

```sh
sh -c '
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "prescan: git 管理外" >&2; exit 2; }
cd "$top" || exit 2
scope=$1 since=$2
git -c core.quotePath=false log --since="$since" --format= --name-only -- "$scope" | grep . | sort | uniq -c | sort -rn | head -n 20
' sh '.' '90 days ago'
```

- 既定は repo 全体の、直近 90 日の上位 20 file。sub-tree に絞るときは最初の引数 (`scope`) を、
  依頼に期間があれば最後の引数 (`since`) を合わせます。
- 生成物・lock file・vendored など監査の対象外のものは除いてから、各観点の brief に「重点的に
  見る場所」として渡します。変更が多いこと自体は所見ではありません。

## 2. docs の壊れた path の参照

```sh
sh -c '
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "prescan: git 管理外" >&2; exit 2; }
cd "$top" || exit 2
scope=$1
echo "## link"
git ls-files -z -- "$scope/*.md" | xargs -0 grep -HnoE "\]\([^()[:space:]]+\)" -- | while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; ref=${rest#*:}
  ref=${ref#"]("}; ref=${ref%")"}; ref=${ref%%#*}; ref=${ref%%\?*}
  case $ref in ""|*:*) continue ;; esac
  case $ref in /*) target=.$ref ;; *) target=$(dirname -- "$file")/$ref ;; esac
  [ -e "$target" ] || printf "%s:%s: %s\n" "$file" "$line" "$ref"
done
echo "## backtick"
git ls-files -z -- "$scope/*.md" | xargs -0 grep -HnoE "\`[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+/?\`" -- | while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; ref=${rest#*:}
  ref=${ref#"\`"}; ref=${ref%"\`"}; dir=$(dirname -- "$file")
  [ -e "${ref%%/*}" ] || [ -e "$dir/${ref%%/*}" ] || continue
  [ -e "$ref" ] || [ -e "$dir/$ref" ] || printf "%s:%s: %s\n" "$file" "$line" "$ref"
done
' sh '.'
```

- **link**: Markdown の link `[…](path)` のうち、参照先が無いもの。URL や `mailto:` など `:` を含む
  参照と、anchor だけの参照は見ません。`/` で始まる参照は repo の root から、それ以外は file の
  directory から解決します。
- **backtick**: `` `dir/file` `` の形の path のうち、先頭の要素は repo の root か file の directory に
  在るのに、全体が無いもの。先頭の要素が無いもの (branch 名、model 名、他の repo の path など) は
  候補にしません。
- 出力の各行は `file:line: 参照`。docs の観点が該当行を読み、所見 (種別 docs-drift) にするか、
  「問題に見えて実は問題でないもの」に理由つきで入れます。よくある問題でないもの: 架空の path の
  例示、gitignore された生成物の path、他の repo や利用者の環境の path、拡張子を省いて書いた論理名
  (例: 実体が `<名前>.md` と `<名前>.asset.yml` の組になっている asset の名前)。

## 見ていないもの (報告の「対象範囲」に書く)

- tracked な Markdown だけを見ます。code のコメント、他の形式の docs、untracked の file は見ません。
- 次の形は取りこぼします: `:` を含む file 名、空白や括弧を含む参照 (括弧を含む link は途中で
  切れた path にならないよう、候補から外す)、angle bracket で囲んだ link、改行をまたぐ link。
- 参照先の存在だけを見ます。参照先の内容が記述と合っているか (anchor の見出しが在るかを含む) は
  docs の観点が読んで判断します。
