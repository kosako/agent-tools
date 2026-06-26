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

  # build が扱える artifact_kind。
  SUPPORTED_KINDS = %w[skill instruction].freeze

  # asset.kind から導出する既定の artifact_kind。
  # compatibility.<tool>.artifact_kind が明示されればそちらを優先する。
  DEFAULT_BY_KIND = {
    "skill" => "skill",
    "prompt" => "skill",
    "workflow" => "skill",
    "instruction" => "instruction",
    "template" => "skill",
    "script" => "script",
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

  # tool home 内の target-artifact 配置先 path を返す (path 解決の単一 source)。
  # home は解決済みの tool home dir (例 ~/.claude / ~/.codex)。
  # - instruction: tool 固有ファイル名 (INSTRUCTION_FILENAMES)。claude-code は
  #   agent-tools/ subdir 配下に所有ファイルを置き、codex は home 直下。filename を
  #   解決できない tool では nil。
  # - script: <home>/agent-tools/scripts/<name> (配布は P3-04)。
  # - それ以外 (skill 等): <home>/skills/<name>。
  def self.target_path(home, tool, name, kind)
    case kind
    when "instruction"
      filename = INSTRUCTION_FILENAMES[tool]
      filename && (tool == "claude-code" ? File.join(home, "agent-tools", filename) : File.join(home, filename))
    when "script"
      # script body は tool home の agent-tools/scripts/ subdir に配る (配置先の正本は
      # docs/runtime-injection-defense.md)。実際の build / sync 配布は P3-04。
      File.join(home, "agent-tools", "scripts", name)
    else
      File.join(home, "skills", name)
    end
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
    when "script"
      # script kind は P3-03b では認識・検証・配置先解決まで。build / sync 配布と marker 戦略は
      # P3-04 で入る。それまで buildable でない → register が "unsupported" にし、registered だが
      # 配布されないサイレント断裂を防ぐ (registered != buildable を作らない)。
      false
    else
      false
    end
  end
end
