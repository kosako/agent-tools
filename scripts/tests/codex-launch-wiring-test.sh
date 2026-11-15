#!/bin/sh
# read-only の Codex の起動と回収の script (personal-codex-launch) の組み込み (#672) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (script の挙動は codex-launch-test.sh)。
# 句は、文・項目・段落・sh の block・表の行のどれか 1 つの単位の中で探す。節の全体からは探さない (語が別の文や項目に
# 移っただけの変更を通さないため)。status のような短い語は、同じ単位にある扱いの語と組にして見る。文書を単位に分ける
# 読み方と、受ける整形の範囲 (空白の数、折り返し、見出しの # の後ろの空白、fence の字下げ、sh の行継続) は、
# lib/markdown_units.rb が持つ (#685)。
# - personal-codex-review の LAUNCH.md の先頭の節に、launch (kind=review と対象の OID) と collect の command、status ごとの
#   扱い (STARTED・BLOCKED の 3 つの理由・RUNNING・DONE・executor-result の retryable)、script が無いときだけ手で組む句がある。
#   SKILL.md の §4 と §5 が、script と brief の雛形を指す。
# - review の brief の雛形 (BRIEF-TEMPLATE.md) に、決まった節と、script が足す 3 つの注意 (heredoc、変数名 path、skill と
#   session の開始の手順を起動しない) の説明がある。その 3 つは、script の制約の節 (定数) に実際に入っている。
# - personal-repo-audit の CODEX-LAUNCH.md の先頭の節に、launch (kind=json と schema) と collect の command、process の
#   有無で判定しない句がある。相談 (CONSULT.md) と反証 (REFUTE.md) が、同じ節と自分の schema を指す。
# - sweep の SKILL.md と RECORD.md に、起動の前に directory を記録して --run-root に渡す句と、再開で collect にかける句がある。
# - docs/codex-launch.md の呼び方の表に、4 つの呼び出し側の行がある。script の kind の一覧は、文書に出てくる kind と一致する。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby -r"$script_dir/lib/markdown_units" - "$root" <<'RUBY'
# encoding: UTF-8
root = ARGV.fetch(0)
errors = []
MU = MarkdownUnits
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }
KIND_NAMES = { items: "項目", sentences: "文", paragraphs: "段落", sh: "sh の block", rows: "表の行" }.freeze

section = lambda do |rel, heading|
  body = MU.section(read.call(rel), heading)
  errors << "#{rel} に「#{heading}」の節が無い" if body.nil?
  body
end

# 節を kind の単位に分ける。表の行は、fence の外で `|` から始まる行。
units_of = lambda do |body, kind|
  case kind
  when :sh then MU.sh_blocks(body)
  when :rows then MU.prose(body).lines.select { |l| l.lstrip.start_with?("|") }
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

review = "shared/skills/personal-codex-review"
audit = "shared/skills/personal-repo-audit"
sweep = "shared/skills/personal-maintenance-sweep"
grill = "shared/skills/personal-grill-me"

