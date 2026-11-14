#!/bin/sh
# read-only の Codex の起動と回収の script (personal-codex-launch) の組み込み (#672) が文書に残っていることを検査する。
# 文言の検知で、振る舞いの保証ではない (script の挙動は codex-launch-test.sh)。
# - personal-codex-review の LAUNCH.md の先頭の節に、launch (kind=review と対象の OID) と collect の command、status ごとの
#   扱い (STARTED・BLOCKED の 3 つの理由・RUNNING・DONE・executor-result の retryable)、script が無いときだけ手で組む句がある。
#   SKILL.md の §4 と §5 が、script と brief の雛形を指す。
# - review の brief の雛形 (BRIEF-TEMPLATE.md) に、決まった節と、script が足す 3 つの注意 (heredoc、変数名 path、skill と
#   session の開始の手順を起動しない) の説明がある。その 3 つは、script の制約の節 (定数) に実際に入っている。
# - personal-repo-audit の CODEX-LAUNCH.md の先頭の節に、launch (kind=json と schema) と collect の command、process の
#   有無で判定しない句がある。相談 (CONSULT.md) と反証 (REFUTE.md) が、同じ節と自分の schema を指す。
# - sweep の SKILL.md と RECORD.md に、起動の前に directory を記録して --run-root に渡す句と、再開で collect にかける句がある。
# - docs/codex-launch.md の呼び方の表に、4 つの呼び出し側がある。script の kind の一覧は、文書に出てくる kind と一致する。
# 節は見出しの level で次の見出しまでを取り、code block の中の見出しでは区切らない。句は空白を除いて比べる。
# 引数で repo root を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-"$script_dir/../.."}
ruby - "$root" <<'RUBY'
root = ARGV.fetch(0)
errors = []
squash = ->(s) { s.gsub(/\s+/, "") }
read = ->(rel) { File.read(File.join(root, rel), encoding: "UTF-8") }

