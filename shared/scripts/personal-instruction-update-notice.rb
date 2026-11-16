#!/usr/bin/env ruby
# frozen_string_literal: true

# instruction-update-notice: 配備済みの運用 instruction が、session が読み込んだ後に更新されたことを、その session に
# 伝える Claude Code の hook body (#688)。SessionStart で file の節ごとの hash を session ごとに記録し、
# UserPromptSubmit で今の file と比べて、違えば変わった節と file の場所を additionalContext で伝える。
#
# 正本: docs/instruction-update-notice.md。
#
# 強度ラベル (偽らない): steering / fail-open。読み直しを促すだけで、強制しない。
# - exit code は常に 0 で、prompt を止めない。入力が読めない・見る file が条件を満たさないときは、何も出さない。
#   記録を書けない・想定外の例外では、stderr に 1 行を出す (促しを出した後に記録を書けなかったら、次の入力で
#   もう一度促す。見逃しにしない)。
# - 見る file は、この script の実体の directory から見た ../CLAUDE.md に固定する (env や hook の入力では変えない)。
# - 記録は ${XDG_STATE_HOME:-~/.local/state}/agent-tools/personal-instruction-update-notice/<session_id>.json
#   ($AGENT_TOOLS_INSTRUCTION_NOTICE_DIR があれば、その directory)。節の名前と hash だけを書き、本文は書かない。
#   どの repository にも入れない。network には触れず、外部 command も起動しない。
#
# payload 互換: field 名と出力の形は Claude Code の hooks docs (2026-11-16 に確認) に基づく。

