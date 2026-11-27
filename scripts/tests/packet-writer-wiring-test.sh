#!/bin/sh
# agent の packet の書き手を worker-update に通す規則 (#782) が、文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (操作の挙動は packet-worker-update-test と exhaustive-decisions-test、handoff の順序は
# worker-request-order-test)。説明の文はそのまま固定しない。項目・文ごとに、要る語がそろっているかを見る。節の全体からは
# 探さない (語が別の項目や文に移っただけの変更を通さないため)。文書を単位に分ける読み方は lib/markdown_units.rb。
# - handoff の手順 1.5 に、worker-update で書き file を直接編集しない文、digest を先に取ってから読む文、PR を出した worker の
#   順 (open のうちに entry、続けて review)、拒まれたときに直接の編集に戻らない文、digest_mismatch のやり直しの条件 (結果が
#   載っていればやり直さず、次の入口が違っても draft に留める) の文、stale_temp の一時 file に触れない項目、委譲の例外も操作で書く文がある。frontmatter の updated を手で書く古い指示が無い。
# - handoff の手順 5 に、次の入口を書けなかったとき (review の packet、拒まれた) は書けなかったことを添え、違いは確かめられた
#   ときだけ伝える文がある。手順 3 に、手順 1.5 で書けなかったときは dry-run を照らし、最新節が今回の結果でなければ publish
#   しない文がある。
# - docs/agent-packets.md の「## tooling(`personal-packet`)」に、残る直接の書き手を名指しして窓が残ると書いた項目がある。
# - operating-loop の割当の記録に、作成の後は round で足し、直接編集しない文がある。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
root = ARGV.fetch(0)
errors = []
MU = MarkdownUnits
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節の中の単位 (文か字下げした項目) のうち、key を含むものがちょうど 1 つある。その単位 (無ければ nil)。
one = lambda do |rel, heading, kind, key|
  body = section.call(rel, heading)
  next nil if body.nil?
  units = kind == :sentences ? MU.sentences(body) : MU.bullets(body)
  hits = MU.containing(units, key)
  if hits.size != 1
    errors << "#{rel} の「#{heading}」で、#{key.inspect} を含む#{kind == :sentences ? '文' : '項目'}が #{hits.size} 個ある (1 個のはず)"
    next nil
  end
  hits[0]
end

terms = lambda do |where, text, words|
  next if text.nil?
  missing = MU.missing(text, words)
  errors << "#{where} に #{missing.map(&:inspect).join('、')} が無い" unless missing.empty?
end

