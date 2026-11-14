#!/usr/bin/env ruby
# frozen_string_literal: true

# personal-post-check: 投稿や記録の前の 3 つの検査 (文体・目印・public-safety の gate) を順にかけ、結果を 1 つにまとめて返す (#676)。
# 投稿はしない。何も書かず、network に触れない。
#
# かける検査は、この script と同じ directory の次の 3 つ。それぞれの規則と出力は変えない。
# - personal-ja-style-check --stdin                     文体。指摘だけで、止めない検査
# - personal-work-marker-check --kind <kind> --stdin    目印の形。--marker-kind を渡したときだけ
# - personal-public-safety-gate --stdin                 公開の前の gate
# 3 つは、途中で止めずにすべてかける (1 つが止まっても、残りの結果を 1 回で読めるように)。
#
# 使い方: personal-post-check --body-file <file> [--title <題名>] [--marker-kind <pr|review-result|escape-issue>] [--style-reviewed]
# - --body-file: 本文の file (regular file、UTF-8、1 MiB まで、空白だけでない)。
# - --title: 題名 (1 行で、空でない)。渡すと、検査に渡す入力は「題名、空行、本文」になる。合わせて 1 MiB まで。
# - --marker-kind: 目印の検査もかける。pr は --title が必須で、入力は「題名、空行、本文」。review-result と escape-issue は本文だけを
#   渡す。目印は個人 project だけに当てる決まりなので、渡すかどうかは呼び出し側が決める。
# - --style-reviewed: 文体の指摘を読んだうえで、そのままにすると決めた印。
#
# 出力 (stdout): 検査ごとに見出しの行を出し、その下に、検査の出力を各行の頭に 2 文字の空白を付けて続ける。最後に判定の行を出す。
#   style: <件数> finding(s) | unavailable
#   marker: ok | <N> error(s) | stop (exit <N>) | stop (signal) | skipped | unavailable
#   gate: ok | warning | stop (exit <N>) | stop (signal) | unavailable
#   post-check: ok | stop (<理由>) | style-findings (<件数> 件。読んで直すか、--style-reviewed を付けてかけ直す)
# 3 つの検査が出す行のほかに、題名や本文を出力に足さない。
#
# exit: 0 = 投稿してよい / 1 = 止める (gate が exit 0 でない・gate の警告・目印が exit 0 でない・検査を使えない) /
#   3 = gate と目印は通っているが、文体の指摘をまだ読んでいない (読んで直すか、--style-reviewed を付けてかけ直す) /
#   2 = usage・入力を読めない・形が外れる・想定外の例外 (stderr に 1 行。stdout は空)。
# exit 3 は、指摘を読む前に投稿しないための区切りで、指摘があっても投稿を止める gate ではない。

require "open3"

