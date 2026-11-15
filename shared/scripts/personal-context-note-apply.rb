#!/usr/bin/env ruby
# frozen_string_literal: true

# context-note-apply: repo の参照先の note (.agent-context.local.md) を、人が差分を確かめてから書き換える helper (#677)。
# note は agent が書き換えない決まりなので、agent は note の新しい全文を案の file に書き、この helper を実行する 1 行の command を
# 人に渡す。人が自分の terminal で実行し、差分を見て `y` と答えたときだけ書く。
#
# 正本: docs/context-note-apply.md。
#
# 順に次を確かめ、前の段で止まったら後ろの段は行わない。
# 1. agent の session の目印 (env の CLAUDECODE / CODEX_THREAD_ID / CODEX_SANDBOX / AGENT_TOOLS_OPENCODE) が 1 つでも空でなければ
#    書かない (personal-ai-trailer-gate と同じ目印)。
# 2. 標準入力と標準出力の両方が端末でなければ書かない (agent の Bash の tool、出力を溜める wrapper を通した起動)。
# 3. repository や index を選ぶ git の env を 1 つでも継承していれば (値が空でも)、tracked かを判定できないので止める。
# 4. 案の file は regular file で、空でなく、1 MiB 以下で、UTF-8 として読めること。
# 5. note は、無ければ新しく作る。symlink、regular file でないもの、git で tracked のもの (大文字小文字の違いを含む) には書かない。
# 6. 案が今の note と同じなら、何もせずに終わる。
# 7. 差分を diff -u の形で見せる。制御文字と書式の文字 (Unicode の Cc と Cf。tab を除く) は <U+XXXX> の形で見せる。
# 8. [y/N] を聞き、y か yes のときだけ進む。
# 9. 書く直前に 5 の条件と、差分を見せた時から note が変わっていないことを確かめ直す。
# 10. 同じ directory の一時 file に書いてから rename で置き換える。今の note の権限を保ち、新しく作るときは 0600 にする。
#
# 強度ラベル (偽らない): 手順の守りであって境界ではない。env の目印と端末の検査は、agent が意図すれば外せる (端末を持つ pane に
# command と答えを打ち込む、など)。確かめ直してから rename までの短い窓は残る。agent が note を書かない決まりは運用 instruction が持つ。
#
# 出力: 説明の行を出し、最後の行は stdout の `context-note-apply: <label>`。
# exit: 0 = written / unchanged、1 = 書かなかった (declined / agent-session / no-tty / symlink / not-regular / tracked / changed)、
# 2 = usage / input / undetermined / write-failed。

require "digest"
require "open3"
require "securerandom"
require "tmpdir"