handoff = "shared/skills/personal-session-handoff/SKILL.md"
step = "### 1.5. packet を更新する (local、常に)"
terms.call("手順 1.5 の直接編集しない文", one.call(handoff, step, :sentences, "直接編集しません"), %w[worker-update #782])
terms.call("手順 1.5 の digest の順の文", one.call(handoff, step, :sentences, "SHA-256 を先に取り"), %w[その後に 読み直して])
terms.call("手順 1.5 の PR を出した worker の順の文", one.call(handoff, step, :sentences, "open のうちに"),
           ["`entry`", "`review` の操作", "`state: review`"])
terms.call("手順 1.5 の拒まれたときの文", one.call(handoff, step, :sentences, "拒まれたとき"), %w[直接の編集に戻らない])
# digest_mismatch のやり直しの条件は、文の単位で見る (条件と処理が別の文に移った変更を通さない)。
terms.call("手順 1.5 の digest_mismatch のやり直さない文", one.call(handoff, step, :sentences, "もう `結果` に載っていれば"),
           ["`entry` をやり直さない"])
terms.call("手順 1.5 の digest_mismatch の次の入口の文", one.call(handoff, step, :sentences, "書く予定と"),
           ["`次の入口`", "違っても書かず", "draft"])
terms.call("手順 1.5 の digest_mismatch のやり直す文", one.call(handoff, step, :sentences, "結果が載っていなければ"),
           %w[1 回だけやり直す])
terms.call("手順 1.5 の stale_temp の項目", one.call(handoff, step, :bullets, "一時 file には触れない"),
           ["`stale_temp`", "draft", "片付けるのは人"])
terms.call("手順 1.5 の委譲の例外の項目", one.call(handoff, step, :bullets, "例外は orchestrator として"),
           ["`worker-update` の操作で書き", "手で書き換えない"])
body = section.call(handoff, step)
if body && MU.squash(body).include?(MU.squash("frontmatter の `updated` を今の日時にする"))
  errors << "#{handoff} の手順 1.5 に、updated を手で書く古い指示が残っている"
end

packets = "docs/agent-packets.md"
tooling = "## tooling(`personal-packet`)"
terms.call("agent-packets の窓が残る項目", one.call(packets, tooling, :bullets, "この窓は残る"), ["閉じていない", "script が動いていない間"])
# 残る書き手は、その下の字下げした項目に 1 つずつ。
[["人の直接の編集", ["人の判断"]], ["`依頼` の既存の文の訂正", ["`round`"]], ["回復の手直し", ["`published`", "人が行う"]],
 ["packet の新規の作成", []]].each do |key, words|
  terms.call("agent-packets の残る書き手 #{key}", one.call(packets, tooling, :bullets, key), words)
end

# 書き方の規則の正本は tooling の節に 1 つ。概要の表と書式の節は、そこを指す (例外を落とした一般化を書き直さない)。
row = MU.rows(section.call(packets, "## 位置づけ(何の正本か)").to_s).find { |r| r.start_with?("| packet `.agent-packets/") }
errors << "#{packets} の「## 位置づけ(何の正本か)」に packet の行が無い" if row.nil?
terms.call("agent-packets の概要の packet の行", row, ["「tooling」の書き方の規則が正本"])
terms.call("agent-packets の書式の節の印の文", one.call(packets, "## 書式", :sentences, "印を使う書き手"), ["どうしだけ"])
terms.call("agent-packets の書式の節の窓の文", one.call(packets, "## 書式", :sentences, "直接の書き手として残るもの"),
           ["「tooling」の残る書き手", "`依頼` の文の訂正", "窓は残る"])
terms.call("手順 1.5 の review の packet の文", one.call(handoff, step, :sentences, "packet が既に review なら"),
           ["結果だけを渡し", "`次の入口` と `state` は変えない"])
# 手順 5: 次の入口を書けなかったときは、packet の次の入口と違うことを添える (round 5 の指摘)。
step5 = "### 5. 次回の入口を一文で示す"
terms.call("手順 5 の書けなかったときの文", one.call(handoff, step5, :sentences, "書けなかったとき"),
           ["既に review", "拒まれて", "書けなかったことを"])
terms.call("手順 5 の違いを伝える文", one.call(handoff, step5, :sentences, "違うと確かめられたときだけ"), ["違うことも伝えます"])
# 手順 3: 手順 1.5 で書けなかったときは、dry-run を今回の handoff と照らし、最新節が今回の結果でなければ publish しない。
step3 = "### 3. 記録する"
terms.call("手順 3 の照らす文", one.call(handoff, step3, :sentences, "packet を書けなかったときは"), ["`--dry-run`", "照らします"])
terms.call("手順 3 の publish しない文", one.call(handoff, step3, :sentences, "今回の結果でなければ"), ["publish しません"])

loop_doc = "shared/workflows/personal-project-operating-loop.md"
loop_text = read.call(loop_doc)
hits = MU.containing(MU.sentences(loop_text), "割当をやり直したとき")
if hits.size == 1
  terms.call("operating-loop の割当の記録の文", hits[0], ["`round`", "`依頼` に足します", "直接編集しない"])
else
  errors << "#{loop_doc} に「割当をやり直したとき」を含む文が #{hits.size} 個ある (1 個のはず)"
end

if errors.empty?
  puts "ok: packet-writer-wiring"
else
  errors.each { |e| warn "FAIL: packet-writer-wiring: #{e}" }
  exit 1
end
RUBY
