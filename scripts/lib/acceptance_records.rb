# frozen_string_literal: true

# 受け入れの記録 (docs/acceptance-records.md) を読み、今の engine の版と比べる (#725)。doctor が使う。
# - 記録は項目ごとに 1 行で、最後に通した smoke の engine の版、agent-tools と dotfiles の commit、日時、根拠を持つ。
# - 比べるのは engine の版だけ。commit は記録するだけで比べない (毎日変わるので、比べると常に未確認になる)。
# - 版は各 CLI の `--version` だけで読み、5 秒と出力 4 KiB を上限にする。CLI の生の出力は返さない。
# - doctor 自身は書き込みも通信もしない。起動した CLI の `--version` の副作用は保証の外 (docs の限界)。

require_relative "probe_child"

module AcceptanceRecords
  PATH = "docs/acceptance-records.md"
  # 項目と、関係する engine の正本 (docs の項目の表は test でこれと照らす)。順は docs と出力の順。
  ITEMS = {
    "hook-claude" => %w[claude-code],
    "hook-codex" => %w[codex],
    "worker-run" => %w[codex herdr],
    "notify" => %w[claude-code herdr],
    "resume" => %w[claude-code codex herdr],
  }.freeze
  # 版の 1 語: 数字 3 つと、任意の接尾辞 (`-` か `+` で始まる)。比べるのはこの 1 語の文字列全体。
  VERSION = /\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?/.freeze
  # engine ごとの版の command と、出力の 1 行目の形 (2026-11-28 の Claude Code 2.1.332・Codex 0.171.0・herdr 0.9.5 で測った)。
  ENGINES = {
    "claude-code" => { argv: %w[claude --version], line: /\A(#{VERSION}) \(Claude Code\)\z/ },
    "codex" => { argv: %w[codex --version], line: /\Acodex-cli (#{VERSION})\z/ },
    "herdr" => { argv: %w[herdr --version], line: /\Aherdr (#{VERSION})\z/ },
  }.freeze
  HEADER = %w[項目 engine agent-tools dotfiles 日時 根拠].freeze
  SECTION = "## 記録"
  TIMEOUT = 5
  MAX_BYTES = 4096

  Row = Struct.new(:item, :engines, :agent_tools, :dotfiles, :date, :evidence, keyword_init: true)

  module_function

  # 記録の文書の本文から、[rows, problems] を返す。表が無ければ nil (doctor は 1 行の warn を出す)。
  # problems は形の異常 (行ごと)。重複した項目は、どちらの行も rows に入れない。
  def parse(text)
    lines = text.lines.map(&:chomp)
    start = lines.index(SECTION)
    return nil unless start

    # 表は、`|` で始まる最初の行から、空行か次の `## ` の見出しの前までとする。途中の `|` で始まらない行は、表の行として
    # 読み、形の異常にする (黙って読むのを止めない。#810 の review)。
    table = []
    lines[(start + 1)..-1].each do |line|
      break if line.start_with?("## ")
      if table.empty?
        next if line.strip.empty?
        break unless line.start_with?("|")
      elsif line.strip.empty?
        break
      end
      table << line
    end
    return nil if table.length < 2 || cells(table[0]) != HEADER || !separator?(table[1])

    rows = []
    problems = []
    # 同じ項目の行は、形の異常の行も含めて数える (2 行目が崩れていても、1 行目を使わない。#810 の review)。
    named = Hash.new(0)
    table[2..-1].each_with_index do |line, i|
      first = cells(line).first
      named[first] += 1 if ITEMS.key?(first)
      row, problem = parse_row(line)
      if problem
        problems << "row #{i + 1}: #{problem}"
      else
        rows << row
      end
    end
    dup = named.select { |_, n| n > 1 }.keys
    dup.each { |item| problems << "item #{item} has more than one row" }
    [rows.reject { |r| dup.include?(r.item) }, problems]
  end

  def cells(line)
    inner = line.strip
    return [] unless inner.start_with?("|") && inner.end_with?("|")

    inner[1..-2].split("|", -1).map(&:strip)
  end

  def separator?(line)
    c = cells(line)
    c.length == HEADER.length && c.all? { |x| x.match?(/\A:?-{3,}:?\z/) }
  end

  def parse_row(line)
    c = cells(line)
    return [nil, "expected #{HEADER.length} columns"] unless c.length == HEADER.length

    item, engines, agent_tools, dotfiles, date, evidence = c
    return [nil, "unknown item"] unless ITEMS.key?(item)

    pairs = engines.split("; ", -1).map { |e| e.split(" ", -1) }
    unless pairs.all? { |p| p.length == 2 && ENGINES.key?(p[0]) && p[1].match?(/\A#{VERSION}\z/) }
      return [nil, "engine column must be '<engine> <version>' joined by '; '"]
    end
    return [nil, "engine listed twice"] unless pairs.map(&:first).uniq.length == pairs.length
    return [nil, "agent-tools commit must be 7-40 hex digits"] unless agent_tools.match?(/\A[0-9a-f]{7,40}\z/)
    return [nil, "dotfiles commit must be 7-40 hex digits"] unless dotfiles.match?(/\A[0-9a-f]{7,40}\z/)
    return [nil, "date must be YYYY-MM-DD"] unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    return [nil, "evidence must be #<number>"] unless evidence.match?(/\A#\d+\z/)

    [Row.new(item: item, engines: pairs.to_h, agent_tools: agent_tools, dotfiles: dotfiles, date: date,
             evidence: evidence), nil]
  end

  # 今の版を読む。読めなければ nil (CLI が無い、非ゼロで終わった、期限か上限を越えた、形が違う)。
  def read_version(engine)
    spec = ENGINES.fetch(engine)
    r = ProbeChild.run(spec[:argv], env: {}, chdir: "/", timeout: TIMEOUT, max_bytes: MAX_BYTES)
    return nil unless r.completed && r.status&.success? && !r.truncated

    first = r.out.to_s.lines.first.to_s.strip
    m = first.match(spec[:line])
    m && m[1]
  rescue SystemCallError
    nil
  end

  # 項目ごとの判定を [level, message] の列で返す。versions は engine => 版 (読めなければ nil) を返す callable。
  def evaluate(rows, versions)
    by_item = rows.map { |r| [r.item, r] }.to_h
    ITEMS.map do |item, engines|
      row = by_item[item]
      next ["warn", "#{item} not recorded"] unless row
      next ["warn", "#{item} unconfirmed (engines differ from the item: #{row.engines.keys.join(', ')})"] unless row.engines.keys.sort == engines.sort

      notes = engines.map do |engine|
        now = versions.call(engine)
        if now.nil?
          "#{engine} version unreadable"
        elsif now != row.engines.fetch(engine)
          "#{engine} #{row.engines.fetch(engine)} -> #{now}"
        end
      end.compact
      if notes.empty?
        ["ok", "#{item} (#{row.date}, #{row.evidence})"]
      else
        ["warn", "#{item} unconfirmed (#{notes.join('; ')})"]
      end
    end
  end
end
