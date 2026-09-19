#!/usr/bin/env ruby
# frozen_string_literal: true

# skill routing acceptance harness の判定コア (#280 A-1)。
# Spec: docs/skill-routing-acceptance.md。
#
# この lib は network / CLI にアクセスしない。probe の「実行」(隔離 project で claude / codex を
# 走らせ、どの skill が発火したかと token 使用量を観測する = 実機・probe-skill-routing.sh) と
# 「判定」(ここ) を分離し、判定を fixture で deterministic に検証できるようにする。
# 判定入力は case set (scripts/lib/skill_routing_cases.json) と probe 結果の JSON。
#
# 判定契約:
#   - coverage: case set の全 case に run がある (欠落 = 偽の安心 を弾く)。status が ok でない run
#     (CLI 失敗 / 観測不能) は緑に数えず構造エラーに倒す。
#   - primary hit: case の primary skill が observed に含まれる (primary が null の case は対象外)。
#   - must_not violation: case の must_not のいずれかが observed に含まれる (routing の破れ)。
#   - token: run ごとの prompt_tokens / output_tokens を合算して報告する (gate ではなく観測値。
#     description の圧縮が context 量に効いたかを見るための指標)。
#   - baseline 比較 (--baseline): 同じ tool・同じ model・同じ case 集合・同じ run 数の結果同士だけ
#     比較する (条件が違えば構造エラー)。候補で primary hit が減る、または violation が増えたら
#     回帰として exit 1。token の増減は報告だけで gate にしない。
#
# exit code の分類 (incident class を混ぜない):
#   - 1 = 観測された破れ (must_not violation / baseline からの回帰)。probe の結果そのものが赤。
#   - 2 = 入力・構造エラー (JSON 不正 / スキーマ違反 / coverage 欠落 / error run / 比較条件不一致)。
#     破れの証拠ではない。破れと同居するときは 1 を優先し、全 failure を報告する。
#   - 0 は完全 coverage かつ violation 0 (比較時は回帰なし) のときだけ。
#
# 信頼境界 (honest): judge は runner が付けた observed / token を信頼する。observed が実際の
# Skill 起動を正しく写しているかは runner の責務 (実機ログが証跡)。judge が縛れるのは coverage・
# 集合演算・比較条件までで、それ以上「検証」したフリをしない。

require "json"

