# frozen_string_literal: true

# plugin artifact (OpenCode の plugins/*.js) の管理 marker (ファイル内 JS ブロックコメント) の
# 生成と解析を 1 箇所に集約する。build が生成し、sync / status / doctor が所有判定に使う。
# instruction の HTML コメント marker (InstructionMarker) と対称の API (render / parse /
# managed? / matches?) を持つが、module は分ける: OpenCode の process の中で動く実行コードの
# 目印なので、解析は緩めず (strip しない・CRLF と非 UTF-8 を拒否する)、InstructionMarker の
# 挙動 (strip / CRLF 受容 / scrub) には触れない (#295)。
#
# format: 本体先頭行に 1 行。
#   /* agent-tools:managed v=1 repo=agent-tools name=... target=opencode \
#      artifact_kind=plugin source=shared/plugins/... build_id=sha256:... */
#
# 値に空白を含まない前提 (name=kebab, source=path, build_id=sha256:..., target=tool)。
# export にはしない (plugin の loader は名前付き export をすべて plugin 関数として扱うため)。
module PluginMarker
  PREFIX = "/* agent-tools:managed"
  SUFFIX = "*/"
  VERSION = "1"
  ARTIFACT_KIND = "plugin"
  REQUIRED_FIELDS = %w[v repo name target artifact_kind source build_id].freeze

  # marker 行を生成する (末尾の改行は含まない)。
  def self.render(name:, target:, source:, build_id:)
    "#{PREFIX} v=#{VERSION} repo=agent-tools " \
      "name=#{name} target=#{target} artifact_kind=#{ARTIFACT_KIND} " \
      "source=#{source} build_id=#{build_id} #{SUFFIX}"
  end

  # content の先頭行だけを厳密に解析する。妥当な agent-tools plugin marker でなければ nil。
  # 先頭行は render の出力と同じ形 (token は単一の空白区切り) でなければならず、`\r` などの
  # 制御文字を含む行、UTF-8 として不正な行、2 行目以降の marker はすべて nil に落ちる
  # (unmanaged 扱い = sync では conflict、prune では skip。fail-closed)。
  def self.parse(content)
    first = first_line(content)
    return nil unless first&.start_with?("#{PREFIX} ") && first.end_with?(" #{SUFFIX}")

    body = first[(PREFIX.length + 1)...-(SUFFIX.length + 1)]
    pairs = {}
    body.split(" ", -1).each do |token|
      key, value = token.split("=", 2)
      return nil if key.nil? || key.empty? || value.nil? || value.empty?

      return nil if pairs.key?(key) # 重複キーは不正

      pairs[key] = value
    end

    # 厳密: 必須フィールドと完全一致する (余分キーは不正)。
    return nil unless pairs.keys.sort == REQUIRED_FIELDS.sort
    return nil unless pairs["v"] == VERSION
    return nil unless pairs["repo"] == "agent-tools"
    return nil unless pairs["artifact_kind"] == ARTIFACT_KIND
    # 値形式の基本検証: build_id は hash、source は相対 path。
    return nil unless pairs["build_id"].start_with?("sha256:")
    return nil if pairs["source"].start_with?("/")

    pairs
  end

  # content が指定 target の agent-tools plugin として管理されているか。
  def self.managed?(content, target)
    marker = parse(content)
    !marker.nil? && marker["target"] == target
  end

  # content (generated plugin) が catalog entry (target / name / build_id) と一致するか。
  # 不一致 = source 変更後に build していない (stale generated)。sync が配置前の gate に使う。
  def self.matches?(content, target:, name:, build_id:)
    marker = parse(content)
    !marker.nil? && marker["target"] == target &&
      marker["name"] == name && marker["build_id"] == build_id
  end

  # 先頭行 (最初の "\n" の手前) を UTF-8 文字列として返す。bytes のまま切り出してから
  # encoding を検証するので、binread した内容でも File.read した内容でも同じ判定になる。
  # 制御文字 (`\r` / `\t` を含む) が混ざる行と、UTF-8 として不正な行は nil。
  def self.first_line(content)
    line = content.to_s.b.split("\n", 2).first
    return nil if line.nil?

    line = line.dup.force_encoding(Encoding::UTF_8)
    return nil unless line.valid_encoding?
    return nil if line.match?(/[[:cntrl:]]/)

    line
  end
  private_class_method :first_line
end
