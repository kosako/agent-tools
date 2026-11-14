#!/bin/sh
# 投稿の前の検査をまとめる script (personal-post-check) の組み込み (#676 の 2 本目) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (script の挙動は post-check-test、期待挙動は各 skill の evals.json の case)。
# - 運用 instruction の「## public safety」に、投稿の前の検査をこの script でまとめてかける句と、exit code ごとの扱い
#   (0 のときだけ投稿、3 は読んでから --style-reviewed、1 と 2 は投稿しない)、検査と投稿を別の呼び出しにする句がある。
# - personal-review-request の手順 2 に、exit code ごとの扱いの句がある。検査の command の block と投稿の command の
#   block が分かれていて (検査の block に gh が無い)、検査の block が先にある。検査を 1 つずつ組み立てる前の形
#   (gate の stderr を file に取る形) が残っていない。手順 4 に、個人 project で --marker-kind review-result を付ける句と、
#   目印で止まったら投稿しない句がある。
# - operating-loop の 3 つの節に、この script を指す句がある。
# - docs/post-check.md に「## 組み込み先」の節がある。
# - 文書が使う option と目印の種類が、script にある (script の名前を変えたのに文書が古いまま、を落とす)。
# - personal-review-request の evals.json に、この script に触れる case がある。
# 節は見出しの level で次の見出しまでを取り、code block の中の見出しでは区切らない。句は空白を除いて比べる (行の
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

section = lambda do |text, heading|
  lines = text.lines
  start = lines.index { |l| l.chomp == heading }
  next nil if start.nil?
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

