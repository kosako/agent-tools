#!/usr/bin/env ruby
# frozen_string_literal: true

# tool-call-report: personal-tool-call-record-hook が書いた JSONL (event ごとに 1 行) を読み、期間内の tool call
# を session_id + tool_use_id で 1 つにまとめて、人が週次で読む report (md) と機械で比べる数字 (json) を出す
# 集計 script (#461)。記録を読むだけで、file にも network にも書かない。固定の列だけを集計し、生の記録を
# LLM に読ませない前提 (R09)。
#
# 正本: docs/tool-call-record-hook.md の「集計 (personal-tool-call-report)」。
#
# 強度ラベル (偽らない): 集計は記録と同じ強さまで。
# - 主体は記録 hook の client の自己申告 (claude-code / codex / unknown) まで。認証された主体には結び付かない。
# - 記録 (JSONL) は agent と同じ OS user が書き換えられる。集計は記録をそのまま信じる (改竄は検知しない)。
# - 「Pre だけ」の call は unknown であって拒否ではない (記録 hook の「集計側の約束」)。denied と書くのは
#   PermissionDenied の行があるときだけ。
#
# 仕組み:
# - option を先に全部解決してから集計する。不正な option は理由と usage を stderr に出して exit 2。
# - 入力は --file (複数可)。無ければ ${XDG_STATE_HOME:-$HOME/.local/state}/agent-tools/
#   personal-tool-call-record-hook/claude-code.jsonl (記録 hook の既定と同じ場所)。読めない file は stderr に
#   1 行出して続け、1 つも読めなければ exit 1。
# - 使う行は JSON object で ts が ISO 8601 のもの。それ以外は「壊れた行」として数えて skip する (落ちない)。
# - 期間は行ごとに ts の local 日付 (offset を尊重して local time に直した日付) で判定する。until は含む。
#   既定は --days 7 (今日を含む直近 7 日)。--since / --until は片方だけでもよい (--days とは併用しない)。
#   SessionStart は期間に関わらず版の結合に使う (期間外なら期間外の行としても数える)。
# - 結合は session_id + tool_use_id (同じ tool_use_id でも session が違えば別の call)。tool_use_id の無い tool 行
#   (と知らない event の行) は「結合不能」として数え、call には数えない。
# - 除外: tool が ToolSearch の call は集計から外し、件数だけ 1 節に出す。deferred な MCP tool では model が
#   先に ToolSearch を呼ぶので、その Pre / Post が call の前に混ざる (2026-10-09 の実測、記録 hook の docs の
#   「集計側の約束」)。
# - 判断: PostToolUse か PostToolUseFailure がある → allowed。PermissionDenied がある → denied。
#   PreToolUse だけ → unknown。結果: PostToolUse → output。PostToolUseFailure → その行の result (error /
#   interrupted)。無ければ unknown。版: その session の SessionStart の version (複数なら ts が最新のもの)。
#   無ければ unknown。reason の有無は判断が denied の call についてだけ数える (あり + なし = denied の call 数。
#   空白だけの reason は「なし」)。
# - 出さないもの: 引数の値 (記録に無い)、session_id、tool_use_id、file の絶対 path (名前だけ)、PermissionDenied
#   の reason の本文 (件数だけ)。report は public な場所に貼られうる前提。
# - 集計の値は決定的: tool と MCP server は件数の多い順 (同数なら名前順)、client × 版は名前順、op と判断・結果は
#   固定の順。中央値は偶数個なら中央 2 つの平均、p95 は nearest-rank。

require "date"
require "json"
require "time"

