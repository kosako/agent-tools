#!/usr/bin/env ruby
# frozen_string_literal: true

# Report-only status。dotfiles が読める contract JSON を出力する。
# Spec: docs/status-manifest-contract.md (contract_version 1)
#
# - いかなる state も変更しない (read-only inspection のみ)。
# - secrets / absolute local paths を出力しない。
# - 外部依存ゼロ、network access なし。

require "json"
require "yaml"

require_relative "check_manifests"
require_relative "check_injection"
require_relative "build"
require_relative "sync"

module Status
  CONTRACT_VERSION = 1
  # Sync の plan action から contract の target state への対応。
  ACTION_TO_STATE = {
    "skip" => "managed",
    "update" => "stale",
    "conflict" => "conflict",
    "create" => "missing",
  }.freeze

  class Runner
    def initialize(root, homes)
      @root = File.expand_path(root)
      @homes = homes
    end

    def report
      manifest_count, manifest_errors = CheckManifests::Runner.new(@root).run
      _, findings = CheckInjection::Runner.new(@root).run
      generated_total, generated_stale = generated_state

      {
        "contract_version" => CONTRACT_VERSION,
        "repo" => {
          "present" => File.directory?(File.join(@root, "shared")),
          "clean" => repo_clean?,
        },
        "assets" => {
          "total" => manifest_count,
          "manifest_errors" => manifest_errors.size,
        },
        "checks" => {
          "manifest_validation" => manifest_errors.empty? ? "pass" : "fail",
          "prompt_injection_static" => injection_outcome(findings),
        },
        "generated" => {
          "total" => generated_total,
          "stale" => generated_stale,
        },
        "sync_targets" => sync_targets,
      }
    end

    private

    def repo_clean?
      out = IO.popen(["git", "-C", @root, "status", "--porcelain"], err: File::NULL, &:read)
      $?.success? && out.empty?
    rescue SystemCallError
      false
    end

    def injection_outcome(findings)
      return "fail" if findings.any? { |f| f.risk == "high" }
      return "human_review" if findings.any? { |f| f.risk == "medium" }

      "pass"
    end

    # generated artifacts の数と、source より古い (build_id 不一致) artifact の数。
    def generated_state
      sources = manifest_sources
      total = 0
      stale = 0
      Sync::TOOLS.each do |tool|
        Dir.glob(File.join(@root, "generated", tool, "skills", "*")).sort.each do |artifact|
          next unless File.directory?(artifact)

          total += 1
          stale += 1 unless fresh?(artifact, sources)
        end
      end
      [total, stale]
    end

    def fresh?(artifact, sources)
      marker_path = File.join(artifact, Sync::MARKER_FILE)
      return false unless File.file?(marker_path)

      marker = load_yaml(File.read(marker_path), marker_path)
      return false unless marker.is_a?(Hash)

      source = sources[marker["name"]]
      return false unless source

      marker["build_id"] == Build.build_id_for(@root, source["path"], source["format"])
    rescue Psych::Exception
      false
    end

    def manifest_sources
      paths = Dir.glob(File.join(@root, "shared/**/*.asset.yml")) +
              Dir.glob(File.join(@root, "shared/**/asset.yml"))
      paths.each_with_object({}) do |full, map|
        data = load_yaml(File.read(full), full)
        next unless data.is_a?(Hash) && data["name"] && data["source"].is_a?(Hash)

        map[data["name"]] = data["source"]
      rescue Psych::Exception
        next
      end
    end

    def sync_targets
      Sync::Runner.new(@root, @homes).plan.map do |p|
        {
          "tool" => p.tool,
          "name" => p.name,
          "state" => ACTION_TO_STATE.fetch(p.action),
        }
      end
    end

    def load_yaml(content, path)
      if Psych::VERSION.split(".").first.to_i >= 4
        YAML.safe_load(content, filename: path)
      else
        YAML.safe_load(content, [], [], false, path)
      end
    end
  end

  def self.main(argv)
    root = Dir.pwd
    json = false
    homes = {
      "codex" => File.expand_path("~/.codex"),
      "claude-code" => File.expand_path("~/.claude"),
    }
    until argv.empty?
      case (arg = argv.shift)
      when "--root"
        root = argv.shift or abort_usage
      when "--json"
        json = true
      when "--codex-home"
        homes["codex"] = File.expand_path(argv.shift || abort_usage)
      when "--claude-home"
        homes["claude-code"] = File.expand_path(argv.shift || abort_usage)
      when "-h", "--help"
        print_usage
        return 0
      else
        warn "unknown option: #{arg}"
        abort_usage
      end
    end

    report = Runner.new(root, homes).report
    if json
      puts JSON.pretty_generate(report)
    else
      print_human(report)
    end
    0
  end

  def self.print_human(report)
    puts "repo:      present=#{report['repo']['present']} clean=#{report['repo']['clean']}"
    puts "assets:    #{report['assets']['total']} manifest(s), #{report['assets']['manifest_errors']} error(s)"
    puts "checks:    manifest=#{report['checks']['manifest_validation']} injection=#{report['checks']['prompt_injection_static']}"
    puts "generated: #{report['generated']['total']} artifact(s), #{report['generated']['stale']} stale"
    report["sync_targets"].each do |t|
      puts "target:    [#{t['tool']}] #{t['name']} #{t['state']}"
    end
  end

  def self.print_usage
    puts "usage: status.sh [--root DIR] [--json] [--codex-home DIR] [--claude-home DIR]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Status.main(ARGV) if $PROGRAM_NAME == __FILE__
