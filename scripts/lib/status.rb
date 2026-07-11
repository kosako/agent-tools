#!/usr/bin/env ruby
# frozen_string_literal: true

# Report-only status。dotfiles が読める contract JSON を出力する。
# Spec: docs/status-manifest-contract.md (contract_version 3)
#
# - いかなる state も変更しない (read-only inspection のみ)。
# - secrets / absolute local paths を出力しない。
# - 外部依存ゼロ、network access なし。

require "json"

require_relative "assets"
require_relative "check_manifests"
require_relative "check_injection"
require_relative "build"
require_relative "sync"
require_relative "artifact_targets"
require_relative "catalog"
require_relative "yaml_marker"
require_relative "instruction_marker"
require_relative "cli"

module Status
  CONTRACT_VERSION = 3

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
    # skill (directory) / instruction (単一ファイル) / script (単一ファイル + sidecar) を数える。
    def generated_state
      sources = safe_sources_by_name
      total = 0
      stale = 0
      ArtifactTargets::TOOLS.each do |tool|
        Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "skill"), "*")).sort.each do |artifact|
          next unless File.directory?(artifact)

          total += 1
          stale += 1 unless fresh?(artifact, sources)
        end
        Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "instruction"), "*")).sort.each do |artifact|
          next unless File.file?(artifact)

          total += 1
          stale += 1 unless fresh_instruction?(artifact, sources)
        end
        Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "script"), "*")).sort.each do |artifact|
          next unless File.file?(artifact)
          next if artifact.end_with?(ArtifactTargets::MARKER_BASENAME) # sidecar marker は本体と一緒に数える

          total += 1
          stale += 1 unless fresh_script?(artifact, sources)
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

    # skill (directory) の鮮度判定。dir 直下の marker を読む。
    def fresh?(artifact, sources)
      fresh_by_marker_file?(File.join(artifact, ArtifactTargets::MARKER_BASENAME), sources)
    end

    # script (単一ファイル) の鮮度判定。sidecar marker を読む。
    def fresh_script?(artifact, sources)
      fresh_by_marker_file?(ArtifactTargets.sidecar_marker_path(artifact), sources)
    end

    # YAML marker file (skill の dir 直下 / script の sidecar) から鮮度を判定する。
    def fresh_by_marker_file?(marker_path, sources)
      marker_fresh?(YamlMarker.read_file(marker_path), sources)
    rescue StandardError
      # 鮮度判定は best-effort。marker / source / build_id 計算の失敗 (Psych /
      # source path 欠落の TypeError / source ファイル欠落の Errno 等) は、検証不能 =
      # stale として扱い、status report 全体を落とさない。
      false
    end

    # instruction (ファイル内コメント marker) の鮮度判定。
    def fresh_instruction?(path, sources)
      marker_fresh?(InstructionMarker.parse(File.read(path)), sources)
    rescue StandardError
      # fresh? と同じく best-effort: 検証不能なら stale 扱い (Errno / TypeError 等)。
      false
    end

    # marker (nil 可) の name から source manifest を引き、build_id が現在の source 内容と
    # 一致するか。marker 形式 (YAML / HTML コメント) に依らない鮮度判定の共通 tail。
    def marker_fresh?(marker, sources)
      return false unless marker

      source = sources[marker["name"]]
      return false unless source

      marker["build_id"] == Build.build_id_for(@root, source["path"], source["format"])
    end

    # catalog (docs/register-catalog.md) の register summary。読めない catalog
    # (不在 / version 不一致 / 壊れた JSON) は catalog なし扱い (Catalog.read に委ねる)。
    def register_summary
      catalog = Catalog.read(@root)
      {
        "catalog_present" => catalog.present?,
        "registered" => catalog.entries.count { |a| a["registration"] == "registered" },
        "human_review_required" => catalog.entries.count { |a| a["registration"] == "human_review_required" },
        "unsupported" => catalog.entries.count { |a| a["registration"] == "unsupported" },
      }
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

    # Sync plan を contract の target state にマップする。skip の判定は plan.code
    # (機械可読) だけを見て、表示文言 (plan.reason) に依存しない — sync の文言変更で
    # dotfiles 連携 contract を壊さないため (#152)。
    # manifest-stale (登録判断が古い) は配置済みでも再 register が要るので stale。
    # registered でない entry は sync が配置しないが、過去に配置した実体が target に
    # 残っていることがある (一度承認して配布 → 後で gate がかかった等)。これを missing
    # (target 不在) と混同すると掃除対象に気づけないので deployed_but_inactive で
    # 区別する (#186・contract v3)。
    def target_state(plan)
      case plan.action
      when "update" then "stale"
      when "conflict" then "conflict"
      when "create" then "missing"
      when "skip"
        case plan.code
        when :up_to_date then "managed"
        when :manifest_stale then "stale"
        when :not_registered then not_registered_state(plan)
        else "missing"
        end
      else
        # sync が未知の action を導入したら、nil (doctor が KeyError で crash) に落とさず
        # conflict = fail に倒して表面化させる (fail-closed)。
        "conflict"
      end
    end

    # 未登録 (human_review_required / unsupported) entry の deployment state。
    # target 実体がディスクに在れば deployed_but_inactive、無ければ missing。
    # symlink は (dangling でも) path が塞がっている事実を隠さないため「在る」扱い
    # (sync 自体は symlink に触らない)。
    def not_registered_state(plan)
      File.exist?(plan.target) || File.symlink?(plan.target) ? "deployed_but_inactive" : "missing"
    end

  end

  def self.main(argv)
    opts = Cli.parse(argv, usage: USAGE,
                     bool_flags: %w[--json],
                     value_flags: %w[--root --codex-home --claude-home])
    return 0 if opts == :help

    root = opts["--root"] || Dir.pwd
    json = opts.key?("--json")
    homes = ArtifactTargets.default_homes
    homes["codex"] = File.expand_path(opts["--codex-home"]) if opts["--codex-home"]
    homes["claude-code"] = File.expand_path(opts["--claude-home"]) if opts["--claude-home"]

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

  USAGE = "usage: status.sh [--root DIR] [--json] [--codex-home DIR] [--claude-home DIR]"
end

exit Status.main(ARGV) if $PROGRAM_NAME == __FILE__
