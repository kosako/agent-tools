# frozen_string_literal: true

# 分類器の不変条件の試行 (#754) の隔離。Spec: docs/classifier-invariants.md の「隔離」。
#
# read と区分された command を、command ごとに新しい一時 dir の中で走らせ、終わり方を返す。
# 層は 2 つある。文字列の guard は、一時 dir の外を指す形と、終わらない形を走らせない。
# sandbox-exec の profile は、外への書き込み、network、HOME の読み取り、表に無い program の起動、
# 外の process への signal を拒む。
# command は必ず sandbox-exec を通す。sandbox を適用できなければ sandbox-exec が失敗し、command は走らない。
# preflight は、profile の拒否が効いていること (対照つき) と、sandbox を外しても語彙の中の書き込みが
# 一時 dir に閉じることを確かめる。呼ぶ側は、走らせる前に preflight をかけ、通らなければ走らせない。
#
# 責務の境界:
#   - ここは走らせて終わり方を返すだけ。snapshot、差分、違反の判定は judge.rb が持つ。
#   - guard は分類器を読まない。分類器と同じ読み違いを、ここに持ち込まないため。
#   - 止めた後に group が空と確かめられなかった回は、呼ぶ側が「未測定」に数える。
#   - group を抜けた子 (setsid など) は追えず、気付けない。その子も sandbox の中には留まる。
#
# 値は shell の文字列に埋め込まず、argv の配列で渡す。

require "etc"
require "fileutils"
require "socket"
require "tmpdir"
require_relative "../probe_child"

