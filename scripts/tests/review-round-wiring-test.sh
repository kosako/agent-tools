#!/bin/sh
# 2 回目以降の review を前の round からの差分を中心に読む手順 (#673) が、文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (範囲の判定と対象の節の中身は codex-launch-test)。
# 説明の文はそのまま固定しない。項目・文・段落・code span ごとに、要る語がそろっているかを見る。言い回しを変えても、
# 語が同じ単位に残っていれば通る。節の全体からは探さない (語が別の項目や文に移っただけの変更を通さないため)。
# 文書を単位に分ける読み方と、受ける整形の範囲は、lib/markdown_units.rb が持つ。
# - personal-codex-review の LAUNCH.md の起動の手順に、前の round の head を --prev-head-oid で渡す文と、その値 (前の round の
#   結果の Target の head)、渡さないとき、範囲を script が決めること (条件の正本の場所) の文がある。STARTED の扱いに、
#   review_scope と scope_reason を caller に返す文がある。
# - SKILL.md の §4 に、2 回目以降の brief の段落 (incremental と full、条件の正本、雛形の節に書くもの) と、script が無いときは
#   前の round からの差分を中心に読む節を書かない文がある。
# - BRIEF-TEMPLATE.md の雛形の round の節が、前の round の結果と対応の項目だけで、差分の取得と読み方を持たない (script が書く)。
#   雛形の外の注に、--prev-head-oid を渡すことと、読み方は script が書くことがある。policy の読み方は、索引の読む節だけを
#   節ごとに読む形。
# - personal-review-request の手順 3 に、2 回目以降の review の項目 (前の head の値、渡さないとき、Claude が reviewer のときは
#   PR 全体、結果の Target は今の base と head) がある。TEMPLATES.md の結果の節に、読んだ範囲の 1 行の形がある。
# - 範囲を軽くした round が読み直す policy の 2 つの節が、policy の file と索引に実際にあり、script の対象の節もその 2 つを
#   指す (節の名前が変わったのに古い名前を指す、を落とす)。
# - docs/codex-launch.md に「2 回目以降の review」の節があり、4 つの条件の確かめ方がある。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
root = ARGV.fetch(0)
errors = []
MU = MarkdownUnits
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

