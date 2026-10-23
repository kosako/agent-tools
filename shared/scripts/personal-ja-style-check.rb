#!/usr/bin/env ruby
# frozen_string_literal: true
#
# personal-ja-style-check: AI が書いた日本語の文章に残りやすい型を見つけて指摘する (#556)。
#
# 見る型は、agent-tools の文章 (session の返答・Issue / PR の本文とコメント・commit message・作業ログ) を
# 測って user が「直したい」と選んだ 4 つ:
# - em-dash: ダッシュ (—・―・–・─) を文の区切りに使う。
# - bold-label: 太字の見出しに中身を続ける箇条書き (`- **見出し**: 中身`) と、行頭の `**見出し**:`。
# - long-run / long-sentence: 長い文が切れ目なく続く、1 文が長すぎる。
# - negation-run / idiom: 文末の打ち消しが続く、「〜側に倒す」「黙って無視」のような慣用の言い回し。
#
# 指摘を出すだけで、文章を直さず、何も書かない。gate ではない: 走り終えれば指摘の有無にかかわらず exit 0 で、
# 止めるかは読んだ人 (agent) が決める。公開の前の検査 (public-safety の gate) とは別の口で、並べて使う。
#
# 使い方: personal-ja-style-check [--json] (--stdin | <file>...)
# - --stdin: 標準入力の text を 1 つの入力として見る。file と一緒には使えない。
# - <file>: UTF-8 の text file (1 MiB まで)。複数可。
# - --json: 入力ごとの findings と stats を JSON で stdout に出す。
# 既定の出力は `<入力>:<行>: [<規則>] <説明> | <抜き出し>` を 1 指摘 1 行で stdout に出し、最後に件数の行を出す。
#
# 読み方 (Markdown を前提にする): fenced code block の中は見ない。inline code・<code>・URL は 1 文字の
# 置き字 (〓) に置き換えてから見る (中の記号や長さで判定しないため)。見出しと表の行は文として数えない
# (ダッシュだけ見る)。箇条書きの印・引用の印・太字の印・link の書き方は文の長さに含めない。文は「。！？!?」か
# 行末で切る。空行・見出し・表・code block で段落が切れ、「続く」の判定はそこで途切れる。
#
# exit: 0 = 走り終えた (指摘の有無は問わない) / 2 = usage・入力を読めない (file が無い・通常の file でない・
# 1 MiB を超える)・想定外の例外。stderr の message に入力の text は載せない。
#
# C locale でも読む text を UTF-8 として扱う (#432。personal-public-safety-gate と同じ固定)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

require "json"

