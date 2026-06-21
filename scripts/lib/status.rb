#!/usr/bin/env ruby
# frozen_string_literal: true

# Report-only status。dotfiles が読める contract JSON を出力する。
# Spec: docs/status-manifest-contract.md (contract_version 2)
#
# - いかなる state も変更しない (read-only inspection のみ)。
# - secrets / absolute local paths を出力しない。
# - 外部依存ゼロ、network access なし。

require "json"
require "yaml"

require_relative "assets"
require_relative "check_manifests"
require_relative "check_injection"
require_relative "build"
require_relative "sync"
require_relative "artifact_targets"
require_relative "instruction_marker"

module Status
  CONTRACT_VERSION = 2

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
        "register" => register_summary,
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
    # skill (directory) と instruction (単一ファイル) の両方を数える。
    def generated_state
      sources = safe_sources_by_name
      total = 0
      stale = 0
      Sync::TOOLS.each do |tool|
        Dir.glob(File.join(@root, "generated", tool, "skills", "*")).sort.each do |artifact|
          next unless File.directory?(artifact)

          total += 1
          stale += 1 unless fresh?(artifact, sources)
        end
        Dir.glob(File.join(@root, "generated", tool, "instructions", "*")).sort.each do |artifact|
          next unless File.file?(artifact)

          total += 1
          stale += 1 unless fresh_instruction?(artifact, sources)
        end
      end
      [total, stale]
    end

    # 壊れた / 型不正な manifest があっても status report を落とさない。source を解決できない
    # ときは空 map を返し、freshness は全 generated を stale 扱い (保守的) に倒す。manifest
    # 自体の不正は manifest_validation check が "fail" として別途報告する。
    def safe_sources_by_name
      Assets.sources_by_name(@root)
    rescue StandardError
      {}
    end

    def fresh?(artifact, sources)
      marker_path = File.join(artifact, Sync::MARKER_FILE)
      return false unless File.file?(marker_path)

      marker = YamlUtil.load(File.read(marker_path), marker_path)
      return false unless marker.is_a?(Hash)

      source = sources[marker["name"]]
      return false unless source

      marker["build_id"] == Build.build_id_for(@root, source["path"], source["format"])
    rescue StandardError
      # 鮮度判定は best-effort。marker / source / build_id 計算の失敗 (Psych /
      # source path 欠落の TypeError / source ファイル欠落の Errno 等) は、検証不能 =
      # stale として扱い、status report 全体を落とさない。
      false
    end

    # instruction (ファイル内コメント marker) の鮮度判定。
    def fresh_instruction?(path, sources)
      marker = InstructionMarker.parse(File.read(path))
      return false unless marker

      source = sources[marker["name"]]
      return false unless source

      marker["build_id"] == Build.build_id_for(@root, source["path"], source["format"])
    rescue StandardError
      # fresh? と同じく best-effort: 検証不能なら stale 扱い (Errno / TypeError 等)。
      false
    end

    # catalog (docs/register-catalog.md) の register summary。
    def register_summary
      catalog_path = File.join(@root, "generated", "catalog.json")
      summary = {
        "catalog_present" => false, "registered" => 0,
        "human_review_required" => 0, "unsupported" => 0
      }
      return summary unless File.file?(catalog_path)

      data = JSON.parse(File.read(catalog_path))
      # version の一致しない catalog は無視する (re-run register)。
      return summary unless data["catalog_version"] == ArtifactTargets::CATALOG_VERSION

      assets = data.fetch("assets", [])
      summary["catalog_present"] = true
      summary["registered"] = assets.count { |a| a["registration"] == "registered" }
      summary["human_review_required"] = assets.count { |a| a["registration"] == "human_review_required" }
      summary["unsupported"] = assets.count { |a| a["registration"] == "unsupported" }
      summary
    rescue JSON::ParserError
      summary
    end

    def sync_targets
      Sync::Runner.new(@root, @homes).plan.map do |p|
        {
          "tool" => p.tool,
          "name" => p.name,
          "state" => target_state(p),
        }
      end
    end

    # Sync plan を contract の target state にマップする。
    # registered でない artifact は配置されないため、target は missing 扱い。
    def target_state(plan)
      case plan.action
      when "update" then "stale"
      when "conflict" then "conflict"
      when "create" then "missing"
      when "skip" then plan.reason == "up-to-date" ? "managed" : "missing"
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
    reg = report["register"]
    puts "register:  catalog_present=#{reg['catalog_present']} registered=#{reg['registered']} human_review_required=#{reg['human_review_required']} unsupported=#{reg['unsupported']}"
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