section = lambda do |rel, heading, text = nil|
  body = MU.section(text || read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

KIND = { items: "項目", paragraphs: "段落", sentences: "文" }.freeze

# 単位 (kind) のうち key を含むものがちょうど 1 つある。その単位 (無ければ nil)。
one = lambda do |where, body, kind, key|
  next nil if body.nil?
  hits = MU.containing(MU.public_send(kind, body), key)
  if hits.size != 1
    errors << "#{where} で、#{key.inspect} を含む#{KIND.fetch(kind)}が #{hits.size} 個ある (1 個のはず)"
    next nil
  end
  hits[0]
end

terms = lambda do |where, text, words|
  next if text.nil?
  missing = MU.missing(text, words)
  errors << "#{where} に #{missing.map(&:inspect).join("、")} が無い" unless missing.empty?
end

review = "shared/skills/personal-codex-review"

# 1. LAUNCH.md の起動の手順 (番号の list の中の項目なので、文の単位で見る)
launch = "#{review}/LAUNCH.md"
head = "### personal-codex-launch で起動して回収する (#672)"
body = section.call(launch, head)
w = "#{launch} の「#{head}」"
terms.call("#{w} の --prev-head-oid を足す文", one.call(w, body, :sentences, '`--prev-head-oid "$prev_head_oid"`'),
           ["2 回目以降の review", "前の round の base と head", '`--prev-base-oid "$prev_base_oid"`'])
terms.call("#{w} の前の head の値の文", one.call(w, body, :sentences, "前の round の結果の `Target:` の行"), ["base の OID", "head の OID"])
terms.call("#{w} の渡すときと渡さないときの文", one.call(w, body, :sentences, "verdict のある結果で終わったときだけ渡し"),
           ["verdict の無い停止", "PR 全体の読み直し", "渡しません"])
terms.call("#{w} の範囲を script が決める文", one.call(w, body, :sentences, "前の round からの差分を中心に読んでよいかは"),
           ["script が git で決め", "対象の節", "`docs/codex-launch.md`", "「2 回目以降の review」"])
terms.call("#{w} の STARTED の範囲の文", one.call(w, body, :sentences, "`review_scope`"),
           ["前の round の OID の組", "`incremental`", "`full`", "`scope_reason`", "caller に返します"])

# 2. SKILL.md の §4
skill = "#{review}/SKILL.md"
b4 = section.call(skill, "## 4. brief")
w = "#{skill} の「## 4. brief」"
terms.call("#{w} の 2 回目以降の段落", one.call(w, b4, :paragraphs, "`--prev-head-oid`"),
           ["2 回目以降の review", "`--prev-base-oid`", "前の round の base と head", "`incremental`", "`full`", "`docs/codex-launch.md`", "「round <回数> の追加の情報」",
            "前の round の指摘と依頼元の対応"])
terms.call("#{w} の script が無いときの文", one.call(w, b4, :sentences, "前の round からの差分を中心に読む節を"),
           ["script が無い環境", "書かず", "PR 全体を読む対象"])

# 3. BRIEF-TEMPLATE.md
tpl = "#{review}/BRIEF-TEMPLATE.md"
bt = section.call(tpl, "## 雛形")
w = "#{tpl} の「## 雛形」"
unless bt.nil?
  blocks = MU.blocks(bt).select { |info, _| info == "markdown" }
  if blocks.size != 1
    errors << "#{w} に markdown の block が #{blocks.size} 個ある (1 個のはず)"
  else
    block = blocks[0][1]
    rh = "## round <回数> の追加の情報 (2 回目以降だけ)"
    round = section.call("#{tpl} の雛形の block", rh, block)
    unless round.nil?
      wr = "#{tpl} の雛形の「#{rh}」"
      one.call(wr, round, :items, "前の round (head <前の head の OID>) の結果")
      one.call(wr, round, :items, "依頼元の対応")
      errors << "#{wr} に差分の取得 (git diff) がある (読み方は script が対象の節に書く)" if MU.squash(round).include?("gitdiff")
    end
    terms.call("#{tpl} の雛形の policy の段落", one.call("#{tpl} の雛形", block, :paragraphs, "policy-index.md"),
               ["`### review`", "「sections(読む節)」", "`policies/review.md`", "`rg -n '^#'`", "`sed -n`", "file 全体を一度に読まない",
                "`review-output-contract.md`"])
  end
  terms.call("#{w} の 2 回目以降の注", one.call(w, bt, :items, "`--prev-head-oid`"),
             ["2 回目以降", "`--prev-base-oid`", "`LAUNCH.md` の手順 2", "`git diff <前の head の OID>..<今の head の OID>`", "script が対象の節に書く",
              "書きません", "`scope_reason`"])
end

# 4. personal-review-request
request = "shared/skills/personal-review-request/SKILL.md"
step3 = "### 3. レビュー実行"
w = "#{request} の「#{step3}」"
it = one.call(w, section.call(request, step3), :items, "**2 回目以降の review**")
terms.call("#{w} の 2 回目以降の項目", it,
           ["前の round の結果の `Target:` の行の base と head", "`personal-codex-review`", "`--prev-base-oid`", "`--prev-head-oid`", "`personal-codex-launch`",
            "`docs/codex-launch.md`", "verdict のある結果", "verdict の無い停止", "PR 全体の読み直し"])
terms.call("#{w} の 2 回目以降の項目の Claude の文", it && one.call(w, it, :sentences, "Claude がレビュアーのときは"), ["毎 round PR 全体を読む"])
terms.call("#{w} の 2 回目以降の項目の Target の文", it && one.call(w, it, :sentences, "前の head を書かない"),
           ["結果の `Target:` の行", "今の base と head"])

templates = "shared/skills/personal-review-request/TEMPLATES.md"
rh = "## 📋 レビュー結果 (手順 4)"
w = "#{templates} の「#{rh}」"
para = one.call(w, section.call(templates, rh), :paragraphs, "読んだ範囲を 1 行")
terms.call("#{w} の範囲の段落", para, ["2 回目以降の review", "前の round の base と head を渡したとき", "目印の 5 行の後に", "`scope_reason`",
                                     "`Target:` の行は、今の base と head のまま"])
unless para.nil?
  spans = MU.code_spans(para)
  ["範囲: 前の round (head <前の head の OID の先頭 8 文字>) からの差分を中心に読んだ", "範囲: PR 全体 (<scope_reason>)"].each do |form|
    errors << "#{w} の範囲の段落に #{form.inspect} の形が無い" unless spans.include?(MU.squash(form))
  end
end

# 5. 軽くした round が読み直す policy の節が実在し、script もその節を指す
names = %w[指摘の再評価と追跡 堂々巡りの検出]
policy = "shared/skills/personal-production-rail/references/policies/review.md"
names.each { |name| section.call(policy, "## #{name}") }
index = "shared/skills/personal-production-rail/references/policy-index.md"
sections_item = one.call("#{index} の「### review」", section.call(index, "### review"), :items, "sections(読む節)")
terms.call("#{index} の「### review」の読む節の項目", sections_item, names.map { |n| "「#{n}」" } + ["再レビュー"])
src = File.join(root, "shared/scripts/personal-codex-launch.rb")
if File.file?(src)
  require src
  lines = CodexLaunch.incremental_lines("b" * 40, "h" * 40, "p" * 40).join("\n")
  terms.call("script の対象の節 (incremental)", lines, ["「#{names[0]}」と「#{names[1]}」", "`policies/review.md`", "`review-output-contract.md`"])
else
  errors << "shared/scripts/personal-codex-launch.rb が無い"
end

# 6. docs/codex-launch.md
doc = "docs/codex-launch.md"
dh = "### 2 回目以降の review (`--prev-head-oid`)"
terms.call("#{doc} の「#{dh}」", section.call(doc, dh),
           ["`git merge-base --is-ancestor <前> <今>`", "`git rev-list --merges <前>..<今>`", "`git merge-base --all <前の base> <前>`",
            "`git merge-base --all <base> <今>`", "`--prev-base-oid`", "`git diff --numstat`", "半分以下", "`scope_reason`", "`Target:`", "`personal-merge-preflight`"])

unless errors.empty?
  warn errors.map { |e| "FAIL: #{e}" }.join("\n")
  exit 1
end
RUBY

echo "ok: review-round-wiring-test"
