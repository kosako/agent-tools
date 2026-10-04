#!/bin/sh
# capability が使えないときの規律が skill の文書と evals に残っていることを検査する (#217)。
# 文言の検知で、振る舞いの保証ではない (どちらの skill も evals は自動で走らない。期待挙動は
# evals.json の各 case)。
# - personal-session-handoff: 耐久が要らない判断を memory に委ねるのは、host が memory 機能を提供し、
#   現在の範囲で書き込みが許されるときだけ。無い・書けないときは会話内に残し、新しい file や sink を
#   作らない (手順 4 の節と、やってはいけないことの節)。条件の無い「従来どおり memory に委ねます」は残さない。
# - personal-github-safe-reader: safe-gh を配備していない・実行できない・exit が想定外のときは、生の
#   `gh` へ fallback せず、本文を読まずに停止して hand-off する (安全な読み口の節と、やってはいけない
#   ことの節)。呼び直してよいのは、呼び方の誤りが safe-gh の固定の message から明らかなときの 1 度だけで、
#   それでも exit 0 にならなければ停止する (安全な読み口の節)。
# - 両 skill の evals.json に、その場合の case (name と assertion の id) がある。safe-reader には、gh api の
#   失敗では呼び直さない assertion と、呼び方の誤りで 1 度だけ呼び直す case・呼び直しも失敗したら停止する
#   case がある。evals.json の root が object でなければ失敗にする。
# 節の外にだけ語があっても規則として読まれないので、節に範囲を絞る。
# 検査そのものの確認として、evals.json の root を [] / null に置き換えた copy で検査が失敗することも
# 確かめる (必要な case が消えても成功する経路が無いことの確認)。
# 引数で skill の directory の親 (既定は shared/skills) を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

