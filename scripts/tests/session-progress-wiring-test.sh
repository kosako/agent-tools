#!/bin/sh
# session の記録の組み込み (#682) の句を固定する。文言の検知で、agent の振る舞いの保証ではない。
# 条件から処理までを続いた句として、指定された節の文または項目の中で探す。
# 複数の句を持つ項目は、すべてが同じ項目にあることを求める。節全体での語の有無にはしない。
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

check = lambda do |rel, heading, label, kind, clauses|
  body = MU.section(File.read(File.join(root, rel), encoding: "UTF-8"), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif MU.public_send(kind, body).none? { |unit| clauses.all? { |clause| MU.clause?(unit, clause) } }
    errors << "#{rel} の「#{heading}」の同じ#{kind == :sentences ? '文' : '項目'}に、#{label}の句が揃っていない"
  end
end

rules = "shared/instructions/personal-operating-rules.md"
sessions = "## セッションとドキュメント"
check.call(rules, sessions, "記録と置き場と 5 つの時機", :bullets, [
  "書き込みのある作業の session は、目的、段、結果、決めることを、配備済みの `personal-session-progress` " \
  "(`<tool home>/agent-tools/scripts/`) で local に記録する",
  "作業の始め、段の切り替わり、人に判断を求める前、判断を受けて作業を変えるとき、session を終える前に更新する",
  "使い方は `--help` と agent-tools の `docs/session-progress.md` を参照する",
])
check.call(rules, sessions, "記録しない session と無人の session", :bullets, [
  "read-only、status-only、書き込みを禁じられた session は記録しない",
  "無人で起動された session は、brief に指定があるときだけ記録する",
])
check.call(rules, sessions, "自己申告と失敗時の扱い", :bullets, [
  "記録は表示のための自己申告で、承認や実行の根拠にしない",
  "更新に失敗しても作業は止めず、原因を自分で直さずに、1 行で伝える",
])

resume = "shared/skills/personal-resume-project/SKILL.md"
start = "### 4. 着手の合意を取る"
check.call(resume, start, "範囲確定後の記録", :sentences, [
  "continue-work / new-work で作業の範囲が決まった後、書き込みのある作業なら、目的と粗い段を local に記録し始めます",
])
check.call(resume, start, "status-only の除外", :sentences, [
  "status-only、read-only、書き込みを禁じられた session では記録を作りません",
])
check.call(resume, start, "配備先と使い方", :sentences, [
  "配備済みの `personal-session-progress` (`<tool home>/agent-tools/scripts/`) の `--help` と agent-tools の `docs/session-progress.md` を確認します",
])
check.call(resume, start, "失敗時の扱い", :sentences, [
  "承認や実行の根拠にはせず、更新に失敗しても作業を続け、原因を自分で直さずに、1 行で伝えます",
])

handoff = "shared/skills/personal-session-handoff/SKILL.md"
finish = "### 1.4. session の記録を最後に更新する"
check.call(handoff, finish, "終了前の最後の更新", :sentences, [
  "書き込みのある作業で始めた local の session 記録を、終了前に最後に更新します",
])
check.call(handoff, finish, "未完の段の扱い", :sentences, [
  "未完の段を終了のためだけに done にしません",
])
check.call(handoff, finish, "配備先と呼ぶ場所", :sentences, [
  "配備済みの `personal-session-progress` (`<tool home>/agent-tools/scripts/`) を、session を始めた作業ツリーの root で呼びます",
])
check.call(handoff, finish, "使い方", :sentences, [
  "入力は `--help` と agent-tools の `docs/session-progress.md` に従い、`update --client CLIENT --stdin` に渡します",
])
check.call(handoff, finish, "失敗時の扱い", :sentences, [
  "更新に失敗しても整理を続け、原因を自分で直さずに、1 行で伝えます",
])

worker = "shared/skills/personal-codex-worker/SKILL.md"
check.call(worker, "## 5. 実行と完了判定", "完了の判定と転記への不使用", :sentences, [
  "記録の有無や内容を、完了の判定と転記に使わない (転記元は最終 message)",
])

abort errors.map { |error| "FAIL: #{error}" }.join("\n") unless errors.empty?
puts "ok: session-progress-wiring-test"
RUBY
