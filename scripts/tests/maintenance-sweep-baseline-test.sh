#!/bin/sh
# personal-maintenance-sweep の手順 0b (repo の設定を personal-repo-baseline で確かめる。#539) の契約を検査する。
# - 0b の節の bullet が、`--check` だけを付けること・sweep の中で `--apply` をかけないこと・結果を追跡 Issue / run の
#   コメント / 所見の Issue に書かないこと・`--apply` は人の承認で sweep とは別にかけること・再開と既存の監査結果から
#   始める run でもかけ直すことを、それぞれ句として書いている
# - 再開と既存の監査結果から始める run の bullet が 0b を通す順に入れている (入れないと再開で 0b を飛ばす)
# - 手順 8 の追跡 Issue の bullet と「やってはいけないこと」が、結果を public にしないことと `--apply` の禁止を書いている
# - RECORD.md の state.json の例が JSON として読め、`settings` に checked_at / exit / stdout / stderr がある (exit 2 の
#   理由は stderr にだけ出るので、stdout だけでは確かめられなかった理由が残らない)
# 句は空白を除いて比べ (行の折り返しの位置に依らない)、句の直後が区切り (。、( か末尾) であることも求める (否定は
# 句の後ろに付くので、「かけない」を「かけないことはない」のように反転した文を部分一致で通さない)。句は述語まで書く
# (述語の前で切ると「済ませてから」を「省いて」に反転しても通る)。手順の列挙は括弧の注釈を除いてから比べる。
# 引数で sweep の skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

sweep_dir=${1:-"$repo_root/shared/skills/personal-maintenance-sweep"}
[ -f "$sweep_dir/SKILL.md" ] || fail "missing $sweep_dir/SKILL.md"
[ -f "$sweep_dir/RECORD.md" ] || fail "missing $sweep_dir/RECORD.md"

ruby - "$sweep_dir/SKILL.md" "$sweep_dir/RECORD.md" <<'RUBY'
require "json"

skill = File.read(ARGV.fetch(0), encoding: "UTF-8").split("\n")
record = File.read(ARGV.fetch(1), encoding: "UTF-8")

def squash(text)
  text.gsub(/\s+/, "")
end

# 句が空白を除いた本文にあり、直後が区切りか末尾であること。
def clause?(text, clause)
  squash(text).match?(/#{Regexp.escape(squash(clause))}(?=[。、(]|\z)/)
end

# 括弧の注釈 (入れ子を含む) を除いてから clause? で比べる。注釈を挟む列挙でも、述語まで続けて照合するため。
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

# 節の中の bullet (行頭の「- 」から次の「- 」の前まで。続きの行は前の bullet に足す)。
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

STEP = {
  "読むだけ" => [
    "引数は `--check` だけにする",
    "`--apply` は sweep の中ではかけない",
  ],
  "書く先" => [
    "追跡 Issue の本文、run のコメント、所見の Issue には書かず、起票もしない",
  ],
  "直すとき" => [
    "`--apply` は人が承認したときだけ、sweep の run とは別にかける",
  ],
  "かける run" => [
    "中断した run の再開と、既存の監査結果から始める run でもかけ直す",
  ],
}.freeze

step = section(skill, "### 0b. repo の設定を確かめる (baseline)")
if step.nil?
  errors << "SKILL.md に「### 0b. repo の設定を確かめる (baseline)」の節が無い"
else
  list = bullets(step)
  STEP.each do |label, clauses|
    b = find(list, label)
    if b.nil?
      errors << "0b の節に「#{label}」の bullet が無い"
      next
    end
    missing = clauses.reject { |c| clause?(b, c) }
    errors << "0b の「#{label}」の bullet に句 #{missing.inspect} が無い" unless missing.empty?
  end
end

modes = section(skill, "## 発火とモード")
if modes.nil?
  errors << "SKILL.md に「## 発火とモード」の節が無い"
else
  list = bullets(modes)
  {
    "中断した run を再開する" => "手順 0 と 0b と 2 をやり直し",
    "既存の監査結果から始める" => "手順 0 と 0b と 1 と 2 を済ませてから",
  }.each do |label, c|
    b = find(list, label)
    if b.nil?
      errors << "発火とモードに「#{label}」の bullet が無い"
    elsif !bare_clause?(b, c)
      errors << "「#{label}」の bullet に 0b を通す句 #{c.inspect} が無い"
    end
  end
end

record_step = section(skill, "### 8. 記録する")
tracking = record_step && find(bullets(record_step), "追跡 Issue")
if tracking.nil?
  errors << "手順 8 に「追跡 Issue」の bullet が無い"
elsif !clause?(tracking, "残量の数字と repo の設定の確認の結果は書かない")
  errors << "手順 8 の追跡 Issue の bullet に、repo の設定の確認の結果を書かない句が無い"
end

bans = section(skill, "## やってはいけないこと")
if bans.nil?
  errors << "SKILL.md に「## やってはいけないこと」の節が無い"
else
  ban = bullets(bans).find { |b| clause?(b, "sweep の中で `personal-repo-baseline --apply` をかける") }
  if ban.nil?
    errors << "やってはいけないことに `--apply` をかけることの禁止が無い"
  elsif !clause?(ban, "repo の設定の確認の結果を、追跡 Issue・run のコメント・所見の Issue に書く")
    errors << "やってはいけないことに、確認の結果を Issue に書くことの禁止が無い"
  end
end

block = record[/`state\.json` の中身:\s*```json\n(.*?)\n```/m, 1]
if block.nil?
  errors << "RECORD.md に state.json の例が無い"
else
  begin
    settings = JSON.parse(block)["settings"]
    if !settings.is_a?(Hash)
      errors << "RECORD.md の state.json の例に settings の object が無い"
    elsif settings.keys.sort != %w[checked_at exit stderr stdout]
      errors << "RECORD.md の state.json の settings の key が checked_at / exit / stdout / stderr でない: #{settings.keys.inspect}"
    end
  rescue JSON::ParserError => e
    errors << "RECORD.md の state.json の例が JSON として読めない: #{e.message[0, 80]}"
  end
end

abort "FAIL: maintenance-sweep-baseline\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: maintenance-sweep-baseline"
RUBY
