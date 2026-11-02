#!/bin/sh
# Codex の review・監査・反証の待ち方の規則 (#421) が文書に残っていることを検査する。文言の検知で、振る舞いの
# 保証ではない (期待挙動は各 skill の evals.json の case。model eval は自動で走らない)。
# - personal-codex-review: wait の timeout の後に pane の foreground process で生存を見て、判定できないときは
#   「消滅」に倒さず、wait が尽きても動いていれば process を止めずに `Status: RUNNING` で返し、その run の
#   `done.txt` を確かめる前に同じ対象の review を起動し直さない (LAUNCH.md・SKILL.md §5 / §6・RESULT-FORMAT.md)。
# - personal-review-request: executor の RUNNING では結果を投稿せず、起動し直さない。
# - personal-repo-audit の CODEX-LAUNCH.md: 実行中かは今回の nonce の `done.txt` の有無だけで判定し、無ければ
#   同じ対象を新しく起動しない。
# - personal-maintenance-sweep: 監査と反証の run dir を起動の前に記録し (`codex-run` / `refute-run`)、再開では
#   次の段で Codex を起動する単位 (`pending` / `audited`) だけを、起動し直す前に回収する (`refuted` と `done` は
#   戻さない)。`done.txt` が無ければ `target_commit` に関わらず起動し直さず、あっても `target_commit` が違えば古い
#   結果も再実行も使わない。fix モードの review の RUNNING も起動し直さない。
# - evals.json に各 case がある。
# 規則の文は文の頭から文末の「。」まで含め、所定の節の中にあることを、改行と空白を除いて比べる (後ろに否定を
# 足す・続きを消す・節の外へ移すと落ちる)。一覧と表は文でないので、行の全体で比べる。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
require "json"

root = ARGV.fetch(0)
errors = []
squash = ->(s) { s.gsub(/\s+/, "") }
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

# 見出し (`#` の数で level を決める) から、同じか上の level の次の見出しまで。
section = lambda do |text, heading|
  level = heading[/\A#+/].size
  body = text[/^#{Regexp.escape(heading)}\n(.*?)(?=^\#{1,#{level}} |\z)/m, 1]
  body && squash.call(body)
end

check = lambda do |rel, heading, label, phrase|
  body = section.call(read.call(rel), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
  elsif !body.include?(squash.call(phrase))
    errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い"
  end
end

review = "shared/skills/personal-codex-review"
check.call("#{review}/LAUNCH.md", "### herdr 経由", "生存の確認",
           "timeout したら `herdr pane process-info --pane <pane-id>` で pane の foreground process (`result.process_info.foreground_processes[].name`) に `codex` が居るかを見ます (`personal-codex-worker` の `LAUNCH.md` §6 と同じ判定。#421)。")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "executor-exit にする条件",
           "**居ないと確認できて** `done.txt` が無ければ `Blocked at: executor-exit` で停止します。")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "判定できないときの扱い",
           "process-info が失敗する・解釈できないときは「消滅」に倒さず、居るときと同じく wait を続けます。")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "wait が尽きたときの RUNNING",
           "process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返します (雛形は `RESULT-FORMAT.md`)。")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "起動し直さない規則",
           "その run の `done.txt` を確かめる前に、同じ対象の review を起動し直しません (2 本目が並んで走る)。")
check.call("#{review}/SKILL.md", "## 5. 実行と完了判定", "§5 の待ち方",
           "生きていれば wait を繰り返し (合計 3 回まで)、尽きても `done.txt` が無ければ、process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返す。")
check.call("#{review}/SKILL.md", "## 5. 実行と完了判定", "§5 の起動し直さない規則",
           "その前に同じ対象の review を起動し直さない (2 本目が並んで走る)。")
check.call("#{review}/SKILL.md", "## 6. 返却形式", "§6 の RUNNING の返却",
           "wait が尽きても review が動いているときは verdict を作らず、`Status: RUNNING`、pane id・run dir・nonce、Next step (pane を見て続行か中断かを人が決める。続行なら `done.txt` を待って同じ続行条件で回収する。run script を再実行しない)、`Independence: not-established` を返す (#421)。")
format = read.call("#{review}/RESULT-FORMAT.md")
errors << "#{review}/RESULT-FORMAT.md に `Status: RUNNING` の雛形が無い" unless format.include?("```text\nStatus: RUNNING\nPane: <pane id> / Run dir: <path> / Nonce: <nonce>\n")

