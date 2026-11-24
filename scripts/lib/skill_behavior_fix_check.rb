# frozen_string_literal: true

# skill の挙動の評価 (#369) で、直す case の修正が正しいかを測る (#763)。Spec: docs/skill-behavior-eval.md の「修正の正しさ」。
#
# run の後の project の file を読み、case の fix_check の例の引数で関数を呼び、戻り値を例の値と比べる。
# - 読む code は agent が書いたもの。必ず sandbox-exec の中で走らせる。適用できなければ走らせない (unmeasured)。
# - 期待する値は子に渡さない。照合は親で行う。子の出力や exit code を書き換えても、正しい値を返さない限り passed にならない。
# - この file は #754 の隔離 (probe_classifier/) を使わない。あちらは、まとめて外しても挙動が変わらない約束のため。

require "etc"
require "json"
require "rbconfig"
require_relative "probe_child"
require_relative "skill_behavior_cases"

module SkillBehaviorFixCheck
  C = SkillBehaviorCases
  SANDBOX_EXEC = "/usr/bin/sandbox-exec"
  TIMEOUT = 10
  # 子に渡す環境。これだけを渡す (親の環境は渡さない)。
  CHILD_ENV = { "PATH" => "/usr/bin:/bin", "LC_ALL" => "en_US.UTF-8" }.freeze

  # status と reason は C::FIX_STATUSES の語彙。passed は合った例の数 (unmeasured では nil)。raw は raw log に残す出力。
  Outcome = Struct.new(:status, :reason, :passed, :total, :raw, keyword_init: true) do
    def to_h_for_results
      { "status" => status, "reason" => reason, "passed" => passed, "total" => total }
    end

    def label
      "#{status}/#{reason}#{passed.nil? ? '' : " (#{passed}/#{total})"}"
    end
  end

  # 子から回収する出力の上限 (stdout と stderr のそれぞれ)。結果は 1 KB に満たない。
  MAX_OUTPUT = 65_536

  # 子の中の code。引数は ARGV[0] の JSON (file と calls)。結果は取り置いた口に 2 行で書く。
  # 1 行目の ready は、起動できたことの印。2 行目は、読み込みの失敗の印か、例ごとの値の配列。
  # 読む code の出力は /dev/null に捨てる。code が process を終えたら (exit・signal)、2 行目は出ない。
  # 読んだ後に、code が書き換えられる部品をなるべく使わない。関数は、名前を書いた呼び出しで呼ぶ (send を通すと、send の
  # 再定義で、直っていない関数が合って見える)。引数の JSON は、読む前に ARGV から消す。書き出しの method は、読む前に取り置く。
  def self.driver(function)
    raise ArgumentError, "unexpected function name" unless function.match?(C::FIX_FUNCTION)

    <<~RUBY
      require "json"
      spec = JSON.parse(ARGV.fetch(0))
      ARGV.clear
      dump = JSON.method(:generate)
      out = STDOUT.dup
      out.sync = true
      null = File.open(File::NULL, "r+")
      [STDIN, STDOUT, STDERR].each { |io| io.reopen(null) }
      out.puts("ready")
      begin
        load(File.expand_path(spec["file"]))
      rescue SystemExit, SignalException
        exit!(1)
      rescue Exception
        out.puts("load-error")
        exit!(0)
      end
      values = spec["calls"].map do |args|
        begin
          value = #{function}(*args)
          case value
          when Integer then value.bit_length <= 64 ? value : nil
          when Float then value.finite? ? value : nil
          when Rational then value.to_f
          end
        rescue SystemExit, SignalException
          exit!(1)
        rescue Exception
          nil
        end
      end
      out.puts(dump.call(values))
      exit!(0)
    RUBY
  end

  def self.ruby
    File.realpath(RbConfig.ruby)
  end

  def self.quote(path)
    raise ArgumentError, "path cannot be written in a sandbox profile" if path.match?(/["\\\n]/)

    "\"#{path}\""
  end

  # 読み取りを拒む dir (HOME)。環境の HOME と、account の HOME の両方。
  def self.home_dirs
    [ENV["HOME"], Etc.getpwuid&.dir].compact.map { |p| File.realpath(p) if File.directory?(p) }.compact.uniq - ["/"]
  end

  def self.ancestors(path)
    dirs = []
    dirs << (path = File.dirname(path)) until path == "/"
    dirs
  end

  # 後ろの規則が前の規則に勝つ。書けるのは /dev/null だけ。起動できる program は、この ruby だけで、fork はできない。
  def self.profile(proj)
    readable = [File.realpath(proj), File.realpath(RbConfig::CONFIG.fetch("prefix"))]
    homes = home_dirs
    lines = ["(version 1)", "(allow default)", "(deny network*)", '(deny file-write* (subpath "/"))',
             '(allow file-write* (literal "/dev/null"))']
    lines << "(deny file-read* #{homes.map { |d| "(subpath #{quote(d)})" }.join(' ')})" unless homes.empty?
    lines << "(allow file-read* #{readable.map { |d| "(subpath #{quote(d)})" }.join(' ')})"
    # 読める dir が HOME の下にあると、load と require が path を解決できない。親の dir は、情報 (stat) だけを許す。
    above = readable.flat_map { |d| ancestors(d) }.uniq
    lines << "(allow file-read-metadata #{above.map { |d| "(literal #{quote(d)})" }.join(' ')})"
    lines.push("(deny process-exec*)", "(allow process-exec* (literal #{quote(ruby)}))", "(deny process-fork)",
               "(deny signal)", "(allow signal (target self))", "(deny mach-lookup)", "(deny appleevent-send)",
               "(deny job-creation)")
    lines.join("\n")
  end

  # proj (run の後の project) の spec の file を検査する。spec は case の fix_check。
  def self.run(proj, spec, timeout: TIMEOUT, sandbox: SANDBOX_EXEC)
    total = spec["examples"].length
    payload = JSON.generate("file" => spec["file"], "calls" => spec["examples"].map { |e| e["args"] })
    argv = [sandbox, "-p", profile(proj), ruby, "--disable=gems", "-e", driver(spec["function"]), payload]
    result = ProbeChild.run(argv, env: CHILD_ENV, chdir: proj, timeout: timeout, unsetenv_others: true, max_bytes: MAX_OUTPUT)
    status, reason, passed = decide(result, spec)
    Outcome.new(status: status, reason: reason, passed: passed, total: total,
                raw: "#{result.out.b}\n--- stderr\n#{result.err.b}\n")
  rescue SystemCallError, ArgumentError => e
    # sandbox-exec を起動できない (無い、profile に書けない path、など)。code は走っていない。
    Outcome.new(status: "unmeasured", reason: "sandbox", passed: nil, total: spec["examples"].length,
                raw: "could not start: #{e.class}\n")
  end

  def self.decide(result, spec)
    text = result.out.b
    ready = text.start_with?("ready\n")
    return ["unmeasured", "timeout", nil] unless result.completed
    # sandbox-exec 自体の失敗は、driver が始まる前に、0 でない終了 code と、決まった字面で終わる。
    if !ready && result.status && !result.status.success? && result.err.b.match?(/^sandbox-exec: /n)
      return ["unmeasured", "sandbox", nil]
    end
    return ["unmeasured", "launch", nil] unless ready
    return ["unmeasured", "signal", nil] if result.status.nil? || result.status.signaled?
    # 上限を越えた出力は、途中で切れているので、どの形も受けない。
    return ["failed", "no-result", 0] if result.truncated
    return ["failed", "load-error", 0] if text == "ready\nload-error\n"

    # ちょうど 2 行の形だけを受ける。
    line = text[/\Aready\n([^\n]*)\n\z/n, 1]
    values = line.nil? ? nil : parse_values(line, spec["examples"].length)
    return ["failed", "no-result", 0] if values.nil?

    passed = spec["examples"].zip(values).count { |e, v| v == e["returns"] }
    passed == values.length ? ["passed", "ok", passed] : ["failed", "wrong", passed]
  end

  def self.parse_values(line, length)
    values = JSON.parse(line.dup.force_encoding(Encoding::UTF_8))
    values.is_a?(Array) && values.length == length ? values : nil
  rescue JSON::ParserError, EncodingError
    nil
  end

  # 手を付けていない fixture を、検査が「合わない」と見分け、合う例も 1 つはあるか (検査が動く証拠)。
  def self.detects_untouched?(outcome)
    outcome.status == "failed" && outcome.reason == "wrong" && outcome.passed.positive?
  end
end
