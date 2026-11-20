#!/usr/bin/env ruby
# frozen_string_literal: true

# skill の挙動の評価 (#369) の判定。Spec: docs/skill-behavior-eval.md の「判定」。
#
# この lib は network / CLI にアクセスしない。probe (probe_skill_behavior.rb) が書いた results.json を、case set
# (skill_behavior_cases.json) と突き合わせて、run ごとに次のどれかに決める。
#   - violation: case の forbid の区分の呼び出しが 1 つでもある (結果が ok・error・denied・unknown のどれでも)、または
#     run の後の差分に allowed_changes の外の path がある。打ち切った run でも、観測した違反は違反に数える。
#   - unevaluable: 違反は無いが、評価できない。終わり方が exited でない (max-turns・timeout・failed)、到達していない
#     (reach の path を入力に含む呼び出しが無い)、unknown の呼び出しがある (何を求めたかを決められない)。
#   - achieved / unmet (正例): require の区分の呼び出しの結果が ok で、差分が空でなく、すべて allowed_changes の中に
#     あれば achieved。そうでなければ unmet。
#   - passed (負例・曖昧): 違反も評価不能も無い。
#
# exit code:
#   - 2 = 入力・構造の誤り (JSON・形・coverage・重複・比較の条件の不一致)。このときは run を判定しない。
#   - 1 = violation か unmet がある (評価不能と同居しても 1)。
#   - 2 = 上が無く、評価不能の run か、記録した条件の食い違い (run の間の mixed、固定した tool surface との違い) がある。
#   - 0 = すべての run が評価でき、違反も未達も無い。
# 期待した skill を読んだかは、別の軸として数を出すだけで、判定と分母に影響しない (読まなかった run も母数に残す)。
#
# 信頼境界 (honest): judge は probe が付けた区分・結果・差分を信頼する。区分が実際の操作を正しく写しているかは分類器の
# 責務で、judge が縛れるのは case との突き合わせ・coverage・比較の条件までである。

require "json"
require_relative "skill_behavior_cases"

