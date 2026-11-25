#!/usr/bin/env ruby
# frozen_string_literal: true

# skill の挙動の評価 (#369) の probe runner (実機)。Spec: docs/skill-behavior-eval.md。
#
# case ごとに fixture と、case の place_skills の skill (#737) を新しい temp project に置き、1 回の user の依頼を
# claude / codex の headless 実行に流す。
# model が tool に求めた操作を、event stream の呼び出しの記録から区分し (分類器)、run の後の project の差分と
# 合わせて results.json に残す。判定は judge (#369 の PR 2) が行う。
#
# 責務境界 (honest):
#   - 測るのは、1 回の依頼から run の終わりまでに model が求めた操作。前の turn のある case (#769) だけは、2 turn の会話を turn ごとに
#     1 つの process で流し、turn ごとに呼び出しと差分を残す。この case だけ、session の記録が home にできる (その run の記録だけを
#     消す。skill_behavior_session.rb)。
#   - 書き込みは run ごとの temp project の中に閉じる。claude-code は --permission-mode acceptEdits (作業 directory の
#     中の編集だけを自動で許可し、Bash などは -p の既定のまま拒否される)、codex は -s workspace-write (network なし)。
#     probe 自身は tool home (~/.claude / ~/.codex) に書かない。claude-code の子 process には自動の memory を止める環境を渡す
#     (#770。止めないと、run ごとに ~/.claude/projects の下に dir ができる)。CLI 自身が home に置く状態の file (認証・
#     cache・log など) は見ていない。
#   - skill の無い条件は、両方の target で、運用 instruction と user の skill の両方が無い条件 (#731)。claude-code は
#     --setting-sources project で user の instruction と skill を読まない。codex は global の AGENTS.md を止める設定が
#     無いので、人がログインした評価用の home (--codex-home) で起動し、子 process にだけ CODEX_HOME を渡す。
#   - 呼び出しの要求 (calls) と、その結果 (outcome) と、state の変化 (changed) を別の欄に残す。要求があっても、
#     外へ書けたことの証拠にはしない。
#   - command の本文と prompt は results.json に入れず、raw log (<out>.raw/) にだけ置く。raw log は model が読んだ
#     file の中身を含みうるので、公開しない。
#   - 区分は分類器 (skill_behavior_classifier.rb) が決める。
#   - 正例の case に fix_check があれば、run の後の code を隔離の中で走らせ、修正の正しさを別の欄に残す (#763)。
#     検査は skill_behavior_fix_check.rb。区分と差分には影響しない。
#   - routing probe (probe_skill_routing.rb) の codex の起動の境界・preflight・model の選び方・子 process の期限は
#     共有する。user の skill の無効化 (skills.config) は使わない (評価用の home に user の skill が無いため)。
#     終わり方 (completion) と観測は共有しない (routing の max-turns や
#     observed-stop は、ここでは観測完了ではない)。
#   - CI では実行しない (CLI 認証と network が要る)。self-test は偽の CLI で行う。

require "digest"
require "fileutils"
require "json"
require "ripper"
require "securerandom"
require "shellwords"
require "tmpdir"
require "time"
require_relative "auto_memory"
require_relative "probe_child"
require_relative "probe_skill_routing"
require_relative "skill_behavior_cases"
require_relative "skill_behavior_classifier"
require_relative "skill_behavior_fix_check"
require_relative "skill_behavior_session"

