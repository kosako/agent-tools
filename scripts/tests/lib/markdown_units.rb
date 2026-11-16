# scripts/tests/*-wiring-test.sh が共有する、Markdown の文書を単位に分ける helper (#676)。
# suite 側から
#   ruby -r"$script_dir/lib/markdown_units" - ... <<'RUBY'
# で読み込む。文言の検知のための最小の読み方で、Markdown の parser ではない。行ごとに読み、複数行にまたがる正規表現で
# block を切り出さない。
#
# 受ける整形 (これが契約。ここに無い書き方は受けない。たとえば `~~~` の fence、`*` や番号の list、4 つ以上の backtick の
# fence、全角の空白での字下げ):
# - 見出し: 行の頭の `#` の並びと、その後ろの空白か tab が 1 つ以上 (節は section、次の見出しまでの導入は lead)。照合は空白を除いて比べる (`###  2.` も `### 2.` と同じ)。
#   level は `#` の数。fence の中の行は見出しとみなさない。
# - fence: 行の頭 (空白か tab の字下げは可) の ``` で始まり、次の ``` で始まる行で終わる。info string (`sh` など) は、
#   始まりの行の ``` の後ろ (前後の空白は除く)。
# - sh の block (info string が `sh`) の行継続: 行末の `\` と改行は、空白 1 つにつなげてから見る。ほかの block はそのまま。
# - 項目: 行の頭の `-` と空白か tab が 1 つ以上で始まる行と、字下げした続きの行 (fence の外)。
# - 一覧: 続いた項目のまとまり。空行か、字下げの無い行 (項目でない行) で終わる。
# - 字下げした項目 (bullets): 行の頭 (字下げは可) の `-` と空白か tab で始まる行と、その `-` より深く字下げした続きの行。
#   子の項目は親と分け、子の後ろにある親の続きの行は親に付ける。空行と fence で閉じる (番号つきの手順の下の項目もここで取る)。
# - 段落: 空行で区切る (fence の外。fence も段落を区切る)。段落を項目の始まりで切った、項目でない部分 (plains) も取れる。
# - 文: 「。」で区切る (fence の外。空白を除いた後で区切る)。
# - 文のつながり: key を含む文と、その後ろに続く文 (sentence_runs)。
# - code span: fence の外の `…`。行をまたいで折り返してよい。中の空白と折り返しを除いて比べる。
# - 語の照合: どれも空白 (折り返しを含む) を除いて比べる。
# - 句の照合 (clause?): 空白を除いた句の直後が区切り (。、( ) か末尾であること。括弧の注釈 (半角の丸括弧) は bare で除ける。
# - そのほか: 見出しの列 (headings)、level ごとの位置の順の節 (sections)、表の行 (rows)、ある行のすぐ後ろの fence の block
#   (block_after。間に許すのは空行だけ)。
module MarkdownUnits
  FENCE = /\A[ \t]*```(.*)$/.freeze
  HEADING = /\A(#+)[ \t]+\S/.freeze
  ITEM = /\A-[ \t]+\S/.freeze
  BULLET = /\A([ \t]*)-[ \t]+\S/.freeze

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

  # 見出しから、次の見出し (level を問わない) の前までの本文 (見出しの直後の導入の部分)。無ければ nil。fence の中の見出しの形の
  # 行では切らない。
  def lead(text, heading)
    body = section(text, heading)
    return nil if body.nil?

    out = +""
    fence = false
    body.each_line do |line|
      fence = !fence if line =~ FENCE
      break if !fence && line =~ HEADING

      out << line
    end
    out
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

  # fence で囲んだ block を [info string, 中身] の列で返す。中身はそのまま。閉じていない fence は数えない。
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
    out
  end

  # info string が `sh` の block の中身の列。行継続 (行末の `\` と改行) は、空白 1 つにつなげる。
  def sh_blocks(text)
    blocks(text).select { |info, _| info == "sh" }.map { |_, body| body.gsub(/\\\n[ \t]*/, " ") }
  end

  # 一覧 (続いた項目のまとまり) の列。一覧は項目の列。
  def lists(text)
    out = []
    open = false
    prose(text).each_line do |line|
      if line =~ ITEM
        out << [] unless open
        out[-1] << line.dup
        open = true
      elsif open && line =~ /\A[ \t]+\S/
        out[-1][-1] << line
      else
        open = false
      end
    end
    out
  end

  # 項目 (`-` で始まる行と、字下げした続きの行) の列。
  def items(text)
    lists(text).flatten
  end

  # 字下げの有無に関わらず、`-` の項目を 1 つずつ分けた列 (bullets)。子の項目は親と分ける。続きの行は、その行より浅い字下げの
  # 項目のうち、いちばん近いものに付ける (子の項目の後ろにある親の続きの行は、親に付く)。空行と fence で、開いている項目を閉じる。
  # 字下げの深さは、行の頭の空白と tab の数で比べる。
  def bullets(text)
    out = []
    open = []
    prose(text).each_line do |line|
      if (m = line.match(BULLET))
        depth = m[1].size
        open.pop while open.any? && open.last[0] >= depth
        out << line.dup
        open << [depth, out.size - 1]
      elsif line.strip.empty?
        open.clear
      else
        depth = line[/\A[ \t]*/].size
        open.pop while open.any? && open.last[0] >= depth
        out[open.last[1]] << line if open.any?
      end
    end
    out
  end

  # 段落を項目の始まりで切った範囲のうち、項目でない部分の列 (plains)。段落の中の文を `- ` で別の項目に切り出しても、同じ段落の
  # まま通らないように、項目でない文の続きを見るために使う。
  def plains(text)
    paragraphs(text).flat_map { |para| para.lines.slice_before { |l| l.match?(BULLET) }.map(&:join) }
                    .reject { |chunk| chunk.match?(BULLET) }
  end

  # 段落 (空行で区切る) の列。
  def paragraphs(text)
    prose(text).split(/\n[ \t]*\n/).reject { |para| para.strip.empty? }
  end

  # 文 (「。」で区切る) の列。どれも空白を除いた形。
  def sentences(text)
    squash(prose(text)).split("。").reject(&:empty?)
  end

  # key を含む文から始まる、続いた n 個の文のつながり (各文の末尾に「。」を付けてつなげた形) の列。条件の文と、それに続く処理の
  # 文を組で見るため (処理の文だけを別の分岐へ移した変更を通さない。#685)。各文に「。」を付けるので、「。」で終わる句は文の終わり
  # まで比べられる (文の後ろに否定を足した変更を通さない)。key も、文の末尾の「。」を付けた形と比べる。
  def sentence_runs(text, key, n)
    list = sentences(text).map { |s| "#{s}。" }
    want = squash(key)
    list.each_index.select { |i| list[i].include?(want) }.map { |i| list[i, n].join }
  end

  # code span の中身の列。どれも空白を除いた形。
  def code_spans(text)
    prose(text).scan(/`([^`]+)`/).flatten.map { |span| squash(span) }
  end

  # 見出しの列 ([level, 名前])。fence の中の見出しの形の行は数えない。名前は前後の空白を除く。
  def headings(text)
    out = []
    fence = false
    text.each_line do |line|
      if line =~ FENCE
        fence = !fence
        next
      end
      next if fence || line !~ HEADING

      marks = line[/\A#+/]
      out << [marks.size, line[marks.size..-1].strip]
    end
    out
  end

  # 表の行 (fence の外で、字下げを除いて `|` から始まる行) の列。
  def rows(text)
    prose(text).lines.select { |l| l.lstrip.start_with?("|") }
  end

  # 空白を除いて lead で始まる行 (fence の外) のすぐ後ろの fence の block ([info string, 中身])。lead の行と fence の間に許すのは
  # 空行だけで、本文や見出しを挟んだ先の block は取らない (別の節の例を拾わないため)。無ければ nil。
  def block_after(text, lead)
    want = squash(lead)
    lines = text.lines
    fence = false
    at = lines.index do |line|
      fence = !fence if line =~ FENCE
      !fence && squash(line).start_with?(want)
    end
    return nil if at.nil?

    rest = lines[(at + 1)..-1].drop_while { |line| line.strip.empty? }
    return nil unless rest.first =~ FENCE

    blocks(rest.join).first
  end

  # 見出しの level ごとに、出てくる位置の順に分けた節の列 ([名前, 本文])。同じ名前の見出しも別の節として返す。本文は、次の同じか
  # 上の level の見出しの前まで。fence の中の見出しの形の行では切らない。
  def sections(text, level)
    out = []
    fence = false
    text.each_line do |line|
      fence = !fence if line =~ FENCE
      marks = !fence && line =~ HEADING ? line[/\A#+/] : nil
      if marks && marks.size == level
        out << [line[marks.size..-1].strip, +""]
      elsif marks && marks.size < level
        out << nil
      elsif out.last
        out.last[1] << line
      end
    end
    out.compact
  end

  SEPARATORS = %w[。 、 (].freeze

  # 句 (空白を除いた形) が text にあり、直後が区切り (。、( ) か末尾であること。否定は句の後ろに付くので、「〜しないことは
  # ない」のような反転を部分一致で通さないため。
  def clause?(text, clause)
    t = squash(text)
    c = squash(clause)
    at = t.index(c)
    until at.nil?
      after = t[at + c.size]
      return true if after.nil? || SEPARATORS.include?(after)

      at = t.index(c, at + 1)
    end
    false
  end

  # 括弧の注釈 (半角の丸括弧。入れ子を含む) を除いた text。注釈を挟む列挙でも、述語まで続けて照合するため。対の無い括弧は残す。
  def bare(text)
    out = +""
    opens = []
    text.each_char do |ch|
      if ch == "("
        opens << out.size
        out << ch
      elsif ch == ")" && opens.any?
        out = out[0, opens.pop]
      else
        out << ch
      end
    end
    out
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
