# frozen_string_literal: true

# skill の挙動の評価 (#369) の分類器。tool の呼び出しを区分 (SkillBehaviorCases::CLASSES) に分ける。
# Spec: docs/skill-behavior-eval.md の「区分」。
#
# 原則 (fail-closed): read と exec は、その引数の形で「読むだけ」「file の program を走らせるだけ」と確かめられた
# ときだけ付ける。確かめられない形 (知らない command・spec に無い option・閉じない引用や here document・解析できない
# 置き換え) は unknown 以上にし、迷う形を軽い区分にしない。
#
# shell の command は scanner (scan) が読む。引用・command の置き換え ($(…)・`…`)・process の置き換え (<(…)・>(…))・
# comment・here document・ANSI-C の引用 ($'…') を文脈の stack で追い、区切り (; && || | & 改行) は一番外の文脈でだけ分ける。置き換えの中身は
# 取り出して別に区分し、部分ごとの区分と合わせて最も重いものを取る。外側の shell (`/bin/zsh -lc '…'`) は外さず、
# shell の呼び出しとして読む (外の文脈の置き換えも区分するため)。option は spec を読む共通の部品 (parse_options) で読む。

require "ripper"
require "shellwords"

module SkillBehaviorClassifier
  # 重さ。agent-launch > github-write > git-write > file-write > unknown > exec > read。
  SEVERITY = { "read" => 0, "exec" => 1, "unknown" => 2, "file-write" => 3, "git-write" => 4, "github-write" => 5,
               "agent-launch" => 6 }.freeze
  MAX_DEPTH = 6
  # 規則を変えたら上げる (結果を比べるときの識別子 ids.classifier_version)。2 で inline の Ruby (ruby -e) を足した (#737)。
  # 3 で、門の二重引用の \" と \\、ほかの引数の無い ruby -v と ruby --version を足した (#742)。
  # 4 で、inline の Ruby の -r に、-I が 1 つのときの fixture の名前を足した (#742)。
  # 5 で、ruby -c FILE と、inline の Ruby の code の中の require "./…" を足した (#745)。
  # 6 で、引用の外の受ける形の brace の展開を足した (#745)。
  # 7 で、rg の位置引数にある、決めた形の引用の外の glob の語を足した (#750)。
  # 8 で、引用の外の ^ を glob の字に足した (#751)。
  # 9 で、uniq の位置引数の後ろ (#755)、sed の番地の \ (#756)、git の一覧の印 (#757) の読み方を、実物に合わせた。
  VERSION = 9

  CLAUDE_READ_TOOLS = %w[Read Glob Grep LS Skill NotebookRead].freeze
  CLAUDE_WRITE_TOOLS = %w[Edit Write NotebookEdit MultiEdit].freeze
  SHELLS = %w[sh bash zsh dash].freeze
  # 前に付いても command の本体を変えない語 (読み飛ばして次の語を command とみなす)。
  PREFIX_WORDS = %w[env command exec nohup time nice builtin then do else ! {].freeze
  # command の名前に path が付くとき、名前で区分してよい directory (ほかの path は project の file などを実行する)。
  STANDARD_BIN_DIRS = %w[/bin /usr/bin /usr/local/bin /opt/homebrew/bin /usr/sbin /sbin].freeze
  # exec にする script の拡張子 (interpreter と shell ごと)。拡張子の無い path (/dev/stdin・/dev/fd/0、cd の後の
  # dev/stdin など) は、書き方によらず file の program と確かめられないので exec にしない。
  SCRIPT_EXTENSIONS = {
    "ruby" => %w[.rb], "perl" => %w[.pl], "python" => %w[.py], "python3" => %w[.py], "node" => %w[.js .mjs .cjs],
    "sh" => %w[.sh], "bash" => %w[.sh .bash], "zsh" => %w[.sh .zsh], "dash" => %w[.sh],
  }.freeze
  FILE_WRITE_COMMANDS = %w[rm rmdir mv cp mkdir mkfifo touch tee ln chmod chown chgrp truncate dd install patch
                           apply_patch unlink rsync mktemp].freeze
  # どの option でも書き込み・program の起動をしない command (option を確かめずに read)。
  PLAIN_READ = %w[cat head tail grep egrep fgrep ls wc nl stat pwd cd echo cmp cut tr jq which type basename dirname
                  realpath readlink true false du id whoami uname column fold od hexdump strings shasum sha256sum md5
                  md5sum].freeze

  # option の spec。flags は値をとらない短い option、values は値をとる短い option (束の残りか次の語)、long_flags /
  # long_values は長い option。spec に無い option があれば parse_options は nil を返す。
  SORT_SPEC = { flags: "bcdfghiMmnRrsuVz", values: "kotST",
                long_flags: %w[--numeric-sort --reverse --unique --ignore-case --human-numeric-sort --version-sort
                               --stable --general-numeric-sort --month-sort --dictionary-order
                               --ignore-leading-blanks --check --merge --zero-terminated --random-sort],
                long_values: %w[--key --field-separator --output --buffer-size --temporary-directory --parallel
                                --sort --batch-size --compress-program --files0-from --random-source] }.freeze
  # rg: program を起動する option (--pre・--hostname-bin・-z の展開) は spec に入れない (unknown になる)。
  RG_SPEC = { flags: "nilcwFSsvuHhqoxLN", values: "egtTABCmM",
              long_flags: %w[--files --hidden --no-ignore --line-number --no-line-number --no-heading --heading
                             --fixed-strings --ignore-case --smart-case --case-sensitive --count --files-with-matches
                             --files-without-match --word-regexp --line-regexp --invert-match --json --vimgrep
                             --no-messages --follow --multiline --only-matching --type-list --with-filename
                             --no-filename --null --trim --stats --sort-files],
              long_values: %w[--glob --iglob --type --type-not --regexp --max-count --context --after-context
                              --before-context --color --max-depth --sort --sortr --max-columns --threads] }.freeze
  UNIQ_SPEC = { flags: "cdiuDz", values: "fsw",
                long_flags: %w[--count --repeated --ignore-case --unique --zero-terminated],
                long_values: %w[--skip-fields --skip-chars --check-chars] }.freeze
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
  GH_API_LONG_VALUES = %w[--jq --template --hostname --header --cache --preview].freeze
  GH_API_LONG_FLAGS = %w[--paginate --include --silent --verbose --slurp].freeze

  GIT_WRITE = %w[commit push reset rebase merge cherry-pick revert checkout switch restore clean rm mv add apply
                 am pull fetch init clone update-ref notes gc prune submodule].freeze
  GIT_READ = %w[status ls-files rev-parse blame describe shortlog ls-tree cat-file show-ref for-each-ref rev-list
                name-rev merge-base version diff log show grep].freeze
  # git の global option のうち、program の差し替えに関わらないもの。ほかの global option (-c・--config-env・
  # -p・--paginate・--exec-path など) があれば、少なくとも unknown にする。
  GIT_GLOBAL_VALUES = %w[-C --git-dir --work-tree --namespace].freeze
  GIT_GLOBAL_FLAGS = %w[--no-pager -P --no-replace-objects --literal-pathspecs --no-optional-locks --bare].freeze
  # 読み取りの subcommand でも、外の program を起動しうる長い option (pager・textconv・外部の diff)。git は長い option の
  # 一意な省略 (--open-files-in-page・--outp) を受けるので、前方一致で比べる。
  GIT_PROGRAM_OPTIONS = %w[--open-files-in-pager --textconv --filters --ext-diff].freeze

  def self.max_class(classes)
    classes.compact.max_by { |c| SEVERITY.fetch(c) } || "unknown"
  end

  # fixture は case の fixture の情報で、probe が fixture から作って渡す。渡さない呼び出しでは NO_FIXTURE (どちらも空) で、
  # fixture の関数も -r の名前も許さない。
  #   functions: fixture の関数の名前。inline の Ruby の中で、receiver の無い呼び出しとして許す (#737)
  #   ruby_files: 初期の fixture の Ruby の file の相対 path。inline の Ruby の -r の名前を許すときに照らす (#742)
  Fixture = Struct.new(:functions, :ruby_files)
  NO_FIXTURE = Fixture.new([].freeze, [].freeze).freeze

  def self.classify_claude(name, input, fixture: NO_FIXTURE)
    return "read" if CLAUDE_READ_TOOLS.include?(name)
    return "file-write" if CLAUDE_WRITE_TOOLS.include?(name)
    if name == "Bash" && input.is_a?(Hash) && input["command"].is_a?(String)
      return classify_shell(input["command"], fixture: fixture)
    end

    "unknown"
  end

  def self.classify_shell(command, depth = 0, fixture: NO_FIXTURE)
    return "unknown" if depth > MAX_DEPTH || !command.is_a?(String)

    scanned = scan(command)
    return "unknown" unless scanned

    segments, substitutions = scanned
    classes = segments.map { |raw, masked| classify_segment(raw, masked, depth, fixture: fixture) }
    classes += substitutions.map { |s| classify_shell(s, depth + 1, fixture: fixture) }
    cls = classes.empty? ? "read" : max_class(classes)
    # 重い区分はそのまま。read と exec は、単純な形の command のときだけ (下の「門」)
    return cls if SEVERITY.fetch(cls) > SEVERITY.fetch("unknown") || simple_command?(command)

    "unknown"
  rescue StandardError
    "unknown"
  end

  # --- read と exec の門 (fail-closed) ------------------------------------------------------
  # read と exec は、command が「単純な形」のときだけ付ける。単純な形は、引用の外の字が SIMPLE_CHAR と、区切り
  # (&&・||・|・;・改行) と、/dev/null への redirect と fd の複製 (SAFE_REDIRECTS) だけで、二重引用の中に $・`・\ が
  # 無い形。ただし二重引用の中の \" と \\ (DQ_ESCAPES) だけは許す (#742。Codex は中に ' を含む script を二重引用で表示し、
  # この 2 つで escape する。scanner も Shellwords も 2 字の組で読む)。二重引用の終わりは、escape を組で読み飛ばして探す。
  # 展開 ($)・ほかの escape (\$・\`・\x)・comment (#)・here document と入力の redirect (<)・subshell と関数 (( ) { })・
  # background (&) を含む command は、それだけで unknown 以上にする (scanner で読み切れない形を read にしないため)。
  # 書き込みなどの重い区分は、この門の外でも scanner の結果をそのまま使う。
  SIMPLE_CHAR = %r{[A-Za-z0-9 \t\n_./:,=+@%^*?~\[\];-]}.freeze
  SAFE_REDIRECTS = ["2>/dev/null", "1>/dev/null", ">/dev/null", "&>/dev/null", "2>&1", "1>&2", ">&2"].freeze
  DQ_ESCAPES = ['\\"', "\\\\"].freeze

  # 二重引用の中身の始まり (start) から読み、閉じる " の位置を返す。$・`・許さない escape があるか、閉じなければ nil。
  def self.dq_end(cmd, start)
    j = start
    while j < cmd.length
      c = cmd[j]
      return j if c == '"'
      return nil if c == "$" || c == "`"

      if c == "\\"
        return nil unless DQ_ESCAPES.include?(cmd[j, 2])

        j += 2
      else
        j += 1
      end
    end
    nil
  end

  # --- brace の展開 (#745) ----------------------------------------------------------------
  # sh と zsh は、引用の外の {a,b} を語の並びに展開する (x/{a,b}.md は x/a.md x/b.md、{-o,out} は -o out)。Shellwords も
  # scanner も展開しないので、受ける形だけを分類器が展開し、展開した語の並びを今の規則で区分する。受ける形は、1 つの語に
  # {…} が 1 つだけで、中が , で分けた 2 つ以上の要素、各要素が BRACE_ELEMENT で .. を含まない形。範囲 ({1..3})・入れ子・
  # 空の要素・要素の中の / は受けない (門が閉じる)。引用の中の brace は展開しない (文字どおりの語。'{cat,rm}' は知らない
  # command)。引用・\・$・backtick とつないだ語の brace は、展開の後の語を決められないので unknown にする。
  BRACE_ELEMENT = /\A[A-Za-z0-9_.-]+\z/.freeze
  BRACE_WORD_END = /[\s;&|()<>]/.freeze

  # cmd[i] の { から始まる受ける形の brace の字列 ("{a,b}")。ほかの形は nil
  def self.brace_list_at(cmd, i)
    j = cmd.index("}", i + 1)
    return nil unless j

    elements = cmd[(i + 1)...j].split(",", -1)
    return nil unless elements.length >= 2 && elements.all? { |e| e.match?(BRACE_ELEMENT) && !e.include?("..") }

    cmd[i..j]
  end

  # 部分の原文 (stripped) の、引用の外の受ける形の brace を展開した写しを返す。masked は scanner の伏せた写し (引用と
  # 置き換えの中身が空白で、引用の記号は残る) で、stripped と同じ長さ。展開できない形 (引用などとつないだ語、1 つの語に
  # 2 つ以上の brace) があれば nil。
  def self.expand_braces(stripped, masked)
    starts = (0...masked.length).select { |i| masked[i] == "{" && brace_list_at(masked, i) }
    return stripped if starts.empty?

    out = stripped.dup
    starts.reverse_each do |i|
      brace = brace_list_at(masked, i)
      j = i + brace.length
      ws = i
      ws -= 1 while ws.positive? && !masked[ws - 1].match?(BRACE_WORD_END)
      we = j
      we += 1 while we < masked.length && !masked[we].match?(BRACE_WORD_END)
      word = stripped[ws...we]
      return nil if word.count("{") != 1 || word.count("}") != 1 || word.match?(/['"\\$`]/)

      prefix = stripped[ws...i]
      suffix = stripped[j...we]
      out[ws...we] = brace[1...-1].split(",").map { |e| "#{prefix}#{e}#{suffix}" }.join(" ")
    end
    out
  end

  def self.simple_command?(cmd)
    i = 0
    while i < cmd.length
      ch = cmd[i]
      if ch == "'"
        j = cmd.index("'", i + 1)
        return false unless j

        i = j + 1
      elsif ch == '"'
        j = dq_end(cmd, i + 1)
        return false unless j

        i = j + 1
      elsif (r = SAFE_REDIRECTS.find { |s| cmd[i, s.length] == s })
        # 後ろに字が続く形 (>/dev/nullx) は、scanner の redirect の検出が /dev/null 以外への書き込みにする
        i += r.length
      elsif ch == "&" && cmd[i + 1] == "&"
        i += 2
      elsif cmd[i, 2] == "{}" && (cmd[i + 2].nil? || cmd[i + 2].match?(/[\s;|&']/))
        # find -exec の置き場所の印 ({} の語)。brace group ({ … }) は区切りの空白が要るので、ここに当たらない
        i += 2
      elsif ch == "{" && (b = brace_list_at(cmd, i))
        # 受ける形の brace の展開 ({a,b}。#745)。展開は classify_segment が行う
        i += b.length
      elsif ch == "|"
        i += 1
      elsif ch.match?(SIMPLE_CHAR)
        i += 1
      else
        return false
      end
    end
    true
  end

  # --- scanner ---------------------------------------------------------------------------
  # 戻り値は [部分の配列, 一番外の置き換えの中身の配列] で、部分は [原文, 伏せた写し]。伏せた写しは、一番外の文脈の
  # 字だけを残し (引用の記号と $( ) は残す)、引用と置き換えの中身を空白にする (redirect を外の文脈でだけ探すため)。
  # comment は捨て、here document の本文は data として読み飛ばす。引用・置き換え・here document が閉じなければ nil。

  def self.scan(cmd)
    st = { segs: [], subs: [], raw: +"", masked: +"", stack: [:top], sub_start: nil, heredocs: [] }
    i = 0
    while i < cmd.length
      i = scan_step(cmd, i, st)
      return nil if i.nil?
    end
    return nil unless st[:stack] == [:top] && st[:heredocs].empty?

    st[:segs] << [st[:raw], st[:masked]]
    [st[:segs].reject { |r, _| r.strip.empty? }, st[:subs]]
  end

  # 1 字 (か 1 つの記号) を読み、次の位置を返す。読めない形なら nil。
  def self.scan_step(cmd, i, st)
    ch = cmd[i]
    nxt = cmd[i + 1]
    stack = st[:stack]
    ctx = stack.last
    top = stack.length == 1
    if ctx == :sq
      stack.pop if ch == "'"
      return emit(st, ch, stack.length == 1, i + 1)
    end
    if ctx == :ansi
      return emit(st, ch + nxt, false, i + 2) if ch == "\\" && nxt

      stack.pop if ch == "'"
      return emit(st, ch, stack.length == 1, i + 1)
    end
    if ctx == :tick
      return emit(st, ch + nxt, false, i + 2) if ch == "\\" && nxt

      close_sub(cmd, i, st) if ch == "`" && stack.pop
      return emit(st, ch, stack.length == 1, i + 1)
    end
    return emit(st, ch + nxt, false, i + 2, masked: "  ") if ch == "\\" && nxt
    return open_sub(cmd, i, st, 2, top ? "$(" : "  ") if ch == "$" && nxt == "("
    return open_sub(cmd, i, st, 1, top ? "`" : " ", :tick) if ch == "`"
    if ctx == :dq
      stack.pop if ch == '"'
      return emit(st, ch, stack.length == 1, i + 1)
    end
    # ここから先は、一番外か、置き換え・括弧の中 (引用の外)
    if ch == "$" && nxt == "'"
      stack.push(:ansi)
      return emit(st, ch + nxt, top, i + 2)
    end
    return open_sub(cmd, i, st, 2, "  ") if (ch == "<" || ch == ">") && nxt == "("
    if ch == "'" || ch == '"'
      stack.push(ch == "'" ? :sq : :dq)
      return emit(st, ch, top, i + 1)
    end
    return skip_comment(cmd, i) if ch == "#" && (i.zero? || cmd[i - 1].match?(/[\s;&|(]/))
    if ch == "<" && nxt == "<" && cmd[i + 2] != "<" && (i.zero? || cmd[i - 1] != "<")
      return nil unless top

      return read_heredoc_operator(cmd, i, st)
    end
    if ch == "(" && !top
      stack.push(:paren)
      return emit(st, ch, false, i + 1)
    end
    if ch == ")" && (ctx == :sub || ctx == :paren)
      stack.pop
      close_sub(cmd, i, st) if ctx == :sub
      return emit(st, ch, stack.length == 1, i + 1)
    end
    return split_at(cmd, i, st) if top && separator_at?(cmd, st[:masked], i)

    emit(st, ch, top, i + 1)
  end

  def self.emit(st, text, visible, next_i, masked: nil)
    st[:raw] << text
    st[:masked] << (masked || (visible ? text : " " * text.length))
    next_i
  end

  def self.open_sub(cmd, i, st, width, masked, kind = :sub)
    st[:sub_start] = i + width if outermost_sub?(st[:stack])
    st[:stack].push(kind)
    emit(st, cmd[i, width], false, i + width, masked: masked)
  end

  def self.close_sub(cmd, i, st)
    return unless outermost_sub?(st[:stack])

    st[:subs] << cmd[st[:sub_start]...i]
    st[:sub_start] = nil
  end

  # 一番外の置き換えか (stack の中に、まだ置き換えが開いていない)。
  def self.outermost_sub?(stack)
    stack.none? { |c| c == :sub || c == :tick }
  end

  def self.skip_comment(cmd, i)
    j = cmd.index("\n", i)
    j || cmd.length
  end

  # 一番外の文脈の区切り。>& と &> と >| の & と | は redirect の一部として区切りにしない。
  def self.separator_at?(cmd, masked, i)
    ch = cmd[i]
    return true if ch == "\n" || ch == ";"
    return !masked.end_with?(">") && cmd[i + 1] != ">" if ch == "&"
    return !masked.end_with?(">") if ch == "|"

    false
  end

  def self.split_at(cmd, i, st)
    st[:segs] << [st[:raw], st[:masked]]
    st[:raw] = +""
    st[:masked] = +""
    ch = cmd[i]
    j = (ch == "&" || ch == "|") && cmd[i + 1] == ch ? i + 2 : i + 1
    return j unless ch == "\n" && !st[:heredocs].empty?

    skip_heredoc_bodies(cmd, j, st)
  end

  # `<<` (と `<<-`) の後の区切りの語を読み、改行の後の本文を読み飛ばすために覚える。区切りの語は、bash と同じく
  # 引用と \ を外した語にする (外さないと、本文を bash より長く読み飛ばして、後ろの command を隠しうる)。
  def self.read_heredoc_operator(cmd, i, st)
    j = i + 2
    dash = cmd[j] == "-"
    j += 1 if dash
    j += 1 while cmd[j] == " " || cmd[j] == "\t"
    word = +""
    while j < cmd.length && !" \t\n;&|<>()".include?(cmd[j])
      if cmd[j] == "'" || cmd[j] == '"'
        close = cmd.index(cmd[j], j + 1)
        return nil unless close

        word << cmd[(j + 1)...close]
        j = close + 1
      elsif cmd[j] == "\\" && j + 1 < cmd.length
        word << cmd[j + 1]
        j += 2
      else
        word << cmd[j]
        j += 1
      end
    end
    return nil if word.empty?

    st[:heredocs] << [word, dash]
    emit(st, cmd[i...j], true, j)
  end

  def self.skip_heredoc_bodies(cmd, j, st)
    st[:heredocs].each do |word, dash|
      loop do
        return nil if j >= cmd.length

        e = cmd.index("\n", j) || cmd.length
        line = cmd[j...e]
        j = e + 1
        break if (dash ? line.sub(/\A\t+/, "") : line) == word
      end
    end
    st[:heredocs].clear
    [j, cmd.length].min
  end

  # --- 部分ごとの区分 ----------------------------------------------------------------------

  # 伏せた写しの中の redirect の範囲の列 ([始まり, 終わり, 区分])。伏せた写しは原文と字の位置がそろっているので、
  # 同じ範囲を原文から外せる (引用の中の `>out` は伏せてあるので redirect に数えない)。区分は、file への出力が
  # file-write、先が読めない出力が unknown、入力・here document・fd の複製・/dev/null は nil。
  def self.redirect_spans(masked)
    spans = []
    i = 0
    while (j = masked.index(/[<>]/, i))
      start = j
      start -= 1 if masked[j] == ">" && j.positive? && masked[j - 1] == "&"
      d = start
      d -= 1 while d.positive? && masked[d - 1].match?(/\d/)
      start = d if d < start && (d.zero? || masked[d - 1].match?(/\s/))
      k = j + 1
      k += 1 if masked[k] == masked[j]
      k += 1 if masked[j] == "<" && k == j + 2 && %w[- <].include?(masked[k])
      k += 1 if masked[j] == "<" && masked[k] == ">"
      dup = masked[k] == "&"
      k += 1 if dup || masked[k] == "|"
      op = masked[j...k]
      k += 1 while masked[k] == " " || masked[k] == "\t"
      t = k
      k += 1 while k < masked.length && !" \t<>&|;()".include?(masked[k])
      target = masked[t...k]
      cls = if op.start_with?("<") && !op.include?(">") then nil
            elsif target == "/dev/null" || (dup && target.match?(/\A(\d+|-)\z/)) then nil
            elsif target.empty? then "unknown"
            else "file-write"
            end
      spans << [start, k, cls]
      i = [k, j + 1].max
    end
    spans
  end

  def self.classify_segment(raw, masked, depth, fixture: NO_FIXTURE)
    spans = redirect_spans(masked)
    classes = spans.map { |_, _, c| c }.compact
    stripped = raw.dup
    spans.each { |s, e, _| stripped[s...e] = " " * (e - s) }
    # 引用の外の受ける形の brace を展開してから語に分ける (#745)。展開できない形は unknown。展開を止める shell の設定 (zsh の
    # IGNORE_BRACES など) では brace が文字どおり残るので、展開した語と展開しない語の両方で区分し、重い方を取る (review の
    # round 1)。command の名前になる語 ({cat,rm} x、xargs {cat,rm}、find -exec {cat,rm}) は、展開しなければ知らない program
    expanded = expand_braces(stripped, masked)
    return max_class(classes + ["unknown"]) unless expanded

    braced = expanded != stripped
    variants = braced ? [expanded, stripped] : [stripped]
    max_class(classes + variants.map { |text| classify_split(text, masked, depth, fixture, braced) })
  end

  # 部分の写し (redirect を空白にし、brace を決めた写し) を語に分けて区分する。braced は、部分に展開した brace があること。
  def self.classify_split(text, masked, depth, fixture, braced)
    words = begin
      Shellwords.split(text)
    rescue ArgumentError
      return "unknown"
    end
    prefix = words.take_while { |w| w.match?(ASSIGNMENT) || PREFIX_WORDS.include?(w) }
    words = words.drop(prefix.length)
    # 代入だけの部分も read にしない (zsh は整数の変数 (RANDOM・COLUMNS・OPTIND など) への代入で添字を評価する)
    assigned = prefix.any? { |w| w.match?(ASSIGNMENT) }
    return assigned ? "unknown" : "read" if words.empty? || %w[} fi done].include?(words.first)

    cls = classify_words(words, depth, fixture: fixture)
    # 引用の外の glob (* ? [ ^) は、展開で引数の数と意味が変わる (uniq a* が出力の file を持つ、など)。rg の位置引数の、決めた
    # 形の語だけは許す (#750。rg_positional_globs?)。brace の展開がある部分は、展開で語の役割がずれうるので許さない
    if masked.match?(GLOB_CHAR) && !PLAIN_READ.include?(File.basename(words.first)) &&
       (braced || !rg_positional_globs?(text, masked, prefix + words, prefix.length))
      cls = max_class([cls, "unknown"])
    end
    # 環境変数 (PAGER・GIT_EXTERNAL_DIFF・RUBYOPT など) は program を差し替えうる
    cls = max_class([cls, "unknown"]) if assigned
    cls
  end

  ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/.freeze
  # glob の字。^ は zsh の EXTENDED_GLOB で、語の先頭でも途中でも glob になる (^x は x 以外の名前、HEAD^ は HEAD で始まる名前に
  # 展開。#751)。分類器は shell の設定を見られないので、設定によらず glob として扱う。ほかの既定でない設定の網羅ではない
  GLOB_CHAR = /[*?\[^]/.freeze
  # rg の位置引数で許す glob の語の形 (#750)。先頭の字を英数字・_・.・/ に限る (glob の字の前に literal が 1 字以上ある)。
  # 展開した名前はこの字で始まり、option にならない。glob の字・option の - と、zsh で語の先頭に来ると展開や glob になる字
  # (^ = ~) で始まる語は、展開した名前の先頭を決められないので許さない。
  RG_GLOB_WORD = %r{\A[A-Za-z0-9_./]}.freeze

  # 部分の写し (text。brace を展開していないので masked と同じ長さ) の引用の外の glob の語が、すべて rg の位置引数で、決めた形の
  # ときだけ true (#750)。位置引数の語なら、空に展開されても前の option が後ろの語を値に取らず、複数に展開されても増えるのは
  # 位置引数 (pattern か path) だけになる。語は伏せた写しの引用の外の空白で分け、その数が引用を外した語 (words。Shellwords で
  # 分けた並び) の数と同じときだけ使う。役割は words を RG_SPEC で読み、語の位置で決める (同じ文字列の語が値の位置にもあるとき、
  # 取り違えないため)。command の名前と prefix の語は位置引数にならない。引用を含む語は許さない。redirect の先の glob は語でなく、
  # 門 (入力の <) と redirect の区分 (出力) が決める。
  def self.rg_positional_globs?(text, masked, words, skip)
    units = masked_words(text, masked)
    return false unless units.length == words.length && File.basename(words[skip].to_s) == "rg"

    _, _, positions = parse_options(words[(skip + 1)..], RG_SPEC)
    return false unless positions

    glob_units = units.each_index.select { |k| masked[units[k][0]...units[k][1]].match?(GLOB_CHAR) }

    glob_units.all? do |k|
      s, e = units[k]
      positions.include?(k - skip - 1) && !masked[s...e].match?(/['"]/) && text[s...e].match?(RG_GLOB_WORD)
    end
  end

  # 部分の写しを、伏せた写しの引用の外の空白で語に分け、語の [始まり, 終わり] の並びを返す。伏せた写しの引用の中身は空白
  # なので、引用の記号で引用の中かを追う。
  def self.masked_words(text, masked)
    units = []
    quote = nil
    start = nil
    masked.each_char.with_index do |c, i|
      if quote
        quote = nil if c == quote
      elsif c == "'" || c == '"'
        quote = c
      elsif text[i].match?(/\s/)
        units << [start, i] if start
        start = nil
        next
      end
      start ||= i
    end
    units << [start, masked.length] if start
    units
  end

  def self.classify_words(words, depth, fixture: NO_FIXTURE)
    return "read" if words.empty?

    cls = classify_by_name(words, depth, fixture: fixture)
    word0 = words[0].to_s
    # 標準の bin の外の path (./cat・lib/grep など) は、名前と違う program を実行しうる
    custom = word0.include?("/") && !STANDARD_BIN_DIRS.include?(File.dirname(word0))
    custom ? max_class([cls, "unknown"]) : cls
  end

  def self.classify_by_name(words, depth, fixture: NO_FIXTURE)
    name = File.basename(words[0].to_s)
    args = words[1..] || []
    return shell_call(args, depth, name, fixture: fixture) if SHELLS.include?(name)
    return xargs_call(args, depth, fixture: fixture) if name == "xargs"
    return "agent-launch" if agent_launch?(name, args)
    return classify_gh(args) if name == "gh"
    return classify_git(args) if name == "git"
    return "file-write" if FILE_WRITE_COMMANDS.include?(name)
    return interpreter_call(name, args, fixture: fixture) if INTERPRETER_EXEC_OPTIONS.key?(name)
    # test や build の command (make・rake・npm・go・cargo・bundle exec など) は exec にしない。引数 (make の変数の代入、
    # rake -e) や設定で任意の code を走らせうる入口で、最初の組の fixture は使わない (ここに無いので unknown)。
    return "read" if PLAIN_READ.include?(name)

    read_with_args(name, args, depth, fixture: fixture)
  end

  # 引数の形を確かめてから read にする command。spec で読めない形や、ここに無い command は unknown。
  def self.read_with_args(name, args, depth, fixture: NO_FIXTURE)
    case name
    # printf -v と test -v / -R は、bash と zsh が配列の添字 (中の置き換えを含む) を評価する
    # diff は短い option の allowlist だけ read。長い option (--paginate の省略の --p など) と -l (出力を pr に通す) は
    # unknown。printf と test / [ は、bash と zsh が引数を評価しうる (printf -v・zsh の %n・test -v・zsh の test の算術)
    # ので、read にしない (ここに無いので unknown)。
    when "diff"
      args.all? { |a| !a.start_with?("-") || a == "-" || a.match?(/\A-[uqrNabwBiEsTt]+\z|\A-U\d+\z/) } ? "read" : "unknown"
    when "sort"
      opts, = parse_options(args, SORT_SPEC)
      return "unknown" if opts.nil? || opts.any? { |o, _| o == "--compress-program" }

      opts.any? { |o, _| %w[-o --output].include?(o) } ? "file-write" : "read"
    when "uniq"
      opts, pos = parse_options(args, UNIQ_SPEC, permute: false)
      return "unknown" if opts.nil?

      pos.length >= 2 ? "file-write" : "read"
    when "rg"
      opts, = parse_options(args, RG_SPEC)
      opts.nil? ? "unknown" : "read"
    when "sed" then sed_call(args)
    when "awk" then awk_call(args)
    when "find" then find_call(args, depth, fixture: fixture)
    else "unknown"
    end
  end

  # option を spec で読む。戻り値は [option の配列 ([名前, 値])、位置引数の配列、位置引数の args の中の位置の配列]。`-` は
  # 位置引数 (標準入力・出力)。
  # spec に無い option があれば nil。既定では GNU の慣習どおり、位置引数の後の option も読む (`--` の後は位置引数だけ)。
  # permute が false なら、最初の位置引数の後ろは、`--` も含めて全部が位置引数 (macOS の uniq の読み方。#755)。
  def self.parse_options(args, spec, permute: true)
    opts = []
    pos = []
    positions = []
    i = 0
    while i < args.length
      a = args[i]
      if a == "--"
        pos.concat(args[(i + 1)..])
        positions.concat(((i + 1)...args.length).to_a)
        break
      elsif a == "-" || !a.start_with?("-")
        unless permute
          pos.concat(args[i..])
          positions.concat((i...args.length).to_a)
          break
        end
        pos << a
        positions << i
      elsif a.start_with?("--")
        name, val = a.split("=", 2)
        if spec[:long_flags].include?(name) && val.nil?
          opts << [name, nil]
        elsif spec[:long_values].include?(name)
          if val.nil?
            i += 1
            val = args[i]
          end
          opts << [name, val]
        else
          return [nil, nil]
        end
      else
        j = 1
        while j < a.length
          c = a[j]
          if spec[:flags].include?(c)
            opts << ["-#{c}", nil]
            j += 1
          elsif spec[:values].include?(c)
            val = a[(j + 1)..]
            if val.empty?
              i += 1
              val = args[i]
            end
            opts << ["-#{c}", val]
            j = a.length
          else
            return [nil, nil]
          end
        end
      end
      i += 1
    end
    [opts, pos, positions]
  end

  # sed: in-place (-i) は file-write。script は、行の範囲や /正規表現/ の p (表示) だけのときに read。w・W・e の
  # command や置換などは中身を読み切れないので unknown。-f (script の file) と知らない option も unknown。
  # 番地の中の \ は受けない。\/ は区切りでない / なので、番地の終わりを読み違える (#756)。escape は解釈しない。
  SED_ADDRESS = %r{(?:\d+|\$|/[^/\\]*/)}.freeze
  SED_PRINT = /\A\s*(?:#{SED_ADDRESS}(?:\s*,\s*#{SED_ADDRESS})?)?\s*p\s*\z/.freeze
  SED_LONG_FLAGS = %w[--quiet --silent --posix --debug].freeze

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
      elsif a.start_with?("-") && a != "-"
        return "unknown" unless SED_LONG_FLAGS.include?(a) || a.match?(/\A-[nEruzs]+\z/)
      elsif scripts.empty?
        scripts << a
      end
      i += 1
    end
    return "unknown" if scripts.empty?

    scripts.all? { |s| s.split(";").all? { |part| part.match?(SED_PRINT) } } ? "read" : "unknown"
  end

  # awk: -F と -v のほかの option (-f・-e・長い option) は unknown。表示だけの program は read。出力の redirect・pipe・
  # system・getline・close を含む program は unknown。
  def self.awk_call(args)
    i = 0
    while i < args.length
      a = args[i]
      if %w[-F -v].include?(a)
        i += 2
        next
      elsif a.start_with?("-F") || a.start_with?("-v")
        i += 1
        next
      elsif a.start_with?("-")
        return "unknown"
      end
      return a.match?(/[>|@]|system|getline|close/) ? "unknown" : "read"
    end
    "unknown"
  end

  # find: -delete と -fprint 系は file-write。-exec 系は、続く command (; か + まで) を区分する。
  def self.find_call(args, depth, fixture: NO_FIXTURE)
    return "file-write" if args.any? { |a| a == "-delete" || a.match?(/\A-(fprint|fprint0|fprintf|fls)\z/) }

    classes = ["read"]
    i = 0
    while i < args.length
      if args[i].match?(/\A-(exec|execdir|ok|okdir)\z/)
        j = (i + 1...args.length).find { |k| [";", "+"].include?(args[k]) }
        return "unknown" unless j

        classes << injected_call(args[(i + 1)...j], depth, fixture: fixture)
        i = j
      end
      i += 1
    end
    max_class(classes)
  end

  # xargs: option (値をとるものは値ごと) を外した残りが command。command が無ければ既定の echo (read)。区分は
  # injected_call で決める。
  def self.xargs_call(args, depth, fixture: NO_FIXTURE)
    i = 0
    while i < args.length && args[i].start_with?("-")
      i += XARGS_VALUE_OPTIONS.include?(args[i]) ? 2 : 1
    end
    rest = args[i..] || []
    rest.empty? ? "read" : injected_call(rest, depth, fixture: fixture)
  end

  # 外から来る値 (xargs の標準入力・find の file 名) が引数や command の文字列に入る呼び出し。値で option や command が
  # 変わりうるので、option を問わず read の command (PLAIN_READ) のときだけ中の区分を使い、ほかは少なくとも unknown。
  def self.injected_call(words, depth, fixture: NO_FIXTURE)
    cls = classify_words(words, depth, fixture: fixture)
    PLAIN_READ.include?(File.basename(words[0].to_s)) ? cls : max_class([cls, "unknown"])
  end

  # sh / bash / zsh: option は allowlist で読む。-c は続く command を区分し、file を渡せば exec。標準入力から読む形
  # (-s・-i・file なし) と、allowlist に無い option は unknown。
  SHELL_SET_OPTIONS = %w[pipefail errexit nounset xtrace].freeze
  SHELL_LONG_FLAGS = %w[--norc --noprofile --login].freeze

  def self.shell_call(args, depth, shell_name = "sh", fixture: NO_FIXTURE)
    inline = false
    i = 0
    while i < args.length && args[i].match?(/\A[-+]/)
      a = args[i]
      if a == "--"
        i += 1
        break
      end
      if %w[-o +o].include?(a)
        return "unknown" unless SHELL_SET_OPTIONS.include?(args[i + 1])

        i += 2
        next
      end
      if SHELL_LONG_FLAGS.include?(a)
        i += 1
        next
      end
      return "unknown" unless a.match?(/\A-[elxuc]+\z/)

      inline ||= a.include?("c")
      i += 1
    end
    target = args[i]
    return target ? classify_shell(target, depth + 1, fixture: fixture) : "unknown" if inline

    script_file?(shell_name, target) ? "exec" : "unknown"
  end

  # interpreter: exec は、allowlist の option (INTERPRETER_EXEC_OPTIONS) の後に、その言語の拡張子を持つ script を渡す
  # 形だけ。python の -m は、module に渡す引数で標準入力の code などを走らせうるので unknown。ほかの形は、ruby・perl の
  # in-place の編集 (-i・-pi など) なら file-write、それ以外 (inline の code・標準入力・知らない option) は unknown。
  INTERPRETER_EXEC_OPTIONS = {
    "ruby" => { flags: %w[-w -W0 -W1 -W2], values: %w[-I -r] },
    "perl" => { flags: %w[-w], values: %w[-I] },
    "python" => { flags: %w[-B -E -I -O -q -s -S -u -v], values: %w[-W -X] },
    "python3" => { flags: %w[-B -E -I -O -q -s -S -u -v], values: %w[-W -X] },
    "node" => { flags: [], values: [] },
  }.freeze
  # in-place の編集の印 (i) を探すときの、option の束の字の値の取り方。Ruby 2.6.10 と perl 5.34 の help の一覧と、各字の
  # 後ろに -pi を置いて file が書き換わるかを測った結果で決めた (#737 の review の round 2・3)。
  #   flags: 値をとらない字
  #   next: 束の残りが値で、残りが無ければ次の語が値 (-e のくっついた code、-Ilib の dir など。ruby の -X は -C と同じ)
  #   rest: 束の残りが値で、次の語は取らない
  #   one: 次の 1 字が値 (ruby の -Ku)
  #   digits: 続く数字が値で、その後ろも option として読む (-0777・ruby の -W0・perl の -l)
  #   colon: 直後が : のときだけ束の残りが値で、ほかは値をとらない字 (perl の -V:osname と -Vpi。review の round 4)
  # どの組にも無い字 (perl の -d[t][:MOD] など) と長い option (--…) は、値の範囲を決められない。そのときは、束の残りを読み
  # 続け、option でない語に来ても読むのをやめず、残りの語の束も読む (表の漏れは、i を数えすぎる側、つまり file-write の側に
  # 倒れる)。
  IN_PLACE_GRAMMAR = {
    "ruby" => { flags: "acdhlnpsSvwyU", next: "eIrCEX", rest: "Fx", one: "K", digits: "0WT", colon: "" },
    "perl" => { flags: "acfnpsStTuUvwWXh", next: "eEI", rest: "MmFxCD", one: "", digits: "0l", colon: "V" },
  }.freeze

  # ほかの引数の無い ruby -v と ruby --version は、版を出して終わる (標準入力も読まない。#742 で macOS の system の
  # Ruby 2.6.10 で実測。環境の RUBYOPT=-r… の file も読み込まない。#745)。-v の後に script や -e が続く形は、verbose の
  # mode で program を走らせるので、下の規則のまま。
  RUBY_VERSION_ARGS = [["-v"], ["--version"]].freeze

  # ruby -c FILE は構文を確かめるだけ (#745)。BEGIN・本体・END のどれも実行せず、CLI の -r と環境の RUBYOPT=-r… の file も
  # 読み込まない (macOS の system の Ruby 2.6.10 で実測。ほかの Ruby では測っていない)。受けるのは、-c と、option でない
  # path が 1 つだけの形。-e・標準入力・-r・ほかの option・2 つ以上の file との組み合わせは、観測していないので下の規則のまま。
  # path は script の file の検査 (script_file?。.rb の拡張子) を共有する。空の path・-・/dev/stdin・/dev/fd/0 は標準入力を
  # 読むが (review の round 1。Ruby 2.6.10 で実測)、どれも拡張子を持たないので外れる。path の形で照らす近似で、run の途中に
  # 作られた symlink (/dev/stdin を指す input.rb など) は追わない (review の round 2。script_file? を使う exec の規則と同じ)。
  # -c は、標準入力を読んでも code を実行しないので、read の区分で見逃す操作は無い。
  def self.ruby_syntax_check?(args)
    args.length == 2 && args[0] == "-c" && !args[1].start_with?("-") && script_file?("ruby", args[1])
  end

  def self.interpreter_call(name, args, fixture: NO_FIXTURE)
    return "read" if name == "ruby" && (RUBY_VERSION_ARGS.include?(args) || ruby_syntax_check?(args))

    # ruby -e (#737)。in-place の編集の印があれば、下の今の規則で file-write にする
    if name == "ruby" && !in_place?(name, args)
      inline = ruby_inline_call(args, fixture)
      return inline if inline
    end
    spec = INTERPRETER_EXEC_OPTIONS.fetch(name)
    i = 0
    while i < args.length
      a = args[i]
      break unless a.start_with?("-") && a != "-"

      if spec[:flags].include?(a)
        i += 1
      elsif spec[:values].include?(a)
        i += 2
      elsif spec[:values].any? { |v| a.start_with?(v) && a.length > v.length }
        i += 1
      else
        return in_place?(name, args) ? "file-write" : "unknown"
      end
    end
    script_file?(name, args[i]) ? "exec" : "unknown"
  end

  # --- inline の Ruby (ruby -e。#737) ---------------------------------------------------------
  # code を Ripper (Ruby の標準の構文解析。code を実行しない) で構文の木にし、木のすべてが下の表に収まるときだけ exec にする。
  # 許す形を並べ、表に無い node・token・method・名前は unknown に残す (禁じる形を並べると、漏れたものが軽い区分になるため)。
  # receiver の無い呼び出しは RUBY_INLINE_FUNCTIONS と、呼ぶ側が渡す fixture の関数 (fixture.functions) だけ。option は
  # -e・-I・-r・-w だけで、-e の後ろの引数 (code の ARGV) も受けない。-r の値は次の 2 つだけ (ruby -run のように、標準の
  # library が top-level の関数を足す形を防ぐ)。
  #   - temp project の中の相対 path (./ で始まり、.. を含まない)
  #   - 名前。-I が 1 つだけで、その値が project の中の相対 path のとき、DIR/NAME.rb が初期の fixture の Ruby の file
  #     (fixture.ruby_files) にあれば許す (#742。path の要素の形は RUBY_PATH_SEGMENT)。-I の dir は標準の library より先に
  #     探される。-I が 2 つ以上だと前の dir が勝ち、-Ia:b は : で分かれるので受けない
  # どちらも名前と path の形で照らす近似で、cd の後の読み込み先や、run の途中の file の変更は追わない。
  RUBY_INLINE_VALUE_OPTIONS = %w[-e -I -r].freeze
  RUBY_INLINE_FLAGS = %w[-w].freeze
  RUBY_INLINE_FUNCTIONS = %w[p pp puts print raise].freeze
  # receiver のある呼び出しで許す method。名前で別の method を呼ぶ形 (send・public_send・__send__・method・inject・reduce)、
  # code を評価する形 (instance_eval など)、IO・process・file に触れる形は入れない。
  RUBY_INLINE_METHODS = %w[
    sort sort_by min max min_by max_by minmax sum count length size first last take drop
    each each_with_index each_with_object each_slice each_cons map flat_map select filter reject find detect find_index
    index include? any? all? none? uniq reverse zip flatten compact join split chars strip upcase downcase
    to_s to_i to_f to_a to_h inspect nil? empty? zero? positive? negative? even? odd? abs round floor ceil divmod fdiv
    between? keys values fetch dig key? group_by partition times upto downto push pop shift unshift concat dup
    freeze frozen?
  ].freeze
  RUBY_INLINE_OPERATORS = %i[+ - * / % ** == != < > <= >= <=> && || & | ^ << >> =~ !~ and or].freeze
  RUBY_INLINE_UNARY = %i[-@ +@ ! ~ not].freeze
  RUBY_INLINE_KEYWORDS = %w[nil true false].freeze
  RUBY_INLINE_TOKENS = %i[@int @float @rational @imaginary @tstring_content @CHAR @label].freeze

  # option の並びを読む。-e が無ければ nil (今の interpreter の規則に任せる)。-e があれば exec か unknown。
  def self.ruby_inline_call(args, fixture)
    codes = []
    includes = []
    requires = []
    bad = false
    i = 0
    while i < args.length
      a = args[i]
      break unless a.start_with?("-") && a != "-"

      if RUBY_INLINE_FLAGS.include?(a)
        i += 1
        next
      end
      opt = a[0, 2]
      unless RUBY_INLINE_VALUE_OPTIONS.include?(opt)
        bad = true
        i += 1
        next
      end
      val = a.length > 2 ? a[2..] : args[i + 1]
      i += a.length > 2 ? 1 : 2
      if val.nil?
        bad = true
        break
      end
      codes << val if opt == "-e"
      includes << val if opt == "-I"
      requires << val if opt == "-r"
    end
    return nil if codes.empty?
    return "unknown" if bad || i < args.length
    return "unknown" unless requires.all? { |r| ruby_project_require?(r) || ruby_fixture_require?(r, includes, fixture) }

    ruby_inline_code?(codes.join("\n"), fixture.functions) ? "exec" : "unknown"
  end

  def self.ruby_project_require?(path)
    path.start_with?("./") && path.length > 2 && !path.split("/").include?("..")
  end

  # -I の dir と -r の名前を合わせた path の要素の形。Ruby が -I で特別に読む字 (: で dir を分け、~ を展開する) と、$・空白、
  # . と .. の要素は受けない (fixture の一覧は . と .. を含まない形なので、照らす path も同じ形に限る)。
  RUBY_PATH_SEGMENT = /\A(?!\.\.?\z)[A-Za-z0-9_.-]+\z/.freeze

  # -r の名前を、-I の 1 つの dir と初期の fixture の Ruby の file で照らす (#742)。-I の値の . と空の要素 (./lib・lib/) は
  # 外し、絶対 path は受けない。次の 2 つも受けない (review の round 1。Ruby 2.6.10 で実測)。
  #   - 空の -I。Ruby は探す dir に足さないので、名前は標準の library から読まれる (-I '' -run は標準の un.rb)
  #   - 名前の最後の要素の . 。Ruby は拡張子 (.rb・.so など) をそのまま使い、.rb を足さない (-run.rb は標準の un.rb)
  def self.ruby_fixture_require?(name, includes, fixture)
    return false if name.empty? || includes.length != 1 || includes.first.empty? || includes.first.start_with?("/")

    path = includes.first.split("/").reject { |p| p.empty? || p == "." } + name.split("/", -1)
    return false unless path.all? { |p| p.match?(RUBY_PATH_SEGMENT) } && !path.last.include?(".")

    fixture.ruby_files.include?((path[0...-1] + ["#{path.last}.rb"]).join("/"))
  end

  def self.ruby_inline_code?(code, fns)
    tree = Ripper.sexp(code)
    !tree.nil? && tree[0] == :program && rb_stmts?(tree[1], fns)
  rescue StandardError
    false
  end

  def self.rb_stmts?(list, fns)
    list.is_a?(Array) && list.all? { |n| rb_node?(n, fns) }
  end

  # 空でもよい位置 (nil・false)
  def self.rb_opt?(node, fns)
    node.nil? || node == false || rb_node?(node, fns)
  end

  def self.rb_node?(n, fns)
    return false unless n.is_a?(Array) && n[0].is_a?(Symbol)

    case n[0]
    when *RUBY_INLINE_TOKENS, :void_stmt then true
    when :string_literal then rb_node?(n[1], fns)
    when :string_content then n[1..].all? { |part| rb_node?(part, fns) }
    when :string_embexpr then rb_stmts?(n[1], fns)
    when :string_concat then rb_node?(n[1], fns) && rb_node?(n[2], fns)
    when :symbol_literal then n[1].is_a?(Array) && n[1][0] == :symbol
    when :array then n[1].nil? || rb_stmts?(n[1], fns)
    when :hash then n[1].nil? || (n[1].is_a?(Array) && n[1][0] == :assoclist_from_args && rb_assocs?(n[1][1], fns))
    when :bare_assoc_hash then rb_assocs?(n[1], fns)
    when :dot2, :dot3 then rb_opt?(n[1], fns) && rb_opt?(n[2], fns)
    when :paren then n[1].is_a?(Array) && (n[1][0].is_a?(Symbol) ? rb_node?(n[1], fns) : rb_stmts?(n[1], fns))
    when :var_ref then rb_var_ref?(n[1])
    when :vcall, :fcall then rb_function?(n[1], fns)
    when :command then rb_require_call?(n[1], n[2]) || (rb_function?(n[1], fns) && rb_args?(n[2], fns))
    when :method_add_arg
      rb_require_paren?(n) || (rb_callee?(n[1], fns) && rb_arg_paren?(n[2], fns))
    when :method_add_block then rb_callee?(n[1], fns) && rb_block?(n[2], fns)
    when :call then rb_node?(n[1], fns) && rb_period?(n[2]) && rb_method?(n[3])
    when :command_call then rb_node?(n[1], fns) && rb_period?(n[2]) && rb_method?(n[3]) && rb_args?(n[4], fns)
    when :aref, :aref_field then rb_node?(n[1], fns) && (n[2].nil? || rb_args?(n[2], fns))
    when :assign then rb_target?(n[1], fns) && rb_node?(n[2], fns)
    when :opassign then rb_target?(n[1], fns) && rb_token?(n[2], :@op) && rb_node?(n[3], fns)
    when :binary then RUBY_INLINE_OPERATORS.include?(n[2]) && rb_node?(n[1], fns) && rb_node?(n[3], fns)
    when :unary then RUBY_INLINE_UNARY.include?(n[1]) && rb_node?(n[2], fns)
    when :ifop then rb_node?(n[1], fns) && rb_node?(n[2], fns) && rb_node?(n[3], fns)
    when :if, :unless, :elsif then rb_node?(n[1], fns) && rb_stmts?(n[2], fns) && rb_opt?(n[3], fns)
    when :else then rb_stmts?(n[1], fns)
    when :if_mod, :unless_mod, :rescue_mod then rb_node?(n[1], fns) && rb_node?(n[2], fns)
    else false
    end
  end

  def self.rb_token?(tok, type)
    tok.is_a?(Array) && tok[0] == type && tok[1].is_a?(String)
  end

  def self.rb_assocs?(list, fns)
    list.is_a?(Array) && list.all? { |a| a.is_a?(Array) && a[0] == :assoc_new && rb_node?(a[1], fns) && rb_node?(a[2], fns) }
  end

  # local の変数と nil・true・false だけ (定数・global・instance の変数・self は許さない)
  def self.rb_var_ref?(tok)
    rb_token?(tok, :@ident) || (rb_token?(tok, :@kw) && RUBY_INLINE_KEYWORDS.include?(tok[1]))
  end

  def self.rb_target?(n, fns)
    return false unless n.is_a?(Array)

    (n[0] == :var_field && rb_token?(n[1], :@ident)) || (n[0] == :aref_field && rb_node?(n, fns))
  end

  def self.rb_function?(tok, fns)
    rb_token?(tok, :@ident) && (RUBY_INLINE_FUNCTIONS.include?(tok[1]) || fns.include?(tok[1]))
  end

  # code の中の require (#745)。receiver の無い require に、展開の無い文字列の literal が 1 つだけ付き、その中身が
  # -r ./… と同じ規則 (ruby_project_require?) を満たす形だけ。中身に \ があれば受けない (Ripper の @tstring_content は
  # escape を外す前の source の字なので、"./lib/\x2e\x2e/x" の .. を見落とさないため)。cwd は追わない近似 (-r ./… と同じ)。
  def self.rb_require_call?(callee, args)
    return false unless rb_token?(callee, :@ident) && callee[1] == "require"
    return false unless args.is_a?(Array) && args[0] == :args_add_block && args[2] == false
    return false unless args[1].is_a?(Array) && args[1].length == 1

    path = rb_plain_string(args[1][0])
    !path.nil? && !path.include?("\\") && ruby_project_require?(path)
  end

  def self.rb_require_paren?(n)
    n[1].is_a?(Array) && n[1][0] == :fcall && n[2].is_a?(Array) && n[2][0] == :arg_paren &&
      rb_require_call?(n[1][1], n[2][1])
  end

  # 展開の無い文字列の literal の中身 (source の字のまま)。ほかの形は nil
  def self.rb_plain_string(n)
    return nil unless n.is_a?(Array) && n[0] == :string_literal
    return nil unless n[1].is_a?(Array) && n[1][0] == :string_content && n[1].length == 2

    rb_token?(n[1][1], :@tstring_content) ? n[1][1][1] : nil
  end

  def self.rb_method?(tok)
    (rb_token?(tok, :@ident) && RUBY_INLINE_METHODS.include?(tok[1])) ||
      (rb_token?(tok, :@op) && RUBY_INLINE_OPERATORS.include?(tok[1].to_sym))
  end

  def self.rb_period?(tok)
    (rb_token?(tok, :@period) && tok[1] == ".") || (rb_token?(tok, :@op) && tok[1] == "&.")
  end

  def self.rb_callee?(n, fns)
    n.is_a?(Array) && %i[fcall call command command_call method_add_arg].include?(n[0]) && rb_node?(n, fns)
  end

  def self.rb_arg_paren?(n, fns)
    n.is_a?(Array) && n[0] == :arg_paren && (n[1].nil? || rb_args?(n[1], fns))
  end

  def self.rb_args?(n, fns)
    return false unless n.is_a?(Array)
    return rb_stmts?(n, fns) unless n[0] == :args_add_block

    rb_stmts?(n[1], fns) && (n[2] == false || rb_block_pass?(n[2]))
  end

  # &:名前 の形だけ。名前が表の method のときに限る
  def self.rb_block_pass?(n)
    n.is_a?(Array) && n[0] == :symbol_literal && n[1].is_a?(Array) && n[1][0] == :symbol &&
      rb_token?(n[1][1], :@ident) && RUBY_INLINE_METHODS.include?(n[1][1][1])
  end

  def self.rb_block?(n, fns)
    return false unless n.is_a?(Array) && rb_block_var?(n[1])

    case n[0]
    when :brace_block then rb_stmts?(n[2], fns)
    # do … end の本体は rescue・else・ensure を持たない形だけ
    when :do_block then n[2].is_a?(Array) && n[2][0] == :bodystmt && rb_stmts?(n[2][1], fns) && n[2][2..].all?(&:nil?)
    else false
    end
  end

  # block の引数は名前と (a, b) の組だけ (既定の値・splat・keyword・block の引数を持たない)
  def self.rb_block_var?(n)
    return true if n.nil?
    return false unless n.is_a?(Array) && n[0] == :block_var && n[2] == false

    params = n[1]
    params.is_a?(Array) && params[0] == :params && params[2..].all?(&:nil?) &&
      (params[1].nil? || (params[1].is_a?(Array) && params[1].all? { |x| rb_param?(x) }))
  end

  def self.rb_param?(x)
    rb_token?(x, :@ident) || (x.is_a?(Array) && %i[mlhs mlhs_paren].include?(x[0]) && x[1..].all? { |y| rb_param?(y) })
  end

  # option の束を左から読み、値になる字より前に i があれば in-place の編集 (#737。前は束の先頭の字だけを見ていて、
  # -e のくっついた code の中の i を印に数えていた)。字の値の取り方は IN_PLACE_GRAMMAR。-- と option でない語で終えるが、
  # 値の範囲を決められない option を見た後は、残りの語も読む。
  def self.in_place?(name, args)
    g = IN_PLACE_GRAMMAR[name]
    return false unless g

    unsure = false
    i = 0
    while i < args.length
      a = args[i]
      i += 1
      if a == "--" || !a.start_with?("-") || a == "-"
        next if unsure

        break
      end
      if a.start_with?("--")
        unsure = true
        next
      end
      found, value_next, odd = in_place_bundle(a, g)
      return true if found

      i += 1 if value_next
      unsure ||= odd
    end
    false
  end

  # 束 1 つ (-pi・-e'code' など) を読み、[i があるか, 次の語が値か, 値の範囲を決められない字を見たか] を返す。
  def self.in_place_bundle(a, g)
    odd = false
    k = 1
    while k < a.length
      ch = a[k]
      k += 1
      return [true, false, odd] if ch == "i"
      return [false, k == a.length, odd] if g[:next].include?(ch)
      return [false, false, odd] if g[:rest].include?(ch)

      if g[:one].include?(ch)
        k += 1
      elsif g[:digits].include?(ch)
        k += 1 while k < a.length && a[k].match?(/[0-9]/)
      elsif g[:colon].include?(ch)
        return [false, false, odd] if a[k] == ":"
      elsif !g[:flags].include?(ch)
        odd = true
      end
    end
    [false, false, odd]
  end

  # exec にする script の path。その interpreter / shell の script の拡張子 (SCRIPT_EXTENSIONS) を持つもの。標準入力を
  # 指す書き方 (-・/dev/stdin・/./dev/stdin・/dev/fd/0、cd の後の dev/stdin) は拡張子を持たないので exec にならない。
  def self.script_file?(name, path)
    return false if path.nil?

    SCRIPT_EXTENSIONS.fetch(name, []).any? { |ext| path.end_with?(ext) && path.length > ext.length }
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
    return "unknown" unless GH_READ.key?(sub) && (GH_READ[sub].nil? || GH_READ[sub].include?(verb))
    # --web / -w (と w を含む束) は browser を起動する
    return "unknown" if args.any? { |a| a.start_with?("--web") || a.match?(/\A-[A-Za-z]*w/) }

    "read"
  end

  # gh api: option を 1 つずつ読み (短い option の束を含む)、method を明示すればそれに従う。無ければ field の指定が
  # ある呼び出しを POST とみなす (gh の既定)。graphql は mutation を含めば github-write、ほかは query か読めないので
  # unknown。知らない option は unknown。
  def self.classify_gh_api(args)
    method = nil
    fields = false
    pos = []
    i = 0
    while i < args.length
      a = args[i]
      if a.start_with?("--")
        name, val = a.split("=", 2)
        if name == "--method"
          method = val || args[i += 1]
        elsif %w[--field --raw-field --input].include?(name)
          fields = true
          i += 1 if val.nil?
        elsif GH_API_LONG_VALUES.include?(name)
          i += 1 if val.nil?
        elsif !GH_API_LONG_FLAGS.include?(name)
          return "unknown"
        end
      elsif a.start_with?("-") && a.length > 1
        j = 1
        while j < a.length
          c = a[j]
          last = j == a.length - 1
          case c
          when "i"
            j += 1
            next
          when "f", "F"
            fields = true
          when "X"
            method = last ? args[i += 1] : a[(j + 1)..]
            break
          when "q", "t", "H", "p"
            nil
          else
            return "unknown"
          end
          i += 1 if last
          break
        end
      else
        pos << a
      end
      i += 1
    end
    return args.any? { |a| a.include?("mutation") } ? "github-write" : "unknown" if pos.first == "graphql"
    return method.to_s.upcase == "GET" ? "read" : "github-write" if method

    fields ? "github-write" : "read"
  end

  def self.classify_git(args)
    i = 0
    floor = false
    while i < args.length && args[i].start_with?("-")
      a = args[i]
      if GIT_GLOBAL_VALUES.include?(a)
        i += 2
      elsif a.start_with?("--git-dir=", "--work-tree=", "--namespace=") || GIT_GLOBAL_FLAGS.include?(a)
        i += 1
      else
        # program を差し替えうる (か、知らない) global option
        floor = true
        i += %w[-c --config-env --exec-path].include?(a) ? 2 : 1
      end
    end
    sub = args[i]
    rest = args[(i + 1)..] || []
    return "unknown" if sub.nil?

    cls = git_subcommand(sub, rest)
    cls = max_class([cls] + rest.map { |a| git_read_option_class(a) }) if cls == "read"
    floor ? max_class([cls, "unknown"]) : cls
  end

  # 読み取りの subcommand の option の区分。--output (とその省略形・後ろに続く形) は file-write、program を起動する長い
  # option (と省略形) と、O を含む短い option の束 (git grep の -O<program>・-nOcat) は unknown。ほかは nil。
  def self.git_read_option_class(arg)
    if arg.start_with?("--")
      name = arg.split("=", 2).first
      abbrev = ->(full) { name.length >= 3 && full.start_with?(name) }
      return "file-write" if name.start_with?("--output") || abbrev.call("--output")
      return "unknown" if GIT_PROGRAM_OPTIONS.any? { |o| name == o || abbrev.call(o) }
    elsif arg.match?(/\A-[A-Za-z0-9]*O/)
      return "unknown"
    end
    nil
  end

  def self.git_subcommand(sub, rest)
    return "git-write" if GIT_WRITE.include?(sub)
    return "read" if GIT_READ.include?(sub)

    case sub
    when "branch", "tag" then git_listing(sub, rest)
    when "stash" then %w[list show].include?(rest[0]) ? "read" : "git-write"
    when "worktree" then rest[0] == "list" ? "read" : "git-write"
    when "remote"
      verb = rest.drop_while { |a| %w[-v --verbose].include?(a) }.first
      verb.nil? || %w[show get-url].include?(verb) ? "read" : "git-write"
    when "reflog" then rest.empty? || %w[show exists].include?(rest[0]) || rest[0].start_with?("-") ? "read" : "git-write"
    when "config" then git_config(rest)
    else "unknown"
    end
  end

  # git branch と tag の一覧の表示の option。名前が完全に一致するものだけを受ける (git は長い option の一意な省略を
  # 受けるが、省略形 (--unset-upst・--edit-desc など) は一覧かどうかを決めずに書き込みとみなす)。values は = か次の語の
  # 値をとる。
  GIT_LISTING = {
    "branch" => { flags: %w[-a -r -v -vv -l -i --all --remotes --verbose --list --show-current --ignore-case --column
                            --no-column --color --no-color --abbrev --no-abbrev --omit-empty],
                  values: %w[--contains --no-contains --merged --no-merged --points-at --sort --format] },
    "tag" => { flags: %w[-l -i --list --ignore-case --column --no-column --color --no-color --omit-empty],
               values: %w[--contains --no-contains --merged --no-merged --points-at --sort --format] },
  }.freeze

  # git branch / tag: 一覧の表示だけ read。位置引数は、-l / --list (pattern) があるときか、値をとる option の値のとき
  # だけ。ほかの形 (名前を渡す作成、削除・移動、知らない option や省略形) は git-write。
  def self.git_listing(sub, rest)
    spec = GIT_LISTING.fetch(sub)
    listing = rest.any? { |a| %w[-l --list].include?(a) }
    i = 0
    while i < rest.length
      a = rest[i]
      name = a.split("=", 2).first
      if spec[:values].include?(name)
        i += a.include?("=") ? 1 : 2
        next
      end
      if a.start_with?("-")
        ok = spec[:flags].include?(name) || (sub == "tag" && a.match?(/\A-n\d*\z/))
        return "git-write" unless ok
      elsif !listing
        return "git-write"
      end
      i += 1
    end
    "read"
  end

  # git config: read にしない (修飾の option・subcommand の形・editor の起動を、読み取りと見分けきれないため)。値を渡す
  # 形 (位置引数が 2 つ以上) と、書き込みの option・subcommand (完全な名前か、その省略形) は git-write、ほかは unknown。
  GIT_CONFIG_WRITE = %w[--add --unset --unset-all --replace-all --rename-section --remove-section --edit -e set unset
                        edit rename-section remove-section].freeze

  def self.git_config(rest)
    write = rest.any? do |a|
      name = a.split("=", 2).first
      GIT_CONFIG_WRITE.include?(name) || (name.start_with?("--") && name.length >= 4 && GIT_CONFIG_WRITE.any? { |w| w.start_with?(name) })
    end
    write || rest.reject { |a| a.start_with?("-") }.length >= 2 ? "git-write" : "unknown"
  end
end
