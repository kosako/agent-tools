# frozen_string_literal: true

require_relative "marker_value"

# instruction artifact の管理 marker (ファイル内 HTML コメント) の生成と解析を
# 1 箇所に集約する。build が生成し、connect / sync が所有判定に使う。
#
# format: 本体先頭行に 1 行。
#   <!-- agent-tools:managed v=1 repo=agent-tools name=... target=... \
#        artifact_kind=instruction source=... build_id=... -->
#
# 値は MarkerValue の閉じた形だけ (render は name=kebab、target=tool、source=英数字と . _ - / の相対 path、build_id=sha256:<64 桁の hex>)。
# 空白・コメントの終端・改行を含む値は render が拒み、parse は unmanaged にする (#570。parse は安全な token の形だけを見る)。
module InstructionMarker
  PREFIX = "<!-- agent-tools:managed"
  SUFFIX = "-->"
  VERSION = "1"
  REQUIRED_FIELDS = %w[v repo name target artifact_kind source build_id].freeze

  # marker 行を生成する。
  def self.render(name:, target:, source:, build_id:)
    MarkerValue.check!(name: name, target: target, source: source, build_id: build_id)
    "#{PREFIX} v=#{VERSION} repo=agent-tools " \
      "name=#{name} target=#{target} artifact_kind=instruction " \
      "source=#{source} build_id=#{build_id} #{SUFFIX}"
  end

  # content の先頭行から marker を厳密に解析する。
  # 妥当な agent-tools instruction marker でなければ nil を返す。
  # 非 UTF-8 バイトは scrub してから解析する (String#strip の ArgumentError で
  # クラッシュさせない, #149)。marker 行自体が壊れていれば下の検査で nil に落ち、
  # unmanaged 扱い = conflict に倒れる (fail-closed)。
  def self.parse(content)
    first = content.to_s.scrub("�").lines.first&.strip
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
    # 値の形 (#570): コメントを壊しうる文字を含まない値だけを通す (MarkerValue.parse_valid?)。
    return nil unless MarkerValue.parse_valid?(name: pairs["name"], target: pairs["target"], source: pairs["source"],
                                               build_id: pairs["build_id"])

    pairs
  end

  # content が指定 target の agent-tools instruction として管理されているか。
  def self.managed?(content, target)
    marker = parse(content)
    !marker.nil? && marker["target"] == target
  end

  # content (generated instruction) が catalog entry (target / name / build_id) と一致するか。
  # 不一致 = source 変更後に build していない (stale generated)。sync / connect が配置前の
  # gate として共有する (#152: 別実装だった一致検証の単一 source)。
  def self.matches?(content, target:, name:, build_id:)
    marker = parse(content)
    !marker.nil? && marker["target"] == target &&
      marker["name"] == name && marker["build_id"] == build_id
  end
end