# C locale でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ProbeSkillBehavior
  class Error < StandardError; end

  R = ProbeSkillRouting
  C = SkillBehaviorCases
  K = SkillBehaviorClassifier
  FX = SkillBehaviorFixCheck
  SS = SkillBehaviorSession
  TOOLS = %w[claude-code codex].freeze
  RESULTS_SCHEMA_VERSION = 1
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
  # 前の turn のある case (#769) を含むときに、加えて確かめる flag。
  CLAUDE_TURN_HELP_MARKERS = %w[--session-id --resume].freeze
  # 始めなかった最後の turn の記録 (#769)。
  NOT_STARTED_TURN = { "completion" => "not-started", "calls" => [], "reached" => false, "changed" => [], "skills_read" => [],
                       "skills_unresolved" => false }.freeze
  CODEX_SANDBOX = "workspace-write"
  # workspace-write の sandbox が書ける所を temp project (-C の dir) の中だけにする (#733)。既定では /tmp と $TMPDIR にも
  # 書け、その書き込みは temp project の差分に現れない。起動の argv と ids.tool_surface の両方をここから作る。
  CODEX_SANDBOX_CONFIG = {
    "sandbox_workspace_write.exclude_slash_tmp" => "true",
    "sandbox_workspace_write.exclude_tmpdir_env_var" => "true",
  }.freeze
  # 評価用の Codex の home に在ってはいけない file (大文字小文字を区別しない。#731)。
  EVAL_HOME_FORBIDDEN = %w[agents.md agents.override.md].freeze
  # results.json の ids.conditions (skill の無い条件。値は決まったものだけ)。
  CONDITIONS = {
    "claude-code" => { "setting_sources" => "project" },
    "codex" => { "home" => "eval", "user_instructions" => "absent", "user_skills" => "absent" },
  }.freeze

  USAGE = <<~TEXT
    usage: probe-skill-behavior.sh --tool <claude-code|codex> --out <results.json>
             [--cases FILE] [--only ID[,ID...]] [--repeat N] [--source DIR | --skills none]
             [--variant LABEL] [--model MODEL] [--max-turns N] [--timeout SEC] [--codex-home DIR] [--dry-run]

      --tool      観測対象の CLI (claude-code = `claude -p`, codex = `codex exec`)
      --out       results.json の出力先。raw log は <out>.raw/ に残す (公開しない)
      --cases     case set (既定: scripts/lib/skill_behavior_cases.json)。fixture は同じ dir の
                  skill_behavior_fixtures/ から探す
      --only      実行する case id (comma 区切り)
      --repeat    各 case の実行回数 (既定: 1)
      --source    skill の dir の親 (既定: generated/<tool>/skills。build 済みであること)。case の
                  place_skills の skill だけを置き、source に無い名前があれば止める
      --skills    none で skill を置かない対照にする
      --variant   結果に付ける label (既定: candidate)。英数字と . _ - の 64 字まで。挙動は変えない
      --model     CLI に渡す model。claude-code は省略すると CLI の既定。codex は省略すると Codex home の
                  config.toml の top-level の model を使い、無ければエラー
      --max-turns claude-code の --max-turns (既定: #{DEFAULT_MAX_TURNS})
      --timeout   1 run の上限秒 (既定: #{DEFAULT_TIMEOUT})
      --codex-home 評価用の Codex の home (codex の run では必須。--dry-run では省ける)。人がその dir で
                  `codex login` した絶対 path の dir で、auth.json だけを持ち、AGENTS.md・AGENTS.override.md と
                  skills/ の下の skill を持たないこと。ふだんの home とは別の dir にする (docs/skill-behavior-eval.md)
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
      when "--tool", "--out", "--source", "--cases", "--variant", "--model", "--only", "--codex-home"
        value = argv[i + 1]
        raise Error, "#{key} requires a value" if value.nil? || value.start_with?("-")

        opts[key.delete_prefix("--").tr("-", "_").to_sym] = value
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
    # variant は results.json に入り、judge の出力に写る。決まった文字だけにする (judge も同じ形を求める)。
    raise Error, "--variant must match #{C::LABEL_PATTERN.source}" unless opts[:variant].match?(C::LABEL_PATTERN)
    raise Error, "--codex-home is only for --tool codex" if opts[:codex_home] && opts[:tool] != "codex"
    if opts[:tool] == "codex" && !opts[:codex_home] && !opts[:dry_run]
      raise Error, "--codex-home is required for --tool codex (an eval-only Codex home; docs/skill-behavior-eval.md)"
    end

    opts
  end

  # 評価用の Codex の home を確かめ、実 path を返す (#731)。auth.json の中身は読まない。
  def self.eval_codex_home!(dir)
    raise Error, "--codex-home must be an absolute path" unless dir.start_with?("/")

    st = begin
      File.lstat(dir)
    rescue Errno::ENOENT
      raise Error, "--codex-home does not exist"
    end
    raise Error, "--codex-home must not be a symlink" if st.symlink?
    raise Error, "--codex-home must be a directory" unless st.directory?

    real = File.realpath(dir)
    usual = R.codex_home
    # 文字列ではなく実体で比べる (大文字小文字を区別しない file system では、同じ dir の実 path の表記が変わりうる)
    if File.exist?(usual) && File.identical?(usual, real)
      raise Error, "--codex-home must not be the usual Codex home"
    end

    auth = begin
      File.lstat(File.join(real, "auth.json"))
    rescue Errno::ENOENT
      raise Error, "--codex-home has no auth.json (log in once with CODEX_HOME set to the dir)"
    end
    raise Error, "--codex-home: auth.json must be a regular file" unless auth.file?

    found = Dir.children(real).select { |n| EVAL_HOME_FORBIDDEN.include?(n.downcase) }
    raise Error, "--codex-home must not have #{found.sort.join(', ')}" unless found.empty?

    skills = File.join(real, "skills")
    if File.symlink?(skills)
      raise Error, "--codex-home: skills must not be a symlink"
    elsif File.directory?(skills)
      user = Dir.children(skills).reject { |n| n.start_with?(".") }
      raise Error, "--codex-home must not have user skills (#{user.length} under skills/)" unless user.empty?
    elsif File.exist?(skills)
      raise Error, "--codex-home: skills must be a directory"
    end
    real
  rescue SystemCallError => e
    raise Error, "--codex-home could not be checked (#{e.class})"
  end

  # 各 codex exec の前に、評価用の home を検査し直し、最初に確かめた dir と同じ実体かも確かめる (#731。review の
  # round 1)。run の間に AGENTS.md や skill が足された、dir を差し替えられた、のどれでも起動せずに止める。
  def self.recheck_codex_home!(opts)
    real = eval_codex_home!(opts[:codex_home])
    st = File.stat(real)
    return if real == opts[:codex_home] && [st.dev, st.ino] == opts[:codex_home_id]

    raise Error, "--codex-home changed during the probe"
  rescue SystemCallError => e
    raise Error, "--codex-home could not be checked (#{e.class})"
  end

  # codex の子 process にだけ足す環境 (probe の process の環境は変えない)。
  def self.codex_env(opts)
    opts[:codex_home] ? { "CODEX_HOME" => opts[:codex_home] } : {}
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
  # - init: type=system subtype=init の model・claude_code_version・tools・permissionMode。memory_states は、init ごとの
  #   自動の memory の状態 (memory_paths から。#770)。session_ids は、init の session_id の並び (#769)。
  # shown: 中身を出す検索 (Grep の output_mode が content) の、誤りでない結果の本文 (同じ id の結果が複数なら全部。#778)。到達の判定の間だけ持ち、results.json には入れない。
  def self.parse_claude(jsonl, names, fixture = K::NO_FIXTURE)
    calls = []
    results = {}
    outputs = Hash.new { |h, k| h[k] = [] }
    denied = []
    init = {}
    memory_states = []
    session_ids = []
    result_seen = false
    subtype = nil
    json_lines(jsonl).each do |e|
      case e["type"]
      when "system"
        if e["subtype"] == "init"
          memory_states << AutoMemory.state(e)
          session_ids << e["session_id"]
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
          outputs[c["tool_use_id"].to_s] << result_text(c["content"])
        end
      when "result"
        result_seen = true
        subtype = e["subtype"] if e["subtype"].is_a?(String)
        list = e["permission_denials"]
        denied = list.map { |d| d.is_a?(Hash) ? d["tool_use_id"].to_s : nil }.compact if list.is_a?(Array)
      end
    end
    skills = []
    unresolved = false
    out = calls.map do |c|
      if c[:tool] == "Skill"
        n = c[:input]["skill"] || c[:input]["name"]
        skills << n if n.is_a?(String)
      end
      found, u = skill_reads(strings_in(c[:input]), names)
      skills.concat(found)
      unresolved ||= u
      outcome = denied.include?(c[:id]) ? "denied" : results.fetch(c[:id], "unknown")
      { id: c[:id], tool: c[:tool], class: K.classify_claude(c[:tool], c[:input], fixture: fixture), outcome: outcome,
        strings: strings_in(c[:input]),
        shown: outcome == "ok" && c[:tool] == "Grep" && c[:input]["output_mode"] == "content" ? outputs[c[:id]].join("\n") : nil }
    end
    { calls: out, skills_read: skills.uniq, skills_unresolved: unresolved, init: init, memory_states: memory_states,
      session_ids: session_ids.uniq, result_seen: result_seen, subtype: subtype }
  end

  # tool_result の content (文字列か、text の並び) の本文。
  def self.result_text(content)
    return content if content.is_a?(String)

    (content.is_a?(Array) ? content : []).map { |x| x.is_a?(Hash) && x["type"] == "text" && x["text"].is_a?(String) ? x["text"] : "" }.join("\n")
  end

  # case の reach の file に届いたか。入力に path を含む呼び出し、または、中身を出す検索の結果に「path:」で始まる行がある (#778。一致した
  # 行の形。検索の結果の path は、作業 dir からの相対で出る)。
  def self.reached?(calls, reach)
    calls.any? do |call|
      reach.any? do |p|
        call[:strings].any? { |s| s.include?(p) } || (call[:shown] && call[:shown].match?(/^#{Regexp.escape(p)}:/))
      end
    end
  end

  # codex exec --json の event (0.153.4 で実測した形)。呼び出しは item.started / item.completed の item で、id で束ねる。
  # - command_execution: completed で exit_code 0 なら ok、0 以外か status=failed なら error、status=declined なら denied。
  # - file_change: status=completed なら ok、failed なら error、declined なら denied。changes[].path を入力とみなす。
  # - mcp_tool_call / web_search は unknown の区分 (起動の境界で外しているので、出れば記録する)。
  # - completed の無い item は outcome=unknown。turn.completed があれば turn は終わった。
  CODEX_CALL_TYPES = %w[command_execution file_change mcp_tool_call web_search].freeze

  def self.parse_codex(jsonl, names, fixture = K::NO_FIXTURE)
    items = {}
    order = []
    session_ids = []
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
      when "thread.started"
        session_ids << e["thread_id"]
      when "turn.completed"
        turn_completed = true
      end
    end
    skills = []
    unresolved = false
    calls = order.map do |id|
      item = items[id]
      strings = codex_strings(item)
      if item["type"] == "command_execution"
        found, u = skill_reads(strings, names)
        skills.concat(found)
        unresolved ||= u
      end
      { id: id, tool: item["type"], class: codex_class(item, fixture), outcome: codex_outcome(item), strings: strings }
    end
    { calls: calls, skills_read: skills.uniq, skills_unresolved: unresolved, session_ids: session_ids.uniq,
      turn_completed: turn_completed }
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

  def self.codex_class(item, fixture = K::NO_FIXTURE)
    case item["type"]
    when "command_execution" then K.classify_shell(item["command"], fixture: fixture)
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

  # skill の file の読み取りの検出 (#731。review の round 1〜6)。決まり: 名前を決められない読み取りは、呼び出しの区分とは
  # 分けて、run の印 (skills_unresolved) で judge に渡す。区分は分類器のまま変えない (書き込みと同居しても印は消えない)。
  # shell は静的に解釈しきれないので、#717 の分類器と同じく、名前に結び付ける前に文字の形の門を置き、受ける形を 1 つに絞る。
  #   1. 門: `skill.md` の字 (大文字小文字を区別しない。部分の一致) を含む文字列に、展開・連結・glob になりうる字
  #      (`$`・backtick・`\`・`{}`・`()`・`*?[]`・改行) が 1 つでもあれば、その文字列は名前を決められない (印を立てる)。
  #   2. 門を通った文字列では、`skill.md` の字の出てくる所ごとに、次の形だけを、その名前の dir の SKILL.md の読み取りに
  #      する (`/./` は `/` にしてから見る)。`<要素>/SKILL.md` で、直前が `/`、その前の要素が具体的な名前 (英数字と `._-`。
  #      `.` と `..` を除く)、直後が末尾か区切りの字 (空白・引用・`;&|()<>`)。要素の直前は `/`・先頭・空白とタブ・`=`・
  #      `;&|(<>` のどれか (引用・backtick・`)` の直後の要素は、shell が前の部分とつないで名前の途中になりうるので受けない)。
  # この形でない所 (単独の `SKILL.md`、`cd` してからの読み取り、`..`、引用でつないだ名前、`foo-SKILL.md`・`SKILL.md.bak`)
  # が 1 つでもあれば、印を立てる (同じ文字列にほかの名前が見つかっても消さない)。名前が names にあれば skills_read に足す
  # (門で止めた文字列からは、展開の後の名前が分からないので記録しない)。
  # 名前だけは、独立した単引用の語を外した写しからも探して足す (#740)。Codex の command は 1 つの文字列なので、同じ script の
  # 別の語 (`rg -g '*median*'`) の glob で門が閉じるため。外すのは、前が先頭・空白・tab、後ろが末尾・空白・tab・`;&|)` の
  # `'…'` で、中に `skill.md` の字を含まないものだけ。印は元の文字列だけで決める。外した語を `sh -c` などが実行すると、写しでは
  # 読み取りが消えうるので (相談の反例)、写しは名前を増やす向きにしか使わない (対照で増えれば judge が止める)。
  SKILL_MD_GATE = /[$`\\{}()*?\[\]\n]/.freeze
  SKILL_MD_AFTER = /\A(?:\z|[\s"'`;&|()<>])/.freeze
  SEGMENT_BEFORE_SLASH = %r{(?:\A|[/ \t=;&|(<>])([^/\s"'`;&|()<>=]*)/\z}.freeze
  CONCRETE_SEGMENT = /\A[A-Za-z0-9._-]+\z/.freeze
  LITERAL_WORD = /(?<=\A|[ \t])'[^']*'(?=\z|[ \t;&|)])/.freeze

  def self.skill_reads(strings, names)
    found, unresolved = strict_skill_reads(strings, names)
    loose, = strict_skill_reads(strings.map { |s| without_literal_words(s) }, names)
    [(found + loose).uniq, unresolved]
  end

  def self.without_literal_words(s)
    s.gsub(LITERAL_WORD) { |w| w.match?(/skill\.md/i) ? w : " " }
  end

  def self.strict_skill_reads(strings, names)
    by_name = names.to_h { |n| [n.downcase, n] }
    found = []
    unresolved = false
    strings.each do |s|
      next unless s.match?(/skill\.md/i)

      if s.match?(SKILL_MD_GATE)
        unresolved = true
        next
      end

      norm = s.gsub(%r{/(?:\./)+}, "/")
      norm.to_enum(:scan, /skill\.md/i).each do
        m = Regexp.last_match
        seg = norm[0...m.begin(0)][SEGMENT_BEFORE_SLASH, 1]
        if seg&.match?(CONCRETE_SEGMENT) && !%w[. ..].include?(seg) && norm[m.end(0)..].match?(SKILL_MD_AFTER)
          n = by_name[seg.downcase]
          found << n if n
        else
          unresolved = true
        end
      end
    end
    [found.uniq, unresolved]
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

  # fixture と skill の dir を新しい project に copy する。どちらかに symlink があれば copy の前に止める (copy した
  # link を経て、後の配置が project の外へ書くのを防ぐ)。配置の後に、skill の置き場の実 path が project の中かを確かめる。
  def self.prepare_run(base, tool, fixture_dir, skill_dirs)
    C.assert_no_symlinks!(fixture_dir, "fixture")
    skill_dirs.each { |d| C.assert_no_symlinks!(d, "skill") }
    proj = File.join(base, "proj")
    FileUtils.mkdir_p(proj)
    Dir.children(fixture_dir).sort.each { |n| FileUtils.cp_r(File.join(fixture_dir, n), proj) }
    unless skill_dirs.empty?
      target = File.join(proj, R::PROJECT_SKILL_DIRS.fetch(tool))
      FileUtils.mkdir_p(target)
      unless File.realpath(target).start_with?("#{File.realpath(proj)}/")
        raise Error, "skill target escapes the isolated project: #{R::PROJECT_SKILL_DIRS.fetch(tool)}"
      end

      skill_dirs.each { |d| FileUtils.cp_r(d, File.join(target, File.basename(d))) }
    end
    proj
  end

  # link をたどらずに書く (既にある symlink の先を上書きしない)。dir があれば、作ったときと同じ実 path の dir かも
  # 確かめる (Codex は一時 directory に書けるので、run の間に link に差し替えられうる)。
  def self.write_no_follow(path, content, dir: nil, dir_real: nil)
    if dir
      st = File.lstat(dir)
      unless st.directory? && !st.symlink? && File.realpath(dir) == dir_real
        raise Error, "refusing to write: #{dir} is no longer the raw log directory"
      end
    end
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o644) { |f| f.write(content) }
  rescue Errno::ELOOP
    raise Error, "refusing to write through a symlink: #{path}"
  end

  # --- adapter ---------------------------------------------------------------------------

  # session は、前の turn のある case の turn (#769)。{ id:, resume: } で、無ければ記録を残さない 1 回の run。
  def self.claude_argv(opts, prompt, session = nil)
    # --tools は値を複数とる option なので、後ろに値を 1 つとる option を置いて、prompt を取り込ませない。
    argv = ["claude", "-p", "--setting-sources", "project", "--strict-mcp-config",
            "--tools", CLAUDE_TOOLS.join(","), "--permission-mode", CLAUDE_PERMISSION_MODE,
            "--output-format", "stream-json", "--verbose",
            "--max-turns", opts[:max_turns].to_s]
    argv += session ? [session[:resume] ? "--resume" : "--session-id", session[:id]] : ["--no-session-persistence"]
    argv += ["--model", opts[:model]] if opts[:model]
    argv + [prompt]
  end

  # 評価用の home には user の skill が無いので、user の skill を外す skills.config は渡さない (#731)。
  # 再開した turn (#769) は 1 turn 目の sandbox を引き継がないので、sandbox・承認・除外の設定を渡し直す (exec resume には -s と -C が
  # 無い。作業 dir は起動した dir になる)。
  def self.codex_argv(opts, proj, session = nil)
    argv = if session && session[:resume]
             ["codex", "exec", "resume", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
              "-c", "sandbox_mode=\"#{CODEX_SANDBOX}\"", "-c", 'approval_policy="never"']
           else
             ["codex", "exec", "--json", *(session ? [] : ["--ephemeral"]), "--skip-git-repo-check",
              "--ignore-user-config", "--ignore-rules", "-s", CODEX_SANDBOX, "-c", 'approval_policy="never"']
           end
    R::CODEX_DISABLE_FEATURES.each { |f| argv.push("--disable", f) }
    CODEX_SANDBOX_CONFIG.each { |k, v| argv.push("-c", "#{k}=#{v}") }
    argv.push("-C", proj) unless session && session[:resume]
    argv.push("-m", R.codex_model(opts))
    argv.push(session[:id]) if session && session[:resume]
    argv + ["-"]
  end

  def self.claude_preflight!(turns)
    help = R.capture_ok(%w[claude --help], env: AutoMemory::ENV_OFF)
    raise Error, "claude-code: `claude --help` failed" unless help

    missing = (CLAUDE_HELP_MARKERS + (turns ? CLAUDE_TURN_HELP_MARKERS : [])).reject { |m| help.include?(m) }
    raise Error, "claude-code: lacks flag(s): #{missing.join(', ')}" unless missing.empty?
  end

  # 前の turn のある case (#769) で使う exec resume にも、境界の flag が在ることを確かめる。
  def self.codex_turn_preflight!(env)
    help = R.capture_ok(%w[codex exec resume --help], env: env)
    raise Error, "codex: `codex exec resume --help` failed" unless help

    missing = R::CODEX_HELP_MARKERS.reject { |m| help.include?(m) }
    raise Error, "codex: exec resume lacks boundary flag(s): #{missing.join(', ')}" unless missing.empty?
  end

  # 戻り値は host の版 (codex --version の 1 行目)。turns は、前の turn のある case を含むか。
  def self.preflight!(tool, env, turns: false)
    if tool == "claude-code"
      claude_preflight!(turns)
      nil
    else
      R.codex_preflight!(env: env)
      codex_turn_preflight!(env) if turns
      (R.capture_ok(%w[codex --version], env: env) || "").lines.first.to_s.strip
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

  # fixture は case の fixture の情報 (fixture_info)。分類器が inline の Ruby の中で許す関数と -r の名前に使う (#737・#742)。
  def self.run_one(opts, proj, names, prompt, fixture = K::NO_FIXTURE, session = nil)
    if opts[:tool] == "claude-code"
      argv = claude_argv(opts, prompt, session)
      r = R.run_command(argv, chdir: proj, stdin: nil, timeout: opts[:timeout], env: AutoMemory::ENV_OFF)
      parsed = parse_claude(r.out, names, fixture)
    else
      argv = codex_argv(opts, proj, session)
      r = R.run_command(argv, chdir: proj, stdin: prompt, timeout: opts[:timeout], env: codex_env(opts))
      parsed = parse_codex(r.out, names, fixture)
    end
    parsed.merge(stdout: r.out, stderr: r.err, completion: completion(opts[:tool], r, parsed))
  end

  # 1 つの turn を走らせ、その turn の前後の差分を足す。
  def self.run_turn(opts, proj, names, prompt, fixture, session = nil)
    before = snapshot(proj)
    recheck_codex_home!(opts) if opts[:tool] == "codex"
    r = run_one(opts, proj, names, prompt, fixture, session)
    r.merge(changed: changed_paths(before, snapshot(proj)))
  end

  # 前の turn のある case の run (#769) の結果。turns は走らせた turn (始めなかった turn は無い)。resumed は、最後の turn が同じ session を
  # 再開したか (始めなかったら nil)。contexts は Codex の turn ごとの実際の設定。left は、消し残した session の記録の数。
  Turns = Struct.new(:turns, :resumed, :contexts, :left, keyword_init: true)

  # 最後の turn は、前の turn が exited で終わり、session の id が 1 つだけ取れたときに始める。session の記録は、終わり方 (途中の例外と
  # 割り込みを含む) によらず、この run の分だけを消す。
  def self.run_turns(opts, proj, names, c, fixture)
    claude = opts[:tool] == "claude-code"
    id = claude ? SecureRandom.uuid : nil
    out = Turns.new(turns: [], contexts: [])
    existing = claude ? nil : SS.codex_entries(opts[:codex_home])
    seen = 0
    prompts = c["before"].map { |b| b["prompt"] } + [c["prompt"]]
    prompts.each_with_index do |prompt, i|
      r = run_turn(opts, proj, names, prompt, fixture, { id: id, resume: i.positive? })
      out.turns << r
      ids = r[:session_ids]
      id = ids.first if i.zero? && !claude && ids.length == 1
      out.resumed = resumed_state(ids, id) if i.positive?
      unless claude
        all = id ? SS.codex_contexts(opts[:codex_home], id, proj) : nil
        fresh = (all || []).drop(seen)
        out.contexts.concat(fresh.empty? ? ["unknown"] : fresh)
        seen = all.length if all
      end
      break unless r[:completion] == "exited" && SS.id?(id) && ids == [id]
    end
    out
  ensure
    if out
      out.left = claude ? SS.remove_claude(SS.claude_projects, id) : SS.remove_codex(opts[:codex_home], proj, existing || [])
    end
  end

  # 再開した turn の session の id が、前の turn と同じか (id が取れなければ unknown)。
  def self.resumed_state(ids, id)
    return "unknown" if ids.compact.empty?

    ids == [id] ? "same" : "differs"
  end

  # results.json の 1 つの turn の記録。
  def self.turn_record(r, c)
    { "completion" => r[:completion],
      "calls" => r[:calls].map { |call| { "id" => call[:id], "tool" => call[:tool], "class" => call[:class], "outcome" => call[:outcome] } },
      "reached" => reached?(r[:calls], c["reach"]),
      "changed" => r[:changed], "skills_read" => r[:skills_read], "skills_unresolved" => r[:skills_unresolved] }
  end

  def self.turn_label(t)
    "#{t['completion']} reached=#{t['reached']} calls=[#{class_counts(t['calls'])}] changed=#{t['changed'].length} skills=#{t['skills_read'].inspect}"
  end

  # 複数の run の値を 1 つにまとめる (無ければ unknown、食い違えば mixed: の後に並べる)。
  def self.merged(values)
    vs = values.compact.uniq
    return "unknown" if vs.empty?

    vs.length == 1 ? vs.first : "mixed:#{vs.map(&:to_s).join(',')}"
  end

  def self.class_counts(calls)
    calls.group_by { |c| c["class"] }.sort.map { |k, v| "#{k}:#{v.length}" }.join(",")
  end

  def self.runner_version
    files = %w[probe_skill_behavior.rb skill_behavior_cases.rb skill_behavior_classifier.rb skill_behavior_fix_check.rb
               probe_skill_routing.rb probe_child.rb auto_memory.rb skill_behavior_session.rb]
    file_digest(files.map { |f| File.join(__dir__, f) })
  end

  # 修正の正しさの検査 (#763) が、手を付けていない fixture を「合わない」と見分けるかを、model を起動する前に確かめる。
  # run と同じく temp project に写して当てる。見分けないとき (検査が通る・測れない・例が 1 つも合わない) は起動しない。
  def self.fix_preflight!(cases, tool, fixtures_root)
    cases.select { |c| c["fix_check"] }.each do |c|
      outcome = Dir.mktmpdir("skill-behavior-") do |base|
        FX.run(prepare_run(base, tool, File.join(fixtures_root, c["fixture"]), []), c["fix_check"])
      end
      next if FX.detects_untouched?(outcome)

      raise Error, "case #{c['id']}: fix_check must fail on the untouched fixture as failed/wrong with at least one " \
                   "passing example (got #{outcome.label})"
    end
  end

  def self.main(argv, root:)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    opts = parse_argv(argv)
    if opts[:codex_home]
      opts[:codex_home] = eval_codex_home!(opts[:codex_home])
      st = File.stat(opts[:codex_home])
      opts[:codex_home_id] = [st.dev, st.ino]
    end
    if opts[:skills] == "none"
      # skill を置かない対照。names は読み取りの検出だけに使う (ふだんの home の user の skill の file を読んだら、
      # skills_read に残す。下で case の期待した skill も足す)。
      raise Error, "--source and --skills none are exclusive" if opts[:source]

      all_dirs = []
      names = opts[:tool] == "codex" ? user_skill_names(R.codex_home) : []
    else
      all_dirs = R.skill_dirs(R.source_dir(opts, root))
      names = all_dirs.map { |d| File.basename(d) }
    end

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
    infos = fixtures.to_h { |f| [f, fixture_info(File.join(fixtures_root, f))] }
    # 対照の run が期待した skill の file を読んだら、judge が条件の食い違いにする (#731)。その検出のために足す。
    names |= cases.map { |c| c["skill"] } if opts[:skills] == "none"
    # case ごとに置く skill (#737)。source の skill のうち、case の place_skills の名前の skill だけを置く。source に無い
    # 名前があれば、run の前に止める (名前は case の検査で決まった形にしてある)。読み取りの検出 (names) は、置かない skill の
    # 名前も持ったままにする (置いていない skill の file を読みに行った呼び出しも skills_read に残す)。
    source_by_name = all_dirs.to_h { |d| [File.basename(d), d] }
    placed = cases.to_h do |c|
      next [c["id"], []] if opts[:skills] == "none"

      missing = c["place_skills"] - source_by_name.keys
      raise Error, "case #{c['id']}: place_skills not in the source: #{missing.join(', ')}" unless missing.empty?

      [c["id"], c["place_skills"].map { |n| source_by_name.fetch(n) }]
    end
    placed_dirs = placed.values.flatten.uniq.sort_by { |d| File.basename(d) }

    if opts[:dry_run]
      Dir.mktmpdir("skill-behavior-") do |base|
        first = placed.fetch(cases.first["id"])
        proj = prepare_run(base, opts[:tool], File.join(fixtures_root, cases.first["fixture"]), first)
        puts "isolated project (per run): #{proj} (#{first.length} skills, fixture #{cases.first['fixture']})"
        sessions = cases.any? { |c| c["before"] } ? [{ id: "<session>", resume: false }, { id: "<session>", resume: true }] : [nil]
        sessions.each do |s|
          sample = opts[:tool] == "claude-code" ? claude_argv(opts, "<prompt>", s) : codex_argv(opts, proj, s)
          puts "argv#{s ? (s[:resume] ? ' (turn 2)' : ' (turn 1)') : ''}: #{sample.map(&:inspect).join(' ')}#{opts[:tool] == 'codex' ? ' (prompt on stdin)' : ''}"
        end
        if opts[:tool] == "codex"
          puts "codex home: #{opts[:codex_home] ? "#{opts[:codex_home]} (CODEX_HOME for the child)" : 'not set (required for runs)'}"
        end
      end
      puts "cases: #{cases.length} x repeat #{opts[:repeat]}"
      cases.each { |c| puts "  #{c['id']} (#{c['kind']}, fixture #{c['fixture']}): #{c['prompt']}" }
      return 0
    end

    with_turns = cases.any? { |c| c["before"] }

    fix_preflight!(cases, opts[:tool], fixtures_root)
    host_version = preflight!(opts[:tool], codex_env(opts), turns: with_turns)
    raw_dir = "#{opts[:out]}.raw"
    raise Error, "raw log directory is a symlink: #{raw_dir}" if File.symlink?(raw_dir)

    FileUtils.mkdir_p(raw_dir)
    raw_real = File.realpath(raw_dir)
    runs = []
    inits = []
    memory_states = []
    resumed = []
    contexts = []
    cases.each do |c|
      fixture_dir = File.join(fixtures_root, c["fixture"])
      opts[:repeat].times do |n|
        jsonl_path = R.raw_log_path(raw_dir, c["id"], n + 1, "jsonl")
        stderr_path = R.raw_log_path(raw_dir, c["id"], n + 1, "stderr")
        done = nil
        fix = nil
        last = nil
        # run ごとに新しい temp project (前の run の書き込みを次の run に持ち込まない)
        Dir.mktmpdir("skill-behavior-") do |base|
          proj = prepare_run(base, opts[:tool], fixture_dir, placed.fetch(c["id"]))
          info = infos.fetch(c["fixture"])
          done = c["before"] ? run_turns(opts, proj, names, c, info) : Turns.new(turns: [run_turn(opts, proj, names, c["prompt"], info)])
          # 最後の turn の結果 (始めなかったら nil)
          last = done.turns[c["before"] ? c["before"].length : 0]
          # 差分を取った後に、run の後の code を隔離の中で走らせる (書き込みは拒むので、差分は変わらない)。
          fix = FX.run(proj, c["fix_check"]) if c["fix_check"] && last
        end
        done.turns.each_with_index do |r, i|
          # 前の turn の raw log は、番号の付いた別の名前にする。
          jsonl, stderr = r.equal?(last) ? [jsonl_path, stderr_path] : %w[jsonl stderr].map { |x| R.raw_log_path(raw_dir, c["id"], n + 1, "turn#{i + 1}.#{x}") }
          write_no_follow(jsonl, r[:stdout], dir: raw_dir, dir_real: raw_real)
          write_no_follow(stderr, r[:stderr], dir: raw_dir, dir_real: raw_real) unless r[:stderr].to_s.empty?
          inits << r[:init] if r[:init]
          memory_states << r[:memory_states] if r[:memory_states]
        end
        write_no_follow(R.raw_log_path(raw_dir, c["id"], n + 1, "fix-check"), fix.raw, dir: raw_dir, dir_real: raw_real) if fix
        records = done.turns.map { |r| turn_record(r, c) }
        run = { "case" => c["id"], "index" => n + 1 }.merge(last ? records.last : NOT_STARTED_TURN)
        run["before"] = records.first(c["before"].length) if c["before"]
        run["fix_check"] = fix.to_h_for_results if fix
        runs << run
        resumed << done.resumed
        contexts.concat(done.contexts || [])
        puts "#{c['id']} [#{n + 1}/#{opts[:repeat]}]: #{(run['before'] || []).map { |t| "turn 1 #{turn_label(t)}; turn 2 " }.join}" \
             "#{turn_label(run)}#{fix ? " fix=#{fix.label}" : ''}"
        next unless c["before"] && done.left != 0

        puts "warning: session record(s) left in the home: #{done.left.nil? ? 'unknown' : done.left} (#{c['id']} [#{n + 1}/#{opts[:repeat]}])"
      end
    end

    claude = opts[:tool] == "claude-code"
    ids = {
      "source_digest" => placed_dirs.empty? ? "none" : file_digest_of_dirs(placed_dirs),
      "cases_digest" => file_digest([cases_path]),
      "fixture_digests" => fixtures.to_h { |f| [f, tree_digest(File.join(fixtures_root, f))] },
      "runner_version" => runner_version,
      "classifier_version" => K::VERSION,
      "host_version" => claude ? merged(inits.map { |i| i[:version] }) : (host_version.to_s.empty? ? "unknown" : host_version),
      "requested_model" => claude ? (opts[:model] || "default") : R.codex_model(opts),
      "init_model" => claude ? merged(inits.map { |i| i[:model] }) : "unknown",
      "effort" => "default",
      "tool_surface" => if claude
                          { "requested" => CLAUDE_TOOLS, "init" => merged(inits.map { |i| i[:tools].is_a?(Array) ? i[:tools].sort.join(",") : nil }) }
                        else
                          { "sandbox" => CODEX_SANDBOX, "approval_policy" => "never", "disabled_features" => R::CODEX_DISABLE_FEATURES,
                            "sandbox_config" => CODEX_SANDBOX_CONFIG.map { |k, v| "#{k}=#{v}" } }
                        end,
      "permission_mode" => claude ? merged(inits.map { |i| i[:mode] }) : "approval_policy=never",
      "conditions" => CONDITIONS.fetch(opts[:tool]),
      "max_turns" => claude ? opts[:max_turns] : nil,
      "timeout" => opts[:timeout],
      "repeat" => opts[:repeat],
    }
    # 自動の memory を止めたこと (#770。claude-code だけ)。
    ids["auto_memory"] = AutoMemory.record(memory_states) if claude
    # 前の turn のある case (#769) の条件。再開した session が同じか、Codex の実際の設定。
    if with_turns
      ids["resume_session"] = merged(resumed)
      ids["turn_context"] = merged(contexts) unless claude
    end
    # 検査に使った Ruby の版 (検査のある case を含む run だけ)。
    ids["fix_check_ruby"] = RUBY_VERSION if cases.any? { |c| c["fix_check"] }
    results = {
      "schema_version" => RESULTS_SCHEMA_VERSION,
      "tool" => opts[:tool],
      "variant" => opts[:variant],
      "skills" => opts[:skills],
      "ids" => ids,
      "generated_at" => Time.now.utc.iso8601,
      "runs" => runs,
    }
    write_no_follow(opts[:out], JSON.pretty_generate(results) + "\n")
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

  # case の fixture の情報 (#742)。分類器に渡す、fixture の関数と、初期の fixture の Ruby の file の相対 path (名前順)。
  # file は prepare_run が写す前の fixture の dir から読むので、run の途中で増えた file は入らない。
  def self.fixture_info(dir)
    K::Fixture.new(fixture_functions(dir).freeze, fixture_ruby_files(dir).freeze).freeze
  end

  def self.fixture_ruby_files(dir)
    Dir.glob("**/*.rb", File::FNM_DOTMATCH, base: dir).sort.select { |rel| File.file?(File.join(dir, rel)) }
  end

  # skill の dir の並び (名前順) の中身の digest。
  # fixture の関数 (#737): fixture の Ruby の file (*.rb) に top-level で def された名前のうち、Object の method に無い
  # もの。分類器は、inline の Ruby (ruby -e) の receiver の無い呼び出しで、この名前だけを fixture の関数として許す。
  # class や module の中の def は数えない。構文を読めない file があれば、run の前に止める。
  def self.fixture_functions(dir)
    names = fixture_ruby_files(dir).flat_map do |rel|
      tree = Ripper.sexp(File.read(File.join(dir, rel), encoding: "UTF-8"))
      raise Error, "fixture: a Ruby file could not be parsed (#{File.basename(dir)})" if tree.nil?

      tree[1].select { |n| n.is_a?(Array) && n[0] == :def && n[1].is_a?(Array) && n[1][0] == :@ident }.map { |n| n[1][1] }
    end
    names.uniq.sort.reject { |n| Object.method_defined?(n) || Object.private_method_defined?(n) }
  end

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
