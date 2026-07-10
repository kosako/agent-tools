# frozen_string_literal: true

# artifact_kind の解決と target-artifact の情報を 1 箇所に集約する。
#
# dependency-light: 他の script lib に依存しない。build / register /
# check-manifests から read され、循環 require (Build -> Gate -> CheckManifests)
# を避けるための独立 module。
module ArtifactTargets
  # catalog (generated/catalog.json) の version。reader (sync / status / doctor) は
  # これと一致しない catalog を古いものとして無視する。
  # v3: entry に manifest_path / manifest_digest を追加 (登録判断の鮮度検出, #148)。
  # v4: build_id を full SHA-256 + length-framing 化し、承認を artifact_kind に束縛
  #     (approved_artifact_kind, #184)。旧 12-hex build_id の catalog / marker は失効。
  CATALOG_VERSION = 4

  # catalog の repo root 相対 path。register が書き、Catalog.read が読む (#152)。
  CATALOG_PATH = "generated/catalog.json"

  # build が扱える artifact_kind。
  SUPPORTED_KINDS = %w[skill instruction script].freeze

  # management marker の basename。directory artifact (skill) は dir 直下にこの名前で
  # 置き、単一ファイル artifact (script) は <artifact path> + この名前の sidecar file に
  # 置く。build が書き、sync / status / doctor が所有判定に読む単一 source。
  MARKER_BASENAME = ".agent-tools-managed.yml"

  # asset.kind から導出する既定の artifact_kind。
  # compatibility.<tool>.artifact_kind が明示されればそちらを優先する。
  DEFAULT_BY_KIND = {
    "skill" => "skill",
    "prompt" => "skill",
    "workflow" => "skill",
    "instruction" => "instruction",
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

  # 単一ファイル artifact (script) の sidecar management marker file path。
  # 本体を改変せず所有を示すため、本体の隣に <artifact path>.agent-tools-managed.yml を置く
  # (docs/status-manifest-contract.md)。build (生成) と sync / status (所有判定) が共有する。
  def self.sidecar_marker_path(artifact_path)
    "#{artifact_path}#{MARKER_BASENAME}"
  end

  # tool home 内の target-artifact 配置先 path を返す (path 解決の単一 source)。
  # home は解決済みの tool home dir (例 ~/.claude / ~/.codex)。
  # name の要否は kind で変わる: instruction は name を使わない (nil 可)、
  # skill / script は name が path に入るため必須 (generated_path と同じ契約)。
  # - instruction: tool 固有ファイル名 (INSTRUCTION_FILENAMES)。claude-code は
  #   agent-tools/ subdir 配下に所有ファイルを置き、codex は home 直下。filename を
  #   解決できない tool では nil。
  # - script: <home>/agent-tools/scripts/<name>。
  # - それ以外 (skill 等): <home>/skills/<name>。
  def self.target_path(home, tool, name, kind)
    case kind
    when "instruction"
      filename = INSTRUCTION_FILENAMES[tool]
      filename && (tool == "claude-code" ? File.join(home, "agent-tools", filename) : File.join(home, filename))
    when "script"
      # script body は tool home の agent-tools/scripts/ subdir に配る (配置先の正本は
      # docs/runtime-injection-defense.md)。
      File.join(home, "agent-tools", "scripts", name)
    else
      File.join(home, "skills", name)
    end
  end

  # generated/ 配下の artifact_kind 別出力 dir。
  GENERATED_SUBDIRS = {
    "skill" => "skills",
    "instruction" => "instructions",
    "script" => "scripts",
  }.freeze

  # generated/ 配下の kind 別出力 dir (build の出力先 / status・prune の glob 起点)。
  def self.generated_dir(root, tool, kind)
    File.join(root, "generated", tool, GENERATED_SUBDIRS.fetch(kind))
  end

  # generated 側の artifact path (target_path の生成側対称。path 解決の単一 source)。
  # - instruction: tool 固有ファイル名 (INSTRUCTION_FILENAMES)。name は使わず、filename を
  #   解決できない tool では nil (target_path と同じ契約)。
  # - それ以外 (skill / script): <generated_dir>/<name>。
  def self.generated_path(root, tool, name, kind)
    if kind == "instruction"
      filename = INSTRUCTION_FILENAMES[tool]
      filename && File.join(generated_dir(root, tool, kind), filename)
    else
      File.join(generated_dir(root, tool, kind), name)
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
      # script body は単一実行ファイルとして配る (sidecar marker)。directory 形式は
      # 配置先 (<home>/agent-tools/scripts/<name>) が単一ファイルなので buildable でない
      # → register が "unsupported" にし、registered != buildable のサイレント断裂を防ぐ。
      source = asset[:source]
      format = source.is_a?(Hash) ? source["format"] : nil
      format != "directory"
    else
      false
    end
  end
end
