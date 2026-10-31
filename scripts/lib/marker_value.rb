# frozen_string_literal: true

require_relative "artifact_targets"

# 生成物のコメントの中に埋め込む管理 marker の値の形 (#570)。plugin の JS ブロックコメント (PluginMarker) と
# instruction の HTML コメント (InstructionMarker) が共有する。値に空白・コメントの終端 (`*/` / `-->`)・改行・制御文字が
# 入ると、marker の token が崩れるか、生成物のコメントの外に承認していない文字列が出うる。そこで値に許す文字を閉じた形に
# 限る。
# - render (build が作る marker) は厳密な形だけ: name は kebab、target は tool、source は相対 path、build_id は
#   sha256:<64 桁の hex>。外れれば例外 (build の前に check-manifests が source.path を同じ形で拒むので、通常は届かない)。
# - parse (配置済みの marker を読む) は、コメントを壊しうる文字が無いことだけを見る: source は render と同じ path の形、
#   ほかの値は安全な token (英数字と . _ : -)。古い build の build_id など、render の形より広い既存の marker を
#   unmanaged に変えないため。外れた marker は nil (unmanaged = fail-closed)。
module MarkerValue
  # 相対 path の segment は英数字と `.` `_` `-` だけで、`.` と `..` の segment は許さない。先頭と末尾の `/` も許さない。
  SOURCE_SEGMENT = /\A[A-Za-z0-9._-]+\z/.freeze
  # parse で source 以外の値に許す token (空白・`*`・`>`・`/`・改行・制御文字を含まない)。
  TOKEN = /\A[A-Za-z0-9._:-]+\z/.freeze
  BUILD_ID = /\Asha256:[0-9a-f]{64}\z/.freeze

  # source.path の形 (marker に埋め込む値。directory の asset の manifest では、末尾の `/` を外してから当てる)。
  def self.source?(value)
    return false unless value.is_a?(String) && !value.empty?

    value.split("/", -1).all? { |s| s.match?(SOURCE_SEGMENT) && s != "." && s != ".." }
  end

  def self.token?(value)
    value.is_a?(String) && value.match?(TOKEN)
  end

  # render が出す形 (厳密)。
  def self.render_valid?(name:, target:, source:, build_id:)
    name.is_a?(String) && name.match?(ArtifactTargets::NAME_PATTERN) && ArtifactTargets::TOOLS.include?(target) &&
      source?(source) && build_id.is_a?(String) && build_id.match?(BUILD_ID)
  end

  # parse が受け入れる形 (コメントを壊す文字が無い)。build_id の `sha256:` の接頭辞は parse の側でも見る。
  def self.parse_valid?(name:, target:, source:, build_id:)
    token?(name) && token?(target) && source?(source) && token?(build_id) && build_id.start_with?("sha256:")
  end

  # render の前の検査。外れた値は ArgumentError (marker を作らない)。
  def self.check!(name:, target:, source:, build_id:)
    return if render_valid?(name: name, target: target, source: source, build_id: build_id)

    raise ArgumentError, "marker value out of the allowed form (name / target / source / build_id)"
  end
end
