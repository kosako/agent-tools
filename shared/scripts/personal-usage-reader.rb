#!/usr/bin/env ruby
# frozen_string_literal: true

# usage-reader: 使用量の枠の残量を読む「読み取り口」を、repo の外の local 設定で確定して起動する固定の
# wrapper (#385)。personal-project-operating-loop の「割当」、personal-maintenance-sweep の BUDGET、grill の
# CONSULT は、残量を読むときにこの script だけを (配備先の path を literal の変数に入れ、引数なしで) 呼ぶ。
# repo root の `.agent-context.local.md` などの note に書かれた command は実行しない (note は data-only。
# docs/instruction-artifact-kind.md)。どの実行ファイルを使うかは machine ごとの設定で、中身は dotfiles が置く
# (docs/boundary-with-dotfiles.md)。
#
# 設定は `${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/usage-reader.json` に固定し、path を引数で受け取らない
# (XDG_CONFIG_HOME が絶対 path でなければ使わず、HOME も絶対 path でなければ場所を決めずに止める。どちらも
# 相対 path を cwd の repo から解決しないため)。中身は JSON object で、key は次の 2 つだけ:
# - `argv` (必須): 空でない文字列の配列。argv[0] は絶対 path で、在り、regular file で (symlink は辿った先で
#   判定する)、実行できること。
# - `timeout_sec` (任意): 1〜120 の整数。既定は 20。
# 知らない key、型や範囲の外れ、argv の要素の制御文字は不正。
#
# 起動は shell を通さない (`Process.spawn([argv0, argv0], *rest)`。要素が 1 つでも shell に渡らない形)。stdin は
# /dev/null、cwd は / (呼び出し元の repo の内容に左右されない)、子の stderr は捨てる。子は自分の process group
# で起動し、timeout と出力の上限 (1 MiB) を超えたら group ごと SIGKILL で止める。
#
# exit:
# - 0: 子が exit 0 で、stdout が空でない。stdout をそのまま出す。
# - 3: 設定 file が無い (読み取り口なし)。stdout は空。
# - 2: usage / 設定の場所を決められない / 設定が不正 / 設定 file が在るのに regular file でない・確かめられない・
#   読めない / 実行ファイルが上の条件を満たさない / 起動できない / 子が 0 以外で終わった / timeout / 出力が空か
#   上限を超えた。理由を stderr に 1 行出し、stdout は空。
# 理由文に設定の中身 (argv の値・知らない key の名前) と path は出さない。

require "json"