# C locale でも外部 encoding を UTF-8 に固定する (#432。配布する script の共通の決まりで、c-locale-test が確かめる)。
# この script 自身は、本文・引数・検査の出力を、どれも byte で読んでから UTF-8 として扱う。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module PostCheck
  NAME = "personal-post-check"
  EXIT_OK = 0
  EXIT_STOP = 1
  EXIT_USAGE = 2
  EXIT_STYLE = 3

  STYLE_NAME = "personal-ja-style-check"
  MARKER_NAME = "personal-work-marker-check"
  GATE_NAME = "personal-public-safety-gate"

  MARKER_KINDS = %w[pr review-result escape-issue].freeze
  MAX_INPUT_BYTES = 1024 * 1024
  STYLE_COUNT = /\Aja-style-check: (?<count>\d+) finding\(s\) in 1 input\(s\)\z/.freeze
  MARKER_ERRORS = /\Awork-marker-check: \S+: (?<count>\d+) error\(s\) \(markers v\d+\)\z/.freeze
  GATE_WARNING = "public-safety-gate: warning:"
  # 止める理由の語と、最後の行に並べる順。
  REASONS = %w[gate gate-warning marker unavailable].freeze

  class UsageError < StandardError; end

  # 1 つの検査の結果。status は見出しに出す語、lines は検査の出力 (そのまま)、reasons は止める理由。
  Result = Struct.new(:status, :lines, :reasons, :findings)

  module_function

  def run(argv)
    opts = parse(argv)
    body = read_body(opts[:body_file])
    title = opts[:title]
    combined = title ? "#{title}\n\n#{body}" : body
    raise UsageError, "題名と本文を合わせて #{MAX_INPUT_BYTES} byte を超える" if combined.bytesize > MAX_INPUT_BYTES

    dir = File.dirname(File.realpath(__FILE__))
    style = check_style(dir, combined)
    marker = check_marker(dir, opts[:marker_kind], opts[:marker_kind] == "pr" ? combined : body)
    gate = check_gate(dir, combined)

    out = []
    { "style" => style, "marker" => marker, "gate" => gate }.each do |label, result|
      out << "#{label}: #{result.status}"
      result.lines.each { |line| out << "  #{line}" }
    end
    reasons = REASONS & (style.reasons + marker.reasons + gate.reasons)
    code, verdict = decide(reasons, style.findings.to_i, opts[:style_reviewed])
    out << "post-check: #{verdict}"
    $stdout.write(out.join("\n") + "\n")
    code
  rescue UsageError => e
    warn "#{NAME}: #{e.message}"
    EXIT_USAGE
  rescue StandardError => e
    # 想定外の例外も exit 2 で返す。内容を含みうる message は出さず、class 名だけを出す。
    warn "#{NAME}: unexpected error (#{e.class})"
    EXIT_USAGE
  end

  # 判定: 止める理由があれば exit 1。無ければ、読んでいない文体の指摘があるときだけ exit 3。
  def decide(reasons, findings, reviewed)
    return [EXIT_STOP, "stop (#{reasons.join(', ')})"] unless reasons.empty?
    if findings.positive? && !reviewed
      return [EXIT_STYLE, "style-findings (#{findings} 件。読んで直すか、--style-reviewed を付けてかけ直す)"]
    end

    [EXIT_OK, "ok"]
  end

  # ---- 入力

  def parse(argv)
    args = argv.map { |arg| arg.dup.force_encoding(Encoding::UTF_8) }
    raise UsageError, "引数を UTF-8 として読めません" unless args.all?(&:valid_encoding?)

    opts = { style_reviewed: false }
    until args.empty?
      name = args.shift
      case name
      when "--style-reviewed"
        raise UsageError, "--style-reviewed が重複しています" if opts[:style_reviewed]

        opts[:style_reviewed] = true
      when "--body-file", "--title", "--marker-kind"
        key = name.delete_prefix("--").tr("-", "_").to_sym
        raise UsageError, "#{name} が重複しています" if opts.key?(key)
        raise UsageError, "#{name} に値がありません" if args.empty?

        opts[key] = args.shift
      else
        raise UsageError, "知らない引数があります"
      end
    end
    raise UsageError, "--body-file が要ります" unless opts.key?(:body_file)

    kind = opts[:marker_kind]
    raise UsageError, "--marker-kind は #{MARKER_KINDS.join(' / ')} のどれか" if kind && !MARKER_KINDS.include?(kind)

    title = opts[:title]
    if title
      raise UsageError, "--title は 1 行で渡す" if title.match?(/[\r\n]/)
      raise UsageError, "--title が空です" if blank?(title)
    end
    raise UsageError, "--marker-kind pr には --title が要ります" if kind == "pr" && title.nil?

    opts
  end

  def read_body(file)
    # regular file だけを読む (FIFO を開くと、書き手を待って止まる)。
    raise UsageError, "--body-file が無いか、regular file ではありません" unless File.file?(file)

    # 長さを指定した binread は、空の file で nil を返す。
    bytes = File.binread(file, MAX_INPUT_BYTES + 1) || String.new
    raise UsageError, "--body-file が #{MAX_INPUT_BYTES} byte を超える" if bytes.bytesize > MAX_INPUT_BYTES

    text = bytes.force_encoding(Encoding::UTF_8)
    raise UsageError, "--body-file を UTF-8 として読めません" unless text.valid_encoding?
    raise UsageError, "--body-file が空です (空白だけ)" if blank?(text)

    text
  rescue SystemCallError => e
    raise UsageError, "--body-file を読めません (#{e.class})"
  end

  # 空か、空白 (全角の空白などを含む) だけか。
  def blank?(text)
    text.match?(/\A[[:space:]]*\z/)
  end

  # ---- 検査

  # 同じ directory の検査を argv で起動する ([path, argv0] の形で渡し、shell を通さない)。file が無い・起動できないときは
  # nil を返す。
  def capture(dir, name, args, input)
    file = File.join(dir, name)
    out, err, status = Open3.capture3([file, file], *args, stdin_data: input, binmode: true)
    [lines_of(out), lines_of(err), status.exitstatus]
  rescue SystemCallError
    nil
  end

  # 検査の出力を行に分ける (そのまま出すので、中身は変えない。UTF-8 として読めない byte は置き換える)。
  def lines_of(text)
    text.force_encoding(Encoding::UTF_8).scrub("?").split(/\r?\n/)
  end

  def unavailable(lines = [])
    Result.new("unavailable", lines, ["unavailable"], nil)
  end

  # 検査の stdout から件数の行を読む。stdout の最後の行で、同じ形の行がほかに無いときだけ読む (途中の行や重複した行から
  # 件数を拾わない。形が外れた出力は、読めないものとして扱う)。
  def count_line(lines, pattern)
    return nil unless lines.count { |line| pattern.match?(line) } == 1

    pattern.match(lines.last)
  end

  # exit 0 以外で終わった検査の見出しの語。signal で終わった検査には exit code が無い。
  def stop_label(status)
    status.nil? ? "stop (signal)" : "stop (exit #{status})"
  end

  # 文体: 指摘だけの検査。exit 0 で、件数の行を決まった形 (count_line) で読めたときだけ使える。
  def check_style(dir, input)
    out, err, status = capture(dir, STYLE_NAME, ["--stdin"], input)
    return unavailable if out.nil?

    count = count_line(out, STYLE_COUNT)
    return unavailable(out + err) unless status == 0 && count

    Result.new("#{count[:count]} finding(s)", out + err, [], count[:count].to_i)
  end

  # 目印: --marker-kind を渡したときだけ。exit 0 以外は止める。
  def check_marker(dir, kind, input)
    return Result.new("skipped", [], [], nil) if kind.nil?

    out, err, status = capture(dir, MARKER_NAME, ["--kind", kind, "--stdin"], input)
    return unavailable if out.nil?
    return Result.new("ok", out + err, [], nil) if status == 0

    count = count_line(out, MARKER_ERRORS)
    label = status == 1 && count ? "#{count[:count]} error(s)" : stop_label(status)
    Result.new(label, out + err, ["marker"], nil)
  end

  # gate: exit 0 で、stderr に警告の行が無いときだけ通る。
  def check_gate(dir, input)
    out, err, status = capture(dir, GATE_NAME, ["--stdin"], input)
    return unavailable if out.nil?

    warned = err.any? { |line| line.start_with?(GATE_WARNING) }
    reasons = []
    reasons << "gate" unless status == 0
    reasons << "gate-warning" if warned
    label = if status != 0 then stop_label(status)
            elsif warned then "warning"
            else "ok"
            end
    Result.new(label, err + out, reasons, nil)
  end
end

exit PostCheck.run(ARGV) if $PROGRAM_NAME == __FILE__
