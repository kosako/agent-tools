#!/usr/bin/env ruby
# frozen_string_literal: true

# generated/ の personal assets を local tool directories に反映する。
# Spec: docs/sync-policy.md, docs/status-manifest-contract.md
#
# - default は dry-run。書き込みには --apply が必須。
# - 対象は `personal-` で始まる generated assets のみ。
# - 更新してよいのは agent-tools management marker を持つ target のみ。
# - 同名 unmanaged target は conflict として停止する。
# - 許可 target は <tool home>/skills/personal-* のみ。それ以外の path は構成しない。

require "yaml"

require_relative "yaml_util"
require "fileutils"

module Sync
  MARKER_FILE = ".agent-tools-managed.yml"
  TOOLS = %w[codex claude-code].freeze

  Plan = Struct.new(:action, :tool, :name, :target, :reason) do
    def to_s
      line = "#{action}: [#{tool}] #{target}"
      reason ? "#{line} (#{reason})" : line
    end
  end

  class Runner
    def initialize(root, homes)
      @root = File.expand_path(root)
      @homes = homes
    end

    def plan
      plans = []
      TOOLS.each do |tool|
        Dir.glob(File.join(@root, "generated", tool, "skills", "*")).sort.each do |artifact|
          next unless File.directory?(artifact)

          plans << plan_for(tool, artifact)
        end
      end
      plans
    end

    def apply(plans)
      plans.each do |p|
        next unless %w[create update].include?(p.action)

        artifact = File.join(@root, "generated", p.tool, "skills", p.name)
        FileUtils.rm_rf(p.target)
        FileUtils.mkdir_p(File.dirname(p.target))
        FileUtils.cp_r(artifact, p.target)
      end
    end

    private

    def plan_for(tool, artifact)
      name = File.basename(artifact)
      target = File.join(@homes.fetch(tool), "skills", name)

      unless name.start_with?("personal-")
        return Plan.new("conflict", tool, name, target, "generated asset without personal- prefix")
      end

      source_marker = read_marker(artifact)
      unless managed?(source_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "generated artifact is missing a valid marker")
      end

      # symlink は実体の所在によらず unmanaged target として扱い、決して触らない。
      if File.symlink?(target)
        return Plan.new("conflict", tool, name, target, "existing target is a symlink")
      end

      unless File.exist?(target)
        return Plan.new("create", tool, name, target)
      end

      target_marker = File.directory?(target) ? read_marker(target) : nil
      unless managed?(target_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged")
      end

      if target_marker["build_id"] == source_marker["build_id"]
        Plan.new("skip", tool, name, target, "up-to-date")
      else
        Plan.new("update", tool, name, target)
      end
    end

    def read_marker(dir)
      path = File.join(dir, MARKER_FILE)
      return nil unless File.file?(path)

      data = YamlUtil.load(File.read(path), path)
      data.is_a?(Hash) ? data : nil
    rescue Psych::Exception
      nil
    end

    def managed?(marker, tool, name)
      marker &&
        marker["repo"] == "agent-tools" &&
        marker["target"] == tool &&
        marker["name"] == name
    end

  end

  def self.main(argv)
    root = Dir.pwd
    apply = false
    quiet = false
    homes = {
      "codex" => File.expand_path("~/.codex"),
      "claude-code" => File.expand_path("~/.claude"),
    }
    until argv.empty?
      case (arg = argv.shift)
      when "--root"
        root = argv.shift or abort_usage
      when "--apply"
        apply = true
      when "--codex-home"
        homes["codex"] = File.expand_path(argv.shift || abort_usage)
      when "--claude-home"
        homes["claude-code"] = File.expand_path(argv.shift || abort_usage)
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

    runner = Runner.new(root, homes)
    plans = runner.plan

    if plans.empty?
      puts "ok: nothing to sync (run scripts/build.sh first)" unless quiet
      return 0
    end

    # 表示は tilde 表記に正規化する (docs/status-manifest-contract.md)。
    plans.each { |p| puts p.to_s.sub(Dir.home, "~") }

    conflicts = plans.select { |p| p.action == "conflict" }
    unless conflicts.empty?
      warn "fail: #{conflicts.size} conflict(s); nothing was applied"
      return 1
    end

    changes = plans.count { |p| %w[create update].include?(p.action) }
    if apply
      runner.apply(plans)
      puts "ok: applied #{changes} change(s)" unless quiet
    else
      puts "ok: dry-run only, #{changes} change(s) pending (use --apply to write)" unless quiet
    end
    0
  end

  def self.print_usage
    puts "usage: sync.sh [--root DIR] [--apply] [--codex-home DIR] [--claude-home DIR] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Sync.main(ARGV) if $PROGRAM_NAME == __FILE__
