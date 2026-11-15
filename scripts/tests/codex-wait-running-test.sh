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
# 規則の句は、条件から処理までを続いた 1 つの句として、文・項目・段落のどれか 1 つの単位の中で探す。前の文を受ける文
# (「その run の」「その前に」「満たせば」など) は、受ける文から続く文のつながり (helper の sentence_runs) で組にして見る。
# 表は行の単位、fence の中の一覧は block の行の単位で比べる。節の全体からは探さない (句が別の単位や分岐へ移っただけの
# 変更を通さないため)。文書を単位に分ける読み方と、受ける整形の範囲は lib/markdown_units.rb が持つ (#685)。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
# encoding: UTF-8
require "json"

root = ARGV.fetch(0)
errors = []
MU = MarkdownUnits
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }
KIND_NAMES = { items: "項目", bullets: "項目", sentences: "文", paragraphs: "段落", rows: "表の行", block_lines: "fence の中の行" }.freeze

section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節を kind の単位に分ける。表の行は fence の外で `|` から始まる行、fence の中の行は block の 1 行ずつ。
units_of = lambda do |body, kind|
  case kind
  when :rows then MU.prose(body).lines.select { |l| l.lstrip.start_with?("|") }
  when :block_lines then MU.blocks(body).flat_map { |_, text| text.lines }
  else MU.public_send(kind, body)
  end
end

# 節の中の kind の単位のうち、key を含むものがある。terms があれば、key と同じ単位に terms がすべてある。
check = lambda do |rel, heading, label, kind, key, terms = []|
  body = section.call(rel, heading)
  next if body.nil?
  hits = MU.containing(units_of.call(body, kind), key)
  if hits.empty?
    errors << "#{rel} の「#{heading}」に、#{label} (#{key.inspect}) を含む#{KIND_NAMES.fetch(kind)}が無い"
  elsif terms.any? && hits.none? { |u| MU.missing(u, terms).empty? }
    errors << "#{rel} の「#{heading}」の#{label}の#{KIND_NAMES.fetch(kind)}に #{MU.missing(hits[0], terms).map(&:inspect).join("、")} が無い"
  end
end

# 節の中で、key を含む文から始まる n 個の文のつながりのどれかに、terms がすべてある。つながりは、key を含む項目 (helper の
# bullets。字下げした子の項目は親と分ける。within が :paragraphs なら段落) の中だけで数える。受ける文を別の項目へ切り出した変更を通さないため (項目の境目をまたいで数えると、
# 切り出しても隣の文のまま通る)。
run_check = lambda do |rel, heading, label, key, n, terms, within = :bullets|
  body = section.call(rel, heading)
  next if body.nil?
  runs = MU.containing(MU.public_send(within, body), key).flat_map { |u| MU.sentence_runs(u, key, n) }
  if runs.empty?
    errors << "#{rel} の「#{heading}」に、#{label} (#{key.inspect}) を含む文が無い"
  elsif runs.none? { |r| MU.missing(r, terms).empty? }
    errors << "#{rel} の「#{heading}」の#{label}の、#{key.inspect} から #{n} 文に #{MU.missing(runs[0], terms).map(&:inspect).join("、")} が無い"
  end
end

review = "shared/skills/personal-codex-review"
herdr = "### herdr 経由"
lm = "#{review}/LAUNCH.md"
check.call(lm, herdr, "生存の確認", :bullets,
           "timeout したら `herdr pane process-info --pane <pane-id>` で pane の foreground process (`result.process_info.foreground_processes[].name`) に `codex` が居るかを見ます (`personal-codex-worker` の `LAUNCH.md` §6 と同じ判定。#421)。")
check.call(lm, herdr, "executor-exit にする条件", :bullets, "**居ないと確認できて** `done.txt` が無ければ `Blocked at: executor-exit` で停止します。")
check.call(lm, herdr, "判定できないときの扱い", :bullets, "process-info が失敗する・解釈できないときは「消滅」に倒さず、居るときと同じく wait を続けます。")
# RUNNING で返す文は、wait が尽きたときの文を受ける。起動し直さない文 (「その run の」) は、後から done.txt が現れたときの文を
# 受ける (間に safe-run の注意の文が挟まるので、つながりを 2 つに分ける)。
run_check.call(lm, herdr, "wait が尽きたときの RUNNING",
               "3 回の wait が尽きても `done.txt` が無く、codex が居る (または居ないと確認できない) ときは、review はまだ動いています", 2,
               ["process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返します (雛形は `RESULT-FORMAT.md`)。"])
run_check.call(lm, herdr, "起動し直さない規則", "後から `done.txt` が現れたら、同じ続行条件で判定して結果を読みます", 2,
               ["その run の `done.txt` を確かめる前に、同じ対象の review を起動し直しません (2 本目が並んで走る)。"])
skill = "#{review}/SKILL.md"
run_check.call(skill, "## 5. 実行と完了判定", "§5 の待ち方と起動し直さない規則",
               "生きていれば wait を繰り返し (合計 3 回まで)、尽きても `done.txt` が無ければ、process を止めずに `Status: RUNNING` で pane id・run dir・nonce を返す。", 3,
               ["RUNNING の run は、後から `done.txt` を同じ続行条件で確かめて回収する。",
                "その前に同じ対象の review を起動し直さない (2 本目が並んで走る)。"])
