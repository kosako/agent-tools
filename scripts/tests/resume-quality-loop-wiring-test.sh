#!/bin/sh
# resume の品質ループの宣言の知らせ (#815) の句を固定する。文言の検知で、agent の振る舞いの保証ではない。
# 手順 2 の収集と、手順 3 の提示の句を、それぞれ同じ項目の中で探す (節全体での語の有無にはしない)。
# 空白と折り返しは helper で吸収し、句末の否定反転は MU.clause? で拒否する。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
# encoding: UTF-8
root = ARGV.fetch(0)
MU = MarkdownUnits
errors = []

check = lambda do |rel, heading, label, clauses|
  body = MU.section(File.read(File.join(root, rel), encoding: "UTF-8"), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif MU.bullets(body).none? { |unit| clauses.all? { |clause| MU.clause?(unit, clause) } }
    errors << "#{rel} の「#{heading}」の同じ項目に、#{label}の句が揃っていない"
  end
end

resume = "shared/skills/personal-resume-project/SKILL.md"
check.call(resume, "### 2. 直近の状況を集める", "品質ループの宣言の収集", [
  "個人 project でだけ、turn の終わりの QA の宣言 (`checks.local.json` の `qa_checks`) がこの repo にあるかを見ます",
  "どこかで判定できなければ、何も足さずに次へ進みます",
  "env の `GH_REPO` と `GH_HOST` がどちらも空であること",
  "`gh api user --jq .login` と `gh api 'repos/{owner}/{repo}' --jq '.owner.type + \" \" + .owner.login'`",
  "owner の type が `User`",
  "login が自分の login と一致すること",
  "gh が失敗した、値の形が違うときは判定しない",
  "配備済みの `personal-changed-scope-qa --declaration-status`",
  "stdout の 1 語だけを使う",
  "stderr は提示に写さない",
])
check.call(resume, "### 3. 現在地をまとめて提示する", "品質ループの知らせ", [
  "手順 2 の品質ループの宣言が `absent` のときだけ",
  "ほかの語のときと、判定しなかったときは何も足さない",
  "質問にせず、作業を止めず、file を書かない",
])

if errors.empty?
  puts "ok: resume-quality-loop-wiring"
else
  errors.each { |e| warn "FAIL: #{e}" }
  exit 1
end
RUBY
