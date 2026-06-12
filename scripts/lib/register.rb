#!/usr/bin/env ruby
# frozen_string_literal: true

# register: shared assets を検証し、catalog に登録状態を記録する。
# Spec: docs/register-catalog.md (catalog_version 1)
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

module Register
  CATALOG_VERSION = 1
  CATALOG_PATH = "generated/catalog.json"

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
        "catalog_version" => CATALOG_VERSION,
        "assets" => assets.map { |a| catalog_entry(a) },
      }
    end

    def write(catalog)
      path = File.join(@root, CATALOG_PATH)
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

    def catalog_entry(asset)
      # 宣言 risk の medium / unknown も human review 必須として扱う。
      review_needed = asset[:flagged] ||
                      asset[:declared_risks].any? { |r| %w[medium unknown].include?(r) }
      registration =
        if !review_needed
          "registered"
        elsif asset[:human_review] == "approved"
          "registered"
        else
          "human_review_required"
        end
      {
        "name" => asset[:name],
        "kind" => asset[:kind],
        "visibility" => asset[:visibility],
        "targets" => asset[:targets],
        "source" => asset[:source],
        # source content の決定的 hash。doctor の鮮度判定に使う。
        "build_id" => Build.build_id_for(@root, asset[:source]["path"], asset[:source]["format"]),
        "checks" => {
          "manifest_validation" => "pass",
          "prompt_injection_static" => asset[:flagged] ? "human_review" : "pass",
        },
        "registration" => registration,
      }
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
    pending = catalog["assets"].count { |a| a["registration"] == "human_review_required" }
    registered = catalog["assets"].size - pending
    unless quiet
      puts "ok: catalog written (#{registered} registered, #{pending} human review required)"
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
