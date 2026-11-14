# scripts/tests/*-wiring-test.sh が共有する、Markdown の文書を単位に分ける helper (#676)。
# suite 側から
#   ruby -r"$script_dir/lib/markdown_units" - ... <<'RUBY'
# で読み込む。文言の検知のための最小の読み方で、Markdown の parser ではない。行ごとに読み、複数行にまたがる正規表現で
# block を切り出さない。
#
# 受ける整形 (これが契約。ここに無い書き方は受けない。たとえば `~~~` の fence、`*` や番号の list、4 つ以上の backtick の
# fence、全角の空白での字下げ):
# - 見出し: 行の頭の `#` の並びと、その後ろの空白か tab が 1 つ以上。照合は空白を除いて比べる (`###  2.` も `### 2.` と同じ)。
#   level は `#` の数。fence の中の行は見出しとみなさない。
# - fence: 行の頭 (空白か tab の字下げは可) の ``` で始まり、次の ``` で始まる行で終わる。info string (`sh` など) は、
#   始まりの行の ``` の後ろ (前後の空白は除く)。
# - sh の block の行継続: 行末の `\` と改行は、空白 1 つにつなげてから見る。
# - 項目: 行の頭の「- 」で始まる行と、字下げした続きの行 (fence の外)。空行と字下げの無い行で終わる。
# - 段落: 空行で区切る (fence の外。fence も段落を区切る)。
# - 文: 「。」で区切る (fence の外。空白を除いた後で区切る)。
# - code span: fence の外の `…`。行をまたいで折り返してよい。中の空白と折り返しを除いて比べる。
# - 語の照合: どれも空白 (折り返しを含む) を除いて比べる。
module MarkdownUnits
  FENCE = /\A[ \t]*```(.*)$/.freeze
  HEADING = /\A(#+)[ \t]+\S/.freeze

  module_function

  def squash(text)
    text.gsub(/\s+/, "")
  end

  # 見出しから、同じか上の level の次の見出しまで。無ければ nil。
  def section(text, heading)
    want = squash(heading)
    level = heading[/\A#+/].to_s.size
    body = nil
    fence = false
    text.each_line do |line|
      fence = !fence if line =~ FENCE
      marks = !fence && line[HEADING, 1]
      if marks && body.nil?
        body = [] if squash(line) == want
        next
      end
      break if marks && marks.size <= level

      body << line unless body.nil?
    end
    body&.join
  end

  # fence の外の行だけをつなげた text (fence の所には空行を置き、段落と項目を区切る)。
  def prose(text)
    out = +""
    fence = false
    text.each_line do |line|
      if line =~ FENCE
        fence = !fence
        out << "\n"
        next
      end
      out << line unless fence
    end
    out
  end

  # fence で囲んだ block を [info string, 中身] の列で返す。中身は、行継続をつなげたもの。閉じていない fence は数えない。
  def blocks(text)
    out = []
    current = nil
    text.each_line do |line|
      if line =~ FENCE
        if current
          out << current
          current = nil
        else
          current = [Regexp.last_match(1).strip, +""]
        end
      elsif current
        current[1] << line
      end
    end
    out.map { |info, body| [info, body.gsub(/\\\n[ \t]*/, " ")] }
  end

  # 項目 (「- 」で始まる行と、字下げした続きの行) の列。
  def items(text)
    out = []
    open = false
    prose(text).each_line do |line|
      if line.start_with?("- ")
        out << line.dup
        open = true
      elsif open && line =~ /\A[ \t]+\S/
        out[-1] << line
      else
        open = false
      end
    end
    out
  end

  # 段落 (空行で区切る) の列。
  def paragraphs(text)
    prose(text).split(/\n[ \t]*\n/).reject { |para| para.strip.empty? }
  end

  # 文 (「。」で区切る) の列。どれも空白を除いた形。
  def sentences(text)
    squash(prose(text)).split("。").reject(&:empty?)
  end

  # code span の中身の列。どれも空白を除いた形。
  def code_spans(text)
    prose(text).scan(/`([^`]+)`/).flatten.map { |span| squash(span) }
  end

  # units のうち、key を含むもの (空白を除いて比べる)。
  def containing(units, key)
    want = squash(key)
    units.select { |unit| squash(unit).include?(want) }
  end

  # text に無い語の列 (空白を除いて比べる)。
  def missing(text, words)
    have = squash(text)
    words.reject { |word| have.include?(squash(word)) }
  end
end
