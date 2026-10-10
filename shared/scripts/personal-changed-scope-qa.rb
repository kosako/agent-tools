#!/usr/bin/env ruby
# frozen_string_literal: true

# changed-scope-qa: Stop hook body。turn の終わりに「tracked な変更があるのに repo 宣言の
# QA check (lint / typecheck / 対象テスト) が未実行 or stale」なら、一度だけ block して
# 続行させる品質 gate (#200 §4.5 / #203)。「check を忘れたまま終了」を防ぐ。
#
# 正本: docs/quality-loop-hooks.md。
#
# 強度ラベル (偽らない): 通常経路に対する best-effort gate。hook 無効化・別経路で迂回
# できる。品質の意味判断 (何が十分な検証か) は production-rail / モデルの領分のまま。
#
# check の発見は fast-edit-check と同じ中央 local 設定 (checks.local.json) の qa_checks。
# 宣言が無い repo・repo 外・変更なしでは無言 no-op (opt-in 設計)。qa_checks は
# 「repo 全体で数秒・決定的」な suite だけを宣言する (Stop のたびに走りうる)。
#
# 設定例 (checks.local.json):
#   {
#     "/Users/<you>/src/some-repo": {
#       "qa_checks": [
#         {"name": "manifests", "command": ["scripts/check-manifests.sh", "--quiet"]}
#       ]
#     }
#   }
#   command は cwd = repo root で実行される。check ごとに max_footprint_mb / max_seconds を宣言できる。
#
# check の起動 (#467): 同じ dir の personal-safe-run の子として、memory (既定 4096 MiB) と時間 (既定 300 秒) の
# 上限を付けて起動する (safe-run が無い・実行できないなら check は走らせない)。hook 1 回の時間の総予算は 540 秒で、
# 総予算で短くした期限で止まった check は予算切れ (missing)。結果は safe-run の report を検証してから分類する。
# hook が INT / TERM / HUP を受けたら、動いている check を safe-run に止めさせ、state も出力も残さずに終わる。
# 詳細は下の SafeRunCheck と docs の「check の起動」。
#
# 無限ループ対策 (仕様・#200 §4.5):
# - `stop_hook_active` が true (この turn で既に継続済み) のときは **block しない**。
# - scope 指紋 + 結果を state file に cache し、**同一 scope への block は 1 回だけ**。
#   pass 済み scope は無言 pass / fail 済み scope は非ブロッキング警告のみ。
# - 実行できなかった check (missing: 不在 ENOENT・権限 EACCES・不正形式 ENOEXEC などの起動の失敗、safe-run を
#   使えない・report が不正・予算切れ・safe-run が期限までに終わらない) は「警告に降格」して block しない。
#   起動した check が signal で終わったのは起動の失敗ではなく実 failure (#373)。missing の check は cache で
#   確定させず、state に missing として分離保持して cache-hit 時にもそれだけ再試行する
#   (環境が直れば拾われる。実 failure の再 block はしない)。
#
# scope 指紋 (false pass を防ぐため QA の実入力を全部含める):
#   HEAD sha + `git status --porcelain -z -uall` + `git diff HEAD` + untracked file の
#   内容 digest + 宣言 check 定義の JSON。untracked の内容変更・dirty を保った branch
#   切替・check 定義の変更のどれでも指紋が変わり、再検査される。初回 commit 前 (HEAD が無い)
#   は `git diff HEAD` の代わりに stage 済み (`--cached`) と未 stage の diff を使う。材料の git が
#   失敗したら判定不能として gate しない (#373)。
#
# 検査対象の帰属 (#203 裁定): agent の変更とユーザーの手元変更を区別せず、**working tree の
# dirty scope 全体** (tracked の変更 + untracked) を対象にする。単純さを優先し、ユーザー
# 自身の書きかけ変更も検査対象になることを明記する。
#
# state: ~/.cache/agent-tools/changed-scope-qa/<repo path の sha256>.json
# (AGENT_TOOLS_QA_STATE_DIR で override 可・test 用)。check は決定的である前提
# (同一 scope の再実行を cache が省くため)。

require "json"
require "digest"
require "tmpdir"