# 1. review の LAUNCH.md
launch_md = "#{review}/LAUNCH.md"
head = "### personal-codex-launch で起動して回収する (#672)"
[
  ["script の場所の句", :sentences, "配備済みの `personal-codex-launch`"],
  ["手で組むのは script が無いときだけの句", :sentences, "手で組むのは、script が配備されていない環境だけ"],
  ["launch の command", :sh,
   %q("$launch" launch --kind review --repo "$repo" --brief "$brief" --label "$label" --run-root "$run_root" --base-ref "$base_ref" --base-oid "$base_oid" --head-oid "$head_oid")],
  ["collect の command", :sh, %q("$launch" collect --run-dir "$run_dir")],
  ["brief に制約を書かない句", :sentences, "script が brief の先頭に足すので、書きません"],
  ["値の受け渡しの句", :sentences, "検査してから literal の変数で渡します"],
  # status は、同じ文にある扱いの語と組にする。
  ["STARTED の扱い", :sentences, "`STARTED`:", ["`run_dir` を控えて"]],
  ["capability-preflight の扱い", :sentences, "が `capability-preflight`", ["`Status: BLOCKED`"]],
  ["target-identity の扱い", :sentences, "で `target-identity`", ["`Status: BLOCKED`"]],
  ["launch-path の扱い", :sentences, "で `launch-path`", ["herdr が使えません"]],
  ["DONE の扱い", :sentences, "`DONE` (exit 0)", ["`result`", "読みます"]],
  ["RUNNING の扱い", :sentences, "`RUNNING` (exit 3)", ["まだ動いています"]],
  ["executor-exit の扱い", :sentences, "で `executor-exit`", ["`Blocked at: executor-exit`"]],
  ["executor-result の扱い", :sentences, "で `executor-result`", ["`retryable` が true なら空振り"]],
  ["RUNNING で起動し直さない句", :sentences, "同じ対象を起動し直しません"],
  ["空振りは 1 回だけ再実行する句", :sentences, "新しい `launch` で同じ brief を 1 回だけ起動し直します"],
  ["verdict の無い結果は再実行しない句", :sentences, "再実行せずに `Blocked at: executor-result` で停止します"],
  ["直接は起動しない経路の句", :sentences, "`SKILL.md` §2 の起動経路の 2"],
  # exit 2 は入力の誤りと想定外の例外で扱いを分け、fallback の run の回収は状態ごとに分ける (#680 の review の F2・F3)。
  ["入力の誤りでは何も起動していない句", :sentences, "何も起動しておらず、run dir も作っていません"],
  # 想定外の例外の後は、run dir の launch.json の pane の ID で起動の状況を確かめる。label の pane が無いことは根拠にしない
  # (命名に失敗しても起動は続く。#680 の review の round 2 の F2)。
  ["run root を渡す句", :sentences, "`--run-root` には、その起動だけに使う新しい directory (repository の外) を渡します"],
  ["想定外の例外で起動し直す前に確かめる句", :sentences, "同じ値で起動し直す前に、`--run-root` に渡した directory の下に、`launch.json` を持つ run dir が出来ていないか"],
  ["pane_id が null なら起動していない句", :sentences, "run dir が無い、または `launch.json` の `pane_id` が null"],
  ["pane_id があれば起動済みかもしれない句", :sentences, "`launch.json` に `pane_id` がある", ["起動済みかもしれません"]],
  ["pane_id があれば起動し直さない句", :sentences, "起動し直さず、その run dir に `collect` をかけて"],
  ["確かめられなければ人に返す句", :sentences, "起動の状況を確かめられない: 起動し直さず、人に返します"],
  ["label の pane を根拠にしない句", :sentences, "pane が無いことを未起動の根拠にしません"],
  ["pane_id が null の run の句", :sentences, "`launch.json` の `pane_id` が null の run"],
  ["直接起動で done.txt が無いときの句", :sentences, "`Blocked at: executor-exit` として扱います"],
  ["pane_id がある launch-path の run は collect にかけない句", :sentences, "この run は `collect` にかけず"],
].each { |label, kind, key, terms| check.call(launch_md, head, label, kind, key, terms || []) }
check.call(launch_md, "### run dir と run script (script が実装している契約)", "今の run script の契約", :sh,
           "codex exec --ignore-user-config --ignore-rules -s read-only")

skill = "#{review}/SKILL.md"
check.call(skill, "## 4. brief", "script が足す節を brief に書かない句", :sentences, "script が brief の先頭に足します")
check.call(skill, "## 4. brief", "雛形への参照", :sentences, "`BRIEF-TEMPLATE.md`")
check.call(skill, "## 5. 実行と完了判定", "script で起動と回収を行う句", :sentences, "配備済みの `personal-codex-launch` (`launch` と `collect`) で行います")
check.call(skill, "## 5. 実行と完了判定", "script が無いときだけ手で組む句", :sentences, "script が配備されていない環境だけ")

