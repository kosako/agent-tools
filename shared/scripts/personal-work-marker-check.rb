#!/usr/bin/env ruby
# frozen_string_literal: true
#
# personal-work-marker-check: 計測が読む目印 (docs/work-markers.md の v2) の形を、投稿の前に確かめる (#661)。
#
# kind:
# - pr: 1 行目に PR の題、空行、続いて本文。題の末尾の `(#<番号>)` か、本文の `Closes #<番号>` の行の少なくとも一方で
#   Issue と紐付く。両方あれば、題の番号が `Closes` の行の番号に含まれる。
# - review-result: review の結果コメント。決まった 3 行 (見出し・verdict・Finding summary) が行の先頭からちょうど
#   1 回ずつあり、verdict が finding の数と合う (review-output-contract の表)。
# - escape-issue: `escape` の label を付ける Issue の本文。`元の PR: #<番号>` の行が行の先頭からちょうど 1 回あり、
#   形が合う。
#
# どの kind も Markdown の構文を解釈しない。決まった形の行を行の先頭から読み、code block の中でも数える (近似の
# Markdown の解釈は、list・字下げ・fence の組み合わせの境界で取りこぼすため。#663 の review)。例を書くときは、決まった
# 形にならないように書く (番号を `<番号>` にする、行の先頭に空白を入れる)。
# pr の本文で、決まった形 (行の先頭からの `Closes #<番号>` の 1 行) の外に GitHub の closing keyword があれば、GitHub が
# 閉じる Issue として読むことがあるので、崩れではなく note で知らせる。別の repository の参照
# (`Closes <owner>/<repo>#<番号>`) は、題の番号との照合に使わない。
#
# 何も書かず、network に触れない。出力に入力の本文は載せない (行番号・規則・説明だけ)。
#
# 使い方: personal-work-marker-check --kind (pr|review-result|escape-issue) --stdin
# 出力: 形の崩れごとに `-:<行>: [<規則>] <説明>` を stdout に出す (行が決まらないときは 0)。崩れではない注意は
# `-:<行>: note: [<規則>] <説明>`。最後に `work-marker-check: <kind>: ok|<N> error(s) (markers v<版>)` の行を出す
# (<版> は MARKERS_VERSION。今は 2)。
#
# exit: 0 = 形が合う / 1 = 形が崩れている (投稿しない) / 2 = usage・入力を読めない (1 MiB を超える、UTF-8 として
# 読めない、pr の 2 行目が空でない、pr の題が空)・想定外の例外。stderr の message に入力の text は載せない。
#
# C locale でも読む text を UTF-8 として扱う (#432。personal-public-safety-gate と同じ固定)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module WorkMarkerCheck
  MARKERS_VERSION = "2"
  MAX_INPUT_BYTES = 1024 * 1024
  KINDS = %w[pr review-result escape-issue].freeze

  # 決まった行の形 (docs/work-markers.md の v2)。括弧は全角、絵文字は雛形と同じ codepoint (異体字の選択子なし)。
  RESULT_HEADING = /\A## 📋 レビュー結果（by (?:Codex|Claude|personal-dependabot-pin-check)）/
  VERDICT_LINE = /\A\*\*Review process verdict: (?<verdict>REJECT|Warning|APPROVE)\*\*[ \t]*\z/
  FINDING_SUMMARY = %r{\A\*\*Finding summary: 🔴 must (?<must>\d+) / 🟡 should (?<should>\d+) / ⚪ nit (?<nit>\d+)\*\*[ \t]*\z}
  REF = %r{(?:#\d+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#\d+)}
  ORIGIN_PR = /\A元の PR: #{REF}(?:, #{REF})*[ \t]*\z/

  # 形が合わないときに、近い行を手掛かりとして示すための緩い一致。
  RESULT_HEADING_NEAR = /\A\s*#|📋/
  VERDICT_NEAR = /review process verdict/i
  FINDING_NEAR = /finding summary/i
  ORIGIN_NEAR = /元の\s*PR/

  PR_TITLE_REF = /\(#(?<num>\d+)\)[ \t]*\z/
  # 本文の Issue を閉じる目印の行。行の先頭から `Closes #<番号>` が 1 つだけ (別の repository は `<owner>/<repo>#<番号>`)。
  CLOSES_LINE = %r{\ACloses (?:(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#(?<num>\d+)[ \t]*\z}
  # GitHub の closing keyword (close / fix / resolve の活用形。大文字小文字は問わず、後ろの `:` を許す)。決まった形の行の
  # 外にあれば note で知らせる。
  CLOSING = /(?<![A-Za-z0-9_])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?[ \t]+(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#\d+/i

  class InputError < StandardError; end

  Finding = Struct.new(:line, :rule, :message, :note)

  # 1 つの入力を kind の規則で見て、findings を持つ。
  class Document
    attr_reader :findings

    def initialize(kind, text)
      @findings = []
      @lines = text.sub(/\A\u{FEFF}/, "").split(/\r?\n/, -1)
      case kind
      when "pr" then check_pr
      when "review-result" then check_review_result
      when "escape-issue" then check_escape_issue
      end
    end

    def errors
      @findings.reject(&:note)
    end

    private

    def error(line, rule, message)
      @findings << Finding.new(line, rule, message, false)
    end

    def note(line, rule, message)
      @findings << Finding.new(line, rule, message, true)
    end

    # 行の番号 (1 始まり) の一覧。
    def matching(pattern)
      @lines.each_index.select { |i| pattern.match?(@lines[i]) }.map { |i| i + 1 }
    end

    # 決まった行がちょうど 1 回あることを確かめ、その行の番号を返す (無い・重複なら nil)。
    def exactly_one(pattern, near, rule, label)
      hits = matching(pattern)
      if hits.size == 1
        hits.first
      elsif hits.empty?
        nears = matching(near)
        hint = nears.empty? ? "" : " (近い形の行: #{nears.first(5).join(', ')}。行の先頭から、docs/work-markers.md と同じ文字で書く)"
        error(nears.first || 0, rule, "#{label}が無い#{hint}")
        nil
      else
        hits.drop(1).each { |n| error(n, rule, "#{label}が重複している (最初は #{hits.first} 行目)") }
        nil
      end
    end

    def check_review_result
      exactly_one(RESULT_HEADING, RESULT_HEADING_NEAR, "result-heading", "見出し `## 📋 レビュー結果（by <reviewer>）` の行")
      verdict_at = exactly_one(VERDICT_LINE, VERDICT_NEAR, "verdict-line", "`**Review process verdict: <verdict>**` の行")
      summary_at = exactly_one(FINDING_SUMMARY, FINDING_NEAR, "finding-summary", "`**Finding summary: 🔴 must N / 🟡 should N / ⚪ nit N**` の行")
      return unless verdict_at && summary_at

      verdict = VERDICT_LINE.match(@lines[verdict_at - 1])[:verdict]
      counts = FINDING_SUMMARY.match(@lines[summary_at - 1])
      expected = if counts[:must].to_i.positive? then "REJECT"
                 elsif counts[:should].to_i.positive? then "Warning"
                 else "APPROVE"
                 end
      return if verdict == expected

      error(verdict_at, "verdict-mismatch", "verdict が #{verdict} だが、finding の数からは #{expected} (must があれば REJECT、must 0 で should があれば Warning、どちらも 0 なら APPROVE)")
    end

    def check_escape_issue
      exactly_one(ORIGIN_PR, ORIGIN_NEAR, "origin-pr", "`元の PR: #<番号>` の行")
    end

    def check_pr
      title = @lines.first.to_s
      raise InputError, "1 行目に PR の題を書く" if title.strip.empty?
      raise InputError, "2 行目は空行にする (1 行目に題、空行、続いて本文)" if @lines.size > 1 && !@lines[1].strip.empty?

      title_ref = PR_TITLE_REF.match(title)&.[](:num)
      closes = [] # 決まった形の行: [行, repo, 番号]
      loose = []  # 決まった形の外に closing keyword がある行
      @lines.each_with_index do |line, i|
        next if i < 2

        if (m = CLOSES_LINE.match(line))
          closes << [i + 1, m[:repo], m[:num]]
        elsif CLOSING.match?(line)
          loose << i + 1
        end
      end
      local = closes.reject { |(_, repo, _)| repo }
      numbers = local.map(&:last).uniq
      unless loose.empty?
        note(loose.first, "loose-closing",
             "決まった形 (行の先頭からの `Closes #<番号>` の 1 行) の外に closing keyword がある (#{loose.first(5).join(', ')} 行目)。" \
             "GitHub が閉じる Issue として読むことがある。閉じるなら決まった形の行にし、例なら番号を `<番号>` のように書く")
      end
      if title_ref.nil? && numbers.empty?
        error(1, "issue-link", "Issue との紐付けが無い (題の末尾の `(#<番号>)` か、本文の行の先頭からの `Closes #<番号>` を書く)")
        return
      end
      if title_ref && !numbers.empty? && !numbers.include?(title_ref)
        error(local.first.first, "issue-mismatch",
              "題の (##{title_ref}) が、本文の Closes の行の Issue (#{numbers.map { |n| "##{n}" }.join(', ')}) に無い")
      end
      note(1, "no-title-ref", "題の末尾に `(#<番号>)` が無い (本文の Closes の行で紐付く)") if title_ref.nil?
      note(1, "no-closes", "本文に Closes の行が無い (Issue を閉じない途中の PR なら、このままでよい)") if numbers.empty?
    end
  end

  USAGE = "usage: personal-work-marker-check --kind (#{KINDS.join('|')}) --stdin"

  def self.run(argv)
    kind = nil
    use_stdin = false
    args = argv.dup
    until args.empty?
      arg = args.shift
      if arg == "--stdin"
        use_stdin = true
      elsif arg == "--kind" && kind.nil? && !args.empty?
        kind = args.shift
      else
        $stderr.puts USAGE
        return 2
      end
    end
    unless use_stdin && KINDS.include?(kind)
      $stderr.puts USAGE
      return 2
    end

    doc = Document.new(kind, read_stdin)
    doc.findings.sort_by { |f| [f.line, f.note ? 1 : 0, f.rule] }.each do |f|
      $stdout.puts(f.note ? "-:#{f.line}: note: [#{f.rule}] #{f.message}" : "-:#{f.line}: [#{f.rule}] #{f.message}")
    end
    errors = doc.errors.size
    $stdout.puts "work-marker-check: #{kind}: #{errors.zero? ? 'ok' : "#{errors} error(s)"} (markers v#{MARKERS_VERSION})"
    errors.zero? ? 0 : 1
  rescue InputError => e
    $stderr.puts "work-marker-check: error: #{e.message}"
    2
  rescue StandardError => e
    # 想定外も exit 2 に倒す。内容を含みうる message は出さず class 名だけ。
    $stderr.puts "work-marker-check: unexpected error (#{e.class})"
    2
  end

  def self.read_stdin
    # 上限 + 1 byte までだけ読む (超えた入力を全部読まずに断る)。空の入力では read が nil を返す。
    bytes = $stdin.binmode.read(MAX_INPUT_BYTES + 1) || +""
    raise InputError, "stdin が #{MAX_INPUT_BYTES} byte を超える" if bytes.bytesize > MAX_INPUT_BYTES

    text = bytes.force_encoding(Encoding::UTF_8)
    raise InputError, "stdin を UTF-8 として読めない" unless text.valid_encoding?

    text
  end
end

exit WorkMarkerCheck.run(ARGV) if $PROGRAM_NAME == __FILE__
