#!/usr/bin/env ruby
# frozen_string_literal: true

# register: shared assets を検証し、catalog に登録状態を記録する。
# Spec: docs/register-catalog.md (catalog_version 3)
#
# - 副作用は generated/catalog.json の書き込みのみ。
# - gate は build と同じ: manifest error / high finding で fail し、catalog を更新しない。
# - medium finding は manifest の review.human_review と asset 単位で突き合わせる。
# - 外部依存ゼロ、network access なし。

require "json"
require "fileutils"

require_relative "assets"
require_relative "gate"
require_relative "check_injection"
require_relative "build"
require_relative "artifact_targets"

module Register
  class Error < StandardError; end

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
    end

    # catalog hash を返す。gate violation は Error を raise し、catalog は書かない。
    def run
      # 致命 gate は build と共有する (docs/register-catalog.md)。
      errors = Gate.fatal_errors(@root)
      unless errors.empty?
        errors.each { |line| warn line }
        raise Error, "fatal gate failed; catalog not updated"
      end

      findings = CheckInjection::Runner.new(@root).run.last
      assets = Assets.load_all(@root).map { |a| a.merge(flagged: false) }
      mediums = findings.select { |f| f.risk == "medium" }
      assign_findings(assets, mediums)

      {
        "catalog_version" => ArtifactTargets::CATALOG_VERSION,
        "assets" => assets.flat_map { |a| catalog_entries(a) },
      }
    end

    def write(catalog)
      path = File.join(@root, ArtifactTargets::CATALOG_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(catalog) + "\n")
    end

    private

    # medium finding の path を asset の source path / manifest path に対応づける。
    def assign_findings(assets, mediums)
      mediums.each do |finding|
        asset = assets.find { |a| owns_path?(a, finding.path) }
        unless asset
          raise Error, "medium finding on #{finding.path}, which is not part of any asset; " \
                       "clean the file or move it out of shared/"
        end

        warn finding.to_s
        asset[:flagged] = true
      end
    end

    def owns_path?(asset, path)
      source = asset[:source]["path"]
      path == source ||
        path == asset[:manifest_path] ||
        path.start_with?("#{source.chomp('/')}/")
    end

    # asset を target ごとの catalog entry (target-artifact 単位) に展開する。
    # review 観点の registration は asset 単位で決まり、buildable でない
    # target-artifact は "unsupported" にして registered != buildable を防ぐ。
    def catalog_entries(asset)
      # 宣言 risk の medium / unknown も human review 必須として扱う。
      # script artifact は実行コードの配布で、静的 gate が当てられるのは injection 文言の
      # regex のみ (コードの悪性は検査できない)。directory skill の scripts/ を #43 まで
      # fail-closed にしているのと対称に、常に human review を要求する。判定は manifest の
      # kind でなく resolve 後の artifact_kind で行う (compatibility override で任意 kind を
      # script 配布にできるため、kind 基準では迂回できてしまう)。
      script_artifact = (asset[:targets] || [])
                        .any? { |tool| ArtifactTargets.resolve(asset, tool) == "script" }
      review_needed = asset[:flagged] ||
                      script_artifact ||
                      asset[:declared_risks].any? { |r| %w[medium unknown].include?(r) }
      # source content の決定的 hash。target に依らない。doctor の鮮度判定に使う。
      build_id = Build.build_id_for(@root, asset[:source]["path"], asset[:source]["format"])
      # 承認は内容 (build_id) に紐づける。approved だけの永続承認は、承認後に source が
      # 全面的に変わっても registered のまま残る穴になる (#148)。approved_build_id が
      # 現在の build_id と一致するときだけ承認が効く。不一致は再レビューを促す。
      approval_effective = asset[:human_review] == "approved" &&
                           asset[:approved_build_id] == build_id
      if review_needed && asset[:human_review] == "approved" && !approval_effective
        warn "#{asset[:name]}: human_review is approved but review.approved_build_id does not " \
             "match current build_id #{build_id}; re-review the content and update approved_build_id"
      end
      review_registration =
        if !review_needed
          "registered"
        elsif approval_effective
          "registered"
        else
          "human_review_required"
        end

      # 登録判断 (risk / review / targets) は manifest に依存する。manifest の digest を
      # entry に記録し、reader (sync / doctor) が register 後の manifest 変更を検出できる
      # ようにする (#148)。
      manifest_digest = Assets.manifest_digest(@root, asset[:manifest_path])

      (asset[:targets] || []).map do |tool|
        registration = ArtifactTargets.buildable?(asset, tool) ? review_registration : "unsupported"
        {
          "name" => asset[:name],
          "target" => tool,
          "artifact_kind" => ArtifactTargets.resolve(asset, tool),
          "kind" => asset[:kind],
          "visibility" => asset[:visibility],
          "source" => asset[:source],
          "build_id" => build_id,
          "manifest_path" => asset[:manifest_path],
          "manifest_digest" => manifest_digest,
          "checks" => {
            "manifest_validation" => "pass",
            "prompt_injection_static" => asset[:flagged] ? "human_review" : "pass",
          },
          "registration" => registration,
        }
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

    runner = Runner.new(root)
    begin
      catalog = runner.run
    rescue Error => e
      warn "fail: #{e.message}"
      return 1
    end

    runner.write(catalog)
    entries = catalog["assets"]
    registered = entries.count { |a| a["registration"] == "registered" }
    pending = entries.count { |a| a["registration"] == "human_review_required" }
    unsupported = entries.count { |a| a["registration"] == "unsupported" }
    unless quiet
      msg = "ok: catalog written (#{registered} registered, #{pending} human review required"
      msg += ", #{unsupported} unsupported" if unsupported.positive?
      puts "#{msg})"
    end
    pending.zero? ? 0 : 3
  end

  def self.print_usage
    puts "usage: register.sh [--root DIR] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Register.main(ARGV) if $PROGRAM_NAME == __FILE__
