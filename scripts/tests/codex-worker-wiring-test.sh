#!/bin/sh
# #706 の caller 契約。文は節内の続いた句、command は argv と実物の usage で照合する。
# root を引数で差し替え、契約の削除・反転・誤った option を変異で検査できる。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
require "open3"
require "shellwords"
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
clause.call(s7, "人が `gate-publish.err` を確かめたときだけ `--accept-warnings` を付ける")
clause.call(s7, "人の確認なしに `--accept-warnings` を付けない")
clause.call(s7, "`READY` のときだけ、`check` が返した `head_oid` を指定して push する")
clause.call(s7, "PR 作成後は `personal-packet worker-update <issue> --stdin` の `review` 操作で packet を書く")
clause.call(s7, "その前に packet を読み直し、`expected_sha256` と PR 番号を渡す")
clause.call(s7, "`worker-update` の `round` 操作で修正内容と次の入口を記録する")
clause.call(s7, "`open` なら `worker-update` の `stop` 操作で区分と固定の理由を記録する")
clause.call(s5, "起動の前に `worker-update` の `run-start` 操作で記録し、読み直してから起動する")
clause.call(s6, "結果は要約せず `worker-update` の `result` 操作で転記し、`run` を `last_run` に移す")
s3 = section.call(skill, "## 3. clone と branch")
clause.call(s3, "script が `worker-update` の `branch` 操作で保存する")

examples = section.call(launch, "## 1. 通常の呼び出しの例")
clause.call(examples, "人が `gate-publish.err` を確かめたときだけ `--accept-warnings` を付ける")
clause.call(examples, "人の確認なしに `--accept-warnings` を付けない")
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
lines = MU.sh_blocks(publish).flat_map(&:lines).map(&:strip)
errors << "push は check の head_oid を使う" unless lines.include?('git -C "$main" push origin "${head_oid}:refs/heads/${branch}"')
errors << "head_oid は READY の JSON から読む" unless lines.include?(%q{head_oid=$(jq -er 'select(.status == "READY") | .head_oid' "$check_file") || exit 1})
packet = section.call(launch, "## 4. packet の更新")
errors << "packet を worker-update で書く command が無い" unless MU.sh_blocks(packet).any? { |b| b.strip == '"$packet_cli" worker-update "$issue" --stdin < "$update_file"' }
clause.call(packet, "毎回 packet を読み直し、その byte 列の SHA-256 を `expected_sha256` に指定する")
abort "FAIL: codex-worker-wiring\n  #{errors.join("\n  ")}" unless errors.empty?
puts "ok: codex-worker-wiring"
RUBY
