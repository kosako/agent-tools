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
#   - 観測の全損: primary を持つ run があるのに ok の run の observed がすべて空なら構造エラー (#582)。1 件ずつの
#     primary MISS は報告だけで exit に響かないので、全損は別に止める。一部だけ観測を失ったときは見分けられない
#     (下の「信頼境界」)。
#   - primary hit: case の primary skill が observed に含まれる (primary が null の case は対象外)。
#   - must_not violation: case の must_not のいずれかが observed に含まれる (routing の破れ)。
#   - token: run ごとの prompt_tokens / output_tokens を合算して報告する (gate ではなく観測値。
#     description の圧縮が context 量に効いたかを見るための指標)。first_prompt_tokens (最初の
#     API call の prompt 量) は任意 field で、全 ok run が持つときだけ集計する。turn 数に依存
#     しないので listing の大きさの差はこちらに素直に出る。
#   - baseline 比較 (--baseline): 同じ tool・同じ model・同じ case 集合・同じ run 数の結果同士だけ
#     比較する (条件が違えば構造エラー)。primary は case ごとに比べ、baseline で半分以上の run が当たって
#     いた case が候補で一度も当たらなければ回帰として exit 1 (#417)。それより小さい減少は warn: の行で
#     出し、exit に響かない。合計は比べない。must_not は baseline によらず候補の run ごとの破れ (上)。
#     token の増減は報告だけで gate にしない。
#
# exit code の分類 (incident class を混ぜない):
#   - 1 = 観測された破れ (must_not violation / baseline からの回帰)。probe の結果そのものが赤。
#   - 2 = 入力・構造エラー (JSON 不正 / スキーマ違反 / coverage 欠落 / error run / 観測の全損 / 比較条件不一致)。
#     破れの証拠ではない。破れと同居するときは 1 を優先し、全 failure を報告する。
#   - 0 は完全 coverage かつ violation 0 (比較時は回帰なし) のときだけ。
#
# 信頼境界 (honest): judge は runner が付けた observed / token を信頼する。observed が実際の
# Skill 起動を正しく写しているかは runner の責務 (実機ログが証跡)。judge が縛れるのは coverage・
# 集合演算・比較条件までで、それ以上「検証」したフリをしない。

