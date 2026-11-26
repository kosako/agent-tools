# frozen_string_literal: true

# doctor の body の検査 (#722)。sync と status は、skill・script・plugin の鮮度を管理 marker の build_id だけで
# 決めるので、marker を変えずに body だけが変わっても managed のままになる。ここでは、source から一時 directory に
# 同じ builder で作り直し、配備先の body と比べる。
#
# - 比べるのは、artifact の中の名前の集合、種類 (file・directory・symlink)、file の byte、通常の file の所有者の
#   実行 bit、symlink の行き先の文字列。symlink は辿らない。directory の mode と group・other の bit は umask で
#   変わるので比べない。instruction の所有 file は mode を人の file から引き継ぐ (sync の existing_mode) ので、
#   実行 bit も比べない。
# - 作り直した marker の build_id が配備先の marker と違う (配備の後に source が変わった) とき、作り直しや読み取りに
#   失敗したときは、一致ともずれとも言わず未検査にする。
# - 書くのは、repo・tool home・agents home の外の一時 directory だけで、終わると消す。理由に例外の文言 (path を
#   含みうる) は出さず、class の名前だけを出す。
#
# 同じ OS user による改ざんの防御ではない (doctor を走らせる前に戻せる)。偶発的なずれと取り違えを見つけるための
# 検査。Spec: docs/install-and-usage.md の「状態を見る」、docs/sync-policy.md。

require "etc"
require "fileutils"
require "tmpdir"

require_relative "artifact_targets"
require_relative "build"
require_relative "instruction_marker"
require_relative "local_instructions"
require_relative "plugin_marker"
require_relative "yaml_marker"