request = "shared/skills/personal-review-request/SKILL.md"
check.call(request, "### 3. レビュー実行", "executor の RUNNING の扱い",
           "executor が `Status: RUNNING` (wait が尽きても review が動いている。#421) を返したら、結果のコメントは投稿せず、同じ対象の review を起動し直さない。")
check.call(request, "### 3. レビュー実行", "RUNNING の判断の主体",
           "返った pane と run dir を人に示し、続行か中断かを人が決める (executor の `RESULT-FORMAT.md`)。")
check.call(request, "### 3. レビュー実行", "RUNNING の回収",
           "続行なら、その run dir の `done.txt` を待って executor と同じ続行条件で回収し、回収できたら手順 4 に進む。")

launch = "shared/skills/personal-repo-audit/CODEX-LAUNCH.md"
check.call(launch, "## 完了の判定", "done.txt だけで判定する規則",
           "判定は今回の nonce の `done.txt` の有無だけで行い、pane や process の有無では判定しません (`personal-grill-me` の `CONSULT.md` の相談と同じ。#421)。")
check.call(launch, "## 完了の判定", "起動し直さない規則",
           "その run の `done.txt` が現れるまで、同じ対象の監査 (反証) を新しく起動しません (2 本目が並んで走り、使用量を二重に使う)。")

sweep = "shared/skills/personal-maintenance-sweep"
resume = "## 発火とモード"
check.call("#{sweep}/SKILL.md", resume, "再開の回収の対象",
           "どちらの場合も、Codex を起動し直す前に、次の段で Codex を起動する単位の run の記録を見る: `pending` の単位は監査の `units/<n>/codex-run`、`audited` の単位は反証の run の `refute-run` (`RECORD.md`)。")
check.call("#{sweep}/SKILL.md", resume, "回収済みの状態を戻さない規則",
           "`refuted` と `done` の単位は、回収済みなので見ない (状態を戻さない)。")
check.call("#{sweep}/SKILL.md", resume, "done.txt が無いときの扱い",
           "記録した run dir に、その run の nonce (run script の先頭に埋めた値) の `done.txt` が無ければ、Codex がまだ動いている (止まったとは限らない) として、`target_commit` に関わらず起動し直さず、run dir を添えて人に返す (`CODEX-LAUNCH.md` の「完了の判定」の実行中。止めるかは人が決める)。")
check.call("#{sweep}/SKILL.md", resume, "target_commit が違うときの扱い",
           "`done.txt` があり、`target_commit` が今の `HEAD` と違えば、古い run の結果は使わず、再実行もしない (上のとおり新しい run として監査からやり直す)。")
check.call("#{sweep}/SKILL.md", resume, "回収した単位の状態の進め方",
           "満たせば結果を保存して、その単位を次の状態に進める (監査の結果は `pending` → `audited`、反証の結果は、反証に含めた単位を `audited` → `refuted`)。")
check.call("#{sweep}/SKILL.md", "### 3. 監査する (単位ごと)", "監査の run dir の記録",
           "起動の前に、run dir の path を `units/<n>/codex-run` に書く (再開で回収するため。`RECORD.md`。#421)。")
# 一覧と表は文でないので、行の全体で比べる。
check.call("#{sweep}/RECORD.md", "## local の state", "反証の run dir の記録",
           "refute-run                Codex に反証させたときの run dir の path (1 行。起動の前に書く。#421)")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "反証の run dir の記録の行",
           "| run dir の path の記録 (起動の前。再開で回収する。#421) | sweep の `units/<n>/codex-run` | sweep の run の `refute-run` (`RECORD.md`) |")
check.call("#{sweep}/FIX.md", "## review", "fix モードの review の RUNNING",
           "executor が `Status: RUNNING` (wait が尽きても review が動いている。#421) を返したときも、その round を結果なしの記録のまま `blocked` にして人に渡し、新しい round を起動しません (再開で上の回収の手順に入る)。")

{
  review => %w[wait-cap-running-not-killed],
  "shared/skills/personal-repo-audit" => %w[codex-launch-no-done-is-running],
  sweep => %w[resume-collects-codex-run-first resume-target-changed-no-retry],
  "shared/skills/personal-review-request" => %w[codex-review-running-no-comment],
}.each do |dir, names|
  evals = JSON.parse(read.call("#{dir}/evals/evals.json"))["evals"]
  names.each do |name|
    errors << "#{dir}/evals/evals.json に case #{name} が無い" unless evals.any? { |e| e["name"] == name }
  end
  ids = evals.map { |e| e["id"] }
  errors << "#{dir}/evals/evals.json の id が重複している" unless ids.uniq.size == ids.size
end

abort "FAIL: codex-wait-running\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: codex-wait-running"
RUBY
