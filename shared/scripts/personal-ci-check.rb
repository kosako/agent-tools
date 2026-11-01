#!/usr/bin/env ruby
# frozen_string_literal: true

# ci-check: GitHub Actions の workflow の file を決まった規則で検査し、所見を personal-repo-audit と同じ形
# (`findings.schema.json`) の JSON で出す (#541)。AI を使わない。GitHub にも network にも触れず (git で手元の
# commit を読むだけ。partial clone の未取得の object も取りに行かず、replacement ref も当てない)、--window-out の file の
# ほかは何も書かない。
# 運用と規則の正本は docs/ci-check.md。
#
# 対象: 今の directory の git repo の HEAD の commit にある `.github/workflows/` 直下の `*.yml` / `*.yaml` (GitHub が
# workflow として読む場所)。作業ツリーの未 commit の変更は読まない (sweep が監査する commit と揃える)。
#
# 規則 (v1):
# - timeout-missing (debt / medium): job に `timeout-minutes` が無い (値が空のときも無いとみなす)。GitHub の既定は
#   360 分で、止まらなくなった job が 6 時間 runner を使い続ける。reusable workflow を呼ぶ job (`uses:`) は
#   `timeout-minutes` を書けない (GitHub の docs) ので見ず、not_problems に出す (呼ばれる側の file の job で見る)。
# - concurrency-missing (proposal / low): pull_request で起動する workflow に `concurrency` が無い (workflow の top
#   level にも、すべての job にも無い)。取り消してよいかは workflow によるので、判断が要るものとして出す。
#
# 出力に載せる file の名前と job の名前は、規則の形 (SAFE_FILE_RE / JOB_ID_RE) に合うものだけ。repo の中の他の
# 文字列 (`uses:` の値など) は出さない (所見は public な Issue の材料になる)。
#
# run の記録の点検 (`--since` を付けたときだけ。#541): GitHub の API (`gh api`。shell を通さず、env の GH_REPO は渡さ
# ない) で、窓 (since, until] に終わった attempt を読み、次を所見にする。`--since` が無ければ network に触れない。
# - job-timed-out (defect / medium): job が cancelled で、GitHub の annotation「has exceeded the maximum execution
#   time」が付いている。1 回でも所見。
# - flaky-rerun (defect / low): 同じ job が、ある attempt で failure、後の attempt で success。窓の中で 2 回 (2 本の
#   run) 以上なら所見 (原因は断定しない)。1 回は summary に数えるだけ。
# - deprecation-* (debt / low): default branch への push の run (workflow ごとに窓の中の直近 5 本) の annotation に、
#   決まった語 (deprecated・will be removed・will migrate など) がある。annotation の文面は自由文なので出力に載せず、
#   決まった型 (Node.js の版・runner の label の移行) だけを決まった文言にし、ほかは語とリンクだけを出す。
# - それ以外の cancelled の job (concurrency の取り消し、runner を確保できない、など) は summary に数えるだけ。
# 見るのは repo の workflow の file から走る run だけ (Dependabot などの dynamic な run は見ない)。探すのは作成が
# since の 7 日前より後の run (後からのやり直しを拾うため)。API の呼び出しは 1 回の実行で 200 回・120 秒まで。
# 点検に失敗したら (上限・gh の失敗・応答の形の違い)、点検の所見はすべて捨て、scope.not_seen に「run の記録」の行を
# 書いて exit 2 にする (静的な検査の結果は出す)。
#
# exit:
# - 0: 所見なし (workflow の file が無いときを含む)。
# - 1: 所見あり (proposal を含む)。
# - 2: usage / repo を選ぶ git の環境変数を継承している / 今の directory の repo や HEAD を解決できない / 確かめ
#   られない file がある (YAML として読めない、文書が 1 つでない、入れ子が深すぎる、明示の tag がある、key が重なる・
#   merge key を使う、workflow の形でない、symlink などの通常の file でないもの、大きすぎる、名前が規則の外、その file
#   の検査の中の想定外の失敗) / run の記録を確かめられない。確かめられない file があっても、残りの file は確かめて出す
#   (理由は scope.not_seen)。
# 結果は stdout に JSON。run 全体の失敗 (usage・環境変数・repo や HEAD を解決できない・git の失敗・想定外の例外) は
# stdout に何も出さず、stderr に 1 行。

