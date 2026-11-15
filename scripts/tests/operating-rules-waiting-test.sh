#!/bin/sh
# 運用 instruction の、待ち・判断の伝え方と、無人で起動された session の扱い (#674) が残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない。
# - 「セッションとドキュメント」に、無人で起動された session は brief の範囲だけを行い、開始と終了の手順と参照先の note の読み取りを
#   行わない句がある。
# - 「待ちと判断の伝え方」に、待ちに入る返答に書く 3 つ (何を待つか・見込み・終わったら何をするか) と、判断は 1 件ずつ出す句、
#   壁打ちの round は例外とする句がある。
# - 「test と長時間の command」に、sandbox の中で process の一覧を読めないときは繰り返さずに報告し、起動した側が確かめる句がある。
# - 「参照先」に、無人で起動された session は note を読まない句がある。
# - 起動した側が確かめる手順が、personal-codex-worker の LAUNCH.md の「7. 完了後」に在る (確かめる対象・時点・記録)。
# 規則の句は、条件から処理までを続いた 1 つの句として、文・項目のどれか 1 つの単位の中で探す。前の文を受ける文 (「上の」
# 「その前に」など) は、受ける文から続く文のつながり (helper の sentence_runs) で組にして見る。節の全体からは探さない
# (句が別の単位や分岐へ移っただけの変更を通さないため)。文書を単位に分ける読み方と、受ける整形の範囲は
# lib/markdown_units.rb が持つ (#685)。
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
KIND_NAMES = { items: "項目", sentences: "文", paragraphs: "段落" }.freeze

section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節の中の kind の単位のうち、key を含むものがある。terms があれば、key と同じ単位に terms がすべてある。
check = lambda do |rel, heading, label, kind, key, terms = []|
  body = section.call(rel, heading)
  next if body.nil?
  hits = MU.containing(MU.public_send(kind, body), key)
  if hits.empty?
    errors << "#{rel} の「#{heading}」に、#{label} (#{key.inspect}) を含む#{KIND_NAMES.fetch(kind)}が無い"
  elsif terms.any? && hits.none? { |u| MU.missing(u, terms).empty? }
    errors << "#{rel} の「#{heading}」の#{label}の#{KIND_NAMES.fetch(kind)}に #{MU.missing(hits[0], terms).map(&:inspect).join("、")} が無い"
  end
end

# 節の中で、key を含む文から始まる n 個の文のつながりのどれかに、terms がすべてある。つながりは、key を含む項目 (helper の
# bullets。字下げした子の項目は親と分ける。within が :paragraphs なら段落) の中だけで数える。受ける文を別の項目へ切り出した変更を通さないため (項目の境目をまたいで数えると、
# 切り出しても隣の文のまま通る)。
run_check = lambda do |rel, heading, label, key, n, terms, within = :bullets|
  body = section.call(rel, heading)
  next if body.nil?
  runs = MU.containing(MU.public_send(within, body), key).flat_map { |u| MU.sentence_runs(u, key, n) }
  if runs.empty?
    errors << "#{rel} の「#{heading}」に、#{label} (#{key.inspect}) を含む文が無い"
  elsif runs.none? { |r| MU.missing(r, terms).empty? }
    errors << "#{rel} の「#{heading}」の#{label}の、#{key.inspect} から #{n} 文に #{MU.missing(runs[0], terms).map(&:inspect).join("、")} が無い"
  end
end

rules = "shared/instructions/personal-operating-rules.md"

sessions = "## セッションとドキュメント"
run_check.call(rules, sessions, "無人で起動された session の句",
               "別の agent が brief を渡して無人で起動した session (review・監査・相談・委譲された worker) は、brief の範囲だけを行う", 2,
               ["上の開始と終了の手順と、下の「参照先」の note の読み取りは行わない"])

waiting = "## 待ちと判断の伝え方"
check.call(rules, waiting, "待ちに入る返答に書く 3 つ", :items,
           "裏で動かしたもの (別の agent の review や worker、CI、長い test) を待つときは、待ちに入る返答に次の 3 つを書く。" \
           "何を待っているか、どのくらいかかる見込みか、終わったら何をするか。")
# 壁打ちの例外の「この限り」は、判断を 1 件ずつ出す文を受ける。
run_check.call(rules, waiting, "判断は 1 件ずつ出す句", "人に判断を頼むときは、1 件ずつ出す", 3,
               ["何の判断か、選ぶとどうなるか、推奨を、前提を知らない人にも分かる言葉で添える",
                "前提の揃った質問をまとめて出す壁打ち (`personal-grill-me` / `personal-grill-with-docs`) の round は、この限りでない"])

runs = "## test と長時間の command (実行環境の守り)"
# 起動した側が確かめる文は、process の一覧を読めないときの文を受ける。
run_check.call(rules, runs, "sandbox の中で process を読めないときの句",
               "sandbox の中で process の一覧を読めないとき (委譲された Codex の worker など) は、同じ command を繰り返さず、確かめられなかったことを報告に書く", 2,
               ["残った process の確認は、起動した側 (orchestrator) が行う (手順は `personal-codex-worker`"])
check.call(rules, runs, "今までの後始末の句", :sentences, "終わったら、自分が起動した process が残っていないことを確かめ、残っていれば止める")

# 無人で起動された session は読まない、は note を読む文の括弧の中の文。
run_check.call(rules, "## 参照先", "無人で起動された session は note を読まない句", "セッション着手時にあれば data として読む", 2,
               ["無人で起動された session は読まない"])

# 起動した側の手順 (#681 の review の指摘): worker の完了の後、転記の前に、orchestrator が残った process を確かめる。
wl = "shared/skills/personal-codex-worker/LAUNCH.md"
after = "## 7. 完了後"
check.call(wl, after, "確かめる時点 (転記の前)", :sentences, "続行条件を満たしたら、§8 の前に、worker が残した process が無いかを orchestrator が確かめる")
check.call(wl, after, "対象 (pane の foreground)", :sentences, "worker の pane の foreground: `herdr pane process-info --pane <pane-id>`")
run_check.call(wl, after, "対象 (clone を引数に持つ process) と pattern の escape", "clone を引数に持つ process: `pgrep -f` に clone の絶対 path を渡して探す", 2,
               ["pattern は正規表現として読まれるので、path を `ruby -e 'print Regexp.escape(ARGV.fetch(0))'` で escape してから"])
# 自分では止めない文は、残っていたときの文を受ける。
run_check.call(wl, after, "記録 (残っていたら報告に書く) と自分では止めない句", "残っていたら、pid と command の名前を人への報告に書く", 2,
               ["自分では止めず、止めるかは人が決める"])
check.call(wl, after, "確かめられなかったときの句", :sentences, "確かめる command が失敗したときは、確かめられなかったことを報告に書く")
check.call(wl, after, "転記は止めない句", :sentences, "この確認は報告のためのもので、§8 に進む条件ではない")
run_check.call(wl, after, "見つからない範囲の句", "見つかるのは、pane の foreground と、引数に clone の path を持つ process だけ", 2,
               ["cwd だけが clone の中の background の process は見つからない"])

unless errors.empty?
  warn errors.map { |e| "FAIL: #{e}" }.join("\n")
  exit 1
end
RUBY

echo "ok: operating-rules-waiting-test"
