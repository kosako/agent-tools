#!/bin/sh
# 目印の検査 (personal-work-marker-check) の組み込み (#661) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (期待挙動は script の self-test と、各 skill の手順)。
# - docs/work-markers.md に「対象」(個人 project だけ、ほかの repo では強制しない) と「検査」の節があり、script の 3 つの
#   kind の command がある。kind の一覧は script の定数と一致する。
# - personal-review-request の手順 4 に、結果コメントを通す command の句、ほかの repo では当てない句、verdict を依頼元が
#   書き換えない句がある。
# - operating-loop の「PR の完了条件」に PR を通す command の句と、ほかの repo では強制しない句、「merge 後に見つかった
#   誤り」に escape の Issue を通す command の句がある。
# - personal-codex-worker の §7 に PR を通す句、LAUNCH.md の §9 に command の行があり、その行が文体の検査の command より
#   後、public-safety の gate の command より前にある。
# - personal-maintenance-sweep の FIX.md の「PR」に command の行がある。
# - 手順の 4 か所のどれも、個人 project に限ることを書いている。
# 節は見出しの level で次の見出しまでを取り、code block の中の見出しでは区切らない。句は空白を除いて比べる。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
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

body_of = lambda do |rel, heading|
  body = section.call(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

check = lambda do |rel, heading, label, phrase|
  body = body_of.call(rel, heading)
  next if body.nil?
  errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い" unless squash.call(body).include?(squash.call(phrase))
end

# 1. 約束の docs
markers = "docs/work-markers.md"
check.call(markers, "## 対象", "個人 project に限る句", "個人 project** だけに当てる")
check.call(markers, "## 対象", "ほかの repo では強制しない句", "目印を強制しない")
check.call(markers, "## 対象", "判定できないときの句", "判定できないときも強制しない")
check_heading = "## 検査 (personal-work-marker-check)"
src = File.join(root, "shared/scripts/personal-work-marker-check.rb")
if File.file?(src)
  require src
  errors << "script の kind が想定と違う (#{WorkMarkerCheck::KINDS.inspect})" unless WorkMarkerCheck::KINDS == %w[pr review-result escape-issue]
  WorkMarkerCheck::KINDS.each { |k| check.call(markers, check_heading, "kind #{k} の command", "--kind #{k} --stdin") }
else
  errors << "shared/scripts/personal-work-marker-check.rb が無い"
end

# 2. review の結果コメント
rr = "shared/skills/personal-review-request/SKILL.md"
rr4 = "### 4. 結果を PR に投稿"
check.call(rr, rr4, "結果コメントを通す句", "`personal-work-marker-check --kind review-result --stdin`")
check.call(rr, rr4, "ほかの repo では当てない句", "ほかの repo では、この検査を当てない")
check.call(rr, rr4, "verdict を書き換えない句", "依頼元が verdict を書き換えず")

# 3. 運用の docs
ol = "shared/workflows/personal-project-operating-loop.md"
check.call(ol, "## PR の完了条件", "PR を通す句", "`personal-work-marker-check --kind pr --stdin`")
check.call(ol, "## PR の完了条件", "ほかの repo では強制しない句", "目印も検査も強制しない")
check.call(ol, "## merge 後に見つかった誤り", "escape の Issue を通す句", "`personal-work-marker-check --kind escape-issue --stdin`")
check.call(ol, "## merge 後に見つかった誤り", "ほかの repo では label を作らない句", "label を作らず")

# 4. Codex worker の PR
ws = "shared/skills/personal-codex-worker/SKILL.md"
ws7 = "## 7. PR (orchestrator の操作)"
check.call(ws, ws7, "PR を通す句", "`personal-work-marker-check --kind pr --stdin`")
wl = "shared/skills/personal-codex-worker/LAUNCH.md"
wl9 = "## 9. 回収 (fetch) と trailer 検査と PR"
marker_cmd = '| "$marker" --kind pr --stdin'
style_cmd = '| "$style" --stdin'
gate_cmd = '| "$gate" --stdin'
check.call(wl, wl9, "PR を通す command の行", marker_cmd)
if (b = section.call(read.call(wl), wl9))
  m, s, g = [marker_cmd, style_cmd, gate_cmd].map { |c| b.index(c) }
  errors << "#{wl} の §9 で、目印の検査の command が文体の検査の後・gate の前にない" unless m && s && g && s < m && m < g
end

# 5. sweep の fix の PR
check.call("shared/skills/personal-maintenance-sweep/FIX.md", "## PR", "PR を通す command の行", marker_cmd)

# 6. 手順の 4 か所は、個人 project に限る。節にはもともと「個人 project」の語がありうるので、検査を呼ぶ文の頭の句で見る。
scope = "(運用 instruction の「個人 project の GitHub の操作と merge」の対象と同じ判定) では、"
[[rr, rr4, "個人 project #{scope}gate の前に本文を"],
 [ol, "## PR の完了条件", "個人 project では、題の末尾の `(#<Issue>)`"],
 [ws, ws7, "個人 project の PR では、題名と本文を `personal-work-marker-check --kind pr --stdin`"],
 [wl, wl9, "個人 project の PR #{scope}続けて題名と本文を"],
 ["shared/skills/personal-maintenance-sweep/FIX.md", "## PR", "個人 project の repo #{scope}題名と本文を"]].each do |(rel, h, phrase)|
  check.call(rel, h, "個人 project に限る句", phrase)
end

if errors.empty?
  puts "ok: work-marker-wiring"
else
  errors.each { |e| warn "FAIL: #{e}" }
  exit 1
end
RUBY
