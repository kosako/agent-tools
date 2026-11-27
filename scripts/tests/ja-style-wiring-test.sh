#!/bin/sh
# 日本語の文章の検査 (personal-ja-style-check) の組み込み (#556 の 2 番目の PR) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (期待挙動は各 skill の evals.json の case。model eval は自動で走らない)。
# - 運用 instruction に「## 日本語の文章」の節があり、4 つの型を避ける原則と、投稿・記録の前に
#   `personal-ja-style-check --stdin` に通して指摘を直すか理由を持つこと、gate ではないことが句としてある。
# - personal-review-request の手順 2 に、personal-post-check でまとめてかける句 (文体の検査がその中でかかること)、
#   指摘だけで投稿を止めない句と command の行 (同じ sh の block で body を定める)、手順 4 に reviewer の指摘を転記した部分は書き換えない句、手順 5 に
#   後続のコメントも通す句がある (#676 から、この 3 つの手順は personal-post-check 経由。exit code の扱いは
#   post-check-wiring-test が見る)。
# - personal-session-handoff の手順 3 に、publish の前に --dry-run の本文を通す句と、保存した節を直さない句と、作業ログの本文を
#   通す句がある。手順 1.5 に、CLI に渡す前に本文を通す句がある (#782)。
# - personal-codex-worker の §4 の brief の一覧に「文章の規則:」の bullet があり、worker が commit の前に通し gate で
#   ないことが句としてある (一覧の外にだけあっても worker には届かない)。§7 に題名と本文を通す句、LAUNCH.md の §9 に
#   post-check の句がある。実行は codex-worker-check-test が検査する。
# - personal-maintenance-sweep の RECORD.md の所見の Issue の節に、題名と本文を先に通す句と command の行があり、その
#   command が gate の command より前にある。FIX.md の検証の節に commit message を通す句、PR の節に題名と本文を通す句と
#   command の行がある。SKILL.md の手順 7 と 7b の要約にも通す句がある。
# 節は見出しの level で次の見出しまでを取り、code block の中の見出し (雛形の `## 主張` など) では区切らない。
# 文書を単位 (節、sh の block、一覧の項目、雛形の block) に分ける読み方と、受ける整形の範囲は lib/markdown_units.rb が持つ。
# この test は、文書を直接 正規表現で読まない。
# - 雛形 (review-request の TEMPLATES.md の markdown の block と、codex-review の RESULT-FORMAT.md の text の block) を
#   検査の script にかけて、bold-label と em-dash が出ない (雛形が型を指示していない)。
# - 3 つの skill の evals.json に、検査に触れる case がある。
# 句は空白を除いて比べる (行の折り返しの位置に依らない)。引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
require "json"
require "open3"

root = ARGV.fetch(0)
errors = []
squash = ->(s) { s.gsub(/\s+/, "") }
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

# 見出し (`#` の数で level を決める) から、同じか上の level の次の見出しまで (code block の中の行は見出しとみなさない)。
# 無ければ nil。見出しは空白を除いて比べる (読み方と、受ける整形の範囲は lib/markdown_units.rb)。
section = ->(text, heading) { MarkdownUnits.section(text, heading) }

