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
#   - skill の無い条件は、両方の target で、運用 instruction と user の skill の両方が無い条件 (#731)。claude-code は
#     --setting-sources project で user の instruction と skill を読まない。codex は global の AGENTS.md を止める設定が
#     無いので、人がログインした評価用の home (--codex-home) で起動し、子 process にだけ CODEX_HOME を渡す。
#   - 呼び出しの要求 (calls) と、その結果 (outcome) と、state の変化 (changed) を別の欄に残す。要求があっても、
#     外へ書けたことの証拠にはしない。
#   - command の本文と prompt は results.json に入れず、raw log (<out>.raw/) にだけ置く。raw log は model が読んだ
#     file の中身を含みうるので、公開しない。
#   - 区分は分類器 (skill_behavior_classifier.rb) が決める。
#   - routing probe (probe_skill_routing.rb) の codex の起動の境界・preflight・model の選び方・子 process の期限は
#     共有する。user の skill の無効化 (skills.config) は使わない (評価用の home に user の skill が無いため)。
#     終わり方 (completion) と観測は共有しない (routing の max-turns や
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
require_relative "skill_behavior_classifier"

# C locale でも、読む text (file・command の出力) を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ProbeSkillBehavior
  class Error < StandardError; end

  R = ProbeSkillRouting
  C = SkillBehaviorCases
  K = SkillBehaviorClassifier
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
  CODEX_SANDBOX = "workspace-write"
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
      --source    置く skill の dir の親 (既定: generated/<tool>/skills。build 済みであること)
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
      { id: c[:id], tool: c[:tool], class: K.classify_claude(c[:tool], c[:input]), outcome: outcome,
        strings: strings_in(c[:input]) }
    end
    { calls: out, skills_read: skills.uniq, skills_unresolved: unresolved, init: init, result_seen: result_seen,
      subtype: subtype }
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
      { id: id, tool: item["type"], class: codex_class(item), outcome: codex_outcome(item), strings: strings }
    end
    { calls: calls, skills_read: skills.uniq, skills_unresolved: unresolved, turn_completed: turn_completed }
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
    when "command_execution" then K.classify_shell(item["command"])
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

  # skill の file の読み取りの検出 (#731。review の round 1〜4)。決まり: 名前を決められない読み取りは、呼び出しの区分とは
  # 分けて、run の印 (skills_unresolved) で judge に渡す。区分は分類器のまま変えない (書き込みと同居しても印は消えない)。
  # shell は静的に解釈しきれないので、名前に結び付ける形を 1 つに絞る (#717 と同じ考え方)。文字列の中の `skill.md` の字
  # (大文字小文字を区別しない。部分の一致) の出てくる所ごとに見て、次の形だけを、その名前の dir の SKILL.md の読み取りに
  # する。`/./` は `/` にしてから見る。
  #   - `<要素>/SKILL.md`: 直前が `/` で、その前の要素が具体的な名前 (英数字と `._-`。`.` と `..` を除く)、直後が末尾か
  #     区切りの字 (空白・引用・`;&|()<>`)。要素の直前は `/`・先頭・空白・`=`・`;&|()<>` のどれか (引用や backtick の
  #     直後の要素は、shell が前の部分とつないで名前の途中になりうるので受けない)。要素より前の部分に変数や glob が
  #     あってもよい (読む file の名前は変わらない)。
  # この形でない所 (単独の `SKILL.md`、`cd` してからの読み取り、`*/SKILL.md`・`SKILL.md*`・`*SKILL.md` の glob、変数、
  # `..`、引用でつないだ名前、`foo-SKILL.md`・`SKILL.md.bak`) が 1 つでもあれば、印を立てる (同じ文字列にほかの名前が
  # 見つかっても消さない)。名前が names にあれば skills_read に足す。
  SKILL_MD_AFTER = /\A(?:\z|[\s"'`;&|()<>])/.freeze
  SEGMENT_BEFORE_SLASH = %r{(?:\A|[/\s=;&|()<>])([^/\s"'`;&|()<>=]*)/\z}.freeze
  CONCRETE_SEGMENT = /\A[A-Za-z0-9._-]+\z/.freeze

  def self.skill_reads(strings, names)
    by_name = names.to_h { |n| [n.downcase, n] }
    found = []
    unresolved = false
    strings.each do |s|
      next unless s.match?(/skill\.md/i)

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

  def self.claude_argv(opts, prompt)
    # --tools は値を複数とる option なので、後ろに値を 1 つとる option を置いて、prompt を取り込ませない。
    argv = ["claude", "-p", "--setting-sources", "project", "--strict-mcp-config",
            "--tools", CLAUDE_TOOLS.join(","), "--permission-mode", CLAUDE_PERMISSION_MODE,
            "--output-format", "stream-json", "--verbose",
            "--max-turns", opts[:max_turns].to_s, "--no-session-persistence"]
    argv += ["--model", opts[:model]] if opts[:model]
    argv + [prompt]
  end

  # 評価用の home には user の skill が無いので、user の skill を外す skills.config は渡さない (#731)。
  def self.codex_argv(opts, proj)
    argv = ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules", "-s", CODEX_SANDBOX, "-c", 'approval_policy="never"']
    R::CODEX_DISABLE_FEATURES.each { |f| argv.push("--disable", f) }
    argv.push("-C", proj, "-m", R.codex_model(opts))
    argv + ["-"]
  end

  def self.claude_preflight!
    help = R.capture_ok(%w[claude --help])
    raise Error, "claude-code: `claude --help` failed" unless help

    missing = CLAUDE_HELP_MARKERS.reject { |m| help.include?(m) }
    raise Error, "claude-code: lacks flag(s): #{missing.join(', ')}" unless missing.empty?
  end

  # 戻り値は host の版 (codex --version の 1 行目)。
  def self.preflight!(tool, env)
    if tool == "claude-code"
      claude_preflight!
      nil
    else
      R.codex_preflight!(env: env)
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

  def self.run_one(opts, proj, names, prompt)
    if opts[:tool] == "claude-code"
      argv = claude_argv(opts, prompt)
      r = R.run_command(argv, chdir: proj, stdin: nil, timeout: opts[:timeout])
      parsed = parse_claude(r.out, names)
    else
      argv = codex_argv(opts, proj)
      r = R.run_command(argv, chdir: proj, stdin: prompt, timeout: opts[:timeout], env: codex_env(opts))
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
    files = %w[probe_skill_behavior.rb skill_behavior_cases.rb skill_behavior_classifier.rb probe_skill_routing.rb
               probe_child.rb]
    file_digest(files.map { |f| File.join(__dir__, f) })
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
    # 対照の run が期待した skill の file を読んだら、judge が条件の食い違いにする (#731)。その検出のために足す。
    names |= cases.map { |c| c["skill"] } if opts[:skills] == "none"

    if opts[:dry_run]
      Dir.mktmpdir("skill-behavior-") do |base|
        proj = prepare_run(base, opts[:tool], File.join(fixtures_root, cases.first["fixture"]), placed)
        puts "isolated project (per run): #{proj} (#{placed.length} skills, fixture #{cases.first['fixture']})"
        sample = opts[:tool] == "claude-code" ? claude_argv(opts, "<prompt>") : codex_argv(opts, proj)
        puts "argv: #{sample.map(&:inspect).join(' ')}#{opts[:tool] == 'codex' ? ' (prompt on stdin)' : ''}"
        if opts[:tool] == "codex"
          puts "codex home: #{opts[:codex_home] ? "#{opts[:codex_home]} (CODEX_HOME for the child)" : 'not set (required for runs)'}"
        end
      end
      puts "cases: #{cases.length} x repeat #{opts[:repeat]}"
      cases.each { |c| puts "  #{c['id']} (#{c['kind']}, fixture #{c['fixture']}): #{c['prompt']}" }
      return 0
    end

    host_version = preflight!(opts[:tool], codex_env(opts))
    raw_dir = "#{opts[:out]}.raw"
    raise Error, "raw log directory is a symlink: #{raw_dir}" if File.symlink?(raw_dir)

    FileUtils.mkdir_p(raw_dir)
    raw_real = File.realpath(raw_dir)
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
          recheck_codex_home!(opts) if opts[:tool] == "codex"
          r = run_one(opts, proj, names, c["prompt"])
          changed = changed_paths(before, snapshot(proj))
        end
        write_no_follow(jsonl_path, r[:stdout], dir: raw_dir, dir_real: raw_real)
        write_no_follow(stderr_path, r[:stderr], dir: raw_dir, dir_real: raw_real) unless r[:stderr].to_s.empty?
        inits << r[:init] if r[:init]
        reached = r[:calls].any? { |call| call[:strings].any? { |s| c["reach"].any? { |p| s.include?(p) } } }
        runs << {
          "case" => c["id"], "index" => n + 1, "completion" => r[:completion],
          "calls" => r[:calls].map { |call| { "id" => call[:id], "tool" => call[:tool], "class" => call[:class],
                                              "outcome" => call[:outcome] } },
          "reached" => reached, "changed" => changed, "skills_read" => r[:skills_read],
          "skills_unresolved" => r[:skills_unresolved],
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
      "classifier_version" => K::VERSION,
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
      "conditions" => CONDITIONS.fetch(opts[:tool]),
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