module ChangedScopeQa
  VERSION = "1"

  CONFIG_PATH_ENV = "AGENT_TOOLS_CHECKS_CONFIG"
  DEFAULT_CONFIG = File.join(ENV["HOME"].to_s, ".config", "agent-tools", "checks.local.json")
  STATE_DIR_ENV = "AGENT_TOOLS_QA_STATE_DIR"
  DEFAULT_STATE_DIR = File.join(ENV["HOME"].to_s, ".cache", "agent-tools", "changed-scope-qa")

  OUTPUT_CAP = 2000
  # check の時間の上限の既定 (秒) と、hook 1 回の時間の総予算 (秒。Claude Code / Codex の hook の timeout の既定
  # 600 秒より短い)。#467
  DEFAULT_MAX_SECONDS = 300
  BUDGET_SECONDS = 540
  CLEANUP_INCOMPLETE = "safe-run が check の process group を止め切れませんでした"

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
      return false unless data.is_a?(Hash) && data["version"] == 1
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

  def state_dir
    ENV[STATE_DIR_ENV].to_s.empty? ? DEFAULT_STATE_DIR : ENV[STATE_DIR_ENV]
  end

  def load_config
    return nil unless File.file?(config_path)

    data = JSON.parse(File.read(config_path))
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil # 設定エラーの steer は fast-edit-check 側が担う (二重に騒がない)
  end

  def repo_root
    out = IO.popen(%w[git rev-parse --show-toplevel], err: File::NULL, &:read)
    return nil unless $?.success?

    File.realpath(out.chomp)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def check_name(check)
    check["name"] || check["command"].first
  end

  # [有効 check, 不正 entry の名前]。不正 entry は黙って除外せず警告で可視化する。
  def qa_checks(entry)
    checks = entry.is_a?(Hash) ? entry["qa_checks"] : nil
    return [[], []] unless checks.is_a?(Array)

    valid = []
    invalid = []
    checks.each_with_index do |c, i|
      # 要素に NUL を含む command は起動 (Process.spawn) が ArgumentError にして包括 rescue に落ちる (無言の exit 0)
      # ので、設定の検証で不正な entry として除外する (#462 review)。上限 (max_footprint_mb / max_seconds) は
      # safe-run の範囲の整数だけを受け付ける (#467)
      if c.is_a?(Hash) && c["command"].is_a?(Array) && !c["command"].empty? &&
         c["command"].all? { |a| a.is_a?(String) && !a.include?("\0") } &&
         !SafeRunCheck.limits(c, DEFAULT_MAX_SECONDS).nil?
        valid << c
      else
        invalid << "qa_checks[#{i}]"
      end
    end
    [valid, invalid]
  end

  # status --porcelain -z -uall の untracked ("?? ") entry の内容 digest。
  # rename / copy entry は path が 2 要素 (新\0旧) なので旧側を読み飛ばす。
  def untracked_digest(status_z, root)
    tokens = status_z.split("\0")
    parts = []
    i = 0
    while i < tokens.length
      token = tokens[i]
      i += 1
      next if token.nil? || token.length < 4

      xy = token[0, 2]
      path = token[3..-1]
      i += 1 if xy.start_with?("R", "C") # 旧 path token を消費
      next unless xy == "??"

      full = File.join(root, path)
      digest =
        begin
          if File.symlink?(full)
            # File.file? / SHA256.file はリンク先を評価する (dangling だと常に non-file)。
            # リンクの向き先そのものを指紋に含め、種別も区別する (R2 指摘)。
            "symlink:" + Digest::SHA256.hexdigest(File.readlink(full))
          elsif File.file?(full)
            Digest::SHA256.file(full).hexdigest
          else
            "non-file"
          end
        rescue StandardError
          "unreadable"
        end
      parts << "#{path}=#{digest}"
    end
    parts.join("\n")
  end

  # dirty scope の指紋。nil = 判定不能 / 空 = clean。材料の git のどれかが失敗したら判定不能にする
  # (空の diff として指紋を作ると、変わった内容を同じ scope とみなして cache に当たる。#373)。
  def scope_fingerprint(root, checks)
    status = git_output(root, "status", "--porcelain", "-z", "-uall")
    return nil if status.nil?
    return "" if status.empty?

    head, head_status = git_run(root, "rev-parse", "--verify", "-q", "HEAD")
    # `--verify -q` は HEAD が無い (初回 commit 前) ときだけ exit 1 になる。それ以外の失敗 (128 や signal) は
    # unborn と区別して判定不能にする。
    unborn = head_status.exitstatus == 1
    return nil unless head_status.success? || unborn

    # --no-ext-diff: 外部 diff の出力を指紋に使うと、内容が変わっても指紋が同じになり cache で false pass になる
    # (test で固定。#430 の 5)。--no-color: 色の設定を変えても指紋が変わらないようにする (false pass の防止では
    # ないので、test では固定していない)。
    diff = unborn ? unborn_diff(root) : git_output(root, "diff", "HEAD", "--no-color", "--no-ext-diff")
    return nil if diff.nil?

    Digest::SHA256.hexdigest(
      [unborn ? "unborn" : head.chomp, status, diff, untracked_digest(status, root),
       JSON.generate(checks)].join("\0")
    )
  end

  # 初回 commit 前 (HEAD が無い) は `git diff HEAD` が使えない。stage 済み (index と空の tree の差) と
  # 未 stage (作業ツリーと index の差) を合わせて読む (#373)。どちらかが失敗したら nil。
  def unborn_diff(root)
    staged = git_output(root, "diff", "--cached", "--no-color", "--no-ext-diff")
    unstaged = git_output(root, "diff", "--no-color", "--no-ext-diff")
    staged && unstaged && "#{staged}\0#{unstaged}"
  end

  # git の出力と終了状態。
  def git_run(root, *args)
    out = IO.popen(["git", "-C", root, *args], err: File::NULL, &:read)
    [out, $?]
  end

  # git の出力 (exit 0 のときだけ)。失敗は nil。
  def git_output(root, *args)
    out, status = git_run(root, *args)
    status.success? ? out : nil
  end

  def state_path(root)
    File.join(state_dir, Digest::SHA256.hexdigest(root) + ".json")
  end

  def read_state(root)
    path = state_path(root)
    return nil unless File.file?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  def write_state(root, fingerprint, outcome, missing)
    # hook が中断されたら state を書かない (次の Stop で同じ scope を検査し直す)
    raise SafeRunCheck::Interrupted if SafeRunCheck.interrupted?

    require "fileutils"
    FileUtils.mkdir_p(state_dir)
    File.write(state_path(root),
               JSON.generate("fingerprint" => fingerprint, "outcome" => outcome,
                             "missing" => missing))
  end

  # check を safe-run の子として、memory と時間の上限を付けて起動する (#467)。結果は safe-run の report で分類する:
  # pass / failure (exit N・signal・safe-run が上限で止めた) / missing (safe-run を使えない・check を起動できない
  # (不在・権限・不正形式・ENOTDIR など。#430 の 4)・report が不正・予算切れ・safe-run が期限までに終わらない)。
  # missing は cache で確定させず、次の Stop で再試行する。check が signal で終わったのは実 failure (#373)。
  # cleanup が終わり切らなかった pass は missing として再実行し (警告が cache-hit で消えないように)、failure には
  # 理由に添える。hook が中断されたら SafeRunCheck::Interrupted が上がる。
  def run_check(check, root, budget_deadline)
    footprint, seconds = SafeRunCheck.limits(check, DEFAULT_MAX_SECONDS)
    result = SafeRunCheck.run(check["command"], root, footprint, seconds, budget_deadline)
    passed = result[:status] == :pass
    reason = result[:reason]
    reason = passed ? CLEANUP_INCOMPLETE : "#{reason} (#{CLEANUP_INCOMPLETE})" if result[:cleanup_incomplete]
    { name: check_name(check), ok: passed, output: result[:output], reason: reason,
      missing: result[:status] == :missing || (passed && result[:cleanup_incomplete]) }
  end

  # 未実行の check の一覧 (名前と理由)。
  def missing_list(results)
    results.map { |r| "#{r[:name]} (#{r[:reason]})" }.join(", ")
  end

  def truncate(text)
    text = text.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?
    text.length > OUTPUT_CAP ? text[0, OUTPUT_CAP] + "\n…(truncated)" : text
  end

  # Stop の additionalContext は Claude を再継続させる。警告はユーザーにだけ届ける。
  def emit_warning(message)
    puts JSON.generate("systemMessage" => truncate(message))
  end

  # 失敗した check の名前と終了の理由を先にまとめ、ログはその後ろに置く。呼び出し側は要約全体を先頭から
  # 打ち切るので、長いログの後ろにある check の理由が消えないようにする (#381 review CSQA-02)。
  def failure_summary(failures)
    reasons = failures.map { |r| "- #{r[:name]}: #{r[:reason]}" }
    logs = failures.map { |r| "[#{r[:name]}]\n#{truncate(r[:output])}" }
    (reasons + logs).join("\n")
  end

  # 同一 scope の cache hit。block は消費済みなので二度と block しない。
  # missing として保持した check だけ再試行し (環境が直れば拾う)、state を更新して
  # [exit code, ユーザー向け警告 (nil 可)] を返す。
  def handle_cached(root, fingerprint, state, checks, budget_deadline)
    missing_names = state["missing"].is_a?(Array) ? state["missing"] : []
    return [0, nil] if state["outcome"] == "pass" && missing_names.empty?

    retried = checks.select { |c| missing_names.include?(check_name(c)) }
                    .map { |c| run_check(c, root, budget_deadline) }
    still = retried.select { |r| r[:missing] }
    still_missing = still.map { |r| r[:name] }
    new_failures = retried.reject { |r| r[:ok] || r[:missing] }

    if state["outcome"] == "fail" || !new_failures.empty?
      write_state(root, fingerprint, "fail", still_missing)
      [0, "changed-scope-qa: 前回と同一の変更 scope で未解消の check 失敗があります " \
          "(再 block はしません。人間の判断に委ねます)。" +
          (new_failures.empty? ? "" : "\n#{failure_summary(new_failures)}")]
    elsif still_missing.empty?
      write_state(root, fingerprint, "pass", [])
      [0, nil]
    else
      write_state(root, fingerprint, "pass", still_missing)
      [0, "changed-scope-qa: check を実行できませんでした: " \
          "#{missing_list(still)} — block はしません。"]
    end
  end

  # stdout の JSON emission は 1 回だけに保つ (複数 JSON 行は runner の parse を壊しうる)。
  # notes に非ブロッキングの伝達事項を集め、最後にまとめて 1 回 emit する。
  def run
    SafeRunCheck.install_traps
    budget_deadline = SafeRunCheck.now + BUDGET_SECONDS
    payload = JSON.parse($stdin.read) rescue {}
    already_continued = payload["stop_hook_active"] == true
    notes = []

    config = load_config
    return 0 if config.nil?

    root = repo_root
    return 0 if root.nil?

    checks, invalid = qa_checks(config[root])
    return 0 if checks.empty? && invalid.empty?

    unless invalid.empty?
      notes << "changed-scope-qa: 設定エラー: 不正な check 宣言を無視しました: " \
               "#{invalid.join(', ')} (#{config_path})"
    end

    code = gate(root, checks, already_continued, notes, budget_deadline) unless checks.empty?
    code ||= 0
    emit_warning(notes.join("\n")) unless notes.empty? || code != 0
    code
  rescue SafeRunCheck::Interrupted
    0 # hook が中断された: 動いていた check は safe-run が止めた。state も出力も残さない (次の Stop で再検査)
  rescue StandardError
    0 # fail-open: hook 内部の想定外でセッションを塞がない
  end

  # gate 本体。非ブロッキングの伝達事項は notes に追記し、block するときだけ
  # stderr + exit 2 を使う (block 時は stdout JSON が無視されるため notes は出さない)。
  def gate(root, checks, already_continued, notes, budget_deadline)
    fingerprint = scope_fingerprint(root, checks)
    return 0 if fingerprint.nil? || fingerprint.empty? # clean or 判定不能 → gate しない

    state = read_state(root)
    if state && state["fingerprint"] == fingerprint
      code, message = handle_cached(root, fingerprint, state, checks, budget_deadline)
      notes << message if message
      return code
    end

    results = checks.map { |c| run_check(c, root, budget_deadline) }
    missing = results.select { |r| r[:missing] }
    failures = results.reject { |r| r[:ok] || r[:missing] }
    missing_names = missing.map { |r| r[:name] }

    if failures.empty?
      if missing.empty?
        write_state(root, fingerprint, "pass", [])
      else
        # 実行できた check は全 pass だが未実行が残る: pass + missing で保持し、
        # cache-hit 時に missing だけ再試行される (block はしない)
        notes << "changed-scope-qa: check を実行できませんでした: " \
                 "#{missing_list(missing)} — block はしません。"
        write_state(root, fingerprint, "pass", missing_names)
      end
      return 0
    end

    # 実 failure あり: この scope への block を 1 回だけ消費する (missing は分離保持)
    write_state(root, fingerprint, "fail", missing_names)
    summary = failure_summary(failures)
    summary += "\n(未実行の check: #{missing_list(missing)})" unless missing.empty?
    if already_continued
      notes << "changed-scope-qa: check がまだ失敗しています (この turn では再 block " \
               "しません):\n#{summary}"
      return 0
    end

    warn truncate("changed-scope-qa: 変更 scope に対する repo 宣言の check が失敗しています。" \
                  "終了する前に修正してください:\n#{summary}")
    2
  end
end

exit ChangedScopeQa.run if $PROGRAM_NAME == __FILE__
