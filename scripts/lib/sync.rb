#!/usr/bin/env ruby
# frozen_string_literal: true

# generated/ の personal assets を local tool directories に反映する。
# Spec: docs/sync-policy.md, docs/status-manifest-contract.md
#
# - default は dry-run。書き込みには --apply が必須。
# - 対象は `personal-` で始まる generated assets のみ。
# - 更新してよいのは agent-tools management marker を持つ target のみ。
# - 同名 unmanaged target は conflict として停止する。
# - 許可 target は artifact_kind 別: skill = <tool home>/skills/personal-*、
#   instruction = connect 確立済みの所有ファイル、script = <tool home>/agent-tools/scripts/
#   personal-* (sidecar marker つき)。それ以外の path は構成しない (docs/sync-policy.md)。

require "yaml"
require "fileutils"

require_relative "yaml_util"
require_relative "artifact_targets"
require_relative "catalog"
require_relative "instruction_marker"
require_relative "assets"

module Sync
  TOOLS = %w[codex claude-code].freeze

  # code は reason (人間向け表示文言) と対になる機械可読な skip 理由。status が contract
  # の target state 判定に読む (#152: 表示文言の変更で contract を壊さないための分離)。
  Plan = Struct.new(:action, :tool, :name, :target, :reason, :kind, :gen, :code) do
    def to_s
      line = "#{action}: [#{tool}] #{target}"
      reason ? "#{line} (#{reason})" : line
    end
  end

  class Runner
    def initialize(root, homes)
      @root = File.expand_path(root)
      @homes = homes
      load_catalog
    end

    # catalog を source of truth として読む (target-artifact 単位)。不在 / version 不一致 /
    # 壊れた JSON は catalog なし扱い (Catalog.read が fail-closed に判定)。
    def load_catalog
      result = Catalog.read(@root)
      @catalog_present = result.present?
      @entries = result.entries
    end

    attr_reader :catalog_present

    # catalog の各 target-artifact を列挙し、registered のものを配置する。
    def plan
      @entries.map { |entry| plan_for_entry(entry) }
    end

    def apply(plans)
      plans.each do |p|
        next unless %w[create update].include?(p.action)

        case p.kind
        when "instruction"
          # instruction は単一ファイル。所有先は connect が確立済み (sync は update)。
          FileUtils.mkdir_p(File.dirname(p.target))
          FileUtils.cp(p.gen, p.target)
        when "script"
          # script は単一実行ファイル + sidecar marker。本体を実行可能にして配置する。
          FileUtils.mkdir_p(File.dirname(p.target))
          FileUtils.cp(p.gen, p.target)
          File.chmod(0o755, p.target)
          FileUtils.cp(ArtifactTargets.sidecar_marker_path(p.gen), ArtifactTargets.sidecar_marker_path(p.target))
        else
          FileUtils.rm_rf(p.target)
          FileUtils.mkdir_p(File.dirname(p.target))
          FileUtils.cp_r(p.gen, p.target)
        end
      end
    end

    private

    # catalog entry (target-artifact) を plan にマップする。registered 以外は配置しない。
    def plan_for_entry(entry)
      tool = entry["target"]
      name = entry["name"]
      kind = entry["artifact_kind"]

      if entry["registration"] != "registered"
        return Plan.new("skip", tool, name, target_path(tool, name, kind), entry["registration"], kind, nil,
                        :not_registered)
      end
      # 登録判断 (risk / review / targets) は manifest に依存する。register 後に manifest が
      # 変わった entry は判断ごと stale なので、配置せず register を促す (fail-closed, #148)。
      unless Assets.manifest_fresh?(@root, entry)
        return Plan.new("skip", tool, name, target_path(tool, name, kind),
                        "manifest changed; run scripts/register.sh first", kind, nil, :manifest_stale)
      end

      case kind
      when "skill" then plan_skill(tool, name, entry["build_id"])
      when "instruction" then plan_instruction(tool, name, entry["build_id"])
      when "script" then plan_script(tool, name, entry["build_id"])
      else
        Plan.new("skip", tool, name, nil, "unsupported artifact_kind #{kind.inspect}", kind, nil, :unsupported)
      end
    end

    # registered でない entry の skip 表示に使う target path。
    # path 解決は ArtifactTargets.target_path が単一 source (skill / instruction 共通)。
    def target_path(tool, name, kind)
      ArtifactTargets.target_path(@homes.fetch(tool), tool, name, kind)
    end

    def plan_skill(tool, name, expected_build_id)
      target = target_path(tool, name, "skill")
      gen = ArtifactTargets.generated_path(@root, tool, name, "skill")

      unless name.start_with?("personal-")
        return Plan.new("conflict", tool, name, target, "generated asset without personal- prefix", "skill", gen)
      end
      unless File.directory?(gen)
        return Plan.new("skip", tool, name, target, "run build first", "skill", gen, :build_first)
      end

      source_marker = read_marker(gen)
      unless managed?(source_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "generated artifact is missing a valid marker", "skill", gen)
      end
      # generated が catalog entry と一致するか (build_id)。不一致 = register 後に build して
      # いない (stale generated)。instruction (plan_instruction) と同じく "run build first" で
      # skip し、古い generated を配置しない。
      if source_marker["build_id"] != expected_build_id
        return Plan.new("skip", tool, name, target, "run build first", "skill", gen, :build_first)
      end
      # symlink は実体の所在によらず unmanaged target として扱い、決して触らない。
      # 親 dir (<home>/skills) が symlink の場合も、rm_rf / cp_r が外へ追従しないよう
      # conflict にする (plan_instruction と同じ防御)。
      if File.symlink?(target) || File.symlink?(File.dirname(target))
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "skill", gen)
      end
      unless File.exist?(target)
        return Plan.new("create", tool, name, target, nil, "skill", gen)
      end

      target_marker = File.directory?(target) ? read_marker(target) : nil
      unless managed?(target_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "skill", gen)
      end

      if target_marker["build_id"] == source_marker["build_id"]
        Plan.new("skip", tool, name, target, "up-to-date", "skill", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "skill", gen)
      end
    end

    # instruction は connect が所有を確立する。sync は create に落ちず、未接続なら
    # connect を促す。catalog の name / build_id を真実として generated と所有先の
    # marker を照合し、update / skip を決める。
    def plan_instruction(tool, name, expected_build_id)
      gen = ArtifactTargets.generated_path(@root, tool, name, "instruction")
      unless gen
        return Plan.new("skip", tool, name, nil, "instruction unsupported for #{tool}", "instruction", nil,
                        :unsupported)
      end
      target = target_path(tool, name, "instruction")

      # instruction は plan_skill / plan_script のような personal- prefix 検査をしない:
      # あの検査は配置先 namespace (<home>/skills/personal-* 等、name から導出される path) を
      # 守るためのもので、instruction の配置先は name 非依存の固定ファイル (CLAUDE.md /
      # AGENTS.md)。name 自体の prefix は check-manifests が manifest 段階で enforce する。

      # generated が catalog entry と一致するか (target + name + build_id)。
      # 一致しなければ build が未実行 / 古い (判定は InstructionMarker.matches? に集約, #152)。
      unless File.file?(gen) &&
             InstructionMarker.matches?(File.read(gen), target: tool, name: name, build_id: expected_build_id)
        return Plan.new("skip", tool, name, target, "run build first", "instruction", gen, :build_first)
      end
      # 所有先とその親 dir が symlink なら決して触らない (connect と同じ保証)。
      if File.symlink?(target) || File.symlink?(File.dirname(target))
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "instruction", gen)
      end
      # 未接続なら connect を促す。sync は create しない。
      # 所有先が無い場合に加え、空ファイル (空白のみ) も未接続として扱う
      # (codex の AGENTS.md は空で存在しうる。空の claim は connect の責務)。
      if !File.exist?(target) || (File.file?(target) && File.read(target).strip.empty?)
        return Plan.new("skip", tool, name, target, "run connect first", "instruction", gen, :connect_first)
      end

      target_marker = File.file?(target) ? InstructionMarker.parse(File.read(target)) : nil
      # 所有先が同じ asset の agent-tools 管理か (target + name)。別 asset の残存ファイルを
      # managed と誤認しない。
      unless target_marker && target_marker["target"] == tool && target_marker["name"] == name
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "instruction", gen)
      end

      if target_marker["build_id"] == expected_build_id
        Plan.new("skip", tool, name, target, "up-to-date", "instruction", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "instruction", gen)
      end
    end

    # script は単一実行ファイル + sidecar marker。skill (plan_skill) と同じ marker ベースの
    # 所有 / stale / symlink 防御を、単一ファイルと 2 階層の配置先
    # (<home>/agent-tools/scripts/<name>) にあわせて適用する。instruction と違い人間ファイルを
    # 介さないため connect は不要で、未配置なら直接 create する。
    def plan_script(tool, name, expected_build_id)
      target = target_path(tool, name, "script")
      gen = ArtifactTargets.generated_path(@root, tool, name, "script")

      unless name.start_with?("personal-")
        return Plan.new("conflict", tool, name, target, "generated asset without personal- prefix", "script", gen)
      end
      unless File.file?(gen)
        return Plan.new("skip", tool, name, target, "run build first", "script", gen, :build_first)
      end

      source_marker = read_marker_file(ArtifactTargets.sidecar_marker_path(gen))
      unless managed?(source_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "generated artifact is missing a valid marker", "script", gen)
      end
      # generated が catalog entry と一致するか (build_id)。不一致 = register 後に build して
      # いない (stale generated)。plan_skill / plan_instruction と同じく run build first で skip。
      if source_marker["build_id"] != expected_build_id
        return Plan.new("skip", tool, name, target, "run build first", "script", gen, :build_first)
      end
      # 配置先本体・sidecar marker・その親 (agent-tools/scripts)・さらにその親
      # (agent-tools) のいずれかが symlink なら、cp / chmod が home の外へ追従しうるため
      # 触らない (plan_skill の親 dir 防御を、sync が書き込む 2 ファイル + 2 階層に広げる)。
      if script_target_symlink?(target)
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "script", gen)
      end
      unless File.exist?(target)
        return Plan.new("create", tool, name, target, nil, "script", gen)
      end

      target_marker = File.file?(target) ? read_marker_file(ArtifactTargets.sidecar_marker_path(target)) : nil
      unless managed?(target_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "script", gen)
      end

      if target_marker["build_id"] == source_marker["build_id"]
        Plan.new("skip", tool, name, target, "up-to-date", "script", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "script", gen)
      end
    end

    # sync が script で書き込む経路 (本体 / sidecar marker / 配置先 dir 2 階層) のいずれかが
    # symlink かを判定する。1 つでも symlink なら cp / chmod が home の外へ追従しうる。
    def script_target_symlink?(target)
      scripts_dir = File.dirname(target)          # <home>/agent-tools/scripts
      agent_tools_dir = File.dirname(scripts_dir) # <home>/agent-tools
      File.symlink?(target) ||
        File.symlink?(ArtifactTargets.sidecar_marker_path(target)) ||
        File.symlink?(scripts_dir) ||
        File.symlink?(agent_tools_dir)
    end

    # directory artifact (skill) の dir 直下 marker を読む。
    def read_marker(dir)
      read_marker_file(File.join(dir, ArtifactTargets::MARKER_BASENAME))
    end

    # marker file を読んで Hash を返す。不在 / 型不正 / parse 失敗は nil。
    def read_marker_file(path)
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
      msg = runner.catalog_present ? "nothing to sync (run scripts/build.sh first)" : "no catalog; run scripts/register.sh first"
      puts "ok: #{msg}" unless quiet
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
