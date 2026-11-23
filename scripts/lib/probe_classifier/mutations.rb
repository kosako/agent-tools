# frozen_string_literal: true

# 分類器の不変条件の試行 (#754) の変異の表。Spec: docs/classifier-invariants.md。
#
# 変異は、分類器の source の 1 か所を置き換えて、過去に塞いだ穴の型を 1 つ開け直す。壊した版が read と区分し、
# 元の版は区分しない command を走らせ、試行が違反を見つけるかを確かめる (陽性の対照)。
# 見つからなければ、判定か fixture か生成器のどれかが足りない。
#
# 責務の境界:
#   - ここは表と、source の文字列への当て方だけを持つ。分類器の file を読む、書く、走らせるのは入口。
#   - 表の対象は、試行で固定した版 (25a12ed) の分類器。repo の今の分類器に当たることは求めない
#     (分類器を直す PR が、この表の保守を負わないようにする)。当たらない source には Error を上げる。
#   - witness と見込みは、25a12ed の file を変異させ、入口の --command で隔離の中を走らせて決めた。
#     道具の版や fixture が変われば、測り直す。

module ProbeClassifier
  # isolation.rb と同じ定義。この file だけを読んでも使えるように、ここでも開く。
  class Error < StandardError; end

  module Mutations
    # 変異を当てられない (知らない名前、置き換える文字列が 1 回だけ出る形でない)。入口は exit 2 にする。
    class Error < ProbeClassifier::Error; end

    # from を to に置き換える。from は、source に 1 回だけ出る文字列。
    #   invariant: 効く不変条件 (I1 か I2)。
    #   needs:     witness が要る任意の道具の名前 (その道具が無い machine では「測れない」)。
    #   variant:   witness を走らせる変種。
    #   expect:    出方。violation は反例 (exit 1)。non-default-variant は、既定でない変種だけで出て、
    #              人に出すものになる (exit 3)。
    #   witnesses: 変異した版が read と区分し、元の版は区分せず、走らせると invariant の違反になる command。
    #              どれも guard を通る。先頭が代表。
    #   unmeasurable: guard が通す形で出せないときの理由 (そのとき witnesses は空)。
    #   reopens:   開け直す穴の型。
    Mutation = Struct.new(:name, :from, :to, :invariant, :needs, :variant, :expect, :witnesses, :unmeasurable,
                          :reopens, keyword_init: true)

    EXPECTATIONS = %w[violation non-default-variant].freeze

    # from と to は、分類器の source の字のまま (単一引用の literal。\A や \[ をそのまま持つ)。
    TABLE = [
      Mutation.new(
        name: "plain-read-sort",
        from: 'md5sum].freeze',
        to: 'md5sum sort].freeze',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["sort -o out.txt in.txt", "sort in.txt -o out.txt"], unmeasurable: nil,
        reopens: "書き込みの option を持つ command を、名前だけで read にする",
      ),
      Mutation.new(
        name: "uniq-output-operand",
        from: 'pos.length >= 2 ? "file-write" : "read"',
        to: '"read"',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["uniq in.txt out.txt", "uniq - out.txt"], unmeasurable: nil,
        reopens: "uniq の 2 つ目の位置引数 (出力の file) を見ない",
      ),
      Mutation.new(
        name: "uniq-spec-drift",
        from: 'UNIQ_SPEC = { flags: "cdiuDz", values: "fsw",',
        to: 'UNIQ_SPEC = { flags: "diuDz", values: "fswc",',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["uniq -c in.txt out.txt"], unmeasurable: nil,
        reopens: "option の表で、値をとらない字を値をとる字に取り違える",
      ),
      Mutation.new(
        name: "find-delete",
        from: 'a == "-delete" || a.match?(/\A-(fprint|fprint0|fprintf|fls)\z/)',
        to: 'a.match?(/\A-(fprint|fprint0|fprintf|fls)\z/)',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["find . -name x -delete", "find lib -name median.rb -delete"], unmeasurable: nil,
        reopens: "find の -delete を見ない",
      ),
      Mutation.new(
        name: "git-output-option",
        from: 'name.start_with?("--output") || abbrev.call("--output")',
        to: 'false',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["git log --output=out.txt", "git diff --output=out.txt"], unmeasurable: nil,
        reopens: "git の読み取りの subcommand の --output を見ない",
      ),
      Mutation.new(
        name: "brace-expansion-off",
        from: 'starts = (0...masked.length).select { |i| masked[i] == "{" && brace_list_at(masked, i) }',
        to: 'starts = []',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["sort {-o,out.txt} in.txt", "uniq {in.txt,out.txt}"], unmeasurable: nil,
        reopens: "brace を展開せずに区分する",
      ),
      Mutation.new(
        name: "glob-floor-off",
        from: '(braced || !rg_positional_globs?(text, masked, prefix + words, prefix.length))',
        to: 'false',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["uniq pair/*", "cd sortopt && sort *"], unmeasurable: nil,
        reopens: "引用の外の glob を、展開の前の語のまま区分する",
      ),
      Mutation.new(
        name: "dq-dollar",
        from: 'return nil if c == "$" || c == "`"',
        to: 'return nil if c == "`"',
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ['sort "${zz:--o}" out.txt in.txt'], unmeasurable: nil,
        reopens: "門が、二重引用の中の $ を通す",
      ),
      Mutation.new(
        name: "assignment-only-read",
        from: 'assigned ? "unknown" : "read"',
        to: '"read"',
        # zsh だけで出る (bash と sh は、同じ代入で置き換えを走らせない)。a=1 が無いと、zsh でも走らない。
        invariant: "I1", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["a=1; RANDOM='a[$(sort -o out.txt in.txt)1]'"], unmeasurable: nil,
        reopens: "代入だけの部分を read にする (zsh は、整数の変数への代入で添字の中の置き換えを走らせる)",
      ),
      Mutation.new(
        name: "custom-path-floor-off",
        from: 'custom ? max_class([cls, "unknown"]) : cls',
        to: 'cls',
        invariant: "I2", needs: [], variant: "zsh", expect: "violation",
        witnesses: ["./cat x", "bin/grep apple in.txt"], unmeasurable: nil,
        reopens: "標準の bin の外の path の command を、名前で区分する",
      ),
      Mutation.new(
        name: "rg-glob-word-any",
        from: 'RG_GLOB_WORD = %r{\A[A-Za-z0-9_./]}.freeze',
        to: 'RG_GLOB_WORD = %r{\A}.freeze',
        invariant: "I2", needs: ["rg"], variant: "zsh", expect: "violation",
        witnesses: ["cd pre && rg median *"], unmeasurable: nil,
        reopens: "rg の位置引数の glob の語の、先頭の字の絞りを外す",
      ),
      Mutation.new(
        name: "caret-not-glob",
        from: 'GLOB_CHAR = /[*?\[^]/.freeze',
        to: 'GLOB_CHAR = /[*?\[]/.freeze',
        invariant: "I1", needs: [], variant: "zsh-extendedglob", expect: "non-default-variant",
        witnesses: ["cd pair && uniq ^x", "cd sortopt && sort ^x"], unmeasurable: nil,
        reopens: "引用の外の ^ を glob の字として扱わない (#751 の穴)",
      ),
    ].each(&:freeze).freeze

    def self.names
      TABLE.map(&:name)
    end

    def self.fetch(name)
      TABLE.find { |m| m.name == name } || raise(Error, "unknown mutation (known: #{names.join(', ')})")
    end

    # needle が source に出る回数 (重ならない数え方)。
    def self.occurrences(source, needle)
      count = 0
      at = 0
      while (found = source.index(needle, at))
        count += 1
        at = found + needle.length
      end
      count
    end

    # source (分類器の file の中身) に変異を当てた文字列を返す。source は変えない。
    # 置き換える文字列が 1 回だけ出るときに限る。0 回は、対象でない版の source。2 回以上は、どこを変えるかが
    # 決まらない。どちらも Error にして、変異していない source を「変異した版」として調べさせない。
    def self.apply(source, name)
      mutation = fetch(name)
      raise Error, "the classifier source is not a string" unless source.is_a?(String)

      count = occurrences(source, mutation.from)
      unless count == 1
        raise Error, "mutation #{mutation.name} does not apply: the text to replace occurs #{count} times (expected 1)"
      end

      # 位置で切ってつなぐ (sub に文字列を渡すと、to の中の \ が後方参照として読まれる)。
      at = source.index(mutation.from)
      source[0...at] + mutation.to + source[(at + mutation.from.length)..-1]
    end
  end
end
