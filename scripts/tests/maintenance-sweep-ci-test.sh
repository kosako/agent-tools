#!/bin/sh
# personal-maintenance-sweep の手順 3 の `ci` の単位 (personal-ci-check で CI の workflow を決まった規則に当てる。#541) の
# 契約を検査する。
# - 手順 3 が、どのプリセットでも単位の先頭に AI を使わない `ci` の単位を足すこと、script を `--since` / `--until` の窓を
#   付けてかけること、窓を RECORD.md の `ci.json` の block で決めること、run の記録を確かめられなければ始まりを遅らせて
#   2 回までかけ直し、形でない出力ならかけ直しをやめて前の結果を使うこと、exit 0 / 1 か exit 2 で stdout が空でなく所見の
#   JSON の形なら audited にして他の単位と同じく反証へ進めること、exit 2 で stdout が空・形でない・script が無いなら所見
#   なしの done にすること (条件と遷移先を組で見る)、sweep を止めないこと、exit と stderr と窓を state に残すこと、Codex の
#   session では pending に残すこと、その単位の後は残量を読み直さないことを、それぞれ句として書いている
# - 手順 8 の「CI の窓」が、窓の時刻を進める条件 (起票まで進む run・done・run の記録の行が無い・上限で回した所見が無い)
#   と進める先を 1 つの句で書き、それ以外は進めないと書いている
# - 既存の監査結果から始める run と、中断した run の再開が、`ci` の単位を飛ばさない句を書いている
# - 手順 9 の報告に、CI を確かめられないときと、点検した窓・時刻を進めたか・見なかった期間がある。「停止と縮小」の表に、
#   CI を確かめられないときと run の記録を確かめられないときの扱いがある
# - RECORD.md の state.json の例が JSON として読め、先頭の単位が `ci` で ci_check に exit / stderr と窓の key があり、
#   consumption が `ci` の単位を指さない。`ci` の単位の bullet が、起動できなかったときの書き方と消費を残さないことを
#   書いている。tree に ci.json があり、ci.json の例が checked_until / run_id の JSON で、basis の表が 4 つの値を持ち、
#   書き直しが時刻を戻さない句がある (block の振る舞いは maintenance-sweep-ci-window-test.sh)
# - BUDGET.md が、`ci` の単位を単位の数に数えないこと・その後は読み直さないことを書いている
# - evals に ci の単位の 9 件 (毎回足す / script が無い / Codex の session では pending / exit 2 で JSON あり / 壊れた出力 /
#   初回の窓と進める / 縮めてかけ直す / report モードでは進めない / 30 日で切る) があり、prompt の前提にどの session かを
#   書いている
# 句は空白を除いて比べ (行の折り返しの位置に依らない)、句の直後が区切り (。、( か末尾) であることも求める (否定は
# 句の後ろに付くので、反転した文を部分一致で通さない)。括弧の注釈を挟む句は、注釈を除いてから比べる。
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

sweep_dir=${1:-"$repo_root/shared/skills/personal-maintenance-sweep"}
for f in SKILL.md RECORD.md BUDGET.md evals/evals.json; do
  [ -f "$sweep_dir/$f" ] || fail "missing $sweep_dir/$f"
done

ruby - "$sweep_dir" <<'RUBY'
require "json"

dir = ARGV.fetch(0)
skill = File.read(File.join(dir, "SKILL.md"), encoding: "UTF-8").split("\n")
record = File.read(File.join(dir, "RECORD.md"), encoding: "UTF-8")
budget = File.read(File.join(dir, "BUDGET.md"), encoding: "UTF-8")
evals = JSON.parse(File.read(File.join(dir, "evals/evals.json"), encoding: "UTF-8"))

def squash(text)
  text.gsub(/\s+/, "")
end

