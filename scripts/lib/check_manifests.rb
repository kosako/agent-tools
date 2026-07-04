#!/usr/bin/env ruby
# frozen_string_literal: true

# Static validator for sidecar asset manifests.
# Spec: docs/asset-manifest-schema.md (schema_version 1)
#
# 外部依存ゼロ、network access なしで実行できること。

require "yaml"

require_relative "yaml_util"
require_relative "assets"
require_relative "artifact_targets"

module CheckManifests
  KINDS = %w[skill prompt workflow agent instruction script].freeze
  TRACKED_VISIBILITIES = %w[public personal].freeze
  FORBIDDEN_VISIBILITIES = %w[private work client secret].freeze
  TARGETS = %w[codex claude-code].freeze
  RISK_KEYS = %w[prompt_injection privacy].freeze
  RISK_LEVELS = %w[low medium high unknown].freeze
  SOURCE_FORMATS = %w[markdown yaml json toml text directory].freeze
  REQUIRED_FIELDS = %w[schema_version name kind visibility targets risk source].freeze
  OPTIONAL_FIELDS = %w[summary description review compatibility].freeze
  # review は人間が宣言する human_review (+ approved_build_id) のみ。機械計測の結果は
  # catalog 側が真実 (docs/register-catalog.md)。旧 static_check / llm_review は消費者
  # 不在の informational だったため撤去 (#153。LLM review 層を作るときは #43 の設計で再導入)。
  REVIEW_VALUES = {
    "human_review" => %w[pending approved rejected not_needed],
  }.freeze
  # 承認を内容に紐づける build_id (#148)。build.rb の build_id 形式 (sha256: + 先頭 12 hex)。
  # human_review: approved と対で使う。
  APPROVED_BUILD_ID_KEY = "approved_build_id"
  APPROVED_BUILD_ID_PATTERN = /\Asha256:[0-9a-f]{12}\z/.freeze
  NAME_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
  ASSET_CATEGORIES = %w[skills prompts workflows agents instructions scripts].freeze
  NON_ASSET_BASENAMES = %w[README.md].freeze

  class Runner
    attr_reader :errors

    def initialize(root)
      @root = File.expand_path(root)
      @errors = []
      @declared_names = Hash.new { |h, k| h[k] = [] }
      @instruction_targets = Hash.new { |h, k| h[k] = [] }
    end

    def run
      manifests = discover_manifests
      manifests.each { |path| validate_manifest(path) }
      check_duplicate_names
      check_sources_have_manifests
      check_instruction_uniqueness
      [manifests.size, @errors]
    end

    private

    def error(path, message)
      @errors << "#{path}: #{message}"
    end

    def rel(path)
      path.sub(%r{\A#{Regexp.escape(@root)}/}, "")
    end

    def discover_manifests
      Assets.manifest_paths(@root).map { |p| rel(p) }
    end


    def validate_manifest(path)
      content = File.read(File.join(@root, path))
      data = begin
        YamlUtil.load(content, path)
      rescue Psych::Exception => e
        error(path, "YAML parse error: #{e.message}")
        return
      end

      unless data.is_a?(Hash)
        error(path, "manifest must be a YAML mapping")
        return
      end

      (data.keys - REQUIRED_FIELDS - OPTIONAL_FIELDS).each do |key|
        error(path, "unknown field: #{key}")
      end
      REQUIRED_FIELDS.each do |key|
        error(path, "missing required field: #{key}") unless data.key?(key)
      end

      @declared_names[data["name"]] << path if data["name"].is_a?(String)
      collect_instruction_targets(data, path)
      check_directory_skill_contents(data, path)

      validate_schema_version(path, data["schema_version"]) if data.key?("schema_version")
      validate_name(path, data["name"]) if data.key?("name")
      validate_kind(path, data["kind"]) if data.key?("kind")
      validate_visibility(path, data["visibility"]) if data.key?("visibility")
      validate_targets(path, data["targets"]) if data.key?("targets")
      validate_risk(path, data["risk"]) if data.key?("risk")
      validate_source(path, data["source"]) if data.key?("source")
      validate_review(path, data["review"]) if data.key?("review")
      validate_compatibility(path, data["compatibility"]) if data.key?("compatibility")
      validate_text_field(path, "summary", data["summary"]) if data.key?("summary")
      validate_text_field(path, "description", data["description"]) if data.key?("description")
    end

    # compatibility は { <tool> => { "artifact_kind" => <kind> } }。無検証だと typo
    # (artifact_kind: skil など) が silent に unsupported へ落ち、配布されない原因に人間が
    # 気づけない (gate の fail-closed 方針に反する)。キーと値を厳密に検証する。
    def validate_compatibility(path, value)
      unless value.is_a?(Hash)
        error(path, "compatibility must be a mapping")
        return
      end
      value.each do |tool, entry|
        error(path, "compatibility has unknown tool: #{tool}") unless TARGETS.include?(tool)
        unless entry.is_a?(Hash)
          error(path, "compatibility.#{tool} must be a mapping")
          next
        end
        (entry.keys - %w[artifact_kind]).each do |key|
          error(path, "compatibility.#{tool} has unknown key: #{key}")
        end
        next unless entry.key?("artifact_kind")

        kind = entry["artifact_kind"]
        unless ArtifactTargets.supported?(kind)
          error(path, "compatibility.#{tool}.artifact_kind must be one of " \
                      "#{ArtifactTargets::SUPPORTED_KINDS.join(', ')}, got #{kind.inspect}")
        end
      end
    end

    def validate_schema_version(path, value)
      return if value == 1

      error(path, "schema_version must be 1, got #{value.inspect}")
    end

    def validate_name(path, value)
      unless value.is_a?(String) && value.match?(NAME_PATTERN)
        error(path, "name must be lower kebab-case, got #{value.inspect}")
        return
      end
      error(path, "name must start with personal-") unless value.start_with?("personal-")

      expected = expected_name_for(path)
      if expected && value != expected
        error(path, "name #{value.inspect} does not match asset base name #{expected.inspect}")
      end
    end

    # sidecar manifest なら source file の base name、directory manifest なら
    # directory name が asset name の期待値になる。
    def expected_name_for(path)
      base = File.basename(path)
      if base == "asset.yml"
        File.basename(File.dirname(path))
      else
        base.sub(/\.asset\.yml\z/, "")
      end
    end

    def validate_kind(path, value)
      return if KINDS.include?(value)

      error(path, "kind must be one of #{KINDS.join(', ')}, got #{value.inspect}")
    end

    def validate_visibility(path, value)
      return if TRACKED_VISIBILITIES.include?(value)

      if FORBIDDEN_VISIBILITIES.include?(value)
        error(path, "visibility #{value.inspect} must not be tracked in this public repository")
      else
        error(path, "visibility must be one of #{TRACKED_VISIBILITIES.join(', ')}, got #{value.inspect}")
      end
    end

    def validate_targets(path, value)
      unless value.is_a?(Array) && !value.empty?
        error(path, "targets must be a non-empty list")
        return
      end
      value.each do |target|
        unless TARGETS.include?(target)
          error(path, "targets must be one of #{TARGETS.join(', ')}, got #{target.inspect}")
        end
      end
      error(path, "targets must not contain duplicates") if value.uniq.size != value.size
    end

    def validate_risk(path, value)
      unless value.is_a?(Hash)
        error(path, "risk must be a mapping with keys #{RISK_KEYS.join(', ')}")
        return
      end
      (value.keys - RISK_KEYS).each { |key| error(path, "unknown risk key: #{key}") }
      RISK_KEYS.each do |key|
        unless value.key?(key)
          error(path, "missing risk key: #{key}")
          next
        end
        unless RISK_LEVELS.include?(value[key])
          error(path, "risk.#{key} must be one of #{RISK_LEVELS.join(', ')}, got #{value[key].inspect}")
        end
      end
    end

    def validate_source(path, value)
      unless value.is_a?(Hash)
        error(path, "source must be a mapping with keys path, format")
        return
      end
      (value.keys - %w[path format]).each { |key| error(path, "unknown source key: #{key}") }

      source_path = value["path"]
      format = value["format"]

      unless SOURCE_FORMATS.include?(format)
        error(path, "source.format must be one of #{SOURCE_FORMATS.join(', ')}, got #{format.inspect}")
      end

      unless source_path.is_a?(String) && !source_path.empty?
        error(path, "missing source key: path")
        return
      end
      if source_path.start_with?("/")
        error(path, "source.path must be relative, got #{source_path.inspect}")
        return
      end
      if source_path.split("/").include?("..")
        error(path, "source.path must not contain '..'")
        return
      end
      unless source_path.start_with?("shared/")
        error(path, "source.path must be under shared/, got #{source_path.inspect}")
      end

      full = File.join(@root, source_path)
      if format == "directory"
        if File.directory?(full)
          check_directory_no_symlinks(path, full)
        else
          error(path, "source.path #{source_path.inspect} is not a directory")
        end
        expected_dir = File.dirname(path)
        unless source_path.chomp("/") == expected_dir
          error(path, "directory manifest must point at its own directory #{expected_dir.inspect}")
        end
      else
        # single-file source も symlink を fail-closed で reject する (directory asset の
        # check_directory_no_symlinks と同じ境界)。symlink を許すと build の FileUtils.cp /
        # build_id_for が shared/ の外を読み、特に script は byte 保持の実行ファイルとして
        # 配布されるため、任意ファイルの内容を配布物に取り込めてしまう。
        if File.symlink?(full)
          error(path, "source.path must not be a symlink: #{source_path.inspect}")
        elsif !File.file?(full)
          error(path, "source.path #{source_path.inspect} does not exist")
        end
        if File.basename(path) == "asset.yml"
          error(path, "directory manifest requires source.format: directory")
        elsif File.dirname(source_path) != File.dirname(path)
          error(path, "sidecar manifest must sit next to its source file")
        end
      end
    end

    # directory asset 内に symlink / 特殊ファイルがあると build の cp_r が dereference し、
    # build_id 計算 (File.file?) も symlink 先を読むため、shared/ の外へ脱出しうる。
    # regular file / directory 以外を reject して fail-closed にする (gate 経由で build /
    # register が止まる)。
    def check_directory_no_symlinks(path, dir)
      Dir.glob(File.join(dir, "**/*"), File::FNM_DOTMATCH).sort.each do |entry|
        base = File.basename(entry)
        next if base == "." || base == ".."

        rel = entry.sub("#{@root}/", "")
        if File.symlink?(entry)
          error(path, "directory asset must not contain symlinks: #{rel}")
        elsif !File.file?(entry) && !File.directory?(entry)
          error(path, "directory asset must not contain special files: #{rel}")
        end
      end
    end

    def validate_review(path, value)
      unless value.is_a?(Hash)
        error(path, "review must be a mapping")
        return
      end
      (value.keys - REVIEW_VALUES.keys - [APPROVED_BUILD_ID_KEY]).each { |key| error(path, "unknown review key: #{key}") }
      REVIEW_VALUES.each do |key, allowed|
        next unless value.key?(key)

        unless allowed.include?(value[key])
          error(path, "review.#{key} must be one of #{allowed.join(', ')}, got #{value[key].inspect}")
        end
      end
      if value.key?(APPROVED_BUILD_ID_KEY)
        unless value[APPROVED_BUILD_ID_KEY].is_a?(String) && value[APPROVED_BUILD_ID_KEY] =~ APPROVED_BUILD_ID_PATTERN
          error(path, "review.#{APPROVED_BUILD_ID_KEY} must be a build_id (sha256: + 12 hex chars)")
        end
        unless value["human_review"] == "approved"
          error(path, "review.#{APPROVED_BUILD_ID_KEY} requires review.human_review: approved")
        end
      end
    end

    def validate_text_field(path, field, value)
      return if value.is_a?(String) && !value.strip.empty?

      error(path, "#{field} must be a non-empty string")
    end

    # asset name は generated artifact の path になるため、repository 全体で一意でなければ
    # ならない。重複すると build が後勝ちで上書きしてしまう。
    def check_duplicate_names
      @declared_names.each do |name, paths|
        next if paths.size < 2

        paths.each do |path|
          others = (paths - [path]).join(", ")
          error(path, "duplicate asset name #{name.inspect} (also declared in #{others})")
        end
      end
    end

    # instruction artifact を生成する asset を target 別に集める。schema の型検証が
    # 終わる前に呼ばれるため、Assets.from_manifest (risk/review の型を仮定する) は
    # 使わず、resolve に必要な kind / compatibility / source.format だけを安全に読む
    # (valid YAML だが型不正な manifest でもクラッシュしない)。directory format の
    # instruction はここで reject する。
    def collect_instruction_targets(data, path)
      targets = data["targets"]
      return unless targets.is_a?(Array)

      asset = { kind: data["kind"], compatibility: data["compatibility"] }
      instruction_tools = targets.select do |tool|
        tool.is_a?(String) && ArtifactTargets.resolve(asset, tool) == "instruction"
      end
      return if instruction_tools.empty?

      instruction_tools.each { |tool| @instruction_targets[tool] << path }

      source = data["source"]
      format = source.is_a?(Hash) ? source["format"] : nil
      if format == "directory"
        error(path, "instruction asset must be a single file, not a directory format")
      end
    end

    # directory 形式の skill asset の中身を Phase 1 制約で検証する。
    # scripts/ (実行コード) は配る前の安全検査能力が無い (#43 待ち) ため fail-closed
    # で止める。黙ってスキップせず、理由を出して gate を止める。
    # 型不正 manifest でもクラッシュしないよう、resolve に必要な値だけを安全に読む。
    def check_directory_skill_contents(data, path)
      source = data["source"]
      return unless source.is_a?(Hash) && source["format"] == "directory"

      targets = data["targets"]
      return unless targets.is_a?(Array)

      asset = { kind: data["kind"], compatibility: data["compatibility"], source: source }
      is_skill = targets.any? do |tool|
        tool.is_a?(String) && ArtifactTargets.resolve(asset, tool) == "skill"
      end
      return unless is_skill

      source_path = source["path"]
      return unless source_path.is_a?(String)

      ArtifactTargets::SKILL_FORBIDDEN_DIRS.each do |sub|
        next unless File.directory?(File.join(@root, source_path, sub))

        error(path, "directory skill must not contain #{sub}/ " \
                    "(executable code is not supported yet; blocked on external scanner, see #43)")
      end
    end

    # 1 つの target に instruction artifact を生成する asset は高々 1 個。
    # 複数あると CLAUDE.md / AGENTS.md をどの asset で生成するか決まらない
    # (後勝ち上書きを防ぐ)。
    def check_instruction_uniqueness
      @instruction_targets.each do |tool, paths|
        next if paths.size < 2

        paths.sort.each do |path|
          others = (paths - [path]).sort.join(", ")
          error(path, "multiple instruction assets target #{tool} (also: #{others}); only one allowed")
        end
      end
    end

    # shared/<category>/ 直下の asset source に manifest が無いものを検出する。
    def check_sources_have_manifests
      ASSET_CATEGORIES.each do |category|
        dir = File.join(@root, "shared", category)
        next unless File.directory?(dir)

        Dir.children(dir).sort.each do |entry|
          next if entry.start_with?(".")
          next if NON_ASSET_BASENAMES.include?(entry)
          next if entry.end_with?(".asset.yml")

          full = File.join(dir, entry)
          if File.directory?(full)
            unless File.file?(File.join(full, "asset.yml"))
              error(rel(full), "directory asset is missing asset.yml")
            end
          else
            sidecar = File.join(dir, "#{entry.sub(/\.[^.]+\z/, '')}.asset.yml")
            unless File.file?(sidecar)
              error(rel(full), "asset source is missing sidecar manifest #{File.basename(sidecar)}")
            end
          end
        end
      end
    end
  end

  def self.main(argv)
    root = Dir.pwd
    quiet = false
    until argv.empty?
      case (arg = argv.shift)
      when "--root"
        root = argv.shift or abort_usage
      when "--quiet"
        quiet = true
      when "-h", "--help"
        print_usage
        return 0
      else
        warn "unknown option: #{arg}"
        abort_usage
      end
    end

    count, errors = Runner.new(root).run
    errors.each { |line| puts line }
    if errors.empty?
      puts "ok: #{count} manifest(s) validated" unless quiet
      0
    else
      warn "#{errors.size} error(s) in #{count} manifest(s)"
      1
    end
  end

  def self.print_usage
    puts "usage: check-manifests.sh [--root DIR] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit CheckManifests.main(ARGV) if $PROGRAM_NAME == __FILE__