check = lambda do |rel, heading, label, phrase|
  body = section.call(read.call(rel), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif !squash.call(body).include?(squash.call(phrase))
    errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い"
  end
end

# 節の中の sh の block (fence ごとに切り出し、行継続をつなげたもの) のどれかに、command がある。空白の数に依らずに比べる。
command = lambda do |rel, heading, label, line|
  body = section.call(read.call(rel), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif MarkdownUnits.sh_blocks(body).none? { |b| MarkdownUnits.missing(b, [line]).empty? }
    errors << "#{rel} の「#{heading}」の sh の block に#{label} (#{line.inspect}) が無い"
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
check.call(request, step2, "まとめてかける句",
           "本文を書いたら、配備済みの `personal-post-check`")
check.call(request, step2, "文体の検査がかかる句",
           "文体の検査 (`personal-ja-style-check`。#556。運用 instruction の「日本語の文章」)")
check.call(request, step2, "止めない句",
           "文体の検査は指摘だけで、投稿を止める gate ではありません。")
check.call(request, step2, "手順 4・5 も同じ句", "手順 4 の結果コメントと手順 5 の後続のコメントも同じです")
# 検査の command の行がある sh の block を、fence ごとに切り出して探す (行継続はつなげてから見る)。その block は、投稿と
# 同じ本文 file (`body`) を自分で定める (別の block や地の文の代入に頼ると、掲載順では未設定の `body` を渡すことになる)。
step2_body = section.call(read.call(request), step2).to_s
check_command = /"\$check"\s+--body-file\s+"\$body"/
check_block = MarkdownUnits.sh_blocks(step2_body).find { |b| b.match?(check_command) }
if check_block.nil?
  errors << "#{request} の手順 2 に検査 (personal-post-check) の command の行がある sh の block が無い"
else
  assign_at = check_block =~ /^[ \t]*body=/
  errors << "#{request} の手順 2 の検査の block で、`body` の代入が検査の command より前に無い" \
    if assign_at.nil? || assign_at > (check_block =~ check_command)
end
check.call(request, "### 4. 結果を PR に投稿", "転記した部分を書き換えない句",
           "文体の指摘で直すのは、依頼元として自分が書く部分 (評価・採用しない理由) だけで、reviewer の指摘を転記した部分は指摘が出ても書き換えない (指摘の中身を変えないため)。")
check.call(request, "### 5. 後続のやり取りも PR 上で", "後続も通す句",
           "後続のコメントも、投稿の前に手順 2 と同じく `personal-post-check` に通します")

handoff = "shared/skills/personal-session-handoff/SKILL.md"
step3 = "### 3. 記録する"
check.call(handoff, step3, "publish の前に通す句",
           "publish の前に、`personal-packet publish --dry-run <issue>` が出す本文を `personal-ja-style-check --stdin` に通します。")
check.call(handoff, step3, "保存した節を直さない句",
           "保存した節は直しません (手順 1.5 で CLI に渡す前の本文に通してあり、保存した後に直すと直接の編集になるため。#782)。")
check.call(handoff, "### 1.5. packet を更新する (local、常に)", "CLI に渡す前に通す句",
           "本文は、CLI に渡す前に `personal-ja-style-check --stdin` に通し、指摘を直すか、そのままにする理由を持つ (保存した節は後から直さないため。手順 3)。")
check.call(handoff, step3, "作業ログを通す句",
           "書き込む本文も、記録の前に `personal-ja-style-check --stdin` に通し、指摘を直すか、そのままにする理由を持ちます。")

worker = "shared/skills/personal-codex-worker/SKILL.md"
brief = section.call(read.call(worker), "## 4. brief")
if brief.nil?
  errors << "#{worker} に「## 4. brief」の節が無い"
else
  # 節の中の最初の一覧の項目 (続きの行を含む) から、名前が「文章の規則:」のものを取る。名前は空白を除いて比べる。
  bullets = MarkdownUnits.lists(brief).first || []
  rule = bullets.find { |b| squash.call(b).start_with?(squash.call("- 文章の規則:")) }
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
check.call(worker, "## 7. PR (orchestrator の操作)", "check 経由で題名と本文を通す句",
           "`check` は題名と本文を `personal-ja-style-check --stdin --json` に通す。")
check.call(worker, "## 7. PR (orchestrator の操作)", "指摘を読む句",
           "文体の指摘は直すか、そのままにする理由を持つ。")
check.call("shared/skills/personal-codex-worker/LAUNCH.md", "## 9. 回収 (fetch) と trailer 検査と PR", "投稿前の検査",
           "受け入れ後に題名と本文を書き、push の前に `personal-post-check` に通す。")

# 雛形を検査にかける。code block の中は検査が読まないので、block の中身を取り出して渡す。取り出せたかは file ごとに
# 別々に見る (連結後の文字列で見ると、TEMPLATES.md だけで両方の目印が揃い、RESULT-FORMAT.md の block が無くても通る)。
extract = lambda do |rel, fence, mark|
  text = MarkdownUnits.blocks(read.call(rel)).select { |info, _| info == fence }.map { |_, body| body + "\n" }.join
  errors << "雛形の code block を取り出せない (#{rel} の #{fence} の block に #{mark.inspect} が無い)" \
    unless MarkdownUnits.missing(text, [mark]).empty?
  text
end
templates = extract.call("shared/skills/personal-review-request/TEMPLATES.md", "markdown", "レビュー依頼") +
            extract.call("shared/skills/personal-codex-review/RESULT-FORMAT.md", "text", "Review process verdict")
unless templates.empty?
  out, err, status = Open3.capture3("ruby", File.join(root, "shared/scripts/personal-ja-style-check.rb"), "--json", "--stdin",
                                    stdin_data: templates)
  if status.exitstatus != 0
    errors << "雛形の検査が exit #{status.exitstatus} で終わった: #{err.lines.first.to_s.strip}"
  else
    hits = JSON.parse(out)["inputs"][0]["findings"].select { |f| %w[bold-label em-dash].include?(f["rule"]) }
    hits.each { |f| errors << "雛形に #{f["rule"]} の指摘がある (#{f["snippet"]})" }
  end
end

sweep = "shared/skills/personal-maintenance-sweep"
issue = "## 所見の Issue"
check.call("#{sweep}/RECORD.md", issue, "先に通す句",
           "題名と本文を書いたら、先に `personal-ja-style-check --stdin` に通し、指摘を直すか理由を持つ (指摘だけで投稿を止めない。#556。運用 instruction の「日本語の文章」)。追跡 Issue の本文と run のコメントも同じ。")
command.call("#{sweep}/RECORD.md", issue, "command の行", %q!{ printf '%s\n\n' "$title" && cat "$body_file"; } | "$style" --stdin!)
# 文体の検査は gate の前 (直してから gate に通す)。両方の command があることを先に求め (無ければ順序を比べずに落とす)、
# あるときだけ順序を比べる。sh の block を順につなげ、空白を除いた上での位置で比べる。
issue_commands = squash.call(MarkdownUnits.sh_blocks(section.call(read.call("#{sweep}/RECORD.md"), issue).to_s).join("\n"))
style_at = issue_commands.index(squash.call('"$style" --stdin'))
gate_at = issue_commands.index(squash.call('"$gate" --stdin'))
if style_at.nil? || gate_at.nil?
  missing = [("文体の検査" if style_at.nil?), ("gate" if gate_at.nil?)].compact.join("と")
  errors << "#{sweep}/RECORD.md の「#{issue}」に#{missing}の command (--stdin) が無い"
elsif style_at > gate_at
  errors << "#{sweep}/RECORD.md の「#{issue}」で、文体の検査の command が gate の command より後にある"
end
check.call("#{sweep}/FIX.md", "## 検証 (累積差分に対して)", "commit message を通す句",
           "commit の前にその file を `personal-ja-style-check --stdin` に通し、指摘を直すか理由を持ちます (指摘だけで止めない。#556。運用 instruction の「日本語の文章」)。")
check.call("#{sweep}/FIX.md", "## PR", "題名と本文を通す句",
           "題名と本文は、書いたら `personal-ja-style-check --stdin` に通し、指摘を直すか理由を持ってから、「検証」の公開する内容の gate に入れます (指摘だけで止めない。#556。運用 instruction の「日本語の文章」)。")
command.call("#{sweep}/FIX.md", "## PR", "command の行", %q!{ printf '%s\n\n' "$title" && cat "$body_file"; } | "$style" --stdin!)
check.call("#{sweep}/SKILL.md", "### 7. 起票する (issues モードだけ)", "通す句",
           "投稿の前に `personal-ja-style-check` (指摘だけ。直すか理由を持つ) と public-safety の gate に通し、gate を通らなければ投稿しない。")
check.call("#{sweep}/SKILL.md", "### 7b. 修正する (fix モードだけ)", "通す句",
           "commit の message と PR の題名・本文は、書いたら先に `personal-ja-style-check` に通す (指摘だけ。直すか理由を持つ。#556)。")

%w[personal-review-request personal-session-handoff personal-codex-worker personal-maintenance-sweep].each do |skill|
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
