#!/bin/sh
# 投稿の前の検査をまとめる script (personal-post-check) の組み込み (#676 の 2 本目) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (script の挙動は post-check-test、期待挙動は各 skill の evals.json の case)。
# 説明の文はそのまま固定しない。項目・文・段落・1 つの command (code span)・sh の block ごとに、要る語 (script の名前、
# option、exit code と「投稿する・しない」、理由の語) がそろっているかを見る。言い回しを変えても、語が同じ単位に残って
# いれば通る。節の全体からは探さない (語が別の項目や文に移っただけの変更を通さないため)。
# 文書を単位に分ける読み方と、受ける整形の範囲 (空白の数、折り返し、見出しの # の後ろの空白、fence の字下げ、sh の
# 行継続) は、lib/markdown_units.rb が持つ。
# - 運用 instruction の「## public safety」に、この script でまとめてかける項目があり、exit code ごとの扱い (0 のときだけ
#   投稿、3 は --style-reviewed、1 と 2 は投稿しない)、検査と投稿を別の呼び出しにすること、skill の手順が検査を個別に
#   定めている場面は範囲の外であることが入っている。もとの gate の宣言の項目も残っている。
# - personal-review-request の手順 2 に、exit code ごとの項目がある。検査の command の block と投稿の command の block が
#   分かれていて (検査の block に gh が無い)、検査の block が先にある。検査を 1 つずつ組み立てる前の形 (gate の stderr を
#   file に取る形) が残っていない。手順 4 に、個人 project で --marker-kind review-result を付けること、目印で止まったら
#   投稿しないことが入っている。
# - operating-loop の 3 つの節が、この script を指す。
# - docs/post-check.md に「## 組み込み先」の節がある。
# - 文書が使う option と目印の種類と exit code が、script にある (script を変えたのに文書が古いまま、を落とす)。
# - personal-review-request の evals.json に、この script に触れる case がある。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
require "json"

root = ARGV.fetch(0)
errors = []
MU = MarkdownUnits
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

# 節の本文。無ければ記録して nil。
section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節の中の単位 (kind は :items / :paragraphs / :sentences) のうち、key を含むもの。1 つも無ければ記録する。
units = lambda do |rel, heading, kind, key|
  body = section.call(rel, heading)
  next [] if body.nil?
  hits = MU.containing(MU.public_send(kind, body), key)
  errors << "#{rel} の「#{heading}」に、#{key.inspect} を含む#{{ items: "項目", paragraphs: "段落", sentences: "文" }.fetch(kind)}が無い" if hits.empty?
  hits
end

# 節の中の項目のうち、key を含むものがちょうど 1 つある。その項目 (無ければ nil)。
item = lambda do |rel, heading, key|
  body = section.call(rel, heading)
  next nil if body.nil?
  hits = MU.containing(MU.items(body), key)
  if hits.size != 1
    errors << "#{rel} の「#{heading}」で、#{key.inspect} を含む項目が #{hits.size} 個ある (1 個のはず)"
    next nil
  end
  hits[0]
end

# text の中に、語がすべてある。
terms = lambda do |where, text, words|
  next if text.nil?
  missing = MU.missing(text, words)
  errors << "#{where} に #{missing.map(&:inspect).join("、")} が無い" unless missing.empty?
end

# 節の中の code span のうち、語をすべて含むものが 1 つはある (1 つの command の中で語の組を見る)。
command_span = lambda do |rel, heading, label, words|
  body = section.call(rel, heading)
  next if body.nil?
  errors << "#{rel} の「#{heading}」に、#{label} (#{words.join(" と ")} を含む 1 つの command) が無い" \
    unless MU.code_spans(body).any? { |span| MU.missing(span, words).empty? }
end

# 1. 運用 instruction
rules = "shared/instructions/personal-operating-rules.md"
ps = "## public safety"
terms.call("#{rules} の「#{ps}」の personal-post-check の項目", item.call(rules, ps, "`personal-post-check`"),
           ["題名・本文・コメント", "exit 0 のときだけ投稿", "exit 3", "`--style-reviewed`", "exit 1 と exit 2 では投稿しない",
            "別の呼び出し", "個別に定めている場面", "その手順に従う"])
# もとの gate の宣言は残っている (この script の項目で置き換えていない)。
terms.call("#{rules} の「#{ps}」の gate の項目", item.call(rules, ps, "public-safety の gate (`--stdin`)"),
           ["exit 0 で警告が無いときだけ公開する", "公開せず"])

# 2. review の依頼・結果・後続のコメント
request = "shared/skills/personal-review-request/SKILL.md"
step2 = "### 2. 依頼コメントを準備・投稿 (投稿は write-authorized のみ)"
where2 = "#{request} の手順 2"
# かかる検査を書く段落: 文体の検査の名前がある段落に、この script と gate がある (節の別の所にあるだけでは通さない)。
units.call(request, step2, :paragraphs, "`personal-ja-style-check`").each do |para|
  terms.call("#{where2} の、かかる検査を書く段落", para, ["`personal-post-check`", "public-safety の gate"])
end
terms.call("#{where2} の exit 0 の項目", item.call(request, step2, "exit 0:"), ["投稿してよい", "別の呼び出し", "連ねません"])
terms.call("#{where2} の exit 3 の項目", item.call(request, step2, "exit 3:"),
           ["`--style-reviewed`", "指摘を読んで", "gate ではありません", "読まずに"])
terms.call("#{where2} の exit 1 の項目", item.call(request, step2, "exit 1:"),
           ["投稿しません", "`gate`", "`gate-warning`", "`unavailable`", "`marker`", "人に見せて"])
terms.call("#{where2} の exit 2 の項目", item.call(request, step2, "exit 2:"), ["入力の誤り"])
terms.call("#{where2} の script が無いときの項目", item.call(request, step2, "そのものが無い"), ["投稿せず", "省いて投稿しません"])

