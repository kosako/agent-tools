#!/usr/bin/env ruby
# frozen_string_literal: true

# Build adapters: shared source assets から tool 別 artifacts を生成する。
# Spec: docs/asset-manifest-schema.md, docs/status-manifest-contract.md,
#       adapters/<tool>/README.md
#
# 外部依存ゼロ、network access なしで実行できること。
# 生成前に manifest validation と static injection check を必ず通す。

require "digest"
require "fileutils"

require_relative "assets"
require_relative "gate"
require_relative "artifact_targets"
require_relative "instruction_marker"
require_relative "plugin_marker"
require_relative "yaml_marker"
require_relative "cli"

module Build
  TOOLS = ArtifactTargets::TOOLS

  # 出力 (generated/ の下) の書き込み先を安全に書き換えられないときの error (#386)。
  # 経路の symlink、単一 file の書き込み先が regular file でない、旧い出力 dir を消しきれない。
  class OutputPathError < StandardError; end

  # root の generated/ から path までの各要素を lstat で順に調べ、symlink があれば
  # OutputPathError で止める。build と register が書き込み・削除の前に呼ぶ (#386)。
  # 設定ミスで出力先が generated/ の外 (tool home など) を指したときに、同名の dir を確かめずに
  # 消して書く事故よけで、攻撃の防御ではない: 同じ user による検査の後の差し替えは扱わない
  # (docs/sync-policy.md の TOCTOU と同じ立場)。root より上の要素は調べない (repo が
  # /var → /private/var のような symlink の下にあってもよい)。途中の要素がまだ無ければ、
  # その先も無いので検査を終える (作るのは呼び出し側の mkdir_p)。
  def self.guard_output_path!(root, path)
    root = File.expand_path(root)
    base = File.join(root, "generated")
    unless path == base || path.start_with?("#{base}/")
      raise ArgumentError, "output path is not under generated/: #{path}"
    end

    current = root
    path[(root.length + 1)..-1].split("/").each do |part|
      current = File.join(current, part)
      begin
        stat = File.lstat(current)
      rescue Errno::ENOENT, Errno::ENOTDIR
        return
      end
      next unless stat.symlink?

      raise OutputPathError,
            "symlink at #{Assets.rel(root, current)} in the output path #{Assets.rel(root, path)}; " \
            "refusing to write or delete through it"
    end
  end

  # 単一 file の書き込み先: guard_output_path! に加えて、leaf が無いか regular file であることを
  # 確かめる。leaf が directory だと FileUtils.cp はその中 (<leaf>/<source の basename>) に書き、
  # 調べた leaf の外へ出るため (#386)。書き込みは検査した leaf そのものに向く。
  def self.guard_output_file!(root, path)
    guard_output_path!(root, path)
    begin
      stat = File.lstat(path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      return
    end
    return if stat.file?

    raise OutputPathError,
          "output path #{Assets.rel(File.expand_path(root), path)} exists and is not a regular file; " \
          "refusing to write through it"
  end

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
      @built = []
      @skipped = []
    end

    def run
      Assets.load_all(@root).each do |asset|
        asset[:targets].each do |tool|
          artifact_kind = ArtifactTargets.resolve(asset, tool)
          # unsupported (agent 等) と、supported でも tool の表 (TOOL_KINDS) に無い組 (plugin →
          # codex 等) は生成しない。後者は check-manifests が gate で止めるので通常は到達しないが、
          # 生成の走査が TOOLS × 全 kind にならないことを Runner 単体でも保証する (#295)。
          unless ArtifactTargets.tool_supports?(tool, artifact_kind)
            @skipped << "#{asset[:manifest_path]}: unsupported artifact_kind " \
                        "#{artifact_kind.inspect} for #{tool}"
            next
          end
          case artifact_kind
          when "skill"
            build_skill(tool, asset)
          when "instruction"
            build_instruction(tool, asset)
          when "script"
            build_script(tool, asset)
          when "plugin"
            build_plugin(tool, asset)
          else
            # TOOL_KINDS に kind を足したのに builder を足し忘れた実装ミス。黙って skip しない。
            raise ArgumentError, "no builder for artifact_kind #{artifact_kind.inspect}"
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
      out_dir = ArtifactTargets.generated_path(@root, tool, name, "skill")

      # rm_rf と mkdir_p の前に経路を調べる。SKILL.md・directory の中身・marker は、旧 dir を
      # 消しきって作り直した空の dir の中に書くので、経路の検査はこの 1 回で足りる (#386)。
      guard(out_dir)
      FileUtils.rm_rf(out_dir)
      # rm_rf は削除の失敗 (書き込み不可の dir など) を握りつぶし、mkdir_p は残った dir を受け入れる。
      # 旧 dir が残ったまま書くと、残った中身 (外への symlink など) を辿りうるので止める (#386)。
      if File.exist?(out_dir)
        raise OutputPathError, "could not remove the old output dir #{rel(out_dir)}; refusing to write into it"
      end
      FileUtils.mkdir_p(out_dir)

      if format == "directory"
        copy_directory_asset(source, out_dir)
      else
        # 単一 file の skill も directory と同じく source を byte のまま配る (承認した bytes = 配る bytes。
        # manifest から frontmatter を生成すると、build_id に入らない内容が配られてしまう。#376)。
        File.binwrite(File.join(out_dir, "SKILL.md"), File.binread(File.join(@root, source)))
      end
      build_id = Build.build_id_for(@root, source, format)

      write_marker(out_dir, name, tool, source, build_id)
      @built << rel(out_dir)
    end

    # instruction asset を tool 別の単一ファイル (claude-code: CLAUDE.md /
    # codex: AGENTS.md) として生成する。所有 marker は HTML コメントで本体に埋める
    # (instruction は単一ファイル所有なので skill の dir sidecar marker が使えない)。
    def build_instruction(tool, asset)
      out = ArtifactTargets.generated_path(@root, tool, asset[:name], "instruction")
      unless out
        @skipped << "#{asset[:manifest_path]}: instruction unsupported for #{tool}"
        return
      end
      source = asset[:source]["path"]
      format = asset[:source]["format"]
      if format == "directory"
        @skipped << "#{asset[:manifest_path]}: instruction must be a single file, not a directory"
        return
      end

      guard_file(out)
      FileUtils.mkdir_p(File.dirname(out))
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

      out = ArtifactTargets.generated_path(@root, tool, name, "script")
      sidecar = ArtifactTargets.sidecar_marker_path(out)
      guard_file(out, sidecar)
      FileUtils.mkdir_p(File.dirname(out))
      FileUtils.cp(File.join(@root, source), out)
      File.chmod(0o755, out) # script は配置先で実行されるため実行可能にする
      build_id = Build.build_id_for(@root, source, format)
      File.write(sidecar, YamlMarker.render(name: name, target: tool, source: source, build_id: build_id))
      @built << rel(out)
    end

    # plugin asset を OpenCode の plugins/<name>.js として生成する。所有 marker は先頭行の JS
    # ブロックコメント (PluginMarker) で本体に埋め、2 行目以降は source の bytes をそのまま保つ
    # (byte 単位で保持し、encoding の変換や改行の正規化をしない)。OpenCode が import して読む
    # file で実行ファイルではないので、実行ビットは立てない (mode 0644)。
    def build_plugin(tool, asset)
      name = asset[:name]
      source = asset[:source]["path"]
      format = asset[:source]["format"]
      if format == "directory"
        @skipped << "#{asset[:manifest_path]}: plugin must be a single .js file, not a directory"
        return
      end

      out = ArtifactTargets.generated_path(@root, tool, name, "plugin")
      guard_file(out)
      FileUtils.mkdir_p(File.dirname(out))
      build_id = Build.build_id_for(@root, source, format)
      marker = PluginMarker.render(name: name, target: tool, source: source, build_id: build_id)
      File.binwrite(out, "#{marker}\n".b + File.binread(File.join(@root, source)))
      File.chmod(0o644, out)
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

    # directory artifact (skill) の管理 marker を dir 直下に書く。
    def write_marker(out_dir, name, tool, source, build_id)
      File.write(File.join(out_dir, ArtifactTargets::MARKER_BASENAME),
                 YamlMarker.render(name: name, target: tool, source: source, build_id: build_id))
    end

    def rel(path)
      Assets.rel(@root, path)
    end

    # 書き込み・削除の前に、出力の経路 (leaf と途中の dir) に symlink が無いことを確かめる。
    # 見つけたら OutputPathError で止め、それ以上書かない (#386)。
    def guard(*paths)
      paths.each { |path| Build.guard_output_path!(@root, path) }
    end

    # 単一 file の書き込みの前に、経路に加えて leaf が無いか regular file であることを確かめる (#386)。
    def guard_file(*paths)
      paths.each { |path| Build.guard_output_file!(@root, path) }
    end

    public

    # 現在の manifests に対応しない generated artifacts を削除する。
    # 削除するのは agent-tools marker を持つものだけ。marker のない directory / file は
    # warning として返し、残す。走査は TOOL_KINDS の組だけを回す (TOOLS × 全 kind ではない, #295)。
    def prune
      expected = expected_names
      pruned = []
      kept = []
      TOOLS.each do |tool|
        ArtifactTargets::TOOL_KINDS.fetch(tool).each do |kind|
          removed, left =
            case kind
            when "skill" then prune_skills(tool, expected[tool][kind])
            when "script" then prune_scripts(tool, expected[tool][kind])
            when "instruction" then prune_instructions(tool, expected[tool][kind])
            when "plugin" then prune_plugins(tool, expected[tool][kind])
            else raise ArgumentError, "no prune for artifact_kind #{kind.inspect}"
            end
          pruned.concat(removed)
          kept.concat(left)
        end
      end
      [pruned, kept]
    end

    private

    # tool × artifact_kind ごとに、現在の manifests が期待する artifact 名。
    # unsupported は build しないので期待リストに入れない。else で skill 扱いすると kind 変更
    # (skill→agent 等) 後の stale な generated/<tool>/skills/<name> が prune 保護されて残ってしまう。
    def expected_names
      expected = Hash.new { |by_tool, tool| by_tool[tool] = Hash.new { |by_kind, kind| by_kind[kind] = [] } }
      Assets.load_all(@root).each do |asset|
        (asset[:targets] || []).each do |tool|
          kind = ArtifactTargets.resolve(asset, tool)
          expected[tool][kind] << asset[:name] if ArtifactTargets.supported?(kind)
        end
      end
      expected
    end

    # skill: manifest に対応しない generated directory を削除する。
    # (skill -> instruction 転換で残った stale skill もここで消える)
    def prune_skills(tool, names)
      pruned = []
      kept = []
      Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "skill"), "*")).sort.each do |dir|
        next unless File.directory?(dir)
        next if names.include?(File.basename(dir))

        if managed_marker?(dir)
          guard(dir)
          FileUtils.rm_rf(dir)
          pruned << rel(dir)
        else
          kept << rel(dir)
        end
      end
      [pruned, kept]
    end

    # script: manifest に対応しない managed script (と sidecar marker) を削除する。
    # sidecar marker file 自体は本体と一緒に処理するため列挙対象から外す。
    def prune_scripts(tool, names)
      pruned = []
      kept = []
      Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "script"), "*")).sort.each do |path|
        next unless File.file?(path)
        next if path.end_with?(ArtifactTargets::MARKER_BASENAME)
        next if names.include?(File.basename(path))

        if script_managed_marker?(path)
          sidecar = ArtifactTargets.sidecar_marker_path(path)
          guard(path, sidecar)
          FileUtils.rm_f(path)
          FileUtils.rm_f(sidecar)
          pruned << rel(path)
        else
          kept << rel(path)
        end
      end
      [pruned, kept]
    end

    # instruction: 期待する canonical ファイル (INSTRUCTION_FILENAMES) 以外の
    # marker 付きファイルを削除する。instruction asset が無ければ canonical も対象。
    def prune_instructions(tool, names)
      pruned = []
      kept = []
      keep = names.empty? ? nil : ArtifactTargets::INSTRUCTION_FILENAMES[tool]
      Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "instruction"), "*")).sort.each do |file|
        next unless File.file?(file)
        next if keep && File.basename(file) == keep

        if InstructionMarker.parse(File.read(file))
          guard(file)
          FileUtils.rm_f(file)
          pruned << rel(file)
        else
          kept << rel(file)
        end
      end
      [pruned, kept]
    end

    # plugin: manifest に対応しない managed plugin を削除する。管理の判定は先頭行の marker
    # (PluginMarker.parse)。marker が無い / 壊れている file は残す。
    def prune_plugins(tool, names)
      pruned = []
      kept = []
      expected_files = names.map { |name| ArtifactTargets.plugin_filename(name) }
      Dir.glob(File.join(ArtifactTargets.generated_dir(@root, tool, "plugin"), "*")).sort.each do |path|
        next unless File.file?(path)
        next if expected_files.include?(File.basename(path))

        if PluginMarker.parse(File.binread(path))
          guard(path)
          FileUtils.rm_f(path)
          pruned << rel(path)
        else
          kept << rel(path)
        end
      end
      [pruned, kept]
    end

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
      marker = YamlMarker.read_file(marker_path)
      !marker.nil? && marker["repo"] == "agent-tools"
    end
  end

  # build_id の digest 入力に最初に混ぜる domain tag。scheme を変えたら v を上げる
  # (全 build_id / 承認が失効し再取得になる)。
  BUILD_ID_DOMAIN = "agent-tools/build_id/v2"

  # source content から決定的な build_id を作る。status の stale 判定でも使う。
  #
  # 形式は full SHA-256 (64 hex, #184)。旧形式 (先頭 12 hex 切り詰め) は外部由来の悪性
  # コンテンツを脅威に置くと衝突探索の余地が大きすぎるため廃止した。digest 入力は
  # domain tag + 経路 tag ("directory" / "file") + length-framed な parts:
  # - 無区切り連結だと「path "/ab" + content "c"」と「path "/a" + content "bc"」のような
  #   異なる tree が同一 digest 入力になる構造的衝突が可能 (#184 回帰テストあり)。
  # - 経路 tag が無いと「directory の framed byte 列」をそのまま本文に持つ単一ファイルが
  #   同じ build_id になり、format を差し替えて旧承認を再利用できる
  #   (#191 レビュー H02-REVIEW-01・cross-format 回帰テストあり)。
  def self.build_id_for(root, source, format)
    digest = Digest::SHA256.new
    digest_framed(digest, BUILD_ID_DOMAIN)
    if format == "directory"
      digest_framed(digest, "directory")
      # source.path は末尾スラッシュ付きでも check-manifests を通る (chomp して検証)。
      # 相対 path 計算 (evals 除外) が末尾スラッシュで壊れないよう正規化する。
      src_dir = File.join(root, source).chomp("/")
      # copy (copy_directory_asset は Dir.children + cp_r で dotfile も配る) と揃えるため
      # FNM_DOTMATCH で dotfile も hash に含める。含めないと dotfile だけ変えた更新が
      # build_id 不変となり sync が up-to-date で skip し、永久に配布されない。
      # FNM_DOTMATCH では `.` 等の dir entry も返りうるが、File.file? が非ファイルを弾く。
      Dir.glob(File.join(src_dir, "**/*"), File::FNM_DOTMATCH).sort.each do |f|
        next unless File.file?(f)
        # copy と同じく、manifest として除外するのは top-level の asset.yml のみ。
        next if f == File.join(src_dir, "asset.yml")
        # 配置されない予約 dir (evals 等) は build_id に含めない。
        # 配置成果物が変わらない eval 編集で stale 扱いにならないようにする (copy と整合)。
        next if ArtifactTargets::SKILL_NON_DEPLOY_DIRS.include?(f.sub("#{src_dir}/", "").split("/").first)

        digest_framed(digest, f.sub(src_dir, ""))
        digest_framed(digest, File.read(f, mode: "rb"))
      end
    else
      # 非 directory format (markdown / yaml / ... / text) は build が同じ単一ファイル
      # 経路で扱うため、経路 tag も共通の "file" (format 文字列の相互差し替えは配布物を
      # 変えず、承認を無駄に失効させない)。
      digest_framed(digest, "file")
      digest_framed(digest, File.read(File.join(root, source), mode: "rb"))
    end
    "sha256:#{digest.hexdigest}"
  end

  # digest に length-framed な part を足す (4-byte big-endian の byte 長 + bytes)。
  # part 境界を digest 入力に固定し、隣接 part 間で bytes を移し替える衝突を塞ぐ。
  def self.digest_framed(digest, part)
    digest.update([part.bytesize].pack("N"))
    digest.update(part)
  end
  private_class_method :digest_framed

  def self.main(argv)
    opts = Cli.parse(argv, usage: USAGE, bool_flags: %w[--quiet --prune], value_flags: %w[--root])
    return 0 if opts == :help

    root = opts["--root"] || Cli::DEFAULT_ROOT
    quiet = opts.key?("--quiet")
    prune = opts.key?("--prune")

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
  rescue OutputPathError => e
    # 書き込み先を安全に書き換えられないときは、それ以上書かずに理由を出して止める (#386)。
    warn "fail: #{e.message}"
    1
  end

  # build 前の必須 gate。register と同じ致命 gate を共有する (Gate.fatal_errors)。
  # medium finding では止めない。生成は中間物で、sync が catalog を見て止める。
  def self.run_gates(root)
    errors = Gate.fatal_errors(root)
    errors.each { |line| warn line }
    errors.empty?
  end

  USAGE = "usage: build.sh [--root DIR] [--prune] [--quiet]"
end

exit Build.main(ARGV) if $PROGRAM_NAME == __FILE__