module UsageReader
  MAX_OUTPUT = 1024 * 1024
  DEFAULT_TIMEOUT = 20
  TIMEOUT_RANGE = (1..120).freeze
  KEYS = %w[argv timeout_sec].freeze
  EXIT_OK = 0
  EXIT_ERROR = 2
  EXIT_ABSENT = 3

  # 設定が無いことを表す (exit 3)。
  class Absent < StandardError; end

  module_function

  def usage
    "usage: personal-usage-reader [--help]"
  end

  def help
    <<~TEXT
      #{usage}
      ${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/usage-reader.json の argv を shell を通さずに起動し、
      その stdout を出す。exit 0 = 読めた / 3 = 設定 file が無い / 2 = 不正・失敗 (理由を stderr に 1 行)。
    TEXT
  end

  # XDG_CONFIG_HOME は絶対 path のときだけ使う (XDG の仕様。相対 path を cwd の repo から解決しない)。
  def config_path
    base = ENV["XDG_CONFIG_HOME"].to_s
    base = File.join(Dir.home, ".config") unless base.start_with?("/")
    raise ArgumentError, "設定 file の場所を決められません (HOME が絶対 path ではありません)" unless base.start_with?("/")

    File.join(base, "agent-tools", "usage-reader.json")
  end

  # 無い file は Absent。在るのに regular file でない・確かめられない・読めない file は不正 (無いことにしない)。
  # symlink は辿った先で判定する (personal-codex-model-selection の設定 file と同じ扱い)。
  def read_config(path)
    begin
      stat = File.stat(path)
    rescue Errno::ENOENT
      raise Absent, "設定 file がありません (読み取り口なし)"
    end
    raise ArgumentError, "設定 file が regular file ではありません" unless stat.file?

    File.read(path, encoding: "UTF-8")
  rescue SystemCallError => e
    raise ArgumentError, "設定 file を確かめられないか読めません (#{e.class})"
  end

  def parse_config(text)
    raise ArgumentError, "設定 file が UTF-8 として読めません" unless text.valid_encoding?

    config = begin
      JSON.parse(text)
    rescue JSON::ParserError
      raise ArgumentError, "設定 file が JSON として読めません"
    end
    raise ArgumentError, "設定 file の top-level が object ではありません" unless config.is_a?(Hash)
    raise ArgumentError, "設定 file に知らない key があります" unless (config.keys - KEYS).empty?

    argv = config["argv"]
    unless argv.is_a?(Array) && !argv.empty? && argv.all? { |a| a.is_a?(String) }
      raise ArgumentError, "設定 file の argv が空でない文字列の配列ではありません"
    end
    if argv.any? { |a| !a.valid_encoding? || a =~ /[[:cntrl:]]/ }
      raise ArgumentError, "設定 file の argv の要素に制御文字か UTF-8 として読めない文字があります"
    end
    raise ArgumentError, "設定 file の argv[0] が絶対 path ではありません" unless argv[0].start_with?("/")

    timeout = config.fetch("timeout_sec", DEFAULT_TIMEOUT)
    unless timeout.is_a?(Integer) && TIMEOUT_RANGE.cover?(timeout)
      raise ArgumentError, "設定 file の timeout_sec が #{TIMEOUT_RANGE.min}〜#{TIMEOUT_RANGE.max} の整数ではありません"
    end

    [argv, timeout]
  end

  def check_executable(path)
    stat = File.stat(path)
    raise ArgumentError, "読み取り口の実行ファイルが regular file ではありません" unless stat.file?
    raise ArgumentError, "読み取り口の実行ファイルを実行できません" unless stat.executable?
  rescue Errno::ENOENT
    raise ArgumentError, "読み取り口の実行ファイルが在りません"
  rescue SystemCallError => e
    raise ArgumentError, "読み取り口の実行ファイルを確かめられません (#{e.class})"
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def kill_group(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH, Errno::EPERM
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  # deadline までに子の stdout を上限つきで読み、子の終了を待つ。戻り値は [出力, 終了 status, 止めた理由]。
  # 止めた理由は nil (自分で終わった) / :timeout / :overflow で、止めたときは group ごと kill して回収する。
  def collect(pid, reader, deadline)
    out = String.new(encoding: Encoding::BINARY)
    stopped = nil
    loop do
      remaining = deadline - now
      if remaining <= 0
        stopped = :timeout
        break
      end
      next unless IO.select([reader], nil, nil, remaining)

      chunk = reader.read_nonblock(65_536, exception: false)
      next if chunk == :wait_readable
      break if chunk.nil?

      out << chunk
      if out.bytesize > MAX_OUTPUT
        stopped = :overflow
        break
      end
    end
    status = nil
    until stopped
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      break if status
      if now >= deadline
        stopped = :timeout
      else
        sleep 0.02
      end
    end
    if stopped
      kill_group(pid)
      _, status = Process.waitpid2(pid)
    end
    [out, status, stopped]
  end

  def run_reader(argv, timeout)
    reader, writer = IO.pipe
    begin
      pid = Process.spawn([argv[0], argv[0]], *argv[1..-1],
                          in: File::NULL, out: writer, err: File::NULL, chdir: "/", pgroup: true)
    rescue SystemCallError => e
      raise ArgumentError, "読み取り口を起動できません (#{e.class})"
    ensure
      writer.close
    end
    begin
      out, status, stopped = collect(pid, reader, now + timeout)
    ensure
      reader.close
    end
    raise ArgumentError, "読み取り口が timeout_sec の時間内に終わらなかったので止めました" if stopped == :timeout
    raise ArgumentError, "読み取り口の出力が上限 (#{MAX_OUTPUT} byte) を超えました" if stopped == :overflow
    raise ArgumentError, "読み取り口が signal #{status.termsig} で終わりました" if status.signaled?
    raise ArgumentError, "読み取り口が exit #{status.exitstatus} で終わりました" unless status.success?
    raise ArgumentError, "読み取り口の出力が空です" if out.empty?

    out
  end

  def run(args)
    if args == ["--help"]
      $stdout.write(help)
      return EXIT_OK
    end
    raise ArgumentError, usage unless args.empty?

    argv, timeout = parse_config(read_config(config_path))
    check_executable(argv[0])
    out = run_reader(argv, timeout)
    $stdout.binmode
    $stdout.write(out)
    EXIT_OK
  rescue Absent => e
    warn "personal-usage-reader: #{e.message}"
    EXIT_ABSENT
  rescue ArgumentError => e
    warn "personal-usage-reader: #{e.message}"
    EXIT_ERROR
  rescue StandardError => e
    warn "personal-usage-reader: unexpected error (#{e.class})"
    EXIT_ERROR
  end
end

exit UsageReader.run(ARGV) if $PROGRAM_NAME == __FILE__