module ToolCallReport
  NAME = "personal-tool-call-report"
  RECORD_HOOK = "personal-tool-call-record-hook"
  SCHEMA_VERSION = 1
  DEFAULT_DAYS = 7
  DEFAULT_TOP = 20
  FORMATS = %w[md json].freeze
  TOOL_EVENTS = %w[PreToolUse PostToolUse PostToolUseFailure PermissionDenied].freeze
  # 集計から外す tool (件数だけ出す)。ToolSearch は deferred な tool の探索で、業務の操作ではない。
  EXCLUDED_TOOLS = %w[ToolSearch].freeze
  DECISIONS = %w[allowed denied unknown].freeze
  RESULTS = %w[output error interrupted unknown].freeze
  OPS = %w[append edit replace other].freeze
  DATE_RE = /\A\d{4}-\d{2}-\d{2}\z/.freeze
  POSITIVE_RE = /\A[1-9]\d*\z/.freeze
  EXIT_OK = 0
  EXIT_NO_INPUT = 1
  EXIT_USAGE = 2

  # 引数の誤り (exit 2)。
  class UsageError < StandardError; end

  module_function

  def usage
    "usage: #{NAME} [--file <path>]... [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--days N] [--top N] " \
      "[--format md|json] [--help|-h]"
  end

  def help
    <<~TEXT
      #{usage}
      #{RECORD_HOOK} の JSONL を読み、期間内の tool call を session_id + tool_use_id で結合して件数を出す。
      --file <path>      読む JSONL (繰り返して複数可)。既定は
                         ${XDG_STATE_HOME:-$HOME/.local/state}/agent-tools/#{RECORD_HOOK}/claude-code.jsonl
      --since / --until  期間 (local の日付。until は含む。片方だけでもよい)
      --days N           今日を含む直近 N 日 (既定 #{DEFAULT_DAYS})。--since / --until とは併用できない
      --top N            tool ごとの call 数に出す上位の数 (既定 #{DEFAULT_TOP})
      --format md|json   出力の形 (既定 md)
      exit 0 = 正常 / 1 = 入力 file が 1 つも読めない / 2 = 引数の誤り (理由と usage を stderr に出す)
    TEXT
  end

  # 戻り値は exit code。env / out / err / today は test の差し替え口。
  def main(argv, env: ENV, out: $stdout, err: $stderr, today: Date.today)
    opts = parse_options(argv)
    if opts[:help]
      out.puts help
      return EXIT_OK
    end
    since, until_date, days = resolve_period(opts, today)
    files = opts[:files].empty? ? [default_record_path(env)].compact : opts[:files]
    if files.empty?
      err.puts "#{NAME}: cannot resolve the default record location (set HOME or XDG_STATE_HOME, or pass --file)"
      return EXIT_NO_INPUT
    end
    scan = scan_files(files, since, until_date, err)
    if scan[:read].empty?
      err.puts "#{NAME}: no readable input file"
      return EXIT_NO_INPUT
    end
    report = build_report(scan, since, until_date, days, opts[:top])
    out.puts(opts[:format] == "json" ? JSON.pretty_generate(report) : render_md(report))
    EXIT_OK
  rescue UsageError => e
    err.puts "#{NAME}: #{e.message}"
    err.puts usage
    EXIT_USAGE
  end

  # ---- option ---------------------------------------------------------------------------------

  # 全部の option を先に解決する。値の形と組み合わせの誤りは UsageError。
  def parse_options(argv)
    opts = { files: [], since: nil, until: nil, days: nil, top: DEFAULT_TOP, format: "md", help: false }
    args = argv.dup
    until args.empty?
      arg = args.shift
      case arg
      when "--help", "-h" then opts[:help] = true
      when "--file" then opts[:files] << take_value(args, arg)
      when "--since" then opts[:since] = parse_date(take_value(args, arg), arg)
      when "--until" then opts[:until] = parse_date(take_value(args, arg), arg)
      when "--days" then opts[:days] = parse_positive(take_value(args, arg), arg)
      when "--top" then opts[:top] = parse_positive(take_value(args, arg), arg)
      when "--format"
        value = take_value(args, arg)
        raise UsageError, "#{arg} must be one of: #{FORMATS.join(', ')}" unless FORMATS.include?(value)

        opts[:format] = value
      else
        raise UsageError, "unknown argument: #{arg}"
      end
    end
    raise UsageError, "--days cannot be combined with --since / --until" if opts[:days] && (opts[:since] || opts[:until])
    raise UsageError, "--since must not be later than --until" if opts[:since] && opts[:until] && opts[:since] > opts[:until]

    opts
  end

  def take_value(args, arg)
    raise UsageError, "#{arg} requires a value" if args.empty?

    args.shift
  end

  def parse_date(value, arg)
    raise UsageError, "#{arg} must be YYYY-MM-DD" unless value.match?(DATE_RE)

    Date.strptime(value, "%Y-%m-%d")
  rescue ArgumentError
    raise UsageError, "#{arg} is not a valid date"
  end

  def parse_positive(value, arg)
    raise UsageError, "#{arg} must be a positive integer" unless value.match?(POSITIVE_RE)

    value.to_i
  end

  # [since, until, days]。--since / --until があればそのまま (片方だけなら他方は nil = 制限なし)。
  # 無ければ今日を含む直近 days 日。
  def resolve_period(opts, today)
    return [opts[:since], opts[:until], nil] if opts[:since] || opts[:until]

    days = opts[:days] || DEFAULT_DAYS
    [today - (days - 1), today, days]
  end

  # 既定の記録の場所 (記録 hook の record_path と同じ規則)。絶対 path に決められなければ nil。
  def default_record_path(env)
    state = env["XDG_STATE_HOME"].to_s
    if state.empty?
      home = env["HOME"].to_s
      return nil if home.empty?

      state = File.join(home, ".local", "state")
    end
    return nil unless state.start_with?("/")

    File.join(state, "agent-tools", RECORD_HOOK, "claude-code.jsonl")
  end

  # ---- 読み取り ---------------------------------------------------------------------------------

  # file を順に読み、行ごとに 壊れた行 / 期間外 / 期間内 に分けて集計の材料を作る。読めない file は stderr に
  # 1 行出して飛ばす (:read に入らない。path は制御文字を空白にして出す)。file の名前は basename だけ持つ
  # (report に絶対 path を出さない)。
  def scan_files(files, since, until_date, err)
    scan = {
      read: [], unreadable: 0,
      lines: 0, broken: 0, out_of_period: 0, unjoinable: 0,
      versions: {}, groups: {}, sessions: {}, days: {},
    }
    files.each do |path|
      begin
        File.open(path, "r:UTF-8") { |io| io.each_line { |line| scan_line(scan, line, since, until_date) } }
      rescue SystemCallError, IOError => e
        scan[:unreadable] += 1
        err.puts "#{NAME}: cannot read #{plain(path)} (#{e.class})"
        next
      end
      scan[:read] << File.basename(path).dup.force_encoding("UTF-8").scrub
    end
    scan
  end

  def scan_line(scan, line, since, until_date)
    scan[:lines] += 1
    row = parse_row(line)
    if row.nil?
      scan[:broken] += 1
      return
    end
    data = row[:data]
    session_id = string_or_nil(data["session_id"])
    register_version(scan[:versions], session_id, row) if data["event"] == "SessionStart"
    unless in_period?(row[:date], since, until_date)
      scan[:out_of_period] += 1
      return
    end
    scan[:days][row[:date]] = true
    scan[:sessions][session_id] = true if session_id
    return if data["event"] == "SessionStart"

    tool_use_id = string_or_nil(data["tool_use_id"])
    if TOOL_EVENTS.include?(data["event"]) && tool_use_id
      (scan[:groups][[session_id, tool_use_id]] ||= []) << data
    else
      scan[:unjoinable] += 1
    end
  end

  # JSON object で ts が ISO 8601 の行だけ row にする。それ以外は nil (壊れた行)。不正な byte は置換して読む
  # (json は文字列の中の不正な byte を通すので、先に揃える)。
  def parse_row(line)
    data = JSON.parse(line.scrub)
    return nil unless data.is_a?(Hash) && data["ts"].is_a?(String)

    time = Time.iso8601(data["ts"]).localtime
    { data: data, time: time, date: Date.new(time.year, time.month, time.day) }
  rescue JSON::ParserError, ArgumentError
    nil
  end

  # 版は SessionStart の version。同じ session に複数あれば ts が最新のもの (同時刻なら後に読んだ方)。
  def register_version(versions, session_id, row)
    return if session_id.nil?

    current = versions[session_id]
    return if current && current[0] > row[:time]

    versions[session_id] = [row[:time], string_or_nil(row[:data]["version"]) || "unknown"]
  end

  def in_period?(date, since, until_date)
    (since.nil? || date >= since) && (until_date.nil? || date <= until_date)
  end

  # ---- 結合 -------------------------------------------------------------------------------------

  def build_calls(groups, versions)
    groups.map { |(session_id, _tool_use_id), rows| build_call(session_id, rows, versions) }
  end

  # 1 つの call (同じ session_id + tool_use_id の行の集まり) の列を導く。同じ event が複数あれば先に読んだ行。
  # reason は判断が denied の call についてだけ見る (Post 系が勝って allowed になった call の PermissionDenied 行は
  # 数えない。空白だけの reason は「なし」)。
  def build_call(session_id, rows, versions)
    by_event = {}
    rows.each { |r| by_event[r["event"]] ||= r }
    head = by_event["PreToolUse"] || rows.first
    post = by_event["PostToolUse"]
    failure = by_event["PostToolUseFailure"]
    denied = by_event["PermissionDenied"]
    version = versions[session_id]
    decision = decision_of(post, failure, denied)
    {
      client: string_or_nil(head["client"]) || "unknown",
      version: version ? version[1] : "unknown",
      tool: string_or_nil(head["tool"]) || "unknown",
      mcp_server: mcp_name(rows),
      op: first_string(rows, "op"),
      decision: decision,
      result: result_of(post, failure),
      duration_ms: rows.map { |r| r["duration_ms"] }.find { |d| d.is_a?(Numeric) },
      reason: decision == "denied" && !blank?(denied["reason"]),
    }
  end

  def decision_of(post, failure, denied)
    return "allowed" if post || failure
    return "denied" if denied

    "unknown"
  end

  def result_of(post, failure)
    return "output" if post
    return "unknown" if failure.nil?

    failure["result"] == "interrupted" ? "interrupted" : "error"
  end

  def mcp_name(rows)
    rows.map { |r| r["mcp_server"].is_a?(Hash) ? string_or_nil(r["mcp_server"]["name"]) : nil }.compact.first
  end

  def first_string(rows, key)
    rows.map { |r| string_or_nil(r[key]) }.compact.first
  end

  # ---- 集計 -------------------------------------------------------------------------------------

  # md と json が同じ数字を持つように、集計は 1 つの Hash に固め、どちらの出力もそれを描く。
  def build_report(scan, since, until_date, days, top)
    calls, excluded = build_calls(scan[:groups], scan[:versions]).partition { |c| !EXCLUDED_TOOLS.include?(c[:tool]) }
    durations = calls.map { |c| c[:duration_ms] }.compact.sort
    tools = counts(calls.map { |c| c[:tool] })
    denied_calls = calls.select { |c| c[:decision] == "denied" }
    {
      "schema_version" => SCHEMA_VERSION,
      "period" => { "since" => since && since.to_s, "until" => until_date && until_date.to_s, "days" => days },
      "files" => { "read" => scan[:read], "unreadable" => scan[:unreadable] },
      "lines" => {
        "total" => scan[:lines], "broken" => scan[:broken],
        "out_of_period" => scan[:out_of_period], "unjoinable" => scan[:unjoinable],
      },
      "calls" => calls.length,
      "excluded_calls" => { "tools" => EXCLUDED_TOOLS, "count" => excluded.length },
      "sessions" => scan[:sessions].length,
      "active_days" => scan[:days].length,
      "by_client_version" => counts(calls.map { |c| [c[:client], c[:version]] })
        .map { |(client, version), n| { "client" => client, "version" => version, "calls" => n } },
      "tools" => {
        "top" => top, "distinct" => tools.length,
        "rows" => ranked(tools).first(top).map { |tool, n| { "tool" => tool, "calls" => n } },
      },
      "mcp_servers" => ranked(counts(calls.map { |c| c[:mcp_server] }.compact))
        .map { |name, n| { "name" => name, "calls" => n } },
      "decisions" => breakdown(DECISIONS, calls.map { |c| c[:decision] }),
      "results" => breakdown(RESULTS, calls.map { |c| c[:result] }),
      "ops" => fixed_counts(OPS, calls.map { |c| c[:op] }.compact),
      "duration_ms" => { "count" => durations.length, "median" => median(durations), "p95" => p95(durations) },
      "denied_reasons" => {
        "with_reason" => denied_calls.count { |c| c[:reason] },
        "without_reason" => denied_calls.count { |c| !c[:reason] },
      },
    }
  end

  # 値 → 件数を key 順の [key, n] で出す。
  def counts(values)
    values.each_with_object(Hash.new(0)) { |v, h| h[v] += 1 }.sort
  end

  # [key, n] を件数の多い順 (同数なら key 順) にする。
  def ranked(pairs)
    pairs.sort_by { |key, n| [-n, key] }
  end

  # 固定の key を全部 (0 でも) 出し、知らない値があれば key 順で後ろに足す。
  def fixed_counts(keys, values)
    counted = values.each_with_object(Hash.new(0)) { |v, h| h[v] += 1 }
    (keys + (counted.keys - keys).sort).each_with_object({}) { |k, h| h[k] = counted.fetch(k, 0) }
  end

  # 固定の内訳に unknown の比率 (% で小数 1 桁。0 件なら nil) を足す。
  def breakdown(keys, values)
    result = fixed_counts(keys, values)
    result["unknown_percent"] = values.empty? ? nil : (result["unknown"] * 100.0 / values.length).round(1)
    result
  end

  # 中央値 (sort 済みの配列。偶数個なら中央 2 つの平均)。空なら nil。
  def median(sorted)
    return nil if sorted.empty?

    mid = sorted.length / 2
    number(sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0)
  end

  # p95 (nearest-rank: 上から 95% の順位の値。整数の計算で ceil(0.95 n))。空なら nil。
  def p95(sorted)
    return nil if sorted.empty?

    number(sorted[(95 * sorted.length + 99) / 100 - 1])
  end

  # 整数に等しい float は整数で出す (md と json で同じ見え方にする)。それ以外は小数 1 桁。
  def number(value)
    return value unless value.is_a?(Float)
    return value.to_i if value.finite? && value == value.floor

    value.round(1)
  end

  # ---- 出力 (md) --------------------------------------------------------------------------------

  def render_md(r)
    lines = ["# tool call report (#{RECORD_HOOK})", ""]
    section(lines, "## 1. 概況", %w[項目 値], [
      ["期間", period_text(r["period"])],
      ["読んだ file", r["files"]["read"].join(", ")],
      ["読めなかった file", r["files"]["unreadable"]],
      ["行数", r["lines"]["total"]],
      ["壊れた行", r["lines"]["broken"]],
      ["期間外の行", r["lines"]["out_of_period"]],
      ["結合不能の行 (tool_use_id 無し / 知らない event)", r["lines"]["unjoinable"]],
      ["call 数", r["calls"]],
      ["除外した call (#{r['excluded_calls']['tools'].join(' / ')})", r["excluded_calls"]["count"]],
      ["session 数", r["sessions"]],
      ["作業日数", r["active_days"]],
    ])
    section(lines, "## 2. client × 版", ["client", "版", "call 数"],
            r["by_client_version"].map { |x| [x["client"], x["version"], x["calls"]] })
    section(lines, "## 3. tool (上位 #{r['tools']['top']} / #{r['tools']['distinct']} 種類)", ["tool", "call 数"],
            r["tools"]["rows"].map { |x| [x["tool"], x["calls"]] })
    section(lines, "### MCP server (mcp_server.name)", ["mcp_server", "call 数"],
            r["mcp_servers"].map { |x| [x["name"], x["calls"]] })
    lines << "## 4. 判断と結果" << ""
    section(lines, "### 判断", ["判断", "call 数"], breakdown_rows(DECISIONS, r["decisions"]))
    section(lines, "### 結果", ["結果", "call 数"], breakdown_rows(RESULTS, r["results"]))
    section(lines, "## 5. Notion update-page の op", ["op", "call 数"], r["ops"].to_a)
    section(lines, "## 6. duration_ms (あるものだけ)", %w[項目 値], [
      ["あり (call 数)", r["duration_ms"]["count"]],
      ["中央値", r["duration_ms"]["median"] || "n/a"],
      ["p95", r["duration_ms"]["p95"] || "n/a"],
    ])
    section(lines, "## 7. denied の call の reason (件数だけ)", %w[項目 件数], [
      ["reason あり", r["denied_reasons"]["with_reason"]],
      ["reason なし", r["denied_reasons"]["without_reason"]],
    ])
    lines.join("\n")
  end

  def period_text(period)
    range = "#{period['since'] || '(下限なし)'} 〜 #{period['until'] || '(上限なし)'}"
    period["days"] ? "#{range} (local の日付、今日を含む直近 #{period['days']} 日)" : "#{range} (local の日付)"
  end

  def breakdown_rows(keys, counted)
    percent = counted["unknown_percent"]
    rows = (keys + (counted.keys - keys - ["unknown_percent"])).map { |k| [k, counted[k]] }
    rows << ["unknown の比率", percent.nil? ? "n/a" : format("%.1f%%", percent)]
  end

  # 見出しと表を足す。行が無ければ表の代わりに「(なし)」。
  def section(lines, title, header, rows)
    lines << title << ""
    if rows.empty?
      lines << "(なし)"
    else
      lines << md_row(header) << md_row(header.map { "---" })
      rows.each { |cells| lines << md_row(cells) }
    end
    lines << ""
  end

  def md_row(cells)
    "| #{cells.map { |c| cell(c) }.join(' | ')} |"
  end

  # 表の cell。制御文字は空白に、| は \| にして表を壊さない。
  def cell(value)
    plain(value).gsub("|") { "\\|" }
  end

  # 人が読む 1 行に埋める文字列。不正な byte を置換し、制御文字 (端末の escape を含む) を空白にする。
  def plain(value)
    value.to_s.scrub.gsub(/[[:cntrl:]]/, " ")
  end

  def string_or_nil(value)
    value.is_a?(String) ? value.scrub : nil
  end

  # 文字列でない・空・空白だけなら true。
  def blank?(value)
    string_or_nil(value).to_s.strip.empty?
  end
end

exit ToolCallReport.main(ARGV) if $PROGRAM_NAME == __FILE__
