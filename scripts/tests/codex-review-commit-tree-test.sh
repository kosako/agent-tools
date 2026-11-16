#!/bin/sh
# personal-codex-review の commit mode で、周辺コードも検証済み OID の tree から読む規則が文書に
# 残っていることを検査する (#356)。文言の検知で、振る舞いの保証ではない (期待挙動は evals.json の
# case 30〜32。model eval は自動で走らない)。
# - SKILL.md §3 の commit の項目と、§4 の brief の一覧 (最初の一覧。Codex に届くのはここだけ) の 1 つの項目に、tree から
#   読む command の例・HEAD / worktree を根拠にしないこと・tree に無い file の扱い・object を読めないときに止めること・
#   root commit も同じことがある。§3 では merge commit を対象外にする規則も残っている。節の外や別の項目にだけ語があっても
#   規則として読まれないので、1 つの項目 (子の項目を外した本文) に範囲を絞る。
#   禁止の文は否定形 (§3 は「しません」、§4 は「しない」) まで、句として比べる (句の直後が区切りか末尾)。語幹だけだと
#   「しません」を「します」に変えて禁止を許可へ反転しても語が残り、句の後ろに否定を足した変更も通る。
# - 「やってはいけないこと」の 1 つの項目と、docs/codex-review-launch.md の「brief と target」の 1 つの文が、同じ規則に
#   触れている。
# - evals.json に 3 case があり、id が重複していない。
# 文書を単位に分ける読み方と、受ける整形の範囲は lib/markdown_units.rb が持つ (#685)。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
# encoding: UTF-8
require "json"

root = ARGV.fetch(0)
skill = "shared/skills/personal-codex-review"
MU = MarkdownUnits

# 2 つの項目 (§3 の commit の項目と §4 の brief の一覧の項目) が共に持つべき語。
TREE_RULE = [
  "検証済み OID の tree から読",
  "`git show <oid>:<path>`",
  "`git grep -n -e <pattern> <oid> --`",
  "`git ls-tree -r --name-only <oid>`",
  "値の受け渡しの規則で渡す",
  "その commit 時点では存在しない",
  "読めなければ理由を書いて止め",
  "verdict を出さない",
  "root commit も同じ",
].freeze
# 禁止の句。§3 は です・ます調、§4 は である調で書いてあるので、否定形を節ごとに持つ。
FORBID_POLITE = [
  "現在の HEAD の tree と worktree の file (dirty な変更を含む) は根拠にしません",
  "worktree から補いません",
  "現在の checkout へ fallback しません",
].freeze
FORBID_PLAIN = [
  "現在の HEAD の tree と worktree の file (dirty な変更を含む) は根拠にしない",
  "worktree から補わない",
  "現在の checkout へ fallback しない",
].freeze

# 節の最上位の項目を、子の項目を外した本文で返す (本文を子の項目へ切り出した変更と、項目を丸ごと子に下げた変更を通さない)。
top_items = ->(body) { MU.items(body).map { |item| MU.bullets(item).first } }
first_list = ->(body) { Array(MU.lists(body).first).map { |item| MU.bullets(item).first } }
sentences = ->(body) { MU.paragraphs(body).flat_map { |para| MU.sentences(para).map { |s| "#{s}。" } } }

# [file, 節の見出し, 範囲の名前, 単位の取り方, 語 (含むこと), 句 (直後が区切りか末尾)]。語と句は、どれか 1 つの単位に
# すべてあること。§3 は、最初の commit の項目だけを見る (前の版の範囲。後ろに同じ名前の項目を足しても、最初の項目の欠けを
# 隠さない)。
TARGETS = [
  ["#{skill}/SKILL.md", "## 3. 対象 mode を1つ選び、brief に固定する", "§3 の commit の項目",
   ->(body) { top_items.(body).select { |item| MU.squash(item).start_with?(MU.squash("- **commit**")) }.first(1) },
   TREE_RULE + ["merge commit は commit mode の対象外"], FORBID_POLITE],
  ["#{skill}/SKILL.md", "## 4. brief", "§4 の brief の一覧の項目", first_list, TREE_RULE, FORBID_PLAIN],
  ["#{skill}/SKILL.md", "## やってはいけないこと", "やってはいけないことの項目", top_items,
   ["commit mode で worktree の file"], ["周辺コードの根拠にする"]],
  ["docs/codex-review-launch.md", "## brief と target", "brief と target の文", sentences,
   ["検証済み commit OID の tree"], ["worktree の file は根拠にしません"]],
].freeze

EVAL_NAMES = %w[
  commit-mode-context-from-target-tree
  commit-mode-missing-file-is-absent
  root-commit-context-from-own-tree
].freeze

errors = []
TARGETS.each do |rel, heading, label, pick, words, clauses|
  path = File.join(root, rel)
  unless File.file?(path)
    errors << "#{rel}: file が無い"
    next
  end
  body = MU.section(File.read(path, encoding: "UTF-8"), heading)
  if body.nil?
    errors << "#{rel}: 「#{heading}」の節が見つからない"
    next
  end
  units = pick.call(body)
  if units.empty?
    errors << "#{rel}: #{label}が見つからない"
    next
  end
  lacks = ->(unit) { MU.missing(unit, words) + clauses.reject { |c| MU.clause?(unit, c) } }
  gap = lacks.(units.min_by { |unit| lacks.(unit).size })
  next if gap.empty?

  errors << "#{rel}: #{label}に commit mode の tree の規則の語 #{gap.inspect} が無い"
end

evals_rel = "#{skill}/evals/evals.json"
evals_path = File.join(root, evals_rel)
if File.file?(evals_path)
  cases = JSON.parse(File.read(evals_path, encoding: "UTF-8")).fetch("evals")
  ids = cases.map { |c| c["id"] }
  errors << "#{evals_rel}: id が重複している" unless ids.uniq.length == ids.length
  EVAL_NAMES.each do |name|
    c = cases.find { |x| x["name"] == name }
    if c.nil?
      errors << "#{evals_rel}: case #{name} が無い"
    elsif !c["assertions"].is_a?(Array) || c["assertions"].empty?
      errors << "#{evals_rel}: case #{name} に assertions が無い"
    end
  end
else
  errors << "#{evals_rel}: file が無い"
end

abort "FAIL: codex-review-commit-tree\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: codex-review-commit-tree"
RUBY