module CheckSkillRouting
  class Error < StandardError; end

  CASES_SCHEMA_VERSION = 1
  RESULTS_SCHEMA_VERSION = 1
  KNOWN_TOOLS = %w[claude-code codex].freeze
  RUN_STATUSES = %w[ok error].freeze

  USAGE = <<~TEXT
    usage: check-skill-routing.sh --cases <cases.json> --results <results.json> [--baseline <results.json>]

    <cases.json>   case set (正本: scripts/lib/skill_routing_cases.json)
    <results.json> probe-skill-routing.sh の出力。shape:
      { "schema_version": 1, "tool": "claude-code", "model": "<model id>", "variant": "<label>",
        "runs": [ { "case": "<case id>", "observed": ["<skill name>", ...],
                    "prompt_tokens": 1234, "output_tokens": 56, "status": "ok" } ] }

    判定: 全 case に ok な run があること (coverage)。primary skill の hit と must_not skill の
    violation を数え、token を合算して報告する。--baseline を与えると同条件 (tool / model /
    case 集合 / run 数) の結果と比較し、primary hit の減少または violation の増加を回帰とする。

    exit: 0 = pass (violation 0、比較時は回帰なし),
          1 = breach observed (must_not violation / regression against baseline),
          2 = usage / input / structural error (invalid JSON, schema violation, coverage gap,
              error run, comparison condition mismatch)
  TEXT

  # --- 入力の検証 ---------------------------------------------------------------

  def self.parse_cases(raw)
    data = JSON.parse(raw)
    raise Error, "cases: input must be a JSON object" unless data.is_a?(Hash)
    unless data["schema_version"] == CASES_SCHEMA_VERSION
      raise Error, "cases: schema_version must be #{CASES_SCHEMA_VERSION}"
    end

    inventory = data["inventory"]
    unless inventory.is_a?(Array) && !inventory.empty? && inventory.all? { |s| skill_name?(s) }
      raise Error, "cases: inventory must be a non-empty array of skill names"
    end
    raise Error, "cases: inventory has duplicates" unless inventory.uniq.length == inventory.length

    cases = data["cases"]
    raise Error, "cases: cases must be a non-empty array" unless cases.is_a?(Array) && !cases.empty?
    cases.each_with_index { |c, i| validate_case!(c, i, inventory) }
    ids = cases.map { |c| c["id"] }
    raise Error, "cases: duplicate case id" unless ids.uniq.length == ids.length

    { inventory: inventory, cases: cases }
  end

  def self.validate_case!(c, index, inventory)
    raise Error, "cases[#{index}] must be an object" unless c.is_a?(Hash)
    raise Error, "cases[#{index}].id must be a non-empty string" unless label?(c["id"])
    raise Error, "cases[#{index}].cluster must be a non-empty string" unless label?(c["cluster"])
    unless c["prompt"].is_a?(String) && !c["prompt"].empty? && c["prompt"] !~ /[[:cntrl:]]/
      raise Error, "cases[#{index}].prompt must be a non-empty string without control characters"
    end
    unless c["primary"].nil? || inventory.include?(c["primary"])
      raise Error, "cases[#{index}].primary must be null or an inventory skill"
    end
    unless c["must_not"].is_a?(Array) && c["must_not"].all? { |s| inventory.include?(s) }
      raise Error, "cases[#{index}].must_not must be an array of inventory skills"
    end
    if c["must_not"].include?(c["primary"])
      raise Error, "cases[#{index}]: primary must not appear in must_not"
    end
  end

  def self.parse_results(raw, label)
    data = JSON.parse(raw)
    raise Error, "#{label}: input must be a JSON object" unless data.is_a?(Hash)
    unless data["schema_version"] == RESULTS_SCHEMA_VERSION
      raise Error, "#{label}: schema_version must be #{RESULTS_SCHEMA_VERSION}"
    end
    raise Error, "#{label}: tool must be one of #{KNOWN_TOOLS.join(', ')}" unless KNOWN_TOOLS.include?(data["tool"])
    raise Error, "#{label}: model must be a non-empty string" unless label?(data["model"])
    raise Error, "#{label}: variant must be a non-empty string" unless label?(data["variant"])

    runs = data["runs"]
    raise Error, "#{label}: runs must be an array" unless runs.is_a?(Array)
    runs.each_with_index { |r, i| validate_run!(r, i, label) }
    data
  end

  def self.validate_run!(r, index, label)
    raise Error, "#{label}: runs[#{index}] must be an object" unless r.is_a?(Hash)
    raise Error, "#{label}: runs[#{index}].case must be a non-empty string" unless label?(r["case"])
    unless RUN_STATUSES.include?(r["status"])
      raise Error, "#{label}: runs[#{index}].status must be one of #{RUN_STATUSES.join(', ')}"
    end
    unless r["observed"].is_a?(Array) && r["observed"].all? { |s| skill_name?(s) }
      raise Error, "#{label}: runs[#{index}].observed must be an array of skill names"
    end
    %w[prompt_tokens output_tokens].each do |key|
      unless r[key].is_a?(Integer) && r[key] >= 0
        raise Error, "#{label}: runs[#{index}].#{key} must be a non-negative integer"
      end
    end
  end

  # skill 名は失敗メッセージへ interpolate されるので、制御文字を入力エラーで弾く (出力偽造の防止)。
  def self.skill_name?(value)
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
  end

  def self.label?(value)
    value.is_a?(String) && !value.empty? && value !~ /[[:cntrl:]]/
  end

  # --- 判定 -------------------------------------------------------------------------

  # 1 結果 file の集計。coverage / error run は構造エラー、violation は破れ。
  # 戻り値: { summary:, per_case:, breaches:, structural: }
  def self.evaluate(cases, results, label)
    by_case = Hash.new { |h, k| h[k] = [] }
    results["runs"].each { |r| by_case[r["case"]] << r }

    structural = []
    breaches = []
    per_case = []
    known_ids = cases[:cases].map { |c| c["id"] }
    (by_case.keys - known_ids).each { |id| structural << "#{label}: run for unknown case '#{id}'" }

    hit = 0
    hit_total = 0
    violations = 0
    runs_total = 0
    prompt_tokens = 0
    output_tokens = 0

    cases[:cases].each do |c|
      runs = by_case[c["id"]]
      if runs.empty?
        structural << "#{label}: case '#{c['id']}' has no run (coverage gap)"
        next
      end
      runs.each do |r|
        if r["status"] != "ok"
          structural << "#{label}: case '#{c['id']}' has a run with status '#{r['status']}' (not counted as green)"
          next
        end
        runs_total += 1
        prompt_tokens += r["prompt_tokens"]
        output_tokens += r["output_tokens"]
        observed = r["observed"]
        primary_hit = c["primary"].nil? ? nil : observed.include?(c["primary"])
        unless c["primary"].nil?
          hit_total += 1
          hit += 1 if primary_hit
        end
        violated = c["must_not"] & observed
        if violated.any?
          violations += 1
          breaches << "#{label}: case '#{c['id']}' triggered must_not skill(s) #{violated.join(', ')}"
        end
        per_case << {
          id: c["id"], primary: c["primary"], primary_hit: primary_hit, violated: violated,
          observed: observed, prompt_tokens: r["prompt_tokens"], output_tokens: r["output_tokens"]
        }
      end
    end

    summary = {
      label: label, variant: results["variant"], tool: results["tool"], model: results["model"],
      runs: runs_total, hit: hit, hit_total: hit_total, violations: violations,
      prompt_tokens: prompt_tokens, output_tokens: output_tokens
    }
    { summary: summary, per_case: per_case, breaches: breaches, structural: structural }
  end

  # baseline との比較条件 (tool / model / case ごとの run 数) を検証する。違えば構造エラー。
  def self.comparison_structural(cases, candidate, baseline)
    failures = []
    failures << "comparison: tool differs (#{baseline['tool']} vs #{candidate['tool']})" if candidate["tool"] != baseline["tool"]
    failures << "comparison: model differs (#{baseline['model']} vs #{candidate['model']})" if candidate["model"] != baseline["model"]
    cases[:cases].each do |c|
      n_c = candidate["runs"].count { |r| r["case"] == c["id"] }
      n_b = baseline["runs"].count { |r| r["case"] == c["id"] }
      failures << "comparison: run count differs for case '#{c['id']}' (#{n_b} vs #{n_c})" if n_c != n_b
    end
    failures
  end

  # 候補が baseline から回帰していれば breach として返す (hit 減少 / violation 増加)。
  def self.regressions(cand, base)
    out = []
    if cand[:hit] < base[:hit]
      out << "regression: primary hits decreased (#{base[:hit]}/#{base[:hit_total]} -> #{cand[:hit]}/#{cand[:hit_total]})"
    end
    if cand[:violations] > base[:violations]
      out << "regression: must_not violations increased (#{base[:violations]} -> #{cand[:violations]})"
    end
    out
  end

  # --- 出力 -------------------------------------------------------------------------

  def self.format_case(pc)
    primary = pc[:primary].nil? ? "primary=n/a" : "primary=#{pc[:primary_hit] ? 'hit' : 'MISS'}"
    must_not = pc[:violated].empty? ? "must_not=ok" : "must_not=VIOLATED(#{pc[:violated].join(',')})"
    "case #{pc[:id]}: #{primary} #{must_not} observed=[#{pc[:observed].join(',')}] " \
      "tokens=#{pc[:prompt_tokens]}/#{pc[:output_tokens]}"
  end

  def self.format_summary(s)
    mean = s[:runs].zero? ? 0 : (s[:prompt_tokens].to_f / s[:runs]).round
    "summary[#{s[:label]}] variant=#{s[:variant]} tool=#{s[:tool]} model=#{s[:model]} runs=#{s[:runs]} " \
      "primary=#{s[:hit]}/#{s[:hit_total]} violations=#{s[:violations]} " \
      "prompt_tokens=#{s[:prompt_tokens]} (mean #{mean}) output_tokens=#{s[:output_tokens]}"
  end

  def self.format_delta(cand, base)
    pct = lambda do |c, b|
      b.zero? ? "n/a" : format("%+.1f%%", (c - b) * 100.0 / b)
    end
    "delta candidate-baseline: primary #{format('%+d', cand[:hit] - base[:hit])}, " \
      "violations #{format('%+d', cand[:violations] - base[:violations])}, " \
      "prompt_tokens #{pct.call(cand[:prompt_tokens], base[:prompt_tokens])}, " \
      "output_tokens #{pct.call(cand[:output_tokens], base[:output_tokens])}"
  end

  # --- CLI --------------------------------------------------------------------------

  def self.parse_argv(argv)
    opts = {}
    i = 0
    while i < argv.length
      key = argv[i]
      case key
      when "--cases", "--results", "--baseline"
        value = argv[i + 1]
        raise Error, "#{key} requires a path" if value.nil? || value.start_with?("-")
        raise Error, "#{key} given twice" if opts.key?(key)
        opts[key] = value
        i += 2
      else
        raise Error, "unknown argument: #{key}"
      end
    end
    raise Error, "--cases and --results are required" unless opts["--cases"] && opts["--results"]
    opts
  end

  def self.read_file(path, label)
    raise Error, "#{label} file not found: #{path}" unless File.file?(path)
    File.read(path)
  end

  def self.main(argv)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end

    opts = begin
      parse_argv(argv)
    rescue Error => e
      warn "error: #{e.message}"
      warn USAGE
      return 2
    end

    cases = parse_cases(read_file(opts["--cases"], "cases"))
    candidate = parse_results(read_file(opts["--results"], "results"), "results")
    cand = evaluate(cases, candidate, "candidate")
    cand[:per_case].each { |pc| puts format_case(pc) }
    puts format_summary(cand[:summary])

    breaches = cand[:breaches]
    structural = cand[:structural]

    if opts["--baseline"]
      baseline = parse_results(read_file(opts["--baseline"], "baseline"), "baseline")
      base = evaluate(cases, baseline, "baseline")
      puts format_summary(base[:summary])
      structural += base[:structural]
      structural += comparison_structural(cases, candidate, baseline)
      # baseline 側の violation は候補の破れではない (比較の基準)。回帰判定にだけ使う。
      if structural.empty?
        puts format_delta(cand[:summary], base[:summary])
        breaches += regressions(cand[:summary], base[:summary])
      end
    end

    if breaches.empty? && structural.empty?
      puts "ok: skill routing verified (#{cand[:summary][:runs]} runs, #{cases[:cases].length} cases)"
      return 0
    end

    (breaches + structural).each { |failure| warn "FAIL: #{failure}" }
    breaches.empty? ? 2 : 1
  rescue Error, JSON::ParserError, SystemCallError => e
    warn "error: #{e.message}"
    2
  end
end

exit CheckSkillRouting.main(ARGV) if $PROGRAM_NAME == __FILE__
