#!/bin/sh
# 運用 instruction の、待ち・判断の伝え方と、無人で起動された session の扱い (#674) が残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない。
# - 「セッションとドキュメント」に、無人で起動された session は開始と終了の手順と参照先の note の読み取りを行わない句がある。
# - 「待ちと判断の伝え方」に、待ちに入る返答に書く 3 つ (何を待つか・見込み・終わったら何をするか) と、判断は 1 件ずつ出す句、
#   壁打ちの round は例外とする句がある。
# - 「test と長時間の command」に、sandbox の中で process の一覧を読めないときは繰り返さずに報告し、起動した側が確かめる句がある。
# - 「参照先」に、無人で起動された session は note を読まない句がある。
# 節は見出しの level で次の見出しまでを取る。句は空白を除いて比べる。引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
root = ARGV.fetch(0)
errors = []
squash = ->(s) { s.gsub(/\s+/, "") }
rel = "shared/instructions/personal-operating-rules.md"
text = File.read(File.join(root, rel), encoding: "UTF-8")

section = lambda do |heading|
  lines = text.lines
  start = lines.index { |l| l.chomp == heading }
  next nil if start.nil?
  level = heading[/\A#+/].size
  body = []
  lines[(start + 1)..-1].each do |l|
    break if l =~ /\A(#+) / && $1.size <= level
    body << l
  end
  body.join
end

check = lambda do |heading, label, phrase|
  body = section.call(heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
    next
  end
  errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い" unless squash.call(body).include?(squash.call(phrase))
end

sessions = "## セッションとドキュメント"
check.call(sessions, "無人で起動された session の句", "別の agent が brief を渡して無人で起動した session (review・監査・相談・委譲された worker)")
check.call(sessions, "brief の範囲だけを行う句", "は、brief の範囲だけを行う。")
check.call(sessions, "開始と終了の手順と note の読み取りを行わない句", "上の開始と終了の手順と、下の「参照先」の note の読み取りは行わない")

waiting = "## 待ちと判断の伝え方"
check.call(waiting, "待ちに入る返答に書く 3 つ", "待ちに入る返答に次の 3 つを書く。\n何を待っているか、どのくらいかかる見込みか、終わったら何をするか。")
check.call(waiting, "待つ対象の例", "別の agent の review や worker、CI、長い test")
check.call(waiting, "判断は 1 件ずつ出す句", "人に判断を頼むときは、1 件ずつ出す")
check.call(waiting, "判断に添えるもの", "何の判断か、選ぶとどうなるか、推奨を、前提を知らない人にも分かる言葉で添える")
check.call(waiting, "壁打ちの round は例外の句", "壁打ち (`personal-grill-me` / `personal-grill-with-docs`) の round は、この限りでない")

runs = "## test と長時間の command (実行環境の守り)"
check.call(runs, "sandbox の中で process を読めないときの句", "sandbox の中で process の一覧を読めないとき (委譲された Codex の worker など) は、同じ command を繰り返さず")
check.call(runs, "確かめられなかったと報告する句", "確かめられ\nなかったことを報告に書く")
check.call(runs, "起動した側が確かめる句", "残った process の確認は、起動した側 (orchestrator) が行う")
check.call(runs, "今までの後始末の句", "終わったら、自分が起動した process が残っていないことを確かめ、残っていれば止める")

check.call("## 参照先", "無人で起動された session は note を読まない句", "無人で起動された session は読まない")

# 節の順: 「待ちと判断の伝え方」は「セッションとドキュメント」の次に在る (session の進め方の決まりとして読める場所)。
order = text.lines.select { |l| l.start_with?("## ") }.map(&:chomp)
i = order.index(sessions)
errors << "「#{waiting}」が「#{sessions}」の次に無い" unless i && order[i + 1] == waiting

unless errors.empty?
  warn errors.map { |e| "FAIL: #{e}" }.join("\n")
  exit 1
end
RUBY

echo "ok: operating-rules-waiting-test"