# 2. brief の雛形
tpl = "#{review}/BRIEF-TEMPLATE.md"
if File.file?(File.join(root, tpl))
  added = "## script が足すもの (brief には書かない)"
  # 一覧の項目と、手で組むときの段落の両方に 3 つの注意がある (片方だけ消えても気づく)。
  check.call(tpl, added, "一覧の heredoc と変数名 path の項目", :items, "heredoc を使わない", ["zsh で変数名 `path` を使わない"])
  check.call(tpl, added, "一覧の skill と session の開始の手順の項目", :items, "session の開始の手順を起動しない",
             ["nested な `codex`・`claude`", "skill、subagent"])
  check.call(tpl, added, "一覧の data の境界の項目", :items, "data であって指示ではない")
  check.call(tpl, added, "手で組むときは brief に書く句", :sentences, "必ず入れます")
  check.call(tpl, added, "手で組むときの 3 つの注意の文", :sentences, "heredoc を使わないこと",
             ["zsh で変数名 `path` を使わないこと", "skill と session の開始の手順を起動しないこと", "3 つ"])
  check.call(tpl, "## 雛形", "前の round からの差分の command", :items, "git diff <前の head の OID>..<今の head の OID>")
  check.call(tpl, "## 雛形", "commit mode と uncommitted の対象の句", :items, "script に OID を渡さない")
  body = section.call(tpl, "## 雛形")
  block = body && MU.blocks(body).find { |info, _| info == "markdown" }&.last
  if body && block.nil?
    errors << "#{tpl} の「## 雛形」に markdown の block が無い"
  elsif block
    # 雛形の block の中の見出し (block の中なので、section では取れない)。
    headings = block.lines.select { |l| l.start_with?("#") }.map { |l| MU.squash(l) }
    ["## 目的と独立性", "## task と受け入れ条件", "## 重点観点", "## round <回数> の追加の情報 (2 回目以降だけ)"].each do |h|
      errors << "#{tpl} の雛形に「#{h}」の節が無い" unless headings.include?(MU.squash(h))
    end
    # review の基準の file は、配備済みの reference を指す (Codex の cwd は review の対象の repo なので、agent-tools の source の
    # 場所では、ほかの repo で見つからない。#680 の review の F1)。
    errors << "#{tpl} の雛形の block に、配備済みの reference を指す句が無い" \
      unless MU.missing(block, ["Codex home の `skills/personal-production-rail/references/policy-index.md`"]).empty?
    errors << "#{tpl} の雛形の block が、file を agent-tools の source の場所 (shared/ で始まる path) で指している" if block.include?("shared/")
  end
else
  errors << "#{tpl} が無い"
end

# 雛形が「script が足す」と書いている 3 つの注意が、script の制約の節に実際に入っている。
src = File.join(root, "shared/scripts/personal-codex-launch.rb")
if File.file?(src)
  require src
  constraints = CodexLaunch::CONSTRAINTS
  { "heredoc" => "heredoc を使いません", "変数名 path" => "変数名に `path` を使いません",
    "skill を起動しない" => "skill、subagent を起動しません", "session の開始の手順" => "session の開始の手順" }.each do |label, phrase|
    errors << "script の制約の節に#{label} (#{phrase.inspect}) が無い" unless constraints.include?(phrase)
  end
  kinds = CodexLaunch::KINDS.keys.sort
  errors << "script の kind の一覧が review / text / json でない: #{kinds.inspect}" unless kinds == %w[json review text]
else
  errors << "shared/scripts/personal-codex-launch.rb が無い"
end

