#!/bin/sh
# personal-codex-review の commit mode で、周辺コードも検証済み OID の tree から読む規則が文書に
# 残っていることを検査する (#356)。文言の検知で、振る舞いの保証ではない (期待挙動は evals.json の
# case 30〜32。model eval は自動で走らない)。
# - SKILL.md §3 の commit の bullet と、§4 の brief の一覧 (最初の bullet の一覧。Codex に届くのは
#   ここだけ) に、tree から読む command の例・HEAD / worktree を根拠にしないこと・tree に無い file の
#   扱い・object を読めないときに止めること・root commit も同じことがある。§3 では merge commit を
#   対象外にする規則も残っている。節の外にだけ語があっても規則として読まれないので、節に範囲を絞る。
# - 「やってはいけないこと」と docs/codex-review-launch.md の「brief と target」が同じ規則に触れている。
# - evals.json に 3 case があり、id が重複していない。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
require "json"

root = ARGV.fetch(0)
skill = "shared/skills/personal-codex-review"

H2 = /\A## /.freeze
# 2 つの節 (§3 の commit の bullet と §4 の brief の一覧) が共に持つべき語。
TREE_RULE = [
  "検証済み OID の tree から読",
  "`git show <oid>:<path>`",
  "`git grep -n -e <pattern> <oid> --`",
  "`git ls-tree -r --name-only <oid>`",
  "値の受け渡しの規則で渡す",
  "worktree の file (dirty な変更を含む) は根拠にし",
  "その commit 時点では存在しない",
  "worktree から補",
  "読めなければ理由を書いて止め",
  "verdict を出さない",
  "現在の checkout へ fallback し",
  "root commit も同じ",
].freeze

# [file, 節の名前, [[始まりの行, 終わりの行], ...], 節にあるべき語]。組を順に当てて絞る (前の組で
# 絞った範囲の中で次の組を探す)。始まりの行は範囲に含め、終わりの行 (始まりの次の行から探す) は
# 含めない。終わりが無ければ範囲の末尾まで。
TARGETS = [
  ["#{skill}/SKILL.md", "§3 の commit の bullet",
   [[/\A## 3\. /, H2], [/\A- \*\*commit\*\*/, /\A(?:\S|\s*\z)/]],
   TREE_RULE + ["merge commit は commit mode の対象外"]],
  ["#{skill}/SKILL.md", "§4 の brief の一覧",
   [[/\A## 4\. brief\s*\z/, H2], [/\A- /, /\A\s*\z/]],
   TREE_RULE],
  ["#{skill}/SKILL.md", "やってはいけないこと",
   [[/\A## やってはいけないこと\s*\z/, H2]],
   ["commit mode で worktree の file", "周辺コードの根拠にする"]],
  ["docs/codex-review-launch.md", "brief と target",
   [[/\A## brief と target\s*\z/, H2]],
   ["検証済み commit OID の tree", "worktree の file は根拠にしません"]],
].freeze

EVAL_NAMES = %w[
  commit-mode-context-from-target-tree
  commit-mode-missing-file-is-absent
  root-commit-context-from-own-tree
].freeze

def narrow(lines, start_re, stop_re)
  first = lines.index { |l| l =~ start_re }
  return nil if first.nil?
  rest = lines[(first + 1)..-1]
  stop = rest.index { |l| l =~ stop_re }
  lines[first, 1 + (stop || rest.length)]
end

errors = []
TARGETS.each do |rel, label, ranges, words|
  path = File.join(root, rel)
  unless File.file?(path)
    errors << "#{rel}: file が無い"
    next
  end
  lines = File.read(path, encoding: "UTF-8").split("\n")
  ranges.each do |start_re, stop_re|
    lines = narrow(lines, start_re, stop_re)
    break if lines.nil?
  end
  if lines.nil?
    errors << "#{rel}: #{label}の節が見つからない"
    next
  end
  # 折り返しの位置で落ちないよう、空白と改行を除いて比べる。
  body = lines.join("\n").gsub(/\s+/, "")
  missing = words.reject { |w| body.include?(w.gsub(/\s+/, "")) }
  next if missing.empty?
  errors << "#{rel}: #{label}に commit mode の tree の規則の語 #{missing.inspect} が無い"
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
