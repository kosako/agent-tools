#!/usr/bin/env ruby
# frozen_string_literal: true

# session の自己申告を local に保存・表示する。正本: docs/session-progress.md (#682)。
# 単独配備するため Ruby 2.6 の標準 library だけを使う。
require "json"
require "time"
require "open3"
require "fileutils"
require "securerandom"

Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module SessionProgress
  NAME = "personal-session-progress"
  DIR_NAME = ".agent-session-progress"
  DIR_ENV = "AGENT_TOOLS_SESSION_PROGRESS_DIR"
  CLIENT_ENV = { "claude-code" => "CLAUDE_CODE_SESSION_ID", "codex" => "CODEX_THREAD_ID" }.freeze
  GIT_REPO_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].freeze
  MAX_INPUT = 32 * 1024
  MAX_FILE = 512 * 1024
  MAX_HISTORY = 200
  LOCK_SECONDS = 2
  ID = /\A[a-z0-9_-]{1,32}\z/.freeze
  SESSION_ID = /\A[A-Za-z0-9_-]{1,128}\z/.freeze
  FILE_NAME = /\A(claude-code|codex)-([A-Za-z0-9_-]{1,128})\.json\z/.freeze
  TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/.freeze
  CONTROLS = /[[:cntrl:]\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]/.freeze
  STATES = %w[pending active done skipped].freeze
  RECORD_KEYS = %w[schema_version client session_id revision created_at updated_at purpose steps decisions history history_dropped].freeze

  # message には定数の種別・項目名だけを入れる。parser / OS / gate の本文は外へ出さない。
  class Refused < StandardError; end
  class Usage < StandardError; end
  class Busy < StandardError; end
  class Missing < StandardError; end
  class UniqueHash < Hash
    def []=(key, value)
      raise Refused, "duplicate-key: json" if key?(key)

      super
    end
  end

  module_function

  def object(value, allowed, required, field)
    raise Refused, "type: #{field}" unless value.is_a?(Hash)
    raise Refused, "keys: #{field}" unless (value.keys - allowed).empty? && (required - value.keys).empty?
  end

  def line(value, min, max, field)
    unless value.is_a?(String) && value.valid_encoding? && value.length.between?(min, max) && !CONTROLS.match?(value)
      raise Refused, "text: #{field}"
    end
    raise Refused, "allow-marker: #{field}" if value.match?(/public-safety:\s*allow/i)
  end

  def identifier(value, pattern, field)
    raise Refused, "format: #{field}" unless value.is_a?(String) && value.valid_encoding? && pattern.match?(value)
  end

  def integer(value, min, field)
    raise Refused, "integer: #{field}" unless value.is_a?(Integer) && value >= min
  end

  def array(value, min, max, field)
    raise Refused, "count: #{field}" unless value.is_a?(Array) && value.size.between?(min, max)
  end

  def unique_ids(entries, field)
    ids = entries.map { |entry| entry["id"] }
    raise Refused, "duplicate-id: #{field}" unless ids.uniq.size == ids.size
  end

  def step(value, partial: false)
    keys = %w[id title state result]
    object(value, keys, partial ? ["id"] : keys, "steps")
    identifier(value["id"], ID, "steps.id")
    line(value["title"], 1, 80, "steps.title") if value.key?("title")
    line(value["result"], 0, 240, "steps.result") if value.key?("result")
    if value.key?("state") && !STATES.include?(value["state"])
      raise Refused, "enum: steps.state"
    end
    if !partial && %w[done skipped].include?(value["state"]) && value["result"].empty?
      raise Refused, "required: steps.result"
    end
  end

  def decisions(value)
    array(value, 0, 8, "decisions")
    value.each do |entry|
      keys = %w[id question options recommended]
      object(entry, keys, keys, "decisions")
      identifier(entry["id"], ID, "decisions.id")
      line(entry["question"], 1, 240, "decisions.question")
      array(entry["options"], 0, 4, "decisions.options")
      entry["options"].each { |option| line(option, 1, 120, "decisions.options") }
      rec = entry["recommended"]
      unless rec.nil? || (rec.is_a?(Integer) && rec >= 0 && rec < entry["options"].size)
        raise Refused, "index: decisions.recommended"
      end
    end
    unique_ids(value, "decisions")
  end

  def timestamp(value, field)
    identifier(value, TIME, field)
    raise Refused, "time: #{field}" unless Time.iso8601(value).utc.iso8601(3) == value
  rescue ArgumentError
    raise Refused, "time: #{field}"
  end

  def validate_patch(patch)
    object(patch, %w[purpose steps decisions], [], "input")
    line(patch["purpose"], 1, 240, "purpose") if patch.key?("purpose")
    if patch.key?("steps")
      array(patch["steps"], 0, 32, "steps")
      patch["steps"].each { |entry| step(entry, partial: true) }
      unique_ids(patch["steps"], "steps")
    end
    decisions(patch["decisions"]) if patch.key?("decisions")
    patch
  end

  def validate_record(record)
    object(record, RECORD_KEYS, RECORD_KEYS, "record")
    raise Refused, "version: schema_version" unless record["schema_version"].is_a?(Integer) && record["schema_version"] == 1
    raise Refused, "enum: client" unless CLIENT_ENV.key?(record["client"])
    identifier(record["session_id"], SESSION_ID, "session_id")
    integer(record["revision"], 1, "revision")
    %w[created_at updated_at].each { |key| timestamp(record[key], key) }
    line(record["purpose"], 1, 240, "purpose")
    array(record["steps"], 1, 32, "steps")
    record["steps"].each { |entry| step(entry) }
    unique_ids(record["steps"], "steps")
    decisions(record["decisions"])
    array(record["history"], 0, MAX_HISTORY, "history")
    record["history"].each do |entry|
      keys = %w[at step title state result]
      object(entry, keys, keys, "history")
      timestamp(entry["at"], "history.at")
      step({ "id" => entry["step"], "title" => entry["title"], "state" => entry["state"], "result" => entry["result"] })
      raise Refused, "reference: history.step" unless record["steps"].any? { |s| s["id"] == entry["step"] }
    end
    integer(record["history_dropped"], 0, "history_dropped")
    record
  end

  def parse(bytes, limit, field)
    raise Refused, "bytes: #{field}" if bytes.bytesize > limit
    bytes = bytes.dup.force_encoding(Encoding::UTF_8)
    raise Refused, "encoding: #{field}" unless bytes.valid_encoding?

    # 古い json は UniqueHash、新しい json は parser の option で重複を拒否する。
    JSON.parse(bytes, object_class: UniqueHash, create_additions: false, allow_duplicate_key: false)
  rescue JSON::ParserError, JSON::NestingError
    raise Refused, "json: #{field}"
  end

  def lstat(path)
    File.lstat(path)
  rescue Errno::ENOENT
    nil
  end

  def regular(path, field = "record")
    stat = lstat(path)
    raise Refused, "file-type: #{field}" if stat && !stat.file?
    stat
  end

  def read_record(path)
    return nil unless regular(path)

    bytes = File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(MAX_FILE + 1).to_s }
    record = validate_record(parse(bytes, MAX_FILE, "record"))
    unless File.basename(path) == "#{record['client']}-#{record['session_id']}.json"
      raise Refused, "identity: record"
    end
    record
  end

  def git(*args, dir:)
    Open3.capture3("git", *args, chdir: dir)
  end

  # git の外だけ nil。壊れた .git や bare を「git の外」として通さない。
  def repository_root(dir)
    out, _err, status = git("rev-parse", "--show-toplevel", dir: dir)
    return File.realpath(out.chomp) if status.success?

    _out, _err, probe = git("rev-parse", "--git-dir", dir: dir)
    raise Refused, "git: directory" if probe.success? || status.exitstatus != 128
    current = dir
    loop do
      raise Refused, "git: directory" if lstat(File.join(current, ".git"))
      parent = File.dirname(current)
      break if parent == current
      current = parent
    end
    nil
  end

  def location(opts)
    raise Refused, "environment: git" if GIT_REPO_ENV.any? { |key| ENV.key?(key) }
    root = repository_root(Dir.pwd)
    dir = opts.fetch("dir") { ENV[DIR_ENV] || (root && File.join(root, DIR_NAME)) }
    unless dir.is_a?(String) && dir.valid_encoding? && dir.start_with?("/") && !CONTROLS.match?(dir)
      raise Refused, "absolute-path: dir"
    end
    File.expand_path(dir)
  end

  def check_directory(dir)
    stat = lstat(dir)
    if stat && (!stat.directory? || stat.uid != Process.uid)
      raise Refused, "directory-type-owner: dir"
    end
  end

  def check_git_location(dir)
    ancestor = dir
    ancestor = File.dirname(ancestor) until File.exist?(ancestor)
    actual = File.expand_path(File.join(File.realpath(ancestor), dir.delete_prefix(ancestor).sub(/\A\//, "")))
    root = repository_root(File.realpath(ancestor))
    return unless root
    raise Refused, "git-root: dir" if actual == root

    rel = actual.delete_prefix(root + "/")
    # literal と icase を併用し、override の場所に glob の記号があってもその directory だけを照合する。
    _out, _err, status = git("--no-literal-pathspecs", "ls-files", "--error-unmatch", "--",
                             ":(icase,literal)#{rel}", dir: root)
    raise Refused, "tracked: dir" unless status.exitstatus == 1
    _out, _err, status = git("check-ignore", "-q", "--", rel + "/", dir: root)
    raise Refused, "ignored: dir" unless status.success?
  end

  def prepare_directory(dir)
    check_directory(dir)
    check_git_location(dir)
    FileUtils.mkdir_p(dir, mode: 0o700)
    check_directory(dir)
    File.chmod(0o700, dir)
  end

  def with_lock(dir)
    path = File.join(dir, ".lock")
    regular(path, "lock")
    File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |file|
      raise Refused, "file-type: lock" unless file.stat.file?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_SECONDS
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        raise Busy, "lock: directory" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      yield
    end
  end

  def merge_record(old, patch, client, session_id, now)
    raise Refused, "required: purpose" if old.nil? && !patch.key?("purpose")
    # parser の重複 key 検出用 Hash から、更新できる通常の Hash に移す。
    record = old ? old.to_h : { "schema_version" => 1, "client" => client, "session_id" => session_id, "revision" => 0,
                      "created_at" => now, "steps" => [], "decisions" => [], "history" => [], "history_dropped" => 0 }
    record["purpose"] = patch["purpose"] if patch.key?("purpose")
    record["decisions"] = patch["decisions"] if patch.key?("decisions")
    patch.fetch("steps", []).each do |change|
      index = record["steps"].index { |entry| entry["id"] == change["id"] }
      raise Refused, "required: steps.title" if index.nil? && !change.key?("title")
      before = index.nil? ? nil : record["steps"][index]
      after = (before || { "state" => "pending", "result" => "" }).merge(change)
      if index.nil?
        record["steps"] << after
      else
        record["steps"][index] = after
      end
      if before != after
        record["history"] << { "at" => now, "step" => after["id"], "title" => after["title"],
                                "state" => after["state"], "result" => after["result"] }
      end
    end
    dropped = [record["history"].size - MAX_HISTORY, 0].max
    record["history"].shift(dropped)
    record["history_dropped"] += dropped
    record["revision"] += 1
    record["updated_at"] = now
    validate_record(record)
    # 既存の記録や入力の key 順にかかわらず、保存形は docs の順にそろえる。
    record["steps"] = record["steps"].map { |entry| %w[id title state result].map { |key| [key, entry[key]] }.to_h }
    record["decisions"] = record["decisions"].map { |entry| %w[id question options recommended].map { |key| [key, entry[key]] }.to_h }
    record["history"] = record["history"].map { |entry| %w[at step title state result].map { |key| [key, entry[key]] }.to_h }
    RECORD_KEYS.map { |key| [key, record[key]] }.to_h
  end

  def strings(value)
    case value
    when Hash then value.values.flat_map { |item| strings(item) }
    when Array then value.flat_map { |item| strings(item) }
    when String then [value]
    else []
    end
  end

  def check_content(record)
    gate = File.join(File.dirname(File.realpath(__FILE__)), "personal-public-safety-gate")
    _out, err, status = Open3.capture3([gate, gate], "--stdin", stdin_data: strings(record).join("\n") + "\n", binmode: true)
    raise Refused, "unavailable: gate" unless [0, 1].include?(status.exitstatus)
    raise Refused, "safety: content" unless status.success? && err.empty?
  rescue SystemCallError, IOError
    raise Refused, "unavailable: gate"
  end

  def write_record(path, bytes)
    temp = File.join(File.dirname(path), ".progress-#{SecureRandom.hex(12)}.tmp")
    created = false
    begin
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        created = true
        file.write(bytes)
        file.flush
        file.fsync
      end
      regular(path)
      File.rename(temp, path)
    ensure
      File.unlink(temp) if created && File.exist?(temp)
    end
  end

  def identity(opts)
    client = opts["client"]
    raise Usage, "required: client" unless client
    session_id = opts.fetch("session-id") { ENV[CLIENT_ENV.fetch(client)] }
    identifier(session_id, SESSION_ID, "session_id")
    [client, session_id]
  end

  def update(opts)
    client, session_id = identity(opts)
    patch = validate_patch(parse($stdin.read(MAX_INPUT + 1).to_s, MAX_INPUT, "input"))
    dir = location(opts)
    prepare_directory(dir)
    path = File.join(dir, "#{client}-#{session_id}.json")
    with_lock(dir) do
      record = merge_record(read_record(path), patch, client, session_id, Time.now.utc.iso8601(3))
      bytes = JSON.generate(record) + "\n"
      raise Refused, "bytes: record" if bytes.bytesize > MAX_FILE
      check_content(record)
      write_record(path, bytes)
      $stdout.puts JSON.generate("ok" => true, "revision" => record["revision"], "updated_at" => record["updated_at"])
    end
  end

  def records(dir)
    check_directory(dir)
    return [] unless File.directory?(dir)

    Dir.children(dir).select { |name| FILE_NAME.match?(name) }.map do |name|
      read_record(File.join(dir, name))
    end.compact.sort_by { |record| [record["updated_at"], record["client"], record["session_id"]] }.reverse
  end

  def select_record(dir, opts)
    if opts["latest"] || !opts["client"]
      choices = records(dir)
      choices.select! { |r| r["client"] == opts["client"] } if opts["client"]
      unless opts["latest"]
        id = opts["session-id"]
        if id
          identifier(id, SESSION_ID, "session_id")
          choices.select! { |r| r["session_id"] == id }
        else
          clients = CLIENT_ENV.keys.select { |c| ENV.key?(CLIENT_ENV[c]) }
          raise Usage, "required: client" unless clients.size == 1
          return select_record(dir, opts.merge("client" => clients.first))
        end
        raise Usage, "ambiguous: client" if choices.size > 1
      end
      record = choices.first
    else
      client, id = identity(opts)
      check_directory(dir)
      record = read_record(File.join(dir, "#{client}-#{id}.json"))
    end
    raise Missing, "missing: record" unless record
    record
  end

  def age(record)
    seconds = [(Time.now - Time.iso8601(record["updated_at"])).to_i, 0].max
    seconds < 60 ? "#{seconds} 秒前" : "#{seconds / 60} 分前"
  end

  def counts(record)
    steps = record["steps"]
    "#{steps.count { |s| s['state'] == 'done' }} / #{steps.count { |s| s['state'] != 'skipped' }} 段"
  end

  def render(record)
    lines = ["自己申告 / #{record['client']} / #{record['session_id']} / revision #{record['revision']}",
             "更新: #{record['updated_at']} (#{age(record)})", "目的: #{record['purpose']}", "進み具合: #{counts(record)}"]
    record["steps"].each do |entry|
      lines << "#{"[#{entry['state']}]".ljust(10)}#{entry['title']}"
      lines << "          #{entry['result']}" unless entry["result"].empty?
    end
    lines << "決めること: #{record['decisions'].size} 件"
    record["decisions"].each do |entry|
      rec = entry["recommended"]
      suffix = rec.nil? ? "" : " (推奨: #{entry['options'][rec]})"
      lines << "  #{entry['question']}#{suffix}"
    end
    lines.join("\n")
  end

  def show(opts)
    dir = location(opts)
    loop do
      record = select_record(dir, opts)
      $stdout.puts(opts["json"] ? JSON.generate(record) : render(record))
      break unless opts["watch"]
      $stdout.flush
      sleep opts["watch"]
    end
  rescue Interrupt
    raise unless opts["watch"]
  end

  def options(argv)
    args = argv.map { |arg| arg.dup.force_encoding(Encoding::UTF_8) }
    command = args.shift
    allowed = { "update" => %w[client session-id dir stdin], "show" => %w[client session-id latest dir json watch],
                "list" => %w[dir json], "locate" => %w[client session-id dir] }
    raise Usage, "command: usage" unless allowed.key?(command)
    opts = {}
    until args.empty?
      flag = args.shift
      key = flag.sub(/\A--/, "")
      raise Usage, "option: usage" unless flag.start_with?("--") && allowed[command].include?(key) && !opts.key?(key)
      if %w[stdin latest json].include?(key)
        opts[key] = true
      else
        raise Usage, "value: usage" if args.empty?
        opts[key] = args.shift
      end
    end
    raise Usage, "enum: client" if opts["client"] && !CLIENT_ENV.key?(opts["client"])
    raise Usage, "required: stdin" if command == "update" && !opts["stdin"]
    raise Usage, "conflict: session-id/latest" if opts["session-id"] && opts["latest"]
    if opts["watch"]
      raise Usage, "range: watch" unless /\A(?:[1-9]|[1-5][0-9]|60)\z/.match?(opts["watch"])
      raise Usage, "tty: watch" unless $stdout.tty?
      opts["watch"] = opts["watch"].to_i
    end
    [command, opts]
  end

  def help
    <<~HELP
      personal-session-progress: session の自己申告を local に保存・表示する
      update --client CLIENT [--session-id ID] [--dir DIR] --stdin
      show [--client CLIENT] [--session-id ID | --latest] [--dir DIR] [--json] [--watch SECONDS]
      list [--dir DIR] [--json]
      locate --client CLIENT [--session-id ID] [--dir DIR]

      CLIENT: claude-code / codex。ID は明示値、無ければ client の
      CLAUDE_CODE_SESSION_ID / CODEX_THREAD_ID。update / locate は client が必須。
      show は --latest、明示 ID、env の session を選ぶ。client を省いて曖昧なら拒否する。
      DIR: 絶対 path。省略時は AGENT_TOOLS_SESSION_PROGRESS_DIR、次に
      呼んだ worktree の root の .agent-session-progress/。git の外では指定が必要。
      git の中の置き場は ignore し、tracked entry を含めない。

      update の stdin は変える項目だけの JSON (UTF-8、32 KiB まで):
      {"purpose":"調査と実装","steps":[{"id":"inspect","title":"既存の規約を確かめる","state":"active"}],"decisions":[]}
      続く更新の例:
      {"steps":[{"id":"inspect","state":"done","result":"規約を確かめた"}]}
      purpose は新規時に必須 (1〜240 字)。steps は id で重ね、追加時は title が必須。
      title は 1〜80 字、result は 0〜240 字。state は pending (省略時) / active / done / skipped。
      done / skipped は空でない result が必須。段は削除せず skipped にする。最大 32 段。
      decisions は全置換 (最大 8 件):
      {"decisions":[{"id":"place","question":"置き場を決める","options":["作業ツリー","別の場所"],"recommended":0}]}
      question は 1〜240 字、options は 0〜4 件 (各 1〜120 字)、recommended は index か null。
      段と判断の id は [a-z0-9_-] の 1〜32 字。session ID は [A-Za-z0-9_-] の 1〜128 字。
      自由文は短く自分でまとめた 1 行。prompt、tool の入出力、URL、local path を写さない。
      制御文字、未知・重複 key、public-safety の許可の印を拒否する。
      保存前に隣の personal-public-safety-gate --stdin が必要。警告があれば保存しない。
      履歴は最大 200 件。古い記録は自動で消さない。show --watch は 1〜60 秒、TTY だけ。
      exit: 0 成功 / 1 検査による拒否 / 2 usage・I/O / 3 lock / 4 show の記録なし / 130 中断。
      記録は承認・実行の根拠にしない。詳細: docs/session-progress.md
    HELP
  end

  def run(argv)
    if argv == ["--help"] || (argv.size == 2 && %w[update show list locate].include?(argv[0]) && argv[1] == "--help")
      $stdout.puts help
      return 0
    end
    command, opts = options(argv)
    case command
    when "update" then update(opts)
    when "show" then show(opts)
    when "list"
      rows = records(location(opts))
      $stdout.puts(opts["json"] ? JSON.generate(rows) : rows.map { |r| "#{r['client']} / #{r['session_id'][0, 12]} / #{age(r)} / #{counts(r)} / #{r['purpose']}" })
    when "locate"
      client, id = identity(opts)
      $stdout.puts File.join(location(opts), "#{client}-#{id}.json")
    end
    0
  rescue Refused => e
    warn "#{NAME}: refused: #{e.message}"
    1
  rescue Usage => e
    warn "#{NAME}: usage: #{e.message}"
    2
  rescue Busy => e
    warn "#{NAME}: busy: #{e.message}"
    3
  rescue Missing => e
    warn "#{NAME}: #{e.message}"
    4
  rescue Interrupt
    warn "#{NAME}: interrupted: operation"
    130
  rescue SystemCallError, IOError
    warn "#{NAME}: io: operation"
    2
  rescue StandardError
    warn "#{NAME}: unexpected: operation"
    2
  end
end

exit SessionProgress.run(ARGV) if $PROGRAM_NAME == __FILE__
