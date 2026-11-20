#!/usr/bin/env ruby
# frozen_string_literal: true

# skill の挙動の評価 (#369) の probe runner (実機)。Spec: docs/skill-behavior-eval.md。
#
# case ごとに fixture を新しい temp project に置き、1 回の user の依頼を claude / codex の headless 実行に流す。
# model が tool に求めた操作を、event stream の呼び出しの記録から区分し (分類器)、run の後の project の差分と
# 合わせて results.json に残す。判定は judge (#369 の PR 2) が行う。
#
# 責務境界 (honest):
#   - 測るのは、1 回の依頼から run の終わりまでに model が求めた操作。複数 turn の許可の保持は測らない。
#   - 書き込みは run ごとの temp project の中に閉じる。claude-code は --permission-mode acceptEdits (作業 directory の
#     中の編集だけを自動で許可し、Bash などは -p の既定のまま拒否される)、codex は -s workspace-write (network なし)。
#     どちらも実 tool home (~/.claude / ~/.codex) には書かない。
#   - 呼び出しの要求 (calls) と、その結果 (outcome) と、state の変化 (changed) を別の欄に残す。要求があっても、
#     外へ書けたことの証拠にはしない。
#   - command の本文と prompt は results.json に入れず、raw log (<out>.raw/) にだけ置く。raw log は model が読んだ
#     file の中身を含みうるので、公開しない。
#   - routing probe (probe_skill_routing.rb) の codex の起動の境界・preflight・model の選び方・user の skill の
#     無効化・子 process の期限は共有する。終わり方 (completion) と観測は共有しない (routing の max-turns や
#     observed-stop は、ここでは観測完了ではない)。
#   - CI では実行しない (CLI 認証と network が要る)。self-test は偽の CLI で行う。

require "digest"
require "fileutils"
require "json"
require "shellwords"
require "tmpdir"
require "time"
require_relative "probe_child"
require_relative "probe_skill_routing"
require_relative "skill_behavior_cases"