require "digest"
require "fileutils"
require "json"
require "time"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (stdin・file) を UTF-8 として扱う (#432)。
# scripts/lib/cli.rb (#418) と同じ固定。ENV と ARGV の encoding は変わらない。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module InstructionUpdateNotice
  NAME = "personal-instruction-update-notice"
  DIR_ENV = "AGENT_TOOLS_INSTRUCTION_NOTICE_DIR"
  EVENTS = %w[SessionStart UserPromptSubmit].freeze
  MAX_INPUT_BYTES = 1024 * 1024
  MAX_INSTRUCTION_BYTES = 256 * 1024
  # 記録を読む上限は、見る file の上限から作れる最大の記録より大きくする (読めない記録は「記録が無い」と同じに扱うので、
  # 書いた記録を読めないと、以後の更新を見逃す)。節 1 つにつき、source は 4 bytes 以上 (# と空白と名前と改行) で、
  # 記録は hash と区切りの 72 bytes と名前。名前は JSON の escape で最大 6 倍になるので、全体は source の 24 倍と
  # 封筒の分に収まる。32 倍で余裕を持たせる。
  MAX_STATE_BYTES = MAX_INSTRUCTION_BYTES * 32
  SESSION_ID_RE = /\A[A-Za-z0-9_-]{1,128}\z/.freeze
  STATE_FILE_RE = /\A[A-Za-z0-9_-]{1,128}\.json\z/.freeze
  STATE_VERSION = 1
  STATE_MAX_AGE_SECONDS = 30 * 24 * 60 * 60
  PRUNE_LIMIT = 200
  MARKER_KIND = "artifact_kind=instruction"

  # 配備済みの instruction を節に分けて比べる。この file を require すれば、hook を起動せずに使える。
  # module の本文は、sync の配備の報告が使う scripts/lib/instruction_sections.rb の InstructionSections と一字一句同じに
  # する (この script は単独で配備されるので scripts/lib を require できない)。直すときは両方を直す。一致は
  # scripts/tests/instruction-sections-test.sh が確かめる。
  module Sections
    # local の断片の節の見出し (scripts/lib/local_instructions.rb の LocalInstructions::HEADING と同じ行で、一致は
    # test が確かめる)。この行から末尾までを 1 つの節として扱い、中の見出しを区切りにも出力にも使わない
    # (断片は private な内容で、見出しも出さない。#689)。
    LOCAL_HEADING = "# この machine の local の指示 (repo の外の local な file から、agent-tools の sync が足した節)"
    LOCAL_NAME = "local instructions"
    PREAMBLE_NAME = "(preamble)"
    # agent-tools の marker の行 (HTML コメント 1 行) の開きと閉じ。
    MANAGED_PREFIX = "<!-- agent-tools:managed"
    MANAGED_SUFFIX = "-->"
    MAX_LISTED = 10
    MAX_NAME_CHARS = 80
    HEADING_RE = /\A\#{1,2}[ \t]+(\S.*)\z/.freeze
    FENCE_OPEN_RE = /\A {0,3}(`{3,}|~{3,})/.freeze

    module_function

    # content (UTF-8 の String) を節に分け、[[節の名前, 中身の SHA-256], ...] を出現の順で返す。
    # 同じ名前の節は、中身を順につないで 1 つにする。
    def digests(content)
      bodies = {}
      name = PREAMBLE_NAME
      fence = nil
      lines = content.lines.map(&:chomp)
      lines.shift if lines.first.to_s.start_with?(MANAGED_PREFIX)
      lines.each_with_index do |line, index|
        if line == LOCAL_HEADING
          (bodies[LOCAL_NAME] ||= []) << lines[(index + 1)..-1].join("\n").strip
          break
        end
        fence = next_fence(fence, line)
        heading = fence.nil? ? line[HEADING_RE, 1] : nil
        if heading
          name = heading.strip
          bodies[name] ||= []
          bodies[name] << +""
        else
          bodies[name] ||= [+""]
          bodies[name].last << line << "\n"
        end
      end
      bodies.delete(PREAMBLE_NAME) if bodies[PREAMBLE_NAME]&.all? { |body| body.strip.empty? }
      bodies.map { |section, parts| [section, Digest::SHA256.hexdigest(parts.map(&:strip).join("\n"))] }
    end

    # 行を読んだ後の fence の状態。開いていなければ nil、開いていれば [記号, 長さ]。
    # ``` の開きの行の後ろに ` があれば、fence ではなく inline code として読む。
    def next_fence(fence, line)
      run = line[FENCE_OPEN_RE, 1]
      return fence if run.nil?

      if fence.nil?
        inline = run[0] == "`" && line.sub(FENCE_OPEN_RE, "").include?("`")
        return inline ? nil : [run[0], run.length]
      end
      closes = run[0] == fence[0] && run.length >= fence[1] && line.strip == run
      closes ? nil : fence
    end

    # 2 つの版 ([[名前, hash], ...]) の違いを [[名前, :changed | :added | :removed], ...] で返す。
    # 新しい版での出現の順に並べ、消えた節は最後に置く。
    def diff(old_digests, new_digests)
      old_map = old_digests.to_h
      new_map = new_digests.to_h
      changes = new_digests.each_with_object([]) do |(section, digest), acc|
        if !old_map.key?(section)
          acc << [section, :added]
        elsif old_map[section] != digest
          acc << [section, :changed]
        end
      end
      old_digests.each { |section, _| changes << [section, :removed] unless new_map.key?(section) }
      changes
    end

    # 出力に並べる節 (MAX_LISTED 個まで) と、並べなかった数。
    def listed(changes)
      [changes.first(MAX_LISTED), [changes.size - MAX_LISTED, 0].max]
    end

    # 出力に出す節の名前。制御文字を空白にし、MAX_NAME_CHARS 字で切る。
    def display_name(section)
      section.gsub(/[[:cntrl:]]/, " ")[0, MAX_NAME_CHARS]
    end
  end

  module_function

  # entrypoint。戻り値は exit code (常に 0)。stdin の読み取りも保護範囲に入れる。
  def run
    payload = parse($stdin.read(MAX_INPUT_BYTES + 1))
    return 0 if payload.nil?

    event = payload["hook_event_name"]
    session_id = payload["session_id"]
    return 0 unless EVENTS.include?(event) && session_id.is_a?(String) && SESSION_ID_RE.match?(session_id)

    instruction_path = default_instruction_path
    current = read_instruction(instruction_path)
    return 0 if current.nil?

    dir = state_dir
    if dir.nil?
      report("no absolute state location (set #{DIR_ENV}, XDG_STATE_HOME or HOME); nothing done")
      return 0
    end
    handle(event, File.join(dir, "#{session_id}.json"), current, instruction_path, Time.now)
    0
  rescue SystemCallError, IOError => e
    report("could not read the input or update the state (#{e.class}); nothing more done")
    0
  rescue StandardError => e
    report("unexpected #{e.class}; nothing more done")
    0
  end

  def handle(event, state_file, current, instruction_path, now)
    if event == "SessionStart"
      write_state(state_file, current, now)
      prune(File.dirname(state_file), now)
      return
    end

    recorded = read_state(state_file)
    changes = recorded.nil? ? [] : Sections.diff(recorded, current)
    return if !recorded.nil? && changes.empty?

    # 促しを出してから記録を更新する (記録を書けなかったら、次の入力でもう一度促す。見逃しにしない)。
    $stdout.puts JSON.generate(notice(instruction_path, changes)) unless changes.empty?
    write_state(state_file, current, now)
  end

  # 診断の 1 行。stderr が閉じていても exit 0 を保つ。
  def report(message)
    $stderr.puts "#{NAME}: #{message}"
  rescue SystemCallError, IOError
    nil
  end

  def parse(text)
    return nil if text.nil? || text.bytesize > MAX_INPUT_BYTES

    data = JSON.parse(text)
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  # 見る file は、この script の実体 (symlink から起動されても実体) の directory から見た ../CLAUDE.md。
  def default_instruction_path
    File.expand_path("../CLAUDE.md", File.dirname(File.realpath(__FILE__)))
  end

  # 見る file の節ごとの hash。file が無い・regular file でない・symlink・大きすぎる・UTF-8 でない・先頭の行が
  # agent-tools の instruction の marker でないときは nil。
  def read_instruction(path)
    data = read_regular_file(path, MAX_INSTRUCTION_BYTES)
    return nil if data.nil?

    data.force_encoding(Encoding::UTF_8)
    return nil unless data.valid_encoding? && instruction_marker?(data.lines.first.to_s.chomp)

    Sections.digests(data)
  end

  def instruction_marker?(line)
    prefix = "#{Sections::MANAGED_PREFIX} "
    suffix = " #{Sections::MANAGED_SUFFIX}"
    return false unless line.start_with?(prefix) && line.end_with?(suffix)

    line[prefix.length...-suffix.length].split(/\s+/).include?(MARKER_KIND)
  end

  # symlink でない regular file を limit bytes まで読む。満たさない・読めないときは nil。
  # NOFOLLOW で symlink を開かず、NONBLOCK で FIFO の open を待たない。種類は開いた fd で確かめる。
  def read_regular_file(path, limit)
    File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |f|
      return nil unless f.stat.file?

      # 空の file では read(n) が nil を返す。
      data = f.read(limit + 1) || +""
      data.bytesize > limit ? nil : data
    end
  rescue SystemCallError, IOError
    nil
  end

  # 記録の directory は入口で 1 回だけ解決する。相対 path は cwd 依存になるので受け付けない (nil)。
  def state_dir
    dir = ENV[DIR_ENV].to_s
    if dir.empty?
      state = ENV["XDG_STATE_HOME"].to_s
      if state.empty?
        home = ENV["HOME"].to_s
        return nil if home.empty?

        state = File.join(home, ".local", "state")
      end
      dir = File.join(state, "agent-tools", NAME)
    end
    dir.start_with?("/") ? dir : nil
  end

  # 記録 ([[名前, hash], ...])。file が無い・読めない・形が外れるときは nil (記録が無いときと同じに扱う)。
  def read_state(path)
    data = read_regular_file(path, MAX_STATE_BYTES)
    return nil if data.nil?

    state = JSON.parse(data)
    return nil unless state.is_a?(Hash) && state["v"] == STATE_VERSION

    sections = state["sections"]
    valid = sections.is_a?(Array) && sections.all? do |pair|
      pair.is_a?(Array) && pair.size == 2 && pair.all? { |value| value.is_a?(String) }
    end
    valid ? sections : nil
  rescue JSON::ParserError
    nil
  end

  # 記録は所有者だけが読める権限で書く (directory は 0700、file は 0600)。一時 file に書いて rename で入れ替える
  # (途中で止まっても、切れた記録を残さない)。
  def write_state(path, sections, now)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir, mode: 0o700)
    temp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.tmp")
    body = JSON.generate("v" => STATE_VERSION, "recorded_at" => now.iso8601, "sections" => sections)
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |f| f.write(body + "\n") }
    File.rename(temp, path)
  rescue SystemCallError, IOError
    File.unlink(temp) if temp && File.exist?(temp)
    raise
  end

  # 古い記録を消す (STATE_MAX_AGE_SECONDS より古い、記録の名前の形の regular file だけ。1 回に PRUNE_LIMIT 個まで)。
  # 掃除の失敗は記録の成否に関わらないので、握って進む。
  def prune(dir, now)
    removed = 0
    Dir.children(dir).each do |entry|
      break if removed >= PRUNE_LIMIT
      next unless STATE_FILE_RE.match?(entry)

      file = File.join(dir, entry)
      stat = File.lstat(file)
      next unless stat.file? && now - stat.mtime > STATE_MAX_AGE_SECONDS

      File.unlink(file)
      removed += 1
    end
  rescue SystemCallError
    nil
  end

  def notice(instruction_path, changes)
    names = render(changes)
    context = [
      "運用 instruction の file が、この session が読み込んだ後に配備で更新されています。",
      "file: #{instruction_path}",
      "変わった節: #{names}",
      "この session の context にある運用 instruction は、更新の前の版のことがあります。" \
        "作業を続ける前にこの file を読み、違うところは file の版に従ってください。",
    ].join("\n")
    {
      "hookSpecificOutput" => { "hookEventName" => "UserPromptSubmit", "additionalContext" => context },
      "systemMessage" => "運用 instruction が更新されています (変わった節: #{names})。この session に読み直しを促しました。",
    }
  end

  SUFFIXES = { changed: "", added: "(追加)", removed: "(削除)" }.freeze

  def render(changes)
    shown, rest = Sections.listed(changes)
    text = shown.map { |section, kind| "「#{Sections.display_name(section)}」#{SUFFIXES.fetch(kind)}" }.join("、")
    rest.zero? ? text : "#{text}、ほか #{rest} 個"
  end
end

exit InstructionUpdateNotice.run if $PROGRAM_NAME == __FILE__
