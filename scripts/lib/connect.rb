#!/usr/bin/env ruby
# frozen_string_literal: true

# connect: instruction の所有ファイルを確立し、人間の instruction ファイルから繋ぎ込む。
# Spec: docs/instruction-artifact-kind.md
#
# - これが人間のファイルに触る唯一の操作。日常の build / sync は触らない。
# - default は dry-run。書き込みには --apply が必須。
# - 冪等: 既に接続済みなら no-op。
# - claude-code: <claude home>/agent-tools/CLAUDE.md を所有し、<claude home>/CLAUDE.md に
#   import 1 行を足す。
# - codex: import 非対応のため <codex home>/AGENTS.md を直接所有する (空ファイルのみ
#   claim 可。中身があれば conflict)。
# - symlink / 非通常ファイルは決して触らない。
# - 外部依存ゼロ、network access なし。

require "json"
require "fileutils"

require_relative "artifact_targets"
require_relative "instruction_marker"

module Connect
  # 人間の CLAUDE.md から所有ファイルを取り込む import 行。
  CLAUDE_IMPORT = "@agent-tools/CLAUDE.md"
  CATALOG_PATH = "generated/catalog.json"

  Plan = Struct.new(:action, :tool, :kind, :path, :reason, :gen) do
    def to_s
      line = "#{action}: [#{tool}] #{kind} #{path}"
      reason ? "#{line} (#{reason})" : line
    end
  end

  class Runner
    def initialize(root, homes)
      @root = File.expand_path(root)
      @homes = homes
      load_catalog
    end

    # catalog を source of truth として読む (catalog_version check は sync/status/doctor と
    # 同じ)。connect は registered な instruction だけを所有確立する (review gate)。
    def load_catalog
      @catalog_present = false
      @entries = []
      path = File.join(@root, CATALOG_PATH)
      return unless File.file?(path)

      data = JSON.parse(File.read(path))
      # version の一致しない catalog は古いものとして無視する (re-run register)。
      return unless data["catalog_version"] == ArtifactTargets::CATALOG_VERSION

      @catalog_present = true
      @entries = data.fetch("assets", [])
    rescue JSON::ParserError
      @catalog_present = false
    end

    def plan
      claude_plans + codex_plans
    end

    def apply(plans)
      plans.each do |p|
        case p.action
        when "create" then do_create(p)
        when "add-import" then do_add_import(p)
        end
      end
    end

    private

    def generated_instruction(tool, filename)
      path = File.join(@root, "generated", tool, "instructions", filename)
      File.file?(path) ? path : nil
    end

    # instruction の gate を connect でも enforce する (sync の plan_instruction と同じ契約)。
    # 配置してよいなら nil、不可なら skip 理由を返す。catalog 不在 / 未登録 /
    # human_review_required は配置しない。さらに、配置する generated 物が catalog entry と
    # 一致する (target + name + build_id) ことも確認する。不一致は source 変更後に register
    # していない (古い registered のまま未レビュー content を配置する) ことを意味するので塞ぐ。
    def unconnectable_reason(tool, gen)
      return "no catalog; run scripts/register.sh first" unless @catalog_present

      entry = @entries.find { |e| e["target"] == tool && e["artifact_kind"] == "instruction" }
      return "not in catalog; run scripts/register.sh first" unless entry
      unless entry["registration"] == "registered"
        return "instruction not registered (#{entry["registration"]})"
      end

      marker = InstructionMarker.parse(File.read(gen))
      unless marker && marker["target"] == tool &&
             marker["name"] == entry["name"] && marker["build_id"] == entry["build_id"]
        return "generated instruction is stale; run scripts/build.sh && scripts/register.sh first"
      end

      nil
    end

    # claude-code: 所有ファイル (agent-tools/CLAUDE.md) と人間の CLAUDE.md への import。
    def claude_plans
      tool = "claude-code"
      home = @homes.fetch(tool)
      gen = generated_instruction(tool, "CLAUDE.md")
      return [] unless gen # instruction artifact が無ければ connect 不要

      owned = ArtifactTargets.target_path(home, tool, nil, "instruction")
      import_file = File.join(home, "CLAUDE.md")
      reason = unconnectable_reason(tool, gen)
      return [Plan.new("skip", tool, "owned", owned, reason, gen)] if reason

      [owned_plan(tool, gen, owned), claude_import_plan(tool, import_file)]
    end

    # codex: import 非対応なのでグローバル AGENTS.md を直接所有する。
    def codex_plans
      tool = "codex"
      home = @homes.fetch(tool)
      gen = generated_instruction(tool, "AGENTS.md")
      return [] unless gen

      owned = ArtifactTargets.target_path(home, tool, nil, "instruction")
      reason = unconnectable_reason(tool, gen)
      return [Plan.new("skip", tool, "owned", owned, reason, gen)] if reason

      [owned_plan(tool, gen, owned)]
    end

    # 所有ファイルの create / 接続済み skip / conflict を判定する。
    # symlink / dir / 特殊ファイルは触らない。空ファイルのみ claim 可。
    def owned_plan(tool, gen, owned)
      if File.symlink?(File.dirname(owned))
        return Plan.new("conflict", tool, "owned", owned, "owned parent dir is a symlink", gen)
      end
      if File.symlink?(owned)
        return Plan.new("conflict", tool, "owned", owned, "owned path is a symlink", gen)
      end
      if File.exist?(owned) && !File.file?(owned)
        return Plan.new("conflict", tool, "owned", owned, "owned path is not a regular file", gen)
      end
      return Plan.new("create", tool, "owned", owned, nil, gen) unless File.exist?(owned)

      content = File.read(owned)
      if content.strip.empty?
        return Plan.new("create", tool, "owned", owned, "claiming empty file", gen)
      end
      if InstructionMarker.managed?(content, tool)
        return Plan.new("skip", tool, "owned", owned, "already connected", gen)
      end

      Plan.new("conflict", tool, "owned", owned, "unmanaged file at owned path", gen)
    end

    # 人間の CLAUDE.md へ import 1 行を足す plan。symlink は触らない。冪等。
    def claude_import_plan(tool, import_file)
      if File.symlink?(import_file)
        return Plan.new("conflict", tool, "import", import_file, "CLAUDE.md is a symlink", nil)
      end
      if File.exist?(import_file) && !File.file?(import_file)
        return Plan.new("conflict", tool, "import", import_file, "CLAUDE.md is not a regular file", nil)
      end
      if File.file?(import_file)
        content = File.read(import_file)
        if content.lines.any? { |l| l.strip == CLAUDE_IMPORT }
          return Plan.new("skip", tool, "import", import_file, "import already present", nil)
        end
      end
      Plan.new("add-import", tool, "import", import_file, nil, nil)
    end

    def do_create(plan)
      FileUtils.mkdir_p(File.dirname(plan.path))
      FileUtils.cp(plan.gen, plan.path)
    end

    # 既存内容と改行スタイルを保持して import 1 行を追記する。
    def do_add_import(plan)
      if File.file?(plan.path)
        content = File.read(plan.path)
        nl = content.include?("\r\n") ? "\r\n" : "\n"
        sep = content.empty? || content.end_with?(nl) ? "" : nl
        File.write(plan.path, "#{content}#{sep}#{CLAUDE_IMPORT}#{nl}")
      else
        FileUtils.mkdir_p(File.dirname(plan.path))
        File.write(plan.path, "#{CLAUDE_IMPORT}\n")
      end
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
      puts "ok: no instruction artifacts to connect (run scripts/build.sh first)" unless quiet
      return 0
    end

    plans.each { |p| puts p.to_s.sub(Dir.home, "~") }

    conflicts = plans.select { |p| p.action == "conflict" }
    unless conflicts.empty?
      warn "fail: #{conflicts.size} conflict(s); nothing was applied"
      return 1
    end

    changes = plans.count { |p| %w[create add-import].include?(p.action) }
    if apply
      runner.apply(plans)
      puts "ok: applied #{changes} change(s)" unless quiet
    else
      puts "ok: dry-run only, #{changes} change(s) pending (use --apply to write)" unless quiet
    end
    0
  end

  def self.print_usage
    puts "usage: connect.sh [--root DIR] [--apply] [--codex-home DIR] [--claude-home DIR] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Connect.main(ARGV) if $PROGRAM_NAME == __FILE__
