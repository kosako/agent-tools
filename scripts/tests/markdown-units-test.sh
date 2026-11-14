#!/bin/sh
# scripts/tests/lib/markdown_units.rb の self-test (#676)。wiring の test が文書を単位に分けるときの読み方と、受ける整形の
# 範囲 (helper の冒頭の契約) を固定する。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ruby -r"$script_dir/lib/check_helper" -r"$script_dir/lib/markdown_units" - <<'RUBY'
MU = MarkdownUnits

DOC = <<'MD'
# 題

前書き。

###  2. 手順 (括弧つき)
本文の段落。`one
  two` を使う。次の文。

```sh
## fence の中の見出しの形
body=x
"$check" \
    --body-file "$body"
```

  ```sh
  gh  pr comment
  ```

- 項目 A: 一。
  続きの行。
- 項目 B: 二。

項目の外の段落。
#### 2.1 小見出し
小見出しの本文。
### 3. 次の手順
次の本文。
MD

step2 = MU.section(DOC, "### 2. 手順 (括弧つき)")

# ---- 見出しと節
check "a heading is matched ignoring the spaces after the marks", !step2.nil? && step2.include?("本文の段落")
check "a section runs to the next heading of the same or a higher level", step2.include?("小見出しの本文") && !step2.include?("次の本文")
check "a deeper heading does not end the section", step2.include?("#### 2.1 小見出し")
check "a missing heading gives nil", MU.section(DOC, "### 9. 無い").nil?
check "the level is part of the heading", MU.section(DOC, "## 2. 手順 (括弧つき)").nil?
check "a heading-shaped line inside a fence is not a heading", MU.section("```\n## H\nin\n```\n## H\nreal\n", "## H") == "real\n"
check "a heading-shaped line inside a fence does not end a section", MU.section("## H\na\n```\n# X\n```\nb\n# Y\nc\n", "## H") == "a\n```\n# X\n```\nb\n"
check "a line without a space after the marks is not a heading", MU.section("#!/bin/sh\n## H\nx\n", "#!/bin/sh").nil?

# ---- fence の block
blocks = MU.blocks(step2)
check "blocks are cut fence by fence with their info strings", blocks.map(&:first) == %w[sh sh]
check "a line continuation is joined", blocks[0][1].match?(/"\$check"\s+--body-file\s+"\$body"/) && !blocks[0][1].include?("\\")
check "a block does not run past its closing fence", !blocks[0][1].include?("gh") && blocks[1][1].match?(/\A\s*gh\s+pr\s+comment\s*\z/)
check "an indented fence is a fence", blocks[1][1].include?("gh")
check "an unclosed fence is not a block", MU.blocks("```sh\na\n") == []
check "a fence without an info string has an empty one", MU.blocks("```\na\n```\n") == [["", "a\n"]]
check "the spaces around an info string are dropped", MU.blocks("``` sh  \na\n```\n") == [["sh", "a\n"]]

# ---- fence の外の単位
items = MU.items(step2)
check "items are the dash lines with their indented continuations", items.size == 2 && items[0].include?("続きの行") && !items[1].include?("項目の外")
check "the lines of a fence are not items", MU.items("```\n- in a fence\n```\n- real\n") == ["- real\n"]
paras = MU.paragraphs(step2)
check "paragraphs are split at blank lines and at fences", paras.any? { |para| para.start_with?("本文の段落") && !para.include?("項目") } &&
                                                           paras.none? { |para| para.include?("body=x") }
sentences = MU.sentences(step2)
check "sentences are split at the full stop with the spaces removed", sentences.include?("次の文") && sentences.include?("-項目B:二")
check "the text of a fence is not in the sentences", sentences.none? { |s| s.include?("body=x") }
check "a code span may wrap across lines", MU.code_spans(step2) == ["onetwo"]
check "the backticks of a fence are not code spans", MU.code_spans("```sh\na `b` c\n```\n`d  e`\n") == ["de"]

# ---- 語の照合
check "containing compares without spaces", MU.containing(["a  b\n c", "x"], "a b c") == ["a  b\n c"]
check "missing lists the words that are absent", MU.missing("--marker-kind  pr\n", ["--marker-kind pr", "--title"]) == ["--title"]
check "squash removes every kind of space", MU.squash(" a\tb\n c ") == "abc"

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: markdown-units-test"
