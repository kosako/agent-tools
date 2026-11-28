#!/usr/bin/env ruby
# frozen_string_literal: true

# fast-edit-check: PostToolUse (Edit|Write|apply_patch) hook body。編集直後の変更ファイルに
# 高速 check (syntax / lint) を実行し、失敗要約だけを
# hookSpecificOutput.additionalContext でモデルに返す steering hook (#200 §4.4 / #203)。
# 「書いた直後に機械が指摘 → その場で直す」ループの機械判定部分を担う。
#
# 正本: docs/quality-loop-hooks.md。
#
# 強度ラベル (偽らない): steering / fail-open。block しない (permissionDecision を
# 付けない)。hook 内部の想定外はすべて exit 0 で透過する (編集操作を壊さない)。
# 品質の意味判断 (要求一致・最小差分) は production-rail skill の領分のまま。
#
# check コマンドの発見 (自動推測しない・#203 裁定):
# - 宣言の正本は **ユーザー所有の untracked 中央設定** ~/.config/agent-tools/checks.local.json。
#   repo の実 path をキーに edit_checks (pattern + command) を宣言する。
# - repo 内の宣言ファイルは**読まない**: clone した第三者 repo が「編集のたびに実行される
#   任意コマンド」を宣言できてしまうため (宣言の所有をユーザーに固定する)。
# - 設定形式が JSON なのは、standalone 配布 script に psych 3/4 分岐 (yaml_util の領分) を
#   持ち込まないため。
#
# 既定の check (#814): 宣言が無い repo でも、file を実行しない構文チェックだけを走らせる。
# - `.rb` に `ruby --disable=all -c` (hook 自身を動かしている Ruby)、`.sh` に `/bin/sh -n`。command は hook の中で
#   固定し、PATH から新しく実行 file を引かず、repo の中の file や設定を読まない。
# - 対象は、絶対 path で、実 path (link の参照先) が git の repo root の中にある file だけ。
# - その file に一致する有効な宣言の edit_checks があれば、既定は走らせない (宣言が代わる)。
# - 設定の top-level か repo の entry の "default_edit_checks": false で止める。true / false 以外は設定エラーに
#   して、その範囲の既定を止める。
# - repo root は git を起動せず、file の directory の実 path から上へ .git を探して決める (宣言の照合も同じ)。
#
# 設定例 (checks.local.json):
#   {
#     "/Users/<you>/src/some-repo": {
#       "edit_checks": [
#         {"name": "ruby-syntax", "pattern": "\\.rb$", "command": ["ruby", "-c"]}
#       ]
#     }
#   }
#   command には対象ファイルの絶対 path が 1 引数として追記され、cwd = repo root で実行される。
#   edit_checks は「1 ファイル・数百 ms」の高速 check だけを宣言する (PostToolUse は編集の
#   たびに同期で走る)。check ごとに max_footprint_mb / max_seconds を宣言できる。
#
# check の起動 (#467): 同じ dir の personal-safe-run の子として、memory (既定 4096 MiB) と時間 (既定 30 秒) の
# 上限を付けて起動する (safe-run が無い・実行できないなら check は走らせない)。hook 1 回の時間の総予算は 120 秒で、
# 総予算で短くした期限で止まった check は予算切れ (実行できなかったとして要約に出す)。結果は safe-run の report を
# 検証してから分類する。hook が INT / TERM / HUP を受けたら、動いている check を safe-run に止めさせ、何も出さずに
# 終わる。詳細は下の SafeRunCheck と docs の「check の起動」。
#
# payload 互換: Claude Code は tool_input.file_path、Codex は成功した apply_patch の
# tool_input.command を読む。未知の payload / patch は無言 no-op (fail-open)。

