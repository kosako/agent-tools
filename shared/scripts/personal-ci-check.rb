#!/usr/bin/env ruby
# frozen_string_literal: true

# ci-check: GitHub Actions の workflow の file を決まった規則で検査し、所見を personal-repo-audit と同じ形
# (`findings.schema.json`) の JSON で出す (#541)。AI を使わない。GitHub にも network にも触れず (git で手元の
# commit を読むだけ。partial clone の未取得の object も取りに行かず、replacement ref も当てない)、何も書かない。
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
# exit:
# - 0: 所見なし (workflow の file が無いときを含む)。
# - 1: 所見あり (proposal を含む)。
# - 2: usage / repo を選ぶ git の環境変数を継承している / 今の directory の repo や HEAD を解決できない / 確かめ
#   られない file がある (YAML として読めない、文書が 1 つでない、入れ子が深すぎる、明示の tag がある、key が重なる・
#   merge key を使う、workflow の形でない、symlink などの通常の file でないもの、大きすぎる、名前が規則の外、その file
#   の検査の中の想定外の失敗)。確かめられない file があっても、残りの file は確かめて出す (理由は scope.not_seen)。
# 結果は stdout に JSON。run 全体の失敗 (usage・環境変数・repo や HEAD を解決できない・git の失敗・想定外の例外) は
# stdout に何も出さず、stderr に 1 行。

require "date"
require "json"
require "open3"
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

  # run 全体の失敗 (exit 2、stderr に 1 行)。
  class RunError < StandardError; end
  # 1 つの workflow の file を確かめられない (exit 2、scope.not_seen に理由)。
  class FileError < StandardError; end

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

  module_function

  def usage
    "usage: #{NAME} [--help|-h]"
  end

  def help
    <<~TEXT
      #{usage}
      今の directory の git repo の HEAD の commit にある #{WORKFLOW_DIR}/ の workflow を決まった規則で検査し、
      所見を personal-repo-audit の findings.schema.json の形の JSON で stdout に出す。読むだけで、何も書かない。
      規則: job に timeout-minutes が無い (所見) / pull_request で起動する workflow に concurrency が無い (proposal)。
      exit 0 = 所見なし / 1 = 所見あり / 2 = usage・repo を解決できない・確かめられない file がある (docs/ci-check.md)
    TEXT
  end

  # 戻り値は exit code。
  def main(argv)
    if argv == ["--help"] || argv == ["-h"]
      $stdout.puts help
      return EXIT_OK
    end
    unless argv.empty?
      $stderr.puts "#{NAME}: unknown argument"
      $stderr.puts usage
      return EXIT_ERROR
    end

    inherited = GIT_REPO_ENV.select { |k| ENV.key?(k) }
    unless inherited.empty?
      raise RunError, "#{inherited.join(' / ')} を継承しているので、今の directory の repo を確かめられません (外して実行してください)"
    end

    report, code = check_repo(Dir.pwd)
    $stdout.puts JSON.pretty_generate(report)
    code
  rescue RunError => e
    $stderr.puts "#{NAME}: #{e.message}"
    EXIT_ERROR
  rescue StandardError, SystemStackError => e
    # 想定外の例外を Ruby の既定 (exit 1 = 所見あり と同じ値) で終わらせない。SystemStackError は StandardError の
    # 外なので並べる。
    $stderr.puts "#{NAME}: 想定外の失敗です (#{e.class})"
    EXIT_ERROR
  end

  # ---- repo ------------------------------------------------------------------------------------

  # 今の directory の repo の HEAD を読み、[report, exit code] を返す。git は今の directory で動かす (pathspec を
  # 使わず object を名前で辿り、ls-tree は --full-tree なので、repo の root の path を経由しない)。
  def check_repo(dir)
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

    report = build_report(findings, not_problems, seen, not_seen)
    code = if not_seen.any? then EXIT_ERROR
           elsif findings.any? then EXIT_FINDINGS
           else EXIT_OK
           end
    [report, code]
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

  # ---- 報告 ------------------------------------------------------------------------------------

  def build_report(findings, not_problems, seen, not_seen)
    sorted = findings.sort_by { |f| [SEVERITY_ORDER.index(f["severity"]), f["fingerprint"]] }
    numbered = sorted.each_with_index.map { |f, i| { "id" => format("F%02d", i + 1) }.merge(f) }
    decisions = numbered.select { |f| f["needs_decision"] }.map do |f|
      { "finding_id" => f["id"], "question" => f["decision_reason"] }
    end
    {
      "summary" => summary(numbered, seen, not_seen),
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

  def summary(findings, seen, not_seen)
    if seen.empty? && not_seen.empty?
      return "HEAD の commit に workflow の file (#{WORKFLOW_DIR}/*.yml / *.yaml) が無い。所見: high 0 / medium 0 / low 0 (判断が要る 0)"
    end

    counts = SEVERITY_ORDER.map { |s| "#{s} #{findings.count { |f| f['severity'] == s }}" }.join(" / ")
    decide = findings.count { |f| f["needs_decision"] }
    text = "HEAD の commit の workflow の file を #{seen.size} 本確かめた。所見: #{counts} (判断が要る #{decide})"
    text += "。確かめられない file が #{not_seen.size} 件ある (scope.not_seen)" if not_seen.any?
    text
  end
end

exit CiCheck.main(ARGV) if $PROGRAM_NAME == __FILE__
