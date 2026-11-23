#!/usr/bin/env ruby
# frozen_string_literal: true

# 分類器の不変条件の試行 (#754) の入口。Spec: docs/classifier-invariants.md。
#
# 挙動の評価の分類器が read と区分した command を、隔離した一時 dir の中で実際に走らせ、不変条件
# (I1: fixture の tree を変えない、I2: canary を走らせない) を確かめる。
# 入口は 3 つ。--preflight は隔離の検査だけをかける。--command は、渡した 1 つの command を分類し、
# read で guard を通れば、preflight の後に走らせて判定する (反例の再現に使う)。
# どちらも無ければ生成の入口で、seed と件数から command の列を作って分類する。--run を付けたときだけ、
# 走らせる対象の command を隔離の中で走らせる。付けなければ dry-run で、何も走らせない。
#
# 責務の境界:
#   - 分類は別の process で行う (分類器の file を取り替えて調べるため。同じ process では定数が衝突する)。
#     分類器の file ごとに 1 つの子で、全件を分類する。
#   - 列を作るのは generator.rb、変異の表は mutations.rb、走らせるのは isolation.rb、判定は judge.rb。
#     ここは、引数、順序、走らせる対象の選び方、結果の file、exit code を持つ。
#   - command を走らせる道は Judge.observe だけ (guard と profile の両方がかかる)。ここから sh や system には渡さない。
#   - preflight が通らないとき、sandbox を適用できないときは、command を走らせない (素の実行には戻らない)。
#   - 全体の memory と時間の上限は、呼ぶ側が personal-safe-run で付ける。ここでは包まない。
#   - 結果の file と stderr には、一時 dir と HOME の絶対 path を出さない (置き換えて出す)。
#     --out の dir と分類器の file の場所も出さない。
#
# 値は shell の文字列に埋め込まず、argv の配列と stdin で渡す。

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"
require_relative "probe_child"
require_relative "probe_classifier/isolation"
require_relative "probe_classifier/judge"
require_relative "probe_classifier/generator"
require_relative "probe_classifier/mutations"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
# この entrypoint は cli.rb (#418 の固定) を require しないので、同じ固定を各自で持つ。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ProbeClassifierInvariants
  # 使い方の誤りと、走らせる前に止める理由 (exit 2)。
  class Error < StandardError; end

  Isolation = ProbeClassifier::Isolation
  Judge = ProbeClassifier::Judge
  Generator = ProbeClassifier::Generator
  Mutations = ProbeClassifier::Mutations

  DEFAULT_CLASSIFIER = File.join(__dir__, "skill_behavior_classifier.rb")
  # 分類器が返してよい区分 (SkillBehaviorClassifier::SEVERITY の key)。ほかの値は、分類の失敗として扱う。
  CLASSES = %w[read exec unknown file-write git-write github-write agent-launch].freeze
  CLASSIFY_TIMEOUT = 60
  # 分類だけを行う子の program。分類器の file と command の並びは、stdin の JSON で受ける。
  # coverage を頼まれたら、分類器の file の行ごとの実行の回数を、標準の Coverage で取る。
  #   lines: 実行できる行。load: 読み込みで通った行。all: 分類で通った行 (読み込みの後に回数が増えた行)。
  #   read:  read と区分した command の分類で通った行。
  # 分類の途中の例外は、番号と例外の class の名前だけを返す (文言は path を含みうるので写さない)。
  CLASSIFY_PROGRAM = <<~'RUBY'
    require "json"
    input = JSON.parse($stdin.binmode.read.force_encoding(Encoding::UTF_8))
    file = input.fetch("file")
    if input["coverage"]
      require "coverage"
      Coverage.start
    end
    load file
    peek = -> { Coverage.peek_result[file] }
    base = input["coverage"] ? peek.call : nil
    prev = base
    read_hit = base && Array.new(base.length, false)
    classes = []
    failed = nil
    input.fetch("commands").each_with_index do |command, index|
      begin
        klass = SkillBehaviorClassifier.classify_shell(command)
      rescue StandardError => e
        failed = { "index" => index, "error" => e.class.name.to_s }
        break
      end
      classes << klass
      next unless base

      snap = peek.call
      snap.each_index { |k| read_hit[k] = true if snap[k] && snap[k] > prev[k] } if klass == "read"
      prev = snap
    end
    coverage = nil
    if base && failed.nil?
      coverage = { "lines" => base.count { |n| !n.nil? }, "load" => base.count { |n| n && n > 0 },
                   "all" => prev.each_index.count { |k| prev[k] && prev[k] > base[k] }, "read" => read_hit.count(true) }
    end
    $stdout.write(JSON.generate("version" => SkillBehaviorClassifier::VERSION, "classes" => classes, "failed" => failed,
                                "coverage" => coverage))
  RUBY

  DEFAULT_SEED = 754
  MAX_SEED = 999_999_999
  # 生成の件数。既定は、全部の cell (101 個) が 1 回以上出る小さい数。上限は、試行の 1 回 (2000 件) より上に取る。
  DEFAULT_COUNT = 200
  MAX_COUNT = 5000
  # 入口ごとに受ける引数。
  MODE_OPTIONS = {
    preflight: %i[preflight out],
    command: %i[command out variant classifier mutation],
    generate: %i[out seed count variant classifier baseline mutation run],
  }.freeze
  # 変異した分類器の file の名前 (一時 dir の中)。
  MUTATED_NAME = "mutated_classifier.rb"
  # stdout の報告に出す束の数の上限 (反例と、人に出すもののそれぞれ)。残りは results.json にある。
  REPORT_GROUPS = 30
  # 走らせている間に stderr へ出す途中経過の行の数の目安。
  PROGRESS_LINES = 10
  # 束ねるときに比べる key (番号と command のほか。同じ形の行を 1 つにまとめる)。
  GROUP_KEYS = %w[invariant reason variant cell kinds zone paths names why].freeze

  USAGE = <<~TEXT
    usage: probe-classifier-invariants.sh --preflight [--out DIR]
           probe-classifier-invariants.sh --out DIR --command STRING [--variant NAME] [--classifier FILE] [--mutation NAME]
           probe-classifier-invariants.sh --out DIR [--seed N] [--count N] [--variant NAME] [--classifier FILE]
                                          [--baseline FILE | --mutation NAME] [--run]

      --preflight   隔離の検査だけをかける (否定の検査と、相手を許した対照の組)
      --command     1 つの command を分類し、read で guard を通れば、隔離の中で走らせて判定する
      --seed        生成の seed (既定: #{DEFAULT_SEED}。0 から #{MAX_SEED} の整数)
      --count       生成する command の件数 (既定: #{DEFAULT_COUNT}。1 から #{MAX_COUNT} の整数)
      --run         走らせる対象の command を、preflight の後に隔離の中で走らせる (無ければ dry-run で、何も走らせない)
      --variant     走らせる shell の変種 (既定: #{Isolation::DEFAULT_VARIANT})。#{Isolation::VARIANTS.map(&:name).join(' ')}
      --classifier  調べる分類器の file (既定: この repo の scripts/lib/skill_behavior_classifier.rb)
      --baseline    比べる相手の分類器の file。調べる分類器が read で、相手が read でない command だけを走らせる
      --mutation    調べる分類器の source に変異を 1 つ当てた版を調べる。比べる相手は、当てる前の版
                    #{Mutations.names.each_slice(6).map { |names| names.join(' ') }.join("\n                ")}
      --out         results.json (生成の入口では corpus.jsonl も) を書く dir。git の worktree の外で、無いか空の dir

    exit: 0 = 確かめた反例なし (read でないので走らせなかったとき、dry-run で人に出すものが無いときも),
          1 = 既定の変種で確かめた反例あり,
          2 = 使い方の誤り・guard の拒否 (--command)・分類の失敗・当たらない変異・preflight の失敗・中断・想定外の失敗,
          3 = 人に出すものだけがある (未測定、期限で止めた回、guard が拒んだ生成の command を含む)
  TEXT

  # --- 引数 -------------------------------------------------------------------------------
  def self.parse_argv(argv)
    opts = {}
    i = 0
    while i < argv.length
      key = argv[i]
      case key
      when "--out", "--variant", "--classifier", "--baseline", "--mutation"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

        opts[key.delete_prefix("--").to_sym] = value
        i += 2
      when "--command", "--seed", "--count"
        # 次の語を、- で始まっていても、そのまま受ける (command の中身は見ない。数の検査は validate! で行う)。
        raise Error, "#{key} requires a value" if argv[i + 1].nil?

        opts[key.delete_prefix("--").to_sym] = argv[i + 1]
        i += 2
      when "--preflight", "--run"
        opts[key.delete_prefix("--").to_sym] = true
        i += 1
      else
        raise Error, "unknown argument"
      end
    end
    validate!(opts)
    opts
  end

  def self.mode(opts)
    return :preflight if opts[:preflight]

    opts.key?(:command) ? :command : :generate
  end

  def self.validate!(opts)
    mode = mode(opts)
    extra = opts.keys - MODE_OPTIONS.fetch(mode)
    raise Error, "--preflight takes only --out (got --#{extra.first})" if mode == :preflight && !extra.empty?
    raise Error, "--command cannot be combined with --#{extra.first}" unless extra.empty?
    return if mode == :preflight

    raise Error, mode == :command ? "--command requires --out" : "--out is required (or --preflight)" unless opts[:out]

    if mode == :command
      # argv の文字列は locale の encoding で届く (C locale では US-ASCII)。UTF-8 として持ち直す。
      opts[:command] = opts[:command].dup.force_encoding(Encoding::UTF_8)
      raise Error, "--command is not valid UTF-8" unless opts[:command].valid_encoding?
    else
      raise Error, "--baseline and --mutation cannot be combined" if opts[:baseline] && opts[:mutation]

      opts[:seed] = number("--seed", opts[:seed], DEFAULT_SEED, 0..MAX_SEED)
      opts[:count] = number("--count", opts[:count], DEFAULT_COUNT, 1..MAX_COUNT)
    end
    opts[:variant] ||= Isolation::DEFAULT_VARIANT
    raise Error, "--variant must be one of #{Isolation::VARIANTS.map(&:name).join(', ')}" unless Isolation.variant(opts[:variant])

    # 知らない名前は、何かを読む前に止める (文言は、渡された名前を写さない)。
    Mutations.fetch(opts[:mutation]) if opts[:mutation]
  end

  # 数の引数。数字だけの 10 進の整数で、範囲の中に限る (符号、空白、小数、範囲の外は使い方の誤り)。
  # 結果の file に写す値なので、自由な文字列は受けない。
  def self.number(option, value, default, range)
    return default if value.nil?
    # argv の文字列は壊れた byte を含みうるので、byte の並びとして照合する。
    unless value.b.match?(/\A[0-9]{1,9}\z/) && range.cover?(value.to_i)
      raise Error, "#{option} must be an integer from #{range.min} to #{range.max}"
    end

    value.to_i
  end

  # 引数の path を絶対 path にする。File.expand_path は、居ない user の ~name で ArgumentError を上げる。
  # 使い方の誤りとして返す (受けないと、Ruby の既定の終了が「反例あり」と同じ exit 1 になる)。
  def self.expand_path(option, value)
    File.expand_path(value)
  rescue ArgumentError
    raise Error, "#{option} is not a usable path"
  end

  # dir か、その祖先が git の worktree (か .git の中) か。git の探索は親の env (GIT_CEILING_DIRECTORIES や GIT_DIR) で
  # 結果が変わるので使わず、祖先に .git があるかを filesystem で見る。dir は symlink を解決した path で渡す。
  def self.inside_worktree?(dir)
    loop do
      return true if File.basename(dir) == ".git" || File.exist?(File.join(dir, ".git"))

      parent = File.dirname(dir)
      return false if parent == dir

      dir = parent
    end
  end

  # --out は git の worktree と .git の外で、無いか空の dir に限る (結果を tracked にしないため)。
  # probe-opencode-plugin.sh と同じ決まり。
  def self.check_out!(out)
    path = expand_path("--out", out)
    raise Error, "--out is not a directory" if File.exist?(path) && !File.directory?(path)
    raise Error, "--out must be empty or absent" if File.directory?(path) && !Dir.empty?(path)

    existing = path
    existing = File.dirname(existing) until File.exist?(existing)
    raise Error, "--out must be outside a git worktree" if inside_worktree?(File.join(File.realpath(existing), path[existing.length..-1]))

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

  # 生成した列と、調べる分類器の区分。1 行 1 件で、key は index、command、cell、class の順。
  # 同じ seed、件数、分類器なら、dry-run でも run でも、byte まで同じ file になる (path の置き換えは通さない。
  # 生成した command は、絶対 path を /dev/null のほかに持たない)。
  def self.write_corpus(out, batch)
    FileUtils.mkdir_p(out)
    lines = batch.rows.map { |row| "#{JSON.generate(row.record.merge('class' => batch.classes[row.index]))}\n" }
    File.write(File.join(out, "corpus.jsonl"), lines.join)
  end

  # --- 分類 (別の process) ------------------------------------------------------------------
  # 分類器の file。path は渡された形を絶対 path にしたもの、real は実体。sha256 は、分類に使う前の中身で取る
  # (結果に残す hash が、分類した file を指すように)。
  Source = Struct.new(:path, :real, :sha256, keyword_init: true)

  def self.source(option, file)
    path = expand_path(option, file)
    raise Error, "#{option} is not a readable file" unless File.file?(path) && File.readable?(path)

    real = File.realpath(path)
    Source.new(path: path, real: real, sha256: Digest::SHA256.file(real).hexdigest)
  end

  # commands の全件を、1 つの子で分類する。戻り値は { "version" => 整数, "classes" => 区分の並び,
  # "coverage" => 行の数 (頼まないとき、取れなかったときは nil) }。
  # 子が失敗したとき、版や区分が読めないとき、件数が合わないときは Error
  # (分類できなかった command を「read でない」と数えない)。
  def self.classify_all(source, commands, coverage: false)
    input = JSON.generate("file" => source.real, "commands" => commands, "coverage" => coverage)
    result = ProbeChild.run([RbConfig.ruby, "-e", CLASSIFY_PROGRAM], env: { "LC_ALL" => "C" }, chdir: "/",
                                                                     timeout: CLASSIFY_TIMEOUT, stdin: input,
                                                                     unsetenv_others: true)
    unless result.completed && result.status&.success?
      # 子の stderr の先頭だけを出す (端末でないとき、Ruby は例外の文言を先頭に出す)。分類器の file と、その dir
      # (require_relative の失敗の文言に出る) の場所は、置き換えてから出す。
      head = result.err.to_s.scrub("?").lines.first(2).join
      places = [source.real, source.path].uniq
      places.each { |p| head = head.gsub(p) { "<classifier>" } }
      places.map { |p| File.dirname(p) }.uniq.each { |d| head = head.gsub(d) { "<classifier-dir>" } unless d == "/" }
      raise Error, "the classifier could not be run (exit #{result.status&.exitstatus.inspect}): #{one_line(head)}"
    end

    info = JSON.parse(result.out)
    unless info.is_a?(Hash) && info["version"].is_a?(Integer) && info["classes"].is_a?(Array)
      raise Error, "the classifier returned an unexpected result"
    end
    if info["failed"].is_a?(Hash)
      name = info["failed"]["error"].to_s
      name = "an exception" unless name.match?(/\A[A-Za-z][A-Za-z0-9_:]{0,80}\z/)
      raise Error, "the classifier raised #{name} on row #{info['failed']['index'].to_i}"
    end
    unless info["classes"].length == commands.length && info["classes"].all? { |c| CLASSES.include?(c) }
      raise Error, "the classifier returned an unexpected result"
    end
    info
  rescue JSON::ParserError
    raise Error, "the classifier returned an unexpected result"
  end

  # --- 調べる版と、比べる相手 ---------------------------------------------------------------------
  # subject は調べる版、partner は比べる相手 (無ければ nil)。record は、結果の classifier に hash を残す file
  # (--mutation のときは、変異を当てる前の file。変異した版は、名前と mutated_sha256 で残す)。
  Setup = Struct.new(:subject, :partner, :record, :baseline, :mutation, keyword_init: true)

  # 分類器の file を確かめ、変異を当てるなら当てた版を一時 dir に書いて、block に Setup を渡す。
  def self.with_setup(opts)
    given = source("--classifier", opts[:classifier] || DEFAULT_CLASSIFIER)
    unless opts[:mutation]
      baseline = opts[:baseline] && source("--baseline", opts[:baseline])
      return yield(Setup.new(subject: given, partner: baseline, record: given, baseline: baseline))
    end

    with_mutated(given, opts[:mutation]) do |mutated|
      yield Setup.new(subject: mutated, partner: given, record: given, mutation: opts[:mutation])
    end
  end

  # 変異を当てた版を、worktree の外の一時 dir に書いて block に渡し、終わりに消す。
  # 変異が当たらない source (置き換える文字列が 1 回だけ出る形でない) は Mutations::Error で、何も書かない。
  def self.with_mutated(given, name)
    text = File.binread(given.real).force_encoding(Encoding::UTF_8)
    raise Error, "--classifier is not valid UTF-8" unless text.valid_encoding?

    mutated = Mutations.apply(text, name)
    made = Dir.mktmpdir("probe-classifier-mutated-")
    dir = File.realpath(made)
    raise Error, "the temp dir for the mutated classifier is inside a git worktree" if inside_worktree?(dir)

    path = File.join(dir, MUTATED_NAME)
    File.write(path, mutated)
    yield source("--classifier", path)
  ensure
    FileUtils.rm_rf(made) if made
  end

  # 結果の file に残す、分類器の素性。
  def self.identity(setup, version, partner_version = nil)
    data = { "classifier" => { "version" => version, "sha256" => setup.record.sha256 } }
    data["baseline"] = { "version" => partner_version, "sha256" => setup.baseline.sha256 } if setup.baseline
    data.merge!("mutation" => setup.mutation, "mutated_sha256" => setup.subject.sha256) if setup.mutation
    data
  end

  # --- 入口 -------------------------------------------------------------------------------
  # SystemCallError の文言から、path の部分を落とす (「… @ rb_sysopen - /path」の、理由の所だけを残す)。
  def self.errno_reason(error)
    error.message.split(" @ ", 2).first.split(" - ", 2).first
  end

  def self.preflight_data(pre)
    { "ok" => pre.ok, "unavailable" => pre.unavailable, "checks" => pre.checks.map { |c| { "name" => c.name, "ok" => c.ok } },
      "reasons" => pre.reasons }
  end

  def self.preflight_failure(pre, session)
    head = pre.unavailable ? "sandbox-exec cannot be applied here" : "the isolation preflight failed"
    one_line(redact("#{head}: #{pre.reasons.join('; ')}", session))
  end

  # 隔離の session を開いて block に渡し、終わりに必ず閉じる (一時 dir を残さない)。
  # 途中の例外の文言は一時 dir の path を含みうるので、session が在る間に置き換えてから Error にする。
  # file の操作の失敗 (結果の file を書けない、など) は、--out の dir を含むので、理由の所だけを残す。
  def self.with_session
    session = Isolation::Session.open
    yield session
  rescue Error, ProbeClassifier::Error
    raise
  rescue StandardError => e
    detail = e.is_a?(SystemCallError) ? errno_reason(e) : e.message
    raise Error, one_line(redact("#{e.class}: #{detail}", session))
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

  # --- 1 件の command ------------------------------------------------------------------------
  # info は { "version", "class", "sha256" } と、--mutation のときの "mutation" と "mutated_sha256"。
  def self.command_data(opts, info, executed:)
    data = { "mode" => "command", "variant" => opts[:variant], "command" => opts[:command],
             "classifier" => { "version" => info["version"], "sha256" => info["sha256"] } }
    data.merge!("mutation" => info["mutation"], "mutated_sha256" => info["mutated_sha256"]) if info["mutation"]
    data.merge("counts" => { "generated" => 1, "by_class" => { info["class"] => 1 }, "executed" => executed, "unmeasured" => 0 },
               "violations" => [], "human" => [], "runs" => [])
  end

  # 結果の行に、command と変種を足す (先頭の key は invariant か reason のまま)。extra は、生成の入口が足す
  # 番号と cell。行が自分の変種 (既定の変種の回で見たもの) を持つときは、そちらが残る。
  def self.with_command(items, command, variant, extra = {})
    items.map do |item|
      key, value = item.first
      { key => value }.merge(extra).merge("command" => command, "variant" => variant).merge(item)
    end
  end

  # 走らせた command の結果の file の中身。
  def self.outcome_data(opts, info, outcome)
    data = command_data(opts, info, executed: 1)
    data["counts"]["unmeasured"] = outcome.unmeasured ? 1 : 0
    data["violations"] = with_command(outcome.violations, opts[:command], opts[:variant])
    data["human"] = with_command(outcome.human, opts[:command], opts[:variant])
    data["runs"] = outcome.runs
    data
  end

  def self.run_command(opts, out)
    with_setup(opts) do |setup|
      classified = classify_all(setup.subject, [opts[:command]])
      info = { "version" => classified["version"], "class" => classified["classes"][0], "sha256" => setup.record.sha256 }
      info.merge!("mutation" => setup.mutation, "mutated_sha256" => setup.subject.sha256) if setup.mutation
      unless info["class"] == "read"
        write_results(out, command_data(opts, info, executed: 0))
        puts "command: class=#{info['class']} (not read; not run)"
        next 0
      end
      reason = Isolation.guard(opts[:command])
      raise Error, "the guard rejected the command (#{reason}); it was not run" if reason

      with_session do |session|
        pre = Isolation.preflight(session)
        raise Error, preflight_failure(pre, session) unless pre.ok

        variant = Isolation.variant(opts[:variant])
        outcome = Judge.examine(variant, ->(name) { Judge.observe(session, opts[:command], variant: name) })
        data = outcome_data(opts, info, outcome)
        write_results(out, data, session)
        report(data, session)
        Judge.exit_code(outcome)
      end
    end
  end

  # 報告の 1 行。path は command が作った名前を含むので、制御の字を置き換える (改行を含む名前が、報告の行と
  # 同じ形の行を作らないように)。
  def self.report_line(text, session)
    redact(text, session).gsub(/[\x00-\x1f\x7f]/, "?")
  end

  # 行の中身 (変わった path、名前、理由) を 1 つの文字列にする。
  def self.detail(item)
    (item["paths"] || item["names"] || item["why"] || []).join(" ")
  end

  def self.report(data, session)
    puts "command: class=read variant=#{data['variant']} runs=#{data['runs'].length} " \
         "violations=#{data['violations'].length} human=#{data['human'].length}"
    data["violations"].each { |v| puts report_line("  #{v['invariant']} #{v['kinds'].join(',')} #{v['paths'].join(' ')}", session) }
    data["human"].each { |h| puts report_line("  human #{h['reason']} #{detail(h)}".rstrip, session) }
  end

  # --- 生成の入口 ---------------------------------------------------------------------------
  # rows は生成した列、classes は調べる版の区分、partner_classes は比べる相手の区分 (相手が無ければ nil)。
  # selected は走らせる対象の番号。rejected は、そのうち guard が拒んだ番号から理由。
  # outcomes は、走らせた番号から結論 (Judge::Outcome)。
  Batch = Struct.new(:rows, :classes, :partner_classes, :selected, :rejected, :outcomes, keyword_init: true)

  # 走らせる対象。相手が無ければ、調べる版が read と区分した全件。相手が在れば、調べる版が read で、
  # 相手が read でない件 (差分の組) だけ。
  def self.select_rows(classes, partner_classes)
    classes.each_index.select { |i| classes[i] == "read" && (partner_classes.nil? || partner_classes[i] != "read") }
  end

  def self.build_batch(rows, classes, partner_classes)
    selected = select_rows(classes, partner_classes)
    rejected = {}
    # 走らせる前に guard に通す。生成器は guard を通る形だけを出すので、拒まれた件は生成器の不具合の印。
    selected.each do |i|
      reason = Isolation.guard(rows[i].command)
      rejected[i] = reason if reason
    end
    Batch.new(rows: rows, classes: classes, partner_classes: partner_classes, selected: selected, rejected: rejected,
              outcomes: {})
  end

  # 対象の command を 1 件ずつ走らせ、結論を batch に貯める。起動は Judge.observe だけを通す
  # (guard と、検査した profile の両方がかかる)。
  def self.execute(batch, session, variant)
    targets = batch.selected - batch.rejected.keys
    step = [(targets.length / PROGRESS_LINES.to_f).ceil, 1].max
    warn "run: #{targets.length} commands to run (variant #{variant.name})"
    targets.each_with_index do |index, done|
      command = batch.rows[index].command
      begin
        batch.outcomes[index] = Judge.examine(variant, ->(name) { Judge.observe(session, command, variant: name) })
      rescue Isolation::Rejected => e
        # 先に guard を通してあるので、ここには来ない見込み。来たら、走らせなかった件として数える。
        batch.rejected[index] = e.reason
      end
      warn "run: #{done + 1}/#{targets.length}" if ((done + 1) % step).zero? && done + 1 < targets.length
    end
  end

  # 反例の行と、人に出す行。1 件の --command と同じ形に、番号と cell を足す。
  # guard が拒んだ件は走らせていないので、「違反なし」に数えずに人に出す。
  def self.finding_rows(batch, variant)
    violations = []
    human = batch.rejected.keys.sort.map do |index|
      row = batch.rows[index]
      { "reason" => "guard-rejected", "index" => index, "cell" => row.cell, "command" => row.command, "variant" => variant,
        "why" => [batch.rejected[index]] }
    end
    batch.outcomes.keys.sort.each do |index|
      row = batch.rows[index]
      extra = { "index" => index, "cell" => row.cell }
      violations.concat(with_command(batch.outcomes[index].violations, row.command, variant, extra))
      human.concat(with_command(batch.outcomes[index].human, row.command, variant, extra))
    end
    [violations, human]
  end

  # 同じ形の行 (cell、不変条件か理由、差分の種類、変わった path など) を束ねる。束の代表は、最も短い command
  # (同じ長さなら番号の小さい方) の行で、count に束の件数を持つ。
  def self.grouped(items)
    items.group_by { |item| GROUP_KEYS.map { |key| item[key] } }.values.map do |list|
      list.min_by { |item| [item["command"].length, item["index"]] }.merge("count" => list.length)
    end
  end

  # cell ごとの表 (届いた範囲)。終わり方は、command ごとの最初の起動のもの。
  def self.cell_table(batch)
    by_cell = batch.rows.group_by(&:cell)
    Generator.cell_names.map do |name|
      indexes = by_cell.fetch(name, []).map(&:index)
      ran = indexes.select { |i| batch.outcomes.key?(i) }
      firsts = ran.map { |i| batch.outcomes[i].runs.first["ending"] }
      { "cell" => name, "generated" => indexes.length, "read" => indexes.count { |i| batch.classes[i] == "read" },
        "selected" => (indexes & batch.selected).length, "executed" => ran.length,
        "effective" => firsts.count { |e| Judge::EFFECTIVE_ENDINGS.include?(e) },
        "endings" => Judge::ENDINGS.select { |e| firsts.include?(e) }.map { |e| [e, firsts.count(e)] }.to_h,
        "violations" => ran.count { |i| !batch.outcomes[i].violations.empty? },
        "human" => ran.count { |i| !batch.outcomes[i].human.empty? } }
    end
  end

  # 対照の結果 (--baseline か --mutation のとき)。差分の組は、走らせる対象そのもの。
  #   found:        差分の組に、確かめた反例が 1 つ以上ある。既定でない変種の run では、その変種だけで確かめた違反
  #                 (人に出す non-default-variant) も数える (既定でない変種で見る変異を「見つけた」と言えるように)。
  #   unmeasurable: 変異が要る道具がこの machine に無い。または、差分の組が在るのに、測れた組が 1 つも無い。
  #   missed:       差分の組が 0 件か、どの組も違反にならなかった。
  # dry-run では走らせていないので、result は nil (件数だけを出す)。
  def self.control_data(setup, batch, toolset)
    pairs = batch.selected
    hit = ->(index) { batch.outcomes[index] }
    confirmed = pairs.count { |i| hit.call(i) && !hit.call(i).violations.empty? }
    variant_only = pairs.count { |i| hit.call(i) && hit.call(i).human.any? { |h| h["reason"] == "non-default-variant" } }
    measured = pairs.count { |i| hit.call(i) && !hit.call(i).unmeasured }
    data = { "pairs" => pairs.length, "result" => nil, "confirmed" => confirmed, "variant_only" => variant_only,
             "indexes" => pairs }
    mutation = setup.mutation && Mutations.fetch(setup.mutation)
    if mutation
      data["expected"] = { "invariant" => mutation.invariant, "variant" => mutation.variant, "expect" => mutation.expect,
                           "needs" => mutation.needs }
    end
    return data unless toolset

    missing = mutation ? mutation.needs - toolset.names : []
    data["needs_missing"] = missing if mutation
    data["result"] = if (confirmed + variant_only).positive? then "found"
                     elsif !missing.empty? || (!pairs.empty? && measured.zero?) then "unmeasurable"
                     else "missed"
                     end
    data
  end

  # 結果の file の中身。toolset は、走らせた run の道具の表 (dry-run では nil)。
  def self.generated_data(opts, setup, batch, subject, partner, toolset)
    violations, human = finding_rows(batch, opts[:variant])
    data = { "mode" => toolset ? "run" : "dry-run", "variant" => opts[:variant], "seed" => opts[:seed], "count" => opts[:count],
             "digest" => Generator.digest(batch.rows), "timeout" => Isolation::DEFAULT_TIMEOUT }
    data.merge!(identity(setup, subject["version"], partner && partner["version"]))
    data["counts"] = {
      "generated" => batch.rows.length,
      "by_class" => CLASSES.select { |c| batch.classes.include?(c) }.map { |c| [c, batch.classes.count(c)] }.to_h,
      "selected" => batch.selected.length, "guard_rejected" => batch.rejected.length, "executed" => batch.outcomes.length,
      "unmeasured" => batch.outcomes.values.count(&:unmeasured),
    }
    data["control"] = control_data(setup, batch, toolset) if setup.partner
    data.merge!("violations" => violations, "human" => human, "violation_groups" => grouped(violations),
                "human_groups" => grouped(human), "cells" => cell_table(batch), "coverage" => subject["coverage"])
    data["runs"] = batch.outcomes.keys.sort.flat_map { |i| batch.outcomes[i].runs.map { |run| { "index" => i }.merge(run) } }
    data["tools_missing"] = toolset.missing if toolset
    data
  end

  # 反例があれば 1、人に出すものだけなら 3、どちらも無ければ 0 (1 件の --command と同じ意味)。
  def self.generated_exit_code(data)
    return 1 unless data["violations"].empty?

    data["human"].empty? ? 0 : 3
  end

  def self.group_line(group, session)
    head = group["invariant"] ? "#{group['invariant']} #{group['kinds'].join(',')}" : "human #{group['reason']}"
    report_line("  #{head} #{detail(group)}".rstrip + " x#{group['count']} ##{group['index']} [#{group['cell']}] #{group['command']}",
                session)
  end

  def self.report_generated(data, session)
    counts = data["counts"]
    puts "generated: mode=#{data['mode']} seed=#{data['seed']} count=#{data['count']} variant=#{data['variant']}"
    puts "classes: #{counts['by_class'].map { |name, n| "#{name}=#{n}" }.join(' ')}"
    puts "selected=#{counts['selected']} guard-rejected=#{counts['guard_rejected']} executed=#{counts['executed']} " \
         "unmeasured=#{counts['unmeasured']} violations=#{data['violations'].length} human=#{data['human'].length}"
    if (control = data["control"])
      puts "control: pairs=#{control['pairs']} result=#{control['result'] || 'not-run'} " \
           "confirmed=#{control['confirmed']} variant-only=#{control['variant_only']}"
    end
    if (coverage = data["coverage"])
      puts "coverage: lines=#{coverage['lines']} load=#{coverage['load']} all=#{coverage['all']} read=#{coverage['read']}"
    end
    [data["violation_groups"], data["human_groups"]].each do |groups|
      groups.first(REPORT_GROUPS).each { |group| puts group_line(group, session) }
      puts "  (+#{groups.length - REPORT_GROUPS} more groups in results.json)" if groups.length > REPORT_GROUPS
    end
  end

  def self.finish_generated(opts, setup, batch, subject, partner, out, session)
    data = generated_data(opts, setup, batch, subject, partner, session&.toolset)
    write_corpus(out, batch)
    write_results(out, data, session)
    report_generated(data, session)
    generated_exit_code(data)
  end

  def self.run_generated(opts, out)
    rows = Generator.generate(opts[:seed], opts[:count])
    commands = rows.map(&:command)
    with_setup(opts) do |setup|
      subject = classify_all(setup.subject, commands, coverage: true)
      partner = setup.partner && classify_all(setup.partner, commands)
      batch = build_batch(rows, subject["classes"], partner && partner["classes"])
      unless batch.rejected.empty?
        warn "warning: the guard rejected #{batch.rejected.length} generated command(s); they are not run (see results.json)"
      end
      next finish_generated(opts, setup, batch, subject, partner, out, nil) unless opts[:run]

      with_session do |session|
        # preflight は run の初めに 1 回。通らなければ、何も走らせず、結果の file も書かない。
        pre = Isolation.preflight(session)
        raise Error, preflight_failure(pre, session) unless pre.ok

        execute(batch, session, Isolation.variant(opts[:variant]))
        finish_generated(opts, setup, batch, subject, partner, out, session)
      end
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
    case mode(opts)
    when :preflight then run_preflight(out)
    when :command then run_command(opts, out)
    else run_generated(opts, out)
    end
  rescue Error, ProbeClassifier::Error => e
    warn "error: #{one_line(redact(e.message))}"
    warn USAGE if e.message.match?(/\A(--|unknown argument)/)
    2
  rescue SystemCallError => e
    # 例外の文言は path (--out の dir、分類器の file、一時 dir) を含むので、理由の所だけを出す。
    warn "error: #{one_line(redact(errno_reason(e)))}"
    2
  rescue Interrupt
    warn "error: interrupted"
    2
  rescue StandardError => e
    # 想定していない失敗。exit 1 は「反例あり」の意味なので、Ruby の既定の終了 (exit 1 と backtrace) には任せない。
    warn "error: unexpected failure: #{one_line(redact("#{e.class}: #{e.message}"))}"
    2
  end
end

if $PROGRAM_NAME == __FILE__
  exit ProbeClassifierInvariants.main(ARGV)
end