require "json"
require "rbconfig"
require "tmpdir"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (stdin・file・git や gh の出力) を UTF-8 として扱う (#432)。
# 既定の external encoding が US-ASCII のままだと、日本語を含む値への正規表現や連結が例外で落ちる。
# scripts/lib/cli.rb (#418) と同じ固定。ENV と ARGV の encoding は変わらない。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module FastEditCheck
  VERSION = "1"

  CONFIG_PATH_ENV = "AGENT_TOOLS_CHECKS_CONFIG"
  DEFAULT_CONFIG = File.join(ENV["HOME"].to_s, ".config", "agent-tools", "checks.local.json")

  # モデルに返す失敗出力の上限 (context を溢れさせない)。
  OUTPUT_CAP = 2000
  # check の時間の上限の既定 (秒) と、hook 1 回の時間の総予算 (秒。Claude Code / Codex の hook の timeout の既定
  # 600 秒より短い)。#467
  DEFAULT_MAX_SECONDS = 30
  BUDGET_SECONDS = 120

  # 既定の check (#814)。file を実行しない構文チェックだけを置く。足す条件は docs/quality-loop-hooks.md の
  # 「既定の check」: command を hook の中で固定できる、file の中身を実行しない、1 file で 1 秒未満、interpreter を
  # PATH と repo から引かない。
  DEFAULT_FLAG_KEY = "default_edit_checks"
  DEFAULT_EDIT_CHECKS = [
    { pattern: /\.rb\z/, check: { "name" => "ruby-syntax (既定)",
                                   "command" => [RbConfig.ruby, "--disable=all", "-c"].freeze }.freeze },
    { pattern: /\.sh\z/, check: { "name" => "sh-syntax (既定)", "command" => ["/bin/sh", "-n"].freeze }.freeze },
  ].freeze

  # ---- safe-run 経由の check の起動 (#467。personal-fast-edit-check と personal-changed-scope-qa に同じ本文で置き、
  # test が一致を確かめる) ------------------------------------------------------------------------------------------
  # check は同じ dir の personal-safe-run の子として起動し、memory (phys_footprint の合計) と時間の上限を付ける
  # (無い・実行できないなら check は走らせない)。結果は safe-run の report を検証してから分類する (exit code は使わ
  # ない。137 は command 自身の SIGKILL と区別できないため)。正本: docs/quality-loop-hooks.md。
  module SafeRunCheck
    SAFE_RUN_NAME = "personal-safe-run"
    DEFAULT_MAX_FOOTPRINT_MB = 4096
    FOOTPRINT_RANGE = (1..1_048_576).freeze
    SECONDS_RANGE = (1..86_400).freeze
    # 保持する出力 (stdout と stderr をまとめたもの) の上限。残りは読み捨てる (check を pipe の詰まりで止めない)。
    OUTPUT_KEEP_BYTES = 64 * 1024
    POLL_SECONDS = 0.05
    # safe-run の終了の後に pipe を読む時間 (EOF を待たない。group を抜けた子が書き込み側を持ち続けても止まらない)。
    DRAIN_SECONDS = 0.5
    # safe-run は max_seconds と後始末 (最悪 約 8 秒) で終わるはずなので、それを過ぎたら止める (TERM → 猶予 → KILL)。
    WRAPPER_GRACE_SECONDS = 20
    WRAPPER_KILL_SECONDS = 10
    REASONS = [nil, "time", "footprint", "monitor", "interrupted"].freeze
    # report の必須 field (null を取りうる reason / command_exit / command_signal も、欠落は不正)。
    REPORT_KEYS = %w[version command_started reason exit_status command_exit command_signal cleanup_complete].freeze
    TRAPPED_SIGNALS = %w[INT TERM HUP].freeze

    # hook 自身が中断された。呼び出し側は後続の check を起動せず、state を書かず、何も出さずに終わる。
    class Interrupted < StandardError; end

    module_function

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # hook の INT / TERM / HUP は flag を立てるだけ。動いている safe-run への TERM の転送と後続の停止は run が行う。
    def install_traps
      @interrupted = false
      TRAPPED_SIGNALS.each { |name| Signal.trap(name) { @interrupted = true } }
    end

    def interrupted?
      @interrupted == true
    end

    def safe_run_path
      File.join(File.dirname(File.realpath(__FILE__)), SAFE_RUN_NAME)
    end

    # check の上限 (max_footprint_mb / max_seconds。無ければ既定) を [MiB, 秒] で返す。safe-run の範囲の整数で
    # なければ (bool・小数・文字列を含む) nil (不正な宣言)。
    def limits(check, default_seconds)
      footprint = check.fetch("max_footprint_mb", DEFAULT_MAX_FOOTPRINT_MB)
      seconds = check.fetch("max_seconds", default_seconds)
      return nil unless footprint.is_a?(Integer) && FOOTPRINT_RANGE.cover?(footprint)
      return nil unless seconds.is_a?(Integer) && SECONDS_RANGE.cover?(seconds)

      [footprint, seconds]
    end

    # command を safe-run の子として起動し、結果を返す: {status: :pass / :failure / :missing, reason:, output:,
    # cleanup_incomplete:}。--max-seconds は min(上限, 総予算の残りの切り捨て) で、総予算で短くした期限の time は
    # 予算切れ (missing) にする。残りが 1 秒未満なら起動しない。hook が中断されたら Interrupted を送出する。
    def run(command, root, footprint, max_seconds, budget_deadline)
      raise Interrupted if interrupted?

      path = safe_run_path
      unless File.file?(path) && File.executable?(path)
        return result(:missing, "safe-run を使えません (#{SAFE_RUN_NAME} が無いか実行できません)", "", nil)
      end

      left = (budget_deadline - now).floor
      return result(:missing, "時間の予算が尽きたので起動しませんでした", "", nil) if left < 1

      seconds = [max_seconds, left].min
      Dir.mktmpdir("personal-hook-check-") do |dir|
        report = File.join(dir, "report.json")
        output, outcome = execute(path, command, root, footprint, seconds, report)
        raise Interrupted if outcome == :interrupted || interrupted?
        if outcome == :overdue
          return result(:missing, "safe-run が期限 (#{seconds + WRAPPER_GRACE_SECONDS} 秒) までに終わりませんでした",
                        output, nil)
        end

        classify(load_report(report), output, footprint, seconds, seconds < max_seconds)
      end
    rescue SystemCallError => e
      result(:missing, "safe-run を起動できません (#{e.class})", "", nil)
    end

    def execute(path, command, root, footprint, seconds, report)
      # 期限は起動の前に決める (起動した後の時計の読みに左右されない)。
      deadline = now + seconds + WRAPPER_GRACE_SECONDS
      reader, writer = IO.pipe
      begin
        pid = Process.spawn([path, path], "--max-footprint-mb", footprint.to_s, "--max-seconds", seconds.to_s,
                            "--report", report, "--", *command, chdir: root, out: writer, err: %i[child out])
      ensure
        writer.close
      end
      collect(pid, reader, deadline)
    ensure
      reader.close unless reader.nil? || reader.closed?
    end

    # safe-run の出力を先頭 OUTPUT_KEEP_BYTES だけ保持して読み、終了を WNOHANG で観測する。終わったら pipe を最大
    # DRAIN_SECONDS だけ読んでから抜ける。safe-run が deadline を過ぎても終わらないか hook が中断されたら、
    # safe-run に TERM を送り (safe-run は check の group を止めてから終わる)、WRAPPER_KILL_SECONDS を過ぎても
    # 終わらなければ KILL する。戻り値は [保持した出力, nil / :overdue / :interrupted]。
    def collect(pid, reader, deadline)
      kept = String.new(encoding: Encoding::BINARY)
      outcome = nil
      term_at = nil
      drain_until = nil
      status = nil
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG) if status.nil?
        if status
          drain_until ||= now + DRAIN_SECONDS
          break if reader.closed? || now >= drain_until
        elsif term_at.nil? && (interrupted? || now >= deadline)
          outcome = interrupted? ? :interrupted : :overdue
          term_at = now
          send_signal(pid, "TERM")
        elsif term_at && now >= term_at + WRAPPER_KILL_SECONDS
          send_signal(pid, "KILL")
          _, status = Process.waitpid2(pid)
        end
        read_some(reader, kept)
      end
      [kept, outcome]
    end

    def read_some(reader, kept)
      if reader.closed?
        sleep POLL_SECONDS
        return
      end
      return unless IO.select([reader], nil, nil, POLL_SECONDS)

      chunk = reader.read_nonblock(65_536, exception: false)
      return if chunk == :wait_readable
      return reader.close if chunk.nil?

      room = OUTPUT_KEEP_BYTES - kept.bytesize
      kept << chunk.byteslice(0, room) if room.positive?
    end

    def send_signal(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    # 検証した report (不正・無いなら nil)。
    def load_report(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      valid_report?(data) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def valid_report?(data)
      return false unless data.is_a?(Hash) && REPORT_KEYS.all? { |key| data.key?(key) } && data["version"] == 1
      return false unless [true, false].include?(data["command_started"]) &&
                          [true, false].include?(data["cleanup_complete"])
      return false unless REASONS.include?(data["reason"]) && data["exit_status"].is_a?(Integer)
      return false unless [data["command_exit"], data["command_signal"]].all? { |v| v.nil? || v.is_a?(Integer) }
      return true unless data["command_started"] && data["reason"].nil?

      # leader が自分で終わったときは、exit code と signal のちょうど一方がある
      data["command_exit"].is_a?(Integer) ^ data["command_signal"].is_a?(Integer)
    end

    # 上から順に排他的に分類する。
    def classify(report, output, footprint, seconds, budget_limited)
      return result(:missing, "safe-run の report が無いか不正です", output, nil) if report.nil?
      return result(:missing, "spawn failed (exit #{report['exit_status']})", output, report) unless report["command_started"]

      case report["reason"]
      when "interrupted" then result(:missing, "safe-run が signal で中断されました", output, report)
      when "time"
        if budget_limited
          result(:missing, "時間の予算が尽きました (総予算の残りの #{seconds} 秒で止めました)", output, report)
        else
          result(:failure, "safe-run が止めました (時間の上限 #{seconds} 秒)", output, report)
        end
      when "footprint" then result(:failure, "safe-run が止めました (memory の上限 #{footprint} MiB)", output, report)
      when "monitor" then result(:failure, "safe-run が止めました (memory を監視できません)", output, report)
      else
        exit_code = report["command_exit"]
        if exit_code.nil?
          result(:failure, "terminated by SIG#{Signal.signame(report['command_signal'])}", output, report)
        elsif exit_code.zero?
          result(:pass, nil, output, report)
        else
          result(:failure, "exit #{exit_code}", output, report)
        end
      end
    end

    def result(status, reason, output, report)
      { status: status, reason: reason, output: output,
        cleanup_incomplete: !report.nil? && report["cleanup_complete"] == false }
    end
  end
  # ---- safe-run 経由の check の起動 (ここまで) ---------------------------------------------------------------------

  module_function

  def config_path
    ENV[CONFIG_PATH_ENV].to_s.empty? ? DEFAULT_CONFIG : ENV[CONFIG_PATH_ENV]
  end

  def valid_update_body?(lines)
    has_lines = false
    lines.each_with_index do |line, i|
      if line == "*** End of File"
        return false unless has_lines && i == lines.length - 1
      elsif line == "@@" || line.start_with?("@@ ")
        return false if i.positive? && !has_lines

        has_lines = false
      else
        return false unless line.empty? || line.match?(/\A[ +\-]/)

        has_lines = true
      end
    end
    has_lines
  end

  # 完全な通常 patch だけを解釈する。patch を実行したり、未知の shell wrapper / remote
  # environment を local cwd と推定したりしない。解釈不能なら全体を skip する。
  def patch_paths(command)
    return [] unless command.is_a?(String) && !command.include?("\0")

    lines = command.strip.lines(chomp: true)
    return [] unless lines.shift == "*** Begin Patch" && lines.pop == "*** End Patch"

    paths = []
    until lines.empty?
      header = lines.shift.match(/\A\*\*\* (Add|Update|Delete) File: (\S.*)\z/)
      return [] unless header

      operation, path = header.captures
      if operation == "Update" && lines.first.to_s.start_with?("*** Move to: ")
        move = lines.shift.match(/\A\*\*\* Move to: (\S.*)\z/)
        return [] unless move

        path = move[1]
      end
      body = []
      body << lines.shift until lines.empty? || lines.first.match?(/\A\*\*\* (?:Add|Update|Delete) File: /)
      valid = case operation
              when "Add" then body.all? { |line| line.start_with?("+") }
              when "Update" then valid_update_body?(body)
              when "Delete" then body.empty?
              end
      return [] unless valid

      paths << path unless operation == "Delete"
    end
    paths
  end

  def edited_files(payload)
    return [] unless payload.is_a?(Hash) && payload["tool_input"].is_a?(Hash)

    if payload["tool_name"] == "apply_patch"
      response = payload["tool_response"]
      cwd = payload["cwd"]
      # Codex 0.153.4 の ApplyPatchToolOutput は exit status を先頭に持つ文字列。
      # PostToolUse という event 名だけで成功したと推定しない。
      return [] unless payload["hook_event_name"] == "PostToolUse" &&
                       response.is_a?(String) && response.start_with?("Exit code: 0\n") &&
                       cwd.is_a?(String) && cwd.start_with?(File::SEPARATOR) && File.directory?(cwd)

      files = patch_paths(payload["tool_input"]["command"]).map { |path| File.absolute_path(path, cwd) }
    else
      files = [payload["tool_input"]["file_path"]]
    end
    files.select { |file| file.is_a?(String) && File.file?(file) }.uniq
  end

  # 設定を読む。無い = 宣言していない (nil。既定の check だけが走る)。壊れている・読めない = 警告文字列を返す
  # (無言で握り潰すとユーザーが設定ミスに気づけない)。在るのに regular file でない (directory、指す先の無い
  # symlink など) と、権限で読めないときも、止める設定を読めないので壊れた設定と同じに扱う (#814)。
  # 「無い」は lstat の ENOENT だけ。親の directory に権限が無いなど、ほかの失敗で無いと決めつけない。
  def load_config
    path = config_path
    begin
      File.lstat(path)
    rescue Errno::ENOENT
      return nil
    end
    return "checks.local.json が regular file ではありません" unless File.file?(path)

    data = JSON.parse(File.read(path))
    return "checks.local.json のトップレベルが object ではありません" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    "checks.local.json を JSON として解釈できません"
  rescue SystemCallError
    "checks.local.json を読めません"
  end

  # repo root を、file の directory の実 path から上へ .git を探して決める (#814)。git を起動しないので、PATH の
  # git も GIT_DIR などの env も判定を変えない。.git は、directory なら中に HEAD があり、regular file なら先頭が
  # "gitdir: " のもの (linked worktree・submodule)。.git の中の file は、git が work tree の外として扱うので対象外。
  def repo_root_for(file)
    dir = File.dirname(file)
    return nil unless File.directory?(dir)

    current = File.realpath(dir)
    return nil if current.split(File::SEPARATOR).include?(".git")

    loop do
      return current if git_marker?(File.join(current, ".git"))

      parent = File.dirname(current)
      return nil if parent == current

      current = parent
    end
  rescue SystemCallError
    nil
  end

  def git_marker?(path)
    if File.directory?(path)
      File.file?(File.join(path, "HEAD"))
    elsif File.file?(path)
      File.open(path, "rb") { |f| f.read(8) } == "gitdir: "
    else
      false
    end
  rescue SystemCallError
    false
  end

  # 宣言 entry を [file に一致する有効 check, 不正 entry の名前] に分類する。
  # 不正 entry (構造不備・壊れた regex) は黙って除外せず設定エラーとして可視化する
  # (「設定済みなのに動かない」を診断可能にする)。
  def checks_for(entry, file)
    checks = entry.is_a?(Hash) ? entry["edit_checks"] : nil
    # edit_checks が在るのに配列でない宣言も、黙って無視せず不正な宣言として知らせる (#814 review)
    return [[], ["edit_checks"]] if entry.is_a?(Hash) && entry.key?("edit_checks") && !checks.is_a?(Array)
    return [[], []] unless checks.is_a?(Array)

    matched = []
    invalid = []
    checks.each_with_index do |c, i|
      # 要素に NUL を含む command は起動 (Process.spawn) が ArgumentError にして包括 rescue に落ちる (無言の exit 0)
      # ので、設定の検証で不正な entry として除外する (#462 review)。上限 (max_footprint_mb / max_seconds) は
      # safe-run の範囲の整数だけを受け付ける (#467)
      unless c.is_a?(Hash) && c["pattern"].is_a?(String) && c["command"].is_a?(Array) &&
             !c["command"].empty? && c["command"].all? { |a| a.is_a?(String) && !a.include?("\0") } &&
             !SafeRunCheck.limits(c, DEFAULT_MAX_SECONDS).nil?
        invalid << "edit_checks[#{i}]"
        next
      end
      begin
        matched << c if Regexp.new(c["pattern"]).match?(file)
      rescue RegexpError
        invalid << check_name(c, i) + " (壊れた regex)"
      end
    end
    [matched, invalid]
  end

  # 表示用の名前。name が文字列でない entry (数値など) でも連結で落ちないよう、文字列に限って使う (#430 の 4)。
  def check_name(check, index)
    name = check["name"]
    name.is_a?(String) && !name.empty? ? name : "edit_checks[#{index}]"
  end

  # check を safe-run の子として、memory と時間の上限を付けて起動する (#467)。失敗 (exit N・signal・safe-run が
  # 上限で止めた) と実行できなかった check (safe-run を使えない・check を起動できない (不在・権限・不正形式・ENOTDIR
  # など。#430 の 4)・report が不正・予算切れ・safe-run が期限までに終わらない) は、どちらも理由を付けて要約に出す。
  # hook が中断されたら SafeRunCheck::Interrupted が上がる。
  def run_check(check, file, repo_root, budget_deadline)
    footprint, seconds = SafeRunCheck.limits(check, DEFAULT_MAX_SECONDS)
    result = SafeRunCheck.run(check["command"] + [file], repo_root, footprint, seconds, budget_deadline)
    reason = result[:status] == :missing ? "check を実行できません (#{result[:reason]})" : result[:reason]
    { name: display_name(check), ok: result[:status] == :pass, output: result[:output], reason: reason,
      cleanup_incomplete: result[:cleanup_incomplete] }
  end

  def display_name(check)
    name = check["name"]
    name.is_a?(String) && !name.empty? ? name : check["command"].first
  end

  # file に当たる既定の check (#814)。拡張子は payload の path で見る。相対 path には当てない (先頭が "-" の名前を
  # interpreter が option として読まないように)。
  def default_candidates(file)
    return [] unless file.start_with?(File::SEPARATOR)

    DEFAULT_EDIT_CHECKS.select { |d| d[:pattern].match?(file) }.map { |d| d[:check] }
  end

  # default_edit_checks の値を [既定を走らせるか, 値が不正か] で返す。key が無ければ走らせる。true / false 以外は
  # 不正で、止めたかった可能性があるので走らせない。
  def default_flag(container)
    return [true, false] unless container.is_a?(Hash) && container.key?(DEFAULT_FLAG_KEY)

    case container[DEFAULT_FLAG_KEY]
    when true then [true, false]
    when false then [false, false]
    else [false, true]
    end
  end

  # file の実 path (link の参照先) が repo root の中にあるか。repo の外を指す link には既定を走らせない。
  def inside_root?(file, repo_root)
    File.realpath(file).start_with?(root_prefix(repo_root))
  rescue SystemCallError
    false
  end

  # repo root の下の path の接頭辞。root が "/" のときに "//" にしない (#814 review)。
  def root_prefix(repo_root)
    repo_root.end_with?(File::SEPARATOR) ? repo_root : repo_root + File::SEPARATOR
  end

  # 失敗要約の label は常に repo 相対 path にする (#431 の 4): OpenCode plugin は file ごとに本 script を呼んで
  # 同文の要約を除くので、basename だと同名 file (a/index.rb と b/index.rb) の失敗が 1 件に潰れる。
  # payload の path は symlink 越し (macOS の /var → /private/var など) があり得るので、directory を realpath に
  # して git が realpath で返す repo root と揃えてから prefix を削る。file 自体の symlink は辿らない (repo の外を
  # 指す link でも label は repo の中の path)。check に渡す path は payload のまま。
  def relative_label(file, repo_root)
    real = File.join(File.realpath(File.dirname(file)), File.basename(file))
    real.delete_prefix(root_prefix(repo_root))
  end

  def truncate(text)
    text = text.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?
    text.length > OUTPUT_CAP ? text[0, OUTPUT_CAP] + "\n…(truncated)" : text
  end

  def emit(message)
    puts JSON.generate(
      "hookSpecificOutput" => {
        "hookEventName" => "PostToolUse",
        "additionalContext" => message,
      }
    )
  end

  def run
    SafeRunCheck.install_traps
    budget_deadline = SafeRunCheck.now + BUDGET_SECONDS
    payload = JSON.parse($stdin.read)
    files = edited_files(payload)
    return 0 if files.empty?

    config = load_config
    if config.is_a?(String)
      emit("fast-edit-check: 設定エラー: #{config} (#{config_path})")
      return 0
    end

    config ||= {}
    global_on, global_invalid = default_flag(config)
    parts = []
    reported_config_errors = {}
    reported_flag_errors = {}
    files.each do |file|
      defaults = default_candidates(file)
      # 宣言が無く、既定にも当たらない file では、repo root を探さずに終わる (#814 の P5)
      next if config.empty? && defaults.empty?

      repo_root = repo_root_for(file)
      next if repo_root.nil?

      entry = config[repo_root]
      checks, invalid = entry ? checks_for(entry, file) : [[], []]
      unless invalid.empty? || reported_config_errors[repo_root]
        parts << "fast-edit-check: 設定エラー: 不正な check 宣言を無視しました: " \
                 "#{invalid.join(', ')} (#{config_path})"
        reported_config_errors[repo_root] = true
      end

      # default_edit_checks の型は、宣言が一致するかに関わらず検査して知らせる (#814 review)
      entry_on, entry_invalid = default_flag(entry)
      if global_invalid && !reported_flag_errors[:global]
        parts << "fast-edit-check: 設定エラー: top-level の #{DEFAULT_FLAG_KEY} は true か false にしてください。" \
                 "既定の check を止めました (#{config_path})"
        reported_flag_errors[:global] = true
      end
      if entry_invalid && !reported_flag_errors[repo_root]
        parts << "fast-edit-check: 設定エラー: #{repo_root} の #{DEFAULT_FLAG_KEY} は true か false にしてください。" \
                 "この repo の既定の check を止めました (#{config_path})"
        reported_flag_errors[repo_root] = true
      end
      # 有効な宣言が file に一致すれば、宣言が既定に代わる。一致しなければ既定を走らせる (止める設定が無ければ)
      if checks.empty? && !defaults.empty? && global_on && entry_on && inside_root?(file, repo_root)
        checks = defaults
      end

      results = checks.map { |c| run_check(c, file, repo_root, budget_deadline) }
      failures = results.reject { |r| r[:ok] }
      label = relative_label(file, repo_root)
      unless failures.empty?
        body = failures.map { |r| "[#{r[:name]}] #{r[:reason]}\n#{truncate(r[:output])}" }.join("\n")
        parts << "fast-edit-check: #{label} への編集が check に失敗しました。" \
                 "いま直してください (自動修正はしません):\n#{body}"
      end
      incomplete = results.select { |r| r[:cleanup_incomplete] }.map { |r| r[:name] }
      unless incomplete.empty?
        parts << "fast-edit-check: #{label} の check (#{incomplete.join(', ')}): " \
                 "safe-run が check の process group を止め切れませんでした"
      end
    end
    return 0 if parts.empty?

    # 中断された hook は何も出さない (後続の check は起動していない)
    raise SafeRunCheck::Interrupted if SafeRunCheck.interrupted?

    # 上限は check 単位だけでなく合計にも適用する (複数失敗で context を溢れさせない)
    emit(truncate(parts.join("\n")))
    0
  rescue SafeRunCheck::Interrupted
    0 # hook が中断された: 動いていた check は safe-run が止めた。何も出さない
  rescue StandardError
    0 # fail-open: hook 内部の想定外で編集操作を壊さない
  end
end

exit FastEditCheck.run if $PROGRAM_NAME == __FILE__
