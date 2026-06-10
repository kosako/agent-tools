#!/usr/bin/env ruby
# frozen_string_literal: true

# Static validator for sidecar asset manifests.
# Spec: docs/asset-manifest-schema.md (schema_version 1)
#
# 外部依存ゼロ、network access なしで実行できること。

require "yaml"

module CheckManifests
  KINDS = %w[skill prompt workflow agent instruction template].freeze
  TRACKED_VISIBILITIES = %w[public personal].freeze
  FORBIDDEN_VISIBILITIES = %w[private work client secret].freeze
  TARGETS = %w[codex claude-code].freeze
  RISK_KEYS = %w[prompt_injection privacy].freeze
  RISK_LEVELS = %w[low medium high unknown].freeze
  SOURCE_FORMATS = %w[markdown yaml json toml text directory].freeze
  REQUIRED_FIELDS = %w[schema_version name kind visibility targets risk source].freeze
  OPTIONAL_FIELDS = %w[summary description review compatibility].freeze
  REVIEW_VALUES = {
    "static_check" => %w[pending pass fail],
    "llm_review" => %w[allowed blocked not_needed],
    "human_review" => %w[pending approved rejected not_needed],
  }.freeze
  NAME_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
  ASSET_CATEGORIES = %w[skills prompts workflows agents instructions].freeze
  NON_ASSET_BASENAMES = %w[README.md].freeze

  class Runner
    attr_reader :errors

    def initialize(root)
      @root = File.expand_path(root)
      @errors = []
    end

    def run
      manifests = discover_manifests
      manifests.each { |path| validate_manifest(path) }
      check_sources_have_manifests
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
      sidecars = Dir.glob(File.join(@root, "shared/**/*.asset.yml"))
      dir_manifests = Dir.glob(File.join(@root, "shared/**/asset.yml"))
      (sidecars + dir_manifests).sort.map { |p| rel(p) }
    end

    def load_yaml(content, path)
      if Psych::VERSION.split(".").first.to_i >= 4
        YAML.safe_load(content, filename: path)
      else
        YAML.safe_load(content, [], [], false, path)
      end
    end

    def validate_manifest(path)
      content = File.read(File.join(@root, path))
      data = begin
        load_yaml(content, path)
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

      validate_schema_version(path, data["schema_version"]) if data.key?("schema_version")
      validate_name(path, data["name"]) if data.key?("name")
      validate_kind(path, data["kind"]) if data.key?("kind")
      validate_visibility(path, data["visibility"]) if data.key?("visibility")
      validate_targets(path, data["targets"]) if data.key?("targets")
      validate_risk(path, data["risk"]) if data.key?("risk")
      validate_source(path, data["source"]) if data.key?("source")
      validate_review(path, data["review"]) if data.key?("review")
      validate_text_field(path, "summary", data["summary"]) if data.key?("summary")
      validate_text_field(path, "description", data["description"]) if data.key?("description")
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
        error(path, "source.path #{source_path.inspect} is not a directory") unless File.directory?(full)
        expected_dir = File.dirname(path)
        unless source_path.chomp("/") == expected_dir
          error(path, "directory manifest must point at its own directory #{expected_dir.inspect}")
        end
      else
        error(path, "source.path #{source_path.inspect} does not exist") unless File.file?(full)
        if File.basename(path) == "asset.yml"
          error(path, "directory manifest requires source.format: directory")
        elsif File.dirname(source_path) != File.dirname(path)
          error(path, "sidecar manifest must sit next to its source file")
        end
      end
    end

    def validate_review(path, value)
      unless value.is_a?(Hash)
        error(path, "review must be a mapping")
        return
      end
      (value.keys - REVIEW_VALUES.keys).each { |key| error(path, "unknown review key: #{key}") }
      REVIEW_VALUES.each do |key, allowed|
        next unless value.key?(key)

        unless allowed.include?(value[key])
          error(path, "review.#{key} must be one of #{allowed.join(', ')}, got #{value[key].inspect}")
        end
      end
    end

    def validate_text_field(path, field, value)
      return if value.is_a?(String) && !value.strip.empty?

      error(path, "#{field} must be a non-empty string")
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