module BodyCheck
  # state: :match / :differs / :unverified。detail は表示用の短い理由 (相対 path と違いの種類、または未検査の理由)。
  Result = Struct.new(:state, :detail)

  SOURCE_CHANGED = "source changed since the deployed build"

  module_function

  # plans は sync の plan のうち up-to-date (status の managed) のもの。plan ごとの Result を同じ順で返し、一時
  # directory を消しきれなかったかを 2 つ目の値で返す。avoid は一時 directory を置いてはいけない directory
  # (repo と tool home)。
  def run(root, plans, avoid:, fragment:, env: ENV)
    return [[], false] if plans.empty?

    base = temp_base(avoid, env)
    return [plans.map { unverified("no usable temporary directory") }, false] unless base

    tmp = Dir.mktmpdir("agent-tools-doctor-", base)
    begin
      results =
        begin
          Build::Runner.new(root, out_root: tmp).run
          plans.map { |plan| compare(tmp, plan, fragment) }
        rescue StandardError => e
          # 1 件の失敗で、ほかの target を一致ともずれとも言わない (作り直しは全体で 1 回)。
          plans.map { unverified("could not rebuild (#{e.class})") }
        end
    ensure
      FileUtils.rm_rf(tmp)
    end
    [results, File.exist?(tmp)]
  rescue SystemCallError => e
    [plans.map { unverified("could not use a temporary directory (#{e.class})") }, false]
  end

  # 一時 directory の置き場を選ぶ。Dir.tmpdir は書けない TMPDIR を飛ばして今の directory (.) まで探すので使わない。
  # 候補は TMPDIR、system の一時 directory、/tmp の順で、directory で書け、world-writable なら sticky で、avoid の
  # どれの内側でもないものだけ。無ければ nil (何も書かない)。
  def temp_base(avoid, env)
    avoided = avoid.compact.map { |dir| real_or_expanded(dir) }
    [env["TMPDIR"], Etc.systmpdir, "/tmp"].each do |dir|
      next if dir.nil? || dir.empty?

      real = begin
        File.realpath(dir)
      rescue SystemCallError
        next
      end
      stat = File.stat(real)
      next unless stat.directory? && stat.writable?
      next if stat.world_writable? && !stat.sticky?
      next if avoided.any? { |a| real == a || real.start_with?(File.join(a, "")) }

      return real
    end
    nil
  end

  def real_or_expanded(dir)
    File.realpath(dir)
  rescue SystemCallError
    File.expand_path(dir)
  end

  def compare(tmp, plan, fragment)
    fresh = ArtifactTargets.generated_path(tmp, plan.tool, plan.name, plan.kind)
    case plan.kind
    when "skill" then compare_skill(fresh, plan.target)
    when "script" then compare_script(fresh, plan.target)
    when "plugin" then compare_plugin(fresh, plan.target)
    when "instruction" then compare_instruction(fresh, plan.target, fragment)
    else unverified("no body check for #{plan.kind}")
    end
  rescue StandardError => e
    unverified("could not read (#{e.class})")
  end

  def compare_skill(fresh, target)
    return unverified("no fresh build of this target") unless File.directory?(fresh)

    marker = ArtifactTargets::MARKER_BASENAME
    return unverified(SOURCE_CHANGED) unless same_build?(yaml_build_id(File.join(fresh, marker)), yaml_build_id(File.join(target, marker)))

    diff(tree(fresh), tree(target))
  end

  def compare_script(fresh, target)
    fresh_sidecar = ArtifactTargets.sidecar_marker_path(fresh)
    return unverified("no fresh build of this target") unless File.file?(fresh) && File.file?(fresh_sidecar)

    target_sidecar = ArtifactTargets.sidecar_marker_path(target)
    return unverified(SOURCE_CHANGED) unless same_build?(yaml_build_id(fresh_sidecar), yaml_build_id(target_sidecar))

    names = [File.basename(target), File.basename(target_sidecar)]
    diff(entries(names.zip([fresh, fresh_sidecar])), entries(names.zip([target, target_sidecar])))
  end

  def compare_plugin(fresh, target)
    return unverified("no fresh build of this target") unless File.file?(fresh)
    unless same_build?(PluginMarker.parse(File.binread(fresh))&.fetch("build_id", nil),
                       PluginMarker.parse(File.binread(target))&.fetch("build_id", nil))
      return unverified(SOURCE_CHANGED)
    end

    name = File.basename(target)
    diff(entries([[name, fresh]]), entries([[name, target]]))
  end

  # instruction は、作り直した本文に今の local の断片を足したものと byte で比べる (#689 の断片は正当な違い)。
  def compare_instruction(fresh, target, fragment)
    return unverified("no fresh build of this target") unless File.file?(fresh)
    return unverified(SOURCE_CHANGED) unless same_build?(instruction_build_id(fresh), instruction_build_id(target))

    name = File.basename(target)
    expected = { name => [:file, LocalInstructions.deployed_content(File.binread(fresh), fragment)] }
    actual = { name => File.lstat(target).file? ? [:file, File.binread(target)] : [kind_of(File.lstat(target))] }
    diff(expected, actual)
  end

  # 作り直した marker の build_id が読めて、配備先の marker と同じか。
  def same_build?(fresh_id, target_id)
    !fresh_id.nil? && fresh_id == target_id
  end

  def yaml_build_id(path)
    YamlMarker.read_file(path)&.fetch("build_id", nil)
  end

  def instruction_build_id(path)
    InstructionMarker.parse(File.read(path).scrub("\u{FFFD}"))&.fetch("build_id", nil)
  end

  # directory の中の木を、相対 path → entry の hash にする。symlink は辿らない。
  def tree(dir, prefix = nil, out = {})
    Dir.children(dir).sort.each do |child|
      rel = prefix ? "#{prefix}/#{child}" : child
      path = File.join(dir, child)
      out[rel] = entry(path)
      tree(path, rel, out) if out[rel].first == :dir
    end
    out
  end

  # 単一 file の artifact を [[表示名, path], ...] から hash にする。
  def entries(pairs)
    pairs.each_with_object({}) { |(name, path), out| out[name] = File.exist?(path) || File.symlink?(path) ? entry(path) : nil }
         .compact
  end

  def entry(path)
    stat = File.lstat(path)
    case kind_of(stat)
    when :file then [:file, File.binread(path), (stat.mode & 0o100) != 0]
    when :link then [:link, File.readlink(path)]
    else [kind_of(stat)]
    end
  end

  def kind_of(stat)
    if stat.symlink? then :link
    elsif stat.file? then :file
    elsif stat.directory? then :dir
    else :other
    end
  end

  # 期待 (作り直し) と配備先を比べ、最初の違いを 1 つ返す。違いが無ければ一致。
  def diff(expected, actual)
    (expected.keys | actual.keys).sort.each do |rel|
      want = expected[rel]
      got = actual[rel]
      next if want == got

      what =
        if got.nil? then "missing"
        elsif want.nil? then "extra"
        elsif want.first != got.first then "type"
        elsif want.first == :link then "link target"
        elsif want[1] != got[1] then "content"
        else "exec bit"
        end
      return Result.new(:differs, "#{display(rel)}: #{what}")
    end
    Result.new(:match, nil)
  end

  # 相対 path を 1 行で表示する。UTF-8 として読めないか制御文字を含むときは escape する。
  def display(rel)
    text = rel.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? && !text.match?(/[[:cntrl:]]/) ? text : text.dump
  end

  def unverified(reason)
    Result.new(:unverified, reason)
  end
end