check.call(skill, "## 6. 返却形式", "§6 の RUNNING の返却", :bullets,
           "wait が尽きても review が動いているときは verdict を作らず、`Status: RUNNING`、pane id・run dir・nonce、Next step (pane を見て続行か中断かを人が決める。続行なら `done.txt` を待って同じ続行条件で回収する。run script を再実行しない)、`Independence: not-established` を返す (#421)。")
check.call(skill, "## 5. 実行と完了判定", "続行条件の verdict の行", :bullets,
           "どの経路でも続行条件は「`done.txt` の nonce 一致と `exit=0`」かつ「`result.md` が存在し空でない」かつ「`result.md` に `Review process verdict:` の行がある」の 3 つ (結果の採用、pane の後始末、再開や RUNNING の後の回収のどれも、この 3 つで判定する)。")
check.call(lm, "### 結果 file の判定 (空振り)", "verdict の無い結果で止める規則", :paragraphs,
           "空でなくても `Review process verdict:` の行が無ければ (Codex が verdict を出さずに止まった)、完了として扱わず、再実行もせずに `Blocked at: executor-result` で停止します。")
format = "#{review}/RESULT-FORMAT.md"
running = MU.blocks(read.call(format)).any? do |info, text|
  info == "text" && MU.squash(text).start_with?(MU.squash("Status: RUNNING\nPane: <pane id> / Run dir: <path> / Nonce: <nonce>"))
end
errors << "#{format} に `Status: RUNNING` の雛形 (text の block) が無い" unless running

request = "shared/skills/personal-review-request/SKILL.md"
step3 = "### 3. レビュー実行"
check.call(request, step3, "executor の RUNNING の扱い", :bullets,
           "executor が `Status: RUNNING` (wait が尽きても review が動いている。#421) を返したら、結果のコメントは投稿せず、同じ対象の review を起動し直さない。")
# 人が決める文と回収の文は、RUNNING を返したときの文を受ける。
run_check.call(request, step3, "RUNNING の判断の主体と回収", "を返したら、結果のコメントは投稿せず、同じ対象の review を起動し直さない", 3,
               ["返った pane と run dir を人に示し、続行か中断かを人が決める (executor の `RESULT-FORMAT.md`)。",
                "続行なら、その run dir の `done.txt` を待って executor と同じ続行条件で回収し、回収できたら手順 4 に進む。"])

launch = "shared/skills/personal-repo-audit/CODEX-LAUNCH.md"
done_h = "## 完了の判定"
check.call(launch, done_h, "done.txt だけで判定する規則", :bullets,
           "判定は今回の nonce の `done.txt` の有無だけで行い、pane や process の有無では判定しません (`personal-grill-me` の `CONSULT.md` の相談と同じ。#421)。")
check.call(launch, done_h, "起動し直さない規則", :bullets,
           "`Status: RUNNING` で pane (あれば)・run dir・nonce を返して人に渡し、その run の `done.txt` が現れるまで、同じ対象の監査 (反証) を新しく起動しません (2 本目が並んで走り、使用量を二重に使う)。")

sweep = "shared/skills/personal-maintenance-sweep"
resume = "## 発火とモード"
ss = "#{sweep}/SKILL.md"
# 回収済みの状態を戻さない文は、回収の対象の文を受ける。
run_check.call(ss, resume, "再開の回収の対象と、回収済みの状態を戻さない規則",
               "**Codex の run を先に回収する (#421)**: どちらの場合も、Codex を起動し直す前に、次の段で Codex を起動する単位の run の記録を見る: `pending` の単位は監査の `units/<n>/codex-run`、`audited` の単位は反証の run の `refute-run` (`RECORD.md`)。", 2,
               ["`refuted` と `done` の単位は、回収済みなので見ない (状態を戻さない)。"])
check.call(ss, resume, "done.txt が無いときの扱い", :bullets,
           "記録した run dir に、その run の nonce (run script の先頭に埋めた値) の `done.txt` が無ければ、Codex がまだ動いている (止まったとは限らない) として、`target_commit` に関わらず起動し直さず、run dir を添えて人に返す (`CODEX-LAUNCH.md` の「完了の判定」の実行中。止めるかは人が決める)。")
check.call(ss, resume, "target_commit が違うときの扱い", :bullets,
           "`done.txt` があり、`target_commit` が今の `HEAD` と違えば、古い run の結果は使わず、再実行もしない (上のとおり新しい run として監査からやり直す)。")
# 「満たせば」は、target_commit が同じときの文を受ける。
run_check.call(ss, resume, "回収した単位の状態の進め方", "`done.txt` があり、`target_commit` が今の `HEAD` と同じなら、同じ続行の条件で判定する", 2,
               ["満たせば結果を保存して、その単位を次の状態に進める (監査の結果は `pending` → `audited`、反証の結果は、反証に含めた単位を `audited` → `refuted`)。"])
check.call(ss, "### 3. 監査する (単位ごと)", "監査の run dir の記録", :bullets,
           "起動の前に、run dir の path を `units/<n>/codex-run` に書く (再開で回収するため。`RECORD.md`。#421)。")
check.call("#{sweep}/RECORD.md", "## local の state", "反証の run dir の記録", :block_lines,
           "refute-run                Codex に反証させたときの run dir の path (1 行。起動の前に書く。#421)")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "反証の run dir の記録の行", :rows,
           "| run dir の path の記録 (起動の前。再開で回収する。#421) | sweep の `units/<n>/codex-run` | sweep の run の `refute-run` (`RECORD.md`) |")
check.call("#{sweep}/FIX.md", "## review", "fix モードの review の RUNNING", :bullets,
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