skills_dir=${1:-"$repo_root/shared/skills"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/check.rb" <<'RUBY'
require "json"

skills_dir = ARGV.fetch(0)

HANDOFF = "personal-session-handoff".freeze
READER = "personal-github-safe-reader".freeze
H2 = /\A## /.freeze
H2_OR_H3 = /\A###? /.freeze
DONTS = /\A## やってはいけないこと\s*\z/.freeze

# [file, 節の名前, 始まりの行, 終わりの行, 節にあるべき語]。始まりの行は範囲に含め、終わりの行
# (始まりの次の行から探す) は含めない。終わりが無ければ file の末尾まで。
TEXT_TARGETS = [
  ["#{HANDOFF}/SKILL.md", "手順 4 の節", /\A### 4\. /, H2_OR_H3,
   ["memory 機能", "書き込みが許される", "no-write", "会話内", "新しい file", "sink"]],
  ["#{HANDOFF}/SKILL.md", "やってはいけないことの節", DONTS, H2,
   ["memory", "新しい file", "sink"]],
  ["#{READER}/SKILL.md", "安全な読み口の節", /\A## 安全な読み口/, H2,
   ["配備", "実行できない", "exit", "fallback", "gh issue view --comments", "gh api",
    "本文を読まず", "停止", "hand-off",
    # 呼び直しの例外の条件と回数の制限。
    "呼び方の誤り", "固定の message", "1 度だけ呼び直", "exit 0 にならなければ停止"]],
  ["#{READER}/SKILL.md", "やってはいけないことの節", DONTS, H2,
   ["safe-gh", "fallback", "生の `gh`"]],
].freeze

# [file, 残っていてはいけない語]。条件の無い委任の文言。
FORBIDDEN = [
  ["#{HANDOFF}/SKILL.md", "従来どおり memory に委ねます"],
].freeze

# [file, case の name, あるべき assertion の id]。
EVAL_TARGETS = [
  ["#{HANDOFF}/evals/evals.json", "handoff-no-memory-capability",
   %w[keeps-in-conversation no-new-file-or-sink still-hands-off]],
  ["#{HANDOFF}/evals/evals.json", "handoff-memory-present-no-write",
   %w[no-memory-write still-hands-off]],
  ["#{READER}/evals/evals.json", "safe-gh-not-deployed-no-raw-fallback",
   %w[no-raw-gh-fallback no-body-read stops-and-hands-off]],
  ["#{READER}/evals/evals.json", "safe-gh-fails-no-raw-fallback",
   %w[no-raw-gh-fallback no-body-read stops-and-hands-off no-retry-on-api-failure]],
  ["#{READER}/evals/evals.json", "safe-gh-usage-error-retries-once",
   %w[retries-once-with-fix no-raw-gh-fallback stops-if-retry-fails]],
  ["#{READER}/evals/evals.json", "safe-gh-retry-fails-stops",
   %w[no-second-retry no-raw-gh-fallback no-body-read stops-and-hands-off]],
].freeze

def section(lines, start_re, stop_re)
  first = lines.index { |l| l =~ start_re }
  return nil if first.nil?
  rest = lines[(first + 1)..-1]
  stop = rest.index { |l| l =~ stop_re }
  lines[first, 1 + (stop || rest.length)]
end

def squash(s)
  s.gsub(/\s+/, "")
end

errors = []
TEXT_TARGETS.each do |rel, label, start_re, stop_re, words|
  path = File.join(skills_dir, rel)
  unless File.file?(path)
    errors << "#{rel}: file が無い"
    next
  end
  lines = section(File.read(path, encoding: "UTF-8").split("\n"), start_re, stop_re)
  if lines.nil?
    errors << "#{rel}: #{label} (#{start_re.source}) が見つからない"
    next
  end
  # 折り返しの位置で落ちないよう、空白と改行を除いて比べる。
  body = squash(lines.join("\n"))
  missing = words.reject { |w| body.include?(squash(w)) }
  next if missing.empty?
  errors << "#{rel}: #{label}に capability が無いときの規律の語 #{missing.inspect} が無い"
end

FORBIDDEN.each do |rel, word|
  path = File.join(skills_dir, rel)
  next unless File.file?(path) # file が無いことは上で報告済み
  next unless squash(File.read(path, encoding: "UTF-8")).include?(squash(word))
  errors << "#{rel}: 条件の無い委任の文言 #{word.inspect} が残っている"
end

parsed = {}
EVAL_TARGETS.each do |rel, name, ids|
  path = File.join(skills_dir, rel)
  unless parsed.key?(rel)
    parsed[rel] =
      begin
        File.file?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : :missing
      rescue JSON::ParserError => e
        errors << "#{rel}: JSON として読めない (#{e.message.lines.first.to_s.strip})"
        :invalid
      end
    errors << "#{rel}: file が無い" if parsed[rel] == :missing
    # root が [] / null などなら case を探さずに飛ばすことになるので、黙って通さず失敗にする。
    unless [:missing, :invalid].include?(parsed[rel]) || parsed[rel].is_a?(Hash)
      errors << "#{rel}: root が object でない (#{parsed[rel].class})"
    end
    if parsed[rel].is_a?(Hash)
      case_ids = Array(parsed[rel]["evals"]).map { |c| c["id"] }
      dup = case_ids.select { |i| case_ids.count(i) > 1 }.uniq
      errors << "#{rel}: case の id が重複している #{dup.inspect}" unless dup.empty?
    end
  end
  doc = parsed[rel]
  next unless doc.is_a?(Hash)
  found = Array(doc["evals"]).find { |c| c["name"] == name }
  if found.nil?
    errors << "#{rel}: case #{name.inspect} が無い"
    next
  end
  have = Array(found["assertions"]).map { |a| a["id"] }
  missing = ids - have
  next if missing.empty?
  errors << "#{rel}: case #{name.inspect} に assertion #{missing.inspect} が無い"
end

abort "FAIL: capability-discipline\n  " + errors.join("\n  ") unless errors.empty?
RUBY

ruby "$tmp/check.rb" "$skills_dir"

# 検査そのものの確認: evals.json の root を [] / null に置き換えた copy では、検査が root の形を理由に失敗する。
for skill in personal-session-handoff personal-github-safe-reader; do
  for root in '[]' 'null'; do
    rm -rf "$tmp/skills"
    mkdir "$tmp/skills"
    cp -R "$skills_dir/personal-session-handoff" "$skills_dir/personal-github-safe-reader" "$tmp/skills/"
    printf '%s\n' "$root" > "$tmp/skills/$skill/evals/evals.json"
    if ruby "$tmp/check.rb" "$tmp/skills" > "$tmp/out" 2>&1; then
      fail "capability-discipline: $skill の evals.json の root が $root でも検査が成功した"
    fi
    grep -qF "$skill/evals/evals.json: root が object でない" "$tmp/out" ||
      fail "capability-discipline: $skill の evals.json の root が $root のとき、root の形を理由に失敗しない"
  done
done

echo "ok: capability-discipline"
