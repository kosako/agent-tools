# frozen_string_literal: true

# 分類器の不変条件の試行 (#754) の command の生成器。Spec: docs/classifier-invariants.md。
#
# seed と件数から、command の列を作る。同じ seed と件数なら、Ruby の版に依らず、byte まで同じ列になる。
# 列は、系統 (どの command か) とずらし (どう崩すか) の組 (cell) を、番号の順に回して作る。
# 件数が cell の数以上なら、全部の cell が 1 回以上出る。
#
# 責務の境界:
#   - ここは文字列を作るだけ。分類も実行もしない。走らせるのは、必ず isolation.rb の guard と profile を通す側。
#   - 分類器を読まない (定数を require しない)。同じ列を、今の版、変異、過去の版に当てるため。
#     系統の語は、25a12ed の分類器を読んで決め、下の表に写してある (対応は SOURCES)。
#   - 出す形は、全件が Isolation.guard を通る形に限る (self-test が確かめる)。guard が拒む語 (set、kill、gh、
#     while など) を、operand の名前や pattern に使わない。
#   - operand は fixture の中の相対 path だけ。名前は isolation.rb の fixture の表にある (FIXTURE_PATHS)。
#   - 乱数は SHA-256 から取る整数だけ。shuffle、sample、rand、Object#hash、時刻、pid は使わない。

require "digest"