module ProbeClassifier
  class Error < StandardError; end

  module Isolation
    # guard が拒んだ command を run_command に渡したとき。
    class Rejected < Error
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("the guard rejected the command (#{reason})")
      end
    end

    SANDBOX_EXEC = "/usr/bin/sandbox-exec"
    XCODE_SELECT = "/usr/bin/xcode-select"
    # login の shell (zsh -lc) が PATH を組み直すのに呼ぶ。許さないと、PATH が実機と違う形になる。
    PATH_HELPER = "/usr/libexec/path_helper"
    DEFAULT_TIMEOUT = 5
    # preflight の「終わらない command」の期限。止めるのに、これと ProbeChild の TERM の猶予 (1 秒) がかかる。
    # preflight は走らせるたびにかけるので、短く取る。
    HANG_TIMEOUT = 0.5
    # 止まるまでの時間の余裕。期限と猶予にこれを足した時間を超えたら、期限が効いていないとみなす。
    HANG_MARGIN = 3
    # 一時 dir の中の区画。fx が cwd。marks は canary が印を書く所。
    ZONES = %w[fx home tmp shim tools marks].freeze
    # sandbox を外した対照の profile。guard だけで外に出ないことを確かめるのに使う。
    OPEN_PROFILE = "(version 1)(allow default)"
    # 子の stdin を /dev/null にする包み。pipe のままだと、入力の有無で動きを変える道具 (path を省いた rg など) が、
    # stdin を読む側に回る。
    STDIN_WRAPPER = 'exec "$@" </dev/null'
    # 一時 dir の path に許す字。canary と profile に焼き込むので、引用の要る字を受けない。
    SAFE_PATH = %r{\A(/[A-Za-z0-9_.+-]+)+\z}.freeze

    # --- 道具の表 ---------------------------------------------------------------------------
    # 名前から候補の path (先が優先)。実行のときに、在って実行できる実体だけを tools に symlink で置く。
    # 必須は、fixture を作る git と、preflight が使う道具。欠けると preflight が失敗にする。
    # 書き込みの道具 (rm、touch、tee など) は入れない。fixture を作るのに要るのは git だけ。
    # git の候補は空。developer dir の実体を resolve_tools が足す (GIT_IN_DEVELOPER_DIR)。
    REQUIRED_TOOLS = {
      "sh" => %w[/bin/sh], "bash" => %w[/bin/bash], "zsh" => %w[/bin/zsh], "env" => %w[/usr/bin/env],
      "cat" => %w[/bin/cat], "git" => [], "ruby" => %w[/usr/bin/ruby],
      # system の ruby は、起動のときに uname を呼ぶ (実測)。
      "uname" => %w[/usr/bin/uname], "sort" => %w[/usr/bin/sort], "tail" => %w[/usr/bin/tail],
    }.freeze
    # 任意の道具。無ければ足さない (その名前の command は「見つからない」で終わる)。
    # rg は、決めた場所で解決できた実体だけを足す。親の PATH は見ない (shim を拾わないため)。
    OPTIONAL_TOOLS = {
      "head" => %w[/usr/bin/head], "grep" => %w[/usr/bin/grep], "egrep" => %w[/usr/bin/egrep],
      "fgrep" => %w[/usr/bin/fgrep], "ls" => %w[/bin/ls], "wc" => %w[/usr/bin/wc], "nl" => %w[/usr/bin/nl],
      "stat" => %w[/usr/bin/stat], "pwd" => %w[/bin/pwd], "cd" => %w[/usr/bin/cd], "echo" => %w[/bin/echo],
      "cmp" => %w[/usr/bin/cmp], "cut" => %w[/usr/bin/cut], "tr" => %w[/usr/bin/tr], "jq" => %w[/usr/bin/jq],
      "which" => %w[/usr/bin/which], "type" => %w[/usr/bin/type], "basename" => %w[/usr/bin/basename],
      "dirname" => %w[/usr/bin/dirname], "realpath" => %w[/bin/realpath], "readlink" => %w[/usr/bin/readlink],
      "true" => %w[/usr/bin/true], "false" => %w[/usr/bin/false], "du" => %w[/usr/bin/du], "id" => %w[/usr/bin/id],
      "whoami" => %w[/usr/bin/whoami], "column" => %w[/usr/bin/column], "fold" => %w[/usr/bin/fold],
      "od" => %w[/usr/bin/od], "hexdump" => %w[/usr/bin/hexdump], "strings" => %w[/usr/bin/strings],
      "shasum" => %w[/usr/bin/shasum], "sha256sum" => %w[/sbin/sha256sum /usr/bin/sha256sum],
      "md5" => %w[/sbin/md5], "md5sum" => %w[/sbin/md5sum /usr/bin/md5sum],
      "uniq" => %w[/usr/bin/uniq], "diff" => %w[/usr/bin/diff], "sed" => %w[/usr/bin/sed],
      "awk" => %w[/usr/bin/awk], "find" => %w[/usr/bin/find], "xargs" => %w[/usr/bin/xargs],
      "nohup" => %w[/usr/bin/nohup], "nice" => %w[/usr/bin/nice], "time" => %w[/usr/bin/time],
      "command" => %w[/usr/bin/command], "rg" => %w[/opt/homebrew/bin/rg /usr/local/bin/rg],
    }.freeze
    # script の道具に許す interpreter。ほかの interpreter (perl など) を要る道具は足さない。
    SCRIPT_INTERPRETERS = %w[/bin/sh].freeze
    # git は、developer dir の中の実体を直接置く。/usr/bin/git は、developer dir の git を探して起動する入口で、
    # developer dir が Xcode.app の下の環境 (CI の runner) では、git status と git diff が 0 で終わったまま、
    # 拒否の字面を stderr に出した (探した結果を一時 dir の外に書き残そうとするためと見ている)。
    GIT_IN_DEVELOPER_DIR = %w[usr bin git].freeze

    Tool = Struct.new(:name, :path, :real, keyword_init: true)

    # tools は解決できた道具。missing は、足さなかった名前から理由。
    Toolset = Struct.new(:tools, :missing, :developer_dir, keyword_init: true) do
      def [](name)
        tools.find { |t| t.name == name }
      end

      def names
        tools.map(&:name)
      end

      def missing_required
        REQUIRED_TOOLS.keys & missing.keys
      end

      # exec を許す実 path。照合は実 path なので、symlink の名前ではなく解決した先を並べる。
      def exec_literals
        extra = File.executable?(PATH_HELPER) ? [File.realpath(PATH_HELPER)] : []
        (tools.map(&:real) + extra).uniq
      end
    end

    def self.profile_safe?(path)
      path.start_with?("/") && !path.match?(/["\\\n]/)
    end

    def self.inside?(path, dir)
      path == dir || path.start_with?("#{dir}/")
    end

    # 候補の 1 つを確かめる。使えれば [Tool の材料, nil]、使えなければ [nil, 理由]。
    def self.resolve_candidate(path, deny_read)
      return [nil, "not-found"] unless File.file?(path) && File.executable?(path)

      real = File.realpath(path)
      return [nil, "unsafe-path"] unless profile_safe?(real)
      # HOME の下の実体は、profile が読み取りを拒むので動かない。
      return [nil, "under-home"] if deny_read.any? { |d| inside?(real, d) }

      head = File.open(real, "rb") { |f| f.read(256) }.to_s
      if head.start_with?("#!")
        interpreter = head.lines.first.to_s[2..-1].to_s.split.first.to_s
        return [nil, "interpreter-not-allowed"] unless SCRIPT_INTERPRETERS.include?(interpreter)
      end
      [real, nil]
    rescue SystemCallError
      [nil, "unreadable"]
    end

    # git の実体は developer dir の中にある。その dir を、子と同じ閉じた環境で聞く
    # (親の DEVELOPER_DIR に引かれると、/usr/bin/git が実機で起動する git と食い違う)。
    def self.developer_dir
      return nil unless File.executable?(XCODE_SELECT)

      result = ProbeChild.run([XCODE_SELECT, "-p"], env: {}, chdir: "/", timeout: 10, unsetenv_others: true)
      path = result.out.to_s.strip
      return nil unless result.status&.success? && File.directory?(path)

      real = File.realpath(path)
      profile_safe?(real) ? real : nil
    rescue SystemCallError
      nil
    end

    def self.resolve_tools(deny_read)
      tools = []
      missing = {}
      REQUIRED_TOOLS.merge(OPTIONAL_TOOLS).each do |name, candidates|
        reason = "not-found"
        found = nil
        candidates.each do |path|
          real, why = resolve_candidate(path, deny_read)
          if real
            found = Tool.new(name: name, path: path, real: real)
            break
          end
          reason = why
        end
        found ? tools << found : missing[name] = reason
      end
      dev = developer_dir
      dev = nil if dev && deny_read.any? { |d| inside?(dev, d) }
      if dev
        git = File.join(dev, *GIT_IN_DEVELOPER_DIR)
        real, why = resolve_candidate(git, deny_read)
        if real
          tools << Tool.new(name: "git", path: git, real: real)
          missing.delete("git")
        else
          missing["git"] = why
        end
      else
        missing["git"] = "no-developer-dir"
      end
      Toolset.new(tools: tools, missing: missing, developer_dir: dev)
    end

    # --- 変種の表 ---------------------------------------------------------------------------
    # 1 回の起動は 1 変種。default は既定の設定の shell。base は、同じ shell の既定の変種の名前。
    # bash の nullglob は -O で立てる (/bin/bash 3.2 で通ることを実測した)。
    Variant = Struct.new(:name, :argv, :default, :base, keyword_init: true)
    VARIANTS = [
      Variant.new(name: "zsh", argv: %w[/bin/zsh -f -c], default: true, base: "zsh"),
      Variant.new(name: "bash", argv: %w[/bin/bash -c], default: true, base: "bash"),
      Variant.new(name: "sh", argv: %w[/bin/sh -c], default: true, base: "sh"),
      Variant.new(name: "zsh-extendedglob", argv: %w[/bin/zsh -f -o extendedglob -c], default: false, base: "zsh"),
      Variant.new(name: "zsh-nullglob", argv: %w[/bin/zsh -f -o nullglob -c], default: false, base: "zsh"),
      Variant.new(name: "bash-nullglob", argv: %w[/bin/bash -O nullglob -c], default: false, base: "bash"),
    ].freeze
    DEFAULT_VARIANT = "zsh"

    def self.variant(name)
      VARIANTS.find { |v| v.name == name }
    end

    # --- canary -----------------------------------------------------------------------------
    # 走ると、印の dir に「id.pid」の空の file を書く。id で、どの canary が走ったかが分かる。
    # kind は数え方の区分。path と cli と fixture は I2 に数える。reserved は置いた名前に依るので人に出す。
    # reserved の名前は、分類器が読み飛ばす予約語 (PREFIX_WORDS の then do else ! { と、} fi done)。
    Canary = Struct.new(:id, :zone, :rel, :kind, :lang, keyword_init: true) do
      def path_in(layout)
        File.join(layout.public_send(zone), rel)
      end
    end
    CLI_NAMES = %w[codex claude gh opencode herdr].freeze
    RESERVED_NAMES = { "then" => "then", "do" => "do", "else" => "else", "fi" => "fi", "done" => "done",
                       "!" => "bang", "{" => "lbrace", "}" => "rbrace" }.freeze
    CANARIES = (
      [Canary.new(id: "shim.canary", zone: "shim", rel: "canary", kind: :path, lang: :sh)] +
      CLI_NAMES.map { |n| Canary.new(id: "cli.#{n}", zone: "shim", rel: n, kind: :cli, lang: :sh) } +
      RESERVED_NAMES.map { |n, id| Canary.new(id: "word.#{id}", zone: "shim", rel: n, kind: :reserved, lang: :sh) } +
      [Canary.new(id: "fx.cat", zone: "fx", rel: "cat", kind: :fixture, lang: :sh),
       Canary.new(id: "fx.bin-grep", zone: "fx", rel: "bin/grep", kind: :fixture, lang: :sh),
       # Ruby の file。読み込まれると BEGIN で印を書く。system の ruby 2.6 の -c は BEGIN を走らせない (実測)。
       Canary.new(id: "fx.canary-begin", zone: "fx", rel: "canary_begin.rb", kind: :fixture, lang: :ruby)]
    ).freeze
    MARK_NAME = /\A(?<id>[a-z]+\.[a-z-]+)\.\d+\z/.freeze

    def self.canary(id)
      CANARIES.find { |c| c.id == id }
    end

    # canary の中身。sh のものは builtin だけで印を書く (外の program を呼ぶと、その起動が別の観測に混ざる)。
    def self.canary_body(canary, marks_dir)
      mark = File.join(marks_dir, canary.id)
      case canary.lang
      when :ruby then "BEGIN { File.open(\"#{mark}.\#{Process.pid}\", \"w\") {} }\n"
      else "#!/bin/sh\n: > '#{mark}.'$$\n"
      end
    end

    def self.install_canaries(layout)
      CANARIES.each do |canary|
        path = canary.path_in(layout)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, canary_body(canary, layout.marks))
        File.chmod(canary.lang == :sh ? 0o755 : 0o644, path)
      end
    end

    # hits は canary の id から回数。stray は、印の形でない entry の名前 (印の dir への書き込みの跡)。
    Marks = Struct.new(:hits, :stray, keyword_init: true)

    def self.read_marks(layout)
      hits = Hash.new(0)
      stray = []
      Dir.children(layout.marks).sort.each do |name|
        m = MARK_NAME.match(name)
        if m && canary(m[:id]) && File.file?(File.join(layout.marks, name))
          hits[m[:id]] += 1
        else
          stray << name
        end
      end
      Marks.new(hits: hits, stray: stray)
    end

    # --- 一時 dir の配置と fixture --------------------------------------------------------------
    Layout = Struct.new(:root, :base, :alias_base, keyword_init: true) do
      ZONES.each { |zone| define_method(zone) { File.join(base, zone) } }
    end

    # 基本の fixture。git の repo で、commit が 2 つあり、README.md に未 commit の変更がある。
    # in.txt は同じ行が続く所を持つ (uniq の題材)。x は sed の番地の題材 (a/, を含む行)。
    FIXTURE_FIRST = {
      "README.md" => "# fixture\n\nA small tree for the classifier invariant runs.\n",
      "in.txt" => "apple\napple\nbanana\n",
      "x" => "a/,\nzzz\n",
      "lib/median.rb" => "# frozen_string_literal: true\n\ndef median(values)\n  sorted = values.sort\n  " \
                         "sorted[sorted.length / 2]\nend\n",
    }.freeze
    FIXTURE_SECOND = { "in.txt" => "apple\napple\nbanana\ncherry\ncherry\napple\n" }.freeze
    FIXTURE_DIRTY = { "README.md" => "#{FIXTURE_FIRST.fetch('README.md')}\nuncommitted line\n" }.freeze
    # 狙いごとの dir (scene)。最初の commit に入れる (git からは tracked な file に見える)。
    # 生成器の operand の表 (generator.rb の FIXTURE_PATHS) が、ここの名前を当てにする。
    # - で始まる名前は、glob の展開で option になる。repo には置かず、fixture を作るときに、ここから書く。
    FIXTURE_SCENES = {
      # ちょうど 2 つの file。uniq に渡ると、2 つ目が出力の file になる。
      "pair/a.txt" => "apple\napple\nbanana\n", "pair/b.txt" => "zzz\n",
      # sort の -o と値が、1 語になった名前。
      "sortopt/-oplanted.txt" => "pear\n", "sortopt/in.txt" => "banana\napple\n",
      # rg の --pre と値が、1 語になった名前。値は PATH の canary を指す。
      "pre/--pre=canary" => "median\n", "pre/a.txt" => "median\n",
      # 読むだけの command の option になる名前。
      "plain/-n" => "apple\n", "plain/a.txt" => "apple\nbanana\n",
    }.freeze
    # commit の hash を回ごとに変えないための日時。
    TEMPLATE_ENV = { "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }.freeze
    GIT_INIT = "git -c init.defaultBranch=main init -q ."
    GIT_COMMIT = 'git add -A . && git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "$1"'
    # index の stat を、今の file に合わせ直す。-q は、未 commit の変更があっても失敗にしない。
    GIT_REFRESH = "git update-index -q --refresh"
    # fixture の file の mtime。過去の決まった時刻に揃える。index と同じ秒の mtime が残ると、git は中身を比べ直して
    # index を書き直す。その回は、template を作ってからの時間で結果が変わった (git describe --dirty で実測)。
    FIXTURE_MTIME = Time.utc(2026, 1, 1)

    def self.write_files(dir, files)
      files.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        File.utime(FIXTURE_MTIME, FIXTURE_MTIME, path)
      end
    end

    def self.link_tools(layout, toolset)
      toolset.tools.each { |tool| File.symlink(tool.path, File.join(layout.tools, tool.name)) }
    end

    # --- 閉じた環境 ---------------------------------------------------------------------------
    # 子に渡す環境はこの表だけ。親の環境は引き継がない (RIPGREP_CONFIG_PATH や GIT_DIR が効くと、
    # 同じ command が別の動きになる)。GIT_OPTIONAL_LOCKS=0 は、git status の index の書き直しを止める
    # (git diff の書き直しは止まらなかった。prepare で index を揃えて避ける)。
    ENV_KEYS = %w[HOME PATH TMPDIR LC_ALL GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_OPTIONAL_LOCKS].freeze
    # shell が自分で足す変数 (LOGNAME は zsh が足す。実測)。子の環境を確かめるときに、表の外として数えない。
    SHELL_KEYS = %w[PWD OLDPWD SHLVL LOGNAME _].freeze

    def self.child_env(layout)
      { "HOME" => layout.home, "PATH" => "#{layout.shim}:#{layout.tools}", "TMPDIR" => layout.tmp, "LC_ALL" => "C",
        "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_OPTIONAL_LOCKS" => "0" }
    end

    # 親の環境に変数を立てて block を走らせ、元に戻す (「親の環境が子に渡らない」の検査用)。
    def self.with_parent_env(vars)
      saved = vars.keys.map { |k| [k, ENV[k]] }
      vars.each { |k, v| ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| ENV[k] = v }
    end

    # --- profile ---------------------------------------------------------------------------
    def self.sb_quote(path)
      raise ArgumentError, "path is not safe to embed in a sandbox profile" unless profile_safe?(path)

      "\"#{path}\""
    end

    # sandbox-exec の profile。後ろの規則が前の規則に勝つ。
    # 書き込みは一時 dir と /dev/null だけ。network と、deny_read (本物の HOME) の読み取りを拒む。
    # exec は allowlist。一時 dir の全体には許さない (fixture の中の file が、canary にも拒否にも
    # 当たらずに走るのを防ぐ)。signal は、同じ sandbox の中の process にだけ送れる (shell の builtin の kill は
    # exec の allowlist に掛からないので、外の process を止められないように、別に拒む)。
    # allow_write、network、signals は、否定の検査の対照 (相手を許した profile) のため。
    def self.profile(base:, deny_read:, exec_literals:, exec_subpaths:, allow_write: [], network: false,
                     signals: false)
      raise ArgumentError, "deny_read must not be empty" if deny_read.empty?

      writable = ([base] + allow_write).map { |d| "(subpath #{sb_quote(d)})" }
      execs = exec_literals.map { |p| "(literal #{sb_quote(p)})" } + exec_subpaths.map { |d| "(subpath #{sb_quote(d)})" }
      lines = ["(version 1)", "(allow default)"]
      lines << "(deny network*)" unless network
      lines << '(deny file-write* (subpath "/"))'
      lines << "(allow file-write* #{writable.join(' ')} (literal \"/dev/null\"))"
      lines << "(deny file-read* #{deny_read.map { |d| "(subpath #{sb_quote(d)})" }.join(' ')})"
      lines << "(deny process-exec*)"
      lines << "(allow process-exec* #{execs.join(' ')})"
      lines.push("(deny signal)", "(allow signal (target same-sandbox))") unless signals
      lines.join("\n")
    end

    # --- 起動の結果 ---------------------------------------------------------------------------
    # exit_code と signal は、終わりを確かめられなければ nil。out と err は、一時 dir と HOME の path を
    # 置き換えた後の text。group_empty は、止めた後に子の group が空になったと確かめられたか。
    # sandbox_error は、sandbox-exec 自体が失敗した回 (command は走っていない)。
    Run = Struct.new(:layout, :variant, :command, :exit_code, :signal, :timed_out, :out, :err, :group_empty,
                     :drained, :sandbox_error, keyword_init: true)

    GROUP_TRIES = 40
    GROUP_INTERVAL = 0.025

    # group が空か。ESRCH なら空と確かめられた。signal が届く間 (member が生きている) と、EPERM の間
    # (macOS は中が zombie だけの group に EPERM を返す) は、短く待って確かめ直す。
    def self.group_empty?(pgid, tries: GROUP_TRIES, interval: GROUP_INTERVAL)
      return false unless pgid.is_a?(Integer) && pgid > 1

      tries.times do |n|
        sleep interval if n.positive?
        begin
          Process.kill(0, -pgid)
        rescue Errno::ESRCH
          return true
        rescue Errno::EPERM
          next
        end
      end
      false
    end

    # sandbox が拒んだ起動の終わり方。sh と bash は 126、zsh は 127 (実測)。stderr の字面は shell で違う。
    #   zsh:        zsh:1: operation not permitted: NAME
    #   sh / bash:  /bin/sh: NAME: Operation not permitted
    #   xargs, env: xargs: NAME: Operation not permitted
    DENIED_EXEC = /operation not permitted/i.freeze

    def self.denied_exec?(run)
      [126, 127].include?(run.exit_code) && run.err.match?(DENIED_EXEC)
    end

    # この環境で sandbox を適用できない回 (入れ子の sandbox の中では sandbox_apply が拒まれる)。
    # profile の誤りなど、ほかの失敗は含めない (skip でなく失敗にするため)。
    def self.sandbox_unavailable?(run)
      run.sandbox_error && run.err.match?(/sandbox_apply|could not be started/)
    end

    # --- session ----------------------------------------------------------------------------
    # 1 回の run の間の状態 (一時 dir の置き場、道具の表、fixture の template)。
    class Session
      attr_reader :root, :root_alias, :deny_read, :toolset, :problems, :template

      # root は一時 dir の置き場。省くと自分で作り、close で消す。渡した root は消さない。
      def self.open(root: nil)
        new(root)
      end

      def initialize(root)
        @owned = root.nil?
        given = root || Dir.mktmpdir("probe-classifier-")
        @root_alias = File.expand_path(given)
        @root = File.realpath(given)
        @deny_read = Isolation.real_homes
        @toolset = Isolation.resolve_tools(@deny_read)
        @created = []
        @template = nil
        @problems = setup_problems
      end

      # 隔離を組めない理由。空でなければ、preflight が失敗にする (素の実行には戻らない)。
      def setup_problems
        problems = []
        problems << "the temp root has characters that cannot be embedded safely" unless @root.match?(SAFE_PATH)
        problems << "the real HOME could not be determined" if @deny_read.empty?
        unless @deny_read.all? { |d| Isolation.profile_safe?(d) }
          problems << "the real HOME path cannot be embedded in a sandbox profile"
        end
        # HOME の読み取りを拒むので、HOME の下の一時 dir は使えない。
        problems << "the temp root is under the real HOME" if @deny_read.any? { |d| Isolation.inside?(@root, d) }
        @toolset.missing_required.each do |name|
          problems << "required tool is not usable: #{name} (#{@toolset.missing[name]})"
        end
        problems
      end

      def new_layout(prefix)
        base = File.realpath(Dir.mktmpdir(prefix, @root))
        @created << base
        layout = Layout.new(root: @root, base: base, alias_base: File.join(@root_alias, File.basename(base)))
        ZONES.each { |zone| Dir.mkdir(layout.public_send(zone)) }
        layout
      end

      def profile_for(layout, allow_write: [], deny_read_extra: [], exec_extra: [], network: false, signals: false)
        fixture = CANARIES.select { |c| c.zone == "fx" && c.lang == :sh }.map { |c| c.path_in(layout) }
        Isolation.profile(
          base: layout.base, deny_read: @deny_read + deny_read_extra,
          exec_literals: @toolset.exec_literals + fixture + exec_extra,
          exec_subpaths: [@toolset.developer_dir, layout.shim].compact,
          allow_write: allow_write, network: network, signals: signals,
        )
      end

      # fixture の template を、隔離の中 (profile と閉じた環境の下) で 1 回だけ作る。
      # user の global の git の設定と hook を通さないため。
      def build_template
        return @template if @template
        raise Error, @problems.join("; ") unless @problems.empty?

        layout = new_layout("pci-template-")
        Isolation.link_tools(layout, @toolset)
        Isolation.write_files(layout.fx, FIXTURE_FIRST)
        Isolation.write_files(layout.fx, FIXTURE_SCENES)
        fixture_step(layout, "#{GIT_INIT} && #{GIT_COMMIT}", "first")
        Isolation.write_files(layout.fx, FIXTURE_SECOND)
        fixture_step(layout, GIT_COMMIT, "second")
        Isolation.write_files(layout.fx, FIXTURE_DIRTY)
        # git init が置く hook の見本は実行できる file なので、fixture に残さない。
        FileUtils.rm_rf(File.join(layout.fx, ".git", "hooks"))
        @template = layout
      end

      # fixture を用意する git の 1 歩。隔離の中 (profile と閉じた環境の下) で走らせる。
      def fixture_step(layout, script, message)
        env = Isolation.child_env(layout).merge(TEMPLATE_ENV)
        run = run_argv(layout, ["/bin/sh", "-c", script, "sh", message], env: env, timeout: 30)
        return if run.exit_code == 0 && !run.timed_out

        raise Error, "the fixture could not be prepared (#{message}, exit #{run.exit_code.inspect}): #{run.err.strip}"
      end

      # command 1 件のための新しい一時 dir。template を fx に写し、その後で canary を書く。
      def prepare
        build_template
        layout = new_layout("pci-")
        FileUtils.cp_r(File.join(@template.fx, "."), layout.fx, preserve: true)
        Isolation.link_tools(layout, @toolset)
        # template を写した直後の fixture では、git diff が GIT_OPTIONAL_LOCKS=0 でも index を書き直した (実測。
        # 写した file の stat が index と食い違うためと見ている)。index を揃えた後は書き直さなかったので、
        # fixture の用意の跡を command の書き込みと読み違えないように、走らせる前に揃える。
        fixture_step(layout, GIT_REFRESH, "refresh")
        Isolation.install_canaries(layout)
        layout
      end

      # argv を隔離の中で走らせる。guard は通さない (preflight と fixture の用意、test のための入口)。
      # argv の並びは、sandbox-exec、stdin を /dev/null にする包み、渡された argv の順。
      def run_argv(layout, argv, profile: nil, env: nil, timeout: DEFAULT_TIMEOUT, inherit_env: false,
                   variant: nil, command: nil)
        full = [SANDBOX_EXEC, "-p", profile || profile_for(layout), "/bin/sh", "-c", STDIN_WRAPPER, "sh", *argv]
        result = ProbeChild.run(full, env: env || Isolation.child_env(layout), chdir: layout.fx, timeout: timeout,
                                      unsetenv_others: !inherit_env)
        status = result.status
        err = redact(result.err, layout)
        Run.new(
          layout: layout, variant: variant, command: command, exit_code: status&.exitstatus, signal: status&.termsig,
          timed_out: !result.completed, out: redact(result.out, layout), err: err,
          # ProbeChild.run は group の終わりを返さないので、ここで確かめる。pid が分からなければ未確認。
          group_empty: status ? Isolation.group_empty?(status.pid) : false,
          # sandbox-exec 自体の失敗は 0 で終わらない (65 と 71 を実測)。0 で終わった回の同じ字面は、command の出力。
          drained: result.drained, sandbox_error: err.match?(/^sandbox-exec: /) && status&.exitstatus != 0
        )
      rescue SystemCallError => e
        # sandbox-exec を起動できない (無い、など)。command は走っていない。
        Run.new(layout: layout, variant: variant, command: command, exit_code: nil, signal: nil, timed_out: false,
                out: "", err: "sandbox-exec: could not be started (#{e.class})", group_empty: true, drained: true,
                sandbox_error: true)
      end

      # command を、変種の shell で走らせる。guard は通さない。
      def launch(layout, command, variant: DEFAULT_VARIANT, **opts)
        v = Isolation.variant(variant) || raise(ArgumentError, "unknown variant: #{variant}")
        run_argv(layout, v.argv + [command], variant: v.name, command: command, **opts)
      end

      # 1 件の command を、guard に通してから、新しい一時 dir の中で走らせる。guard が拒めば Rejected。
      # block には、走らせる前の layout を渡す (呼ぶ側が、前の snapshot を取る)。後始末は呼ぶ側が cleanup で行う。
      def run_command(command, variant: DEFAULT_VARIANT, timeout: DEFAULT_TIMEOUT)
        reason = Isolation.guard(command)
        raise Rejected, reason if reason
        raise ArgumentError, "unknown variant: #{variant}" unless Isolation.variant(variant)

        layout = prepare
        begin
          yield layout if block_given?
          launch(layout, command, variant: variant, timeout: timeout)
        rescue StandardError
          cleanup(layout)
          raise
        end
      end

      # 出力に、一時 dir と HOME の絶対 path を残さない。長い path から置き換える。
      def redact(text, layout = nil)
        pairs = []
        pairs.push([layout.base, "<T>"], [layout.alias_base, "<T>"]) if layout
        pairs.push([@root, "<R>"], [@root_alias, "<R>"])
        (@deny_read + [ENV["HOME"].to_s]).each { |home| pairs << [home, "<HOME>"] unless home.empty? }
        out = text.to_s.b
        pairs.uniq.sort_by { |from, _| -from.length }.each { |from, to| out = out.gsub(from.b) { to } }
        out.force_encoding(Encoding::UTF_8).scrub("?")
      end

      # 自分が作った一時 dir だけを消す。
      def cleanup(layout)
        base = layout.base
        return unless @created.include?(base) && Isolation.inside?(base, @root) && base != @root

        FileUtils.rm_rf(base)
        @created.delete(base)
      end

      def close
        @created.dup.each { |base| cleanup(Layout.new(root: @root, base: base, alias_base: base)) }
        @template = nil
        FileUtils.rm_rf(@root) if @owned
      end
    end

    def self.real_homes
      dirs = [ENV["HOME"]]
      begin
        dirs << Etc.getpwuid(Process.uid).dir
      rescue ArgumentError
        nil
      end
      dirs.compact.reject(&:empty?).select { |d| File.directory?(d) }.map { |d| File.realpath(d) }.uniq
    end

    # --- guard (文字列で見る) -----------------------------------------------------------------
    # 一時 dir の外を指しうる形と、network、端末、終わらない形、signal を、走らせる前に拒む。戻り値は、通せば nil、
    # 拒めば理由の名前。分類器より粗く、拒む側に寄せる (通る形でも、ここで拒むことがある)。
    # 止める対象 (shell の process group) から子が外れる形と、後ろで走る子を作る形も拒む。
    # 見るのは command の文字列だけ。実行のときに出来る path (which の出力や、tr で作った .. を xargs に
    # 渡す、など) は見えない。そこは sandbox の層が受ける。run_command は必ず profile を付けて走らせる
    # (profile を替えられるのは、検査のための launch と run_argv だけ)。
    # 実行のときに出来る command (printf で組んだ文字列を sh に渡す、など) も見えない。group を抜ける形が
    # そこから出来た回は、受ける層が無い (docs の「限界」)。
    #
    # 分類器の門が通す安全な redirect (SkillBehaviorClassifier::SAFE_REDIRECTS と同じ 7 つ)。/dev/null の
    # 先頭の / を、絶対 path の規則から外す。後ろに字が続く形 (>/dev/nullx) は外さない。
    SAFE_REDIRECTS = ["2>/dev/null", "1>/dev/null", "&>/dev/null", ">/dev/null", "2>&1", "1>&2", ">&2"].freeze
    # 受ける $ の形 (閉じた表) と、閉じた環境で展開した後の語。生成器が門の外の形として出す文字列だけ。
    # 環境の変数の参照は受けない。guard は、形を展開した後の語に置き換えてから、ほかの規則を当てる
    # (消すと、xargs "${zz:--o}" cat の -o のように、展開で出来る option を見逃す)。
    # 変数を読む形は、その変数が設定されていない前提の語を持つ。変数の名前が command のほかの所に出る形は受けない
    # (zz=-f を先に置くと、"${zz:--o}" は -f になる)。
    # 3 つ目は、置き換えの中の書き込み。語には展開されないので、中で走る command を値に持つ (guard は、その
    # command にほかの規則を当てる)。zsh は、整数の変数 (RANDOM) への代入で、設定済みの変数 a の添字の中の
    # 置き換えを走らせる (a=1 を先に置いた形で実測。a が無ければ走らない。bash と sh では走らない)。
    # 形は、代入の語の全体で持つ (中の $(…) だけを受けると、ほかの位置の置き換えまで通る)。
    DOLLAR_FORMS = { "$'-o'" => "-o", '"${zz:--o}"' => "-o",
                     "RANDOM='a[$(sort -o out.txt in.txt)1]'" => "sort -o out.txt in.txt" }.freeze
    # sed と awk の script の表。番地の / で始まる script は絶対 path の規則に当たるので、人が中身を
    # 確かめた script だけを、単一引用の語の完全一致で外す。K2 (#756) の形と、番地の範囲を表示するだけの形。
    # 表の語は、sed と awk のほかの command の引数でも外れる。番地で始まる script は、字面の上では絶対 path になる。
    # 足すのは、人が中身を確かめた literal だけ。どの machine にも在りそうな場所 (/etc/…、/tmp/…) を指す script は足さない。
    SCRIPT_TABLE = ['/a\/,/w lib/p', "/apple/,/banana/p"].freeze
    # xargs の、値をとる option。値の語を option と読み違えないために使う。
    XARGS_VALUE_OPTIONS = %w[-E -I -J -L -n -P -R -S -s -d -a].freeze
    SIGNAL_NAMES = %w[kill pkill killall].freeze
    # dir を移る builtin。zsh は、引数が 2 つあると、今の dir の path の一部を置き換えて移る (cd fx tools)。
    DIR_BUILTINS = %w[cd chdir pushd popd].freeze
    # shell の設定は、変種の表だけが決める。command の中で設定を変える形は受けない。
    # sh と bash は、job control を立てると (set -m、SHELLOPTS=monitor)、子を別の process group に移す。
    # その子は、止める対象から外れて残った (実測)。zsh は、端末なしでは job control を立てられなかった。
    SHELL_SETTERS = %w[set setopt unsetopt shopt emulate].freeze
    SHELL_ENV = /SHELLOPTS|BASHOPTS/.freeze
    SHELL_NAMES = %w[sh bash zsh dash ksh].freeze
    # 入れ子の shell の名前の直後に受ける option。ほかの option (-m、-i、-o NAME など) は拒む。
    SHELL_OPTIONS = %w[-c -lc].freeze
    # & を使わずに、後ろで走る子を作る語。
    BACKGROUND_NAMES = %w[coproc].freeze
    # 終わりを条件に任せる loop の語。文字列で見える終わらない形 (while :; do :; done) を走らせない。
    # for は、並べた語の数だけ回るので受ける。
    LOOP_NAMES = %w[while until].freeze
    # ruby は、渡された code をそのまま走らせる。code は、止める対象の process group から抜けられる
    # (Process.setsid)。受ける形を、code を走らせない -c と版の表示、file を渡す形に絞る。
    # -v は、後ろに code があると走らせるので、単独のときだけ受ける。
    RUBY_ALONE = [["-v"], ["--version"]].freeze
    # , を含む brace の前後に名前の字か別の brace が付く形と、brace の中の brace。{} (find の置き場所) は当たらない。
    BRACE_GLUED = /[A-Za-z0-9_}-]\{[^{}]*,[^{}]*\}|\{[^{}]*,[^{}]*\}[A-Za-z0-9_{-]|\{[^}]*\{/.freeze
    MAX_NESTING = 6

    def self.guard(command, scripts: SCRIPT_TABLE, dollar_forms: DOLLAR_FORMS)
      return "not-a-string" unless command.is_a?(String)
      return "encoding" unless command.valid_encoding?
      return "empty" if command.strip.empty?
      return "non-ascii-or-control" if command.match?(/[^\t\n\x20-\x7e]/)
      # 行の継続は、2 つの字を 1 つの語につなぐ (.\ と改行と . が .. になる)。
      return "line-continuation" if command.include?("\\\n")

      masked = mask_exemptions(command, scripts, dollar_forms)
      variables = dollar_variables(command, dollar_forms)
      # 引用と \ は、字をつないで別の語を作る ('.'./x は ../x、ta''il は tail)。原文と、引用の記号を
      # 除いた写しの両方に、同じ規則を当てる。
      [masked, masked.gsub(/['"\\]/, "")].each do |view|
        # 受けた形を置き換えた後に、その形が読む変数の名前が残っていれば、どこかで設定しうる。
        return "dollar-variable" if variables.any? { |name| view.include?(name) }

        reason = text_reason(view)
        return reason if reason
      end
      forbidden_reason(masked, 0)
    end

    # 表の形のうち、command に出てくるものが読む変数の名前。
    def self.dollar_variables(command, dollar_forms)
      used = dollar_forms.keys.select { |form| command.include?(form) }
      used.flat_map { |form| form.scan(/\$\{([A-Za-z_][A-Za-z0-9_]*)/).flatten }.uniq
    end

    def self.mask_exemptions(command, scripts, dollar_forms)
      out = command.dup
      scripts.each { |s| out = out.gsub("'#{s}'") { "'#{'_' * s.length}'" } }
      # 展開した後の語に置き換える。後ろに字が続く形 ($'-o'/x) は -o/x になり、option に付いた path として拒まれる。
      dollar_forms.each { |form, word| out = out.gsub(form) { word } }
      SAFE_REDIRECTS.sort_by { |r| -r.length }.each do |r|
        out = out.gsub(/#{Regexp.escape(r)}(?=[ \t\n;|&)]|\z)/) { " " * r.length }
      end
      out
    end

    # 字の並びで見る規則。一時 dir の外を指しうる形と、走るときに文字列を作る形を拒む。
    # / と = は、前が名前の字のときだけ通す (拒む字を並べると、>/x や {x,}/y や ={cat,x} を漏らす)。
    def self.text_reason(view)
      return "dotdot" if view.include?("..")
      return "tilde" if view.include?("~")
      # 走るときに文字列を作る形 ($、backtick、括弧) は、閉じた表の外では受けない。位置に依らない。
      # 括弧は、置き換え、subshell、zsh の glob の修飾子 (x(:A:h) は親の dir を指す) に当たる。
      return "dollar" if view.include?("$")
      return "backtick" if view.include?("`")
      return "paren" if view.match?(/[()]/)
      # && のほかの & (後ろで走らせる &、|&、>&3)。安全な redirect の & は、先に外してある。
      # 後ろで走る子は、shell が終わった時点で止められ、その後の書き込みが見えない。
      return "ampersand" if view.gsub("&&", "").include?("&")
      return "shell-option" if view.match?(SHELL_ENV)
      return "abs-path" if view.match?(%r{(?<![A-Za-z0-9_.*?\]-])/})
      # 短い option に付いた値 (-o/x、-C/x)。前の字が option の字なので、上の規則では見分けられない。
      return "option-path" if view.match?(%r{(?<![A-Za-z0-9_.*?\]/-])-[A-Za-z0-9]+/})
      # zsh は、語の先頭の =name を、その command の絶対 path に展開する (={cat,ruby} も)。
      return "equals-word" if view.match?(%r{(?<![A-Za-z0-9_.*?\]/-])=})
      # brace の展開は、. で終わる部分と . で始まる部分をつないで .. を作れる (.{.,a} や {a,}. の形)。
      return "brace-dot" if view.match?(/[{,]\.|\.[,}]|\{,|,,|,\}/)
      # 名前や option につないだ brace は、展開で別の語を作る (tail -{f,F} は -f と -F、{ta,x}il は tail)。
      # 入れ子の brace も、展開の後の語を追わずに拒む。
      return "brace-glued" if view.match?(BRACE_GLUED)
      # bash と sh の glob は、. で始まる pattern で .. にも当たる (.? や .*)。
      return "glob-dot" if view.match?(/(?<![A-Za-z0-9_*?\]-])\.[*?\[]/)

      nil
    end

    # 走らせない形 (network、端末、終わらない形、外の process への signal、shell の設定の変更)。語の位置に依らず、
    # 同じ部分の中の語の組で見る。引用か \ を含む語は、組み立てた後の中身を、入れ子の command (sh -c '…') として
    # 同じ規則で見る。引用の断片ごとに見ると、つないで出来る command を漏らす ('tail '"-f x" や set\ -m)。
    def self.forbidden_reason(text, depth)
      return "nesting" if depth > MAX_NESTING

      scanned = shell_words(text)
      if scanned.nil?
        return "unbalanced-quote" if depth.zero?

        # 引用の中身が command とは限らない (grep "it's")。閉じなければ、引用を除いて語に分ける。
        plain = text.gsub(/['"\\]/, "")
        scanned = [plain.split(/[|;&()`\n]/).map { |s| s.split(/[ \t{},<>]+/).reject(&:empty?) }, []]
      end
      segments, joined = scanned
      segments.each do |words|
        reason = segment_reason(words)
        return reason if reason
      end
      joined.each do |inner|
        reason = forbidden_reason(inner, depth + 1)
        return reason if reason
      end
      nil
    end

    def self.segment_reason(words)
      names = words.map { |w| File.basename(w) }
      after = ->(name) { (i = names.index(name)) ? words[(i + 1)..-1] : nil }
      # gh は network に出る。shim の canary に当たって、分類器の誤りでない印が付くのも防ぐ。
      return "gh" if names.include?("gh")
      return "git-remote" if names.include?("git") && words.include?("remote")
      # kill は shell の builtin で、一時 dir の外の process にも届く。
      return "signal" unless (names & SIGNAL_NAMES).empty?
      # 追従する tail は終わらない。束の中の f と F (-nF) と、古い書き方 (+5f) も拒む。
      return "tail-follow" if after.call("tail")&.any? { |w| w.match?(/\A[-+][^-]*[fF]/) || w.start_with?("--f") }
      return "find-ok" if after.call("find")&.any? { |w| %w[-ok -okdir].include?(w) }
      return "xargs-tty" if xargs_tty?(after.call("xargs"))
      return "cd-args" if DIR_BUILTINS.any? { |name| after.call(name)&.count { |w| !w.start_with?("-") }.to_i >= 2 }
      return "shell-option" unless (names & SHELL_SETTERS).empty?
      return "shell-option" if shell_option?(names, words)
      return "background" unless (names & BACKGROUND_NAMES).empty?
      return "loop" unless (names & LOOP_NAMES).empty?
      return "ruby-form" unless ruby_forms_ok?(words)
      return "awk-pipe" if awk_pipe?(words)

      nil
    end

    # 道具を指す語。前に = や ! が付いた形 (X=ruby、git の alias の !ruby) も、その道具の起動として見る。
    def self.tool_word?(word, tool)
      word.split(%r{[=!/]}, -1).last == tool
    end

    def self.ruby_word?(word)
      tool_word?(word, "ruby")
    end

    # awk は、program の中の pipe で command を起動する ("cmd" | getline、print | "cmd")。command の文字列は
    # program の中でつないで作れるので ("ru" "by -e …" で ruby が走った。実測)、| のある program を受けない。
    # system は括弧が要るので、括弧の規則が先に拒む。
    def self.awk_pipe?(words)
      words.each_index.any? { |i| tool_word?(words[i], "awk") && words[(i + 1)..-1].any? { |w| w.include?("|") } }
    end

    # ruby の後ろの語が、受ける形に収まるか。受けるのは、単独の -v と --version、-c と file の並び、
    # option の無い file の並び。code を渡す形 (-e)、library を読む形 (-r)、stdin の script (語が無い) は受けない。
    def self.ruby_forms_ok?(words)
      words.each_index.all? do |i|
        next true unless ruby_word?(words[i])

        rest = words[(i + 1)..-1]
        files = rest.first == "-c" ? rest.drop(1) : rest
        RUBY_ALONE.include?(rest) || (!rest.empty? && files.none? { |w| w.start_with?("-") })
      end
    end

    # 入れ子の shell に、表に無い option を渡す形。名前の直後に続く option の語だけを見る
    # (command の文字列より後ろの語は、shell の option ではない)。
    def self.shell_option?(names, words)
      names.each_index.any? do |i|
        next false unless SHELL_NAMES.include?(names[i])

        leading = words[(i + 1)..-1].take_while { |w| w.start_with?("-", "+") }
        !(leading - SHELL_OPTIONS).empty?
      end
    end

    # xargs の -p と -o (端末を開く)。xargs の option は utility の名前の前だけなので、そこまでを見る。
    def self.xargs_tty?(rest)
      return false unless rest

      k = 0
      while k < rest.length && rest[k].start_with?("-")
        word = rest[k]
        return true if word.match?(/\A-[^-]*[po]/) || %w[--interactive --open-tty].include?(word)

        # 値の語を読み飛ばす。- で始まる語は、値でも option として見る (拒む側に寄せる)。
        value = XARGS_VALUE_OPTIONS.include?(word) && rest[k + 1] && !rest[k + 1].start_with?("-")
        k += value ? 2 : 1
      end
      false
    end

    # 引用を追って語に分ける。戻り値は [部分ごとの語の並び, 引用か \ を含む語の並び]。引用が閉じなければ nil。
    # brace と , でも語を切る ({tail,-f} x は、展開の後の tail と -f を語として見る)。
    def self.shell_words(text)
      segments = [[]]
      joined = []
      word = nil
      glued = false
      flush = lambda do
        if word
          segments.last << word
          joined << word if glued
        end
        word = nil
        glued = false
      end
      i = 0
      while i < text.length
        c = text[i]
        if c == "'"
          j = text.index("'", i + 1)
          return nil unless j

          word = (word || +"") << text[(i + 1)...j]
          glued = true
          i = j + 1
        elsif c == '"'
          inner = +""
          j = i + 1
          while j < text.length && text[j] != '"'
            j += 1 if text[j] == "\\" && j + 1 < text.length
            inner << text[j]
            j += 1
          end
          return nil if j >= text.length

          word = (word || +"") << inner
          glued = true
          i = j + 1
        elsif c == "\\"
          word = (word || +"") << text[i + 1].to_s
          glued = true
          i += 2
        elsif "|;&()`\n".include?(c)
          flush.call
          segments << []
          i += 1
        elsif " \t{},<>".include?(c)
          flush.call
          i += 1
        else
          word = (word || +"") << c
          i += 1
        end
      end
      flush.call
      [segments, joined]
    end

    # --- preflight --------------------------------------------------------------------------
    # 隔離の否定の検査を、対照 (相手を許した profile で同じ probe が通る) と組にしてかける。
    # 対照が無いと、probe が壊れていて何も起きなかった回を「拒まれた」と読み違える。
    # negative と control は、検査が見た生の事実。ok はその組から決める。
    Check = Struct.new(:name, :ok, :negative, :control, keyword_init: true)
    # unavailable は、この環境で sandbox を適用できないこと (入れ子の sandbox の中など)。
    Preflight = Struct.new(:ok, :unavailable, :checks, :reasons, keyword_init: true)
    # 表に無い program の代表。対照で走っても、何も変えない。
    UNLISTED_PROGRAM = "/bin/date"
    PARENT_CANARY = "PROBE_CLASSIFIER_PARENT_CANARY"

    def self.preflight(session, hang_timeout: HANG_TIMEOUT)
      unless session.problems.empty?
        return Preflight.new(ok: false, unavailable: false, checks: [], reasons: session.problems.dup)
      end

      layouts = []
      outside = nil
      begin
        # template を作る前に、sandbox を適用できるかを見る (適用できない環境では、何も走らせずに返す)。
        probe = session.new_layout("pci-pre-")
        layouts << probe
        applied = session.run_argv(probe, ["/bin/sh", "-c", ":"])
        if applied.sandbox_error || applied.exit_code != 0
          return Preflight.new(ok: false, unavailable: sandbox_unavailable?(applied), checks: [],
                               reasons: ["sandbox-exec could not run a command under the profile: #{applied.err.strip}"])
        end

        layout = session.prepare
        layouts << layout
        outside = File.realpath(Dir.mktmpdir("pci-outside-", session.root))
        writes = session.prepare
        layouts << writes
        checks = [
          check_write_outside(session, layout, outside), check_read_home(session, layout, outside),
          check_network(session, layout), check_exec_outside(session, layout, outside),
          check_exec_fixture(session, layout), check_exec_unlisted(session, layout), check_signal_outside(session, layout),
          check_env_closed(session, layout), check_timeout_group(session, layout, hang_timeout),
          check_guard_only_write(session, writes, [outside, layout.base]), check_tools_work(session, layout),
        ]
        conclude(session, checks, layout)
      rescue Error, SystemCallError => e
        # 検査を組めなかった回も、理由を返して失敗にする (素の実行には戻らない)。
        Preflight.new(ok: false, unavailable: false, checks: [], reasons: [session.redact("#{e.class}: #{e.message}")])
      ensure
        layouts.each { |l| session.cleanup(l) }
        FileUtils.rm_rf(outside) if outside && inside?(outside, session.root)
      end
    end

    # 検査の結果から、preflight の結論を組む。通らない検査が 1 つでもあれば、ok は false。
    def self.conclude(session, checks, layout = nil)
      reasons = checks.reject(&:ok).map do |c|
        session.redact("#{c.name}: negative=#{c.negative.inspect} control=#{c.control.inspect}", layout)
      end
      Preflight.new(ok: reasons.empty?, unavailable: false, checks: checks, reasons: reasons)
    end

    def self.facts(run, extra = {})
      { exit: run.exit_code, timed_out: run.timed_out, err: run.err.strip[0, 400] }.merge(extra)
    end

    # 一時 dir の外 (別の一時 dir) への書き込み。
    def self.check_write_outside(session, layout, outside)
      target = File.join(outside, "leak.txt")
      argv = ["/bin/sh", "-c", ': > "$1"', "sh", target]
      neg = session.run_argv(layout, argv)
      negative = facts(neg, written: File.exist?(target))
      FileUtils.rm_f(target)
      ctl = session.run_argv(layout, argv, profile: session.profile_for(layout, allow_write: [outside]))
      control = facts(ctl, written: File.exist?(target))
      FileUtils.rm_f(target)
      Check.new(name: "write-outside", negative: negative, control: control,
                ok: !negative[:written] && neg.exit_code != 0 && control[:written])
    end

    # HOME の読み取り。本物の HOME ではなく、代役の dir を deny の一覧に足して確かめる。
    def self.check_read_home(session, layout, outside)
      standin = File.join(outside, "home-standin")
      FileUtils.mkdir_p(standin)
      secret = File.join(standin, "secret.txt")
      File.write(secret, "standin-secret\n")
      argv = ["/bin/cat", secret]
      neg = session.run_argv(layout, argv, profile: session.profile_for(layout, deny_read_extra: [standin]))
      ctl = session.run_argv(layout, argv)
      negative = facts(neg, read: neg.out.include?("standin-secret"))
      control = facts(ctl, read: ctl.out.include?("standin-secret"))
      Check.new(name: "read-home", negative: negative, control: control,
                ok: !negative[:read] && neg.exit_code != 0 && control[:read])
    end

    # network。自分で開いた 127.0.0.1 の port への接続が、待ち受けの側に届くかで見る。
    def self.check_network(session, layout)
      server = TCPServer.new("127.0.0.1", 0)
      argv = ["/bin/bash", "-c", 'exec 3<>"/dev/tcp/127.0.0.1/$1"', "bash", server.addr[1].to_s]
      arrived = lambda do |wait|
        next false unless IO.select([server], nil, nil, wait)

        server.accept_nonblock.close
        true
      end
      neg = session.run_argv(layout, argv)
      negative = facts(neg, connected: arrived.call(0.05))
      ctl = session.run_argv(layout, argv, profile: session.profile_for(layout, network: true))
      control = facts(ctl, connected: arrived.call(1))
      Check.new(name: "network", negative: negative, control: control,
                ok: !negative[:connected] && neg.exit_code != 0 && control[:connected])
    ensure
      server&.close
    end

    def self.probe_script(path, mark)
      File.write(path, "#!/bin/sh\n: > '#{mark}.'$$\n")
      File.chmod(0o755, path)
    end

    def self.marked?(layout, prefix)
      Dir.children(layout.marks).any? { |n| n.start_with?("#{prefix}.") }
    end

    def self.clear_marks(layout, prefix)
      Dir.children(layout.marks).each { |n| FileUtils.rm_f(File.join(layout.marks, n)) if n.start_with?("#{prefix}.") }
    end

    # allowlist の外に置いた偽の CLI。絶対 path でも PATH 経由でも走らない (印が書かれない)。
    def self.check_exec_outside(session, layout, outside)
      fake = File.join(outside, "fakecli")
      probe_script(fake, File.join(layout.marks, "probe.outside"))
      by_path = child_env(layout).merge("PATH" => "#{outside}:#{layout.shim}:#{layout.tools}")
      abs = session.run_argv(layout, ["/bin/sh", "-c", '"$1"', "sh", fake])
      via = session.run_argv(layout, ["/bin/sh", "-c", "fakecli"], env: by_path)
      negative = { abs: facts(abs), path: facts(via), ran: marked?(layout, "probe.outside") }
      clear_marks(layout, "probe.outside")
      ctl = session.run_argv(layout, ["/bin/sh", "-c", "fakecli"], env: by_path,
                                     profile: session.profile_for(layout, exec_extra: [fake]))
      control = facts(ctl, ran: marked?(layout, "probe.outside"))
      clear_marks(layout, "probe.outside")
      Check.new(name: "exec-outside", negative: negative, control: control,
                ok: !negative[:ran] && denied_exec?(abs) && denied_exec?(via) && control[:ran])
    end

    # fixture の中の、canary でない実行 file。一時 dir の全体に exec を許していれば走る。
    def self.check_exec_fixture(session, layout)
      file = File.join(layout.fx, "notcanary")
      probe_script(file, File.join(layout.marks, "probe.fixture"))
      neg = session.launch(layout, "./notcanary")
      negative = facts(neg, ran: marked?(layout, "probe.fixture"))
      clear_marks(layout, "probe.fixture")
      ctl = session.launch(layout, "./notcanary", profile: session.profile_for(layout, exec_extra: [file]))
      control = facts(ctl, ran: marked?(layout, "probe.fixture"))
      clear_marks(layout, "probe.fixture")
      FileUtils.rm_f(file)
      Check.new(name: "exec-fixture", negative: negative, control: control,
                ok: !negative[:ran] && denied_exec?(neg) && control[:ran])
    end

    # 表に無い program の起動が、3 つの shell のどれでも拒まれ、終わり方から見分けられる。
    def self.check_exec_unlisted(session, layout)
      allowed = session.profile_for(layout, exec_extra: [UNLISTED_PROGRAM])
      negative = {}
      control = {}
      ok = true
      VARIANTS.select(&:default).each do |v|
        neg = session.launch(layout, UNLISTED_PROGRAM, variant: v.name)
        ctl = session.launch(layout, UNLISTED_PROGRAM, variant: v.name, profile: allowed)
        negative[v.name] = facts(neg)
        control[v.name] = facts(ctl)
        ok &&= denied_exec?(neg) && neg.exit_code == (v.base == "zsh" ? 127 : 126) && ctl.exit_code == 0
      end
      Check.new(name: "exec-unlisted", negative: negative, control: control, ok: ok)
    end

    # 外の process への signal。この runner 自身に signal 0 を送って見る (届いても何も止めない)。
    def self.check_signal_outside(session, layout)
      argv = ["/bin/sh", "-c", 'kill -0 "$1"', "sh", Process.pid.to_s]
      neg = session.run_argv(layout, argv)
      ctl = session.run_argv(layout, argv, profile: session.profile_for(layout, signals: true))
      Check.new(name: "signal-outside", negative: facts(neg), control: facts(ctl),
                ok: neg.exit_code == 1 && neg.err.match?(DENIED_EXEC) && ctl.exit_code == 0)
    end

    def self.env_keys(text)
      text.lines.map { |l| l.split("=", 2).first.to_s.strip }.reject(&:empty?)
    end

    # 親に立てた環境の変数が子に渡らない。対照は、同じ表を渡して引き継ぎだけを許した起動で、同じ変数が見えること。
    def self.check_env_closed(session, layout)
      neg = ctl = nil
      with_parent_env(PARENT_CANARY => "1") do
        neg = session.launch(layout, "env")
        ctl = session.launch(layout, "env", inherit_env: true)
      end
      extra = env_keys(neg.out) - ENV_KEYS - SHELL_KEYS
      negative = facts(neg, extra: extra)
      control = facts(ctl, leaked: env_keys(ctl.out).include?(PARENT_CANARY))
      Check.new(name: "env-closed", negative: negative, control: control,
                ok: neg.exit_code == 0 && extra.empty? && control[:leaked])
    end

    # 生きている group を「空でない」と読めること (いつも「空」と答える検査を通さないための対照)。
    def self.live_group_control
      reader, writer = IO.pipe
      pid = Process.spawn("/bin/sh", "-c", "read x", in: reader, out: File::NULL, err: File::NULL, pgroup: true)
      reader.close
      live = group_empty?(pid, tries: 2)
      writer.close
      Process.wait(pid)
      { live_reported_empty: live, exited_reported_empty: group_empty?(pid) }
    ensure
      [reader, writer].each { |io| io.close if io && !io.closed? }
    end

    # 終わらない command が期限で止まり、止めた後に子の group が残らない。
    # 「; :」は、shell が tail に置き換わらず、子として tail を持つ形にするため。
    def self.check_timeout_group(session, layout, hang_timeout)
      started = Time.now
      neg = session.launch(layout, "tail -f in.txt; :", variant: "sh", timeout: hang_timeout)
      elapsed = Time.now - started
      # 対照は自分で終わる。期限は既定のままにする (混んだ machine で、短い期限に掛けないため)。
      ctl = session.launch(layout, "tail -n 1 in.txt; :", variant: "sh")
      group = live_group_control
      # 渡した期限で止まること。既定の期限まで待っていれば、ここで落ちる。
      in_time = elapsed < hang_timeout + ProbeChild::TERM_GRACE + HANG_MARGIN
      negative = facts(neg, group_empty: neg.group_empty, in_time: in_time)
      control = facts(ctl, group_empty: ctl.group_empty).merge(group)
      Check.new(name: "timeout-group", negative: negative, control: control,
                ok: neg.timed_out && in_time && neg.group_empty && !ctl.timed_out && ctl.exit_code == 0 && ctl.group_empty &&
                    !group[:live_reported_empty] && group[:exited_reported_empty])
    end

    def self.tree_listing(dir)
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
        stat = File.lstat(path)
        [path, stat.size, stat.mtime.to_f, stat.mode]
      end
    end

    # sandbox を外した profile で、語彙の中の書き込みの変化が一時 dir の中に閉じる (guard の層だけの確かめ)。
    def self.check_guard_only_write(session, layout, watched)
      command = "sort -o out.txt in.txt"
      before = watched.map { |dir| tree_listing(dir) }
      run = session.launch(layout, command, profile: OPEN_PROFILE)
      after = watched.map { |dir| tree_listing(dir) }
      negative = facts(run, guard: guard(command), inside: File.file?(File.join(layout.fx, "out.txt")),
                            outside_changed: before != after)
      Check.new(name: "guard-only-write", negative: negative, control: {},
                ok: negative[:guard].nil? && run.exit_code == 0 && negative[:inside] && !negative[:outside_changed])
    end

    # 表の道具が隔離の中で動き、canary が走ると印が書かれる (全部が拒まれて「違反なし」に見える回を防ぐ)。
    # 道具が拒否の字面を stderr に出さないことも見る。出す道具があると、その道具を使う read の command が
    # 毎回「拒まれた起動」として人に出て、本物の拒否と見分けられなくなる。
    def self.check_tools_work(session, layout)
      expect = {
        "cat in.txt" => FIXTURE_SECOND.fetch("in.txt"),
        # canary は template を写した後に書くので、git からは追跡していない file に見える。
        "git status --short" => " M README.md\n?? bin/\n?? canary_begin.rb\n?? cat\n",
        "ruby -c lib/median.rb" => "Syntax OK\n",
        "zsh -lc 'cat in.txt'" => FIXTURE_SECOND.fetch("in.txt"),
      }
      negative = {}
      ok = true
      expect.each do |command, out|
        run = session.launch(layout, command)
        negative[command] = facts(run, out: run.out[0, 80])
        ok &&= run.exit_code == 0 && run.out == out && !run.err.match?(DENIED_EXEC)
      end
      canary_run = session.launch(layout, "canary")
      hits = read_marks(layout).hits
      negative["canary"] = facts(canary_run, hits: hits.keys)
      Check.new(name: "tools-work", negative: negative, control: {}, ok: ok && hits["shim.canary"] == 1)
    end
  end
end
