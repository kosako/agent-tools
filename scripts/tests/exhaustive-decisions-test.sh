#!/bin/sh
# 入力が有限な判定 2 つを、全部の組で確かめる self-test (#762)。
# - E1: review の相手の判定 (personal-review-routing-preflight の judge)。label の列の全部。
# - E2: packet の worker の操作 (personal-packet の worker_update)。操作、state、run、last_run、tab、branch、pr、expected_run の全部。
# 期待値は、実装を呼び直して作らない。E1 は reviewer の表と性質から、E2 は docs/agent-packets.md の「worker-update の入力と保存」の
# 表から、ここに書き下ろす。組の数を固定する (組が減って気付かない形にしない)。
# git・gh・network には触れない (E2 は、更新先の検査 (git) だけを差し替え、読み書きと判定は本物を通す)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

routing="$repo_root/shared/scripts/personal-review-routing-preflight.rb"
packet="$repo_root/shared/scripts/personal-packet.rb"
for f in "$routing" "$packet"; do
  [ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---- E1 ------------------------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" - "$routing" <<'RUBY'
load ARGV[0]
M = ReviewRoutingPreflight

# author の label と reviewer。personal-review-request の「レビュアーの決定」の表を書き下ろしたもの。
REVIEWER = { claude: :codex, codex: :claude, opencode_anthropic: :codex, opencode_openai: :claude, opencode_other: :claude,
             bot_dependabot: :claude }.freeze
# 判定できない label。1 つでもあれば、ほかが何でも ok にならない。unlisted は、表に無い label。
UNDECIDED = %i[mixed bot_unverified merge_none none opencode_unknown unlisted].freeze
KINDS = (REVIEWER.keys + UNDECIDED).freeze
# AI の系列。reviewer は author と別の系列でなければならない (other と bot は、どちらの AI とも違う)。
FAMILY = { claude: :anthropic, opencode_anthropic: :anthropic, codex: :openai, opencode_openai: :openai,
           opencode_other: :other, bot_dependabot: :bot }.freeze
MAX = 3

check("label の一覧は、判定の側の一覧に unlisted を足したもの", (M::LABELS.keys + [:unlisted]).sort == KINDS.sort)
sequences = (0..MAX).flat_map { |n| KINDS.repeated_permutation(n).to_a }
check("列の数 (#{sequences.length})", sequences.length == 1 + 12 + 144 + 1728)
results = sequences.map { |ks| [ks, M.judge(ks.each_with_index.map { |k, i| [format("%08x", i), k] })] }
show = ->(list) { "#{list.length} 件 #{list.first(2).inspect}" }

# 判定そのもの。空は error、1 種類で reviewer の表にあれば ok、ほかは fail_closed。
bad = results.reject do |ks, r|
  if ks.empty?
    r[:verdict] == :error && !r.key?(:reviewer)
  elsif ks.uniq.length == 1 && REVIEWER.key?(ks[0])
    r == { verdict: :ok, author: ks[0], reviewer: REVIEWER.fetch(ks[0]) }
  else
    r[:verdict] == :fail_closed && !r.key?(:reviewer) && !r.key?(:author)
  end
end
check("全部の列の判定が表と合う: #{show.call(bad)}", bad.empty?)
check("ok になる列の数", results.count { |_, r| r[:verdict] == :ok } == REVIEWER.length * MAX)

# 性質 (上の表を使わない言い方で、もう一度見る)
bad = results.select { |ks, r| (ks & UNDECIDED).any? && r[:verdict] == :ok }
check("判定できない label が 1 つでもあれば ok にならない: #{show.call(bad)}", bad.empty?)
bad = results.select { |_, r| r[:verdict] == :ok && { claude: :anthropic, codex: :openai }.fetch(r[:reviewer]) == FAMILY.fetch(r[:author]) }
check("ok のとき、reviewer は author と別の系列: #{show.call(bad)}", bad.empty?)
bad = results.group_by { |ks, _| ks.uniq.sort }.select { |_, group| group.map { |_, r| r }.uniq.length > 1 }
check("列の順序と重複を変えても、結果 (理由を含む) は同じ: #{show.call(bad.keys)}", bad.empty?)
bad = results.reject { |_, r| r[:verdict] == :ok || (r[:reason].is_a?(String) && !r[:reason].strip.empty?) }
check("ok でない結果は、理由を持つ: #{show.call(bad)}", bad.empty?)

# 理由。原因が違えば理由も違い、列に無い原因の理由は出ない。
alone = UNDECIDED.map { |k| [k, results.find { |ks, _| ks == [k] }[1][:reason]] }.to_h
mixture = results.find { |ks, _| ks == %i[claude codex] }[1][:reason]
check("表に無い label の理由は、系列を決められない label と同じ", alone[:unlisted] == alone[:opencode_unknown])
distinct = alone.reject { |k, _| k == :unlisted }.values + [mixture]
check("原因ごとの理由は、互いに違う (#{distinct.uniq.length})", distinct.uniq.length == UNDECIDED.length)
bad = results.reject do |ks, r|
  next true unless r[:verdict] == :fail_closed

  possible = (ks & UNDECIDED).map { |k| alone.fetch(k) }
  possible << mixture if ks.uniq.length > 1
  possible.include?(r[:reason])
end
check("理由は、列の中にある原因のもの: #{show.call(bad)}", bad.empty?)
bad = results.select { |ks, r| ks.include?(:mixed) && r[:reason] != alone[:mixed] }
check("1 つの commit に複数の AI があれば、その理由を出す: #{show.call(bad)}", bad.empty?)
exit(@failed.zero? ? 0 : 1)
RUBY

# ---- E2 ------------------------------------------------------------------------------------
ruby -r"$script_dir/lib/check_helper" -rdigest -rjson -ryaml -rtime - "$packet" "$tmp" <<'RUBY'
load ARGV[0]
DIR = File.realpath(ARGV[1])
PATH_PACKET = File.join(DIR, "7.md")
# 更新先の検査 (git で tracked でないかなど) だけを差し替える。読み書き、digest、判定、書き換えは本物を通す。
Packet.define_singleton_method(:worker_check_target) { |_issue| PATH_PACKET }

A = "/runs/a"
B = "/runs/b"
NEW = "/runs/new"
STATES = %w[open blocked review done].freeze
UPDATED = "2026-01-01T00:00:00+09:00"
BODY = <<~'TEXT'

  前置き

  ## 依頼

  依頼の本文

  ## 結果

  ### 2026-01-01 worker/codex

  結果の本文

  ## 次の入口

  次の本文

TEXT
TEXTS = { "entry" => "足す結果", "next" => "新しい入口", "request" => "足す依頼", "review_entry" => "足す review" }.freeze

# 節 (## の見出し) ごとの本文。実装の読み方に依らず、行頭の ## だけで分ける。
def split_body(text)
  text.split(/^(?=## )/).map { |part| part.start_with?("## ") ? [part.lines.first.chomp, part.lines.drop(1).join] : ["", part] }.to_h
end

# frontmatter を書く。updated のほかの値は JSON の形 (YAML としても読める) で書き、値の型をそのまま渡す。
def packet_text(front)
  lines = front.map { |k, v| "#{k}: #{k == 'updated' ? v : JSON.generate([v])[1..-2]}\n" }
  "---\n#{lines.join}custom: keep\n# 残す comment\n---\n#{BODY}"
end

# 操作を 1 つ当てる。戻り値は [拒んだ理由 (通れば nil), 当てた後の file の中身]
def apply(original, op, input)
  File.write(PATH_PACKET, original)
  data = { "schema" => 1, "operation" => op, "expected_sha256" => Digest::SHA256.hexdigest(original) }.merge(input)
  code = begin
    Packet.worker_update(7, data)
    nil
  rescue Packet::WorkerUpdateError => e
    e.code
  end
  [code, File.read(PATH_PACKET)]
end

def read_packet(text)
  _, front, body = text.split(/^---\n/, 3)
  [YAML.safe_load(front, permitted_classes: [Time, Date]), split_body(body)]
end

# 壊れた packet (docs の「起動の記録」): run・last_run・tab が空 (記録が無いなら key ごと消す)、run と last_run の両方がある。
# どの操作でも拒む。
def broken?(run, last_run, tab)
  [run, last_run, tab].any?(&:nil?) || (run.is_a?(String) && last_run.is_a?(String))
end

# 前提: docs の表の「前提」の列。has は key があるか (branch は、値が null でも、ある)。
def allowed?(op, state, run, last_run, has, input)
  case op
  when "branch" then !has.include?("branch")
  when "run-start"
    matched = input.key?("expected_run") ? run == input["expected_run"] : (!has.include?("run") || state == "blocked")
    %w[open blocked].include?(state) && matched
  when "result" then state == "open" && run == input["run"]
  when "stop" then state == "open" && [run, last_run].include?(input["run"])
  when "round" then %w[open review blocked].include?(state)
  when "review" then state == "open" && !has.include?("run")
  # entry と done (#782): run が無い間だけ。entry の state は、今の state が open か blocked のときだけ受ける。
  when "entry" then %w[open blocked review].include?(state) && !has.include?("run") && (!input.key?("state") || %w[open blocked].include?(state))
  when "done" then %w[open blocked review].include?(state) && !has.include?("run")
  end
end

# 更新内容: docs の表の「更新内容」の列。戻り値は [変わった後の key と値 (nil は削除), updated が変わるか, 足す節, 置き換える節]
def expected_change(op, state, input, today)
  case op
  when "branch" then [{ "branch" => input["branch"] }, false, {}, {}]
  when "run-start"
    change = { "run" => input["run"], "tab" => input["tab"], "last_run" => nil }
    change["state"] = "open" if state == "blocked"
    [change, state == "blocked", {}, {}]
  when "result"
    [{ "last_run" => input["run"], "run" => nil, "tab" => nil }, true,
     { "## 結果" => "### #{today} worker/codex\n\n足す結果" }, input.key?("next") ? { "## 次の入口" => "新しい入口" } : {}]
  when "stop"
    [{ "state" => "blocked" }, true, { "## 結果" => "### #{today} #{input['role']}\n\n足す結果" }, input.key?("next") ? { "## 次の入口" => "新しい入口" } : {}]
  when "round"
    add = { "## 依頼" => "足す依頼" }
    add["## 結果"] = "### #{today} reviewer/claude\n\n足す review" if input.key?("review_entry")
    [state == "review" ? { "state" => "open" } : {}, true, add, { "## 次の入口" => "新しい入口" }]
  when "review" then [{ "pr" => input["pr"], "state" => "review" }, true, {}, {}]
  when "entry"
    [input.key?("state") ? { "state" => input["state"] } : {}, true, { "## 結果" => "### #{today} #{input['role']}\n\n足す結果" },
     input.key?("next") ? { "## 次の入口" => "新しい入口" } : {}]
  when "done" then [{ "state" => "done" }, true, {}, {}]
  end
end

INPUTS = {
  "branch" => [{ "branch" => "feat/7-x" }],
  "run-start" => [{}, { "expected_run" => A }, { "expected_run" => B }].map { |h| { "run" => NEW, "tab" => "#7" }.merge(h) },
  "result" => [{ "next" => TEXTS["next"] }, {}].map { |h| { "run" => A, "entry" => TEXTS["entry"] }.merge(h) },
  "stop" => %w[worker/codex orchestrator/claude].product([{ "next" => TEXTS["next"] }, {}]).map { |r, h| { "run" => A, "role" => r, "entry" => TEXTS["entry"] }.merge(h) },
  "round" => [{}, { "review_entry" => TEXTS["review_entry"] }].map { |h| { "request" => TEXTS["request"], "next" => TEXTS["next"] }.merge(h) },
  "review" => [{ "pr" => 12 }],
  # worker の role は next の有無と state (無し・open・blocked) の 6 通り。reviewer の role は entry だけ (next と state は入力の検査で拒む)。
  "entry" => (%w[worker/claude worker/codex].product([{ "next" => TEXTS["next"] }, {}], [{}, { "state" => "open" }, { "state" => "blocked" }])
                .map { |r, n, s| { "role" => r, "entry" => TEXTS["entry"] }.merge(n).merge(s) } +
              %w[reviewer/claude reviewer/codex].map { |r| { "role" => r, "entry" => TEXTS["entry"] } }),
  "done" => [{}],
}.freeze
RUNS = [:absent, nil, A, B].freeze
LASTS = [:absent, nil, A, B].freeze
TABS = [:absent, nil, "#7"].freeze
BRANCHES = [:absent, nil, "feat/7-old"].freeze
PRS = [:absent, 3].freeze

check("操作の一覧は、実装の操作の一覧と同じ", INPUTS.keys.sort == Packet::WORKER_INPUT_KEYS.keys.sort)
check("state の一覧は、実装の state の一覧と同じ", STATES.sort == Packet::STATES.sort)
INPUTS.each do |op, list|
  list.each do |input|
    required = Packet::WORKER_INPUT_KEYS.fetch(op)
    optional = Packet::WORKER_OPTIONAL_KEYS.fetch(op, [])
    check("#{op} の入力は、決まった key だけを持つ", (required - input.keys).empty? && (input.keys - required - optional).empty?)
  end
end

tried = Hash.new(0)
accepted = Hash.new(0)
refused = Hash.new(0)
problems = Hash.new { |h, k| h[k] = [] }
INPUTS.each do |op, list|
  list.product(STATES, RUNS, LASTS, TABS, BRANCHES, PRS) do |input, state, run, last_run, tab, branch, pr|
    front = { "issue" => 7, "title" => "t", "state" => state, "worker" => "codex", "updated" => UPDATED }
    { "run" => run, "last_run" => last_run, "tab" => tab, "branch" => branch, "pr" => pr }.each { |k, v| front[k] = v unless v == :absent }
    original = packet_text(front)
    before, before_body = read_packet(original)
    label = "#{op} #{input.reject { |k, _| TEXTS.key?(k) && k != 'next' }.inspect} state=#{state} run=#{run.inspect} last=#{last_run.inspect} tab=#{tab.inspect} branch=#{branch.inspect} pr=#{pr.inspect}"
    tried[op] += 1
    days = [Time.now.strftime("%Y-%m-%d")]
    code, text = apply(original, op, input)
    # 日付の境目をまたいでも揺れないように、呼ぶ前と後の日付のうち、書かれた方を使う
    days << Time.now.strftime("%Y-%m-%d")
    today = days.find { |d| text.include?("### #{d} ") } || days.last
    want = allowed?(op, state, run == :absent ? nil : run, last_run == :absent ? nil : last_run, front.keys, input)
    broken = broken?(run, last_run, tab)
    want &&= !broken
    unless code.nil? == want
      problems["許すかどうか"] << "#{label} want=#{want} got=#{code.inspect}"
      next
    end
    unless want
      refused[code] += 1
      problems["拒む理由"] << "#{label} #{code}" unless code == (broken ? "invalid_packet" : "precondition")
      problems["拒んだ組で file が変わった"] << label unless text == original
      next
    end

    accepted[op] += 1
    after, after_body = read_packet(text)
    change, touched, add, replace = expected_change(op, state, input, today)
    wanted = before.merge(change).reject { |k, v| change.key?(k) && v.nil? }
    problems["変わる key"] << "#{label} #{(after.to_a - wanted.to_a).inspect} #{(wanted.to_a - after.to_a).inspect}" unless
      after.reject { |k, _| k == "updated" } == wanted.reject { |k, _| k == "updated" }
    problems["updated が変わるか"] << label unless (after["updated"] != before["updated"]) == touched
    problems["知らない key と comment"] << label unless text.include?("custom: keep\n# 残す comment\n")
    before_body.each do |name, body|
      got = after_body[name]
      ok = if add.key?(name) then got.start_with?(body.rstrip) && got.strip.end_with?(add[name]) && got.length == body.length + add[name].length + 2
           elsif replace.key?(name) then got.strip == replace[name]
           else got == body
           end
      problems["節 #{name}"] << "#{label} #{got.inspect}" unless ok
    end
    problems["節の数"] << label unless after_body.keys == before_body.keys
  end
end
base = STATES.length * RUNS.length * LASTS.length * TABS.length * BRANCHES.length * PRS.length
check("組の数 #{tried.inspect}", base == 1152 && tried == INPUTS.map { |op, list| [op, base * list.length] }.to_h && tried.values.sum == 32_256)
# 許す組の数。表から手で数えたもの。壊れていない (run, last_run) の組は 5 つ (run が無い 3 つ、run だけの 2 つ)。1 つの state と
# (run, last_run) の組に、tab (有無) と branch と pr の組が 12 ある (branch が無いのは 4 つ)。
counts = {
  "branch" => 4 * 5 * 4,                                 # state は問わない。branch が無い
  "run-start" => (3 + 5) * 12 + 2 * 1 * 12 + 2 * 1 * 12, # expected なし: open は run が無い 3 つ、blocked は 5 つ。あり: 一致する 1 つ × 2 state
  "result" => 2 * (1 * 12),                              # open で、run が一致する 1 つ。next の有無で 2 つ
  "stop" => 2 * 2 * (2 * 12),                            # open で、run か last_run が一致する 2 つ。role が 2 つ、next の有無で 2 つ
  "round" => 2 * (3 * 5 * 12),                           # 3 つの state。review_entry の有無で 2 つ
  "review" => 3 * 12,                                    # open で、run が無い 3 つ
  # entry: run が無い 3 つ。worker の role 2 つは、state 無し (next の有無で 2) が 3 つの state、state あり (2 × 2) が open と blocked。
  # reviewer の role 2 つは 3 つの state。
  "entry" => 2 * (2 * 3 + 4 * 2) * 3 * 12 + 2 * 3 * 3 * 12,
  "done" => 3 * 3 * 12,                                  # 3 つの state で、run が無い 3 つ
}
check("許す組の数 #{accepted.inspect} (表からは #{counts.inspect})", accepted == counts)
# 壊れた組。(run, last_run, tab) の 48 通りのうち、壊れていないのは 5 × 2。
check("壊れた packet の組の数 #{refused.inspect}", refused["invalid_packet"] == (48 - 10) * 4 * 6 * INPUTS.values.map(&:length).sum &&
                                                refused.values.sum == 32_256 - counts.values.sum)
# 壊れた記録の値。上の組の null のほかの形を、key ごとに全部の操作と state に当てる。どの操作でも invalid_packet で拒み、file は変わらない。
# 記録 (run・last_run・tab) は、空でない文字列で、制御文字を含まない。run と last_run は絶対 path。branch は文字列、pr は整数。
BROKEN = {
  "run" => [nil, "", " ", 7, true, [A], { "a" => 1 }, "/runs/\ta", "/runs/\u0001a", "runs/a", "~/runs/a"],
  "last_run" => [nil, "", " ", 7, true, [A], { "a" => 1 }, "/runs/\ta", "/runs/\u0001a", "runs/a", "~/runs/a"],
  "tab" => [nil, "", " ", 7, true, ["#7"], { "a" => 1 }, "#\t7", "#\u00017"],
  "branch" => [7, true, ["x"], { "a" => 1 }],
  "pr" => ["3", true, [3], { "a" => 1 }, 1.5],
}.freeze
broken_tried = 0
BROKEN.each do |key, values|
  values.product(INPUTS.flat_map { |op, list| list.map { |i| [op, i] } }, STATES) do |value, (op, input), state|
    front = { "issue" => 7, "title" => "t", "state" => state, "worker" => "codex", "updated" => UPDATED, key => value }
    original = packet_text(front)
    code, text = apply(original, op, input)
    broken_tried += 1
    problems["壊れた記録を拒まない"] << "#{op} state=#{state} #{key}=#{value.inspect} #{code.inspect}" unless code == "invalid_packet"
    problems["壊れた記録で file が変わった"] << "#{op} state=#{state} #{key}=#{value.inspect}" unless text == original
  end
end
check("壊れた記録の組の数 (#{broken_tried})", broken_tried == 112 * (11 + 11 + 9 + 4 + 5))
problems.each { |name, list| check("#{name}: #{list.length} 件 #{list.first(2).join(' / ')}", list.empty?) }
check("残った file が無い #{Dir.children(DIR).inspect}", Dir.children(DIR) == ["7.md"])
exit(@failed.zero? ? 0 : 1)
RUBY

echo "exhaustive-decisions-test: ok"