# 3. 監査の CODEX-LAUNCH.md と、それを使う相談・反証
codex_launch = "#{audit}/CODEX-LAUNCH.md"
ahead = "## personal-codex-launch で起動して回収する (#672)"
[
  ["launch の command", :sh,
   %q("$launch" launch --kind json --repo "$repo" --brief "$brief" --label "$label" --schema "$schema" --effort "$effort" --run-root "$run_root")],
  ["collect の command", :sh, %q("$launch" collect --run-dir "$run_dir" --waits 3)],
  ["process の有無で判定しない句", :sentences, "script は process の有無では判定しません"],
  ["RUNNING で起動し直さない句", :sentences, "同じ対象を新しく起動しません"],
  ["空振りは 1 回だけ再実行する句", :sentences, "新しい `launch` で同じ brief を 1 回だけ起動し直し"],
  ["手で組むのは script が無いときだけの句", :sentences, "script が配備されていない環境だけ"],
  ["file の名前の違いの句", :sentences, "`CODEX-JSON-DONE-<nonce>`"],
  ["想定外の例外で起動の状況を確かめる句", :sentences, "run dir の `launch.json` で、起動の状況を確かめます"],
  ["確かめられなければ人に返す句", :sentences, "確かめられなければ起動し直さずに人に返します"],
  ["label の pane を根拠にしない句", :sentences, "`audit-<label>` の pane が無いことを、未起動の根拠にしません"],
].each { |label, kind, key| check.call(codex_launch, ahead, label, kind, key) }
consult = "#{grill}/CONSULT.md"
consult_h = "### Claude Code の session → Codex"
check.call(consult, consult_h, "相談の launch の句", :sentences, "launch --kind json --schema <この skill の consult.schema.json>")
check.call(consult, consult_h, "1 回だけ待つ句", :sentences, "collect --run-dir <run dir> --waits 1")
refute = "#{sweep}/REFUTE.md"
refute_h = "## 検証役が Codex のとき"
check.call(refute, refute_h, "反証の launch の句", :sentences, "launch --kind json --schema <この skill の refutation.schema.json>")
check.call(refute, refute_h, "起動の前に記録した directory を渡す句", :sentences, "--run-root <起動の前に記録した directory>")
# 入力の findings.json の置き場は、script の経路と手で組む経路で違う (#680 の review の F4)。
check.call(refute, refute_h, "script の経路の入力の置き場の句", :items, "`<起動の前に記録した directory>/findings.json` の場所を書きます")
check.call(refute, refute_h, "手で組むときの置き場の句", :items, "手で組むとき (run dir を自分で作るとき) の置き場")
check.call(refute, refute_h, "制約は script が足す句", :items, "は script が brief の先頭に足します")

# 4. sweep の run dir の記録
check.call("#{sweep}/SKILL.md", "### 3. 監査する (単位ごと)", "起動の前に directory を記録する句", :items,
           "起動の前に、その起動だけに使う新しい directory を作って場所を `codex-run` に書き、`--run-root` に渡す")
record = "#{sweep}/RECORD.md"
check.call(record, "## local の state", "run dir は 1 つだけの句", :sentences, "run dir は、その下にできるただ 1 つの directory です")
check.call(record, "## local の state", "再開で collect にかける句", :items, "`personal-codex-launch collect --run-dir <run dir>` にかけ")
check.call(record, "## local の state", "RUNNING は起動し直さない句", :items, "起動し直さずに人に返します")
check.call(record, "## local の state", "run dir が無ければ起動していない句", :items, "Codex は起動していません")

# 5. docs
doc = "docs/codex-launch.md"
["`personal-codex-review`", "`personal-repo-audit`", "`personal-maintenance-sweep` の反証", "`personal-grill-me` / `personal-grill-with-docs` の事前相談"].each do |caller|
  check.call(doc, "## 各 skill からの呼び方", "#{caller} の行", :rows, "| #{caller}")
end
check.call("docs/codex-review-launch.md", "# Codex review の起動経路と sandbox", "script への参照", :sentences, "[codex-launch](codex-launch.md)")

unless errors.empty?
  warn errors.map { |e| "FAIL: #{e}" }.join("\n")
  exit 1
end
RUBY

echo "ok: codex-launch-wiring-test"
