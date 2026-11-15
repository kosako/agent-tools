#!/bin/sh
# 参照先の note を人が書き換える helper (personal-context-note-apply) の組み込み (#677) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (helper の挙動は context-note-apply-test)。
# 説明の文はそのまま固定しない。文と項目ごとに、要る語がそろっているかを見る。言い回しを変えても、語が同じ単位に残っていれば
# 通る。節の全体からは探さない (語が別の文に移っただけの変更を通さないため)。文書を単位に分ける読み方は lib/markdown_units.rb。
# - personal-session-handoff の「### 4. 正本ファイル」の節に、helper を人が実行する形で渡すこと、使い捨ての script を書かないこと、
#   案は repo の外の file に全文で書くこと、command は placeholder の無い完成形で repo root と案の file を shell の literal で書く
#   こと、人の terminal で直接実行してもらう (`!` と wrapper を通さない) こと、agent は helper を実行しないこと、がある。
# - 同じ skill の「## やってはいけないこと」に、agent は helper を実行しない、がある。
# - docs/context-note-apply.md の「## 組み込み先」が session-handoff の手順 4 を指す。docs の exit の表の label と exit code が、
#   script が出す label と合う (足した label・消した label の取りこぼしを見る)。
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

section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節の中の文のうち、key を含むものがちょうど 1 つある。その文 (無ければ nil)。
sentence = lambda do |rel, heading, key|
  body = section.call(rel, heading)
  next nil if body.nil?
  hits = MU.containing(MU.sentences(body), key)
  if hits.size != 1
    errors << "#{rel} の「#{heading}」で、#{key.inspect} を含む文が #{hits.size} 個ある (1 個のはず)"
    next nil
  end
  hits[0]
end

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

terms = lambda do |where, text, words|
  next if text.nil?
  missing = MU.missing(text, words)
  errors << "#{where} に #{missing.map(&:inspect).join("、")} が無い" unless missing.empty?
end

# 1. session-handoff の手順 4
handoff = "shared/skills/personal-session-handoff/SKILL.md"
step4 = "### 4. 正本ファイル (`.agent-context.local.md`) への反映をサジェストする"
terms.call("#{handoff} の手順 4 の helper を渡す文", sentence.call(handoff, step4, "`personal-context-note-apply`"),
           ["配備済みの helper", "人が実行する形で渡します"])
terms.call("#{handoff} の手順 4 の使い捨ての script の文", sentence.call(handoff, step4, "使い捨ての script"), ["書きません"])
terms.call("#{handoff} の手順 4 の案の file の文", sentence.call(handoff, step4, "note の新しい全文"), ["repo の外の file", "書きます"])
terms.call("#{handoff} の手順 4 の全文の文", sentence.call(handoff, step4, "差分ではなく"), ["全文にします"])
terms.call("#{handoff} の手順 4 の command を渡す文", sentence.call(handoff, step4, "1 行の command"), ["helper を実行する", "人に渡します"])
terms.call("#{handoff} の手順 4 の command の形の文", sentence.call(handoff, step4, "placeholder の無い完成形"),
           ["repo root", "案の file", "shell の literal", "personal-context-note-apply -C"])
terms.call("#{handoff} の手順 4 の直接実行の文", sentence.call(handoff, step4, "直接実行"),
           ["自分の terminal", "`!`", "wrapper を通さない"])
terms.call("#{handoff} の手順 4 の agent が実行しない文", sentence.call(handoff, step4, "agent は helper を実行しません"),
           ["agent の session の目印", "端末でない"])
terms.call("#{handoff} の「## やってはいけないこと」の helper の項目",
           item.call(handoff, "## やってはいけないこと", "`personal-context-note-apply`"), ["agent は実行しない"])

# 2. docs
doc = "docs/context-note-apply.md"
terms.call("#{doc} の「## 組み込み先」の session-handoff の項目", item.call(doc, "## 組み込み先", "`personal-session-handoff`"),
           ["手順 4"])

# docs の exit の表の label と exit code が、script が出す label と合う。
table = section.call(doc, "## 出力と exit").to_s
doc_labels = {}
table.each_line do |line|
  cells = line.split("|").map(&:strip)
  next unless cells[1].to_s =~ /\A\d\z/

  cells[2].scan(/`([a-z-]+)`/).flatten.each { |label| doc_labels[label] = cells[1].to_i }
end
errors << "#{doc} の「## 出力と exit」に label の表が無い" if doc_labels.empty?
src_path = File.join(root, "shared/scripts/personal-context-note-apply.rb")
if File.file?(src_path)
  src = File.read(src_path, encoding: "UTF-8")
  codes = { "EXIT_OK" => 0, "EXIT_NOT_WRITTEN" => 1, "EXIT_ERROR" => 2 }
  codes.each do |name, value|
    errors << "script の #{name} が #{value} でない" unless src =~ /^\s*#{name} = #{value}$/
  end
  src_labels = {}
  src.scan(/(?:Stop\.new|finish)\((?:stdout, )?"([a-z-]+)", (EXIT_[A-Z_]+)/).each { |label, code| src_labels[label] = codes[code] }
  # usage は usage! が Stop.new("usage", EXIT_ERROR, …) で出す。
  errors << "script の label を読めない" if src_labels.empty?
  (doc_labels.keys | src_labels.keys).sort.each do |label|
    if !src_labels.key?(label)
      errors << "#{doc} の label #{label} を script が出さない"
    elsif !doc_labels.key?(label)
      errors << "script の label #{label} が #{doc} の表に無い"
    elsif doc_labels[label] != src_labels[label]
      errors << "label #{label} の exit が #{doc} (#{doc_labels[label]}) と script (#{src_labels[label]}) で違う"
    end
  end
else
  errors << "shared/scripts/personal-context-note-apply.rb が無い"
end

if errors.empty?
  puts "ok: context-note-apply-wiring-test"
else
  errors.each { |e| warn "FAIL: #{e}" }
  exit 1
end
RUBY
