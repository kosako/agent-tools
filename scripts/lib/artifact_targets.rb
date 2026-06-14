# frozen_string_literal: true

# artifact_kind の解決と target-artifact の情報を 1 箇所に集約する。
#
# dependency-light: 他の script lib に依存しない。build / register /
# check-manifests から read され、循環 require (Build -> Gate -> CheckManifests)
# を避けるための独立 module。
module ArtifactTargets
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
end
