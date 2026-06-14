#!/usr/bin/env ruby
# frozen_string_literal: true

# doctor: state を変更せず local environment assumptions を inspect する。
# Spec: docs/sync-policy.md, docs/status-manifest-contract.md,
#       docs/register-catalog.md
#
# - read-only。いかなる state も変更しない。
# - 出力に secrets / absolute private paths を含めない (paths は tilde 表記)。
# - 外部依存ゼロ、network access なし。

require "json"
require "yaml"

require_relative "assets"
require_relative "status"
require_relative "sync"
require_relative "build"
require_relative "artifact_targets"

module Doctor
  LEVELS = %w[ok info warn fail].freeze

  Line = Struct.new(:level, :area, :message) do
    def to_s
      "#{level}: #{area}: #{message}"
    end
  end

  class Runner
    def initialize(root, homes, agents_home)
      @root = File.expand_path(root)
      @homes = homes
      @agents_home = agents_home
      @lines = []
    end

    def run
      check_runtime
      check_repo_and_assets
      check_tool_homes
      check_forbidden_targets
      check_catalog
      @lines
    end

    private

    def report(level, area, message)
      @lines << Line.new(level, area, message)
    end

    def check_runtime
      report("ok", "ruby", "#{RUBY_VERSION} (psych #{Psych::VERSION})")
      if system("git", "--version", out: File::NULL, err: File::NULL)
        report("ok", "git", "available")
      else
        report("warn", "git", "not available; repo cleanliness cannot be checked")
      end
    end

    # status report を doctor に統合する。
    def check_repo_and_assets
      status = Status::Runner.new(@root, @homes).report

      repo = status["repo"]
      report(repo["present"] ? "ok" : "fail", "repo", "present=#{repo['present']} clean=#{repo['clean']}")

      assets = status["assets"]
      level = assets["manifest_errors"].zero? ? "ok" : "fail"
      report(level, "assets", "#{assets['total']} manifest(s), #{assets['manifest_errors']} error(s)")

      checks = status["checks"]
      report(checks["manifest_validation"] == "pass" ? "ok" : "fail",
             "check", "manifest_validation=#{checks['manifest_validation']}")
      injection = checks["prompt_injection_static"]
      injection_level = { "pass" => "ok", "human_review" => "warn" }.fetch(injection, "fail")
      report(injection_level, "check", "prompt_injection_static=#{injection}")

      generated = status["generated"]
      level = generated["stale"].zero? ? "ok" : "warn"
      report(level, "generated", "#{generated['total']} artifact(s), #{generated['stale']} stale")

      status["sync_targets"].each do |t|
        level = { "managed" => "ok", "missing" => "info", "stale" => "warn", "conflict" => "fail" }.fetch(t["state"])
        report(level, "target", "[#{t['tool']}] #{t['name']} #{t['state']}")
      end
    end

    def check_tool_homes
      @homes.each do |tool, home|
        if File.directory?(home)
          skills = File.join(home, "skills")
          count = File.directory?(skills) ? Dir.glob(File.join(skills, "personal-*")).size : 0
          report("ok", "home", "[#{tool}] #{tilde(home)} present, #{count} personal skill(s)")
        else
          report("info", "home", "[#{tool}] #{tilde(home)} not present (tool not installed?)")
        end
      end
    end

    # 禁止 targets に agent-tools marker が誤って存在しないことを確認する。
    # 深い recursion はせず、禁止 path 直下の marker file だけを見る。
    def check_forbidden_targets
      offenders = forbidden_paths.select do |path|
        File.directory?(path) && File.file?(File.join(path, Sync::MARKER_FILE))
      end
      if offenders.empty?
        report("ok", "forbidden", "no agent-tools markers in forbidden targets")
      else
        offenders.each do |path|
          report("fail", "forbidden", "agent-tools marker found in forbidden target #{tilde(path)}")
        end
      end
    end

    def forbidden_paths
      codex = @homes["codex"]
      claude = @homes["claude-code"]
      paths = [
        File.join(codex, "skills", ".system"),
        File.join(codex, "plugins"),
        File.join(codex, "cache"),
        File.join(claude, "cache"),
        File.join(claude, "sessions"),
        File.join(claude, "projects"),
      ]
      paths + Dir.glob(File.join(@agents_home, "skills", "*", "{db,teams}"))
    end

    # catalog の存在と鮮度 (docs/register-catalog.md)。
    # mtime ではなく、catalog の build_id を source content から再計算して比較する。
    def check_catalog
      catalog = File.join(@root, "generated", "catalog.json")
      unless File.file?(catalog)
        report("info", "catalog", "not present (register not yet run)")
        return
      end

      data = JSON.parse(File.read(catalog))
      unless data["catalog_version"] == ArtifactTargets::CATALOG_VERSION
        report("warn", "catalog", "version mismatch (re-run register)")
        return
      end
      entries = data.fetch("assets", [])
      # target-artifact 単位の catalog を name でまとめる。build_id は target 非依存
      # なので、鮮度判定は name 単位で正しい。
      by_name = entries.each_with_object({}) { |e, h| h[e["name"]] = e }
      manifests = Assets.sources_by_name(@root)

      stale = []
      manifests.each do |name, source|
        entry = by_name[name]
        if entry.nil?
          stale << "#{name}: not in catalog"
        elsif entry["build_id"] != Build.build_id_for(@root, source["path"], source["format"])
          stale << "#{name}: content changed since register"
        end
      end
      (by_name.keys - manifests.keys).each { |name| stale << "#{name}: manifest removed" }

      if stale.empty?
        report("ok", "catalog", "present, #{entries.size} asset(s), fresh")
      else
        report("warn", "catalog", "stale (#{stale.join('; ')})")
      end
    rescue JSON::ParserError
      report("fail", "catalog", "unreadable (invalid JSON)")
    end

    def tilde(path)
      path.sub(Dir.home, "~")
    end

  end

  def self.main(argv)
    root = Dir.pwd
    homes = {
      "codex" => File.expand_path("~/.codex"),
      "claude-code" => File.expand_path("~/.claude"),
    }
    agents_home = File.expand_path("~/.agents")
    until argv.empty?
      case (arg = argv.shift)
      when "--root"
        root = argv.shift or abort_usage
      when "--codex-home"
        homes["codex"] = File.expand_path(argv.shift || abort_usage)
      when "--claude-home"
        homes["claude-code"] = File.expand_path(argv.shift || abort_usage)
      when "--agents-home"
        agents_home = File.expand_path(argv.shift || abort_usage)
      when "-h", "--help"
        print_usage
        return 0
      else
        warn "unknown option: #{arg}"
        abort_usage
      end
    end

    lines = Runner.new(root, homes, agents_home).run
    lines.each { |line| puts line }

    if lines.any? { |l| l.level == "fail" }
      warn "doctor: failures found"
      1
    else
      puts "doctor: ok"
      0
    end
  end

  def self.print_usage
    puts "usage: doctor.sh [--root DIR] [--codex-home DIR] [--claude-home DIR] [--agents-home DIR]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Doctor.main(ARGV) if $PROGRAM_NAME == __FILE__
