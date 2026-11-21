# frozen_string_literal: true

# skill の挙動の評価 (#369) の case set の読み取りと検査。probe (probe_skill_behavior.rb) と judge が共有する。
# Spec: docs/skill-behavior-eval.md。
#
# case は 1 回の user の依頼と、その run で求める / 禁じる操作の区分、到達の条件 (reach)、run の後に変わってよい
# file (allowed_changes)、temp project に置く skill (place_skills) を持つ。形が違えば、run を始める前に止める (Error)。

require "json"

module SkillBehaviorCases
  class Error < StandardError; end

  CASES_SCHEMA_VERSION = 1
  # 操作の区分。exec は file の program (test・script) の実行、unknown は分類器が決められなかった呼び出しで、
  # read と合わせて case の forbid / require には書けない。
  CLASSES = %w[read exec file-write github-write git-write agent-launch unknown].freeze
  EXPECTABLE_CLASSES = (CLASSES - %w[read exec unknown]).freeze
  KINDS = %w[negative positive ambiguous].freeze
  CASE_KEYS = %w[id prompt skill kind pair fixture reach forbid require allowed_changes place_skills].freeze
  ID_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/.freeze
  # results.json の variant (probe の --variant)。出力に写すので、決まった文字だけにする。
  LABEL_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/.freeze

  # 誤りの文には、決まった形の値 (欄の名前・case の id・閉じた区分) と数だけを写し、入力の値を写さない (#369)。
  # 判定の出力は PR などに写すことがあるため。未知の key は名前を出さず、数だけを出す。

  # JSON の text を UTF-8 として確かめて読み、読んだ後の文字列 (key を含む) も確かめる。Ruby 2.6 の JSON 2.1.0 は、
  # 文字列の中の不正な byte をそのまま通し、孤立した下位の surrogate の escape (\udc00〜\udfff) も不正な UTF-8 の
  # 文字列に展開する (上位の \ud800 だけなら構文の誤り)。どちらも後段の正規表現が ArgumentError を投げるので、ここで止める。
  def self.parse_json(text, label)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise Error, "#{label}: not valid UTF-8" unless text.valid_encoding?

    data = JSON.parse(text)
    raise Error, "#{label}: not valid UTF-8" unless valid_strings?(data)

    data
  rescue JSON::ParserError
    raise Error, "#{label}: not valid JSON"
  end

  def self.valid_strings?(value)
    case value
    when String then value.valid_encoding?
    when Array then value.all? { |v| valid_strings?(v) }
    when Hash then value.all? { |k, v| valid_strings?(k) && valid_strings?(v) }
    else true
    end
  end

  def self.unknown_keys_message(label, keys, what = "key")
    "#{label}: #{keys.length} unknown #{what}(s)"
  end

  # text を読み、検査した case の配列を返す。fixtures_root があれば、fixture の dir と reach の path の在否も確かめる。
  def self.parse(text, fixtures_root: nil)
    data = parse_json(text, "cases")
    raise Error, "cases: top-level must be an object" unless data.is_a?(Hash)

    unknown = data.keys - %w[schema_version cases]
    raise Error, unknown_keys_message("cases", unknown, "top-level key") unless unknown.empty?
    unless data["schema_version"] == CASES_SCHEMA_VERSION
      raise Error, "cases: schema_version must be #{CASES_SCHEMA_VERSION}"
    end

    cases = data["cases"]
    raise Error, "cases: cases must be a non-empty array" unless cases.is_a?(Array) && !cases.empty?

    seen = {}
    cases.each_with_index do |c, i|
      validate_case!(c, i, fixtures_root)
      raise Error, "cases[#{i}]: duplicate id #{c['id']}" if seen[c["id"]]

      seen[c["id"]] = true
    end
    cases
  end

  def self.validate_case!(c, i, fixtures_root)
    label = "cases[#{i}]"
    raise Error, "#{label}: must be an object" unless c.is_a?(Hash)

    missing = CASE_KEYS - c.keys
    extra = c.keys - CASE_KEYS
    raise Error, "#{label}: missing key(s): #{missing.join(', ')}" unless missing.empty?
    raise Error, unknown_keys_message(label, extra) unless extra.empty?

    %w[id pair fixture].each do |k|
      raise Error, "#{label}: #{k} must match #{ID_PATTERN.source}" unless c[k].is_a?(String) && c[k].match?(ID_PATTERN)
    end
    label = "cases[#{i}](id=#{c['id']})"
    %w[prompt skill].each do |k|
      raise Error, "#{label}: #{k} must be a non-empty string" unless c[k].is_a?(String) && !c[k].strip.empty?
    end
    # prompt は argv / stdin で渡すが、先頭の '-' は CLI に option と読まれうるので弾く。
    raise Error, "#{label}: prompt must not start with '-'" if c["prompt"].start_with?("-")
    raise Error, "#{label}: kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(c["kind"])

    %w[forbid require].each do |k|
      v = c[k]
      unless v.is_a?(Array) && v.all? { |x| EXPECTABLE_CLASSES.include?(x) } && v.uniq.length == v.length
        raise Error, "#{label}: #{k} must be an array of distinct classes from #{EXPECTABLE_CLASSES.join(', ')}"
      end
    end
    overlap = c["forbid"] & c["require"]
    raise Error, "#{label}: forbid and require overlap: #{overlap.join(', ')}" unless overlap.empty?
    if c["kind"] == "positive"
      raise Error, "#{label}: a positive case must require at least one class" if c["require"].empty?
    else
      raise Error, "#{label}: a #{c['kind']} case must not require a class" unless c["require"].empty?
      raise Error, "#{label}: a #{c['kind']} case must forbid at least one class" if c["forbid"].empty?
    end

    %w[reach allowed_changes].each do |k|
      v = c[k]
      unless v.is_a?(Array) && v.all? { |p| relative_path?(p) } && v.uniq.length == v.length
        raise Error, "#{label}: #{k} must be an array of distinct relative paths (no '..', no leading '/')"
      end
    end
    raise Error, "#{label}: reach must not be empty" if c["reach"].empty?
    # temp project に置く skill (#737)。名前は skill の dir の名前なので、決まった形だけにする (path の区切りや .. を持たない)。
    # その case の skill を必ず含める (置かない skill の挙動を測ることにならないため)。
    v = c["place_skills"]
    unless v.is_a?(Array) && !v.empty? && v.all? { |n| n.is_a?(String) && n.match?(ID_PATTERN) } && v.uniq.length == v.length
      raise Error, "#{label}: place_skills must be a non-empty array of distinct skill names matching #{ID_PATTERN.source}"
    end
    raise Error, "#{label}: place_skills must include the skill" unless v.include?(c["skill"])
    if c["kind"] == "positive" && c["allowed_changes"].empty?
      raise Error, "#{label}: a positive case must allow at least one change"
    end

    return unless fixtures_root

    dir = File.join(fixtures_root, c["fixture"])
    raise Error, "#{label}: fixture not found: #{c['fixture']}" unless File.directory?(dir) && !File.symlink?(dir)

    assert_no_symlinks!(dir, "#{label}: fixture")

    c["reach"].each do |p|
      raise Error, "#{label}: reach path not in fixture #{c['fixture']}: #{p}" unless File.file?(File.join(dir, p))
    end
  end

  # dir の下 (隠し file を含む) に symlink があれば止める。fixture と skill の dir は、link を含まない形でだけ copy する。
  def self.assert_no_symlinks!(dir, label)
    raise Error, "#{label} is a symlink: #{File.basename(dir)}" if File.symlink?(dir)

    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).each do |rel|
      next if rel.split("/").any? { |seg| seg == "." || seg == ".." }
      raise Error, "#{label} contains a symlink: #{rel}" if File.symlink?(File.join(dir, rel))
    end
  end

  # fixture の中の相対 path (空の要素・'.'・'..'・先頭の '/'・制御文字を含まない)。
  def self.relative_path?(p)
    return false unless p.is_a?(String) && !p.empty? && !p.start_with?("/") && !p.match?(/[[:cntrl:]]/)

    p.split("/", -1).none? { |seg| seg.empty? || seg == "." || seg == ".." }
  end
end
