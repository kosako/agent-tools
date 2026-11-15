#!/bin/sh
# 人が merge する PR を待つ script (personal-pr-merge-wait) の組み込み (#675 の 2 本目) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (script の挙動は pr-merge-wait-test)。
# 説明の文はそのまま固定しない。項目・文・sh の block ごとに、要る語 (script の名前、option、exit code と結果の語、
# 「merge の後の手順に進む・進まない」) がそろっているかを見る。言い回しを変えても、語が同じ単位に残っていれば通る。節の
# 全体からは探さない (語が別の項目や文に移っただけの変更を通さないため)。文書を単位に分ける読み方は lib/markdown_units.rb。
# - 運用 instruction の「## 待ちと判断の伝え方」に、人に merge を頼んだ PR はこの script で待ち、merge を確かめたら後片付けに
#   進む、人が伝えに来るのを待たない、手順は operating-loop、の項目がある。
# - operating-loop の「## 人が merge する PR を待つ」に、手順 (head を控える、起動の command、人が伝えに来たときも確かめる)、
#   待ち方 (Claude Code は background、Codex は短い上限で foreground)、exit code ごとの扱いがある。exit 0 だけが merge の後の
#   手順 (default branch の更新、branch の整理、配備) に進み、1・2・3 は進まずに人に伝える。workflow の出口にも書いてある。
# - exit code ごとの項目の結果の語と exit code が、script の結果の表 (RESULTS) と合う。文書が使う option が script にある。
# - docs/pr-merge-wait.md の「## 組み込み先」が、運用 instruction と operating-loop を指す。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
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

# 節の中の文のうち、key を含むもの。1 つも無ければ記録する。
sentences = lambda do |rel, heading, key|
  body = section.call(rel, heading)
  next [] if body.nil?
  hits = MU.containing(MU.sentences(body), key)
  errors << "#{rel} の「#{heading}」に、#{key.inspect} を含む文が無い" if hits.empty?
  hits
end

# text の中に、語がすべてある。
terms = lambda do |where, text, words|
  next if text.nil?
  missing = MU.missing(text, words)
  errors << "#{where} に #{missing.map(&:inspect).join("、")} が無い" unless missing.empty?
end

# 1. 運用 instruction
rules = "shared/instructions/personal-operating-rules.md"
wait_heading = "## 待ちと判断の伝え方"
terms.call("#{rules} の「#{wait_heading}」の personal-pr-merge-wait の項目", item.call(rules, wait_heading, "`personal-pr-merge-wait`"),
           ["merge を頼んだ PR", "merge を待ち", "merge を確かめたら後片付けに進む", "伝えに来るのを待たない",
            "`personal-project-operating-loop`", "人が merge する PR を待つ"])

# 2. 運用の workflow
ol = "shared/workflows/personal-project-operating-loop.md"
section.call(ol, "## 人が merge する PR を待つ")
steps = "### 手順"
sentences.call(ol, steps, "merge を頼むときに").each do |s|
  terms.call("#{ol} の「#{steps}」の head を控える文", s, ["review と CI を通した head", "full の OID", "控える"])
end
sentences.call(ol, steps, "伝えに来たときも").each do |s|
  terms.call("#{ol} の「#{steps}」の人が伝えに来たときの文", s, ["同じ script", "確かめてから進む"])
end
# 起動の command は sh の block の中で、空白の数と字下げに依らずに見る。
steps_body = MU.section(read.call(ol), steps).to_s
launch = MU.sh_blocks(steps_body).find { |b| MU.missing(b, ["personal-pr-merge-wait"]).empty? }
if launch.nil?
  errors << "#{ol} の「#{steps}」に、personal-pr-merge-wait を起動する sh の block が無い"
else
  terms.call("#{ol} の「#{steps}」の起動の block", launch,
             ["wait=<tool home>/agent-tools/scripts/personal-pr-merge-wait", %("$wait" "$pr"), %(--expect-head "$head"), %(--repo "$repo")])
end
how = "### 待ち方"
terms.call("#{ol} の「#{how}」の Claude Code の項目", item.call(ol, how, "Claude Code の session"),
           ["background", "通知", "待ちに入る返答", "待ちと判断の伝え方"])
terms.call("#{ol} の「#{how}」の Codex の項目", item.call(ol, how, "Codex の session"),
           ["`--timeout`", "command の時間の上限より短く", "foreground", "人に返す"])
by_exit = "### exit code ごとの扱い"
exit_items = {}
[0, 1, 2, 3].each { |code| exit_items[code] = item.call(ol, by_exit, "exit #{code}") }
terms.call("#{ol} の「#{by_exit}」の exit 0 の項目", exit_items[0],
           ["merge の後の手順に進む", "`git pull --ff-only`", "`personal-merged-branch-cleanup`", "配備"])
[1, 2, 3].each do |code|
  terms.call("#{ol} の「#{by_exit}」の exit #{code} の項目", exit_items[code], ["merge の後の手順に進まず", "人に伝え"])
end
terms.call("#{ol} の「#{by_exit}」の exit 1 の項目", exit_items[1], ["`state:`", "`head:`", "review と CI をやり直して"])
sentences.call(ol, "## この workflow の出口", "人が merge する PR を待つ手順").each do |s|
  terms.call("#{ol} の「## この workflow の出口」の待つ手順の文", s, ["merge の後の手順を終えたか", "人に返した時点で完了"])
end

# 3. 文書の結果の語と exit code、option が、script と合う。
src = File.join(root, "shared/scripts/personal-pr-merge-wait.rb")
if File.file?(src)
  require src
  PrMergeWait::RESULTS.each_value do |code, word|
    terms.call("#{ol} の「#{by_exit}」の exit #{code} の項目 (script の結果の表)", exit_items[code], ["`#{word}`"])
  end
  errors << "script の exit code が文書と違う" \
    unless [PrMergeWait::EXIT_MERGED, PrMergeWait::EXIT_OTHER, PrMergeWait::EXIT_ERROR, PrMergeWait::EXIT_TIMEOUT] == [0, 1, 2, 3]
  %w[--expect-head --repo --timeout].each do |opt|
    errors << "script に option #{opt} が無い" unless PrMergeWait::OPTIONS.include?(opt)
  end
else
  errors << "shared/scripts/personal-pr-merge-wait.rb が無い"
end

# 4. docs
doc = "docs/pr-merge-wait.md"
terms.call("#{doc} の「## 組み込み先」の運用 instruction の項目", item.call(doc, "## 組み込み先", "待ちと判断の伝え方"),
           ["この script で merge を待ち", "後片付けに進む", "#675 の 2 本目"])
terms.call("#{doc} の「## 組み込み先」の operating-loop の項目", item.call(doc, "## 組み込み先", "人が merge する PR を待つ"),
           ["operating-loop", "background", "foreground", "人に返します"])

abort "FAIL: pr-merge-wait-wiring\n  " + errors.uniq.join("\n  ") unless errors.empty?
puts "ok: pr-merge-wait-wiring"
RUBY
