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
require "yaml"
require "fileutils"

require_relative "check_manifests"
require_relative "check_injection"

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
      _, manifest_errors = CheckManifests::Runner.new(@root).run
      unless manifest_errors.empty?
        manifest_errors.each { |line| warn line }
        raise Error, "manifest validation failed; catalog not updated"
      end

      _, findings = CheckInjection::Runner.new(@root).run
      high = findings.select { |f| f.risk == "high" }
      unless high.empty?
        high.each { |f| warn f.to_s }
        raise Error, "high risk findings present; catalog not updated"
      end

      assets = load_assets

      # human_review: rejected は finding の有無によらず矛盾状態なので fail。
      rejected = assets.select { |a| a[:human_review] == "rejected" }
      unless rejected.empty?
        names = rejected.map { |a| a[:name] }.join(", ")
        raise Error, "rejected asset(s) still present: #{names}; fix or remove them"
      end

      # manifest が宣言した risk も enforce する (docs/asset-manifest-schema.md)。
      declared_high = assets.select { |a| a[:declared_risks].include?("high") }
      unless declared_high.empty?
        names = declared_high.map { |a| a[:name] }.join(", ")
        raise Error, "declared high risk asset(s): #{names}; catalog not updated"
      end

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

    def load_assets
      paths = Dir.glob(File.join(@root, "shared/**/*.asset.yml")) +
              Dir.glob(File.join(@root, "shared/**/asset.yml"))
      paths.sort.map do |full|
        rel = full.sub(%r{\A#{Regexp.escape(@root)}/}, "")
        data = load_yaml(File.read(full), rel)
        {
          name: data["name"],
          kind: data["kind"],
          visibility: data["visibility"],
          targets: data["targets"],
          source: data["source"],
          human_review: data.dig("review", "human_review"),
          declared_risks: (data["risk"] || {}).values,
          manifest_path: rel,
          flagged: false,
        }
      end
    end

    # medium finding の path を asset の source path / manifest path に対応づける。
    def assign_findings(assets, mediums)
      mediums.each do |finding|
        asset = assets.find { |a| owns_path?(a, finding.path) }
        unless asset
          raise Error, "medium finding on #{finding.path} cannot be attributed to any asset"
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
        "checks" => {
          "manifest_validation" => "pass",
          "prompt_injection_static" => asset[:flagged] ? "human_review" : "pass",
        },
        "registration" => registration,
      }
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
