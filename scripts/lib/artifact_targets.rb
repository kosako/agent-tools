# frozen_string_literal: true

# artifact_kind の解決と target-artifact の情報を 1 箇所に集約する。
#
# dependency-light: 他の script lib に依存しない。build / register /
# check-manifests から read され、循環 require (Build -> Gate -> CheckManifests)
# を避けるための独立 module。
module ArtifactTargets
  # catalog (generated/catalog.json) の version。reader (sync / status / doctor) は
  # これと一致しない catalog を古いものとして無視する。
  CATALOG_VERSION = 2

  # build が扱える artifact_kind (sync の instruction 配置は後続対応)。
  SUPPORTED_KINDS = %w[skill instruction].freeze

  # asset.kind から導出する既定の artifact_kind。
  # compatibility.<tool>.artifact_kind が明示されればそちらを優先する。
  DEFAULT_BY_KIND = {
    "skill" => "skill",
    "prompt" => "skill",
    "workflow" => "skill",
    "instruction" => "instruction",
    "template" => "skill",
  }.freeze

  # instruction を配るときの tool 別ファイル名。
  INSTRUCTION_FILENAMES = {
    "claude-code" => "CLAUDE.md",
    "codex" => "AGENTS.md",
  }.freeze

  # directory skill の予約 subdirectory (top-level basename で判定)。
  # SKILL_NON_DEPLOY_DIRS: source には置くが配置先 (build 成果物) には載せない。
  #   evals = skill-creator のテスト材料。ランタイム skill の一部ではない。
  # SKILL_FORBIDDEN_DIRS: Phase 1 では未対応として fail-closed (検出で gate を止める)。
  #   scripts = 実行コード。配る前の安全検査能力 (#43 external scanner) が前提。
  SKILL_NON_DEPLOY_DIRS = %w[evals].freeze
  SKILL_FORBIDDEN_DIRS = %w[scripts].freeze

  # asset (Assets.from_manifest の hash) と tool から artifact_kind を解決する。
  # 解決できない場合は "unsupported" を返す。
  def self.resolve(asset, tool)
    compat = asset[:compatibility]
    explicit = compat.is_a?(Hash) && compat[tool].is_a?(Hash) ? compat[tool]["artifact_kind"] : nil
    explicit || DEFAULT_BY_KIND[asset[:kind]] || "unsupported"
  end

  def self.supported?(kind)
    SUPPORTED_KINDS.include?(kind)
  end

  # その tool 向けに artifact を build できるかを判定する (実 build はしない)。
  # register が「registered != buildable」のサイレント断裂を防ぐために使う。
  def self.buildable?(asset, tool)
    case resolve(asset, tool)
    when "skill"
      true
    when "instruction"
      return false unless INSTRUCTION_FILENAMES.key?(tool)

      source = asset[:source]
      format = source.is_a?(Hash) ? source["format"] : nil
      format != "directory"
    else
      false
    end
  end
end
