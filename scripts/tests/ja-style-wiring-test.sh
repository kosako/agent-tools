#!/bin/sh
# 日本語の文章の検査 (personal-ja-style-check) の組み込み (#556 の 2 番目の PR) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (期待挙動は各 skill の evals.json の case。model eval は自動で走らない)。
# - 運用 instruction に「## 日本語の文章」の節があり、4 つの型を避ける原則と、投稿・記録の前に
#   `personal-ja-style-check --stdin` に通して指摘を直すか理由を持つこと、gate ではないことが句としてある。
# - personal-review-request の手順 2 に、gate の前に通す句と指摘だけで投稿を止めない句と command の行、手順 4 に
#   reviewer の指摘を転記した部分は書き換えない句、手順 5 に後続のコメントも通す句がある。
# - personal-session-handoff の手順 3 に、publish の前に --dry-run の本文を通す句と、作業ログの本文を通す句がある。
# - personal-codex-worker の §4 の brief の一覧に「文章の規則:」の bullet があり、worker が commit の前に通し gate で
#   ないことが句としてある (一覧の外にだけあっても worker には届かない)。§7 に題名と本文を通す句、LAUNCH.md の §9 に
#   command の行がある。
# - 雛形 (review-request の TEMPLATES.md の markdown の block と、codex-review の RESULT-FORMAT.md の text の block) を
#   検査の script にかけて、bold-label と em-dash が出ない (雛形が型を指示していない)。
# - 3 つの skill の evals.json に、検査に触れる case がある。
# 句は空白を除いて比べる (行の折り返しの位置に依らない)。引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
require "json"
require "open3"

root = ARGV.fetch(0)
errors = []
squash = ->(s) { s.gsub(/\s+/, "") }
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