# sh の block (fence ごとに切り出し、行継続をつなげたもの) の中の command は、空白の数と字下げに依らずに見る。
step2_body = MU.section(read.call(request), step2).to_s
sh_blocks = MU.sh_blocks(step2_body)
check_at = sh_blocks.index { |b| b.match?(/"\$check"\s+--body-file\s+"\$body"/) }
post_at = sh_blocks.index { |b| b.match?(/^\s*gh\s+pr\s+comment\s/) }
if check_at.nil?
  errors << "#{where2} に検査 (personal-post-check) の sh の block が無い"
elsif post_at.nil?
  errors << "#{where2} に投稿 (gh pr comment) の sh の block が無い"
else
  errors << "#{where2} で、検査の block に gh の command がある (検査と投稿は別の呼び出し)" if sh_blocks[check_at].match?(/\bgh\s/)
  errors << "#{where2} で、投稿の block が検査の block より前にある" unless check_at < post_at
  errors << "#{where2} で、検査の block が配備先の personal-post-check を指していない" \
    unless MU.missing(sh_blocks[check_at], ["check=<tool home>/agent-tools/scripts/personal-post-check"]).empty?
end
%w[gate_err "$gate" "$style"].each do |old|
  errors << "#{where2} に、検査を 1 つずつ組み立てる前の形 (#{old}) が残っている" if step2_body.include?(old)
end

step4 = "### 4. 結果を PR に投稿"
where4 = "#{request} の手順 4"
units.call(request, step4, :sentences, "`--marker-kind review-result`").each do |s|
  terms.call("#{where4} の目印の検査を足す文", s, ["`personal-post-check`", "個人 project"])
end
units.call(request, step4, :sentences, "手順 2 と同じく").each { |s| terms.call("#{where4} の「手順 2 と同じく」の文", s, ["`personal-post-check` に通す"]) }
units.call(request, step4, :sentences, "理由に `marker`").each { |s| terms.call("#{where4} の目印で止まる文", s, ["exit 1", "投稿しない"]) }
units.call(request, step4, :sentences, "`marker: unavailable`").each { |s| terms.call("#{where4} の目印の検査を使えない文", s, ["投稿せず"]) }
units.call(request, step4, :sentences, "転記した部分の指摘だけが残って").each { |s| terms.call("#{where4} の転記した部分の文", s, ["exit 3", "`--style-reviewed`"]) }
units.call(request, step4, :sentences, "ほかの repo では").each { |s| terms.call("#{where4} のほかの repo の文", s, ["この検査を当てない", "`--marker-kind` を付けない"]) }

# 3. 運用の workflow
ol = "shared/workflows/personal-project-operating-loop.md"
terms.call("#{ol} の「## Public safety check」の personal-post-check の項目", item.call(ol, "## Public safety check", "`personal-post-check`"),
           ["題名・本文・コメント", "exit 0 のときだけ", "別の呼び出し", "個別に定めている場面", "その手順に従う"])
# PR は 1 つの command の中で、escape の Issue は 1 つの文の中で、script と目印の option の対応を見る (option が別の項目や
# 文に移ると、この script の呼び出しから目印の検査が抜ける)。
command_span.call(ol, "## PR の完了条件", "PR の前の command", ["personal-post-check", "--title", "--body-file", "--marker-kind pr"])
units.call(ol, "## merge 後に見つかった誤り", :sentences, "`--marker-kind escape-issue`").each do |s|
  terms.call("#{ol} の「## merge 後に見つかった誤り」の escape の Issue の文", s, ["`personal-post-check`"])
end

# 4. docs
doc = "docs/post-check.md"
terms.call("#{doc} の「## 組み込み先」の review の項目", item.call(doc, "## 組み込み先", "`personal-review-request`"),
           ["手順 2", "この script を通してから投稿", "`--marker-kind review-result`"])
terms.call("#{doc} の「## 組み込み先」の置き換えない手順の項目", item.call(doc, "## 組み込み先", "`personal-codex-worker`"),
           ["`personal-maintenance-sweep`", "今の手順"])

# 5. 文書が使う option と目印の種類と exit code が、script にある。
src = File.join(root, "shared/scripts/personal-post-check.rb")
if File.file?(src)
  require src
  source = File.read(src, encoding: "UTF-8")
  %w[--body-file --title --marker-kind --style-reviewed].each do |opt|
    errors << "script に option #{opt} が無い" unless source.include?(%("#{opt}"))
  end
  %w[pr review-result escape-issue].each do |kind|
    errors << "script の目印の種類に #{kind} が無い" unless PostCheck::MARKER_KINDS.include?(kind)
  end
  %w[gate gate-warning marker unavailable].each do |reason|
    errors << "script の止める理由に #{reason} が無い" unless PostCheck::REASONS.include?(reason)
  end
  errors << "script の exit code が文書と違う" unless [PostCheck::EXIT_OK, PostCheck::EXIT_STOP, PostCheck::EXIT_USAGE, PostCheck::EXIT_STYLE] == [0, 1, 2, 3]
else
  errors << "shared/scripts/personal-post-check.rb が無い"
end

# 6. eval の case
rel = "shared/skills/personal-review-request/evals/evals.json"
evals = JSON.parse(read.call(rel))["evals"]
found = evals.any? do |c|
  [c["expected_output"], *c["assertions"].map { |a| a["text"] }].any? { |t| t.to_s.include?("personal-post-check") }
end
errors << "#{rel} に personal-post-check に触れる case が無い" unless found

abort "FAIL: post-check-wiring\n  " + errors.uniq.join("\n  ") unless errors.empty?
puts "ok: post-check-wiring"
RUBY
