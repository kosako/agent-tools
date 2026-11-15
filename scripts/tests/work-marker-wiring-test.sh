#!/bin/sh
# 目印の検査 (personal-work-marker-check) の組み込み (#661) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (期待挙動は script の self-test と、各 skill の手順)。
# 説明の文はそのまま固定しない。項目・文・段落・sh の block ごとに、要る語がそろっているかを見る。言い回しを変えても、語が
# 同じ単位に残っていれば通る。節の全体からは探さない (語が別の項目や文に移っただけの変更を通さないため)。文書を単位に
# 分ける読み方と、受ける整形の範囲 (空白の数、折り返し、見出しの # の後ろの空白、fence の字下げ、sh の行継続) は、
# lib/markdown_units.rb が持つ (#685)。個人 project に限る条件は、判定の参照 (括弧の中) まで含めた 1 つの句で見る。条件の語は
# 参照の中にもあるので、語だけを探すと、条件を消しても通ってしまう。
# - docs/work-markers.md の「対象」に、目印と検査は個人 project だけに当てる文、ほかの repo と判定できないときは強制しない
#   項目がある。「検査」の sh の block に、script の 3 つの kind の command がある。kind の一覧は script の定数と一致する。
# - personal-review-request の手順 4 に、個人 project で目印の検査もかける段落 (post-check の --marker-kind と、同じ検査の
#   command)、ほかの repo では当てない文、verdict を依頼元が書き換えない文がある。
# - operating-loop の「PR の完了条件」に、個人 project の PR を作る前に検査を通す項目と、ほかの repo では強制しない項目が
#   ある。「merge 後に見つかった誤り」に、escape の Issue を立てる前に通す文と、ほかの repo では label を作らない文がある。
# - personal-codex-worker の §7 に、個人 project の PR を通す文がある。LAUNCH.md の §9 に、個人 project の PR を通す文と、
#   command の sh の block があり、その block が文体の検査の block より後、public-safety の gate の block より前にある。
# - personal-maintenance-sweep の FIX.md の「PR」に、個人 project の repo で通す項目と、command の sh の block がある。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
# encoding: UTF-8
root = ARGV.fetch(0)
errors = []
MU = MarkdownUnits
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }
KIND_NAMES = { items: "項目", paragraphs: "段落", sentences: "文" }.freeze
# 個人 project に限る条件と、その判定の参照。条件の語は参照の括弧の中にもあるので、条件の語だけを探すと、条件を消しても
# 括弧の中の語で通ってしまう。条件と参照を 1 つの句として、検査を呼ぶ句の頭で見る。
SCOPE = "(運用 instruction の「個人 project の GitHub の操作と merge」の対象と同じ判定) "

# 節の本文。無ければ記録して nil。
section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節の中の単位 (kind は :items / :paragraphs / :sentences) のうち、key を含むものがちょうど 1 つある。その単位 (無ければ nil)。
unit = lambda do |rel, heading, kind, key|
  body = section.call(rel, heading)
  next nil if body.nil?
  hits = MU.containing(MU.public_send(kind, body), key)
  if hits.size != 1
    errors << "#{rel} の「#{heading}」で、#{key.inspect} を含む#{KIND_NAMES.fetch(kind)}が #{hits.size} 個ある (1 個のはず)"
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

# 節の sh の block のうち、command を含むものがちょうど 1 つある。その block の番号 (無ければ nil)。空白と行継続に依らずに比べる。
sh_block = lambda do |rel, heading, command|
  body = section.call(rel, heading)
  next nil if body.nil?
  blocks = MU.sh_blocks(body)
  hits = blocks.each_index.select { |i| MU.missing(blocks[i], [command]).empty? }
  if hits.size != 1
    errors << "#{rel} の「#{heading}」で、#{command.inspect} を含む sh の block が #{hits.size} 個ある (1 個のはず)"
    next nil
  end
  hits[0]
end

# 1. 約束の docs
markers = "docs/work-markers.md"
target = "## 対象"
terms.call("#{markers} の「#{target}」の当てる範囲の文", unit.call(markers, target, :sentences, "だけに当てる"),
           ["目印", "「検査」", "**個人 project**"])
terms.call("#{markers} の「#{target}」のほかの repo の項目", unit.call(markers, target, :items, "目印を強制しない"),
           ["会社や別の組織の repo", "他人の repo"])
terms.call("#{markers} の「#{target}」の判定できないときの項目", unit.call(markers, target, :items, "判定できないとき"),
           ["強制しない"])