# 見出し (`#` の数で level を決める) から、同じか上の level の次の見出しまで。
section = lambda do |text, heading|
  level = heading[/\A#+/].size
  text[/^#{Regexp.escape(heading)}\n(.*?)(?=^\#{1,#{level}} |\z)/m, 1]
end

check = lambda do |rel, heading, label, phrase|
  body = section.call(read.call(rel), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif !squash.call(body).include?(squash.call(phrase))
    errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い"
  end
end

rules = "shared/instructions/personal-operating-rules.md"
ja = "## 日本語の文章"
check.call(rules, ja, "ダッシュの原則", "文の区切りにダッシュ (`—` `―` `–`) を使わず、読点・句点・括弧で区切る。")
check.call(rules, ja, "太字の見出しの原則", "太字の見出しに中身を続ける箇条書き (`- **見出し**: 中身`) にせず、地の文で書くか見出しを外す。")
check.call(rules, ja, "長い文の原則", "長い文を連ねない (1 文は 60 字を目安にし、120 字を超えたら 2 つに分ける)。")
check.call(rules, ja, "打ち消しの原則", "文末の打ち消しを 3 文続けない。")
check.call(rules, ja, "慣用の原則", "「〜側に倒す」「黙って〜する」「前提が崩れる」の慣用は平易に言う。")
check.call(rules, ja, "通す宣言",
           "投稿・記録の前に、本文を配備済みの `personal-ja-style-check --stdin` (`<tool home>/agent-tools/scripts/`) に通し、指摘を直すか、そのままにする理由を持つ。")
check.call(rules, ja, "gate ではない宣言",
           "指摘だけで gate ではなく (指摘があっても exit 0)、公開の前の public-safety の gate (下の「public safety」) とは別の口。")

request = "shared/skills/personal-review-request/SKILL.md"
step2 = "### 2. 依頼コメントを準備・投稿 (投稿は write-authorized のみ)"
check.call(request, step2, "gate の前に通す句",
           "本文を書いたら、まず `personal-ja-style-check --stdin` に通します (#556。運用 instruction の「日本語の文章」)。")
check.call(request, step2, "止めない句",
           "指摘だけで投稿を止めません (指摘があっても exit 0): 指摘を読んで直すか、そのままにする理由を持ってから、下の gate に進みます。")
check.call(request, step2, "手順 4・5 も同じ句", "手順 4 の結果コメントと手順 5 の後続のコメントも同じです。")
check.call(request, step2, "command の行", %q!"$style" --stdin < "$body"!)
check.call(request, "### 4. 結果を PR に投稿", "転記した部分を書き換えない句",
           "文体の指摘で直すのは、依頼元として自分が書く部分 (評価・採用しない理由) だけで、reviewer の指摘を転記した部分は指摘が出ても書き換えない (指摘の中身を変えないため)。")
check.call(request, "### 5. 後続のやり取りも PR 上で", "後続も通す句",
           "後続のコメントも、投稿の前に手順 2 と同じ 2 つの検査 (`personal-ja-style-check --stdin` と public-safety の gate) に通します。")

handoff = "shared/skills/personal-session-handoff/SKILL.md"
step3 = "### 3. 記録する"
check.call(handoff, step3, "publish の前に通す句",
           "publish の前に、`personal-packet publish --dry-run <issue>` が出す本文を `personal-ja-style-check --stdin` に通し、指摘があれば自分が書いた最新節と `次の入口` を直します (過去の節は書き換えない。指摘だけで publish を止めない。#556。運用 instruction の「日本語の文章」)。")
check.call(handoff, step3, "作業ログを通す句",
           "書き込む本文も、記録の前に `personal-ja-style-check --stdin` に通し、指摘を直すか、そのままにする理由を持ちます。")

worker = "shared/skills/personal-codex-worker/SKILL.md"
brief = section.call(read.call(worker), "## 4. brief")
if brief.nil?
  errors << "#{worker} に「## 4. brief」の節が無い"
else
  # 節の中の最初の一覧 (最初の「- 」から空行の前まで) を bullet に分け、続きの行は前の bullet に足す。
  lines = brief.split("\n")
  first = lines.index { |l| l.start_with?("- ") }
  list = first ? lines[first..-1] : []
  list = list[0, list.index { |l| l =~ /\A\s*\z/ } || list.length]
  bullets = []
  list.each { |l| l.start_with?("- ") ? bullets << l.dup : bullets[-1] << l }
  rule = bullets.find { |b| b.start_with?("- 文章の規則:") }
  if rule.nil?
    errors << "#{worker} の brief の一覧に「文章の規則:」の bullet が無い"
  else
    {
      "避ける型" => "運用 instruction の「日本語の文章」の型 (ダッシュの区切り、太字の見出しの箇条書き、長い文の連続、打ち消しの連続と慣用) を避けて書く。",
      "commit の前に通す" => "commit の前に message を配備済みの `personal-ja-style-check --stdin` (`~/.codex/agent-tools/scripts/personal-ja-style-check`) に通し、指摘を直すか理由を持つ (指摘だけで gate ではなく、指摘があっても exit 0。#556)。",
    }.each do |label, phrase|
      errors << "#{worker} の文章の規則の bullet に#{label}の句が無い" unless squash.call(rule).include?(squash.call(phrase))
    end
  end
end
check.call(worker, "## 7. PR (orchestrator の操作)", "題名と本文を通す句",
           "PR の題名と本文は先に書き、`personal-ja-style-check --stdin` に通して指摘を直すか理由を持ってから gate に入れる (指摘だけで止めない。#556)。")
check.call("shared/skills/personal-codex-worker/LAUNCH.md", "## 9. 回収 (fetch) と trailer 検査と PR", "command の行",
           %q!{ printf '%s\n\n' "$title" && cat "$body_file"; } | "$style" --stdin!)

# 雛形を検査にかける。code block の中は検査が読まないので、block の中身を取り出して渡す。
templates = +""
read.call("shared/skills/personal-review-request/TEMPLATES.md").scan(/^```markdown\n(.*?)^```/m) { |m| templates << m[0] << "\n" }
read.call("shared/skills/personal-codex-review/RESULT-FORMAT.md").scan(/^```text\n(.*?)^```/m) { |m| templates << m[0] << "\n" }
if templates.include?("レビュー依頼") && templates.include?("Review process verdict")
  out, err, status = Open3.capture3("ruby", File.join(root, "shared/scripts/personal-ja-style-check.rb"), "--json", "--stdin",
                                    stdin_data: templates)
  if status.exitstatus != 0
    errors << "雛形の検査が exit #{status.exitstatus} で終わった: #{err.lines.first.to_s.strip}"
  else
    hits = JSON.parse(out)["inputs"][0]["findings"].select { |f| %w[bold-label em-dash].include?(f["rule"]) }
    hits.each { |f| errors << "雛形に #{f["rule"]} の指摘がある (#{f["snippet"]})" }
  end
else
  errors << "雛形の code block を取り出せない (TEMPLATES.md の markdown の block か RESULT-FORMAT.md の text の block が無い)"
end

%w[personal-review-request personal-session-handoff personal-codex-worker].each do |skill|
  rel = "shared/skills/#{skill}/evals/evals.json"
  evals = JSON.parse(read.call(rel))["evals"]
  found = evals.any? do |c|
    [c["expected_output"], *c["assertions"].map { |a| a["text"] }].any? { |t| t.to_s.include?("personal-ja-style-check") }
  end
  errors << "#{rel} に personal-ja-style-check に触れる case が無い" unless found
end

abort "FAIL: ja-style-wiring\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: ja-style-wiring"
RUBY
