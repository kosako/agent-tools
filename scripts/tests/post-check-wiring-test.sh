#!/bin/sh
# 投稿の前の検査をまとめる script (personal-post-check) の組み込み (#676 の 2 本目) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (script の挙動は post-check-test、期待挙動は各 skill の evals.json の case)。
# 説明の文はそのまま固定しない。項目 (「- 」で始まる行とその続き)・文 (「。」まで)・段落・1 つの command (code span) ごとに、
# 要る語 (script の名前、option、exit code と「投稿する・しない」、理由の語) がそろっているかを見る。言い回しを変えても、
# 語が同じ単位に残っていれば通る。節の全体からは探さない (語が別の項目や文に移っただけの変更を通さないため)。
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
# 節は見出しの level で次の見出しまでを取り、code block の中の見出しでは区切らない。語は空白を除いて比べる (行の
# 折り返しの位置に依らない)。引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
require "json"

root = ARGV.fetch(0)
errors = []
squash = ->(s) { s.gsub(/\s+/, "") }
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

section = lambda do |rel, heading|
  lines = read.call(rel).lines
  start = lines.index { |l| l.chomp == heading }
  if start.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
    next nil
  end
  level = heading[/\A#+/].size
  fence = false
  body = []
  lines[(start + 1)..-1].each do |l|
    fence = !fence if l =~ /\A\s*```/
    break if !fence && l =~ /\A(#+) / && $1.size <= level
    body << l
  end
  body.join
end

# 節の中の項目 (「- 」で始まる行と、字下げした続きの行。code block の中は見ない) のうち、key を含むものを 1 つ取る。
item = lambda do |rel, heading, key|
  body = section.call(rel, heading)
  next nil if body.nil?
  items = []
  open = false
  fence = false
  body.each_line do |l|
    if l =~ /\A\s*```/
      fence = !fence
      open = false
      next
    end
    next if fence
    if l.start_with?("- ")
      items << l.dup
      open = true
    elsif open && l =~ /\A\s+\S/
      items[-1] << l
    else
      open = false
    end
  end
  hits = items.select { |i| squash.call(i).include?(squash.call(key)) }
  if hits.size != 1
    errors << "#{rel} の「#{heading}」で、#{key.inspect} を含む項目が #{hits.size} 個ある (1 個のはず)"
    next nil
  end
  hits[0]
end

# 節の中の文 (「。」まで) のうち、key を含むものをすべて取る。
sentences = lambda do |rel, heading, key|
  body = section.call(rel, heading)
  next [] if body.nil?
  hits = squash.call(body).split("。").select { |s| s.include?(squash.call(key)) }
  errors << "#{rel} の「#{heading}」に、#{key.inspect} を含む文が無い" if hits.empty?
  hits
end

# 節の中の段落 (空行で区切る。code block は除く) のうち、key を含むものをすべて取る。
paragraphs = lambda do |rel, heading, key|
  body = section.call(rel, heading)
  next [] if body.nil?
  paras = [+""]
  fence = false
  body.each_line do |l|
    if l =~ /\A\s*```/
      fence = !fence
      paras << +""
      next
    end
    next if fence
    l.strip.empty? ? paras << +"" : paras[-1] << l
  end
  hits = paras.select { |para| squash.call(para).include?(squash.call(key)) }
  errors << "#{rel} の「#{heading}」に、#{key.inspect} を含む段落が無い" if hits.empty?
  hits
end

# 節の中の code span (1 行の中の `…`) のうち、語をすべて含むものが 1 つはある (1 つの command の中で語の組を見る)。
command_span = lambda do |rel, heading, label, words|
  body = section.call(rel, heading)
  next if body.nil?
  spans = body.scan(/`([^`\n]+)`/).flatten
  errors << "#{rel} の「#{heading}」に、#{label} (#{words.join(" と ")} を含む 1 つの command) が無い" \
    unless spans.any? { |span| words.all? { |w| span.include?(w) } }
end

# text の中に、語がすべてある。
terms = lambda do |where, text, words|
  next if text.nil?
  missing = words.reject { |w| squash.call(text).include?(squash.call(w)) }
  errors << "#{where} に #{missing.map(&:inspect).join("、")} が無い" unless missing.empty?
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
paragraphs.call(request, step2, "`personal-ja-style-check`").each do |para|
  terms.call("#{where2} の、かかる検査を書く段落", para, ["`personal-post-check`", "public-safety の gate"])
end
terms.call("#{where2} の exit 0 の項目", item.call(request, step2, "exit 0:"), ["投稿してよい", "別の呼び出し", "連ねません"])
terms.call("#{where2} の exit 3 の項目", item.call(request, step2, "exit 3:"),
           ["`--style-reviewed`", "指摘を読んで", "gate ではありません", "読まずに"])
terms.call("#{where2} の exit 1 の項目", item.call(request, step2, "exit 1:"),
           ["投稿しません", "`gate`", "`gate-warning`", "`unavailable`", "`marker`", "人に見せて"])
terms.call("#{where2} の exit 2 の項目", item.call(request, step2, "exit 2:"), ["入力の誤り"])
terms.call("#{where2} の script が無いときの項目", item.call(request, step2, "そのものが無い"), ["投稿せず", "省いて投稿しません"])

step2_body = section.call(request, step2).to_s
blocks = []
step2_body.scan(/^```sh\n(.*?)^```/m) { |m| blocks << m[0] }
check_at = blocks.index { |b| b.include?(%q("$check" --body-file "$body")) }
post_at = blocks.index { |b| b.match?(/^gh pr comment /) }
if check_at.nil?
  errors << "#{where2} に検査 (personal-post-check) の sh の block が無い"
elsif post_at.nil?
  errors << "#{where2} に投稿 (gh pr comment) の sh の block が無い"
else
  errors << "#{where2} で、検査の block に gh の command がある (検査と投稿は別の呼び出し)" if blocks[check_at].match?(/\bgh /)
  errors << "#{where2} で、投稿の block が検査の block より前にある" unless check_at < post_at
  errors << "#{where2} で、検査の block が配備先の personal-post-check を指していない" \
    unless blocks[check_at].include?("check=<tool home>/agent-tools/scripts/personal-post-check")
end
%w[gate_err "$gate" "$style"].each do |old|
  errors << "#{where2} に、検査を 1 つずつ組み立てる前の形 (#{old}) が残っている" if step2_body.include?(old)
end

step4 = "### 4. 結果を PR に投稿"
where4 = "#{request} の手順 4"
sentences.call(request, step4, "`--marker-kind review-result`").each do |s|
  terms.call("#{where4} の目印の検査を足す文", s, ["`personal-post-check`", "個人 project"])
end
sentences.call(request, step4, "手順 2 と同じく").each { |s| terms.call("#{where4} の「手順 2 と同じく」の文", s, ["`personal-post-check` に通す"]) }
sentences.call(request, step4, "理由に `marker`").each { |s| terms.call("#{where4} の目印で止まる文", s, ["exit 1", "投稿しない"]) }
sentences.call(request, step4, "`marker: unavailable`").each { |s| terms.call("#{where4} の目印の検査を使えない文", s, ["投稿せず"]) }
sentences.call(request, step4, "転記した部分の指摘だけが残って").each { |s| terms.call("#{where4} の転記した部分の文", s, ["exit 3", "`--style-reviewed`"]) }
sentences.call(request, step4, "ほかの repo では").each { |s| terms.call("#{where4} のほかの repo の文", s, ["この検査を当てない", "`--marker-kind` を付けない"]) }

# 3. 運用の workflow
ol = "shared/workflows/personal-project-operating-loop.md"
terms.call("#{ol} の「## Public safety check」の personal-post-check の項目", item.call(ol, "## Public safety check", "`personal-post-check`"),
           ["題名・本文・コメント", "exit 0 のときだけ", "別の呼び出し", "個別に定めている場面", "その手順に従う"])
# PR は 1 つの command の中で、escape の Issue は 1 つの文の中で、script と目印の option の対応を見る (option が別の項目や
# 文に移ると、この script の呼び出しから目印の検査が抜ける)。
command_span.call(ol, "## PR の完了条件", "PR の前の command", ["personal-post-check", "--title", "--body-file", "--marker-kind pr"])
sentences.call(ol, "## merge 後に見つかった誤り", "`--marker-kind escape-issue`").each do |s|
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