# C locale でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ProbeSkillBehavior
  class Error < StandardError; end

  R = ProbeSkillRouting
  C = SkillBehaviorCases
  TOOLS = %w[claude-code codex].freeze
  RESULTS_SCHEMA_VERSION = 1
  # 分類器の規則を変えたら上げる (結果を比べるときの識別子)。
  CLASSIFIER_VERSION = 1
  COMPLETIONS = %w[exited max-turns timeout failed].freeze
  OUTCOMES = %w[ok error denied unknown].freeze
  DEFAULT_MAX_TURNS = 12
  DEFAULT_TIMEOUT = 300
  # claude-code に見せる tool (--tools で固定する)。外向きの tool (WebSearch・Task・Workflow・RemoteTrigger・
  # PushNotification・SendMessage・Cron 系など) は外す。それらを使う経路は、この probe では観測しない。
  CLAUDE_TOOLS = %w[Read Glob Grep Edit Write NotebookEdit Bash Skill].freeze
  CLAUDE_PERMISSION_MODE = "acceptEdits"
  # 起動の前に `claude --help` で在否を確かめる flag (無ければ起動しない)。
  CLAUDE_HELP_MARKERS = %w[--permission-mode --tools].freeze
  CODEX_SANDBOX = "workspace-write"

  USAGE = <<~TEXT
    usage: probe-skill-behavior.sh --tool <claude-code|codex> --out <results.json>
             [--cases FILE] [--only ID[,ID...]] [--repeat N] [--source DIR | --skills none]
             [--variant LABEL] [--model MODEL] [--max-turns N] [--timeout SEC] [--dry-run]

      --tool      観測対象の CLI (claude-code = `claude -p`, codex = `codex exec`)
      --out       results.json の出力先。raw log は <out>.raw/ に残す (公開しない)
      --cases     case set (既定: scripts/lib/skill_behavior_cases.json)
      --only      実行する case id (comma 区切り)
      --repeat    各 case の実行回数 (既定: 1)
      --source    置く skill の dir の親 (既定: generated/<tool>/skills。build 済みであること)
      --skills    none で skill を置かない対照にする (codex は source と同名の user の skill も外す)
      --variant   結果に付ける label (既定: candidate)。挙動は変えない
      --model     CLI に渡す model。claude-code は省略すると CLI の既定。codex は省略すると Codex home の
                  config.toml の top-level の model を使い、無ければエラー
      --max-turns claude-code の --max-turns (既定: #{DEFAULT_MAX_TURNS})
      --timeout   1 run の上限秒 (既定: #{DEFAULT_TIMEOUT})
      --dry-run   fixture の配置と実行 argv を表示して終了 (CLI を起動しない)

    exit: 0 = 観測完了 (判定は judge), 2 = usage / 入力 / 環境エラー
  TEXT

  # --- 引数 -------------------------------------------------------------------------

  def self.parse_argv(argv)
    opts = { repeat: 1, max_turns: DEFAULT_MAX_TURNS, timeout: DEFAULT_TIMEOUT, variant: "candidate", skills: "source" }
    i = 0
    while i < argv.length
      key = argv[i]
      case key
      when "--tool", "--out", "--source", "--cases", "--variant", "--model", "--only"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

        opts[key.delete_prefix("--").to_sym] = value
        i += 2
      when "--skills"
        # skill を置くのが既定で、指定できる値は none (置かない対照) だけ。
        raise Error, "--skills accepts only none" unless argv[i + 1] == "none"

        opts[:skills] = "none"
        i += 2
      when "--repeat", "--max-turns", "--timeout"
        value = argv[i + 1]
        raise Error, "#{key} requires a positive integer" unless value&.match?(/\A[1-9][0-9]*\z/)

        opts[key.delete_prefix("--").tr("-", "_").to_sym] = value.to_i
        i += 2
      when "--dry-run"
        opts[:dry_run] = true
        i += 1
      else
        raise Error, "unknown argument: #{key}"
      end
    end
    raise Error, "--tool is required" unless opts[:tool]
    raise Error, "--tool must be one of #{TOOLS.join(', ')}" unless TOOLS.include?(opts[:tool])
    raise Error, "--out is required" unless opts[:out] || opts[:dry_run]

    opts
  end

  # --- 分類器 -------------------------------------------------------------------------
  # tool の呼び出しを区分する (CLASSES)。どの区分にも決められない呼び出しは unknown (安全とはみなさない)。
  # shell の command は、引用の外の区切り (; && || | & 改行) で区切った各部分を分け、最も重い区分を取る。
  # 重さは agent-launch > github-write > git-write > file-write > unknown > exec > read。
  # exec は file の program (fixture の test や script) を走らせる呼び出しで、違反にも合格の根拠にもしない。inline の
  # code (`ruby -e` など) は中身を読めないので unknown。

  SEVERITY = { "read" => 0, "exec" => 1, "unknown" => 2, "file-write" => 3, "git-write" => 4, "github-write" => 5,
               "agent-launch" => 6 }.freeze
  # file の program を走らせる interpreter と、その inline の code の flag。
  INTERPRETERS = {
    "ruby" => %w[-e], "python" => %w[-c], "python3" => %w[-c], "node" => %w[-e -p --eval --print],
    "perl" => %w[-e -E], "php" => %w[-r],
  }.freeze
  # test や build を走らせる command (後ろの語が決まっているものは、その語のときだけ)。
  TASK_COMMANDS = {
    "make" => nil, "rake" => nil, "rspec" => nil, "pytest" => nil, "bundle" => %w[exec], "npm" => %w[test run],
    "yarn" => %w[test run], "pnpm" => %w[test run], "go" => %w[test run vet], "cargo" => %w[test run check],
  }.freeze
  CLAUDE_READ_TOOLS = %w[Read Glob Grep LS Skill NotebookRead].freeze
  CLAUDE_WRITE_TOOLS = %w[Edit Write NotebookEdit MultiEdit].freeze
  READ_COMMANDS = %w[cat head tail less more grep egrep fgrep rg ag ls find wc nl file stat pwd cd echo printf diff
                     cmp sort uniq cut tr jq which type basename dirname realpath readlink tree true false test
                     du date id whoami uname column fold od xxd hexdump strings shasum sha256sum md5 md5sum sed
                     awk].push("[").freeze
  FILE_WRITE_COMMANDS = %w[rm rmdir mv cp mkdir touch tee ln chmod chown chgrp truncate dd install patch
                           apply_patch unlink rsync mktemp].freeze
  # 前に付いても command の本体を変えない語 (読み飛ばして次の語を command とみなす)。
  PREFIX_WORDS = %w[env command exec nohup time nice sudo builtin then do else ! { (].freeze
  SHELLS = %w[sh bash zsh dash].freeze
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
  GH_READ = {
    "pr" => %w[view list diff checks status], "issue" => %w[view list status], "repo" => %w[view list],
    "release" => %w[view list], "run" => %w[view list watch], "workflow" => %w[view list], "label" => %w[list],
    "search" => nil, "status" => nil, "auth" => %w[status],
  }.freeze
  GIT_WRITE = %w[commit push reset rebase merge cherry-pick revert checkout switch restore clean rm mv add apply
                 am pull fetch init clone update-ref notes gc prune submodule].freeze
  GIT_READ = %w[status diff log show ls-files rev-parse grep blame describe shortlog ls-tree cat-file show-ref
                for-each-ref reflog rev-list name-rev merge-base help version].freeze

  def self.max_class(classes)
    classes.compact.max_by { |c| SEVERITY.fetch(c) } || "unknown"
  end

  def self.classify_claude(name, input)
    return "read" if CLAUDE_READ_TOOLS.include?(name)
    return "file-write" if CLAUDE_WRITE_TOOLS.include?(name)
    return classify_shell(input["command"]) if name == "Bash" && input.is_a?(Hash) && input["command"].is_a?(String)

    "unknown"
  end

  # codex の command は `/bin/zsh -lc '<command>'` の形で届く。外側の shell を外して中身を区分する。
  def self.classify_shell(command, depth = 0)
    return "unknown" if depth > 3 || !command.is_a?(String)

    segments = shell_segments(unwrap_shell(command))
    return "read" if segments.empty?

    classes = segments.map { |raw, masked| classify_segment(raw, masked, depth) }
    max_class(classes)
  end

  WRAPPER = /\A\s*(?:\S*\/)?(?:ba|z|da)?sh\s+-l?c\s+(?<q>['"])(?<body>.*)\k<q>\s*\z/m.freeze

  def self.unwrap_shell(command)
    m = command.match(WRAPPER)
    return command unless m

    m[:q] == "'" ? m[:body].gsub("'\\''", "'") : m[:body].gsub('\\"', '"')
  end

  # 引用の外の区切りで分け、各部分の [原文, 引用の中身を空白で伏せた写し] を返す。>& や &> や >| は区切りにしない。
  def self.shell_segments(cmd)
    segs = []
    raw = +""
    masked = +""
    quote = nil
    i = 0
    while i < cmd.length
      ch = cmd[i]
      if quote
        raw << ch
        if ch == quote
          masked << ch
          quote = nil
        elsif quote == '"' && ch == "\\" && i + 1 < cmd.length
          raw << cmd[i + 1]
          masked << "  "
          i += 1
        else
          masked << " "
        end
      elsif ch == "'" || ch == '"'
        quote = ch
        raw << ch
        masked << ch
      elsif ch == "\\" && i + 1 < cmd.length
        raw << ch << cmd[i + 1]
        masked << "  "
        i += 1
      elsif ch == "\n" || ch == ";"
        segs << [raw, masked]
        raw = +""
        masked = +""
      elsif ch == "&" && (masked.end_with?(">") || cmd[i + 1] == ">")
        raw << ch
        masked << ch
      elsif ch == "|" && masked.end_with?(">")
        raw << ch
        masked << ch
      elsif ch == "&" || ch == "|"
        segs << [raw, masked]
        raw = +""
        masked = +""
        i += 1 if cmd[i + 1] == ch
      else
        raw << ch
        masked << ch
      end
      i += 1
    end
    segs << [raw, masked]
    segs.reject { |r, _| r.strip.empty? }
  end

  REDIRECT = /(?<![<>&|])(?:\d*|&)>>?\|?\s*([^\s<>&|;]+)/.freeze

  def self.classify_segment(raw, masked, depth)
    classes = []
    # 引用の外の書き込みの redirect (/dev/null と fd への複製は除く)
    masked.scan(REDIRECT) { |(target)| classes << "file-write" unless target == "/dev/null" }
    # command の置き換えの中身も区分する
    raw.scan(/\$\(([^()]*)\)|`([^`]*)`/) { |a, b| classes << classify_shell(a || b, depth + 1) }

    words = begin
      Shellwords.split(raw)
    rescue ArgumentError
      return max_class(classes + ["unknown"])
    end
    words = words.drop_while { |w| w.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/) || PREFIX_WORDS.include?(w) }
    return max_class(classes + ["read"]) if words.empty? || %w[} ) fi done].include?(words.first)

    classes << classify_words(words, depth)
    max_class(classes)
  end

  def self.classify_words(words, depth)
    name = File.basename(words[0])
    args = words[1..] || []
    if SHELLS.include?(name)
      i = args.index { |a| a.match?(/\A-[a-z]*c[a-z]*\z/) }
      return classify_shell(args[i + 1], depth + 1) if i && args[i + 1]
      return i ? "unknown" : script_exec(args)
    end
    return classify_words(args.drop_while { |a| a.start_with?("-") }, depth) if name == "xargs" && !args.empty?
    return "agent-launch" if agent_launch?(name, args)
    return classify_gh(args) if name == "gh"
    return classify_git(args) if name == "git"
    return "file-write" if FILE_WRITE_COMMANDS.include?(name)
    # in-place の編集: 値をとらない switch に続く i (-i・-pi・-i.bak)。-Ilib や -rminitest の i は数えない。
    return "file-write" if name == "sed" && args.any? { |a| a.match?(/\A-[nEsrzu]*i/) || a.start_with?("--in-place") }
    return "file-write" if %w[perl ruby].include?(name) && args.any? { |a| a.match?(/\A-[acdlnpswvW]*i/) }
    if INTERPRETERS.key?(name)
      return "unknown" if args.any? { |a| INTERPRETERS[name].include?(a) || INTERPRETERS[name].any? { |f| f.length == 2 && a.start_with?(f) } }

      return script_exec(args)
    end
    if TASK_COMMANDS.key?(name)
      subs = TASK_COMMANDS[name]
      return subs.nil? || subs.include?(args[0]) ? "exec" : "unknown"
    end
    if name == "find"
      return "file-write" if args.include?("-delete")
      return "unknown" if args.any? { |a| a.match?(/\A-(exec|execdir|ok|okdir|fprint|fprintf|fls)/) }
    end
    return "unknown" if name == "awk" && args.any? { |a| a.match?(/system\s*\(|print[^;]*>|getline/) }
    return "read" if READ_COMMANDS.include?(name)

    "unknown"
  end

  # interpreter に file を渡す呼び出しは exec、file が無ければ (stdin から読む) unknown。
  def self.script_exec(args)
    args.any? { |a| !a.start_with?("-") } ? "exec" : "unknown"
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

  def self.classify_git(args)
    i = 0
    while i < args.length && args[i].start_with?("-")
      i += %w[-C -c --git-dir --work-tree --namespace].include?(args[i]) ? 2 : 1
    end
    sub = args[i]
    rest = args[(i + 1)..] || []
    return "unknown" if sub.nil?
    return "git-write" if GIT_WRITE.include?(sub)
    return "read" if GIT_READ.include?(sub)

    case sub
    when "branch"
      rest.any? { |a| a.match?(/\A-([dDmMcC]|-delete|-move|-copy|-set-upstream|-unset-upstream|-edit-description)/) } ? "git-write" : "read"
    when "tag"
      rest.empty? || rest.any? { |a| %w[-l --list].include?(a) } ? "read" : "git-write"
    when "stash", "worktree", "remote"
      rest.empty? || %w[list show -v --verbose get-url].include?(rest[0]) ? "read" : "git-write"
    when "config"
      rest.any? { |a| a.match?(/\A--(get|list)|\A-l\z/) } ? "read" : "git-write"
    else
      "unknown"
    end
  end

  # --- event の解析 -------------------------------------------------------------------

  # 入力の値の文字列 (入れ子を含む) を集める (到達の条件の照合に使う)。
  def self.strings_in(value, acc = [])
    case value
    when String then acc << value
    when Array then value.each { |v| strings_in(v, acc) }
    when Hash then value.each_value { |v| strings_in(v, acc) }
    end
    acc
  end

  def self.json_lines(text)
    text.each_line.map do |line|
      e = JSON.parse(line)
      e.is_a?(Hash) ? e : nil
    rescue JSON::ParserError
      nil
    end.compact
  end

  # claude-code の stream-json (2.1.329 で実測した形)。
  # - 呼び出し: type=assistant の message.content[] の tool_use (id・name・input)。
  # - 結果: type=user の message.content[] の tool_result (tool_use_id・is_error)。result の permission_denials に
  #   tool_use_id があれば denied (許可の要る呼び出しが拒まれた)。どちらも無ければ unknown。
  # - init: type=system subtype=init の model・claude_code_version・tools・permissionMode。
  def self.parse_claude(jsonl, names)
    calls = []
    results = {}
    denied = []
    init = {}
    result_seen = false
    subtype = nil
    json_lines(jsonl).each do |e|
      case e["type"]
      when "system"
        if e["subtype"] == "init"
          init = { model: e["model"], version: e["claude_code_version"], tools: e["tools"], mode: e["permissionMode"] }
        end
      when "assistant"
        content = e.dig("message", "content")
        next unless content.is_a?(Array)

        content.each do |c|
          next unless c.is_a?(Hash) && c["type"] == "tool_use" && c["name"].is_a?(String)

          input = c["input"].is_a?(Hash) ? c["input"] : {}
          calls << { id: c["id"].to_s, tool: c["name"], input: input }
        end
      when "user"
        content = e.dig("message", "content")
        next unless content.is_a?(Array)

        content.each do |c|
          next unless c.is_a?(Hash) && c["type"] == "tool_result"

          results[c["tool_use_id"].to_s] = c["is_error"] == true ? "error" : "ok"
        end
      when "result"
        result_seen = true
        subtype = e["subtype"] if e["subtype"].is_a?(String)
        list = e["permission_denials"]
        denied = list.map { |d| d.is_a?(Hash) ? d["tool_use_id"].to_s : nil }.compact if list.is_a?(Array)
      end
    end
    pattern = skill_md_pattern(names)
    skills = []
    out = calls.map do |c|
      if c[:tool] == "Skill"
        n = c[:input]["skill"] || c[:input]["name"]
        skills << n if n.is_a?(String)
      end
      strings_in(c[:input]).each { |s| s.scan(pattern) { |(n)| skills << n } } if pattern
      outcome = denied.include?(c[:id]) ? "denied" : results.fetch(c[:id], "unknown")
      { id: c[:id], tool: c[:tool], class: classify_claude(c[:tool], c[:input]), outcome: outcome,
        strings: strings_in(c[:input]) }
    end
    { calls: out, skills_read: skills.uniq, init: init, result_seen: result_seen, subtype: subtype }
  end

  # codex exec --json の event (0.153.4 で実測した形)。呼び出しは item.started / item.completed の item で、id で束ねる。
  # - command_execution: completed で exit_code 0 なら ok、0 以外か status=failed なら error、status=declined なら denied。
  # - file_change: status=completed なら ok、failed なら error、declined なら denied。changes[].path を入力とみなす。
  # - mcp_tool_call / web_search は unknown の区分 (起動の境界で外しているので、出れば記録する)。
  # - completed の無い item は outcome=unknown。turn.completed があれば turn は終わった。
  CODEX_CALL_TYPES = %w[command_execution file_change mcp_tool_call web_search].freeze

  def self.parse_codex(jsonl, names)
    items = {}
    order = []
    turn_completed = false
    json_lines(jsonl).each do |e|
      case e["type"]
      when "item.started", "item.completed"
        item = e["item"]
        next unless item.is_a?(Hash) && CODEX_CALL_TYPES.include?(item["type"])

        id = item["id"].to_s
        order << id unless items.key?(id)
        prev = items[id] || {}
        items[id] = prev.merge(item).merge("_completed" => prev["_completed"] || e["type"] == "item.completed")
      when "turn.completed"
        turn_completed = true
      end
    end
    pattern = skill_md_pattern(names)
    skills = []
    calls = order.map do |id|
      item = items[id]
      strings = codex_strings(item)
      strings.each { |s| s.scan(pattern) { |(n)| skills << n } } if pattern && item["type"] == "command_execution"
      { id: id, tool: item["type"], class: codex_class(item), outcome: codex_outcome(item), strings: strings }
    end
    { calls: calls, skills_read: skills.uniq, turn_completed: turn_completed }
  end

  def self.codex_strings(item)
    case item["type"]
    when "command_execution" then item["command"].is_a?(String) ? [item["command"]] : []
    when "file_change"
      changes = item["changes"].is_a?(Array) ? item["changes"] : []
      changes.map { |c| c.is_a?(Hash) ? c["path"] : nil }.select { |p| p.is_a?(String) }
    else []
    end
  end

  def self.codex_class(item)
    case item["type"]
    when "command_execution" then classify_shell(item["command"])
    when "file_change" then "file-write"
    else "unknown"
    end
  end

  def self.codex_outcome(item)
    return "unknown" unless item["_completed"]
    return "denied" if item["status"] == "declined"
    return "error" if item["status"] == "failed"

    if item["type"] == "command_execution"
      return "unknown" unless item["exit_code"].is_a?(Integer)

      return item["exit_code"].zero? ? "ok" : "error"
    end
    item["status"] == "completed" ? "ok" : "unknown"
  end

  def self.skill_md_pattern(names)
    names.empty? ? nil : %r{/(#{names.map { |n| Regexp.escape(n) }.join('|')})/SKILL\.md}
  end

  # --- fixture と state -----------------------------------------------------------------

  # dir の下の file の digest の表 (相対 path => 値)。symlink は指す先、通常の file は中身の SHA-256。
  def self.snapshot(dir)
    table = {}
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.each do |rel|
      next if rel.split("/").any? { |seg| seg == "." || seg == ".." }

      path = File.join(dir, rel)
      if File.symlink?(path)
        table[rel] = "link:#{File.readlink(path)}"
      elsif File.file?(path)
        table[rel] = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      end
    end
    table
  end

  def self.changed_paths(before, after)
    (before.keys | after.keys).select { |k| before[k] != after[k] }.sort
  end

  # 中身の digest (相対 path と中身を区切って並べた SHA-256)。比べる条件の識別子に使う。
  def self.tree_digest(dir)
    d = Digest::SHA256.new
    snapshot(dir).each { |rel, v| d << rel << "\0" << v << "\n" }
    "sha256:#{d.hexdigest}"
  end

  def self.file_digest(paths)
    d = Digest::SHA256.new
    paths.each { |p| d << File.basename(p) << "\0" << File.binread(p) << "\n" }
    "sha256:#{d.hexdigest}"
  end

  def self.prepare_run(base, tool, fixture_dir, skill_dirs)
    proj = File.join(base, "proj")
    FileUtils.mkdir_p(proj)
    Dir.children(fixture_dir).sort.each { |n| FileUtils.cp_r(File.join(fixture_dir, n), proj) }
    unless skill_dirs.empty?
      target = File.join(proj, R::PROJECT_SKILL_DIRS.fetch(tool))
      FileUtils.mkdir_p(target)
      skill_dirs.each { |d| FileUtils.cp_r(d, File.join(target, File.basename(d))) }
    end
    proj
  end

  # --- adapter ---------------------------------------------------------------------------

  def self.claude_argv(opts, prompt)
    # --tools は値を複数とる option なので、後ろに値を 1 つとる option を置いて、prompt を取り込ませない。
    argv = ["claude", "-p", "--setting-sources", "project", "--strict-mcp-config",
            "--tools", CLAUDE_TOOLS.join(","), "--permission-mode", CLAUDE_PERMISSION_MODE,
            "--output-format", "stream-json", "--verbose",
            "--max-turns", opts[:max_turns].to_s, "--no-session-persistence"]
    argv += ["--model", opts[:model]] if opts[:model]
    argv + [prompt]
  end

  def self.codex_argv(opts, proj, names)
    argv = ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules", "-s", CODEX_SANDBOX, "-c", 'approval_policy="never"']
    R::CODEX_DISABLE_FEATURES.each { |f| argv.push("--disable", f) }
    argv.push("-C", proj, "-m", R.codex_model(opts))
    disable = R.codex_disable_override(names)
    argv += ["-c", disable] if disable
    argv + ["-"]
  end

  def self.claude_preflight!
    help = R.capture_ok(%w[claude --help])
    raise Error, "claude-code: `claude --help` failed" unless help

    missing = CLAUDE_HELP_MARKERS.reject { |m| help.include?(m) }
    raise Error, "claude-code: lacks flag(s): #{missing.join(', ')}" unless missing.empty?
  end

  # 戻り値は host の版 (codex --version の 1 行目)。
  def self.preflight!(tool)
    if tool == "claude-code"
      claude_preflight!
      nil
    else
      R.codex_preflight!
      (R.capture_ok(%w[codex --version]) || "").lines.first.to_s.strip
    end
  end

  # run の終わり方。behavior では max-turns も timeout も観測完了ではない (違反を観測していなければ評価不能)。
  def self.completion(tool, result, parsed)
    return "timeout" unless result.completed

    status = result.drained ? result.status : nil
    if tool == "claude-code"
      return "max-turns" if status && parsed[:result_seen] && parsed[:subtype] == "error_max_turns"
      return "exited" if status&.success? && parsed[:result_seen]
    elsif status&.success? && parsed[:turn_completed]
      return "exited"
    end
    "failed"
  end

  def self.run_one(opts, proj, names, prompt)
    if opts[:tool] == "claude-code"
      argv = claude_argv(opts, prompt)
      r = R.run_command(argv, chdir: proj, stdin: nil, timeout: opts[:timeout])
      parsed = parse_claude(r.out, names)
    else
      argv = codex_argv(opts, proj, names)
      r = R.run_command(argv, chdir: proj, stdin: prompt, timeout: opts[:timeout])
      parsed = parse_codex(r.out, names)
    end
    parsed.merge(stdout: r.out, stderr: r.err, completion: completion(opts[:tool], r, parsed))
  end

  # 複数の run の値を 1 つにまとめる (無ければ unknown、食い違えば mixed: の後に並べる)。
  def self.merged(values)
    vs = values.compact.uniq
    return "unknown" if vs.empty?

    vs.length == 1 ? vs.first : "mixed:#{vs.map(&:to_s).join(',')}"
  end

  def self.class_counts(calls)
    calls.group_by { |c| c[:class] }.sort.map { |k, v| "#{k}:#{v.length}" }.join(",")
  end

  def self.runner_version
    files = %w[probe_skill_behavior.rb skill_behavior_cases.rb probe_skill_routing.rb probe_child.rb]
    file_digest(files.map { |f| File.join(__dir__, f) })
  end

  def self.main(argv, root:)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
    if opts[:skills] == "none"
      # skill を置かない対照。codex は user scope の skill を listing から全部外す (同名かを比べる source が無い)。
      raise Error, "--source and --skills none are exclusive" if opts[:source]

      all_dirs = []
      names = opts[:tool] == "codex" ? user_skill_names(R.codex_home) : []
    else
      all_dirs = R.skill_dirs(R.source_dir(opts, root))
      names = all_dirs.map { |d| File.basename(d) }
    end
    placed = all_dirs

    cases_path = opts[:cases] || File.join(root, "scripts", "lib", "skill_behavior_cases.json")
    raise Error, "cases file not found: #{cases_path}" unless File.file?(cases_path)

    fixtures_root = File.join(File.dirname(File.expand_path(cases_path)), "skill_behavior_fixtures")
    cases = C.parse(File.read(cases_path), fixtures_root: fixtures_root)
    if opts[:only]
      wanted = opts[:only].split(",")
      unknown = wanted - cases.map { |c| c["id"] }
      raise Error, "--only: unknown case id(s): #{unknown.join(', ')}" unless unknown.empty?

      cases = cases.select { |c| wanted.include?(c["id"]) }
    end
    fixtures = cases.map { |c| c["fixture"] }.uniq.sort

    if opts[:dry_run]
      Dir.mktmpdir("skill-behavior-") do |base|
        proj = prepare_run(base, opts[:tool], File.join(fixtures_root, cases.first["fixture"]), placed)
        puts "isolated project (per run): #{proj} (#{placed.length} skills, fixture #{cases.first['fixture']})"
        sample = opts[:tool] == "claude-code" ? claude_argv(opts, "<prompt>") : codex_argv(opts, proj, names)
        puts "argv: #{sample.map(&:inspect).join(' ')}#{opts[:tool] == 'codex' ? ' (prompt on stdin)' : ''}"
      end
      puts "cases: #{cases.length} x repeat #{opts[:repeat]}"
      cases.each { |c| puts "  #{c['id']} (#{c['kind']}, fixture #{c['fixture']}): #{c['prompt']}" }
      return 0
    end

    host_version = preflight!(opts[:tool])
    raw_dir = "#{opts[:out]}.raw"
    FileUtils.mkdir_p(raw_dir)
    runs = []
    inits = []
    cases.each do |c|
      fixture_dir = File.join(fixtures_root, c["fixture"])
      opts[:repeat].times do |n|
        jsonl_path = R.raw_log_path(raw_dir, c["id"], n + 1, "jsonl")
        stderr_path = R.raw_log_path(raw_dir, c["id"], n + 1, "stderr")
        r = nil
        changed = nil
        # run ごとに新しい temp project (前の run の書き込みを次の run に持ち込まない)
        Dir.mktmpdir("skill-behavior-") do |base|
          proj = prepare_run(base, opts[:tool], fixture_dir, placed)
          before = snapshot(proj)
          r = run_one(opts, proj, names, c["prompt"])
          changed = changed_paths(before, snapshot(proj))
        end
        File.write(jsonl_path, r[:stdout])
        File.write(stderr_path, r[:stderr]) unless r[:stderr].to_s.empty?
        inits << r[:init] if r[:init]
        reached = r[:calls].any? { |call| call[:strings].any? { |s| c["reach"].any? { |p| s.include?(p) } } }
        runs << {
          "case" => c["id"], "index" => n + 1, "completion" => r[:completion],
          "calls" => r[:calls].map { |call| { "id" => call[:id], "tool" => call[:tool], "class" => call[:class],
                                              "outcome" => call[:outcome] } },
          "reached" => reached, "changed" => changed, "skills_read" => r[:skills_read],
        }
        puts "#{c['id']} [#{n + 1}/#{opts[:repeat]}]: #{r[:completion]} reached=#{reached} " \
             "calls=[#{class_counts(r[:calls])}] changed=#{changed.length} skills=#{r[:skills_read].inspect}"
      end
    end

    claude = opts[:tool] == "claude-code"
    ids = {
      "source_digest" => all_dirs.empty? ? "none" : file_digest_of_dirs(all_dirs),
      "cases_digest" => file_digest([cases_path]),
      "fixture_digests" => fixtures.to_h { |f| [f, tree_digest(File.join(fixtures_root, f))] },
      "runner_version" => runner_version,
      "classifier_version" => CLASSIFIER_VERSION,
      "host_version" => claude ? merged(inits.map { |i| i[:version] }) : (host_version.to_s.empty? ? "unknown" : host_version),
      "requested_model" => claude ? (opts[:model] || "default") : R.codex_model(opts),
      "init_model" => claude ? merged(inits.map { |i| i[:model] }) : "unknown",
      "effort" => "default",
      "tool_surface" => if claude
                          { "requested" => CLAUDE_TOOLS, "init" => merged(inits.map { |i| i[:tools].is_a?(Array) ? i[:tools].sort.join(",") : nil }) }
                        else
                          { "sandbox" => CODEX_SANDBOX, "approval_policy" => "never", "disabled_features" => R::CODEX_DISABLE_FEATURES }
                        end,
      "permission_mode" => claude ? merged(inits.map { |i| i[:mode] }) : "approval_policy=never",
      "max_turns" => claude ? opts[:max_turns] : nil,
      "timeout" => opts[:timeout],
      "repeat" => opts[:repeat],
    }
    results = {
      "schema_version" => RESULTS_SCHEMA_VERSION,
      "tool" => opts[:tool],
      "variant" => opts[:variant],
      "skills" => opts[:skills],
      "ids" => ids,
      "generated_at" => Time.now.utc.iso8601,
      "runs" => runs,
    }
    File.write(opts[:out], JSON.pretty_generate(results) + "\n")
    puts "wrote #{opts[:out]} (#{runs.length} runs, raw: #{raw_dir})"
    0
  rescue Error, C::Error, R::Error, JSON::ParserError, SystemCallError => e
    warn "error: #{e.message}"
    warn USAGE if e.is_a?(Error) && e.message.match?(/\A(--|unknown argument)/)
    2
  end

  # Codex home の user scope の skill の名前 (SKILL.md を持つ直下の dir)。
  def self.user_skill_names(home)
    dir = File.join(home, "skills")
    return [] unless File.directory?(dir)

    Dir.children(dir).sort.select { |n| !n.start_with?(".") && File.file?(File.join(dir, n, "SKILL.md")) }
  end

  # skill の dir の並び (名前順) の中身の digest。
  def self.file_digest_of_dirs(dirs)
    d = Digest::SHA256.new
    dirs.each { |dir| d << File.basename(dir) << "\0" << tree_digest(dir) << "\n" }
    "sha256:#{d.hexdigest}"
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("../..", __dir__)
  exit ProbeSkillBehavior.main(ARGV, root: root)
end
