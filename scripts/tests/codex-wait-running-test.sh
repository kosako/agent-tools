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
#   起動し直す前に回収する。`done.txt` が無ければ起動し直さない。fix モードの review の RUNNING も同じ。
# - evals.json に各 case がある。
# 規則の文は文末の「。」まで含め、所定の節の中にあることを、改行と空白を除いて比べる (後ろに否定を足す・
# 節の外へ移すと落ちる)。
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
           "timeout したら `herdr pane process-info --pane <pane-id>` で pane の foreground process")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "判定できないときの扱い",
           "process-info が失敗する・解釈できないときは「消滅」に倒さず、居るときと同じく wait を続けます。")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "wait が尽きたときの RUNNING",
           "process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返します")
check.call("#{review}/LAUNCH.md", "### herdr 経由", "起動し直さない規則",
           "その run の `done.txt` を確かめる前に、同じ対象の review を起動し直しません (2 本目が並んで走る)。")
check.call("#{review}/SKILL.md", "## 5. 実行と完了判定", "§5 の待ち方",
           "尽きても `done.txt` が無ければ、process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返す。")
check.call("#{review}/SKILL.md", "## 5. 実行と完了判定", "§5 の起動し直さない規則",
           "その前に同じ対象の review を起動し直さない (2 本目が並んで走る)。")
check.call("#{review}/SKILL.md", "## 6. 返却形式", "§6 の RUNNING の返却",
           "wait が尽きても review が動いているときは verdict を作らず、`Status: RUNNING`、pane id・run dir・nonce、")
format = read.call("#{review}/RESULT-FORMAT.md")
errors << "#{review}/RESULT-FORMAT.md に `Status: RUNNING` の雛形が無い" unless format.include?("```text\nStatus: RUNNING\nPane: <pane id> / Run dir: <path> / Nonce: <nonce>\n")

check.call("shared/skills/personal-review-request/SKILL.md", "### 3. レビュー実行", "executor の RUNNING の扱い",
           "`Status: RUNNING` (wait が尽きても review が動いている。#421) を返したら、結果のコメントは投稿せず、同じ対象の review を起動し直さない。")

launch = "shared/skills/personal-repo-audit/CODEX-LAUNCH.md"
check.call(launch, "## 完了の判定", "done.txt だけで判定する規則",
           "判定は今回の nonce の `done.txt` の有無だけで行い、pane や process の有無では判定しません")
check.call(launch, "## 完了の判定", "起動し直さない規則",
           "その run の `done.txt` が現れるまで、同じ対象の監査 (反証) を新しく起動しません (2 本目が並んで走り、使用量を二重に使う)。")

sweep = "shared/skills/personal-maintenance-sweep"
check.call("#{sweep}/SKILL.md", "## 発火とモード", "再開の回収の規則",
           "Codex を起動し直す前に、`done` でない単位の Codex の run の記録 (監査は `units/<n>/codex-run`、反証は run の `refute-run`。`RECORD.md`) を見る。")
check.call("#{sweep}/SKILL.md", "## 発火とモード", "done.txt が無いときの扱い",
           "その run の nonce (run script の先頭に埋めた値) の `done.txt` が無ければ、Codex がまだ動いている (止まったとは限らない) として起動し直さず、")
check.call("#{sweep}/SKILL.md", "### 3. 監査する (単位ごと)", "監査の run dir の記録",
           "起動の前に、run dir の path を `units/<n>/codex-run` に書く (再開で回収するため。`RECORD.md`。#421)。")
check.call("#{sweep}/RECORD.md", "## local の state", "反証の run dir の記録",
           "refute-run                Codex に反証させたときの run dir の path (1 行。起動の前に書く。#421)")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "反証の run dir の記録の行",
           "| run dir の path の記録 (起動の前。再開で回収する。#421) | sweep の `units/<n>/codex-run` | sweep の run の `refute-run` (`RECORD.md`) |")
check.call("#{sweep}/FIX.md", "## review", "fix モードの review の RUNNING",
           "その round を結果なしの記録のまま `blocked` にして人に渡し、新しい round を起動しません")

{
  review => "wait-cap-running-not-killed",
  "shared/skills/personal-repo-audit" => "codex-launch-no-done-is-running",
  sweep => "resume-collects-codex-run-first",
  "shared/skills/personal-review-request" => "codex-review-running-no-comment",
}.each do |dir, name|
  evals = JSON.parse(read.call("#{dir}/evals/evals.json"))["evals"]
  errors << "#{dir}/evals/evals.json に case #{name} が無い" unless evals.any? { |e| e["name"] == name }
  ids = evals.map { |e| e["id"] }
  errors << "#{dir}/evals/evals.json の id が重複している" unless ids.uniq.size == ids.size
end

abort "FAIL: codex-wait-running\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: codex-wait-running"
RUBY