module ProbeClassifier
  module Generator
    # 行。cell は「系統/ずらし」。
    Row = Struct.new(:index, :command, :cell, keyword_init: true) do
      # corpus.jsonl に書く形 (key は文字列)。
      def record
        { "index" => index, "command" => command, "cell" => cell }
      end
    end

    # 基本形。ずらしは、この 3 つの並びを機械的に崩す。options は、選べる option の並びの候補。
    # lead は、前に置く部分 (xargs に渡す pipe の左)。
    Base = Struct.new(:name, :options, :operands, :lead, keyword_init: true)
    # forms は手で置いた形、bases は機械的に崩す基本形。lane は、系統の中での cell の順番。
    Cell = Struct.new(:name, :family, :shift, :forms, :bases, :lane, keyword_init: true)

    FAMILIES = %w[plain sort uniq diff sed awk find xargs rg ruby git].freeze
    SHIFTS = %w[opt-after dashdash bundle value-next write-form brace glob quote prefix name script git-form].freeze
    # 門の外の形の cell の系統の名前。11 の系統とは別枠で、回す順番の最後に置く。
    GATE = "gate"

    # 系統と、分類器 (25a12ed) の定数と関数の対応。docs の「source との対応」に写す。
    SOURCES = {
      "plain" => "PLAIN_READ、classify_by_name",
      "sort" => "SORT_SPEC、parse_options、read_with_args",
      "uniq" => "UNIQ_SPEC、parse_options、read_with_args",
      "diff" => "read_with_args (diff の短い option の allowlist)",
      "sed" => "SED_ADDRESS、SED_PRINT、SED_LONG_FLAGS、sed_call",
      "awk" => "awk_call",
      "find" => "find_call、injected_call",
      "xargs" => "XARGS_VALUE_OPTIONS、xargs_call、injected_call",
      "rg" => "RG_SPEC、RG_GLOB_WORD、rg_positional_globs?、masked_words、parse_options",
      "ruby" => "RUBY_VERSION_ARGS、ruby_syntax_check?、script_file?、interpreter_call",
      "git" => "GIT_READ、GIT_WRITE、GIT_GLOBAL_VALUES、GIT_GLOBAL_FLAGS、GIT_PROGRAM_OPTIONS、GIT_LISTING、" \
               "classify_git、git_subcommand、git_read_option_class、git_listing、git_config",
      GATE => "SIMPLE_CHAR、DQ_ESCAPES、simple_command?、dq_end、scan_step ($'…')、classify_split (代入だけの部分)",
    }.freeze
    # ずらしと包みが当たる、分類器の定数と関数。
    SHIFT_SOURCES = {
      "opt-after" => "parse_options (位置引数の後ろの option も読む)",
      "dashdash" => "parse_options の --、sed_call、awk_call、git_listing",
      "bundle" => "parse_options (束と、束の残りの値)",
      "value-next" => "parse_options (次の語を値に取る)、git_listing、xargs_call",
      "write-form" => "read_with_args、sed_call、find_call、git_read_option_class、redirect_spans",
      "brace" => "BRACE_ELEMENT、brace_list_at、expand_braces、classify_segment",
      "glob" => "GLOB_CHAR、classify_split、rg_positional_globs?",
      "quote" => "scan、Shellwords.split、simple_command?",
      "prefix" => "PREFIX_WORDS、ASSIGNMENT、classify_split (} fi done)",
      "name" => "STANDARD_BIN_DIRS、classify_words",
      "script" => "SED_PRINT、awk_call",
      "git-form" => "classify_git、git_subcommand",
      "wrap" => "separator_at?、SAFE_REDIRECTS、redirect_spans、shell_call、xargs_call、find_call、injected_call",
    }.freeze

    # --- operand の表 -------------------------------------------------------------------------
    # 表の中の @名前 を、この表の語に置き換える。語は fixture の中の相対 path か、guard が通す literal。
    SLOTS = {
      "file" => %w[in.txt in.txt x README.md lib/median.rb pair/a.txt],
      "gfile" => %w[README.md in.txt x lib/median.rb],
      "rb" => %w[lib/median.rb canary_begin.rb],
      # 書き込みの先。無い名前 (作成になる) と、在る名前 (中身の変更になる)。
      "out" => %w[out.txt out.txt lib/out.txt pair/b.txt],
      # brace の要素と、option につなぐ値に使える名前 (/ を含まない)。
      "fb" => %w[in.txt x README.md],
      "ob" => %w[out.txt],
      "pat" => %w[apple median banana a],
      "dir" => %w[. lib pair plain],
      "path" => %w[in.txt lib lib/median.rb . pair],
      "rgpath" => %w[lib in.txt . pair README.md],
      "fname" => ["x", "in.txt", "median.rb", "a.txt", "'*.rb'", "'*.txt'"],
      "cmd" => %w[cat sort uniq],
      "newname" => %w[x v1 topic],
      "sedp" => ["p", "1p", "2,3p", "'1p;2p'"],
      "prog" => ["'{ print }'", "'{ print NF }'", "'NR<2'", "'END { print NR }'", "'BEGIN { print 1 }'"],
      "gl" => ["*.txt", "in.tx?", "[i]n.txt", "lib/*.rb", "pair/*", "*", "^x", "R*.md", "*/a.txt", "pair/a.*"],
      "br" => ["{in.txt,x}", "{in,in}.txt", "pair/{a,b}.txt", "lib/{median,median}.rb", "{x,README.md}",
               "{README,README}.md"],
    }.freeze
    # 2 つ目のずらしで、最初の file の語を置き換える形。
    DECOR_SLOTS = %w[file gfile rb].freeze
    GLOB_OF = {
      "in.txt" => ["in.tx?", "i*.txt", "[i]n.txt"], "x" => ["?", "[x]"], "README.md" => ["README.*", "R*.md"],
      "lib/median.rb" => ["lib/*.rb", "lib/median.r?", "*/median.rb"], "pair/a.txt" => ["pair/a.*", "pair/*"],
      "canary_begin.rb" => ["canary_*.rb"],
    }.freeze
    BRACE_OF = {
      "in.txt" => ["{in,in}.txt", "{in.txt,x}"], "x" => ["{x,x}", "{x,in.txt}"], "README.md" => ["{README,README}.md"],
      "lib/median.rb" => ["lib/{median,median}.rb"], "pair/a.txt" => ["pair/{a,b}.txt"],
      "canary_begin.rb" => ["{canary_begin,canary_begin}.rb"],
    }.freeze
    # 表が当てにする、fixture の中の名前 (isolation.rb の FIXTURE_FIRST、FIXTURE_SCENES、canary の file)。
    # self-test が、fixture の表と突き合わせる。sortopt と pre の - で始まる名前は、glob の展開でだけ届く。
    FIXTURE_PATHS = %w[README.md in.txt x lib/median.rb pair/a.txt pair/b.txt sortopt/in.txt pre/a.txt plain/a.txt
                       cat bin/grep canary_begin.rb].freeze
    FIXTURE_DIRS = %w[. lib pair plain sortopt pre].freeze

    # 前置きの cell が前に置く語。分類器が読み飛ばす語 (PREFIX_WORDS)、引用した予約語、代入。
    # env done と 'fi' 'done' '}' は、後ろが何であっても read になる (既知の K4)。
    PREFIXES = ["env", "command", "exec", "nohup", "time", "nice", "builtin", "nice -n 5", "'then'", "'do'", "'else'",
                "'!'", "'{'", "env done", "'fi'", "'done'", "'}'", "LC_ALL=C"].freeze
    # 2 つ目のずらしで前に置く語 (区分を変えない語だけ)。
    PLAIN_PREFIXES = %w[env command nice nohup exec].freeze
    # 引用しない名前。guard は、引用した語の中身を入れ子の command として見る。ruby だけの語は、stdin の script を
    # 走らせる形 (語の無い ruby) と同じに見えて、拒まれる。
    UNQUOTED_NAMES = %w[ruby].freeze

    # --- 2 つ目のずらしと包み ---------------------------------------------------------------------
    # [種類, 重み]。重みの合計は 100。
    SECOND_SHIFTS = [[nil, 64], [:prefix, 8], [:quote_name, 8], [:quote, 7], [:glob, 7], [:brace, 6]].freeze
    WRAPS = [[nil, 40], [:second, 16], [:cd, 8], [:redirect, 12], [:nested, 14], [:xargs, 5], [:find, 5]].freeze
    # 分類器の門が通す安全な redirect (SAFE_REDIRECTS と同じ 7 つ)。
    SAFE_REDIRECTS = ["2>/dev/null", "1>/dev/null", ">/dev/null", "&>/dev/null", "2>&1", "1>&2", ">&2"].freeze
    SIDES = ["cat x", "ls", "pwd", "true", "git status --short", "echo in.txt"].freeze
    FILTERS = ["wc -l", "head -n 1", "sort", "uniq -c", "cat"].freeze
    CD_DIRS = %w[. . lib pair plain sortopt pre].freeze
    NESTED_SHELLS = ["sh -c", "bash -c", "zsh -lc", "zsh -c"].freeze
    APPEND_FILES = %w[in.txt x lib/median.rb].freeze
    FIND_ENDS = ["+", "';'"].freeze

    # --- 門の外の形 (閉じた表) -------------------------------------------------------------------
    # 分類器の門 (simple_command?) が閉じる形と、代入だけの部分。門の変異 (dq-dollar、assignment-only-read) の
    # 対照に使う。この表の文字列をそのまま出し、2 つ目のずらしも包みも足さない。
    # $ を含む形は、guard の表 (Isolation::DOLLAR_FORMS) にある形だけ。環境の変数の参照は出さない。
    # 置き換えの中の書き込みは、zsh が整数の変数への代入で、設定済みの変数の添字を評価する形 (a=1 が要る)。
    GATE_FORMS = {
      "gate/ansi-dollar" => ["sort $'-o' out.txt in.txt", "sort in.txt $'-o' out.txt"],
      "gate/dq-dollar" => ['sort "${zz:--o}" out.txt in.txt', 'sort in.txt "${zz:--o}" out.txt'],
      "gate/assignment" => ["n=1", "cat in.txt; n=1", "n=1; cat in.txt", "n=1; m=2"],
      "gate/substitution" => ["a=1; RANDOM='a[$(sort -o out.txt in.txt)1]'", "RANDOM='a[$(sort -o out.txt in.txt)1]'"],
    }.freeze

    # --- 系統とずらしの表 -----------------------------------------------------------------------
    # 書式。
    #   [系統]            次の行の「= …」が、基本形を機械的に崩すずらし。その下が基本形で、
    #                     「名前 :: option の候補 (; で分ける) :: 位置引数 :: 前に置く部分」。
    #   [系統/ずらし]     手で置いた形。1 行が 1 つ。
    # cell は、手で置いた形か、機械的に崩すずらしのどちらかを持つ組だけ (意味のある組)。
    # 手で置いた形は、1 つの cell に 19 個まで (件数 2000 で、どの cell も 19 回は回る)。
    TABLE = <<~'TABLE'
      [plain]
      = opt-after dashdash bundle brace glob quote prefix
      cat :: -n ; -b ; -e ; -v :: @file
      head :: -n 2 ; -c 5 ; -n2 :: @file
      tail :: -n 2 ; -c 5 ; -r :: @file
      grep :: -c ; -n ; -i ; -v ; -E ; -o ; -l :: @pat @file
      egrep :: -c ; -n :: @pat @file
      fgrep :: -c ; -x :: @pat @file
      ls :: -la ; -1 ; -R ; -d :: @path
      wc :: -l ; -c ; -w :: @file
      nl :: -b a ; -n ln :: @file
      stat :: -f %z ; -L ; -x :: @file
      pwd :: -L ; -P ::
      echo :: -n :: @file
      cmp :: -s ; -l :: @file @file
      cut :: -c 1-3 ; -c1-3 ; -b 1 :: @file
      tr :: -s ; -c :: a b
      jq :: -r ; -c ; -n :: . @file
      which :: -a ; -s :: @cmd
      type :: -a :: @cmd
      basename :: -a ; -s .rb :: @path
      dirname :: :: @path
      realpath :: -q :: @path
      readlink :: -n :: @path
      true :: ::
      false :: ::
      du :: -a ; -h ; -s ; -d 1 :: @path
      id :: -u ; -G ; -un ::
      whoami :: ::
      uname :: -a ; -s ; -m ::
      column :: -t ; -c 40 :: @file
      fold :: -w 10 ; -s :: @file
      od :: -c ; -An ; -x :: @file
      hexdump :: -C ; -n 8 :: @file
      strings :: -a ; -n 3 :: @file
      shasum :: -a 256 :: @file
      sha256sum :: --tag ; -q :: @file
      md5 :: -q ; -r :: @file
      md5sum :: --tag :: @file
      [plain/bundle]
      cd @dir
      cd @dir && pwd
      cd lib && cat median.rb
      [plain/write-form]
      cat @file > @out
      echo @pat >> @out
      grep @pat @file >@ob
      head -n 1 @file > @out
      [plain/glob]
      cd plain && cat *
      cd plain && grep apple *
      cd plain && wc *
      cd plain && head *
      cat ^x
      [plain/name]
      ./cat @file
      bin/grep @pat @file
      ./bin/grep -c @pat @file
      ./cat -n @file

      [sort]
      = opt-after dashdash brace glob quote prefix
      sort :: -r ; -n ; -u ; -f :: @file
      sort :: -n -u ; -k 2 ; -t : -k 1 :: @file
      sort :: -u ; -m :: @file @file
      sort :: -o @out :: @file
      sort :: -c ; --reverse ; --unique :: @file
      [sort/bundle]
      sort -rn @file
      sort -k2 @file
      sort -k 1,1 @file
      sort -t: -k2 @file
      sort -bfu @file
      sort -ro @out @file
      sort -uo@ob @file
      sort --key=1 --reverse @file
      sort --output=@out @file
      sort -S 1 -T . @file
      sort --parallel=1 @file
      [sort/value-next]
      sort -k -o @out @file
      sort -t -o @out @file
      sort -T -o @out @file
      sort -S -o @out @file
      sort --key -o @out @file
      sort -o -r @file
      sort --output -u @file
      sort -k -r @file
      [sort/write-form]
      sort -o @out @file
      sort -o@ob @file
      sort --output=@out @file
      sort --output @out @file
      sort @file -o @out
      sort -o @file @file
      sort @file > @out
      sort --compress-program=canary @file
      [sort/brace]
      sort {-o,@ob} @file
      sort {-r,@fb}
      sort -r {@fb,@fb}
      [sort/glob]
      cd sortopt && sort *
      cd sortopt && sort ^x
      sort sortopt/*
      sort *.txt
      sort ^x

      [uniq]
      = opt-after dashdash brace glob quote prefix
      uniq :: -c ; -d ; -u ; -i :: @file
      uniq :: -i -c ; -f 1 ; -s 1 :: @file
      uniq :: :: @file @out
      uniq :: -c :: - @out
      uniq :: --count ; --repeated ; --unique :: @file
      [uniq/bundle]
      uniq -cd @file
      uniq -ci @file
      uniq -f1 @file
      uniq -cf 1 @file
      uniq -s2 -c @file
      uniq --skip-fields=1 @file
      uniq --skip-chars 1 @file
      uniq -w 3 @file
      uniq -D @file
      uniq -cz @file
      [uniq/value-next]
      uniq -f -c @file
      uniq -s -d @file @out
      uniq -w @file @out
      uniq -f @file @out
      uniq --skip-fields -c @file
      uniq -c -f @file @out
      [uniq/write-form]
      uniq @file @out
      uniq - @out
      uniq -c @file @out
      uniq -f1 @file @out
      uniq @file > @out
      uniq -- @file @out
      uniq @file @file
      [uniq/brace]
      uniq {@fb,@ob}
      uniq {-c,@fb}
      uniq -c {@fb,@fb}
      [uniq/glob]
      uniq pair/*
      cd pair && uniq *
      cd pair && uniq ^x
      uniq ^x
      uniq -c in.tx?

      [diff]
      = opt-after dashdash brace glob quote prefix
      diff :: -u ; -q ; -U3 ; -uN :: @file @file
      diff :: -r ; -rq :: lib pair
      diff :: :: @file @file
      diff :: -w -B ; -b -i :: @file @file
      [diff/bundle]
      diff -uN @file @file
      diff -U3 @file @file
      diff -qr lib pair
      diff -bwi @file @file
      diff -U 3 @file @file
      diff -u -s @file @file
      diff --brief @file @file
      diff -l @file @file
      diff -y @file @file
      [diff/brace]
      diff {@fb,@fb}
      diff -u {@fb,@fb}
      diff pair/{a,b}.txt
      [diff/glob]
      diff pair/*
      cd pair && diff *
      diff -u pair/a.* pair/b.*

      [sed]
      = opt-after dashdash brace glob quote prefix
      sed :: -n ; -n -E :: @sedp @file
      sed :: :: @sedp @file
      sed :: -n -e :: @sedp @file
      sed :: -n :: '/a\/,/w lib/p' x
      [sed/bundle]
      sed -nE @sedp @file
      sed -n -e @sedp @file
      sed -n -e 1p -e 2p @file
      sed -En @sedp @file
      sed -ne @sedp @file
      sed --quiet @sedp @file
      sed -n --expression=@sedp @file
      sed -n -u @sedp @file
      [sed/value-next]
      sed -e -n @file
      sed -n -e -i @file
      sed -n @sedp -e 1p @file
      sed -n -f @file @file
      sed -n -e @sedp -e -i @file
      [sed/write-form]
      sed -i '' -n p @file
      sed -i.bak -n p @file
      sed -n -i.bak p @file
      sed -n 'w @out' @file
      sed -n p @file > @out
      sed --in-place -n p @file
      [sed/brace]
      sed -n p {@fb,@fb}
      sed {-n,p} @file
      sed -n {p,@fb}
      [sed/glob]
      sed -n p pair/*
      sed -n p *.txt
      cd pair && sed -n p *
      sed -n 1p ^x
      [sed/script]
      sed -n @sedp @file
      sed -n '/apple/,/banana/p' @file
      sed -n '/a\/,/w lib/p' x
      sed -n -e '/a\/,/w lib/p' x
      sed -n '2,3p' @file
      sed -n '1p;2p' @file
      sed -n 'w @out' @file
      sed -n '1,2w @out' @file
      sed 's/a/b/' @file

      [awk]
      = opt-after dashdash brace glob quote prefix
      awk :: :: @prog @file
      awk :: -F : ; -F: :: @prog @file
      awk :: -v n=1 ; -vn=1 :: @prog @file
      awk :: -F: -v n=2 :: @prog @file
      [awk/bundle]
      awk -F: @prog @file
      awk -F : @prog @file
      awk -v n=1 @prog @file
      awk -vn=1 @prog @file
      awk -F: -v n=1 @prog @file
      awk -f @file @file
      awk -version
      [awk/value-next]
      awk -F -v @prog @file
      awk -v -F @prog @file
      awk -F -f @prog @file
      awk -v n=1 -F @prog @file
      [awk/write-form]
      awk '{ print > "@out" }' @file
      awk '{ print >> "@out" }' @file
      awk @prog @file > @out
      awk '{ printf "" > "@out" }' @file
      [awk/brace]
      awk @prog {@fb,@fb}
      awk {-F,x} @prog @file
      [awk/glob]
      awk @prog pair/*
      awk @prog *.txt
      cd pair && awk @prog *
      [awk/quote]
      awk "{ print }" @file
      awk "NR<2" @file
      [awk/script]
      awk @prog @file
      awk 'BEGIN { print 1 }'
      awk 'END { print NR }' @file
      awk '{ print NR ": " NF }' @file
      awk 'NR>1' @file
      awk '{ getline; print }' @file
      awk '{ print > "@out" }' @file

      [find]
      = opt-after dashdash quote prefix
      find :: :: @dir -name @fname
      find :: :: @dir -type f
      find :: -L ; -H :: @dir -name @fname
      find :: :: @dir -maxdepth 1 -type f
      find :: :: @dir -name @fname -exec cat {} +
      find :: :: @dir -name @fname -exec wc -l {} ';'
      [find/bundle]
      find @dir -maxdepth 1 -type f
      find -L @dir -name @fname
      find -H @dir -type d
      find @dir -type f -name @fname -print
      find @dir -newer @file
      find @dir -name @fname -exec cat {} +
      find @dir -name @fname -exec grep -c @pat {} +
      find @dir -name @fname -exec cat {} ';'
      find @dir -type f -exec wc -l {} +
      find @dir -name @fname -exec sort {} +
      find @dir -name @fname -execdir cat {} +
      [find/value-next]
      find @dir -name -delete
      find @dir -newer -delete
      find @dir -exec cat {} + -name @fname
      find @dir -name -exec cat {} +
      find @dir -path -print
      find @dir -name -print -type f
      [find/write-form]
      find @dir -name @fname -delete
      find . -name x -delete
      find lib -name median.rb -delete
      find pair -name b.txt -delete
      find @dir -name @fname -fprint @out
      find @dir -type f -exec sort -o @out {} +
      find @dir -name @fname > @out
      [find/brace]
      find {lib,pair} -name @fname
      find @dir -name {x,in.txt}
      find @dir {-type,f}
      [find/glob]
      find @dir -name *.rb
      find * -name @fname
      find pair/* -type f
      find lib/*.rb
      find @dir -name ^x
      [find/quote]
      find @dir -name '*.rb'
      find @dir -name "*.txt"
      find @dir -name @fname -exec cat '{}' +
      [find/name]
      find @dir -name @fname -exec ./cat {} +
      find @dir -name in.txt -exec bin/grep -c @pat {} +
      find @dir -name @fname -exec ./cat {} ';'

      [xargs]
      = opt-after dashdash prefix
      xargs :: :: cat :: echo @file |
      xargs :: -n 1 ; -n1 ; -t :: cat :: echo @file @file |
      xargs :: -L 1 :: wc -l :: echo @file |
      xargs :: -I {} :: cat {} :: echo @file |
      xargs :: :: grep -c @pat :: echo @file |
      xargs :: :: :: echo @file |
      [xargs/bundle]
      echo @file | xargs -n 1 cat
      echo @file | xargs -n1 cat
      echo @file | xargs -I {} cat {}
      echo @file | xargs -I{} cat {}
      echo @file | xargs -t cat
      echo @file @file | xargs -L 1 wc -l
      echo @file | xargs -0 cat
      echo @file | xargs -E x cat
      echo @file | xargs -J % cat % @file
      echo @file | xargs -s 100 cat
      ls | xargs wc -l
      [xargs/value-next]
      echo @file | xargs -E -n cat
      echo @file | xargs -I -n cat
      echo @file | xargs -n -t cat
      echo @file | xargs -L -n 1 cat
      echo @file | xargs -J -t cat
      [xargs/write-form]
      echo @file | xargs sort -o @out
      echo @file @out | xargs uniq
      echo @file | xargs -I % sort -o @out %
      echo @out | xargs sort @file -o
      echo @file | xargs cat > @out
      [xargs/brace]
      echo {@fb,@fb} | xargs cat
      echo @file | xargs {-n,1} cat
      echo @file | xargs -n 1 {cat,@fb}
      [xargs/glob]
      ls *.txt | xargs cat
      echo * | xargs wc -l
      echo pair/* | xargs uniq
      echo pair/* | xargs cat
      ls lib/*.rb | xargs grep -c @pat
      echo ^x | xargs cat
      [xargs/quote]
      echo '@file' | xargs cat
      echo @file | xargs 'cat'
      echo @file | xargs "wc" -l
      echo "@file @file" | xargs cat
      echo @file | 'xargs' cat
      [xargs/prefix]
      echo @file | xargs env cat
      echo @file | xargs nice cat
      [xargs/name]
      echo @file | xargs ./cat
      echo @file | xargs bin/grep -c @pat

      [rg]
      = opt-after dashdash brace glob quote prefix
      rg :: -n ; -c ; -i -l ; -F -o :: @pat @rgpath
      rg :: -e @pat ; --regexp @pat :: @rgpath
      rg :: --files :: @dir
      rg :: -g '*.rb' ; -A 1 ; -m 1 :: @pat @rgpath
      [rg/bundle]
      rg -nA 1 @pat @rgpath
      rg -ie @pat @rgpath
      rg -c -m 1 @pat @rgpath
      rg -uu -l @pat @rgpath
      rg --max-count=1 @pat @rgpath
      rg --color never @pat @rgpath
      rg -g '*.txt' @pat .
      rg --sort path @pat @rgpath
      rg -z @pat @rgpath
      rg --pre canary @pat @rgpath
      rg -f @file @rgpath
      [rg/value-next]
      rg -e -n @rgpath
      rg -g -l @pat @rgpath
      rg -A -c @pat @rgpath
      rg -e --pre=canary @rgpath
      rg -m -z @pat @rgpath
      rg --regexp --files @rgpath
      rg -t --pre=canary @pat @rgpath
      [rg/brace]
      rg @pat {lib,pair}
      rg {-n,@pat} @rgpath
      rg -n @pat {@fb,@fb}
      [rg/glob]
      rg @pat lib/*.rb
      rg @pat *
      cd pre && rg median *
      rg @pat ^x
      rg @pat pair/*
      rg @pat *.md
      cd pre && rg median ./*
      rg -g *.rb @pat lib

      [ruby]
      = quote prefix
      ruby :: -c :: @rb
      ruby :: -v ; --version ::
      ruby :: :: @rb
      [ruby/bundle]
      ruby -c @rb
      ruby -v
      ruby --version
      ruby -c lib/median.rb x
      ruby @rb
      ruby -c x
      [ruby/brace]
      ruby {-c,canary_begin.rb}
      ruby -c lib/{median,median}.rb
      ruby -c {canary_begin,canary_begin}.rb
      [ruby/glob]
      ruby -c lib/*.rb
      ruby -c *.rb
      ruby -c lib/median.r?
      ruby -c ^x

      [git]
      = opt-after dashdash brace glob quote prefix
      git log :: --oneline -n 2 ; -1 --stat ; --format=%h :: @gfile
      git diff :: --stat ; --name-only :: @gfile
      git show :: -s ; --stat :: HEAD
      git status :: --short ; -sb ::
      git grep :: -n ; -c ; -l :: @pat
      git blame :: -s :: @gfile
      git branch :: -a ; -v ; --list ::
      git tag :: -l ; -n ::
      git rev-parse :: --short :: HEAD
      [git/bundle]
      git log -n1 --oneline
      git log -1 --stat
      git log --max-count=1 --format=%H
      git log -n 1 -p @gfile
      git diff --stat --name-only
      git diff -U1 @gfile
      git show -s --format=%s HEAD
      git grep -nI @pat
      git grep -c -e @pat
      git ls-files -s
      git blame -L 1,2 @gfile
      git branch -vv
      git tag -n2
      git status -sb
      git log --oneline --abbrev=4
      git rev-parse --short=4 HEAD
      [git/value-next]
      git branch --format --list @newname
      git tag --format --list @newname
      git branch --format -l @newname
      git branch --sort --list @newname
      git branch --contains --list @newname
      git tag --points-at --list @newname
      git branch --merged --list @newname
      git tag --sort -l @newname
      git branch --no-merged -l @newname
      git branch --list --format @newname
      git log --format --output=@out
      git log -n --oneline
      git log --author --oneline
      git -C --no-pager status
      git diff -U --stat
      [git/write-form]
      git log --output=@out
      git diff --output=@out
      git show --output=@out HEAD
      git log --outp=@out
      git diff --output @out
      git log -1 --output=@out --oneline
      git stash show --output=@out
      git branch @newname
      git tag @newname
      git log > @out
      git config user.name x
      [git/brace]
      git log {--oneline,-1}
      git log {--output,@ob}
      git diff {HEAD,HEAD}
      git show {-s,HEAD}
      git {log,status}
      [git/glob]
      git show HEAD^
      git diff HEAD^ HEAD
      git log --oneline -- *.md
      git log ^x
      git grep -n @pat -- *.txt
      git ls-files *
      git diff --stat lib/*
      cd pair && git log --oneline *
      [git/quote]
      git log '--oneline'
      git 'log' --oneline
      git log --format='%h %s'
      [git/git-form]
      git rev-parse HEAD
      git describe --always
      git describe --always --dirty
      git shortlog -s HEAD
      git ls-tree HEAD
      git cat-file -p HEAD
      git show-ref
      git for-each-ref
      git rev-list HEAD
      git version
      git stash list
      git worktree list
      git reflog
      git config --list
      git -C . status
      git --no-pager log --oneline
      git -c core.pager=cat log --oneline
      git diff --no-index in.txt x
      git show HEAD:README.md
    TABLE

    # --- 表を読む ---------------------------------------------------------------------------
    def self.parse_base(line)
      name, options, operands, lead = line.split(/\s*::\s*/, -1)
      Base.new(name: name, options: options.to_s.split(/\s*;\s*/), operands: operands.to_s, lead: lead.to_s)
    end

    # 表から cell の並びを作る。順番は、ずらしの順、その中で系統の順 (小さい件数でも、全部の系統に届くように)。
    # 門の外の cell は最後に置く。
    def self.build_cells(text)
      generic = {}
      bases = Hash.new { |h, k| h[k] = [] }
      forms = Hash.new { |h, k| h[k] = [] }
      section = nil
      text.each_line do |raw|
        line = raw.chomp.strip
        next if line.empty? || line.start_with?("#")

        if (m = line.match(/\A\[([a-z-]+(?:\/[a-z-]+)?)\]\z/))
          section = m[1]
        elsif section.include?("/")
          forms[section] << line
        elsif line.start_with?("= ")
          generic[section] = line[2..-1].split
        else
          bases[section] << parse_base(line)
        end
      end
      cells = []
      SHIFTS.each do |shift|
        FAMILIES.each do |family|
          name = "#{family}/#{shift}"
          mechanical = generic.fetch(family, []).include?(shift)
          next unless forms.key?(name) || mechanical

          cells << Cell.new(name: name, family: family, shift: shift, forms: forms.fetch(name, []).freeze,
                            bases: (mechanical ? bases.fetch(family) : []).freeze, lane: 0)
        end
      end
      FAMILIES.each { |family| cells.select { |c| c.family == family }.each_with_index { |c, k| c.lane = k } }
      GATE_FORMS.each_key do |name|
        cells << Cell.new(name: name, family: GATE, shift: name.split("/", 2).last, forms: GATE_FORMS.fetch(name),
                          bases: [].freeze, lane: 0)
      end
      cells.each(&:freeze).freeze
    end

    CELLS = build_cells(TABLE)
    # 同じ系統の cell が、表の違う所から回り始めるための歩幅。
    LANE_STRIDE = 5

    def self.cell_names
      CELLS.map(&:name)
    end

    def self.gate?(cell_name)
      cell_name.start_with?("#{GATE}/")
    end

    # --- 乱数 (SHA-256 だけ) --------------------------------------------------------------------
    def self.number(text)
      Digest::SHA256.hexdigest(text)[0, 12].to_i(16)
    end

    # 1 行の中の選択。同じ札を続けて引くと、引くたびに別の数になる。
    class Draw
      def initialize(seed, index)
        @head = "#{seed}\n#{index}\n"
        @uses = Hash.new(0)
      end

      def number(label, size)
        turn = @uses[label]
        @uses[label] = turn + 1
        Generator.number("#{@head}#{label}\n#{turn}") % size
      end

      def pick(label, list)
        list[number(label, list.length)]
      end

      # [種類, 重み] の表から、重みに比例して 1 つ選ぶ。
      def weighted(label, table)
        left = number(label, table.sum { |_, weight| weight })
        table.each do |kind, weight|
          return kind if left < weight

          left -= weight
        end
        nil
      end
    end

    # --- 行を作る ---------------------------------------------------------------------------
    # seed は整数でも文字列でもよい (文字列にして使う)。count は 0 以上の整数。
    def self.generate(seed, count)
      raise ArgumentError, "count must be a non-negative integer" unless count.is_a?(Integer) && count >= 0

      Array.new(count) { |index| row(seed, index) }
    end

    def self.row(seed, index)
      raise ArgumentError, "index must be a non-negative integer" unless index.is_a?(Integer) && index >= 0

      seed = seed.to_s
      cell, entry = slot(seed, index)
      return Row.new(index: index, command: entry, cell: cell.name) if cell.family == GATE

      draw = Draw.new(seed, index)
      second = draw.weighted("second", SECOND_SHIFTS)
      text = entry.is_a?(Base) ? shifted(cell.shift, entry, draw) : entry
      command = fill(text, draw, second)
      command = lead_shift(command, second, draw)
      Row.new(index: index, command: wrap(command, draw, cell), cell: cell.name)
    end

    # 番号から、cell と、その中の形 (手で置いた形の文字列か、基本形) を決める。
    # cell は番号の順に回る。形は、seed と系統で決まる所から回り始め、同じ系統の cell は歩幅の分だけずらす。
    def self.slot(seed, index)
      cell = CELLS[index % CELLS.length]
      start = number("#{seed}\nstart\n#{cell.family}") + LANE_STRIDE * cell.lane
      [cell, entry_at(cell, start + index / CELLS.length)]
    end

    # cell の中の形を、順に回して選ぶ。turn は、始まりに、回った数を足した数 (件数が増えれば、全部の形に届く)。
    # 手で置いた形と基本形の両方を持つ cell は、交互に出す。
    def self.entry_at(cell, turn)
      return cell.bases[turn % cell.bases.length] if cell.forms.empty?
      return cell.forms[turn % cell.forms.length] if cell.bases.empty?

      list = turn.even? ? cell.forms : cell.bases
      list[(turn / 2) % list.length]
    end

    # 列の digest。command を 1 行ずつ並べた text の SHA-256 (self-test と入口が、同じ計算を使う)。
    def self.digest(rows)
      Digest::SHA256.hexdigest(rows.map { |row| "#{row.command}\n" }.join)
    end

    # --- 基本形を崩す -------------------------------------------------------------------------
    def self.shifted(shift, base, draw)
      name = base.name.split
      options = base.options.empty? ? [] : draw.pick("option", base.options).split
      operands = base.operands.split
      words = case shift
              when "opt-after" then name + operands + options
              when "dashdash"
                # 4 回に 1 回は、-- を option の前に置く (後ろの option が位置引数になる)。
                early = draw.number("dashdash", 4).zero?
                early ? name + ["--"] + options + operands : name + options + ["--"] + operands
              when "brace" then name + options + swap_operand(operands, "@br")
              when "glob" then name + options + swap_operand(operands, "@gl")
              when "quote" then quoted(name, options, operands, draw)
              when "prefix" then [prefix_for(base, draw)] + name + options + operands
              else name + options + operands
              end
      ([base.lead] + words).reject(&:empty?).join(" ")
    end

    # 最初の file の語を、glob か brace の語に替える。file の語が無ければ、後ろに足す。
    def self.swap_operand(operands, token)
      at = operands.index { |w| w.match?(/\A@(file|gfile|rb|path|rgpath|dir)\z/) }
      return operands + [token] unless at

      operands[0...at] + [token] + operands[(at + 1)..-1]
    end

    # 名前、option、位置引数のどれか 1 語を引用する。引用を含む語と、引用つきの語に替わる語は選ばない。
    # ruby の語も選ばない (UNQUOTED_NAMES)。
    def self.quoted(name, options, operands, draw)
      words = name + options + operands
      plain = words.each_index.reject do |k|
        words[k].match?(/['"]|@(prog|sedp|fname)/) || UNQUOTED_NAMES.include?(words[k])
      end
      return words if plain.empty?

      at = draw.pick("quote-at", plain)
      mark = draw.pick("quote-mark", %w[' "])
      words[0...at] + ["#{mark}#{words[at]}#{mark}"] + words[(at + 1)..-1]
    end

    # '{' は、後ろに別の brace があると guard が拒む (入れ子の brace と見分けない) ので、その基本形には使わない。
    # awk の program (@prog) も brace を持つ。
    def self.prefix_for(base, draw)
      braces = "#{base.options.join(' ')} #{base.operands} #{base.lead}".match?(/\{|@prog/)
      draw.pick("prefix", braces ? PREFIXES - ["'{'"] : PREFIXES)
    end

    # --- @名前 を埋める -------------------------------------------------------------------------
    # second が :quote、:glob、:brace のときは、最初の file の語をその形に替える (2 つ目のずらし)。
    def self.fill(text, draw, second)
      pending = %i[quote glob brace].include?(second) ? second : nil
      # brace のある形には、brace を足さない (2 つの brace の間の字で、guard が入れ子と読むことがある)。
      pending = nil if pending == :brace && text.include?("{")
      text.gsub(/@([a-z]+)/) do
        slot = Regexp.last_match(1)
        value = draw.pick("slot-#{slot}", SLOTS.fetch(slot))
        if pending && DECOR_SLOTS.include?(slot)
          value = decorated(value, pending, draw)
          pending = nil
        end
        value
      end
    end

    def self.decorated(value, kind, draw)
      case kind
      when :quote
        mark = draw.pick("decor-mark", %w[' "])
        "#{mark}#{value}#{mark}"
      when :glob then draw.pick("decor-glob", GLOB_OF.fetch(value, [value]))
      else draw.pick("decor-brace", BRACE_OF.fetch(value, [value]))
      end
    end

    # 区切りも redirect も無い、1 つの部分だけの command か。
    def self.single?(command)
      !command.match?(/[;|&<>]/)
    end

    def self.first_word(command)
      command.split(" ", 2).first.to_s.delete(%q('"))
    end

    # 2 つ目のずらしのうち、先頭に効くもの (前置きと、名前の引用)。
    def self.lead_shift(command, second, draw)
      case second
      when :prefix
        return command unless appendable?(command)

        "#{draw.pick('plain-prefix', PLAIN_PREFIXES)} #{command}"
      when :quote_name
        m = command.match(%r{\A([A-Za-z0-9_./-]+)( .*)?\z}m)
        return command unless m && !UNQUOTED_NAMES.include?(m[1])

        mark = draw.pick("name-mark", %w[' "])
        "#{mark}#{m[1]}#{mark}#{m[2]}"
      else command
      end
    end

    # --- 包み -------------------------------------------------------------------------------
    def self.wrap(command, draw, cell)
      case draw.weighted("wrap", WRAPS)
      when :second then second_part(command, draw)
      when :cd then "cd #{draw.pick('cd', CD_DIRS)} && #{command}"
      when :redirect then "#{command} #{draw.pick('redirect', SAFE_REDIRECTS)}"
      when :nested then nested(command, draw)
      when :xargs then appendable?(command) ? "echo #{draw.pick('append', APPEND_FILES)} | xargs #{command}" : command
      when :find then find_exec(command, draw, cell)
      else command
      end
    end

    def self.second_part(command, draw)
      side = draw.pick("side", SIDES)
      case draw.number("second-form", 6)
      when 0 then "#{command}; #{side}"
      when 1 then "#{command} && #{side}"
      when 2 then "#{side}; #{command}"
      when 3 then "#{side} && #{command}"
      when 4 then "#{command} | #{draw.pick('filter', FILTERS)}"
      else "#{command} || true"
      end
    end

    # 入れ子の shell。中の引用と重ならない引用で包む。包めない形 (両方の引用や \ を含む) は、そのまま返す。
    def self.nested(command, draw)
      mark = if !command.include?("'") then "'"
             elsif !command.match?(/["\\$`]/) then '"'
             end
      return command unless mark

      "#{draw.pick('shell', NESTED_SHELLS)} #{mark}#{command}#{mark}"
    end

    # 前や後ろに語を足せる形か (前置き、xargs、find -exec)。1 つの部分だけの command に限る。
    # cd は外す (前置きを付けると dir を移らず、後ろに語が増えると guard が拒む)。
    def self.appendable?(command)
      single?(command) && first_word(command) != "cd"
    end

    # ruby は、後ろに + や ; が付くと guard の受ける形から外れる。brace のある形も、{} を足さない。
    def self.find_exec(command, draw, cell)
      return command unless appendable?(command) && cell.family != "ruby" && !command.include?("{")

      "find . -name #{draw.pick('append', APPEND_FILES.map { |f| File.basename(f) })} -exec #{command} {} " \
        "#{draw.pick('find-end', FIND_ENDS)}"
    end
  end
end
