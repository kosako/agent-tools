# frozen_string_literal: true

# instruction artifact の管理 marker (ファイル内 HTML コメント) の生成と解析を
# 1 箇所に集約する。build が生成し、connect / sync が所有判定に使う。
#
# format: 本体先頭行に 1 行。
#   <!-- agent-tools:managed v=1 repo=agent-tools name=... target=... \
#        artifact_kind=instruction source=... build_id=... -->
#
# 値に空白を含まない前提 (name=kebab, source=path, build_id=sha256:..., target=tool)。
module InstructionMarker
  PREFIX = "<!-- agent-tools:managed"
  SUFFIX = "-->"
  VERSION = "1"
  REQUIRED_FIELDS = %w[v repo name target artifact_kind source build_id].freeze

  # marker 行を生成する。
  def self.render(name:, target:, source:, build_id:)
    "#{PREFIX} v=#{VERSION} repo=agent-tools " \
      "name=#{name} target=#{target} artifact_kind=instruction " \
      "source=#{source} build_id=#{build_id} #{SUFFIX}"
  end

  # content の先頭行から marker を厳密に解析する。
  # 妥当な agent-tools instruction marker でなければ nil を返す。
  def self.parse(content)
    first = content.to_s.lines.first&.strip
    return nil unless first&.start_with?(PREFIX) && first.end_with?(SUFFIX)

    body = first[PREFIX.length...-SUFFIX.length].strip
    pairs = {}
    body.split(/\s+/).each do |token|
      key, value = token.split("=", 2)
      return nil if value.nil? || value.empty?

      return nil if pairs.key?(key) # 重複キーは不正

      pairs[key] = value
    end

    # 厳密: 必須フィールドと完全一致する (余分キーは不正)。
    return nil unless pairs.keys.sort == REQUIRED_FIELDS.sort
    return nil unless pairs["v"] == VERSION
    return nil unless pairs["repo"] == "agent-tools"
    return nil unless pairs["artifact_kind"] == "instruction"
    # 値形式の基本検証: build_id は hash、source は相対 path。
    return nil unless pairs["build_id"].start_with?("sha256:")
    return nil if pairs["source"].start_with?("/")

    pairs
  end

  # content が指定 target の agent-tools instruction として管理されているか。
  def self.managed?(content, target)
    marker = parse(content)
    !marker.nil? && marker["target"] == target
  end
end
