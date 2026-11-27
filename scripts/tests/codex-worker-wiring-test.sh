#!/bin/sh
# #706 の caller 契約。文は節内の続いた句、command は argv と実物の usage で照合する。
# root を引数で差し替え、契約の削除・反転・誤った option を変異で検査できる。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
require "open3"
require "shellwords"
require File.expand_path("scripts/tests/lib/codex-worker-stop-cases", ARGV.fetch(0))
MU = MarkdownUnits
root = ARGV.fetch(0)
dir = File.join(root, "shared/skills/personal-codex-worker")
skill = File.read(File.join(dir, "SKILL.md"), encoding: "UTF-8")
launch = File.read(File.join(dir, "LAUNCH.md"), encoding: "UTF-8")
errors = []
section = lambda do |text, heading|
  body = MU.section(text, heading)
  errors << "節が無い: #{heading}" unless body
  body.to_s
end
clause = lambda do |body, phrase|
  unless MU.paragraphs(body).any? { |p| MU.clause?(p, phrase) }
    errors << "句が無い: #{phrase}"
  end
end
s5 = section.call(skill, "## 5. 実行と完了判定")
s6 = section.call(skill, "## 6. 結果の転記と停止の記録")
s7 = section.call(skill, "## 7. PR (orchestrator の操作)")
clause.call(s5, "`personal-codex-worker-run launch` を呼ぶ")
clause.call(s6, "`personal-codex-worker-run collect` を呼ぶ")
clause.call(s6, "`empty-result` で `retryable: true` のときだけ、`personal-codex-worker-run retry-empty` を呼ぶ")
clause.call(s7, "`personal-codex-worker-run check` を題名と本文を渡して呼ぶ")
# check と push の間の窓は、手順で短くする (#782 の 2 つ目。人の判断 2026-11-27)。
clause.call(s7, "`READY` を受けたら、間に別の作業を挟まずに push する")
clause.call(s7, "`READY` の後に間が空いたときは、push の前に `check` をかけ直す")
clause.call(s7, "push の後、PR の作成までに間が空いたときも、PR を作る前に `check` をかけ直す")
clause.call(s7, "`READY` でなければ PR を作らない")
clause.call(s7, "人が `gate-publish.err` を確かめて公開を認めたときだけ `--accept-warnings` を付けて `check` をやり直す")
clause.call(s7, "人の確認なしに `--accept-warnings` を付けない")
clause.call(s7, "`READY` のときだけ、`check` が返した `head_oid` を指定して push する")
clause.call(s7, "PR 作成後は `personal-packet worker-update <issue> --stdin` の `review` 操作で packet を書く")
clause.call(s7, "その前に packet を読み直し、`expected_sha256` と PR 番号を渡す")
clause.call(s7, "`worker-update` の `round` 操作で修正内容と次の入口を記録する")
clause.call(s7, "`check` が BLOCKED を返したときは `worker-update` の `stop` を記録しない")
clause.call(s7, "packet は `open` のまま置き、既に `review` ならその状態を保つ")
clause.call(s7, "停止の区分と理由と人の次の手は、返却の `Next step` に書く")
clause.call(s7, "直した後に `check` をやり直す")
clause.call(s7, "worker に直させるときは `worker-update` の `round` で修正 round の項を依頼に足してから `launch` で起動する")
clause.call(s5, "起動の前に `worker-update` の `run-start` 操作で記録し、読み直してから起動する")
clause.call(s6, "結果は要約せず `worker-update` の `result` 操作で転記し、`run` を `last_run` に移す")
s3 = section.call(skill, "## 3. clone と branch")
clause.call(s3, "script が `worker-update` の `branch` 操作で保存する")