check = lambda do |rel, heading, label, phrase|
  body = section.call(read.call(rel), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif !squash.call(body).include?(squash.call(phrase))
    errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い"
  end
end

# 1. 運用 instruction
rules = "shared/instructions/personal-operating-rules.md"
ps = "## public safety"
check.call(rules, ps, "まとめてかける宣言",
           "Issue / PR の題名・本文・コメントの投稿の前の検査 (文体、個人 project の目印、public-safety の gate) は、配備済みの `personal-post-check` (`<tool home>/agent-tools/scripts/`) で 1 回にまとめてかける (#676)。")
check.call(rules, ps, "exit 0 の句", "exit 0 のときだけ投稿する。")
check.call(rules, ps, "exit 3 の句",
           "exit 3 は文体の指摘が残っている印で、読んで直すか、そのままにする理由を持って `--style-reviewed` を付けてかけ直す。")
check.call(rules, ps, "exit 1 と 2 の句", "exit 1 と exit 2 では投稿しない。")
check.call(rules, ps, "別の呼び出しの句", "検査と投稿は別の呼び出しにする (出力を読む前に投稿しないため)。")
# もとの gate の宣言は残っている (この script の文で置き換えていない)。
check.call(rules, ps, "gate の宣言",
           "投稿・push の前に public-safety の gate (`--stdin`) に通し、exit 0 で警告が無いときだけ公開する。")

# 2. review の依頼・結果・後続のコメント
request = "shared/skills/personal-review-request/SKILL.md"
step2 = "### 2. 依頼コメントを準備・投稿 (投稿は write-authorized のみ)"
check.call(request, step2, "exit 0 の句",
           "exit 0: 投稿してよい。下の投稿の command を、別の呼び出しで実行します。検査と投稿を 1 つの command に連ねません")
check.call(request, step2, "読まずに付けない句", "`--style-reviewed` を、指摘を読まずに最初から付けません。")
check.call(request, step2, "exit 1 の句", "exit 1: 投稿しません。")
check.call(request, step2, "gate で止まったら人に見せる句",
           "最後の行の理由が `gate` (gate が exit 0 でない) か `gate-warning` (gate の stderr に `public-safety-gate: warning:` の行がある) なら、本文と出力を人に見せて確認を取ります。")
check.call(request, step2, "検査を使えないときの句", "`unavailable` (検査が無い・起動できない) も投稿せず、人に伝えます。")
check.call(request, step2, "exit 2 の句", "exit 2: 入力の誤りです")
check.call(request, step2, "script が無いときの句",
           "`personal-post-check` そのものが無い・起動できないときも、投稿せずに人に伝えます (検査を省いて投稿しません)。")

step2_body = section.call(read.call(request), step2).to_s
blocks = []
step2_body.scan(/^```sh\n(.*?)^```/m) { |m| blocks << m[0] }
check_at = blocks.index { |b| b.include?(%q("$check" --body-file "$body")) }
post_at = blocks.index { |b| b.match?(/^gh pr comment /) }
if check_at.nil?
  errors << "#{request} の手順 2 に検査 (personal-post-check) の sh の block が無い"
elsif post_at.nil?
  errors << "#{request} の手順 2 に投稿 (gh pr comment) の sh の block が無い"
else
  errors << "#{request} の手順 2 で、検査の block に gh の command がある (検査と投稿は別の呼び出し)" if blocks[check_at].match?(/\bgh /)
  errors << "#{request} の手順 2 で、投稿の block が検査の block より前にある" unless check_at < post_at
  errors << "#{request} の手順 2 で、検査の block が配備先の personal-post-check を指していない" \
    unless blocks[check_at].include?("check=<tool home>/agent-tools/scripts/personal-post-check")
end
%w[gate_err "$gate" "$style"].each do |old|
  errors << "#{request} の手順 2 に、検査を 1 つずつ組み立てる前の形 (#{old}) が残っている" if step2_body.include?(old)
end

step4 = "### 4. 結果を PR に投稿"
check.call(request, step4, "post-check に通す句",
           "投稿の前に、手順 2 と同じく本文を `personal-post-check` に通す (文体の検査と public-safety の gate。#556、#413)。")
check.call(request, step4, "転記した部分の指摘だけが残るときの句",
           "転記した部分の指摘だけが残って exit 3 になったときは、それを理由に `--style-reviewed` を付けてかけ直す。")
check.call(request, step4, "目印の検査を足す句",
           "`personal-post-check` に `--marker-kind review-result` を付け、目印の検査もかける")
check.call(request, step4, "目印で止まったら投稿しない句", "目印の検査が通らなければ exit 1 (理由に `marker`) になり、投稿しない。")
check.call(request, step4, "目印の検査を使えないときの句",
           "目印の検査を使えない (`marker: unavailable`、`marker: stop (…)`) ときも投稿せず、人に伝える。")
check.call(request, step4, "ほかの repo では付けない句", "ほかの repo では、この検査を当てない (`--marker-kind` を付けない。")

# 3. 運用の workflow
ol = "shared/workflows/personal-project-operating-loop.md"
check.call(ol, "## Public safety check", "まとめてかける句",
           "Issue / PR の題名・本文・コメントは、配備済みの `personal-post-check` (`<tool home>/agent-tools/scripts/`) で、文体の検査・目印の検査 (下の 2 つの節。個人 project だけ)・gate を 1 回にまとめてかける (#676)。")
check.call(ol, "## Public safety check", "別の呼び出しの句", "exit 0 のときだけ、別の呼び出しで投稿する。")
check.call(ol, "## PR の完了条件", "PR の前の使い方",
           "`personal-post-check --title <題> --body-file <本文> --marker-kind pr` なら、文体の検査と gate も同じ呼び出しでかかる (#676)。")
check.call(ol, "## merge 後に見つかった誤り", "escape の Issue の前の使い方",
           "`personal-post-check` に `--marker-kind escape-issue` を付けると、文体の検査と gate も同じ呼び出しでかかる。")

# 4. docs
doc = "docs/post-check.md"
check.call(doc, "## 組み込み先", "review の手順", "`personal-review-request` の手順 2 (依頼)・4 (結果)・5 (後続) のコメントは、この script を通してから投稿します。")
check.call(doc, "## 組み込み先", "置き換えない手順", "今の手順 (検査を 1 つずつ) のままです。")

# 5. 文書が使う option と目印の種類が、script にある。
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

abort "FAIL: post-check-wiring\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: post-check-wiring"
RUBY