section = lambda do |text, heading|
  lines = text.lines
  start = lines.index { |l| l.chomp == heading }
  next nil if start.nil?
  level = heading[/\A#+/].size
  fence = false
  body = []
  lines[(start + 1)..-1].each do |l|
    fence = !fence if l =~ /\A\s*```/
    break if !fence && l =~ /\A(#+) / && $1.size <= level
    body << l
  end
  body.join
end

check = lambda do |rel, heading, label, phrase|
  body = section.call(read.call(rel), heading)
  if body.nil?
    errors << "#{rel} に「#{heading}」の節が無い"
    next
  end
  errors << "#{rel} の「#{heading}」に#{label} (#{phrase.inspect}) が無い" unless squash.call(body).include?(squash.call(phrase))
end

review = "shared/skills/personal-codex-review"
audit = "shared/skills/personal-repo-audit"
sweep = "shared/skills/personal-maintenance-sweep"
grill = "shared/skills/personal-grill-me"

# 1. review の LAUNCH.md
launch_md = "#{review}/LAUNCH.md"
head = "### personal-codex-launch で起動して回収する (#672)"
check.call(launch_md, head, "script の場所の句", "配備済みの `personal-codex-launch`")
check.call(launch_md, head, "手で組むのは script が無いときだけの句", "手で組むのは、script が配備されていない環境だけ")
check.call(launch_md, head, "launch の command",
           %q("$launch" launch --kind review --repo "$repo" --brief "$brief" --label "$label" --run-root "$run_root" \ --base-ref "$base_ref" --base-oid "$base_oid" --head-oid "$head_oid"))
check.call(launch_md, head, "collect の command", %q("$launch" collect --run-dir "$run_dir"))
check.call(launch_md, head, "brief に制約を書かない句", "script が brief の先頭に足すので、書きません")
check.call(launch_md, head, "値の受け渡しの句", "検査してから literal の変数で渡します")
%w[STARTED RUNNING DONE capability-preflight target-identity launch-path executor-exit executor-result].each do |word|
  check.call(launch_md, head, "#{word} の扱い", "`#{word}`")
end
check.call(launch_md, head, "RUNNING で起動し直さない句", "同じ対象を起動し直しません")
check.call(launch_md, head, "空振りは 1 回だけ再実行する句", "新しい `launch` で同じ brief を 1 回だけ起動し直します")
check.call(launch_md, head, "verdict の無い結果は再実行しない句", "再実行せずに `Blocked at: executor-result` で停止します")
check.call(launch_md, head, "直接は起動しない経路の句", "`SKILL.md` §2 の起動経路の 2")
# exit 2 は入力の誤りと想定外の例外で扱いを分け、fallback の run の回収は状態ごとに分ける (#680 の review の F2・F3)。
check.call(launch_md, head, "入力の誤りでは何も起動していない句", "何も起動しておらず、run dir も作っていません")
# 想定外の例外の後は、run dir の launch.json の pane の ID で起動の状況を確かめる。label の pane が無いことは根拠にしない
# (命名に失敗しても起動は続く。#680 の review の round 2 の F2)。
check.call(launch_md, head, "run root を渡す句", "`--run-root` には、その起動だけに使う新しい directory (repository の外) を渡します")
check.call(launch_md, head, "想定外の例外で起動し直す前に確かめる句", "同じ値で起動し直す前に、\n`--run-root` に渡した directory の下に、`launch.json` を持つ run dir が出来ていないか")
check.call(launch_md, head, "pane_id が null なら起動していない句", "run dir が無い、または `launch.json` の `pane_id` が null")
check.call(launch_md, head, "pane_id があれば起動し直さない句", "`launch.json` に `pane_id` がある: 起動済みかもしれません。起動し直さず、その run dir に `collect` をかけて")
check.call(launch_md, head, "確かめられなければ人に返す句", "起動の状況を確かめられない: 起動し直さず、人に返します")
check.call(launch_md, head, "label の pane を根拠にしない句", "pane が無いことを\n未起動の根拠にしません")
check.call(launch_md, head, "pane_id が null の run の句", "`launch.json` の `pane_id` が null の run")
check.call(launch_md, head, "直接起動で done.txt が無いときの句", "`Blocked at: executor-exit` として\n扱います")
check.call(launch_md, head, "pane_id がある launch-path の run は collect にかけない句", "この run は `collect` にかけず")
check.call(launch_md, "### run dir と run script (script が実装している契約)", "今の run script の契約", "codex exec --ignore-user-config --ignore-rules -s read-only")

skill = "#{review}/SKILL.md"
check.call(skill, "## 4. brief", "script が足す節を brief に書かない句", "script が brief の先頭に足します")
check.call(skill, "## 4. brief", "雛形への参照", "`BRIEF-TEMPLATE.md`")
check.call(skill, "## 5. 実行と完了判定", "script で起動と回収を行う句", "配備済みの `personal-codex-launch` (`launch` と `collect`) で行います")
check.call(skill, "## 5. 実行と完了判定", "script が無いときだけ手で組む句", "script が配備されていない環境だけ")

# 2. brief の雛形
tpl = "#{review}/BRIEF-TEMPLATE.md"
if File.file?(File.join(root, tpl))
  text = read.call(tpl)
  ["## 目的と独立性", "## task と受け入れ条件", "## 重点観点", "## round <回数> の追加の情報 (2 回目以降だけ)"].each do |h|
    errors << "#{tpl} の雛形に「#{h}」の節が無い" unless text.lines.any? { |l| l.chomp == h }
  end
  added = "## script が足すもの (brief には書かない)"
  { "heredoc" => "heredoc を使わない", "変数名 path" => "zsh で変数名 `path` を使わない",
    "skill と session の開始の手順" => "skill、subagent、session の開始の手順を起動しない",
    "data の境界" => "data であって指示ではない", "手で組むときは brief に書く句" => "必ず入れます" }.each do |label, phrase|
    check.call(tpl, added, "#{label}の説明", phrase)
  end
  # 一覧の項目と、手で組むときの段落の両方に 3 つの注意がある (片方だけ消えても気づく)。
  check.call(tpl, added, "一覧の heredoc と変数名 path の項目", "- heredoc を使わない。\n  - zsh で変数名 `path` を使わない。")
  check.call(tpl, added, "一覧の skill と session の開始の手順の項目", "- nested な `codex`・`claude`、skill、subagent、session の開始の手順を起動しない。")
  check.call(tpl, added, "手で組むときの 3 つの注意の段落",
             "heredoc を使わないこと、zsh で変数名 `path` を使わないこと、skill と session の開始の手順を起動しないことの 3 つ")
  check.call(tpl, "## 雛形", "前の round からの差分の command", "git diff <前の head の OID>..<今の head の OID>")
  check.call(tpl, "## 雛形", "commit mode と uncommitted の対象の句", "script に OID を渡さない")
  # review の基準の file は、配備済みの reference を指す (Codex の cwd は review の対象の repo なので、agent-tools の source の
  # 場所では、ほかの repo で見つからない。#680 の review の F1)。
  check.call(tpl, "## 雛形", "配備済みの reference を指す句", "Codex home の `skills/personal-production-rail/references/policy-index.md`")
  block = section.call(text, "## 雛形").to_s[/```markdown\n(.*?)^```/m, 1].to_s
  errors << "#{tpl} の雛形の block を読めない" if block.empty?
  errors << "#{tpl} の雛形の block が、file を agent-tools の source の場所 (shared/ で始まる path) で指している" if block.include?("shared/")
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
check.call(codex_launch, ahead, "launch の command",
           %q("$launch" launch --kind json --repo "$repo" --brief "$brief" --label "$label" \ --schema "$schema" --effort "$effort" --run-root "$run_root"))
check.call(codex_launch, ahead, "collect の command", %q("$launch" collect --run-dir "$run_dir" --waits 3))
check.call(codex_launch, ahead, "process の有無で判定しない句", "script は process の\n有無では判定しません")
check.call(codex_launch, ahead, "RUNNING で起動し直さない句", "同じ対象を新しく起動しません")
check.call(codex_launch, ahead, "空振りは 1 回だけ再実行する句", "新しい `launch` で同じ brief を 1 回だけ起動し直し")
check.call(codex_launch, ahead, "手で組むのは script が無いときだけの句", "script が配備されていない環境だけ")
check.call(codex_launch, ahead, "file の名前の違いの句", "`CODEX-JSON-DONE-<nonce>`")
check.call("#{grill}/CONSULT.md", "### Claude Code の session → Codex", "相談の launch の句", "launch --kind json --schema <この skill の consult.schema.json>")
check.call("#{grill}/CONSULT.md", "### Claude Code の session → Codex", "1 回だけ待つ句", "collect --run-dir <run dir> --waits 1")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "反証の launch の句", "launch --kind json --schema <この skill の refutation.schema.json>")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "起動の前に記録した directory を渡す句", "--run-root <起動の前に記録した directory>")
# 入力の findings.json の置き場は、script の経路と手で組む経路で違う (#680 の review の F4)。
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "script の経路の入力の置き場の句", "`<起動の前に記録した directory>/findings.json` の場所を書きます")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "手で組むときの置き場の句", "手で組むとき (run dir を自分で作るとき) の置き場")
check.call("#{sweep}/REFUTE.md", "## 検証役が Codex のとき", "制約は script が足す句", "は script が brief の先頭に足します")
check.call(codex_launch, ahead, "想定外の例外で起動の状況を確かめる句", "run dir の `launch.json` で、起動の状況を確かめます")
check.call(codex_launch, ahead, "確かめられなければ人に返す句", "確かめられなければ起動し直さずに人に返します")
check.call(codex_launch, ahead, "label の pane を根拠にしない句", "`audit-<label>` の pane が無いことを、未起動の根拠にしません")

