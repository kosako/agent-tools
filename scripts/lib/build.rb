#!/usr/bin/env ruby
# frozen_string_literal: true

# Build adapters: shared source assets から tool 別 artifacts を生成する。
# Spec: docs/asset-manifest-schema.md, docs/status-manifest-contract.md,
#       adapters/<tool>/README.md
#
# 外部依存ゼロ、network access なしで実行できること。
# 生成前に manifest validation と static injection check を必ず通す。

require "yaml"
require "digest"
require "fileutils"

require_relative "assets"
require_relative "gate"
require_relative "artifact_targets"
require_relative "instruction_marker"

module Build
  TOOLS = %w[codex claude-code].freeze

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
      @built = []
      @skipped = []
    end

    attr_reader :built, :skipped

    def run
      Assets.load_all(@root).each do |asset|
        asset[:targets].each do |tool|
          artifact_kind = ArtifactTargets.resolve(asset, tool)
          case artifact_kind
          when "skill"
            build_skill(tool, asset)
          when "instruction"
            build_instruction(tool, asset)
          when "script"
            build_script(tool, asset)
          else
            @skipped << "#{asset[:manifest_path]}: unsupported artifact_kind " \
                        "#{artifact_kind.inspect} for #{tool}"
          end
        end
      end
      [@built, @skipped]
    end

    private

    def build_skill(tool, asset)
      name = asset[:name]
      source = asset[:source]["path"]
      format = asset[:source]["format"]
      out_dir = File.join(@root, "generated", tool, "skills", name)

      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)

      if format == "directory"
        copy_directory_asset(source, out_dir)
      else
        content = File.read(File.join(@root, source))
        File.write(File.join(out_dir, "SKILL.md"), skill_markdown(content, asset))
      end
      build_id = Build.build_id_for(@root, source, format)

      write_marker(out_dir, name, tool, source, build_id)
      @built << rel(out_dir)
    end

    # instruction asset を tool 別の単一ファイル (claude-code: CLAUDE.md /
    # codex: AGENTS.md) として生成する。所有 marker は HTML コメントで本体に埋める
    # (instruction は単一ファイル所有なので skill の dir sidecar marker が使えない)。
    def build_instruction(tool, asset)
      filename = ArtifactTargets::INSTRUCTION_FILENAMES[tool]
      unless filename
        @skipped << "#{asset[:manifest_path]}: instruction unsupported for #{tool}"
        return
      end
      source = asset[:source]["path"]
      format = asset[:source]["format"]
      if format == "directory"
        @skipped << "#{asset[:manifest_path]}: instruction must be a single file, not a directory"
        return
      end

      out_dir = File.join(@root, "generated", tool, "instructions")
      FileUtils.mkdir_p(out_dir)
      out = File.join(out_dir, filename)
      content = File.read(File.join(@root, source))
      build_id = Build.build_id_for(@root, source, format)
      File.write(out, instruction_with_marker(content, asset[:name], tool, source, build_id))
      @built << rel(out)
    end

    # script asset を単一の実行ファイルとして生成し、sidecar marker を添える。
    # 本体は byte 単位で保持する (任意の interpreter / shebang を壊さない)。所有 marker は
    # 本体を改変しないよう sidecar file に置く (docs/status-manifest-contract.md)。
    # 配置先 (<home>/agent-tools/scripts/<name>) が単一ファイルなので directory 形式は弾く。
    def build_script(tool, asset)
      name = asset[:name]
      source = asset[:source]["path"]
      format = asset[:source]["format"]
      if format == "directory"
        @skipped << "#{asset[:manifest_path]}: script must be a single file, not a directory"
        return
      end

      out_dir = File.join(@root, "generated", tool, "scripts")
      FileUtils.mkdir_p(out_dir)
      out = File.join(out_dir, name)
      FileUtils.cp(File.join(@root, source), out)
      File.chmod(0o755, out) # script は配置先で実行されるため実行可能にする
      build_id = Build.build_id_for(@root, source, format)
      File.write(ArtifactTargets.sidecar_marker_path(out), marker_yaml(name, tool, source, build_id))
      @built << rel(out)
    end

    # instruction 本体の先頭に管理 marker (HTML コメント) を 1 行入れる。
    # marker format は InstructionMarker に集約し、connect / sync が同じ解析を使う。
    def instruction_with_marker(content, name, tool, source, build_id)
      marker = InstructionMarker.render(name: name, target: tool, source: source, build_id: build_id)
      "#{marker}\n#{content}"
    end

    def copy_directory_asset(source, out_dir)
      src_dir = File.join(@root, source)
      Dir.children(src_dir).sort.each do |entry|
        next if entry == "asset.yml"
        # source-only な予約 dir (evals 等) は配置先に載せない。
        next if ArtifactTargets::SKILL_NON_DEPLOY_DIRS.include?(entry)

        FileUtils.cp_r(File.join(src_dir, entry), File.join(out_dir, entry))
      end
    end

    # source が frontmatter を持たない場合のみ、manifest から frontmatter を生成する。
    # YAML dump を使い、特殊文字を含む summary でも frontmatter が壊れないようにする。
    def skill_markdown(content, asset)
      # LF / CRLF どちらの source でも既存 frontmatter を検出する (CRLF を取りこぼして
      # manifest 由来 frontmatter を二重前置しないため)。
      return content if content.start_with?("---\n", "---\r\n")

      description = asset[:summary] || asset[:description] || asset[:name]
      frontmatter = YAML.dump("name" => asset[:name], "description" => description)
      "#{frontmatter}---\n\n#{content}"
    end

    # directory artifact (skill) の管理 marker を dir 直下に書く。
    def write_marker(out_dir, name, tool, source, build_id)
      File.write(File.join(out_dir, ArtifactTargets::MARKER_BASENAME),
                 marker_yaml(name, tool, source, build_id))
    end

    # YAML marker の本文。directory marker (skill) と sidecar marker (script) が共有する。
    def marker_yaml(name, tool, source, build_id)
      YAML.dump(
        "repo" => "agent-tools",
        "name" => name,
        "target" => tool,
        "source" => source,
        "build_id" => build_id,
      )
    end

    def rel(path)
      path.sub(%r{\A#{Regexp.escape(@root)}/}, "")
    end

    public

    # 現在の manifests に対応しない generated artifacts を削除する。
    # 削除するのは agent-tools marker を持つ directory のみ。
    # marker のない directory は warning として返し、残す。
    def prune
      expected = Hash.new { |h, k| h[k] = [] }
      script_expected = Hash.new { |h, k| h[k] = [] }
      instruction_expected = Hash.new(false)
      Assets.load_all(@root).each do |asset|
        (asset[:targets] || []).each do |tool|
          case ArtifactTargets.resolve(asset, tool)
          when "instruction" then instruction_expected[tool] = true
          when "script" then script_expected[tool] << asset[:name]
          else expected[tool] << asset[:name]
          end
        end
      end

      pruned = []
      kept = []
      TOOLS.each do |tool|
        # skill: manifest に対応しない generated directory を削除する。
        # (skill -> instruction 転換で残った stale skill もここで消える)
        Dir.glob(File.join(@root, "generated", tool, "skills", "*")).sort.each do |dir|
          next unless File.directory?(dir)
          next if expected[tool].include?(File.basename(dir))

          if managed_marker?(dir)
            FileUtils.rm_rf(dir)
            pruned << rel(dir)
          else
            kept << rel(dir)
          end
        end

        # script: manifest に対応しない managed script (と sidecar marker) を削除する。
        # sidecar marker file 自体は本体と一緒に処理するため列挙対象から外す。
        Dir.glob(File.join(@root, "generated", tool, "scripts", "*")).sort.each do |path|
          next unless File.file?(path)
          next if path.end_with?(ArtifactTargets::MARKER_BASENAME)
          next if script_expected[tool].include?(File.basename(path))

          if script_managed_marker?(path)
            FileUtils.rm_f(path)
            FileUtils.rm_f(ArtifactTargets.sidecar_marker_path(path))
            pruned << rel(path)
          else
            kept << rel(path)
          end
        end

        # instruction: 期待する canonical ファイル (INSTRUCTION_FILENAMES) 以外の
        # marker 付きファイルを削除する。instruction asset が無ければ canonical も対象。
        keep = instruction_expected[tool] ? ArtifactTargets::INSTRUCTION_FILENAMES[tool] : nil
        Dir.glob(File.join(@root, "generated", tool, "instructions", "*")).sort.each do |file|
          next unless File.file?(file)
          next if keep && File.basename(file) == keep

          if InstructionMarker.parse(File.read(file))
            FileUtils.rm_f(file)
            pruned << rel(file)
          else
            kept << rel(file)
          end
        end
      end
      [pruned, kept]
    end

    private

    # directory artifact (skill) の marker が agent-tools 管理を示すか。
    def managed_marker?(dir)
      marker_present?(File.join(dir, ArtifactTargets::MARKER_BASENAME))
    end

    # 単一ファイル artifact (script) の sidecar marker が agent-tools 管理を示すか。
    def script_managed_marker?(artifact_path)
      marker_present?(ArtifactTargets.sidecar_marker_path(artifact_path))
    end

    # marker file が存在し agent-tools repo を示すか (本文 YAML を読む)。
    def marker_present?(marker_path)
      return false unless File.file?(marker_path)

      data = YamlUtil.load(File.read(marker_path), marker_path)
      data.is_a?(Hash) && data["repo"] == "agent-tools"
    rescue Psych::Exception
      false
    end
  end

  # source content から決定的な build_id を作る。status の stale 判定でも使う。
  def self.build_id_for(root, source, format)
    if format == "directory"
      # source.path は末尾スラッシュ付きでも check-manifests を通る (chomp して検証)。
      # 相対 path 計算 (evals 除外) が末尾スラッシュで壊れないよう正規化する。
      src_dir = File.join(root, source).chomp("/")
      digest = Digest::SHA256.new
      Dir.glob(File.join(src_dir, "**/*")).sort.each do |f|
        next unless File.file?(f)
        # copy と同じく、manifest として除外するのは top-level の asset.yml のみ。
        next if f == File.join(src_dir, "asset.yml")
        # 配置されない予約 dir (evals 等) は build_id に含めない。
        # 配置成果物が変わらない eval 編集で stale 扱いにならないようにする (copy と整合)。
        next if ArtifactTargets::SKILL_NON_DEPLOY_DIRS.include?(f.sub("#{src_dir}/", "").split("/").first)

        digest.update(f.sub(src_dir, ""))
        digest.update(File.read(f, mode: "rb"))
      end
      "sha256:#{digest.hexdigest[0, 12]}"
    else
      "sha256:#{Digest::SHA256.hexdigest(File.read(File.join(root, source)))[0, 12]}"
    end
  end

  def self.main(argv)
    root = Dir.pwd
    quiet = false
    prune = false
    until argv.empty?
      case (arg = argv.shift)
      when "--root"
        root = argv.shift or abort_usage
      when "--quiet"
        quiet = true
      when "--prune"
        prune = true
      when "-h", "--help"
        print_usage
        return 0
      else
        warn "unknown option: #{arg}"
        abort_usage
      end
    end

    unless run_gates(root)
      warn "fail: pre-build gates did not pass; nothing was generated"
      return 1
    end

    runner = Runner.new(root)
    built, skipped = runner.run
    built.each { |line| puts "built: #{line}" }
    skipped.each { |line| warn "skipped: #{line}" }
    if prune
      pruned, kept = runner.prune
      pruned.each { |line| puts "pruned: #{line}" }
      kept.each { |line| warn "kept (unmanaged, no agent-tools marker): #{line}" }
    end
    puts "ok: #{built.size} artifact(s) built" unless quiet
    0
  end

  # build 前の必須 gate。register と同じ致命 gate を共有する (Gate.fatal_errors)。
  # medium finding では止めない。生成は中間物で、sync が catalog を見て止める。
  def self.run_gates(root)
    errors = Gate.fatal_errors(root)
    errors.each { |line| warn line }
    errors.empty?
  end

  def self.print_usage
    puts "usage: build.sh [--root DIR] [--prune] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit Build.main(ARGV) if $PROGRAM_NAME == __FILE__
