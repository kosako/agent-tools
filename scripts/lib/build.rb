#!/usr/bin/env ruby
# frozen_string_literal: true

# Build adapters: shared source assets から tool 別 artifacts を生成する。
# Spec: docs/asset-manifest-schema.md, docs/status-manifest-contract.md,
#       adapters/<tool>/README.md
#
# 外部依存ゼロ、network access なしで実行できること。
# 生成前に manifest validation と static injection check を必ず通す。

require "yaml"
require "digest"
require "fileutils"

require_relative "yaml_util"
require_relative "check_manifests"
require_relative "check_injection"

module Build
  TOOLS = %w[codex claude-code].freeze
  SUPPORTED_ARTIFACT_KINDS = %w[skill].freeze
  # artifact_kind が compatibility で指定されない場合の既定値。
  DEFAULT_ARTIFACT_KIND = {
    "skill" => "skill",
    "prompt" => "skill",
    "workflow" => "skill",
    "instruction" => "skill",
    "template" => "skill",
  }.freeze

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
      @built = []
      @skipped = []
    end

    attr_reader :built, :skipped

    def run
      manifests.each do |path, data|
        kind = data["kind"]
        data["targets"].each do |tool|
          artifact_kind = artifact_kind_for(data, tool, kind)
          unless SUPPORTED_ARTIFACT_KINDS.include?(artifact_kind)
            @skipped << "#{path}: unsupported artifact_kind #{artifact_kind.inspect} for #{tool}"
            next
          end
          build_skill(tool, data)
        end
      end
      [@built, @skipped]
    end

    private

    def manifests
      paths = Dir.glob(File.join(@root, "shared/**/*.asset.yml")) +
              Dir.glob(File.join(@root, "shared/**/asset.yml"))
      paths.sort.map do |full|
        rel = full.sub(%r{\A#{Regexp.escape(@root)}/}, "")
        [rel, YamlUtil.load(File.read(full), rel)]
      end
    end


    def artifact_kind_for(data, tool, kind)
      compat = data["compatibility"]
      explicit = compat.is_a?(Hash) && compat[tool].is_a?(Hash) ? compat[tool]["artifact_kind"] : nil
      explicit || DEFAULT_ARTIFACT_KIND[kind] || "unsupported"
    end

    def build_skill(tool, data)
      name = data["name"]
      source = data.dig("source", "path")
      format = data.dig("source", "format")
      out_dir = File.join(@root, "generated", tool, "skills", name)

      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)

      if format == "directory"
        copy_directory_asset(source, out_dir)
      else
        content = File.read(File.join(@root, source))
        File.write(File.join(out_dir, "SKILL.md"), skill_markdown(content, data))
      end
      build_id = Build.build_id_for(@root, source, format)

      write_marker(out_dir, name, tool, source, build_id)
      @built << rel(out_dir)
    end

    def copy_directory_asset(source, out_dir)
      src_dir = File.join(@root, source)
      Dir.children(src_dir).sort.each do |entry|
        next if entry == "asset.yml"

        FileUtils.cp_r(File.join(src_dir, entry), File.join(out_dir, entry))
      end
    end

    # source が frontmatter を持たない場合のみ、manifest から frontmatter を生成する。
    # YAML dump を使い、特殊文字を含む summary でも frontmatter が壊れないようにする。
    def skill_markdown(content, data)
      return content if content.start_with?("---\n")

      description = data["summary"] || data["description"] || data["name"]
      frontmatter = YAML.dump("name" => data["name"], "description" => description)
      "#{frontmatter}---\n\n#{content}"
    end

    def write_marker(out_dir, name, tool, source, build_id)
      marker = {
        "repo" => "agent-tools",
        "name" => name,
        "target" => tool,
        "source" => source,
        "build_id" => build_id,
      }
      File.write(File.join(out_dir, ".agent-tools-managed.yml"), YAML.dump(marker))
    end

    def rel(path)
      path.sub(%r{\A#{Regexp.escape(@root)}/}, "")
    end
  end

  # source content から決定的な build_id を作る。status の stale 判定でも使う。
  def self.build_id_for(root, source, format)
    if format == "directory"
      src_dir = File.join(root, source)
      digest = Digest::SHA256.new
      Dir.glob(File.join(src_dir, "**/*")).sort.each do |f|
        next unless File.file?(f)
        # copy と同じく、manifest として除外するのは top-level の asset.yml のみ。
        next if f == File.join(src_dir, "asset.yml")

        digest.update(f.sub(src_dir, ""))
        digest.update(File.read(f, mode: "rb"))
      end
      "sha256:#{digest.hexdigest[0, 12]}"
    else
      "sha256:#{Digest::SHA256.hexdigest(File.read(File.join(root, source)))[0, 12]}"
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

    unless run_gates(root)
      warn "fail: pre-build gates did not pass; nothing was generated"
      return 1
    end

    built, skipped = Runner.new(root).run
    built.each { |line| puts "built: #{line}" }
    skipped.each { |line| warn "skipped: #{line}" }
    puts "ok: #{built.size} artifact(s) built" unless quiet
    0
  end

  # build 前の必須 gate。manifest validation と static injection check。
  def self.run_gates(root)
    _, errors = CheckManifests::Runner.new(root).run
    errors.each { |line| warn line }
    return false unless errors.empty?

    _, findings = CheckInjection::Runner.new(root).run
    findings.each { |line| warn line.to_s }
    findings.each do |f|
      if f.risk == "high"
        warn "fail: high risk findings present (registration fail)"
        return false
      end
    end
    if findings.any? { |f| f.risk == "medium" }
      warn "fail: medium risk findings require human review before build"
      return false
    end
    true
  end

  def self.print_usage
    puts "usage: build.sh [--root DIR] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Build.main(ARGV) if $PROGRAM_NAME == __FILE__