examples = section.call(launch, "## 1. 通常の呼び出しの例")
clause.call(examples, "人が `gate-publish.err` を確かめて公開を認めたときだけ `--accept-warnings` を付けて `check` をやり直す")
clause.call(examples, "人の確認なしに `--accept-warnings` を付けない")
# 許可の条件は出現する全単位に求める。正しい記述を残したまま例外を足す変更も拒否する。
[skill, launch].each do |text|
  units = MU.sentences(text) + MU.blocks(text).map(&:last)
  units.select { |unit| unit.include?("--accept-warnings") }.each do |unit|
    allowed = [
      "人が `gate-publish.err` を確かめて公開を認めたときだけ `--accept-warnings` を付けて `check` をやり直す",
      "人の確認なしに `--accept-warnings` を付けない"
    ].any? { |phrase| MU.clause?(unit, phrase) }
    errors << "warning の許可に人の確認の句が無い" unless allowed
  end
  # 自然言語すべての意味判定ではなく、明示的な直接編集の指示だけを拒否する。
  MU.sentences(text).each do |sentence|
    spans = MU.code_spans(sentence)
    if spans.include?("check") && spans.include?("stop") && !MU.clause?(sentence, "`stop` を記録しない")
      errors << "check と stop の文に記録しない句が無い"
    end
    if ["packet の frontmatter を直接書き換える", "frontmatter を手で書き換える"].any? { |p| MU.clause?(sentence, p) }
      errors << "packet の frontmatter を直接編集する指示"
    end
  end
end
# --help は副作用なし。例を shell では実行せず argv に分け、実物の usage と突き合わせる。
help, err, status = Open3.capture3("ruby", File.join(root, "shared/scripts/personal-codex-worker-run.rb"), "--help")
abort "FAIL: worker-run --help: #{err}" unless status.success?
usage = {}
help.lines.each do |line|
  next unless line.start_with?("personal-codex-worker-run ")
  sub = line.split[1]
  usage[sub] = { all: line.scan(/--[a-z-]+/), required: line.gsub(/\[[^\]]*\]/, "").scan(/--[a-z-]+/) }
end
commands = MU.sh_blocks(examples).flat_map(&:lines).reject { |l| l.strip.empty? }.map { |l| Shellwords.split(l) }
errors << "通常の例は launch 2本、collect、retry-empty、check が必要" unless commands.map { |a| a[1] } == %w[launch launch collect retry-empty check]
commands.each do |argv|
  errors << "例の実行先は runner" unless argv.shift == "$runner"
  sub = argv.shift
  spec = usage[sub]
  unless spec
    errors << "usage に無い command: #{sub}"
    next
  end
  if sub == "check"
    errors << "check の stdout を保存する" unless argv.pop(2) == [">", "$check_file"]
  end
  pairs = argv.each_slice(2).to_a
  flags = pairs.map(&:first)
  errors << "usage と一致しない option: #{sub}" unless (flags - spec[:all]).empty? && (spec[:required] - flags).empty? && flags.uniq == flags
  errors << "確認前に warning を許可する例" if flags.include?("--accept-warnings")
  values = { "--repo" => "$main", "--issue" => "$issue", "--branch" => "$branch", "--round" => "$round",
             "--wait-minutes" => "60", "--title" => "$title", "--body-file" => "$body_file" }
  errors << "引数の値または順序が不正: #{sub}" unless pairs.all? { |key, value| values[key] == value && !value.nil? }
end
publish = section.call(launch, "## 9. 回収 (fetch) と trailer 検査と PR")
clause.call(publish, "`READY` の後は、間に別の作業を挟まずに push し、push が成功したら続けて PR を作る")
clause.call(publish, "`READY` の後、push の前か PR の作成の前に間が空いたときは、その前に `check` をかけ直し")
clause.call(publish, "`READY` でなければ先へ進まない")
lines = MU.sh_blocks(publish).flat_map(&:lines).map(&:strip)
push_command = 'git -C "$main" push origin "${head_oid}:refs/heads/${branch}"'
errors << "push の例が無い" unless lines.include?(push_command)
[publish, s7].each do |body|
  MU.sh_blocks(body).flat_map(&:lines).map(&:strip).each do |line|
    next if line.start_with?("#") || !Shellwords.split(line).include?("push")
    errors << "push はすべて check の head_oid を refspec の元にする" unless line == push_command
  end