require "json"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
# この entrypoint は cli.rb (#418 の固定) を require しないので、同じ固定を各自で持つ。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

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
                    "prompt_tokens": 1234, "output_tokens": 56, "status": "ok",
                    "first_prompt_tokens": 1000 } ] }   (first_prompt_tokens は任意)

    判定: 全 case に ok な run があること (coverage)。primary skill の hit と must_not skill の
    violation を数え、token を合算して報告する (prompt_tokens = run 全体、first_prompt_tokens =
    最初の API call の prompt 量。後者は全 run が持つときだけ集計)。--baseline を与えると同条件
    (tool / model / case 集合 / run 数) の結果と case ごとに比較する。baseline で半分以上の run が primary に
    当たっていた case が、候補で一度も当たらなければ回帰。それより小さい減少は warn: の行で出し、exit に
    響かない (合計は比べない)。must_not は baseline によらず、候補で 1 回でも出れば破れ。token は gate に
    せず delta を報告するだけ。

    exit: 0 = pass (violation 0、比較時は回帰なし),
          1 = breach observed (must_not violation / regression against baseline),
          2 = usage / input / structural error (invalid JSON, schema violation, coverage gap,
              error run, every observed empty although primary cases exist, comparison condition mismatch)
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
    unless case_id?(c["id"])
      raise Error, "cases[#{index}].id must match [A-Za-z0-9][A-Za-z0-9._-]* (used as a raw log file name)"
    end
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
    # first_prompt_tokens (最初の API call の prompt 量) は取れる tool だけが書く任意 field。
    if r.key?("first_prompt_tokens") && !(r["first_prompt_tokens"].is_a?(Integer) && r["first_prompt_tokens"] >= 0)
      raise Error, "#{label}: runs[#{index}].first_prompt_tokens must be a non-negative integer when present"
    end
  end

  # skill 名は失敗メッセージへ interpolate されるので、制御文字を入力エラーで弾く (出力偽造の防止)。
  def self.skill_name?(value)
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
  end

  # case id は probe の raw log の file 名 (<out>.raw/<id>-<n>.jsonl) に使うので、skill 名と同じ安全な
  # 文字集合に限る (path の区切りや '..' で raw dir の外を指させない)。
  def self.case_id?(value)
    skill_name?(value)
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
    first_tokens = 0
    first_count = 0
    observed_any = false

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
        if r.key?("first_prompt_tokens")
          first_tokens += r["first_prompt_tokens"]
          first_count += 1
        end
        observed = r["observed"]
        observed_any ||= !observed.empty?
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
          observed: observed, prompt_tokens: r["prompt_tokens"], output_tokens: r["output_tokens"],
          first_prompt_tokens: r["first_prompt_tokens"]
        }
      end
    end

    # 観測の全損 (#582): primary を持つ run があるのに、ok の run の observed がすべて空なら、routing の結果ではなく
    # runner 側の観測の失敗 (CLI の event の形の変化など) と見分けられないので構造エラーにする。primary MISS は 1 件
    # ずつなら報告だけで、baseline との比較でも両方が全損なら回帰にならないため、ここで止める。
    if runs_total.positive? && hit_total.positive? && !observed_any
      structural << "#{label}: every ok run has an empty observed although #{hit_total} run(s) expect a primary skill " \
                    "(observation lost; check the runner / event format, not a routing result)"
    end

    # first_prompt_tokens は全 ok run が持つときだけ集計値として意味を持つ (一部欠けは n/a)。
    summary = {
      label: label, variant: results["variant"], tool: results["tool"], model: results["model"],
      runs: runs_total, hit: hit, hit_total: hit_total, violations: violations,
      prompt_tokens: prompt_tokens, output_tokens: output_tokens,
      first_prompt_tokens: (first_count == runs_total && runs_total.positive? ? first_tokens : nil)
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

  # primary の hit を case ごとに比べる (#417)。baseline で半分以上の run が当たっていた case が、候補で一度も当たら
  # なければ回帰 (breach)。それより小さい減少は警告で、exit には響かない。合計は比べない (ある case の回帰が別の case
  # の改善で打ち消され、揺れだけの差が回帰になるため)。must_not は evaluate が候補の run ごとに破れにするので、ここ
  # では比べない。比較条件 (case ごとの run 数が同じ) は comparison_structural が先に確かめる。
  # 戻り値: [regressions, warnings]
  def self.case_regressions(cand_per_case, base_per_case)
    cand = primary_tally(cand_per_case)
    regressions = []
    warnings = []
    primary_tally(base_per_case).each do |id, (b_hit, b_total)|
      c_hit, c_total = cand.fetch(id, [0, 0])
      next if c_total.zero?

      if b_hit * 2 >= b_total && c_hit.zero?
        regressions << "regression: case '#{id}' primary never hit in candidate (#{b_hit}/#{b_total} -> 0/#{c_total})"
      elsif c_hit * b_total < b_hit * c_total
        warnings << "case '#{id}' primary hit rate decreased (#{b_hit}/#{b_total} -> #{c_hit}/#{c_total})"
      end
    end
    [regressions, warnings]
  end

  # case ごとの primary の [hit 数, run 数] (`primary: null` の case は数えない)。
  def self.primary_tally(per_case)
    per_case.each_with_object({}) do |pc, tally|
      next if pc[:primary].nil?

      hit, total = tally.fetch(pc[:id], [0, 0])
      tally[pc[:id]] = [hit + (pc[:primary_hit] ? 1 : 0), total + 1]
    end
  end

  # --- 出力 -------------------------------------------------------------------------

  def self.format_case(pc)
    primary = pc[:primary].nil? ? "primary=n/a" : "primary=#{pc[:primary_hit] ? 'hit' : 'MISS'}"
    must_not = pc[:violated].empty? ? "must_not=ok" : "must_not=VIOLATED(#{pc[:violated].join(',')})"
    "case #{pc[:id]}: #{primary} #{must_not} observed=[#{pc[:observed].join(',')}] " \
      "tokens=first:#{pc[:first_prompt_tokens] || 'n/a'} total:#{pc[:prompt_tokens]} out:#{pc[:output_tokens]}"
  end

  def self.format_summary(s)
    mean = ->(total) { s[:runs].zero? ? 0 : (total.to_f / s[:runs]).round }
    first = s[:first_prompt_tokens] ? "#{s[:first_prompt_tokens]} (mean #{mean.call(s[:first_prompt_tokens])})" : "n/a"
    "summary[#{s[:label]}] variant=#{s[:variant]} tool=#{s[:tool]} model=#{s[:model]} runs=#{s[:runs]} " \
      "primary=#{s[:hit]}/#{s[:hit_total]} violations=#{s[:violations]} " \
      "prompt_tokens=#{s[:prompt_tokens]} (mean #{mean.call(s[:prompt_tokens])}) output_tokens=#{s[:output_tokens]} " \
      "first_prompt_tokens=#{first}"
  end

  def self.format_delta(cand, base)
    pct = lambda do |c, b|
      c.nil? || b.nil? || b.zero? ? "n/a" : format("%+.1f%%", (c - b) * 100.0 / b)
    end
    "delta candidate-baseline: primary #{format('%+d', cand[:hit] - base[:hit])}, " \
      "violations #{format('%+d', cand[:violations] - base[:violations])}, " \
      "prompt_tokens #{pct.call(cand[:prompt_tokens], base[:prompt_tokens])}, " \
      "output_tokens #{pct.call(cand[:output_tokens], base[:output_tokens])}, " \
      "first_prompt_tokens #{pct.call(cand[:first_prompt_tokens], base[:first_prompt_tokens])}"
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
      # baseline 側の violation は候補の破れではなく、比較にも使わない (must_not は候補の run ごとの破れ)。
      if structural.empty?
        puts format_delta(cand[:summary], base[:summary])
        regressed, warnings = case_regressions(cand[:per_case], base[:per_case])
        warnings.each { |w| puts "warn: #{w}" }
        breaches += regressed
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
