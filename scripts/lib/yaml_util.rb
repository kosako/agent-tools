# frozen_string_literal: true

require "yaml"

# psych 3 (positional args) と psych 4 (keyword args) の両方で動く safe_load。
#
# manifest と skill の frontmatter は、ここを通して「YAML stream の中の 1 文書で、明示の tag と merge key
# (`<<`) を使わず、どの mapping でも書かれた key が load 後に衝突しない」ものだけを読む (#427 の 4)。
# safe_load は stream の最初の文書だけを返し、重複 key は後の値で黙って上書きし、tag 付きの key
# (`!!binary bmFtZQ==` = name) と merge key (`<<: {name: x}`) も同じ key を上書きできるので、そのまま読むと
# 2 文書目の key や、重複した key・衝突する key の先の値が allowlist と name の照合をすり抜ける。
# 配布先の parser がこれらをどう読むかは確かめていないので、validator の側で形を 1 つに限る。
# frontmatter は、開始 marker を剥がした後に明示の marker (`---` / `...`) が残る形も拒む
# (`load_frontmatter`)。manifest は `YAML.dump` が付ける先頭の `---` を許す。
module YamlUtil
  # 構造の違反 (複数文書 / 明示の marker / tag / merge key / 重複・衝突する key)。Psych::Exception の
  # 仲間にして、呼び出し側の既存の rescue (YAML を読めない = fail-closed) に乗せる。
  class DocumentError < Psych::Exception; end

  # manifest 用: 1 文書・tag なし・merge key なし・key の衝突なし。
  def self.load(content, path)
    data = safe_load(content, path)
    check_document!(content, data, path, allow_markers: true)
    data
  end

  # skill の frontmatter 用: 上に加えて、明示の document marker と、値の後の同じ行の YAML のコメントを拒む。
  def self.load_frontmatter(content, path)
    data = safe_load(content, path)
    document = check_document!(content, data, path, allow_markers: false)
    check_trailing_comments!(document.root, content, path)
    data
  end

  # 値の後に、同じ行で YAML のコメントが続く形を拒む (#417)。引用符の無い plain scalar では、空白の後の `#` からが
  # コメントになり、値がそこで黙って切れる (「packet #N」を含む description が `「packet` で切れ、配布先の skill の
  # 一覧にも切れたまま載った)。引用符で囲んだ値と flow の collection (`[a]` / `{a: b}`) の後のコメントも、同じ形
  # なので拒む。block scalar (`>` / `|`) は中の `#` も値の一部で切れず、終わりの位置が次の行の先頭になる (その行の
  # 行全体のコメントを後ろのコメントと取り違える) ので見ない。block の collection は終わりの位置が同じく次の行に
  # なるので、中の値をたどる。flow の collection は終わり (`]` / `}`) の後ろを見たうえで、中の値もたどる (frontmatter
  # 全体を flow の mapping で書くと、中の plain な値が切れうる)。行全体のコメントは値を切らないので見ない。Psych の
  # column は文字の単位なので、行は UTF-8 として切る (C locale で読んだ US-ASCII の文字列を byte の単位で切らない)。
  def self.check_trailing_comments!(root, content, path)
    lines = content.dup.force_encoding(Encoding::UTF_8).lines
    each_inline_value(root) do |node|
      rest = lines[node.end_line].to_s.chomp[node.end_column..].to_s
      next unless rest.lstrip.start_with?("#")

      column = node.end_column + (rest.size - rest.lstrip.size) + 1
      raise DocumentError, "(#{path}): a YAML comment follows the value at line #{node.end_line + 1} column " \
                           "#{column}; the text after ` #` is dropped from a plain value (quote the value or " \
                           "remove the comment)"
    end
  end

  BLOCK_SCALAR_STYLES = [Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED].freeze

  # 終わりの位置が値の直後になる node (block scalar 以外の scalar、flow の collection) を渡す。collection は、block でも
  # flow でも中の値 (mapping は値の側。key は見ない) をたどる。
  def self.each_inline_value(node, &block)
    case node
    when Psych::Nodes::Scalar
      yield node unless BLOCK_SCALAR_STYLES.include?(node.style)
    when Psych::Nodes::Mapping
      yield node if node.style == Psych::Nodes::Mapping::FLOW
      node.children.each_slice(2) { |_key, child| each_inline_value(child, &block) }
    when Psych::Nodes::Sequence
      yield node if node.style == Psych::Nodes::Sequence::FLOW
      node.children.each { |child| each_inline_value(child, &block) }
    end
  end

  def self.safe_load(content, path)
    if Psych::VERSION.split(".").first.to_i >= 4
      YAML.safe_load(content, filename: path)
    else
      YAML.safe_load(content, [], [], false, path)
    end
  end

  # 構文 error と alias は safe_load が path 入りの message で先に出すので、ここは構文が通った stream だけを
  # 見る。data は同じ content を safe_load した値で、node の木と並べて辿る。検査した文書 (node) を返す。
  def self.check_document!(content, data, path, allow_markers:)
    documents = Psych.parse_stream(content, filename: path).children
    unless documents.size == 1
      raise DocumentError, "(#{path}): must contain exactly one YAML document, got #{documents.size}"
    end

    document = documents.first
    unless allow_markers || (document.implicit && document.implicit_end)
      raise DocumentError, "(#{path}): explicit document markers (--- / ...) are not allowed"
    end

    check_tree!(document.root, data, path)
    document
  end

  # node の木と load 後の値を並べて辿る。
  # - 明示の tag (`!!binary` / `!!omap` / `!!str` / `!ruby/...` など) はどこにあっても拒む。tag は key を
  #   別の文字列に解決する (binary) か、構造を変える (omap) ので、書かれた key と load 後の key が食い違う。
  # - mapping の key は plain な scalar に限り、merge key `<<` は拒む (alias が無くても `<<: {k: v}` で
  #   先の k を上書きする)。
  # - 書かれた key の文字列の重複 (行番号つき) と、plain scalar の解決後の衝突 (`true` と `yes` など) を、
  #   書かれた pair の数と load 後の Hash の size の差で拒む。
  def self.check_tree!(node, value, path)
    if node.tag
      raise DocumentError, "(#{path}): explicit tags are not allowed (#{node.tag}) #{at(node)}"
    end

    case node
    when Psych::Nodes::Mapping
      pairs = node.children.each_slice(2).to_a
      seen = {}
      pairs.each do |key, _child|
        unless key.is_a?(Psych::Nodes::Scalar)
          raise DocumentError, "(#{path}): mapping keys must be plain scalars #{at(key)}"
        end
        if key.tag
          raise DocumentError, "(#{path}): explicit tags are not allowed (#{key.tag}) #{at(key)}"
        end
        if key.value == "<<"
          raise DocumentError, "(#{path}): merge keys (<<) are not allowed #{at(key)}"
        end
        if seen.key?(key.value)
          raise DocumentError, "(#{path}): duplicate key #{key.value.inspect} #{at(key)}"
        end
        seen[key.value] = true
      end
      unless value.is_a?(Hash) && value.size == pairs.size
        loaded = value.is_a?(Hash) ? value.size : 0
        raise DocumentError, "(#{path}): mapping keys collide after YAML resolution " \
                             "(#{pairs.size} written, #{loaded} loaded) #{at(node)}"
      end
      # 衝突が無いので、load 後の値は書かれた順に並ぶ (Hash は挿入順)。
      pairs.each_with_index { |(_key, child), i| check_tree!(child, value.values[i], path) }
    when Psych::Nodes::Sequence
      unless value.is_a?(Array) && value.size == node.children.size
        raise DocumentError, "(#{path}): sequence does not load as written #{at(node)}"
      end
      node.children.each_with_index { |child, i| check_tree!(child, value[i], path) }
    when Psych::Nodes::Alias
      # safe_load が先に拒む (BadAlias)。到達したら fail-closed。
      raise DocumentError, "(#{path}): aliases are not allowed #{at(node)}"
    end
  end

  def self.at(node)
    "at line #{node.start_line + 1} column #{node.start_column + 1}"
  end
end