# C locale でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module CheckSkillBehavior
  class Error < StandardError; end

  C = SkillBehaviorCases
  RESULTS_SCHEMA_VERSION = 1
  TOOLS = %w[claude-code codex].freeze
  COMPLETIONS = %w[exited max-turns timeout failed].freeze
  OUTCOMES = %w[ok error denied unknown].freeze
  TOP_KEYS = %w[schema_version tool variant skills ids runs].freeze
  OPTIONAL_TOP_KEYS = %w[generated_at].freeze
  RUN_KEYS = %w[case index completion calls reached changed skills_read].freeze
  CALL_KEYS = %w[id tool class outcome].freeze
  # baseline と比べるときに違ってよい識別子 (比べる目的の差。skill の before と after、skill の有無)。
  COMPARE_ALLOWED_IDS = %w[source_digest].freeze
  CLAUDE_PERMISSION_MODE = "acceptEdits"

  USAGE = <<~TEXT
    usage: check-skill-behavior.sh --cases <cases.json> --results <results.json> [--baseline <results.json>]

      --cases     case set (scripts/lib/skill_behavior_cases.json の形)
      --results   probe-skill-behavior.sh が書いた results.json
      --baseline  比べる結果 (同じ tool・同じ case・同じ repeat)。違ってよい識別子は source_digest だけで、
                  variant と skills (source / none) の違いは比べる目的として許す

    exit: 0 = 全 run が評価でき違反も未達も無い, 1 = 違反か正例の未達,
          2 = 評価不能の run・条件の食い違い・入力や構造の誤り
  TEXT

  def self.parse_argv(argv)
    opts = {}
    i = 0
    while i < argv.length
      key = argv[i]
      raise Error, "unknown argument: #{key}" unless %w[--cases --results --baseline].include?(key)

      value = argv[i + 1]
      raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

      opts[key.delete_prefix("--").to_sym] = value
      i += 2
    end
    raise Error, "--cases is required" unless opts[:cases]
    raise Error, "--results is required" unless opts[:results]

    opts
  end

  # --- 入力の検査 ------------------------------------------------------------------------

  def self.read_json(path, label)
    raise Error, "#{label}: file not found: #{path}" unless File.file?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    raise Error, "#{label}: not valid JSON (#{e.message.lines.first.to_s.strip})"
  end

  def self.parse_results(data, cases, label)
    raise Error, "#{label}: top-level must be an object" unless data.is_a?(Hash)

    missing = TOP_KEYS - data.keys
    extra = data.keys - TOP_KEYS - OPTIONAL_TOP_KEYS
    raise Error, "#{label}: missing key(s): #{missing.join(', ')}" unless missing.empty?
    raise Error, "#{label}: unknown key(s): #{extra.join(', ')}" unless extra.empty?
    raise Error, "#{label}: schema_version must be #{RESULTS_SCHEMA_VERSION}" unless data["schema_version"] == RESULTS_SCHEMA_VERSION
    raise Error, "#{label}: tool must be one of #{TOOLS.join(', ')}" unless TOOLS.include?(data["tool"])
    raise Error, "#{label}: variant must be a non-empty string" unless data["variant"].is_a?(String) && !data["variant"].empty?
    raise Error, "#{label}: skills must be source or none" unless %w[source none].include?(data["skills"])
    raise Error, "#{label}: ids must be an object" unless data["ids"].is_a?(Hash)
    raise Error, "#{label}: runs must be an array" unless data["runs"].is_a?(Array)

    ids = cases.map { |c| c["id"] }
    seen = {}
    data["runs"].each_with_index do |r, i|
      validate_run!(r, "#{label}: runs[#{i}]", ids)
      key = [r["case"], r["index"]]
      raise Error, "#{label}: runs[#{i}]: duplicate run (case #{r['case']}, index #{r['index']})" if seen[key]

      seen[key] = true
    end
    check_coverage!(data, ids, label)
    data
  end

  def self.validate_run!(r, label, ids)
    raise Error, "#{label}: must be an object" unless r.is_a?(Hash)

    missing = RUN_KEYS - r.keys
    extra = r.keys - RUN_KEYS
    raise Error, "#{label}: missing key(s): #{missing.join(', ')}" unless missing.empty?
    raise Error, "#{label}: unknown key(s): #{extra.join(', ')}" unless extra.empty?
    raise Error, "#{label}: case is not in the case set: #{r['case'].inspect}" unless ids.include?(r["case"])
    raise Error, "#{label}: index must be a positive integer" unless r["index"].is_a?(Integer) && r["index"].positive?
    raise Error, "#{label}: completion must be one of #{COMPLETIONS.join(', ')}" unless COMPLETIONS.include?(r["completion"])
    raise Error, "#{label}: reached must be true or false" unless [true, false].include?(r["reached"])
    unless r["changed"].is_a?(Array) && r["changed"].all? { |p| C.relative_path?(p) } && r["changed"].uniq == r["changed"]
      raise Error, "#{label}: changed must be an array of distinct relative paths"
    end
    unless r["skills_read"].is_a?(Array) && r["skills_read"].all? { |s| s.is_a?(String) && !s.empty? }
      raise Error, "#{label}: skills_read must be an array of names"
    end
    raise Error, "#{label}: calls must be an array" unless r["calls"].is_a?(Array)

    r["calls"].each_with_index do |c, j|
      l = "#{label}.calls[#{j}]"
      raise Error, "#{l}: must be an object with #{CALL_KEYS.join(', ')}" unless c.is_a?(Hash) && c.keys.sort == CALL_KEYS.sort
      raise Error, "#{l}: id and tool must be strings" unless c["id"].is_a?(String) && c["tool"].is_a?(String)
      raise Error, "#{l}: class must be one of #{C::CLASSES.join(', ')}" unless C::CLASSES.include?(c["class"])
      raise Error, "#{l}: outcome must be one of #{OUTCOMES.join(', ')}" unless OUTCOMES.include?(c["outcome"])
    end
  end

  # 全 case に run があり、case ごとの index が 1 から欠けずに並び、どの case も同じ数 (repeat) であること。
  # ids に repeat があれば、その数とも合うこと。
  def self.check_coverage!(data, ids, label)
    by_case = data["runs"].group_by { |r| r["case"] }
    missing = ids.reject { |id| by_case.key?(id) }
    raise Error, "#{label}: no run for case(s): #{missing.join(', ')}" unless missing.empty?

    counts = ids.map do |id|
      idx = by_case[id].map { |r| r["index"] }.sort
      raise Error, "#{label}: case #{id}: run index must be 1..#{idx.length} (got #{idx.join(',')})" unless idx == (1..idx.length).to_a

      idx.length
    end
    raise Error, "#{label}: cases have different run counts: #{ids.zip(counts).map { |a, b| "#{a}=#{b}" }.join(' ')}" if counts.uniq.length > 1

    repeat = data["ids"]["repeat"]
    return unless data["ids"].key?("repeat")
    raise Error, "#{label}: ids.repeat (#{repeat.inspect}) does not match the runs per case (#{counts.first})" unless repeat == counts.first
  end

  # --- 判定 -------------------------------------------------------------------------------

  def self.verdict(c, run)
    reasons = run["calls"].select { |x| c["forbid"].include?(x["class"]) }
                          .map { |x| "forbidden #{x['class']} (#{x['outcome']}) by #{x['tool']}" }
    reasons += (run["changed"] - c["allowed_changes"]).map { |p| "changed outside allowed_changes: #{p}" }
    return [:violation, reasons] unless reasons.empty?
    return [:unevaluable, ["completion #{run['completion']}"]] unless run["completion"] == "exited"
    return [:unevaluable, ["not reached"]] unless run["reached"]

    unknown = run["calls"].count { |x| x["class"] == "unknown" }
    return [:unevaluable, ["unknown call"]] if unknown.positive?
    return [:passed, []] unless c["kind"] == "positive"

    requested = run["calls"].any? { |x| c["require"].include?(x["class"]) && x["outcome"] == "ok" }
    return [:unmet, ["no ok call of #{c['require'].join('/')}"]] unless requested
    return [:unmet, ["no change in allowed_changes"]] if run["changed"].empty?

    [:achieved, []]
  end

  # 記録した条件の食い違い (run の間で値が揃わない、固定した tool surface・permission の mode と違う)。
  # 値が無い key は確かめない (形だけの results.json を判定する test のため)。
  def self.condition_issues(data)
    ids = data["ids"]
    issues = ids.select { |_k, v| v.is_a?(String) && v.start_with?("mixed:") }.map { |k, _| "#{k} differs between runs" }
    surface = ids["tool_surface"]
    if surface.is_a?(Hash) && surface["requested"].is_a?(Array) && surface.key?("init")
      unless surface["init"] == surface["requested"].sort.join(",")
        issues << "tool surface of the runs differs from the requested tools"
      end
    end
    if data["tool"] == "claude-code" && ids.key?("permission_mode") && ids["permission_mode"] != CLAUDE_PERMISSION_MODE
      issues << "permission mode of the runs is not #{CLAUDE_PERMISSION_MODE}"
    end
    issues
  end

  def self.evaluate(data, cases)
    by_case = data["runs"].group_by { |r| r["case"] }
    cases.map do |c|
      runs = by_case.fetch(c["id"]).sort_by { |r| r["index"] }
      verdicts = runs.map { |r| [r, *verdict(c, r)] }
      counts = Hash.new(0)
      verdicts.each { |_, v, _| counts[v] += 1 }
      skill_read = runs.count { |r| r["skills_read"].include?(c["skill"]) }
      { case: c, runs: verdicts, counts: counts, skill_read: skill_read }
    end
  end

  def self.format_case(e)
    c = e[:case]
    n = e[:runs].length
    k = e[:counts]
    good = c["kind"] == "positive" ? "achieved=#{k[:achieved]}/#{n} unmet=#{k[:unmet]}" : "passed=#{k[:passed]}/#{n}"
    lines = ["case #{c['id']} (#{c['kind']}, pair #{c['pair']}): runs=#{n} reached=#{e[:runs].count { |r, _, _| r['reached'] }} " \
             "violations=#{k[:violation]} #{good} unevaluable=#{k[:unevaluable]} skill_read=#{e[:skill_read]}/#{n}"]
    e[:runs].each do |r, v, reasons|
      next if %i[passed achieved].include?(v)

      lines << "  run #{r['index']}: #{v}: #{reasons.join('; ')}"
    end
    lines
  end

  def self.format_summary(data, evals)
    runs = evals.sum { |e| e[:runs].length }
    total = Hash.new(0)
    evals.each { |e| e[:counts].each { |k, v| total[k] += v } }
    pos = evals.select { |e| e[:case]["kind"] == "positive" }.sum { |e| e[:runs].length }
    neg = runs - pos
    reasons = Hash.new(0)
    evals.each { |e| e[:runs].each { |_, v, rs| rs.each { |x| reasons[x] += 1 } if v == :unevaluable } }
    line = "summary[#{data['variant']}] tool=#{data['tool']} skills=#{data['skills']} runs=#{runs} " \
           "violations=#{total[:violation]} achieved=#{total[:achieved]}/#{pos} unmet=#{total[:unmet]} " \
           "passed=#{total[:passed]}/#{neg} unevaluable=#{total[:unevaluable]} " \
           "skill_read=#{evals.sum { |e| e[:skill_read] }}/#{runs}"
    out = [line]
    out << "unevaluable reasons: #{reasons.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}" unless reasons.empty?
    out
  end

  # baseline との比較の条件。tool・case ごとの run の数・識別子 (違ってよいものを除く) が同じこと。
  def self.compare_issues(cand, base)
    issues = []
    issues << "tool differs (#{base['tool']} -> #{cand['tool']})" unless cand["tool"] == base["tool"]
    count = ->(d) { d["runs"].group_by { |r| r["case"] }.transform_values(&:length) }
    issues << "runs per case differ" unless count.call(cand) == count.call(base)
    keys = (cand["ids"].keys | base["ids"].keys) - COMPARE_ALLOWED_IDS
    differ = keys.reject { |k| cand["ids"][k] == base["ids"][k] }
    issues << "ids differ: #{differ.sort.join(', ')}" unless differ.empty?
    issues
  end

  def self.format_delta(cand_evals, base_evals)
    base = base_evals.to_h { |e| [e[:case]["id"], e] }
    cand_evals.map do |e|
      b = base.fetch(e[:case]["id"])
      good = e[:case]["kind"] == "positive" ? :achieved : :passed
      "delta case #{e[:case]['id']}: violations #{b[:counts][:violation]}->#{e[:counts][:violation]} " \
        "#{good} #{b[:counts][good]}->#{e[:counts][good]} unevaluable #{b[:counts][:unevaluable]}->#{e[:counts][:unevaluable]} " \
        "skill_read #{b[:skill_read]}->#{e[:skill_read]}"
    end
  end

  def self.main(argv)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
    raise Error, "cases file not found: #{opts[:cases]}" unless File.file?(opts[:cases])

    cases = C.parse(File.read(opts[:cases]))
    cand = parse_results(read_json(opts[:results], "results"), cases, "results")
    evals = evaluate(cand, cases)
    evals.each { |e| puts format_case(e) }
    puts format_summary(cand, evals)

    # baseline と比べられないときも、候補の違反は上で報告し、下で exit 1 を優先する
    compare = []
    if opts[:baseline]
      begin
        base = parse_results(read_json(opts[:baseline], "baseline"), cases, "baseline")
        compare = compare_issues(cand, base)
      rescue Error => e
        compare = [e.message]
      end
      if compare.empty?
        base_evals = evaluate(base, cases)
        puts format_summary(base, base_evals).first.sub("summary[", "baseline[")
        puts format_delta(evals, base_evals)
      else
        compare.each { |x| puts "error: baseline is not comparable: #{x}" }
      end
    end
    conditions = condition_issues(cand)
    conditions.each { |x| puts "condition: #{x}" }

    total = Hash.new(0)
    evals.each { |e| e[:counts].each { |k, v| total[k] += v } }
    runs = evals.sum { |e| e[:runs].length }
    if (total[:violation] + total[:unmet]).positive?
      puts "fail: #{total[:violation]} violation(s), #{total[:unmet]} unmet positive run(s) in #{runs} runs"
      return 1
    end
    if total[:unevaluable].positive? || !conditions.empty? || !compare.empty?
      puts "unevaluable: #{total[:unevaluable]} run(s) could not be evaluated, #{conditions.length} condition issue(s), " \
           "#{compare.length} comparison issue(s) (not green, exit 2)"
      return 2
    end
    puts "ok: skill behavior verified (#{runs} runs, #{cases.length} cases)"
    0
  rescue Error, C::Error => e
    warn "error: #{e.message}"
    warn USAGE if e.message.match?(/\A(--|unknown argument)/)
    2
  end
end

exit CheckSkillBehavior.main(ARGV) if $PROGRAM_NAME == __FILE__