module JaStyleCheck
  VERSION = "1"
  MAX_INPUT_BYTES = 1024 * 1024

  # 閾値 (文字数は空白を除く)。corpus で測って決めた値 (docs/ja-style-check.md)。
  LONG_SENTENCE = 60       # この長さ以上の文が LONG_RUN 文続くと long-run
  LONG_RUN = 3
  VERY_LONG_SENTENCE = 120 # 1 文がこの長さ以上なら long-sentence
  NEGATION_RUN = 3         # 文末の打ち消しがこの数続くと negation-run

  PLACEHOLDER = "〓"

  DASH = /[–—―─]+/
  FENCE_OPEN = /\A {0,3}(`{3,}|~{3,})/
  HEADING = /\A {0,3}\#{1,6}\s/
  TABLE_ROW = /\A\s*\|/
  LIST_MARKER = /\A\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/
  QUOTE_MARKER = /\A\s*(?:>\s?)+/
  # `- **見出し**: 中身` / `1. **見出し**: 中身` / 行頭の `**見出し**: 中身`。太字の中にコロンがある
  # 1 行まるごと太字 (`**判定: APPROVE**`) は当たらない。
  BOLD_LABEL_COLON = /\A\s*(?:(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?\*\*[^*\n]+?\*\*\s*[:：]/
  # 箇条書きの先頭が太字の見出しで、コロンの無い形 (`- **見出し** 中身`)。
  BULLET_BOLD_LEAD = /\A\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?\*\*[^*\n]+?\*\*(?:\s|\z)/
  INLINE_CODE = /`[^`\n]+`/
  HTML_CODE = %r{<code>.*?</code>}
  HTML_BOLD = %r{</?b>}
  HTML_TAG = %r{</?[A-Za-z][^<>\n]*>}
  # URL は空白・括弧の閉じ・日本語の句読点と括弧の開きの前で終わる (句点まで飲み込むと、後ろの文が消える)。
  URL = %r{https?://[^\s<>)）」』。、！？（「『]+}
  # link は宛先が何 (URL の置き字・相対 path・fragment) でも text だけを残す。
  LINK = /\[([^\]\n]*)\]\([^)\n]*\)/
  EMPHASIS = /\*\*|__/
  SENTENCE = /[^。！？!?]*[。！？!?]+|[^。！？!?]+\z/
  TERMINATORS = /[。！？!?]+\z/
  NEGATION_END = /(?:ない|ません|ぬ)[」』）)]*\z/
  IDIOMS = [
    [/側に倒[すしさせ]/, "「〜側に倒す」"],
    [/黙って(?:無視|捨て|落と|消)/, "「黙って〜する」"],
    [/前提が崩れ/, "「前提が崩れる」"],
  ].freeze

  class InputError < StandardError; end

  Finding = Struct.new(:rule, :line, :severity, :message, :snippet) do
    def to_h
      { "rule" => rule, "line" => line, "severity" => severity, "message" => message, "snippet" => snippet }
    end
  end

  Sentence = Struct.new(:line, :text, :length, :negation, :paragraph)

  # 1 つの入力の text を読み、findings と stats を持つ。
  class Document
    attr_reader :findings, :stats

    def initialize(text, scrubbed: false)
      @findings = []
      @sentences = []
      @masked_spans = 0
      @lines = 0
      scan(text)
      sentence_rules
      @findings.sort_by! { |f| [f.line, f.rule] }
      @stats = build_stats(scrubbed)
    end

    private

    # 行ごとに Markdown の構造を見分け、ダッシュと太字の見出しの規則を当て、文を切り出す。
    def scan(text)
      fence = nil
      fence_quoted = false
      paragraph = 0
      text.split("\n", -1).each_with_index do |raw, i|
        lineno = i + 1
        @lines = lineno
        # 引用の印は構造 (code block・見出し・表) を読む前に外す。引用の中の code block や見出しも同じに扱うため。
        line = raw.sub(QUOTE_MARKER, "")
        quoted = line != raw
        if fence
          # 引用の中で開いた code block は引用の印を外した行で閉じ、引用の外で開いたものは元の行で閉じる。
          fence = nil if (fence_quoted ? line : raw) =~ /\A {0,3}#{Regexp.escape(fence[0])}{#{fence.size},}\s*\z/
          paragraph += 1
          next
        end
        if (m = FENCE_OPEN.match(line))
          fence = m[1]
          fence_quoted = quoted
          paragraph += 1
          next
        end
        if line.strip.empty?
          paragraph += 1
          next
        end
        masked = mask(line)
        dash_rule(masked, lineno)
        if HEADING.match?(line) || TABLE_ROW.match?(line)
          paragraph += 1
          next
        end
        bold_label_rule(masked, lineno)
        split_sentences(prose(masked), lineno, paragraph)
      end
    end

    # inline code・<code>・URL を置き字にし、HTML の太字は Markdown の太字に、他の tag は外す。
    def mask(line)
      out = line.gsub(HTML_CODE) { count_masked }
      out = out.gsub(INLINE_CODE) { count_masked }
      out = out.gsub(URL) { count_masked }
      out = out.gsub(HTML_BOLD, "**")
      out.gsub(HTML_TAG, "")
    end

    def count_masked
      @masked_spans += 1
      PLACEHOLDER
    end

    # 文として読む部分: 箇条書きの印、太字の印、link の書き方を外す (引用の印は scan で外してある)。
    def prose(masked)
      masked.sub(LIST_MARKER, "").gsub(LINK, "\\1").gsub(EMPHASIS, "")
    end

    def dash_rule(masked, lineno)
      masked.scan(DASH) do
        pos = Regexp.last_match.begin(0)
        @findings << Finding.new("em-dash", lineno, "warn",
                                 "ダッシュを文の区切りに使っている。読点か句点で区切るか、文を分ける",
                                 around(masked, pos, 24))
      end
    end

    def bold_label_rule(masked, lineno)
      return unless BOLD_LABEL_COLON.match?(masked) || BULLET_BOLD_LEAD.match?(masked)
      @findings << Finding.new("bold-label", lineno, "warn",
                               "太字の見出しに中身を続ける箇条書き。地の文で書くか、見出しを外す",
                               excerpt(masked.strip, 40))
    end

    def split_sentences(text, lineno, paragraph)
      text.scan(SENTENCE) do |part|
        body = part.strip
        next if body.empty?
        length = body.gsub(/\s+/, "").size
        negation = NEGATION_END.match?(body.sub(TERMINATORS, "").rstrip)
        @sentences << Sentence.new(lineno, body, length, negation, paragraph)
      end
    end

    # 文の並びに当てる規則。「続く」は同じ段落の中だけで数える。
    def sentence_rules
      @sentences.group_by(&:paragraph).each_value do |sentences|
        runs(sentences) { |s| s.length >= LONG_SENTENCE }.each do |run|
          next if run.size < LONG_RUN
          lengths = run.map(&:length).join(", ")
          @findings << Finding.new("long-run", run.first.line, "warn",
                                   "#{LONG_SENTENCE} 字以上の文が #{run.size} つ続く (長さ: #{lengths})。" \
                                   "1 文を 2 つに分けるか、短い文を挟む",
                                   excerpt(run.first.text, 40))
        end
        runs(sentences, &:negation).each do |run|
          next if run.size < NEGATION_RUN
          @findings << Finding.new("negation-run", run.first.line, "warn",
                                   "文末の打ち消しが #{run.size} 文続く。肯定の言い方に変えられるか見る",
                                   excerpt(run.first.text, 40))
        end
      end
      @sentences.each do |s|
        if s.length >= VERY_LONG_SENTENCE
          @findings << Finding.new("long-sentence", s.line, "warn",
                                   "1 文が #{VERY_LONG_SENTENCE} 字を超える (#{s.length} 字)。2 つに分ける",
                                   excerpt(s.text, 40))
        end
        IDIOMS.each do |(pattern, label)|
          next unless pattern.match?(s.text)
          @findings << Finding.new("idiom", s.line, "info",
                                   "慣用の言い回し #{label}。平易な言い方にできるか見る",
                                   excerpt(s.text, 40))
        end
      end
    end

    # 条件を満たす要素が隣り合う最大の並びを返す。
    def runs(items)
      result = []
      current = []
      items.each do |item|
        if yield(item)
          current << item
        else
          result << current unless current.empty?
          current = []
        end
      end
      result << current unless current.empty?
      result
    end

    def excerpt(text, max)
      text.size > max ? "#{text[0, max]}…" : text
    end

    def around(text, pos, width)
      from = [pos - width / 2, 0].max
      excerpt(text[from, width], width)
    end

    def build_stats(scrubbed)
      lengths = @sentences.map(&:length)
      n = lengths.size
      mean = n.zero? ? 0.0 : lengths.sum.to_f / n
      sd = n.zero? ? 0.0 : Math.sqrt(lengths.sum { |l| (l - mean)**2 } / n)
      cv = mean.zero? ? 0.0 : sd / mean
      {
        "lines" => @lines,
        "sentences" => n,
        "chars" => lengths.sum,
        "mean_length" => mean.round(1),
        "max_length" => lengths.max || 0,
        "cv" => cv.round(3),
        "long_sentences" => lengths.count { |l| l >= LONG_SENTENCE },
        "negation_endings" => @sentences.count(&:negation),
        "masked_spans" => @masked_spans,
        "scrubbed" => scrubbed,
      }
    end
  end

  USAGE = "usage: personal-ja-style-check [--json] (--stdin | <file>...)"

  def self.run(argv)
    json = false
    use_stdin = false
    files = []
    argv.each do |arg|
      if arg == "--json"
        json = true
      elsif arg == "--stdin"
        use_stdin = true
      elsif arg.b.start_with?("-")
        # option の判定は byte で見る (壊れた UTF-8 の引数に正規表現を当てると ArgumentError になる)。
        $stderr.puts USAGE
        return 2
      else
        # ARGV は locale の encoding で来る (C locale なら ASCII-8BIT)。byte は変えずに UTF-8 として扱う (#432)。
        files << arg.dup.force_encoding(Encoding::UTF_8)
      end
    end
    if use_stdin == !files.empty?
      $stderr.puts USAGE
      return 2
    end

    inputs = use_stdin ? [["-", read_stdin]] : files.map { |f| [display_name(f), read_file(f)] }
    results = inputs.map { |(name, (text, scrubbed))| [name, Document.new(text, scrubbed: scrubbed)] }
    json ? print_json(results) : print_text(results)
    0
  rescue InputError => e
    $stderr.puts "ja-style-check: error: #{e.message}"
    2
  rescue StandardError => e
    # 想定外も exit 2 に倒す。内容を含みうる message は出さず class 名だけ。
    $stderr.puts "ja-style-check: unexpected error (#{e.class})"
    2
  end

  # 入力の bytes を UTF-8 の text にする。壊れた byte は置き換え、置き換えたことを stats に残す。
  def self.decode(bytes)
    text = bytes.force_encoding(Encoding::UTF_8)
    return [text, false] if text.valid_encoding?
    [text.scrub("�"), true]
  end

  # 出力に載せる入力の名前。UTF-8 として読めない byte を含む path は置き換え文字にする (file を開く path には使わない)。
  def self.display_name(path)
    path.valid_encoding? ? path : path.scrub("�")
  end

  def self.read_stdin
    bytes = $stdin.read
    raise InputError, "stdin が #{MAX_INPUT_BYTES} byte を超える" if bytes.bytesize > MAX_INPUT_BYTES
    decode(bytes)
  end

  def self.read_file(path)
    raise InputError, "#{path}: 通常の file でない" unless File.file?(path)
    raise InputError, "#{path}: #{MAX_INPUT_BYTES} byte を超える" if File.size(path) > MAX_INPUT_BYTES
    decode(File.read(path, mode: "rb"))
  end

  def self.print_text(results)
    total = 0
    results.each do |(name, doc)|
      doc.findings.each do |f|
        total += 1
        $stdout.puts "#{name}:#{f.line}: [#{f.rule}] #{f.message} | #{f.snippet}"
      end
    end
    $stdout.puts "ja-style-check: #{total} finding(s) in #{results.size} input(s)"
  end

  def self.print_json(results)
    payload = {
      "tool" => "personal-ja-style-check",
      "version" => VERSION,
      "inputs" => results.map do |(name, doc)|
        { "name" => name, "stats" => doc.stats, "findings" => doc.findings.map(&:to_h) }
      end,
    }
    $stdout.puts JSON.generate(payload)
  end
end

exit JaStyleCheck.run(ARGV) if $PROGRAM_NAME == __FILE__