check_heading = "## 検査 (personal-work-marker-check)"
src = File.join(root, "shared/scripts/personal-work-marker-check.rb")
if File.file?(src)
  require src
  errors << "script の kind が想定と違う (#{WorkMarkerCheck::KINDS.inspect})" unless WorkMarkerCheck::KINDS == %w[pr review-result escape-issue]
  WorkMarkerCheck::KINDS.each { |k| sh_block.call(markers, check_heading, %("$marker" --kind #{k} --stdin)) }
else
  errors << "shared/scripts/personal-work-marker-check.rb が無い"
end

# 2. review の結果コメント
rr = "shared/skills/personal-review-request/SKILL.md"
rr4 = "### 4. 結果を PR に投稿"
terms.call("#{rr} の手順 4 の目印の検査の段落", unit.call(rr, rr4, :paragraphs, "`--marker-kind review-result`"),
           ["個人 project #{SCOPE}では、`personal-post-check` に `--marker-kind review-result` を付け、目印の検査もかける",
            "`personal-work-marker-check --kind review-result --stdin`"])
terms.call("#{rr} の手順 4 のほかの repo の文", unit.call(rr, rr4, :sentences, "ほかの repo では"), ["この検査を当てない"])
terms.call("#{rr} の手順 4 の verdict の文", unit.call(rr, rr4, :sentences, "依頼元が verdict を書き換えず"), ["投稿せずに人に伝える"])

# 3. 運用の docs
ol = "shared/workflows/personal-project-operating-loop.md"
done_h = "## PR の完了条件"
terms.call("#{ol} の「#{done_h}」の目印の項目", unit.call(ol, done_h, :items, "`personal-work-marker-check --kind pr --stdin`"),
           ["個人 project では、題の末尾の `(#<Issue>)`", "`Closes #<Issue>`", "PR を作る前に", "exit 0 のときだけ作る"])
terms.call("#{ol} の「#{done_h}」のほかの repo の項目", unit.call(ol, done_h, :items, "目印も検査も"),
           ["会社や別の組織の repo", "他人の repo", "強制しない"])
escape_h = "## merge 後に見つかった誤り"
terms.call("#{ol} の「#{escape_h}」の escape の Issue を通す文", unit.call(ol, escape_h, :sentences, "`personal-work-marker-check --kind escape-issue --stdin`"),
           ["立てる前に", "本文", "exit 0 のときだけ立てる"])
terms.call("#{ol} の「#{escape_h}」のほかの repo の文", unit.call(ol, escape_h, :sentences, "label を作らず"),
           ["会社や別の組織の repo", "他人の repo", "その repo の決まりに従う"])

# 4. Codex worker の PR
ws = "shared/skills/personal-codex-worker/SKILL.md"
ws7 = "## 7. PR (orchestrator の操作)"
terms.call("#{ws} の §7 の目印の文", unit.call(ws, ws7, :sentences, "`personal-work-marker-check --kind pr --stdin`"),
           ["個人 project の PR では、題名と本文を", "exit 0 のときだけ gate に進む"])
wl = "shared/skills/personal-codex-worker/LAUNCH.md"
wl9 = "## 9. 回収 (fetch) と trailer 検査と PR"
terms.call("#{wl} の §9 の目印の文", unit.call(wl, wl9, :sentences, "目印の検査に通す"), ["個人 project の PR #{SCOPE}では、続けて題名と本文を"])
style_at = sh_block.call(wl, wl9, '| "$style" --stdin')
marker_at = sh_block.call(wl, wl9, '| "$marker" --kind pr --stdin')
gate_at = sh_block.call(wl, wl9, '| "$gate" --stdin')
if style_at && marker_at && gate_at && !(style_at < marker_at && marker_at < gate_at)
  errors << "#{wl} の §9 で、目印の検査の block が文体の検査の block の後・gate の block の前にない"
end

# 5. sweep の fix の PR
fix = "shared/skills/personal-maintenance-sweep/FIX.md"
terms.call("#{fix} の「## PR」の目印の項目", unit.call(fix, "## PR", :items, "目印の検査にも通し"),
           ["個人 project の repo #{SCOPE}では、題名と本文を", "exit 0 のときだけ gate に入れます"])
sh_block.call(fix, "## PR", '| "$marker" --kind pr --stdin')

if errors.empty?
  puts "ok: work-marker-wiring"
else
  errors.each { |e| warn "FAIL: #{e}" }
  exit 1
end
RUBY
