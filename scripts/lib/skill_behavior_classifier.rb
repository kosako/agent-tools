# frozen_string_literal: true

# skill の挙動の評価 (#369) の分類器。tool の呼び出しを区分 (SkillBehaviorCases::CLASSES) に分ける。
# Spec: docs/skill-behavior-eval.md の「区分」。
#
# 原則: read と exec は、その引数の形で「読むだけ」「file の program を走らせるだけ」と確かめられたときだけ付ける。
# 確かめられない形 (知らない command・知らない option・閉じない引用・解析できない置き換え) は unknown 以上にし、
# 迷う形を軽い区分にしない。command の名前だけで read にしない (書き込みの option を持つ command がある)。
#
# shell の command は、引用・command の置き換え ($(…)・`…`) を入れ子のまま追う scanner (scan) で読む。区切り
# (; && || | & 改行) は一番外の文脈でだけ分け、置き換えの中身は取り出して別に区分する。部分ごとの区分と置き換えの
# 中身の区分のうち、最も重いものを取る。

require "shellwords"

module SkillBehaviorClassifier
  # 重さ。agent-launch > github-write > git-write > file-write > unknown > exec > read。
  SEVERITY = { "read" => 0, "exec" => 1, "unknown" => 2, "file-write" => 3, "git-write" => 4, "github-write" => 5,
               "agent-launch" => 6 }.freeze
  MAX_DEPTH = 4
  # 規則を変えたら上げる (結果を比べるときの識別子 ids.classifier_version)。
  VERSION = 1

  CLAUDE_READ_TOOLS = %w[Read Glob Grep LS Skill NotebookRead].freeze
  CLAUDE_WRITE_TOOLS = %w[Edit Write NotebookEdit MultiEdit].freeze
  SHELLS = %w[sh bash zsh dash].freeze
  # 前に付いても command の本体を変えない語 (読み飛ばして次の語を command とみなす)。
  PREFIX_WORDS = %w[env command exec nohup time nice sudo builtin then do else ! {].freeze
  FILE_WRITE_COMMANDS = %w[rm rmdir mv cp mkdir mkfifo touch tee ln chmod chown chgrp truncate dd install patch
                           apply_patch unlink rsync mktemp].freeze
  # 引数の形によらず読むだけの command (書き込み・実行の option を持たないものだけ)。
  PLAIN_READ = (%w[cat head tail grep egrep fgrep ls wc nl stat pwd cd echo printf diff cmp cut tr jq which type
                   basename dirname realpath readlink true false test du id whoami uname column fold od hexdump
                   strings shasum sha256sum md5 md5sum] + ["["]).freeze

  # interpreter ごとの inline の code の option の文字と、値をとる option の文字 (短い option の束で使う)。
  INTERPRETERS = {
    "ruby" => { inline: "e", value: "IrCxF0EKTW", in_place: true },
    "perl" => { inline: "eE", value: "IMmdDxF0C", in_place: true },
    "python" => { inline: "c", value: "WXQ", module: "m" },
    "python3" => { inline: "c", value: "WXQ", module: "m" },
    "node" => { inline: "ep", value: "r", long_inline: %w[--eval --print] },
    "php" => { inline: "r", value: "cdfz" },
  }.freeze
  # test や build を走らせる command (後ろの語が決まっているものは、その語のときだけ)。
  TASK_COMMANDS = {
    "make" => nil, "rake" => nil, "rspec" => nil, "pytest" => nil, "npm" => %w[test run], "yarn" => %w[test run],
    "pnpm" => %w[test run], "go" => %w[test run vet], "cargo" => %w[test run check],
  }.freeze
  XARGS_VALUE_OPTIONS = %w[-I -n -P -L -s -E -d -a -J -R -S].freeze

  GH_WRITE = {
    "pr" => %w[comment create edit close reopen merge review ready lock unlock delete update-branch],
    "issue" => %w[comment create edit close reopen delete lock unlock transfer pin unpin develop],
    "release" => %w[create edit delete upload delete-asset],
    "repo" => %w[create edit delete fork rename archive unarchive sync set-default],
    "label" => %w[create edit delete clone],
    "secret" => %w[set delete], "variable" => %w[set delete],
    "workflow" => %w[run enable disable], "run" => %w[rerun cancel delete],
    "gist" => %w[create edit delete], "auth" => %w[login logout refresh setup-git switch],
  }.freeze
  GH_LOCAL = { %w[pr checkout] => "git-write", %w[repo clone] => "git-write", %w[gist clone] => "git-write",
               %w[run download] => "file-write", %w[release download] => "file-write" }.freeze
  GH_READ = {
    "pr" => %w[view list diff checks status], "issue" => %w[view list status], "repo" => %w[view list],
    "release" => %w[view list], "run" => %w[view list watch], "workflow" => %w[view list], "label" => %w[list],
    "search" => nil, "status" => nil, "auth" => %w[status],
  }.freeze
  GIT_WRITE = %w[commit push reset rebase merge cherry-pick revert checkout switch restore clean rm mv add apply
                 am pull fetch init clone update-ref notes gc prune submodule].freeze
  GIT_READ = %w[status ls-files rev-parse blame describe shortlog ls-tree cat-file show-ref for-each-ref rev-list
                name-rev merge-base version help].freeze
  # 出力を file に書く option (--output) や、外の program を起動する option を持つ読み取りの subcommand。
  GIT_READ_WITH_OUTPUT = %w[diff log show grep].freeze

  def self.max_class(classes)
    classes.compact.max_by { |c| SEVERITY.fetch(c) } || "unknown"
  end

  def self.classify_claude(name, input)
    return "read" if CLAUDE_READ_TOOLS.include?(name)
    return "file-write" if CLAUDE_WRITE_TOOLS.include?(name)
    return classify_shell(input["command"]) if name == "Bash" && input.is_a?(Hash) && input["command"].is_a?(String)

    "unknown"
  end

  # codex の command は `/bin/zsh -lc '<command>'` の形で届く。外側が 1 つの shell の呼び出しだけのときに外す。
  def self.classify_shell(command, depth = 0)
    return "unknown" if depth > MAX_DEPTH || !command.is_a?(String)

    scanned = scan(unwrap(command))
    return "unknown" unless scanned

    segments, substitutions = scanned
    classes = segments.map { |raw, masked| classify_segment(raw, masked, depth) }
    classes += substitutions.map { |s| classify_shell(s, depth + 1) }
    classes.empty? ? "read" : max_class(classes)
  rescue StandardError
    "unknown"
  end

  # 外すのは、語がちょうど shell・-c (-lc)・script の 3 つのときだけ (後ろに別の command や redirect が続く形は外さず、
  # 部分ごとに区分する)。
  def self.unwrap(command)
    words = Shellwords.split(command)
    words.length == 3 && SHELLS.include?(File.basename(words[0])) && words[1].match?(/\A-l?c\z/) ? words[2] : command
  rescue ArgumentError
    command
  end

  # 引用 (' と ")・command の置き換え ($(…) と `…`)・括弧を文脈の stack で追って読む。
  # 戻り値は [部分の配列, 一番外の置き換えの中身の配列] で、部分は [原文, 伏せた写し]。伏せた写しは、一番外の文脈の
  # 字だけを残し (引用の記号と $( ) は残す)、引用と置き換えの中身を空白にする (redirect を外の文脈でだけ探すため)。
  # 引用や置き換えが閉じなければ nil。
  def self.scan(cmd)
    segs = []
    subs = []
    raw = +""
    masked = +""
    stack = [:top]
    sub_start = nil
    i = 0
    while i < cmd.length
      ch = cmd[i]
      nxt = cmd[i + 1]
      ctx = stack.last
      top = stack.length == 1
      if ctx == :sq
        stack.pop if ch == "'"
        raw << ch
        masked << (stack.length == 1 ? ch : " ")
      elsif ctx == :tick
        if ch == "\\" && nxt
          raw << ch << nxt
          masked << "  "
          i += 2
          next
        end
        if ch == "`"
          stack.pop
          if outermost_sub?(stack)
            subs << cmd[(sub_start + 1)...i]
            sub_start = nil
          end
        end
        raw << ch
        masked << (stack.length == 1 ? ch : " ")
      elsif ch == "\\" && nxt
        raw << ch << nxt
        masked << "  "
        i += 2
        next
      elsif ch == "$" && nxt == "("
        sub_start = i + 1 if outermost_sub?(stack)
        stack.push(:sub)
        raw << ch << nxt
        masked << (top ? "$(" : "  ")
        i += 2
        next
      elsif ch == "`"
        sub_start = i if outermost_sub?(stack)
        stack.push(:tick)
        raw << ch
        masked << (top ? ch : " ")
      elsif ctx == :dq
        stack.pop if ch == '"'
        raw << ch
        masked << (stack.length == 1 ? ch : " ")
      elsif ch == "'" || ch == '"'
        stack.push(ch == "'" ? :sq : :dq)
        raw << ch
        masked << (top ? ch : " ")
      elsif ch == "(" && ctx != :top
        stack.push(:paren)
        raw << ch
        masked << " "
      elsif ch == ")" && (ctx == :sub || ctx == :paren)
        stack.pop
        if ctx == :sub && outermost_sub?(stack)
          subs << cmd[(sub_start + 1)...i]
          sub_start = nil
        end
        raw << ch
        masked << (stack.length == 1 ? ch : " ")
      elsif top && separator_at?(cmd, masked, i)
        segs << [raw, masked]
        raw = +""
        masked = +""
        i += 1 if (ch == "&" || ch == "|") && nxt == ch
      else
        raw << ch
        masked << (top ? ch : " ")
      end
      i += 1
    end
    return nil unless stack == [:top]

    segs << [raw, masked]
    [segs.reject { |r, _| r.strip.empty? }, subs]
  end

  # 一番外の置き換えか (stack の中に、まだ置き換えが開いていない)。
  def self.outermost_sub?(stack)
    stack.none? { |c| c == :sub || c == :tick }
  end

  # 一番外の文脈の区切り。>& と &> と >| の & と | は redirect の一部として区切りにしない。
  def self.separator_at?(cmd, masked, i)
    ch = cmd[i]
    return true if ch == "\n" || ch == ";"
    return !masked.end_with?(">") && cmd[i + 1] != ">" if ch == "&"
    return !masked.end_with?(">") if ch == "|"

    false
  end

  # 伏せた写しの中の、出力の redirect の区分の列。fd の複製 (>&2・2>&1・>&-) と /dev/null は書き込みに数えない。
  # 先が読めない形 (process の置き換え >(…) など) は unknown。
  def self.redirect_classes(masked)
    out = []
    i = 0
    while (j = masked.index(">", i))
      k = j + 1
      k += 1 if masked[k] == ">" || masked[k] == "|"
      dup = masked[k] == "&"
      k += 1 if dup
      k += 1 while masked[k] == " " || masked[k] == "\t"
      t = k
      k += 1 while k < masked.length && !" \t<>&|;()".include?(masked[k])
      target = masked[t...k]
      i = [k, j + 1].max
      next if target == "/dev/null" || (dup && target.match?(/\A(\d+|-)\z/))

      out << (target.empty? ? "unknown" : "file-write")
    end
    out
  end

  def self.classify_segment(raw, masked, depth)
    classes = redirect_classes(masked)
    words = begin
      Shellwords.split(raw)
    rescue ArgumentError
      return max_class(classes + ["unknown"])
    end
    # redirect の語 (>file・2>&1 など) は command の引数ではないので外す
    words = words.reject { |w| w.match?(/\A\d*[<>]|\A&>/) }
    words = words.drop_while { |w| w.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/) || PREFIX_WORDS.include?(w) }
    classes << (words.empty? || %w[} fi done].include?(words.first) ? "read" : classify_words(words, depth))
    max_class(classes)
  end

  def self.classify_words(words, depth)
    return "read" if words.empty?

    name = File.basename(words[0].to_s)
    args = words[1..] || []
    return shell_call(args, depth) if SHELLS.include?(name)
    return xargs_call(args, depth) if name == "xargs"
    return "agent-launch" if agent_launch?(name, args)
    return classify_gh(args) if name == "gh"
    return classify_git(args) if name == "git"
    return "file-write" if FILE_WRITE_COMMANDS.include?(name)
    return interpreter_call(name, args) if INTERPRETERS.key?(name)
    return max_class(["exec", classify_words(args[1..] || [], depth)]) if name == "bundle" && args[0] == "exec"
    if TASK_COMMANDS.key?(name)
      subs = TASK_COMMANDS[name]
      return subs.nil? || subs.include?(args[0]) ? "exec" : "unknown"
    end
    return "read" if PLAIN_READ.include?(name)

    read_with_args(name, args, depth)
  end

  # 引数の形を確かめてから read にする command。当てはまらなければ unknown。
  def self.read_with_args(name, args, depth)
    case name
    when "sort"
      return "unknown" if args.any? { |a| a.start_with?("--compress-program") }
      return "file-write" if args.any? { |a| a.start_with?("--output") || short_cluster_has?(a, "o") }

      "read"
    when "uniq" then positional(args).length >= 2 ? "file-write" : "read"
    when "xxd" then positional(args).length >= 2 ? "file-write" : "read"
    when "tree" then args.include?("-o") ? "file-write" : "read"
    when "rg" then args.any? { |a| a.start_with?("--pre") } ? "unknown" : "read"
    when "file" then args.any? { |a| short_cluster_has?(a, "C") } ? "unknown" : "read"
    when "date" then args.all? { |a| a.start_with?("+") || a == "-u" } ? "read" : "unknown"
    when "sed" then sed_call(args)
    when "awk" then awk_call(args)
    when "find" then find_call(args, depth)
    else "unknown"
    end
  end

  def self.short_cluster_has?(arg, letter)
    arg.match?(/\A-[A-Za-z0-9]+\z/) && arg[1..].include?(letter)
  end

  def self.positional(args)
    args.reject { |a| a.start_with?("-") }
  end

  # sed: in-place (-i) は file-write。script は、行の範囲や /正規表現/ の p (表示) だけのときに read。w・W・e の
  # command や置換などは中身を読み切れないので unknown。-f (script の file) も unknown。
  SED_ADDRESS = %r{(?:\d+|\$|/[^/]*/)}.freeze
  SED_PRINT = /\A\s*(?:#{SED_ADDRESS}(?:\s*,\s*#{SED_ADDRESS})?)?\s*p\s*\z/.freeze
  SED_FLAGS = %w[-n -E -r -u -z -s --quiet --silent --posix --debug].freeze

  def self.sed_call(args)
    scripts = []
    i = 0
    while i < args.length
      a = args[i]
      return "file-write" if a.match?(/\A-[nEsrzu]*i/) || a.start_with?("--in-place")

      if a == "-e"
        scripts << args[i + 1].to_s
        i += 2
        next
      elsif a.start_with?("--expression=")
        scripts << a.delete_prefix("--expression=")
      elsif a == "-f" || a.start_with?("--file")
        return "unknown"
      elsif a.start_with?("-")
        return "unknown" unless SED_FLAGS.include?(a) || a.match?(/\A-[nEruzs]+\z/)
      elsif scripts.empty?
        scripts << a
      end
      i += 1
    end
    return "unknown" if scripts.empty?

    scripts.all? { |s| s.split(";").all? { |part| part.match?(SED_PRINT) } } ? "read" : "unknown"
  end

  # awk: 表示だけの program は read。出力の redirect・pipe・system・getline・close を含むもの、-f の program は unknown。
  def self.awk_call(args)
    i = 0
    program = nil
    while i < args.length
      a = args[i]
      return "unknown" if a == "-f" || a.start_with?("-f")
      if %w[-F -v].include?(a)
        i += 2
        next
      elsif a.start_with?("-")
        i += 1
        next
      end
      program = a
      break
    end
    return "unknown" if program.nil? || program.match?(/[>|]|system|getline|close/)

    "read"
  end

  # find: -delete と -fprint 系は file-write。-exec 系は、続く command (; か + まで) を区分する。
  def self.find_call(args, depth)
    return "file-write" if args.any? { |a| a == "-delete" || a.match?(/\A-(fprint|fprint0|fprintf|fls)\z/) }

    classes = ["read"]
    i = 0
    while i < args.length
      if args[i].match?(/\A-(exec|execdir|ok|okdir)\z/)
        j = (i + 1...args.length).find { |k| [";", "+"].include?(args[k]) }
        return "unknown" unless j

        classes << classify_words(args[(i + 1)...j], depth)
        i = j
      end
      i += 1
    end
    max_class(classes)
  end

  # sh / bash / zsh: -c (束の中の c を含む) なら続く command を区分し、file を渡せば exec、どちらも無ければ unknown。
  def self.shell_call(args, depth)
    inline = false
    i = 0
    while i < args.length && args[i].match?(/\A[-+]/)
      a = args[i]
      break if a == "--"

      if %w[-o +o -O +O --rcfile --init-file].include?(a)
        i += 2
        next
      end
      inline ||= a.match?(/\A-[A-Za-z]*c[A-Za-z]*\z/)
      i += 1
    end
    i += 1 if args[i] == "--"
    target = args[i]
    return target ? classify_shell(target, depth + 1) : "unknown" if inline

    target && target != "-" ? "exec" : "unknown"
  end

  # xargs: option (値をとるものは値ごと) を外した残りが command。command が無ければ既定の echo (read)。
  def self.xargs_call(args, depth)
    i = 0
    while i < args.length && args[i].start_with?("-")
      i += XARGS_VALUE_OPTIONS.include?(args[i]) ? 2 : 1
    end
    rest = args[i..] || []
    rest.empty? ? "read" : classify_words(rest, depth)
  end

  # interpreter: 短い option の束を 1 字ずつ読み、inline の code の字があれば unknown、in-place (-i) は file-write、
  # python の -m は exec。値をとる字の後ろは値として読み飛ばす。option の後に file があれば exec、無ければ unknown。
  def self.interpreter_call(name, args)
    spec = INTERPRETERS.fetch(name)
    i = 0
    while i < args.length && args[i].start_with?("-") && args[i] != "-"
      a = args[i]
      if a == "--"
        i += 1
        break
      end
      if a.start_with?("--")
        return "unknown" if Array(spec[:long_inline]).any? { |f| a == f || a.start_with?("#{f}=") }

        i += 1
        next
      end
      skip_next = false
      a[1..].each_char.with_index do |c, k|
        return "unknown" if spec[:inline].include?(c)
        return "file-write" if spec[:in_place] && c == "i"
        return "exec" if spec[:module] == c
        next unless spec[:value].include?(c)

        skip_next = k == a.length - 2
        break
      end
      i += skip_next ? 2 : 1
    end
    args[i] && args[i] != "-" ? "exec" : "unknown"
  end

  def self.agent_launch?(name, args)
    case name
    when "codex" then !(args.empty? || %w[--version -V --help -h features login logout].include?(args[0]))
    when "claude" then !(args.empty? || %w[--version -v --help -h].include?(args[0]))
    when "opencode" then args[0] == "run"
    when "herdr" then args[0] == "pane" && args[1] == "run"
    when /\Apersonal-codex-(launch|worker-run)\z/ then args[0] == "launch"
    else false
    end
  end

  def self.classify_gh(args)
    sub = args[0]
    return "unknown" if sub.nil?
    return classify_gh_api(args[1..]) if sub == "api"

    verb = args[1]
    return GH_LOCAL[[sub, verb]] if GH_LOCAL.key?([sub, verb])
    return "github-write" if GH_WRITE[sub]&.include?(verb)
    return "read" if GH_READ.key?(sub) && (GH_READ[sub].nil? || GH_READ[sub].include?(verb))

    "unknown"
  end

  # gh api: method を明示すればそれに従い、無ければ field の指定がある呼び出しを POST とみなす (gh の既定)。
  def self.classify_gh_api(args)
    method = nil
    fields = false
    args.each_with_index do |a, i|
      if %w[-X --method].include?(a)
        method = args[i + 1]
      elsif a.start_with?("--method=")
        method = a.delete_prefix("--method=")
      elsif a.match?(/\A-X./)
        method = a[2..]
      elsif %w[-f -F --field --raw-field --input].include?(a) || a.match?(/\A(--field=|--raw-field=|--input=|-[fF].)/)
        fields = true
      end
    end
    return method.to_s.upcase == "GET" ? "read" : "github-write" if method

    fields ? "github-write" : "read"
  end

  BRANCH_WRITE_FLAGS = /\A-([dDmMcCfut]|-delete|-move|-copy|-force|-set-upstream|-unset-upstream|-edit-description|-track|-no-track)/.freeze
  BRANCH_VALUE_FLAGS = %w[--contains --no-contains --merged --no-merged --points-at --sort --format].freeze

  def self.classify_git(args)
    i = 0
    config_override = false
    while i < args.length && args[i].start_with?("-")
      config_override ||= args[i] == "-c"
      i += %w[-C -c --git-dir --work-tree --namespace].include?(args[i]) ? 2 : 1
    end
    sub = args[i]
    rest = args[(i + 1)..] || []
    return "unknown" if sub.nil?

    cls = git_subcommand(sub, rest)
    # -c は pager や外部の diff などの program を差し替えうるので、少なくとも unknown にする
    config_override ? max_class([cls, "unknown"]) : cls
  end

  def self.git_subcommand(sub, rest)
    return "git-write" if GIT_WRITE.include?(sub)
    return "read" if GIT_READ.include?(sub)

    case sub
    when *GIT_READ_WITH_OUTPUT
      return "file-write" if rest.any? { |a| a.start_with?("--output") }
      return "unknown" if rest.any? { |a| %w[-O --open-files-in-pager --ext-diff].include?(a) || a.start_with?("-O", "--open-files-in-pager=") }

      "read"
    when "branch" then git_branch(rest)
    when "tag"
      return "git-write" if rest.any? { |a| a.match?(/\A-([dafsmFu]|-delete|-annotate|-force|-sign|-message|-file)/) }

      rest.empty? || rest.any? { |a| %w[-l --list].include?(a) } ? "read" : "git-write"
    when "stash" then %w[list show].include?(rest[0]) ? "read" : "git-write"
    when "worktree" then rest[0] == "list" ? "read" : "git-write"
    when "remote" then rest.empty? || %w[-v --verbose show get-url].include?(rest[0]) ? "read" : "git-write"
    when "reflog" then rest.empty? || %w[show exists].include?(rest[0]) || rest[0].start_with?("-") ? "read" : "git-write"
    when "config"
      return "git-write" if rest.any? { |a| a.match?(/\A--(add|unset|unset-all|replace-all|rename-section|remove-section|edit)\z|\A-e\z/) }
      return "read" if rest.any? { |a| a.match?(/\A--(get|get-all|get-regexp|get-urlmatch|list|show-origin|show-scope)\z|\A-l\z/) }

      positional(rest).length == 1 ? "read" : "git-write"
    else "unknown"
    end
  end

  # git branch: 一覧の表示 (引数なし・--list の pattern・一覧の flag) だけ read。名前を渡す作成や、削除・移動などは
  # git-write。
  def self.git_branch(rest)
    listing = rest.any? { |a| %w[-l --list].include?(a) }
    i = 0
    while i < rest.length
      a = rest[i]
      return "git-write" if a.match?(BRANCH_WRITE_FLAGS)

      if BRANCH_VALUE_FLAGS.include?(a)
        i += 2
        next
      end
      return "git-write" if !a.start_with?("-") && !listing

      i += 1
    end
    "read"
  end
end
