# frozen_string_literal: true

require "digest"

# 配備済みの instruction を節に分けて比べる (sync の配備の報告が使う。#688)。
#
# module の本文は、配備する hook (shared/scripts/personal-instruction-update-notice.rb) の
# InstructionUpdateNotice::Sections と一字一句同じにする。hook は単独で配備されるので scripts/lib を require できず、
# scripts/ は shared/ の特定の asset を require できない (shared/ の違う root でも動く) ので、同じ本文を 2 か所に持つ。
# 直すときは両方を直す。一致は scripts/tests/instruction-sections-test.sh が確かめる。
module InstructionSections
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