# C locale でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ContextNoteApply
  NAME = "personal-context-note-apply"
  NOTE = ".agent-context.local.md"
  USAGE = "usage: #{NAME} [-C <dir>] <案の file>"
  LABEL_PREFIX = "context-note-apply"

  EXIT_OK = 0
  EXIT_NOT_WRITTEN = 1
  EXIT_ERROR = 2

  AGENT_MARKERS = %w[CLAUDECODE CODEX_THREAD_ID CODEX_SANDBOX AGENT_TOOLS_OPENCODE].freeze
  # resume の検査 (#577) と personal-packet と同じ 7 つ。継承していると、別の index を指す GIT_INDEX_FILE で tracked な note を
  # 追跡なしに見たり、GIT_DIR / GIT_WORK_TREE で別の repo を見たりしうる。
  GIT_REPO_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].freeze
  MAX_BYTES = 1024 * 1024
  NEW_MODE = 0o600
  YES = %w[y yes].freeze
  # 表示で隠れうる文字。改行は行の区切り、tab は表示で中身を隠さないので除く。
  HIDDEN_RE = /[[\p{Cc}\p{Cf}]&&[^\t\n]]/.freeze

  # 書かずに終わる。label は最後の行、message は説明の行 (stderr)。
  class Stop < StandardError
    attr_reader :label, :code

    def initialize(label, code, message)
      super(message)
      @label = label
      @code = code
    end
  end

  module_function

  def run(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
    stdout.sync = true
    stderr.sync = true
    written = false
    prompted = false
    dir, proposal_path = parse_args(argv)
    check_agent_session(env)
    check_terminal(stdin, stdout)
    check_git_env(env)
    root = work_tree_root(dir)
    proposal = read_proposal(proposal_path)
    note = File.join(root, NOTE)
    current = inspect_note(root, note)
    if current&.content == proposal
      stdout.puts "案は今の note と同じです。書いていません。"
      return finish(stdout, "unchanged", EXIT_OK)
    end

    show_diff(stdout, note, current, proposal)
    prompted = true
    unless confirm?(stdin, stdout)
      stdout.puts "書いていません。"
      return finish(stdout, "declined", EXIT_NOT_WRITTEN)
    end

    unless inspect_note(root, note) == current
      raise Stop.new("changed", EXIT_NOT_WRITTEN,
                     "差分を見せた後に note が変わったので、書いていません。もう一度実行してください。")
    end

    write_note(note, proposal, current ? current.mode : NEW_MODE)
    written = true
    stdout.puts "note を書きました。"
    finish(stdout, "written", EXIT_OK)
  rescue Stop => e
    stderr.puts "#{NAME}: #{e.message}"
    finish(stdout, e.label, e.code)
  rescue SignalException
    # 答えを待つ間の Ctrl-C など。rename の後なら書いている。
    return finish(stdout, "written", EXIT_OK) if written

    # 確認の行の後なら、改行してから出す (Ctrl-C は端末に改行を残さない)。
    stdout.puts if prompted
    stderr.puts "#{NAME}: 中断しました。書いていません。"
    finish(stdout, "declined", EXIT_NOT_WRITTEN)
  end

  def finish(stdout, label, code)
    stdout.puts "#{LABEL_PREFIX}: #{label}"
    code
  end

  def usage!(message)
    raise Stop.new("usage", EXIT_ERROR, "#{message}\n#{USAGE}")
  end

  def parse_args(argv)
    dir = nil
    files = []
    args = argv.dup
    until args.empty?
      arg = args.shift
      if arg == "--"
        files.concat(args)
        break
      elsif arg == "-C"
        usage!("-C の値がありません") if args.empty?
        usage!("-C は 1 回だけ渡せます") if dir

        dir = args.shift
      elsif arg.start_with?("-") && arg != "-"
        usage!("知らない option です")
      else
        files << arg
      end
    end
    usage!("案の file を 1 つ渡してください") unless files.size == 1
    usage!("案の file は stdin から読めません (標準入力は確認の答えに使う)") if files.first == "-"

    [dir, files.first]
  end

  def check_agent_session(env)
    marker = AGENT_MARKERS.find { |name| !env[name].to_s.empty? }
    return unless marker

    raise Stop.new("agent-session", EXIT_NOT_WRITTEN,
                   "agent の session の中では note を書きません (env の #{marker} が空でない)。人の terminal で実行してください。")
  end

  def check_terminal(stdin, stdout)
    return if stdin.tty? && stdout.tty?

    raise Stop.new("no-tty", EXIT_NOT_WRITTEN,
                   "標準入力と標準出力が端末でないので、確認を取れません。人の terminal で直接実行してください " \
                   "(`!` や出力を溜める wrapper を通さない)。")
  end

  def check_git_env(env)
    name = GIT_REPO_ENV.find { |n| env.key?(n) }
    return unless name

    raise Stop.new("undetermined", EXIT_ERROR,
                   "git の env (#{name}) を継承しているので、note が tracked かを判定できません。外してから実行してください。")
  end

  def work_tree_root(dir)
    dir ||= Dir.pwd
    raise Stop.new("input", EXIT_ERROR, "-C の directory がありません: #{visible(dir)}") unless File.directory?(dir)

    out, _err, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: dir)
    unless status.success? && !out.chomp.empty?
      raise Stop.new("undetermined", EXIT_ERROR, "git の作業 tree の中ではありません: #{visible(dir)}")
    end

    File.realpath(out.chomp)
  rescue SystemCallError => e
    raise Stop.new("undetermined", EXIT_ERROR, "git の作業 tree を判定できません (#{e.class.name})")
  end

  def read_proposal(path)
    raise Stop.new("input", EXIT_ERROR, "案の file がありません: #{visible(path)}") unless File.exist?(path)
    raise Stop.new("input", EXIT_ERROR, "案の file が regular file ではありません: #{visible(path)}") unless File.file?(path)

    # 上限より 1 byte 多く読んで、越えたかを見る (空の file では binread が nil を返す)。
    data = File.binread(path, MAX_BYTES + 1) || +""
    raise Stop.new("input", EXIT_ERROR, "案の file が #{MAX_BYTES} byte を越えています") if data.bytesize > MAX_BYTES
    raise Stop.new("input", EXIT_ERROR, "案の file が空です") if data.empty?

    text = data.force_encoding(Encoding::UTF_8)
    raise Stop.new("input", EXIT_ERROR, "案の file を UTF-8 として読めません") unless text.valid_encoding?

    text
  rescue SystemCallError => e
    raise Stop.new("input", EXIT_ERROR, "案の file を読めません (#{e.class.name})")
  end

  # 今の note。無ければ nil。比べるのは中身と権限 (確かめ直すときに、別の file に置き換わったことにも気づくように inode も見る)。
  Current = Struct.new(:content, :mode, :ino, :dev)

  def inspect_note(root, note)
    st = File.lstat(note)
    raise Stop.new("symlink", EXIT_NOT_WRITTEN, "note が symlink なので書きません: #{visible(note)}") if st.symlink?
    raise Stop.new("not-regular", EXIT_NOT_WRITTEN, "note が regular file ではないので書きません: #{visible(note)}") unless st.file?

    check_untracked(root)
    data = File.binread(note).force_encoding(Encoding::UTF_8)
    raise Stop.new("undetermined", EXIT_ERROR, "note を UTF-8 として読めません: #{visible(note)}") unless data.valid_encoding?

    Current.new(data, st.mode & 0o7777, st.ino, st.dev)
  rescue Errno::ENOENT
    # 無い note も、大文字小文字だけ違う名前で tracked なら書かない (大文字小文字を区別しない file system では同じ file になる)。
    check_untracked(root)
    nil
  rescue SystemCallError => e
    raise Stop.new("undetermined", EXIT_ERROR, "note を読めません (#{e.class.name})")
  end

  # `git ls-files --error-unmatch` の exit 1 だけを「追跡なし」とする (0 = tracked、128 など = 判定できない)。`:(icase)` で大文字小文字の
  # 違いも照合し、環境の GIT_LITERAL_PATHSPECS が `:(icase)` を名前として読ませないよう `--no-literal-pathspecs` を付ける
  # (resume の検査と personal-packet と同じ)。
  def check_untracked(root)
    _out, _err, status = Open3.capture3("git", "--no-literal-pathspecs", "ls-files", "--error-unmatch", "--",
                                        ":(icase)#{NOTE}", chdir: root)
    case status.exitstatus
    when 1 then nil
    when 0 then raise Stop.new("tracked", EXIT_NOT_WRITTEN, "note が git で tracked なので書きません")
    else raise Stop.new("undetermined", EXIT_ERROR, "note が git で tracked かを判定できません (git ls-files: exit #{status.exitstatus.inspect})")
    end
  end

  def show_diff(stdout, note, current, proposal)
    stdout.puts "note: #{visible(note)}"
    stdout.puts "note はまだ無いので、新しく作ります。" unless current
    diff = unified_diff(current ? current.content : "", proposal)
    # 行末の CR も見せるため、外すのは改行だけ (chomp は "\n" を渡しても CR LF を外す)。
    diff.each_line { |line| stdout.puts visible(line.delete_suffix("\n")) }
  end

  def unified_diff(old_text, new_text)
    Dir.mktmpdir("context-note-apply") do |tmp|
      old_path = File.join(tmp, "old")
      new_path = File.join(tmp, "new")
      File.binwrite(old_path, old_text)
      File.binwrite(new_path, new_text)
      out, _err, status = Open3.capture3("diff", "-u", "-L", "今の note", "-L", "案", old_path, new_path)
      # diff の exit は 0 = 同じ、1 = 違う、2 = 失敗。ここに来るのは違うときだけ。
      raise Stop.new("undetermined", EXIT_ERROR, "差分を作れません (diff: exit #{status.exitstatus.inspect})") unless status.exitstatus == 1

      out.force_encoding(Encoding::UTF_8).scrub
    end
  rescue SystemCallError => e
    raise Stop.new("undetermined", EXIT_ERROR, "差分を作れません (#{e.class.name})")
  end

  # 端末に出す文字列の、表示で隠れうる文字を <U+XXXX> の形にする。
  def visible(text)
    text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(HIDDEN_RE) { |c| format("<U+%04X>", c.ord) }
  end

  def confirm?(stdin, stdout)
    stdout.print "この差分で note を書き換えますか? [y/N]: "
    answer = stdin.gets
    if answer.nil?
      # EOF は端末に改行を残さないので、後の出力が確認の行につながらないようにする。
      stdout.puts
      return false
    end

    YES.include?(answer.strip.downcase)
  end

  def write_note(note, content, mode)
    tmp = File.join(File.dirname(note), ".#{NOTE}.#{SecureRandom.hex(8)}.tmp")
    begin
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        f.chmod(mode)
        f.write(content)
        f.flush
        f.fsync
      end
      File.rename(tmp, note)
    ensure
      File.unlink(tmp) if File.exist?(tmp) || File.symlink?(tmp)
    end
  rescue SystemCallError => e
    raise Stop.new("write-failed", EXIT_ERROR, "note を書けませんでした (#{e.class.name})。note は前のままです。")
  end
end

exit ContextNoteApply.run(ARGV) if $PROGRAM_NAME == __FILE__