# 句が空白を除いた本文にあり、直後が区切りか末尾であること。
def clause?(text, clause)
  squash(text).match?(/#{Regexp.escape(squash(clause))}(?=[。、(]|\z)/)
end

# 括弧の注釈 (入れ子を含む) を除いてから clause? で比べる。
def bare_clause?(text, clause)
  bare = text.dup
  nil while bare.gsub!(/\([^()]*\)/, "")
  clause?(bare, clause)
end

# 見出しの行から、同じ深さか浅い次の見出しの前まで。
def section(lines, heading)
  start = lines.index { |l| l == heading }
  return nil if start.nil?
  level = heading[/\A#+/].length
  rest = lines[(start + 1)..-1]
  rest[0, rest.index { |l| l =~ /\A\#{1,#{level}} / } || rest.length]
end

# 節の中の bullet (行頭の「- 」から次の「- 」の前まで。字下げした続きの行と入れ子の bullet は前の bullet に足す)。
def bullets(lines)
  out = []
  lines.each do |l|
    if l.start_with?("- ")
      out << l.dup
    elsif !out.empty? && l.start_with?("  ")
      out[-1] << l
    end
  end
  out
end

def find(list, label)
  list.find { |b| b.start_with?("- **#{label}**") }
end

errors = []

step = section(skill, "### 3. 監査する (単位ごと)")
if step.nil?
  errors << "SKILL.md に「### 3. 監査する (単位ごと)」の節が無い"
else
  intro = step.take_while { |l| !l.start_with?("- ") }.join("\n")
  unless bare_clause?(intro, "どのプリセットでも依頼の範囲によらず、単位の先頭に、AI を使わない `ci` の単位を 1 つ足します")
    errors << "手順 3 の前置きに、どのプリセットでも単位の先頭に `ci` の単位を足す句が無い"
  end
  list = bullets(step)
  ci = find(list, "`ci` の単位")
  if ci.nil?
    errors << "手順 3 に「`ci` の単位」の bullet が無い"
  else
    # 分岐は、条件 (exit・stdout・JSON の形) と遷移先を 1 つの句の組で見る (条件だけを消しても落ちるように)。
    {
      plain: [
        "`ci` の単位は `pending` のまま残し、Claude Code の session の再開でかける",
        "sweep は止めない",
        "下の分岐は使う結果に当てる",
        "窓の時刻 (`ci.json`) を進めるかは手順 8 で決める",
      ],
      bare: [
        "を、`--since` と `--until` で run の記録の窓を付けて今の repo にかける",
        "窓: かける前に、`RECORD.md` の `ci.json` の block で決める",
        "かけ直し: 出力が下の形で、`scope.not_seen` に「run の記録」で始まる行があるときは、block の `since` の次の始まりで" \
        "かけ直す。2 回まで",
        "かけ直しの出力が下の形でなければ、かけ直しをやめて前の結果を使う",
        "exit と stderr、窓は state の単位に残す",
        "exit 0 か 1、または exit 2 で stdout が空でないとき: stdout が repo-audit の `findings.schema.json` の形なら " \
        "`units/<n>/result.json` に保存して `audited` にし、他の単位と同じく反証へ進む",
        "exit 2 で stdout が空、stdout が上の形でない、または script が無いとき: 所見なしで `done` にし、" \
        "報告に「CI を確かめられない」と理由を書く",
      ],
    }.each do |kind, clauses|
      missing = clauses.reject { |c| kind == :bare ? bare_clause?(ci, c) : clause?(ci, c) }
      errors << "「`ci` の単位」の bullet に句 #{missing.inspect} が無い" unless missing.empty?
    end
  end
  reread = list.find { |b| b.start_with?("- 単位が終わるたびに") }
  if reread.nil? || !clause?(reread, "残量を読み直す (`ci` の単位は AI の枠を使わないので読み直さない)")
    errors << "手順 3 の読み直しの bullet に、`ci` の単位の後は読み直さない句が無い"
  end
end

modes = section(skill, "## 発火とモード")
if modes.nil?
  errors << "SKILL.md に「## 発火とモード」の節が無い"
else
  list = bullets(modes)
  {
    "既存の監査結果から始める" => "手順 3 の `ci` の単位は監査の結果に含まれないので、反証の前に足してかける",
    "中断した run を再開する" => "`ci` の単位は監査で Codex を起動しないので記録が無く、`pending` なら手順 3 のとおり script をかけ直す",
  }.each do |label, c|
    b = find(list, label)
    if b.nil?
      errors << "発火とモードに「#{label}」の bullet が無い"
    elsif !clause?(b, c)
      errors << "「#{label}」の bullet に `ci` の単位を飛ばさない句 #{c.inspect} が無い"
    end
  end
end

record_step = section(skill, "### 8. 記録する")
window = record_step && find(bullets(record_step), "CI の窓")
if window.nil?
  errors << "手順 8 に「CI の窓」の bullet が無い"
else
  # 進める条件と進める先は 1 つの句の組で見る (条件を 1 つ消しても、進める先を変えても落ちるように)。
  [
    "起票まで進む run で、`ci` の単位が `done`、`units/<n>/result.json` があってその `scope.not_seen` に「run の記録」で" \
    "始まる行が無く、`ci` の単位の所見に起票の上限で次の run に回したものが無いときだけ、`checked_until` をその単位の" \
    "`until` に進める",
    "それ以外は進めない",
  ].each do |c|
    errors << "「CI の窓」の bullet に句 #{c.inspect} が無い" unless bare_clause?(window, c)
  end
end

report = section(skill, "### 9. 報告する")
ci_report = report && bullets(report).find { |b| b.start_with?("- CI の検査 (手順 3 の `ci` の単位)") }
if ci_report.nil? || !bare_clause?(ci_report, "確かめられない file、または確かめられない")
  errors << "手順 9 に CI の検査の報告の bullet が無い"
else
  ["点検した run の記録の窓と、窓の時刻を進めたか", "見なかった期間と、`ci.json` を読めないことも書く"].each do |c|
    errors << "手順 9 の CI の検査の bullet に句 #{c.inspect} が無い" unless bare_clause?(ci_report, c)
  end
end

stop = section(skill, "## 停止と縮小")
row = stop && stop.find { |l| l.start_with?("| CI を確かめられない") }
if row.nil? || !squash(row).include?(squash("sweep は止めない。`ci` の単位を所見なしで `done` にし、報告に理由を書く"))
  errors << "停止と縮小の表に、CI を確かめられないときに sweep を止めない行が無い"
end
# 表の行は、セルの区切りまで含めて比べる (句の後ろに否定を足す反転は「|」の前に入れられない)。
row = stop && stop.find { |l| l.start_with?("| run の記録を確かめられない") }
if row.nil? || !squash(row).include?(squash("| 窓の始まりを until との中間まで遅らせて 2 回までかけ直す。それでも確かめられなければ" \
                                           "静的な検査の結果で進め、窓の時刻は進めない |"))
  errors << "停止と縮小の表に、run の記録を確かめられないときにかけ直して時刻を進めない行が無い"
end

block = record[/`state\.json` の中身:\s*```json\n(.*?)\n```/m, 1]
if block.nil?
  errors << "RECORD.md に state.json の例が無い"
else
  begin
    units = JSON.parse(block)["units"]
    first = units.is_a?(Array) ? units.first : nil
    if !first.is_a?(Hash) || first["n"] != 1 || first["dimension"] != "ci" || first["area"] != ".github/workflows"
      errors << "RECORD.md の state.json の例の先頭の単位 (n = 1) が `ci` (.github/workflows) でない"
    elsif !first["ci_check"].is_a?(Hash) || first["ci_check"].keys.sort != %w[basis exit since stderr tries unseen_from until]
      errors << "RECORD.md の state.json の `ci` の単位の ci_check が exit / stderr と窓 (since / until / basis / unseen_from / tries) でない"
    end
    consumption = JSON.parse(block)["consumption"]
    if consumption.is_a?(Array) && consumption.any? { |c| c.is_a?(Hash) && c["unit"] == 1 }
      errors << "RECORD.md の state.json の例の consumption が `ci` の単位 (n = 1) を指している (消費を残さない単位)"
    end
  rescue JSON::ParserError => e
    errors << "RECORD.md の state.json の例が JSON として読めない: #{e.message[0, 80]}"
  end
end
# 0b の settings にも同じ書き方の句があるので、`ci` の単位の bullet に絞って見る。
ci_note = bullets(record.split("\n")).find { |b| b.start_with?("- `ci` の単位") }
if ci_note.nil? || !clause?(ci_note, "起動できなかったときは `exit` を null にし、`stderr` に理由を書く")
  errors << "RECORD.md の `ci` の単位の bullet に、起動できなかったときの ci_check の書き方が無い"
end
if ci_note.nil? || !clause?(ci_note, "消費 (`consumption`) は AI の枠を使わないので残さない")
  errors << "RECORD.md の `ci` の単位の bullet に、消費を残さない句が無い"
end

tree = record[/^```text\n(\$\{XDG_STATE_HOME.*?)^```/m, 1]
unless tree && tree.match?(/^  ci\.json +\S/)
  errors << "RECORD.md の local の state の tree に ci.json が無い"
end
ci_json = record[/^`ci\.json` の中身[^\n]*:\s*```json\n(.*?)\n```/m, 1]
begin
  doc = ci_json && JSON.parse(ci_json)
  unless doc.is_a?(Hash) && doc.keys.sort == %w[checked_until run_id]
    errors << "RECORD.md の ci.json の例が checked_until / run_id の JSON でない"
  end
rescue JSON::ParserError => e
  errors << "RECORD.md の ci.json の例が JSON として読めない: #{e.message[0, 80]}"
end
# basis の表の本体 (見出しと区切りの行の後、表が続く間) の 1 列目。
lines = record.split("\n")
head = lines.index { |l| l.start_with?("| `basis` |") }
rows = head ? lines[(head + 2)..-1].take_while { |l| l.start_with?("|") } : []
basis = rows.map { |l| l[/\A\| `(\w+)` \|/, 1] }
unless basis == %w[checked_until capped first unreadable]
  errors << "RECORD.md の basis の表が checked_until / capped / first / unreadable の 4 行でない: #{basis.inspect}"
end
rewrite = bullets(record.split("\n")).find { |b| b.start_with?("- 書くのは手順 8 の条件を満たしたときだけ") }
if rewrite.nil? || !clause?(rewrite, "今の `checked_until` より後の時刻のときだけ書き直す")
  errors << "RECORD.md の ci.json の書き直しの bullet に、時刻を戻さない句が無い"
end

unless clause?(budget, "AI を使わない `ci` の単位が先頭に 1 つ加わります")
  errors << "BUDGET.md にプリセットに `ci` の単位が加わることの句が無い"
end
# 括弧の注釈の中の句は、閉じの「)」まで含めて比べる (句の後ろに否定を足す反転は「)」の前に入れられない)。
{
  "(プリセットの推定 ÷ 単位の数。`ci` の単位は数えない)" => "単位の数に `ci` の単位を数えないこと",
  "(`ci` の単位は AI の枠を使わないので、その後は読み直さない)" => "`ci` の単位の後は読み直さないこと",
}.each do |c, what|
  errors << "BUDGET.md に#{what}の句が無い" unless squash(budget).include?(squash(c))
end

# evals: 毎回足す / script が無い / Codex の session では pending / exit 2 で JSON あり / 壊れた出力 / 初回の窓と進める /
# 縮めてかけ直す / report モードでは進めない / 30 日で切る。どの session の前提かを prompt に書く (Codex の session では
# script をかけないので、期待が変わる)。
want = {
  "ci-unit-every-run" => "Claude Code の session",
  "ci-check-unavailable" => "Claude Code の session",
  "ci-unit-codex-session-pending" => "Codex の session",
  "ci-check-exit2-with-json" => "Claude Code の session",
  "ci-check-broken-output" => "Claude Code の session",
  "ci-window-first-run-advance" => "Claude Code の session",
  "ci-window-retry-halved" => "Claude Code の session",
  "ci-window-report-mode-keeps" => "Claude Code の session",
  "ci-window-capped" => "Claude Code の session",
}
cases = evals.fetch("evals").map { |e| [e["name"], e] }.to_h
want.each do |name, session|
  e = cases[name]
  if e.nil?
    errors << "evals に #{name} が無い"
  elsif !e["prompt"].to_s.include?("[前提: #{session}")
    errors << "evals の #{name} の prompt に「[前提: #{session}」が無い"
  end
end

abort "FAIL: maintenance-sweep-ci\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: maintenance-sweep-ci"
RUBY
