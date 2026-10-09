# frozen_string_literal: true

require "yaml"

# psych 3 (positional args) と psych 4 (keyword args) の両方で動く safe_load。
#
# manifest と skill の frontmatter は、ここを通して「YAML stream の中の 1 文書で、どの mapping にも
# 重複 key が無い」ものだけを読む (#427 の 4)。safe_load は stream の最初の文書だけを返し、重複 key は
# 後の値で黙って上書きするので、2 文書目の key や重複した key の先の値が、allowlist と name の照合を
# すり抜けていた。配布先の parser がこれらをどう読むかは確かめていないので、validator の側で形を
# 1 つに限る。frontmatter は、開始 marker を剥がした後に明示の marker (`---` / `...`) が残る形も拒む
# (`load_frontmatter`)。manifest は `YAML.dump` が付ける先頭の `---` を許す。
module YamlUtil
  # 構造の違反 (複数文書 / 明示の marker / 重複 key)。Psych::Exception の仲間にして、呼び出し側の
  # 既存の rescue (YAML を読めない = fail-closed) に乗せる。
  class DocumentError < Psych::Exception; end

  # manifest 用: 1 文書・重複 key なし。
  def self.load(content, path)
    data = safe_load(content, path)
    check_document!(content, path, allow_markers: true)
    data
  end

  # skill の frontmatter 用: 1 文書・重複 key なしに加え、明示の document marker を拒む。
  def self.load_frontmatter(content, path)
    data = safe_load(content, path)
    check_document!(content, path, allow_markers: false)
    data
  end

  def self.safe_load(content, path)
    if Psych::VERSION.split(".").first.to_i >= 4
      YAML.safe_load(content, filename: path)
    else
      YAML.safe_load(content, [], [], false, path)
    end
  end

  # 構文 error は safe_load が path 入りの message で先に出すので、ここは構文が通った stream だけを見る。
  def self.check_document!(content, path, allow_markers:)
    documents = Psych.parse_stream(content, filename: path).children
    unless documents.size == 1
      raise DocumentError, "(#{path}): must contain exactly one YAML document, got #{documents.size}"
    end

    document = documents.first
    unless allow_markers || (document.implicit && document.implicit_end)
      raise DocumentError, "(#{path}): explicit document markers (--- / ...) are not allowed"
    end

    check_duplicate_keys!(document.root, path)
  end

  # mapping の key は Scalar の値で比べる (入れ子の mapping と sequence の中も辿る)。
  def self.check_duplicate_keys!(node, path)
    case node
    when Psych::Nodes::Mapping
      seen = {}
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar)
          if seen.key?(key.value)
            raise DocumentError, "(#{path}): duplicate key #{key.value.inspect} " \
                                 "at line #{key.start_line + 1} column #{key.start_column + 1}"
          end
          seen[key.value] = true
        end
        check_duplicate_keys!(key, path)
        check_duplicate_keys!(value, path)
      end
    when Psych::Nodes::Sequence
      node.children.each { |child| check_duplicate_keys!(child, path) }
    end
  end
end