require "date"
require "digest"
require "json"
require "open3"
require "time"
require "yaml"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (file・git の出力) を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module CiCheck
  NAME = "personal-ci-check"
  EXIT_OK = 0
  EXIT_FINDINGS = 1
  EXIT_ERROR = 2

  # repository / index の選び方を変える git の環境変数 (personal-packet と同じ集合)。継承していると、今の directory
  # とは別の repo を読みうる (別の repo の所見を起票しうる) ので、1 つでも在れば (値が空でも) 止める。
  GIT_REPO_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].freeze

  WORKFLOW_DIR = ".github/workflows"
  WORKFLOW_EXT_RE = /\.(?:yml|yaml)\z/.freeze
  # 出力 (fingerprint・場所・Issue の本文) に載せてよい file の名前。外れる file は確かめず、名前も出さない。
  SAFE_FILE_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\.(?:yml|yaml)\z/.freeze
  # GitHub の job の名前の規則 (文字か _ で始まり、英数字と - と _ だけ)。外れる workflow は GitHub も受け付けない。
  JOB_ID_RE = /\A[A-Za-z_][A-Za-z0-9_-]*\z/.freeze
  MAX_FILE_BYTES = 1024 * 1024
  # YAML の collection の入れ子の深さの上限 (DepthGuard)。workflow は 10 段ほどなので余裕を持たせる。
  MAX_DEPTH = 64
  # `git ls-tree -z -l` の 1 entry: <mode> SP <type> SP <oid> SP <size (blob 以外は -)> TAB <name>。
  TREE_ENTRY_RE = /\A(\d{6}) (blob|tree|commit) ([0-9a-f]{40}|[0-9a-f]{64}) +(\d+|-)\t(.+)\z/m.freeze
  REGULAR_MODES = %w[100644 100755].freeze
  SEVERITY_ORDER = %w[high medium low].freeze
  PRESCAN = "未実施 (決まった規則の検査で、下調べは要らない)"

  # ---- run の記録の点検の定数 ----
  # 窓の時刻の書き方 (UTC の秒まで)。GitHub の API の query にそのまま入れるので、形を 1 つに限る。
  TIME_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/.freeze
  REPO_RE = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}.freeze
  # 出力に載せてよい run の path (repo の workflow の file)。外れる run (dynamic な run を含む) は見ない。
  RUN_PATH_RE = %r{\A\.github/workflows/[A-Za-z0-9][A-Za-z0-9._-]*\.(?:yml|yaml)\z}.freeze
  # 出力に載せてよい job の表示名 (matrix の値を含む)。外れる名前は hash で表す。
  SAFE_JOB_NAME_RE = %r{\A[A-Za-z0-9_][A-Za-z0-9 _.()/,:+-]{0,99}\z}.freeze
  MAX_API_CALLS = 200
  MAX_API_SECONDS = 120
  # 期限を過ぎて gh を止めた後、reader の thread が pipe を読み終えるのを待つ時間 (過ぎたら thread を止める)。
  READER_GRACE_SECONDS = 1
  # 窓の始まりより前に作られ、窓の中でやり直された run を拾うために、作成をさかのぼる幅。
  SEARCH_BACK_SECONDS = 7 * 24 * 3600
  # GitHub の run の一覧は、created で絞ると 1000 本までしか返さない。
  MAX_LISTED_RUNS = 1000
  PER_PAGE = 100
  # job を読む run の conclusion (timeout と、やり直しの前の失敗を探す)。やり直した run (attempt が 2 以上) も読む。
  JOB_CONCLUSIONS = %w[cancelled failure timed_out].freeze
  DEPRECATION_RUNS_PER_WORKFLOW = 5
  TIMEOUT_MESSAGE_RE = /has exceeded the maximum execution time/.freeze
  # deprecation の語。出力には語ではなく、決まった表記 (値) を載せる。
  DEPRECATION_WORDS = {
    /deprecat(?:ed|ion|es)/i => "deprecated",
    /will be removed/i => "will be removed",
    /will migrate/i => "will migrate",
    /no longer (?:be )?supported/i => "no longer supported",
    /end[- ]of[- ]life/i => "end of life",
  }.freeze
  # 決まった型の deprecation。捕まえた値は形を限った文字だけ。
  NODE_DEPRECATION_RE = /\bNode\.js (\d{1,3}) (?:is|are) deprecated\b/.freeze
  LABEL_MIGRATION_RE = /\bThe ([a-z0-9][a-z0-9.-]{0,40}) label will migrate\b/.freeze
  ANNOTATION_LEVELS = %w[notice warning failure].freeze
  # scope.seen / scope.not_seen の run の記録の行の接頭辞。人向けの表示で、sweep の判定は --window-out の events で行う
  # (この行の文言には依らない。#580)。
  EVENTS_LABEL = "run の記録"

  # run 全体の失敗 (exit 2、stderr に 1 行)。
  class RunError < StandardError; end
  # 引数の誤り (exit 2、stderr に理由と usage)。
  class UsageError < StandardError; end
  # 1 つの workflow の file を確かめられない (exit 2、scope.not_seen に理由)。
  class FileError < StandardError; end
  # run の記録を確かめられない (exit 2、scope.not_seen の「run の記録」の行に理由。点検の所見は捨てる)。
  class EventError < StandardError; end

  # AST を作る前に、parse の event で collection の入れ子の深さを数え、MAX_DEPTH を超えた時点で打ち切る。libyaml の
  # parse は入れ子の深さに対して二乗の時間がかかり (10 万段で約 18 秒)、safe_load と check_keys! は再帰する
  # (深い入れ子は SystemStackError) ため。
  class DepthGuard < Psych::Handler
    def initialize
      super
      @depth = 0
    end

    def start_sequence(*)
      enter
    end

    def start_mapping(*)
      enter
    end

    def end_sequence
      @depth -= 1
    end

    def end_mapping
      @depth -= 1
    end

    private

    def enter
      @depth += 1
      raise FileError, "入れ子が深すぎる (#{MAX_DEPTH} 段まで)" if @depth > MAX_DEPTH
    end
  end

  # GitHub の API を gh で読む (GET だけ)。呼び出しの回数と時間に上限を置き、超えたら EventError。shell を通さず、
  # env の GH_REPO は渡さない (gh の command ごとに向く repo が分かれないように)。上限の時刻を過ぎた gh は止める。
  class GitHubApi
    attr_reader :calls

    def initialize(dir, deadline)
      @dir = dir
      @deadline = deadline
      @calls = 0
    end

    # gh を起動して stdout を JSON として返す。
    def json(*args)
      raise EventError, "API の呼び出しが上限の #{MAX_API_CALLS} 回を超える" if @calls >= MAX_API_CALLS
      raise EventError, "時間が上限の #{MAX_API_SECONDS} 秒を超える" if Time.now >= @deadline

      @calls += 1
      out, status = run_gh(args)
      raise EventError, "gh が失敗した" unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError
      raise EventError, "gh の出力を JSON として読めない"
    end

    private

    # gh は自分の process group で起動し、出力の pipe の読み終わりと、gh の本体の終わりの両方を期限で見る (gh が
    # 起動した子が pipe を握っていれば、本体が終わっても pipe は閉じない)。gh を回収 (wait) するのは pipe を読み終えた
    # 後だけにする。回収するまで gh の PID と process group の id は再利用されないので、期限を過ぎて abandon が送る
    # signal の先は、必ずこの gh とその group になる (回収済みの PID に signal を送らない)。
    def run_gh(args)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn({ "GH_REPO" => nil }, "gh", *args, chdir: @dir, in: File::NULL, out: out_w, err: err_w,
                                                                  pgroup: true)
      out_w.close
      err_w.close
      readers = [Thread.new { out_r.read }, Thread.new { err_r.read }]
      readers.each { |reader| reader.report_on_exception = false }
      while readers.any?(&:alive?)
        abandon(pid, readers) if Time.now >= @deadline
        sleep 0.05
      end
      status = nil
      until (status = Process.wait2(pid, Process::WNOHANG)&.last)
        abandon(pid, readers) if Time.now >= @deadline
        sleep 0.05
      end
      [readers[0].value, status]
    rescue SystemCallError
      raise EventError, "gh を起動できない"
    ensure
      [out_r, err_r].each { |io| io&.close unless io&.closed? }
    end

    # 期限を過ぎた: まだ回収していない gh の本体と group を止めてから回収し、pipe の EOF (子の終わり) を待たずに reader
    # の thread を止めて回収して、EventError にする。gh の group から別の group に移った子が pipe を握っていても、ここで
    # 待ち続けない (その子は止められない)。
    def abandon(pid, readers)
      [-pid, pid].each do |target|
        Process.kill("KILL", target)
      rescue Errno::ESRCH, Errno::EPERM
        # 止めるものが無い。未回収の gh が自分で終わって zombie になり、group にほかの子がいないと、macOS は group への
        # kill に EPERM を返す (group は自分の gh のもの)。
        nil
      end
      Process.wait(pid)
      readers.each do |reader|
        reader.kill unless reader.join(READER_GRACE_SECONDS)
        begin
          reader.join
        rescue StandardError
          nil # 読みかけで止めた thread の例外は使わない
        end
      end
      raise EventError, "時間が上限の #{MAX_API_SECONDS} 秒を超える"
    end
  end

  module_function

  def usage
    "usage: #{NAME} [--since YYYY-MM-DDTHH:MM:SSZ [--until YYYY-MM-DDTHH:MM:SSZ] [--window-out FILE]] [--help|-h]"
  end

  def help
    <<~TEXT
      #{usage}
      今の directory の git repo の HEAD の commit にある #{WORKFLOW_DIR}/ の workflow を決まった規則で検査し、
      所見を personal-repo-audit の findings.schema.json の形の JSON で stdout に出す。読むだけで、--window-out の
      file のほかは何も書かない。
      規則: job に timeout-minutes が無い (所見) / pull_request で起動する workflow に concurrency が無い (proposal)。
      --since を付けたときだけ、GitHub の API で窓 (since, until] に終わった run の記録も点検する (timeout に当たった
      job / 失敗の後のやり直しで通った job / deprecation の annotation)。--until を省くと今の時刻。時刻は UTC の秒まで。
      --window-out FILE (--since と一緒のときだけ) は、窓と run の記録を確かめたか ({"since","until","events":
      "checked"|"unchecked"}) を、FILE を新しく作って書く (在る FILE には書かない)。
      exit 0 = 所見なし / 1 = 所見あり / 2 = usage・repo を解決できない・確かめられない file か run の記録がある
      (docs/ci-check.md)
    TEXT
  end

  # 戻り値は exit code。
  def main(argv)
    if argv == ["--help"] || argv == ["-h"]
      $stdout.puts help
      return EXIT_OK
    end
    window = parse_window(argv)

    inherited = GIT_REPO_ENV.select { |k| ENV.key?(k) }
    unless inherited.empty?
      raise RunError, "#{inherited.join(' / ')} を継承しているので、今の directory の repo を確かめられません (外して実行してください)"
    end

    report, code, events = check_repo(Dir.pwd, window)
    # 窓の状態は stdout より先に書く (書けなければ stdout を出さずに exit 2。sweep は「CI を確かめられない」にする)。
    write_window_state(window[:out], window, events) if window && window[:out]
    $stdout.puts JSON.pretty_generate(report)
    code
  rescue UsageError => e
    $stderr.puts "#{NAME}: #{e.message}"
    $stderr.puts usage
    EXIT_ERROR
  rescue RunError => e
    $stderr.puts "#{NAME}: #{e.message}"
    EXIT_ERROR
  rescue StandardError, SystemStackError => e
    # 想定外の例外を Ruby の既定 (exit 1 = 所見あり と同じ値) で終わらせない。SystemStackError は StandardError の
    # 外なので並べる。
    $stderr.puts "#{NAME}: 想定外の失敗です (#{e.class})"
    EXIT_ERROR
  end

  # 引数から run の記録の窓 ({since:, until:} の時刻と文字列、out: --window-out の path か nil) を返す。--since が
  # 無ければ nil (点検しない)。
  def parse_window(argv)
    opts = {}
    args = argv.dup
    until args.empty?
      arg = args.shift
      raise UsageError, "unknown argument" unless %w[--since --until --window-out].include?(arg)
      raise UsageError, "#{arg} が 2 回ある" if opts.key?(arg)

      value = args.shift
      if arg == "--window-out"
        raise UsageError, "--window-out の値は空でない path で書く" unless value.is_a?(String) && !value.empty? && !value.start_with?("-")
      else
        raise UsageError, "#{arg} の値は YYYY-MM-DDTHH:MM:SSZ (UTC) で書く" unless value.is_a?(String) && value.match?(TIME_RE)
      end

      opts[arg] = value
    end
    return nil if opts.empty?
    raise UsageError, "--until は --since と一緒に使う" if opts.key?("--until") && !opts.key?("--since")
    raise UsageError, "--window-out は --since と一緒に使う" unless opts.key?("--since")

    since_t = parse_time(opts["--since"])
    until_t = opts.key?("--until") ? parse_time(opts["--until"]) : Time.at(Time.now.to_i).utc
    raise UsageError, "--since は --until より前にする" unless since_t < until_t

    { since: since_t, until: until_t, since_s: format_time(since_t), until_s: format_time(until_t), out: opts["--window-out"] }
  end

  # --window-out の file に、窓と run の記録を確かめたか (events = "checked" | "unchecked") を JSON で書く。sweep は
  # scope の人向けの行ではなく、この値でかけ直しと窓の時刻を進めるかを決める (#580)。file は新しく作る (在る path は
  # symlink を含めて書かない。EEXIST も失敗)。書けなければ RunError (stdout を出さずに exit 2)。
  def write_window_state(path, window, events)
    body = JSON.generate("since" => window[:since_s], "until" => window[:until_s], "events" => events) + "\n"
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(body) }
  rescue SystemCallError => e
    raise RunError, "--window-out の file を書けません (#{e.class})"
  end

  def parse_time(text)
    Time.iso8601(text).utc
  rescue ArgumentError
    raise UsageError, "時刻を解釈できない"
  end

  def format_time(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  # ---- repo ------------------------------------------------------------------------------------

  # 今の directory の repo の HEAD を読み、[report, exit code, events] を返す (events は window があるときだけ、run の
  # 記録を確かめたら "checked"、確かめられなければ "unchecked"。無ければ nil)。git は今の directory で動かす (pathspec を
  # 使わず object を名前で辿り、ls-tree は --full-tree なので、repo の root の path を経由しない)。window があれば
  # run の記録も点検する (失敗したら点検の所見は捨て、scope.not_seen に「run の記録」の行を書く)。
  def check_repo(dir, window = nil)
    commit = git(dir, "rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}").delete_suffix("\n")
    files, unreadable = workflow_entries(dir, commit)

    findings = []
    not_problems = []
    seen = []
    not_seen = unreadable.dup
    files.each do |entry|
      path = "#{WORKFLOW_DIR}/#{entry[:name]}"
      begin
        content = read_blob(dir, entry)
        result = check_workflow(path, content)
      rescue FileError => e
        not_seen << "#{path} (#{e.message})"
        next
      rescue StandardError, SystemStackError => e
        # 1 つの file の想定外の失敗で、残りの file の結果を失わない (確かめられない file にする)。git の失敗
        # (RunError) は repo 全体の問題なので、ここで受けずに run を止める。
        raise if e.is_a?(RunError)

        not_seen << "#{path} (想定外の失敗 (#{e.class}))"
        next
      end
      seen << path
      findings.concat(result[:findings])
      not_problems.concat(result[:not_problems])
    end

    events_summary = nil
    events_state = nil
    unless window.nil?
      range = "#{window[:since_s]}〜#{window[:until_s]}"
      begin
        events = check_events(dir, window)
        findings.concat(events[:findings])
        seen << "#{EVENTS_LABEL} (#{range})"
        events_summary = events[:summary]
        events_state = "checked"
      rescue EventError => e
        not_seen << "#{EVENTS_LABEL} (#{range}。#{e.message})"
        events_state = "unchecked"
      end
    end

    report = build_report(findings, not_problems, seen, not_seen, events_summary)
    code = if not_seen.any? then EXIT_ERROR
           elsif findings.any? then EXIT_FINDINGS
           else EXIT_OK
           end
    [report, code, events_state]
  end

  # `.github/workflows/` の直下の workflow の file の entry と、確かめられない entry の理由を返す。path の階層は
  # pathspec を使わずに 1 段ずつ名前の完全一致で辿る (環境変数で pathspec の解釈が変わらないように)。
  def workflow_entries(dir, commit)
    github = tree_entries(dir, commit).find { |e| e[:name] == ".github" }
    return [[], []] if github.nil?
    return [[], [".github (directory でない)"]] unless github[:type] == "tree"

    workflows = tree_entries(dir, github[:oid]).find { |e| e[:name] == "workflows" }
    return [[], []] if workflows.nil?
    return [[], ["#{WORKFLOW_DIR} (directory でない)"]] unless workflows[:type] == "tree"

    files = []
    unreadable = []
    tree_entries(dir, workflows[:oid]).each do |e|
      # subdirectory は GitHub も workflow として読まないので、名前によらず見ない (`archive.yml/` も)。
      next if e[:type] == "tree"
      next unless e[:name].match?(WORKFLOW_EXT_RE)

      unless e[:name].match?(SAFE_FILE_RE)
        unreadable << "#{WORKFLOW_DIR}/ の file 1 つ (名前に規則の外の文字を含むので、名前を出さない)"
        next
      end
      path = "#{WORKFLOW_DIR}/#{e[:name]}"
      if e[:type] != "blob" || !REGULAR_MODES.include?(e[:mode])
        unreadable << "#{path} (通常の file でない)"
      elsif e[:size] > MAX_FILE_BYTES
        unreadable << "#{path} (#{MAX_FILE_BYTES} byte を超える)"
      else
        files << e
      end
    end
    [files.sort_by { |e| e[:name] }, unreadable]
  end

  # `--full-tree`: subdirectory で起動しても、その directory に絞らずに tree の直下を出させる。
  def tree_entries(dir, treeish)
    out = git(dir, "ls-tree", "--full-tree", "-z", "-l", "--end-of-options", treeish)
    out.split("\0").map do |raw|
      m = TREE_ENTRY_RE.match(raw)
      raise RunError, "git ls-tree の出力を解釈できません" if m.nil?

      { mode: m[1], type: m[2], oid: m[3], size: m[4] == "-" ? nil : m[4].to_i, name: m[5] }
    end
  end

  def read_blob(dir, entry)
    content = git(dir, "cat-file", "blob", entry[:oid]).dup.force_encoding(Encoding::UTF_8)
    raise FileError, "UTF-8 として読めない" unless content.valid_encoding?

    content
  end

  # `--no-lazy-fetch`: partial clone で object が手元に無くても、promisor の remote から取りに行かない (network に
  # 触れず、object database に書かない)。無い object は git の失敗 (exit 2) になる。
  # `--no-replace-objects`: `refs/replace/` の replacement ref を当てない (HEAD や blob を別の object に置き換えた
  # ref があっても、HEAD の実体を読む)。
  def git(dir, *args)
    out, _err, status = Open3.capture3("git", "--no-lazy-fetch", "--no-replace-objects", *args, chdir: dir, binmode: true)
    unless status.success?
      raise RunError, "git #{args.first} が失敗しました (今の directory が git repo で、HEAD に commit があり、" \
                      "その object が手元にある (partial clone で取得していないものでない) か確かめてください)"
    end

    out
  rescue SystemCallError => e
    raise RunError, "git を起動できません (#{e.class})"
  end

  # ---- workflow --------------------------------------------------------------------------------

  # 1 つの workflow の file を確かめ、{findings:, not_problems:} を返す (所見の id は build_report が振る)。
  # 確かめられないときは FileError。
  def check_workflow(path, content)
    root, doc = load_yaml(content, path)
    raise FileError, "top level が mapping でない" unless doc.is_a?(Hash)

    jobs = doc["jobs"]
    raise FileError, "jobs が mapping でない" unless jobs.is_a?(Hash) && !jobs.empty?

    jobs.each do |id, job|
      raise FileError, "job の名前が規則の外" unless id.is_a?(String) && id.match?(JOB_ID_RE)
      raise FileError, "job `#{id}` が mapping でない" unless job.is_a?(Hash)
    end
    events = trigger_events(doc)
    lines = job_lines(root)

    findings = []
    not_problems = []
    jobs.each do |id, job|
      location = lines.key?(id) ? "#{path}:#{lines[id]}" : path
      if job.key?("uses")
        not_problems << reusable_caller(location, id)
      elsif job["timeout-minutes"].nil?
        findings << timeout_missing(path, location, id)
      end
    end
    if events.include?("pull_request") && !concurrency?(doc, jobs)
      findings << concurrency_missing(path)
    end
    { findings: findings, not_problems: not_problems }
  end

  # 1 つの文書だけを読み、[AST の root, load した値] を返す。最初に event の parser で入れ子の深さを確かめ
  # (DepthGuard)、次に stream 全体を AST に parse して文書が 1 つであることを求める (safe_load は stream の先頭の
  # 文書しか読まない)。safe_load の前に AST の形 (check_ast!) を、後に書かれた key と load 後の key の対応
  # (check_keys!) を確かめる。anchor と alias は GitHub が workflow で受け付けるので許す。値の型は Date / Time まで
  # (日付の literal)。
  def load_yaml(content, path)
    Psych::Parser.new(DepthGuard.new).parse(content, path)
    documents = Psych.parse_stream(content, filename: path).children
    raise FileError, "YAML の文書が 1 つでない" unless documents.size == 1

    root = documents.first.root
    check_ast!(root)
    doc = if Psych::VERSION.split(".").first.to_i >= 4
            YAML.safe_load(content, permitted_classes: [Date, Time], aliases: true, filename: path)
          else
            YAML.safe_load(content, [Date, Time], [], true, path)
          end
    check_keys!(root, doc)
    [root, doc]
  rescue Psych::Exception, ArgumentError => e
    raise FileError, "YAML として読めない (#{e.class})"
  end

  # safe_load の前に AST を反復で辿り (入れ子の深さは DepthGuard が済ませている)、次を確かめる。load の前に見るのは、
  # psych の版で safe_load の失敗の仕方が違っても同じ理由で止まるように、また load そのものの処理量を抑えるため。
  # - 明示の tag が無い。tag は値の型や構造を変える (`!!omap` の sequence は mapping に読まれ、重なった key が後の
  #   値で上書きされる) ので、どこにあっても読まない。
  # - mapping の key が scalar で、merge key (`<<`) でない。alias や collection の key は、load で Hash に入れるときに
  #   hash を計算する。alias で共有した配列を重ねると、浅く小さい file のままその計算が指数的に増える。merge key は
  #   load 後の key の並びが書かれた順と揃わない。
  def check_ast!(root)
    stack = [root]
    until stack.empty?
      node = stack.pop
      raise FileError, "明示の tag は読まない" if node.respond_to?(:tag) && node.tag

      if node.is_a?(Psych::Nodes::Mapping)
        node.children.each_slice(2) do |key, _child|
          raise FileError, "mapping の key が scalar でない" unless key.is_a?(Psych::Nodes::Scalar)
          raise FileError, "merge key (<<) は読まない" if key.value == "<<"
        end
      end
      node.children&.each { |child| stack.push(child) }
    end
  end

  # AST と load した値を並べて辿り、どの mapping でも、書かれた key と load 後の key が 1 対 1 であることを
  # 確かめる (scripts/lib/yaml_util.rb の check_tree! と同じ考え方。配布する script は単体の file なので写す)。
  # 同じ key を 2 度書くと safe_load は後の値で黙って上書きし、plain の key は YAML の解決で衝突する (`on` と
  # `true` はどちらも true) ので、そのまま読むと GitHub と違う値を見うる。key が scalar で merge key でないことは
  # check_ast! が load の前に確かめている。alias は定義の側で辿る。
  def check_keys!(node, value)
    case node
    when Psych::Nodes::Mapping
      pairs = node.children.each_slice(2).to_a
      seen = {}
      pairs.each do |key, _child|
        raise FileError, "key が重なる" if seen.key?(key.value)

        seen[key.value] = true
      end
      raise FileError, "key が YAML の解決で重なる" unless value.is_a?(Hash) && value.size == pairs.size

      # 重なりが無いので、load 後の値は書かれた順に並ぶ (Hash は挿入順)。values は 1 度だけ作る。
      values = value.values
      pairs.each_with_index { |(_key, child), i| check_keys!(child, values[i]) }
    when Psych::Nodes::Sequence
      # tag を拒んでいるので、sequence は同じ件数の Array に読まれる (yaml_util と同じく、崩れたら止める)。
      raise FileError, "sequence が書かれたとおりに読めない" unless value.is_a?(Array) && value.size == node.children.size

      node.children.each_with_index { |child, i| check_keys!(child, value[i]) }
    end
  end

  # `on` の event の名前の配列。YAML 1.1 の規則で key の `on` は true に読まれるので、両方を見る。
  def trigger_events(doc)
    raise FileError, "on が 2 つある" if doc.key?("on") && doc.key?(true)

    on = doc.key?("on") ? doc["on"] : doc[true]
    case on
    when String then [on]
    when Array
      raise FileError, "on の event が文字列でない" unless on.all? { |e| e.is_a?(String) }

      on
    when Hash
      raise FileError, "on の event が文字列でない" unless on.keys.all? { |e| e.is_a?(String) }

      on.keys
    else
      raise FileError, "on が無い"
    end
  end

  def concurrency?(doc, jobs)
    !doc["concurrency"].nil? || jobs.values.all? { |job| !job["concurrency"].nil? }
  end

  # job の名前 => 行 (1 始まり)。`jobs` の mapping の key の行を AST から読む。見つからない job は含めない。
  def job_lines(root)
    jobs_node = mapping_value(root, "jobs")
    return {} unless jobs_node.is_a?(Psych::Nodes::Mapping)

    jobs_node.children.each_slice(2).each_with_object({}) do |(key, _value), lines|
      lines[key.value] = key.start_line + 1 if key.is_a?(Psych::Nodes::Scalar)
    end
  end

  def mapping_value(node, name)
    return nil unless node.is_a?(Psych::Nodes::Mapping)

    pair = node.children.each_slice(2).find { |key, _value| key.is_a?(Psych::Nodes::Scalar) && key.value == name }
    pair&.last
  end

  # ---- run の記録 ------------------------------------------------------------------------------

  # 窓の run の記録を GitHub の API で読んで点検し、{findings:, summary:} を返す。確かめられないときは EventError
  # (点検の所見は返さない)。
  def check_events(dir, window)
    api = GitHubApi.new(dir, Time.now + MAX_API_SECONDS)
    repo, default_branch = resolve_github_repo(api)
    data = collect_events(api, repo, default_branch, window)
    result = evaluate_events(repo, default_branch, window, data)
    summary = "#{result[:summary]}、API の呼び出し #{api.calls} 回"
    summary += "、名前が規則の外の workflow の run #{data[:skipped]} 本は見ていない" if data[:skipped].positive?
    { findings: result[:findings], summary: summary }
  end

  def resolve_github_repo(api)
    info = api.json("repo", "view", "--json", "nameWithOwner,defaultBranchRef")
    repo = info.is_a?(Hash) ? info["nameWithOwner"] : nil
    ref = info.is_a?(Hash) ? info["defaultBranchRef"] : nil
    branch = ref.is_a?(Hash) ? ref["name"] : nil
    unless repo.is_a?(String) && repo.match?(REPO_RE) && branch.is_a?(String) && !branch.empty?
      raise EventError, "今の repo の GitHub の repo か default branch を解決できない"
    end

    [repo, branch]
  end

  # 点検に要る run・job・annotation だけを読み、{runs:, jobs:, annotations:, skipped:} を返す。jobs は run id => job の
  # 配列 (全 attempt)、annotations は job id => annotation の配列。読む対象の選び方は evaluate_events と同じ述語。
  def collect_events(api, repo, default_branch, window)
    from = format_time(window[:since] - SEARCH_BACK_SECONDS)
    listed = list_runs(api, repo, from, window[:until_s])
    runs = listed.select { |r| workflow_run?(r) }
    skipped = listed.count { |r| r["path"].is_a?(String) && r["path"].start_with?("#{WORKFLOW_DIR}/") && !workflow_run?(r) }

    jobs = {}
    runs.each { |run| jobs[run["id"]] = list_jobs(api, repo, run["id"]) if job_run?(run) }
    deprecation = deprecation_runs(runs, default_branch, window)
    deprecation.each { |run| jobs[run["id"]] ||= list_jobs(api, repo, run["id"]) }

    annotations = {}
    jobs.each do |run_id, run_jobs|
      run_jobs.each do |job|
        next if annotations.key?(job["id"])
        next unless timeout_candidate?(job, window)

        annotations[job["id"]] = list_annotations(api, repo, job["id"])
      end
    end
    deprecation.each do |run|
      latest_attempt_jobs(run, jobs.fetch(run["id"])).each do |job|
        annotations[job["id"]] ||= list_annotations(api, repo, job["id"])
      end
    end
    { runs: runs, jobs: jobs, annotations: annotations, skipped: skipped }
  end

  # 作成が [from, until] の run (窓の後に作られた run は窓の中に終われないので、API の側で除く)。
  def list_runs(api, repo, from, until_s)
    runs = paged(api, "repos/#{repo}/actions/runs?created=#{from}..#{until_s}", "workflow_runs", "run") do |total|
      raise EventError, "run が多すぎて一覧で読み切れない (#{MAX_LISTED_RUNS} 本まで)" if total > MAX_LISTED_RUNS
    end
    runs.map { |run| valid_run!(run) }
  end

  def list_jobs(api, repo, run_id)
    paged(api, "repos/#{repo}/actions/runs/#{run_id}/jobs?filter=all", "jobs", "job").map { |job| valid_job!(job) }
  end

  # total_count を持つ一覧を全 page 読む。取った件数が total_count と合わなければ (短い応答・重なり) 確かめられない
  # (不完全な一覧から 所見なし と判断しない)。最初の page の total_count を block に渡す。
  def paged(api, path, key, what)
    items = []
    total = nil
    page = 1
    loop do
      body = api.json("api", "#{path}&per_page=#{PER_PAGE}&page=#{page}")
      count = body.is_a?(Hash) ? body["total_count"] : nil
      list = body.is_a?(Hash) ? body[key] : nil
      raise EventError, "#{what} の一覧の応答の形が想定と違う" unless count.is_a?(Integer) && list.is_a?(Array)

      if total.nil?
        total = count
        yield total if block_given?
      end
      raise EventError, "#{what} の一覧が読む間に変わった" unless count == total

      items.concat(list)
      # PER_PAGE 未満の page は最後の page。件数の突き合わせは loop の後で行う。
      break if list.size < PER_PAGE || items.size >= total

      page += 1
    end
    ids = items.map { |item| item.is_a?(Hash) ? item["id"] : nil }
    unless items.size == total && ids.uniq.size == ids.size
      raise EventError, "#{what} の一覧が total_count と合わない (#{items.size} / #{total})"
    end

    items
  end

  def list_annotations(api, repo, job_id)
    annotations = []
    page = 1
    loop do
      list = api.json("api", "repos/#{repo}/check-runs/#{job_id}/annotations?per_page=#{PER_PAGE}&page=#{page}")
      raise EventError, "annotation の応答の形が想定と違う" unless list.is_a?(Array)

      list.each do |a|
        unless a.is_a?(Hash) && a["annotation_level"].is_a?(String) && a["message"].is_a?(String)
          raise EventError, "annotation の応答の形が想定と違う"
        end

        annotations << a
      end
      break if list.size < PER_PAGE

      page += 1
    end
    annotations
  end

  # 判定に使う field の型を確かめる (欠けや型の違いを 所見なし に倒さない)。key の欠けは、正当な null (終わって
  # いない run や job の conclusion など) と区別して、確かめられないにする。終わった run と job は、conclusion (job は
  # completed_at も) が要る。
  def valid_run!(run)
    ok = run.is_a?(Hash) && %w[id path event status conclusion run_attempt head_branch updated_at].all? { |k| run.key?(k) } &&
         run["id"].is_a?(Integer) && (run["path"].nil? || run["path"].is_a?(String)) &&
         run["event"].is_a?(String) && run["status"].is_a?(String) &&
         (run["conclusion"].is_a?(String) || (run["conclusion"].nil? && run["status"] != "completed")) &&
         run["run_attempt"].is_a?(Integer) && run["run_attempt"] >= 1 &&
         (run["head_branch"].nil? || run["head_branch"].is_a?(String)) && run["updated_at"].is_a?(String)
    raise EventError, "run の応答の形が想定と違う" unless ok

    time_of(run["updated_at"])
    run
  end

  def valid_job!(job)
    ok = job.is_a?(Hash) && %w[id run_attempt name status conclusion completed_at].all? { |k| job.key?(k) } &&
         job["id"].is_a?(Integer) && job["run_attempt"].is_a?(Integer) &&
         job["name"].is_a?(String) && job["status"].is_a?(String) &&
         (job["status"] == "completed" ? job["conclusion"].is_a?(String) && job["completed_at"].is_a?(String)
                                       : (job["conclusion"].nil? || job["conclusion"].is_a?(String)) &&
                                         (job["completed_at"].nil? || job["completed_at"].is_a?(String)))
    raise EventError, "job の応答の形が想定と違う" unless ok

    time_of(job["completed_at"]) unless job["completed_at"].nil?
    job
  end

  def time_of(value)
    Time.iso8601(value).utc
  rescue ArgumentError
    raise EventError, "応答の時刻を解釈できない"
  end

  # 窓は (since, until]。前の窓の終わりちょうどに終わった attempt を二重に数えない。
  def in_window?(value, window)
    return false if value.nil?

    t = time_of(value)
    t > window[:since] && t <= window[:until]
  end

  # repo の workflow の file から走る run (Dependabot などの dynamic な run と、名前が規則の外の file を除く)。
  def workflow_run?(run)
    run["path"].is_a?(String) && run["path"].match?(RUN_PATH_RE)
  end

  # job を読む run: やり直した run、timeout や失敗の候補を含む run、まだ終わっていない run。窓は job の終わった時刻で
  # 切るので、点検の時点で走っている run の中で窓の中に終わった job (timeout など) は今の窓で見る (次の窓では、その
  # job は since より前に終わっているので見えない)。
  def job_run?(run)
    run["run_attempt"] >= 2 || JOB_CONCLUSIONS.include?(run["conclusion"]) || run["status"] != "completed"
  end

  def timeout_candidate?(job, window)
    job["status"] == "completed" && job["conclusion"] == "cancelled" && in_window?(job["completed_at"], window)
  end

  # deprecation を見る run: default branch への push の run で、窓の中に終わったもの。workflow ごとに直近の数本。
  def deprecation_runs(runs, default_branch, window)
    candidates = runs.select do |r|
      r["event"] == "push" && r["head_branch"] == default_branch && r["status"] == "completed" &&
        in_window?(r["updated_at"], window)
    end
    candidates.group_by { |r| r["path"] }.values.flat_map do |list|
      list.sort_by { |r| [time_of(r["updated_at"]), r["id"]] }.last(DEPRECATION_RUNS_PER_WORKFLOW)
    end
  end

  def latest_attempt_jobs(run, jobs)
    jobs.select { |j| j["run_attempt"] == run["run_attempt"] }
  end

  # 読んだ run の記録を点検する (network に触れない)。{findings:, summary:} を返す。
  def evaluate_events(repo, default_branch, window, data)
    runs_by_id = data[:runs].each_with_object({}) { |r, h| h[r["id"]] = r }
    timeouts = Hash.new { |h, k| h[k] = [] }
    flaky = Hash.new { |h, k| h[k] = [] }
    other_cancelled = 0
    data[:jobs].each do |run_id, jobs|
      path = runs_by_id.fetch(run_id)["path"]
      jobs.each do |job|
        next unless timeout_candidate?(job, window)

        annotations = data[:annotations][job["id"]]
        raise EventError, "cancelled の job の annotation を読めていない" if annotations.nil?

        if annotations.any? { |a| a["annotation_level"] == "failure" && a["message"].match?(TIMEOUT_MESSAGE_RE) }
          timeouts[[path, job["name"]]] << job_url(repo, run_id, job["id"])
        else
          other_cancelled += 1
        end
      end
      jobs.group_by { |j| j["name"] }.each do |name, same|
        failed = same.select { |j| j["conclusion"] == "failure" }.map { |j| j["run_attempt"] }
        next if failed.empty?

        passed = same.find do |j|
          j["conclusion"] == "success" && failed.any? { |a| j["run_attempt"] > a } && in_window?(j["completed_at"], window)
        end
        flaky[[path, name]] << job_url(repo, run_id, passed["id"]) unless passed.nil?
      end
    end

    deprecations = {}
    deprecation_runs(data[:runs], default_branch, window).each do |run|
      latest_attempt_jobs(run, data[:jobs].fetch(run["id"])).each do |job|
        annotations = data[:annotations][job["id"]]
        raise EventError, "deprecation を見る job の annotation を読めていない" if annotations.nil?

        annotations.each do |a|
          word = deprecation_word(a["message"])
          next if word.nil?

          key, label = deprecation_kind(a["message"], word)
          entry = (deprecations[[run["path"], key]] ||= { label: label, levels: [], urls: [] })
          entry[:levels] |= [ANNOTATION_LEVELS.include?(a["annotation_level"]) ? a["annotation_level"] : "不明"]
          url = job_url(repo, run["id"], job["id"])
          entry[:urls] |= [url]
        end
      end
    end

    range = "#{window[:since_s]}〜#{window[:until_s]}"
    findings = []
    timeouts.each { |(path, name), urls| findings << job_timed_out_finding(path, name, urls, range) }
    flaky.each { |(path, name), urls| findings << flaky_rerun_finding(path, name, urls, range) if urls.size >= 2 }
    deprecations.each { |(path, key), entry| findings << deprecation_finding(path, key, entry, range) }

    finished = data[:runs].count { |r| r["status"] == "completed" && in_window?(r["updated_at"], window) }
    reruns = flaky.values.sum(&:size)
    single = flaky.values.count { |urls| urls.size == 1 }
    summary = "#{EVENTS_LABEL} (#{range}): 窓の中に終わった run #{finished} 本、timeout に当たった job #{timeouts.values.sum(&:size)} 回、" \
              "失敗の後のやり直しで通った job #{reruns} 回 (同じ job で 2 回以上を所見にし、1 回だけの job #{single} 件は数えるだけ)、" \
              "それ以外の cancelled の job #{other_cancelled} 回、deprecation の annotation #{deprecations.size} 種類"
    { findings: findings, summary: summary }
  end

  def deprecation_word(message)
    DEPRECATION_WORDS.each { |re, word| return word if message.match?(re) }
    nil
  end

  # deprecation の種類の key (fingerprint の topic) と、出力に載せる決まった文言。annotation の文面は載せない。
  def deprecation_kind(message, word)
    if (m = NODE_DEPRECATION_RE.match(message))
      ["node-#{m[1]}", "Node.js #{m[1]} の deprecation の予告"]
    elsif (m = LABEL_MIGRATION_RE.match(message))
      ["runner-label-#{digest_slug(m[1])}", "runner の label `#{m[1]}` の移行の予告"]
    else
      ["annotation-#{short_hash(message.downcase.gsub(/\s+/, ' ').strip)}", "deprecation を示す語 (#{word}) を含む annotation"]
    end
  end

  def job_url(repo, run_id, job_id)
    "https://github.com/#{repo}/actions/runs/#{run_id}/job/#{job_id}"
  end

  # job の表示名と fingerprint の slug。規則の外の名前は出さず、hash で表す。
  def job_label(name)
    return ["(名前は規則の外。#{short_hash(name)})", "job-#{short_hash(name)}"] unless name.match?(SAFE_JOB_NAME_RE)

    [name, digest_slug(name)]
  end

  # fingerprint に使う slug。元の文字列を小文字の kebab-case にし、必ず元の文字列の hash (6 文字) を添える。変換は
  # 情報を落とす (`test (a.b)` と `test (a-b)`、`ubuntu-24.04` と `ubuntu-24-04`) ので、hash を添える経路と添えない経路を
  # 混ぜると、ある名前の slug が別の名前そのものとぶつかる。kebab が空なら `job-<hash 8 文字>` (最後の区切りの後が 8 文字
  # なので、6 文字の形とはぶつからない)。
  def digest_slug(text)
    kebab = text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    kebab.empty? ? "job-#{short_hash(text)}" : "#{kebab}-#{short_hash(text)[0, 6]}"
  end

  def short_hash(text)
    Digest::SHA256.hexdigest(text)[0, 8]
  end

  # ---- 所見 ------------------------------------------------------------------------------------

  def timeout_missing(path, location, id)
    {
      "fingerprint" => "#{path}@#{id}#timeout-missing",
      "dimension" => "ci",
      "kind" => "debt",
      "severity" => "medium",
      "confidence" => "確証",
      "locations" => [location],
      "claim" => "job `#{id}` に timeout-minutes が無い。",
      "evidence" => "#{path} の jobs.#{id} に timeout-minutes が無い (値が空のときも無いとみなす)。",
      "impact" => "job が止まらなくなると、GitHub の既定の 360 分まで runner を使い続ける (private の repo では実行時間の枠を使い、同時実行の枠を他の job と取り合う)。",
      "recommendation" => "jobs.#{id} に timeout-minutes を足す (目安は普段の実行時間の 2〜3 倍)。",
      "needs_decision" => false,
      "decision_reason" => "",
    }
  end

  def concurrency_missing(path)
    {
      "fingerprint" => "#{path}#concurrency-missing",
      "dimension" => "ci",
      "kind" => "proposal",
      "severity" => "low",
      "confidence" => "確証",
      "locations" => [path],
      "claim" => "pull_request で起動する workflow に concurrency が無い。",
      "evidence" => "#{path} は on に pull_request を持ち、workflow の top level にも、すべての job にも concurrency が無い。",
      "impact" => "同じ PR に続けて push すると、古い commit の run も最後まで走り、runner の枠を使って新しい run を待たせる。",
      "recommendation" => "workflow の top level に concurrency を足す (例: group を workflow と ref で作り、pull_request のときだけ cancel-in-progress を true にする)。",
      "needs_decision" => true,
      "decision_reason" => "取り消してよいかは workflow による (検証だけの CI は取り消してよいが、release や deploy は途中で止めると困る)。",
    }
  end

  def reusable_caller(location, id)
    {
      "location" => location,
      "apparent_issue" => "job `#{id}` に timeout-minutes が無い",
      "reason" => "reusable workflow を呼ぶ job (uses) には timeout-minutes を書けない (GitHub の docs)。呼ばれる側の workflow の job で見る (呼ばれる側が repo の外なら、この検査では見ない)。",
    }
  end

  # run の記録の所見の根拠に載せる link (多くても 3 本)。
  def links(urls)
    shown = urls.first(3).join(" ")
    urls.size > 3 ? "#{shown} ほか #{urls.size - 3} 件" : shown
  end

  def job_timed_out_finding(path, name, urls, range)
    display, slug = job_label(name)
    {
      "fingerprint" => "#{path}@#{slug}#job-timed-out",
      "dimension" => "ci",
      "kind" => "defect",
      "severity" => "medium",
      "confidence" => "確証",
      "locations" => [path],
      "claim" => "job `#{display}` が timeout-minutes に当たって止まった (#{urls.size} 回)。",
      "evidence" => "#{range} に終わった #{path} の run で、job が cancelled になり、GitHub の annotation「has exceeded the maximum execution time」が付いていた: #{links(urls)}",
      "impact" => "job が止まらなくなっているか、普段より遅くなっている。timeout まで runner を使い、結果が出ない。",
      "recommendation" => "その run の log で止まった step を確かめ、hang を直すか、遅くなった理由を調べる (timeout-minutes を延ばすのは理由が分かってから)。",
      "needs_decision" => false,
      "decision_reason" => "",
    }
  end

  def flaky_rerun_finding(path, name, urls, range)
    display, slug = job_label(name)
    {
      "fingerprint" => "#{path}@#{slug}#flaky-rerun",
      "dimension" => "ci",
      "kind" => "defect",
      "severity" => "low",
      "confidence" => "有力",
      "locations" => [path],
      "claim" => "job `#{display}` が、失敗の後のやり直しで通ったことが #{urls.size} 回ある (不安定な job の候補)。",
      "evidence" => "#{range} に終わった #{path} の run で、同じ job がある attempt で failure、後の attempt で success だった (通った attempt): #{links(urls)}",
      "impact" => "結果が実行ごとに揺れると本当の失敗を見落としやすく、やり直しの分だけ runner を使う。原因 (test・外部の依存・runner) は断定していない。",
      "recommendation" => "失敗した attempt の log で落ちた step を比べ、揺れの原因を調べる。",
      "needs_decision" => false,
      "decision_reason" => "",
    }
  end

  def deprecation_finding(path, key, entry, range)
    {
      "fingerprint" => "#{path}#deprecation-#{key}",
      "dimension" => "ci",
      "kind" => "debt",
      "severity" => "low",
      "confidence" => "有力",
      "locations" => [path],
      "claim" => "#{path} の run に、#{entry[:label]}がある (#{entry[:levels].join(' / ')})。",
      "evidence" => "#{range} に default branch への push で終わった run (workflow ごとに直近 #{DEPRECATION_RUNS_PER_WORKFLOW} 本まで) の annotation から、決まった語で判定した。文面は自由文なのでここに載せない (link 先で読む): #{links(entry[:urls])}",
      "impact" => "予告の期限が来ると、workflow が動かなくなるか、挙動が変わる。",
      "recommendation" => "link 先の annotation の文面で対象 (actions・runner の label など) を確かめ、版や設定を上げる。",
      "needs_decision" => false,
      "decision_reason" => "",
    }
  end

  # ---- 報告 ------------------------------------------------------------------------------------

  def build_report(findings, not_problems, seen, not_seen, events_summary = nil)
    sorted = findings.sort_by { |f| [SEVERITY_ORDER.index(f["severity"]), f["fingerprint"]] }
    numbered = sorted.each_with_index.map { |f, i| { "id" => format("F%02d", i + 1) }.merge(f) }
    decisions = numbered.select { |f| f["needs_decision"] }.map do |f|
      { "finding_id" => f["id"], "question" => f["decision_reason"] }
    end
    {
      "summary" => summary(numbered, seen, not_seen, events_summary),
      "findings" => numbered,
      "not_problems" => not_problems,
      "decisions" => decisions,
      "scope" => {
        "seen" => seen,
        "partial" => [],
        "not_seen" => not_seen,
        "uncommitted" => "なし",
        "prescan" => PRESCAN,
      },
    }
  end

  def summary(findings, seen, not_seen, events_summary)
    file_seen = seen.count { |s| !s.start_with?(EVENTS_LABEL) }
    file_not_seen = not_seen.count { |s| !s.start_with?(EVENTS_LABEL) }
    counts = SEVERITY_ORDER.map { |s| "#{s} #{findings.count { |f| f['severity'] == s }}" }.join(" / ")
    decide = findings.count { |f| f["needs_decision"] }
    text = if file_seen.zero? && file_not_seen.zero?
             "HEAD の commit に workflow の file (#{WORKFLOW_DIR}/*.yml / *.yaml) が無い"
           else
             "HEAD の commit の workflow の file を #{file_seen} 本確かめた"
           end
    text += "。所見: #{counts} (判断が要る #{decide})"
    text += "。確かめられない file が #{file_not_seen} 件ある (scope.not_seen)" if file_not_seen.positive?
    text += "。#{events_summary}" unless events_summary.nil?
    text += "。run の記録を確かめられない (scope.not_seen)" if not_seen.any? { |s| s.start_with?(EVENTS_LABEL) }
    text
  end
end

exit CiCheck.main(ARGV) if $PROGRAM_NAME == __FILE__
