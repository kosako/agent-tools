#!/bin/sh
# personal-codex-worker-run の collect が最終 message の見出しを読む規則 (#806) の self-test。
# result_sections を直に呼び、Issue #806 の期待値の表 (E01〜E28) の行を 1 つずつ見る。停止理由の「なし」の判定 (E29・E30)
# と、gate の後の 2 回目の解析は、collect を通して tests/lib/codex-worker-collect-test.rb が見る。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/test-helpers.sh"

ruby -r"$script_dir/lib/check_helper" - "$repo_root/shared/scripts/personal-codex-worker-run.rb" <<'RUBY'
load ARGV[0]
L = CodexWorkerRun::Launcher.new
H = CodexWorkerRun::Launcher::RESULT_HEADINGS
BODY = { "到達点" => "済んだ。", "判断" => "理由も書いた。", "未完" => "なし。", "停止理由 または 質問" => "なし。",
         "commits" => "abc1234 subject", "次の 1 アクション" => "なし (review 待ち)" }.freeze

# heading_line: 見出しの語から見出しの行を作る (形は呼び出しで決める)
def message(form = ->(h) { "### #{h}" }, body: BODY, extra: {})
  H.map { |h| "#{form.call(h)}\n#{body.fetch(h)}\n#{extra.fetch(h, '')}" }.join
end

def parse(text)
  [L.send(:result_sections, text), nil]
rescue CodexWorkerRun::Stop => e
  [nil, e.code]
end

def accepts(name, text)
  sections, code = parse(text)
  check("#{name}: 受ける (#{code.inspect})", code.nil?)
  sections
end

def rejects(name, text)
  _sections, code = parse(text)
  check("#{name}: result-format で止まる (#{code.inspect})", code == "result-format")
end

expected = H.map { |h| [h, "#{BODY.fetch(h)}\n"] }.to_h
s = accepts("E01 6 行とも ### <語>", message)
check("E01 節の中身", s == expected)
s = accepts("E02 6 行とも語だけ", message(->(h) { h }))
check("E02 語だけでも同じ節に分ける", s == expected)
mixed = message(->(h) { H.index(h).even? ? "### #{h}" : h }, body: BODY.merge("判断" => "  字下げした本文。\n\n空行の後。"))
s = accepts("E03 2 つの形が混ざる", mixed)
check("E03 本文の行 (字下げと空行) はそのまま", s["判断"] == "  字下げした本文。\n\n空行の後。\n")
accepts("E04 語の後ろに半角の空白 2 つ", message(->(h) { h == "判断" ? "判断  " : "### #{h}" }))
accepts("E05 ### <語> の前後に半角の空白", message(->(h) { h == "判断" ? "  ### 判断  " : "### #{h}" }))
accepts("E06 語の前後に tab", message(->(h) { h == "判断" ? "\t判断\t" : "### #{h}" }))
rejects("E07 語の前後に全角の空白 (外さない)", message(->(h) { h == "判断" ? "　判断　" : "### #{h}" }))
rejects("E08 全文が CRLF", message.gsub("\n", "\r\n"))
rejects("E09 #### 判断", message(->(h) { h == "判断" ? "#### 判断" : "### #{h}" }))
rejects("E10 **判断**", message(->(h) { h == "判断" ? "**判断**" : "### #{h}" }))
rejects("E11 ###判断 (空白なし)", message(->(h) { h == "判断" ? "###判断" : "### #{h}" }))
rejects("E12 判断:", message(->(h) { h == "判断" ? "判断:" : "### #{h}" }))
rejects("E13 判断 が丸ごと欠ける", message.sub("### 判断\n", ""))
rejects("E14 正しい 6 つに ### 判断 を 1 行足す", message.sub("### 未完\n", "### 判断\n### 未完\n"))
rejects("E15 判断 が 2 回で未完が無い (計 6 行)", message.sub("### 未完\n", "### 判断\n"))
rejects("E16 判断 と 未完 の順が逆", message.sub("### 判断\n理由も書いた。\n### 未完\nなし。\n", "### 未完\nなし。\n### 判断\n理由も書いた。\n"))
rejects("E17 本文に 判断 だけの行", message(extra: { "到達点" => "判断\n" }))
s = accepts("E18 本文の箇条書きの - 判断", message(extra: { "到達点" => "- 判断\n" }))
check("E18 箇条書きの行は本文に残る", s["到達点"] == "済んだ。\n- 判断\n")
rejects("E19 本文の字下げした 判断 (正しい 6 つに足す)", message(extra: { "到達点" => "  判断\n" }))
rejects("E20 本文の code block の中の 判断 (正しい 6 つに足す)", message(extra: { "到達点" => "```\n判断\n```\n" }))
# E21 (限界): 本物の 判断 が欠け、その位置の code block の中に 判断 があれば受ける。単純な判定のまま、構文は見ない
limit = message.sub("### 判断\n", "```\n判断\n")
s = accepts("E21 限界: 欠けた見出しの位置の code block の行を受ける", limit)
check("E21 その行から後を 判断 の節にする", s && s["判断"].start_with?("理由も書いた。"))
s = accepts("E22 本文の表の | 判断 |", message(extra: { "到達点" => "| 判断 |\n" }))
check("E22 表の行は本文に残る", s["到達点"].include?("| 判断 |"))
rejects("E23 6 つの後の最後の行に 判断", message + "判断\n")
rejects("E24 最後の 次の 1 アクション が語だけで中身が無い", message.sub(/### 次の 1 アクション\n.*\z/m, "次の 1 アクション\n"))
rejects("E25 本文の行頭に ## 判断", message(extra: { "到達点" => "## 判断\n" }))
rejects("E26 本文に entry の見出し", message(extra: { "到達点" => "### 2026-01-01 worker/codex\n" }))
rejects("E27 本文に予約の行 **次の入口**", message(extra: { "到達点" => "**次の入口**\n" }))
rejects("E28 次の 1 アクション の中身が空白だけ", message(body: BODY.merge("次の 1 アクション" => "   ")))

# P6 (案 A): launcher の brief の「最終 message の書式」は、見出しの 6 行を code block で示し、終える前に形を確かめる
src = File.read(ARGV[0])
fmt = src[/## 最終 message の書式\n(.*?)\n\s*TEXT\n/m, 1].to_s.gsub(/^ {8}/, "")
block = fmt[/^```markdown\n(.*?)^```$/m, 1].to_s
check("P6 brief: 見出しの 6 行を code block で、この順に示す", block.lines.map(&:chomp) == H.map { |h| "### #{h}" })
check("P6 brief: 終える前に形を確かめる 1 文がある", fmt.include?("終える前に、見出しの 6 行が `### ` で始まり、この順に 1 回ずつあることを確かめてください"))
exit(@failed.zero? ? 0 : 1)
RUBY
echo "codex-worker-result-headings-test: ok"
