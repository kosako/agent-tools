#!/usr/bin/env ruby
# frozen_string_literal: true

# directory skill の evals/evals.json の形式検査 (#216)。
# Spec: docs/asset-manifest-schema.md「evals の形式 (evals/evals.json)」。
#
# 外部依存ゼロ、network access なし。実モデルは呼ばない (実モデルの評価と timeout / refusal の
# 扱いは #369)。検査するのは構造 (必須 field・型・空・id の一意性・skill との対応・files の置き場所)
# だけで、case が十分か・assertion の文が正しいかという意味的な完全性は保証しない。
#
# evals.json は任意 (無いことは error にしない)。Gate.fatal_errors / CheckManifests には組み込まず、
# CI では scripts/tests/check-evals-test.sh が実 repo の tree をこの検査に通す。
#
# 診断は `<file>[:<case>][:<field>]: <message>` の line 単位。<case> は `evals[<index>]` に、id が
# 正しければ `(id=<id>)` を添える。すべての error を集めてから出し、error があれば exit 1。

require "json"

require_relative "yaml_util"
require_relative "cli"

module CheckEvals
  # 置き場所: directory asset の evals/evals.json だけ。単一 file の asset には置き場が無い。
  EVALS_GLOB = "shared/**/evals/evals.json"
  TOP_REQUIRED = %w[skill_name evals].freeze
  TOP_OPTIONAL = %w[notes].freeze
  CASE_REQUIRED = %w[id prompt expected_output assertions].freeze
  CASE_OPTIONAL = %w[name files].freeze
  ASSERTION_FIELDS = %w[id text].freeze
  # assertion の id は lower kebab-case (asset name と同じ形)。
  SLUG_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
  # 未知 field のうち、置き換え先が決まっているものに添える案内。
  FIELD_HINTS = {
    "expectations" => "skill-creator's expectations; this repo uses assertions with id and text",
  }.freeze
  JSON_ERROR_MAX = 160

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
      @errors = []
      @case_count = 0
    end

    # [検査した evals.json の数, case の数, error の行] を返す。
    def run
      # shared/ の無い root で「0 件 ok」と緑にしない (--root の取り違えを見逃さない。Gate と同じ文言)。
      unless File.directory?(File.join(@root, "shared"))
        @errors << "no shared/ directory under root: #{@root} (not an agent-tools repository; check --root)"
        return [0, 0, @errors]
      end
      # base: で root を glob の pattern から外す (root の path に [ や * があっても誤解釈しない)。
      files = Dir.glob(EVALS_GLOB, base: @root).sort
      files.each { |path| check_file(path) }
      [files.size, @case_count, @errors]
    end

    private

    def error(where, message)
      @errors << "#{where}: #{message}"
    end

    def check_file(path)
      # glob の literal な component (shared / evals) は symlink を辿りうるので、root からの各段を
      # lstat し、symlink を含む path は読まない (repo の外を読まない)。
      problem, segment = walk(@root, path.split("/"))
      if problem == :symlink
        error(path, "must not be or go through a symlink: #{segment}")
        return
      end
      full = File.join(@root, path)
      unless File.file?(full)
        error(path, "must be a regular file")
        return
      end

      skill_dir = File.dirname(File.dirname(path))
      manifest_name = read_manifest_name(path, skill_dir)

      content = File.binread(full).force_encoding(Encoding::UTF_8)
      unless content.valid_encoding?
        error(path, "must be valid UTF-8")
        return
      end
      data = begin
        JSON.parse(content)
      rescue JSON::ParserError => e
        error(path, "invalid JSON: #{e.message.lines.first.to_s.strip[0, JSON_ERROR_MAX]}")
        return
      end
      unless data.is_a?(Hash)
        error(path, "top-level must be a JSON object")
        return
      end

      check_unknown(path, data, TOP_REQUIRED + TOP_OPTIONAL)
      check_skill_name(path, data, skill_dir, manifest_name)
      if data.key?("notes") && !data["notes"].is_a?(String)
        error("#{path}:notes", "must be a string")
      end
      check_cases(path, skill_dir, data)
    end

    # skill の directory の asset.yml から name を読む。読めなければ error を足して nil を返す
    # (nil のときは asset.yml との照合を飛ばす。manifest 自体の不正は check-manifests が報告する)。
    def read_manifest_name(path, skill_dir)
      manifest = File.join(skill_dir, "asset.yml")
      full = File.join(@root, manifest)
      if File.symlink?(full)
        error(path, "#{manifest} must not be a symlink")
        return nil
      end
      unless File.file?(full)
        error(path, "no asset.yml in #{skill_dir}; evals.json must sit in a directory asset's evals/")
        return nil
      end
      data = begin
        YamlUtil.load(File.read(full), manifest)
      rescue Psych::Exception
        nil
      end
      name = data.is_a?(Hash) ? data["name"] : nil
      unless name.is_a?(String)
        error("#{path}:skill_name", "cannot read name from #{manifest}")
        return nil
      end
      name
    end

    def check_skill_name(path, data, skill_dir, manifest_name)
      where = "#{path}:skill_name"
      unless data.key?("skill_name")
        error(where, "missing required field")
        return
      end
      value = data["skill_name"]
      unless non_empty_string?(value)
        error(where, "must be a non-empty string")
        return
      end
      dir_name = File.basename(skill_dir)
      if value != dir_name
        error(where, "#{value.inspect} does not match the skill directory name #{dir_name.inspect}")
      end
      if manifest_name && value != manifest_name
        error(where, "#{value.inspect} does not match asset.yml name #{manifest_name.inspect}")
      end
    end

    def check_cases(path, skill_dir, data)
      unless data.key?("evals")
        error("#{path}:evals", "missing required field")
        return
      end
      cases = data["evals"]
      unless cases.is_a?(Array) && !cases.empty?
        error("#{path}:evals", "must be a non-empty array")
        return
      end

      @case_count += cases.size
      first_index_by_id = {}
      cases.each_with_index do |c, index|
        unless c.is_a?(Hash)
          error("#{path}:evals[#{index}]", "must be a JSON object")
          next
        end
        id = c["id"]
        valid_id = case_id?(id)
        where = valid_id ? "#{path}:evals[#{index}](id=#{id})" : "#{path}:evals[#{index}]"

        check_unknown(where, c, CASE_REQUIRED + CASE_OPTIONAL)
        if !c.key?("id")
          error("#{where}:id", "missing required field")
        elsif !valid_id
          error("#{where}:id", "must be a non-negative integer")
        elsif first_index_by_id.key?(id)
          error("#{where}:id", "duplicate case id #{id} (also at evals[#{first_index_by_id[id]}])")
        else
          first_index_by_id[id] = index
        end
        %w[prompt expected_output].each do |key|
          if !c.key?(key)
            error("#{where}:#{key}", "missing required field")
          elsif !non_empty_string?(c[key])
            error("#{where}:#{key}", "must be a non-empty string")
          end
        end
        error("#{where}:name", "must be a string") if c.key?("name") && !c["name"].is_a?(String)
        check_files(where, skill_dir, c["files"]) if c.key?("files")
        check_assertions(where, c)
      end
    end

    # files の各要素は skill の directory からの相対 path。外へ出ず (.. を含まない)、存在し、
    # symlink を経由しない regular file に限る。symlink の先は読まない。
    def check_files(where, skill_dir, files)
      unless files.is_a?(Array)
        error("#{where}:files", "must be an array")
        return
      end
      files.each_with_index do |file, index|
        at = "#{where}:files[#{index}]"
        unless non_empty_string?(file) && !file.include?("\0")
          error(at, "must be a non-empty string")
          next
        end
        if file.start_with?("/")
          error(at, "must be relative to the skill directory, got #{file.inspect}")
          next
        end
        parts = file.split("/", -1)
        if parts.include?("..")
          error(at, "must not leave the skill directory (.. segment), got #{file.inspect}")
          next
        end
        if parts.any? { |part| part.empty? || part == "." }
          error(at, "must be a normalized path (no empty or . segments), got #{file.inspect}")
          next
        end

        base = File.join(@root, skill_dir)
        problem, segment = walk(base, parts)
        if problem == :missing
          error(at, "does not exist: #{file}")
        elsif problem == :symlink
          error(at, "must not be or go through a symlink: #{segment}")
        elsif !File.file?(File.join(base, file))
          error(at, "must be a regular file: #{file}")
        end
      end
    end

    def check_assertions(where, c)
      unless c.key?("assertions")
        error("#{where}:assertions", "missing required field")
        return
      end
      assertions = c["assertions"]
      unless assertions.is_a?(Array) && !assertions.empty?
        error("#{where}:assertions", "must be a non-empty array")
        return
      end

      # assertion の id の一意性は case の中だけ (case をまたいだ同じ id は許す)。
      first_index_by_id = {}
      assertions.each_with_index do |a, index|
        at = "#{where}:assertions[#{index}]"
        unless a.is_a?(Hash)
          error(at, "must be a JSON object")
          next
        end
        check_unknown(at, a, ASSERTION_FIELDS, separator: ".")
        id = a["id"]
        if !a.key?("id")
          error("#{at}.id", "missing required field")
        elsif !(id.is_a?(String) && id.match?(SLUG_PATTERN))
          error("#{at}.id", "must be a lower kebab-case slug, got #{id.inspect}")
        elsif first_index_by_id.key?(id)
          error("#{at}.id", "duplicate assertion id #{id.inspect} in this case (also at assertions[#{first_index_by_id[id]}])")
        else
          first_index_by_id[id] = index
        end
        if !a.key?("text")
          error("#{at}.text", "missing required field")
        elsif !non_empty_string?(a["text"])
          error("#{at}.text", "must be a non-empty string")
        end
      end
    end

    # 未知の field を error にする (typo や skill-creator の別 schema を黙って通さない)。
    def check_unknown(where, hash, known, separator: ":")
      (hash.keys - known).each do |key|
        hint = FIELD_HINTS[key]
        message = hint ? "unknown field (#{hint})" : "unknown field"
        error("#{where}#{separator}#{key}", message)
      end
    end

    # base から parts を 1 段ずつ lstat で辿る。最初に symlink の段があれば [:symlink, 段]、
    # 存在しない段があれば [:missing, 段] (段は base からの相対 path)、どちらも無ければ nil。
    # symlink の先は辿らない。
    def walk(base, parts)
      current = base
      parts.each_with_index do |part, index|
        current = File.join(current, part)
        stat = begin
          File.lstat(current)
        rescue SystemCallError
          nil
        end
        return [:missing, parts[0..index].join("/")] if stat.nil?
        return [:symlink, parts[0..index].join("/")] if stat.symlink?
      end
      nil
    end

    def case_id?(value)
      value.is_a?(Integer) && value >= 0
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end
  end

  def self.main(argv)
    opts = Cli.parse(argv, usage: USAGE, bool_flags: %w[--quiet], value_flags: %w[--root])
    return 0 if opts == :help

    root = opts["--root"] || Cli::DEFAULT_ROOT
    quiet = opts.key?("--quiet")

    files, cases, errors = Runner.new(root).run
    errors.each { |line| puts line }
    if errors.empty?
      puts "ok: #{files} evals file(s), #{cases} case(s) validated" unless quiet
      0
    else
      warn "#{errors.size} error(s) in #{files} evals file(s)"
      1
    end
  end

  USAGE = "usage: ruby scripts/lib/check_evals.rb [--root DIR] [--quiet]"
end

exit CheckEvals.main(ARGV) if $PROGRAM_NAME == __FILE__
