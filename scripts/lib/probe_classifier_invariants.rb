#!/usr/bin/env ruby
# frozen_string_literal: true

# 分類器の不変条件の試行 (#754) の入口。Spec: docs/classifier-invariants.md。
#
# 挙動の評価の分類器が read と区分した command を、隔離した一時 dir の中で実際に走らせ、不変条件
# (I1: fixture の tree を変えない、I2: canary を走らせない) を確かめる。
# 今ある入口は 2 つ。--preflight は隔離の検査だけをかける。--command は、渡した 1 つの command を分類し、
# read で guard を通れば、preflight の後に走らせて判定する (反例の再現に使う)。
#
# 責務の境界:
#   - 分類は別の process で行う (分類器の file を取り替えて調べるため。同じ process では定数が衝突する)。
#   - 走らせるのは isolation.rb、判定は judge.rb。ここは、引数、順序、結果の file、exit code を持つ。
#   - preflight が通らないとき、sandbox を適用できないときは、command を走らせない (素の実行には戻らない)。
#   - 全体の memory と時間の上限は、呼ぶ側が personal-safe-run で付ける。ここでは包まない。
#   - 結果の file と stderr には、一時 dir と HOME の絶対 path を出さない (置き換えて出す)。
#
# 値は shell の文字列に埋め込まず、argv の配列と stdin で渡す。

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require_relative "probe_child"
require_relative "probe_classifier/isolation"
require_relative "probe_classifier/judge"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
# この entrypoint は cli.rb (#418 の固定) を require しないので、同じ固定を各自で持つ。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ProbeClassifierInvariants
  # 使い方の誤りと、走らせる前に止める理由 (exit 2)。
  class Error < StandardError; end

  Isolation = ProbeClassifier::Isolation
  Judge = ProbeClassifier::Judge

  DEFAULT_CLASSIFIER = File.join(__dir__, "skill_behavior_classifier.rb")
  # 分類器が返してよい区分 (SkillBehaviorClassifier::SEVERITY の key)。ほかの値は、分類の失敗として扱う。
  CLASSES = %w[read exec unknown file-write git-write github-write agent-launch].freeze
  CLASSIFY_TIMEOUT = 60
  # 分類だけを行う子の program。分類器の file と command は、stdin の JSON で受ける。
  CLASSIFY_PROGRAM = <<~'RUBY'
    require "json"
    input = JSON.parse($stdin.binmode.read.force_encoding(Encoding::UTF_8))
    load input.fetch("file")
    klass = SkillBehaviorClassifier.classify_shell(input.fetch("command"))
    $stdout.write(JSON.generate("version" => SkillBehaviorClassifier::VERSION, "class" => klass))
  RUBY
  # 生成の入口の引数。生成器と一緒に足すので、今は受けない。
  LATER_OPTIONS = %w[--seed --count --run --baseline --mutation].freeze

  USAGE = <<~TEXT
    usage: probe-classifier-invariants.sh --preflight [--out DIR]
           probe-classifier-invariants.sh --out DIR --command STRING [--variant NAME] [--classifier FILE]

      --preflight   隔離の検査だけをかける (否定の検査と、相手を許した対照の組)
      --command     1 つの command を分類し、read で guard を通れば、隔離の中で走らせて判定する
      --variant     走らせる shell の変種 (既定: #{Isolation::DEFAULT_VARIANT})。#{Isolation::VARIANTS.map(&:name).join(' ')}
      --classifier  調べる分類器の file (既定: この repo の scripts/lib/skill_behavior_classifier.rb)
      --out         results.json を書く dir。git の worktree の外で、無いか空の dir

    exit: 0 = 確かめた反例なし (read でないので走らせなかったときも), 1 = 既定の変種で確かめた反例あり,
          2 = 使い方の誤り・guard の拒否・preflight の失敗・中断, 3 = 人に出すものだけがある
  TEXT

  # --- 引数 -------------------------------------------------------------------------------
  def self.parse_argv(argv)
    opts = {}
    i = 0
    while i < argv.length
      key = argv[i]
      case key
      when "--out", "--variant", "--classifier"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

        opts[key.delete_prefix("--").to_sym] = value
        i += 2
      when "--command"
        # command は - で始まってもよい (中身は見ずに、次の語をそのまま受ける)。
        raise Error, "--command requires a value" if argv[i + 1].nil?

        opts[:command] = argv[i + 1]
        i += 2
      when "--preflight"
        opts[:preflight] = true
        i += 1
      when *LATER_OPTIONS
        raise Error, "#{key} is not available yet (it comes with the generator)"
      else
        raise Error, "unknown argument"
      end
    end
    validate!(opts)
    opts
  end

  def self.validate!(opts)
    if opts[:preflight]
      extra = %i[command variant classifier].select { |k| opts.key?(k) }
      raise Error, "--preflight takes only --out (got --#{extra.first})" unless extra.empty?
      return
    end
    raise Error, "--preflight or --command is required" unless opts.key?(:command)
    raise Error, "--command requires --out" unless opts[:out]
    # argv の文字列は locale の encoding で届く (C locale では US-ASCII)。UTF-8 として持ち直す。
    opts[:command] = opts[:command].dup.force_encoding(Encoding::UTF_8)
    raise Error, "--command is not valid UTF-8" unless opts[:command].valid_encoding?

    opts[:variant] ||= Isolation::DEFAULT_VARIANT
    raise Error, "--variant must be one of #{Isolation::VARIANTS.map(&:name).join(', ')}" unless Isolation.variant(opts[:variant])
  end

  # --out は git の worktree と .git の外で、無いか空の dir に限る (結果を tracked にしないため)。
  # probe-opencode-plugin.sh と同じ決まり。git の探索は親の env (GIT_CEILING_DIRECTORIES や GIT_DIR) で結果が
  # 変わるので使わず、symlink を解決した path について、祖先に .git があるかを filesystem で見る。
  def self.check_out!(out)
    path = File.expand_path(out)
    raise Error, "--out is not a directory" if File.exist?(path) && !File.directory?(path)
    raise Error, "--out must be empty or absent" if File.directory?(path) && !Dir.empty?(path)

    existing = path
    existing = File.dirname(existing) until File.exist?(existing)
    dir = File.join(File.realpath(existing), path[existing.length..-1])
    loop do
      raise Error, "--out must be outside a git worktree" if File.basename(dir) == ".git" || File.exist?(File.join(dir, ".git"))

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    path
  end

  # --- 出力 -------------------------------------------------------------------------------
  # 一時 dir と HOME の絶対 path を置き換える。session が無い間 (走らせる前) は、HOME だけを置き換える。
  def self.redact(text, session = nil)
    return session.redact(text) if session

    out = text.to_s.b
    homes = (Isolation.real_homes + [ENV["HOME"].to_s]).reject(&:empty?).uniq
    homes.sort_by { |h| -h.length }.each { |h| out = out.gsub(h.b) { "<HOME>" } }
    out.force_encoding(Encoding::UTF_8).scrub("?")
  end

  def self.deep_redact(value, session)
    case value
    when String then redact(value, session)
    when Array then value.map { |v| deep_redact(v, session) }
    when Hash then value.map { |k, v| [k, deep_redact(v, session)] }.to_h
    else value
    end
  end

  def self.one_line(text)
    text.to_s.gsub(/\s*\n\s*/, " ").strip
  end

  def self.write_results(out, data, session = nil)
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "results.json"), JSON.pretty_generate(deep_redact(data, session)) + "\n")
  end

  # --- 分類 (別の process) ------------------------------------------------------------------
  # 戻り値は { "version" => 整数, "class" => 区分, "sha256" => file の SHA-256 }。
  # 子が失敗したとき、版や区分が読めないときは Error (分類できなかった command を「read でない」と数えない)。
  def self.classify(file, command)
    path = File.expand_path(file)
    raise Error, "--classifier is not a readable file" unless File.file?(path) && File.readable?(path)

    real = File.realpath(path)
    # 分類に使う前の中身で取る (結果に残す版と hash が、分類した file を指すように)。
    sha256 = Digest::SHA256.file(real).hexdigest
    input = JSON.generate("file" => real, "command" => command)
    result = ProbeChild.run([RbConfig.ruby, "-e", CLASSIFY_PROGRAM], env: { "LC_ALL" => "C" }, chdir: "/",
                                                                     timeout: CLASSIFY_TIMEOUT, stdin: input,
                                                                     unsetenv_others: true)
    unless result.completed && result.status&.success?
      # 子の stderr の先頭だけを出す (端末でないとき、Ruby は例外の文言を先頭に出す)。分類器の file の場所は、
      # 置き換えてから出す。
      head = result.err.to_s.scrub("?").lines.first(2).join
      [real, path].uniq.each { |p| head = head.gsub(p) { "<classifier>" } }
      raise Error, "the classifier could not be run (exit #{result.status&.exitstatus.inspect}): #{one_line(head)}"
    end

    info = JSON.parse(result.out)
    unless info.is_a?(Hash) && info["version"].is_a?(Integer) && CLASSES.include?(info["class"])
      raise Error, "the classifier returned an unexpected result"
    end
    info.merge("sha256" => sha256)
  rescue JSON::ParserError
    raise Error, "the classifier returned an unexpected result"
  end

  # --- 入口 -------------------------------------------------------------------------------
  def self.preflight_data(pre)
    { "ok" => pre.ok, "unavailable" => pre.unavailable, "checks" => pre.checks.map { |c| { "name" => c.name, "ok" => c.ok } },
      "reasons" => pre.reasons }
  end

  def self.preflight_failure(pre, session)
    head = pre.unavailable ? "sandbox-exec cannot be applied here" : "the isolation preflight failed"
    one_line(redact("#{head}: #{pre.reasons.join('; ')}", session))
  end

  # 隔離の session を開いて block に渡し、終わりに必ず閉じる (一時 dir を残さない)。
  # 途中の SystemCallError の文言は一時 dir の path を含みうるので、置き換えてから Error にする。
  def self.with_session
    session = Isolation::Session.open
    yield session
  rescue SystemCallError => e
    raise Error, one_line(redact("#{e.class}: #{e.message}", session))
  ensure
    session&.close
  end

  def self.run_preflight(out)
    with_session do |session|
      pre = Isolation.preflight(session)
      write_results(out, { "mode" => "preflight", "preflight" => preflight_data(pre) }, session) if out
      raise Error, preflight_failure(pre, session) unless pre.ok

      puts "preflight: ok (#{pre.checks.length} checks)"
      0
    end
  end

  def self.command_data(opts, info, executed:)
    { "mode" => "command", "variant" => opts[:variant], "command" => opts[:command],
      "classifier" => { "version" => info["version"], "sha256" => info["sha256"] },
      "counts" => { "generated" => 1, "by_class" => { info["class"] => 1 }, "executed" => executed, "unmeasured" => 0 },
      "violations" => [], "human" => [], "runs" => [] }
  end

  # 結果の行に、command と変種を足す (先頭の key は invariant か reason のまま)。
  def self.with_command(items, opts)
    items.map do |item|
      key, value = item.first
      { key => value, "command" => opts[:command], "variant" => opts[:variant] }.merge(item)
    end
  end

  def self.run_command(opts, out)
    info = classify(opts[:classifier] || DEFAULT_CLASSIFIER, opts[:command])
    unless info["class"] == "read"
      write_results(out, command_data(opts, info, executed: 0))
      puts "command: class=#{info['class']} (not read; not run)"
      return 0
    end
    reason = Isolation.guard(opts[:command])
    raise Error, "the guard rejected the command (#{reason}); it was not run" if reason

    with_session do |session|
      pre = Isolation.preflight(session)
      raise Error, preflight_failure(pre, session) unless pre.ok

      variant = Isolation.variant(opts[:variant])
      outcome = Judge.examine(variant, ->(name) { Judge.observe(session, opts[:command], variant: name) })
      data = command_data(opts, info, executed: 1)
      data["counts"]["unmeasured"] = outcome.unmeasured ? 1 : 0
      data["violations"] = with_command(outcome.violations, opts)
      data["human"] = with_command(outcome.human, opts)
      data["runs"] = outcome.runs
      write_results(out, data, session)
      report(data, session)
      Judge.exit_code(outcome)
    end
  end

  def self.report(data, session)
    puts "command: class=read variant=#{data['variant']} runs=#{data['runs'].length} " \
         "violations=#{data['violations'].length} human=#{data['human'].length}"
    data["violations"].each { |v| puts redact("  #{v['invariant']} #{v['kinds'].join(',')} #{v['paths'].join(' ')}", session) }
    data["human"].each do |h|
      detail = (h["paths"] || h["names"] || h["why"] || []).join(" ")
      puts redact("  human #{h['reason']} #{detail}".rstrip, session)
    end
  end

  def self.main(argv)
    $stdout.sync = true
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
    # 出力先の検査は、何かを走らせる前に行う。
    out = opts[:out] && check_out!(opts[:out])
    opts[:preflight] ? run_preflight(out) : run_command(opts, out)
  rescue Error, ProbeClassifier::Error => e
    warn "error: #{one_line(redact(e.message))}"
    warn USAGE if e.message.match?(/\A(--|unknown argument)/)
    2
  rescue SystemCallError => e
    # 例外の文言は path を含むので、置き換えてから出す。
    warn "error: #{one_line(redact(e.message))}"
    2
  rescue Interrupt
    warn "error: interrupted"
    2
  end
end

if $PROGRAM_NAME == __FILE__
  exit ProbeClassifierInvariants.main(ARGV)
end