end
[s7, publish].each do |body|
  clause.call(body, "exit 1 なら `check` も push もせず、本文と出力を人に見せる")
  clause.call(body, "人が公開を認めたときだけ先へ進む")
  clause.call(body, "exit 3 は指摘を読んで直すか、理由を持って `--style-reviewed` を付けてかけ直す")
  post_at = body.index("`personal-post-check`")
  check_at = body.index(/(?:`personal-codex-worker-run check` を題名と本文を渡して呼ぶ|§1 の `check` を呼ぶ)/)
  push_at = body.index(/(?:`READY` のときだけ、`check` が返した `head_oid` を指定して push する|git -C "\$main" push)/)
  errors << "公開の順は post-check、check、OID push" unless post_at && check_at && push_at && post_at < check_at && check_at < push_at
end
recovery = section.call(launch, "## 3. 停止後の回復")
clause.call(recovery, "`check` が BLOCKED を返したときは `worker-update` の `stop` を記録しない")
clause.call(recovery, "一覧に無い `reason_code` は `Status: BLOCKED` で人に返し、自分で回避しない")
clause.call(recovery, "clone の hook の設定を自分で書き換えない")
clause.call(recovery, "`run-start` が blocked を open に戻し、記録を新しい run に置き換える")
clause.call(recovery, "この場合は `launch-path` / `tab-ownership` で止まる")
clause.call(recovery, "人が `#<issue>` の tab を確かめ、不要なら閉じる")
clause.call(recovery, "未起動の run の記録も上の手順で破棄してから `launch` し直す")
clause.call(recovery, "tab を閉じないなら §10 の未起動 hand-off で渡す")
clause.call(examples, "Claude Code では Bash tool の background (`run_in_background`) で走らせ、完了の通知を待つ")
errors << "head_oid は READY の JSON から読む" unless lines.include?(%q{head_oid=$(jq -er 'select(.status == "READY") | .head_oid' "$check_file") || exit 1})
packet = section.call(launch, "## 4. packet の更新")
errors << "packet を worker-update で書く command が無い" unless MU.sh_blocks(packet).any? { |b| b.strip == '"$packet_cli" worker-update "$issue" --stdin < "$update_file"' }
clause.call(packet, "毎回 packet を読み直し、その byte 列の SHA-256 を `expected_sha256` に指定する")
doc = File.read(File.join(root, "docs/codex-worker-run.md"), encoding: "UTF-8")
table = section.call(doc, "## 停止後の state と回復 (正本)")
rows = MU.rows(table).drop(2).map { |line| line.split("|", -1)[1...-1].map(&:strip) }
documented = rows.flat_map do |cells|
  raise "回復表の列が不正" unless cells.size == 7 && cells.all? { |v| !v.empty? }
  commands = MU.code_spans(cells[0])
  fields = cells[1..3].map { |cell| MU.code_spans(cell).fetch(0) }
  commands.map { |cmd| [cmd, *fields] }
end
source = File.read(File.join(root, "shared/scripts/personal-codex-worker-run.rb"), encoding: "UTF-8")
extracted = CodexWorkerStopCases.extract(source)
errors << "回復表の停止区分が重複" unless documented.uniq == documented
errors << "回復表の停止区分が source と不一致: missing=#{extracted - documented}, extra=#{documented - extracted}" unless documented.sort == extracted
clause.call(table, "未回収の open / run なら、人が破棄を決めた後に上の stop、launch の順を使います")
clause.call(recovery, "人手の hand-off で渡したまま起動しなかった run、終了後の snapshot 照合で止まった run")
abort "FAIL: codex-worker-wiring\n  #{errors.join("\n  ")}" unless errors.empty?
puts "ok: codex-worker-wiring"
RUBY