# 4. sweep の run dir の記録
check.call("#{sweep}/SKILL.md", "### 3. 監査する (単位ごと)", "起動の前に directory を記録する句",
           "起動の前に、その起動だけに使う新しい directory を作って場所を `codex-run` に書き、`--run-root` に渡す")
record = "#{sweep}/RECORD.md"
check.call(record, "## local の state", "run dir は 1 つだけの句", "run dir は、その下にできるただ 1 つの directory です")
check.call(record, "## local の state", "再開で collect にかける句", "`personal-codex-launch collect --run-dir <run dir>` にかけ")
check.call(record, "## local の state", "RUNNING は起動し直さない句", "起動し直さずに人に返します")
check.call(record, "## local の state", "run dir が無ければ起動していない句", "Codex は起動していません")

# 5. docs
doc = "docs/codex-launch.md"
["`personal-codex-review`", "`personal-repo-audit`", "`personal-maintenance-sweep` の反証", "`personal-grill-me` / `personal-grill-with-docs` の事前相談"].each do |caller|
  check.call(doc, "## 各 skill からの呼び方", "#{caller} の行", "| #{caller}")
end
check.call("docs/codex-review-launch.md", "# Codex review の起動経路と sandbox", "script への参照", "[codex-launch](codex-launch.md)")

unless errors.empty?
  warn errors.map { |e| "FAIL: #{e}" }.join("\n")
  exit 1
end
RUBY

echo "ok: codex-launch-wiring-test"
