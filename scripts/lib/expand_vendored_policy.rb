# frozen_string_literal: true

# vendor する takt の facet の `{{include:<kind>/<name>}}` を展開する (#622)。
# 展開の規則は takt の faceted-prompting の facet-includes に合わせる: token を partial の本文でそのまま置き換え
# (token の前後の文字と改行は残す)、partial の中の include も同じ規則で展開し、循環と見つからない partial は
# error にする。partial は <facets root>/partials/<kind>/<name>.md。scope の参照 (`@…`) は扱わず error にする。
# 取得は呼び出し側が行い (pin を指定した Contents API。docs は policies/NOTICE.md)、この script は network に
# 触れない。
require_relative "cli"

module ExpandVendoredPolicy
  USAGE = <<~TEXT
    usage: expand-vendored-policy.sh --root DIR --facets-root PATH --entry PATH [--check FILE]
      --root DIR          取得した upstream の tree の root
      --facets-root PATH  root からの facets の dir (例: builtins/ja/facets)
      --entry PATH        root からの展開する file (例: builtins/ja/facets/policies/review.md)
      --check FILE        展開の結果を FILE と比べる (一致で exit 0、違えば exit 1)。無ければ stdout に出す
    exit: 0 = ok / 1 = --check の不一致 / 2 = 引数・include の誤り・file を読めない
  TEXT

  # 空白は JavaScript の `\s` と `String#trim` の集合 (WhiteSpace と LineTerminator) に合わせる。Ruby の `\s` は
  # ASCII の空白だけで、全角空白などを含む token を取りこぼす。
  JS_SPACE = "[\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]"
  TOKEN = /\{\{#{JS_SPACE}*include#{JS_SPACE}*:#{JS_SPACE}*([^}]*)\}\}/.freeze
  JS_TRIM = /\A#{JS_SPACE}+|#{JS_SPACE}+\z/.freeze
  KINDS = %w[instructions policies knowledge output-contracts].freeze
  NAME = /\A[A-Za-z0-9._-]+\z/.freeze

  class IncludeError < StandardError; end

  # loader は (kind, name) から [本文, 識別子] を返す。識別子は循環の検出に使う。
  def self.expand(body, loader, stack = [])
    out = +""
    cursor = 0
    body.to_enum(:scan, TOKEN).each do
      m = Regexp.last_match
      kind, name = parse_ref(m[1])
      partial, id = loader.call(kind, name)
      if stack.include?(id)
        raise IncludeError, "cyclic include: #{(stack + [id]).join(' -> ')}"
      end

      out << body[cursor...m.begin(0)] << expand(partial, loader, stack + [id])
      cursor = m.end(0)
    end
    out << body[cursor..]
  end

  def self.parse_ref(raw)
    ref = raw.gsub(JS_TRIM, "")
    kind, sep, name = ref.partition("/")
    unless !sep.empty? && KINDS.include?(kind) && name.match?(NAME)
      raise IncludeError, "invalid include #{ref.inspect}: expected {{include:<kind>/<name>}}"
    end

    [kind, name]
  end

  # root の下の rel が、途中の dir も含めて symlink を通らない regular file か。root そのものは見ない
  # (macOS の一時 dir は /var → /private/var の symlink の下にある)。空・. ・.. の segment も拒む。
  def self.plain_file?(root, rel)
    parts = rel.split("/", -1)
    return false if parts.empty? || parts.any? { |s| s.empty? || s == "." || s == ".." }

    path = root
    parts.each do |s|
      path = File.join(path, s)
      return false if File.symlink?(path)
    end
    File.file?(path)
  end

  def self.file_loader(root, facets_root)
    lambda do |kind, name|
      rel = File.join(facets_root, "partials", kind, "#{name}.md")
      raise IncludeError, "missing include #{kind}/#{name}: #{rel}" unless plain_file?(root, rel)

      [File.read(File.join(root, rel), encoding: "UTF-8"), rel]
    end
  end

  def self.main(argv)
    opts = Cli.parse(argv, usage: USAGE, value_flags: %w[--root --facets-root --entry --check])
    return 0 if opts == :help

    root, facets_root, entry = opts.values_at("--root", "--facets-root", "--entry")
    if [root, facets_root, entry].any?(&:nil?)
      warn USAGE
      return 2
    end
    entry_path = File.join(root, entry)
    unless plain_file?(root, entry)
      warn "expand-vendored-policy: entry is not a regular file: #{entry}"
      return 2
    end

    result = expand(File.read(entry_path, encoding: "UTF-8"), file_loader(root, facets_root), [entry])
    if result.match?(TOKEN)
      warn "expand-vendored-policy: include tokens remain after expansion"
      return 2
    end

    if (check = opts["--check"])
      same = File.file?(check) && File.binread(check) == result.b
      warn(same ? "expand-vendored-policy: ok: #{check} matches" : "expand-vendored-policy: #{check} differs from the expansion")
      return same ? 0 : 1
    end
    $stdout.write(result)
    0
  rescue IncludeError, SystemCallError, ArgumentError => e
    warn "expand-vendored-policy: #{e.message}"
    2
  end
end

exit ExpandVendoredPolicy.main(ARGV) if $PROGRAM_NAME == __FILE__
