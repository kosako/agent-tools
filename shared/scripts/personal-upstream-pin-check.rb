#!/usr/bin/env ruby
# frozen_string_literal: true

# upstream-pin-check: 参照元のある asset (vendor や翻案) の参照元が、pin の後に変わったかを決まった規則で見て、所見を
# personal-repo-audit と同じ形 (`findings.schema.json`) の JSON で出す (#623)。AI を使わず、何も書かない。
# 運用と規則の正本は docs/upstream-pin-check.md。
#
# 一覧: 今の directory の git repo の HEAD の commit にある `.github/upstream-pins.json` (作業ツリーの未 commit の変更は
# 読まない。sweep が監査する commit と揃える)。参照元ごとに、repo・pin・見る file の path と、pin のときの blob の
# hash を書く。
#
# 検査: 参照元ごとに GitHub の API (`gh api`。GET だけ、shell を通さず、env の GH_REPO は渡さない) で default branch の
# 先頭の commit の tree を 1 回読み、一覧の file の blob の hash を比べる。変わった file と、無くなった file があれば、
# その参照元を 1 件の所見にする (取り込むかは差分を読んで人や agent が決める)。参照元の本文は読まない。
#
# 出力に載せるのは、一覧に書かれた (形を確かめた) 名前・repo・path と、API の応答の commit の hash (形を確かめた
# もの) と決まった文言だけ。
#
# exit:
# - 0: 所見なし (一覧が無いときを含む)。
# - 1: 所見あり。
# - 2: usage / repo を選ぶ git の環境変数を継承している / repo や HEAD を解決できない / 一覧の形が外れる /
#   確かめられない参照元がある (gh の失敗、応答の形の違い、tree が途中で切れている、上限)。確かめられない参照元が
#   あっても、残りの参照元は確かめて出す (理由は scope.not_seen)。
# 結果は stdout に JSON。run 全体の失敗 (usage・環境変数・repo や HEAD・一覧の形) は stdout に何も出さず、stderr に
# 1 行。

require "json"
require "open3"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module UpstreamPinCheck
  NAME = "personal-upstream-pin-check"
  CONFIG_PATH = ".github/upstream-pins.json"
  EXIT_OK = 0
  EXIT_FINDINGS = 1
  EXIT_ERROR = 2

  # repository / index の選び方を変える git の環境変数 (personal-ci-check と同じ集合)。
  GIT_REPO_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].freeze
  TREE_ENTRY_RE = /\A(\d{6}) (blob|tree|commit) ([0-9a-f]{40}|[0-9a-f]{64}) +(\d+|-)\t(.+)\z/m.freeze
  REGULAR_MODES = %w[100644 100755].freeze
  MAX_CONFIG_BYTES = 64 * 1024
  MAX_UPSTREAMS = 32
  MAX_FILES = 64
  MAX_API_CALLS = 100
  MAX_API_SECONDS = 120
  READER_GRACE_SECONDS = 1

  NAME_RE = /\A[a-z0-9][a-z0-9-]{0,63}\z/.freeze
  REPO_RE = %r{\A[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}\z}.freeze
  SHA_RE = /\A[0-9a-f]{40}\z/.freeze
  SEGMENT_RE = /\A[A-Za-z0-9._-]+\z/.freeze
  BRANCH_RE = /\A[A-Za-z0-9._-]{1,100}\z/.freeze
  UPSTREAM_KEYS = %w[name repo pin notice files].freeze
  TREE_TYPES = %w[blob tree commit].freeze
  PRESCAN = "未実施 (決まった規則の検査で、下調べは要らない)"

  class UsageError < StandardError; end
  class RunError < StandardError; end
  class UpstreamError < StandardError; end
  class DuplicateKeyError < StandardError; end

  # JSON の object の key の重なりを拒む (後の値で黙って上書きしない)。
  class StrictHash < Hash
    def []=(key, value)
      raise DuplicateKeyError if key?(key)

      super
    end
  end

  # GitHub の API を gh で読む (GET だけ)。呼び出しの回数と時間に上限を置き、超えたら UpstreamError。shell を通さず、
  # env の GH_REPO は渡さない。上限の時刻を過ぎた gh は process group ごと止める (personal-ci-check と同じ作り)。
  class GitHubApi
    attr_reader :calls

    def initialize(dir, deadline)
      @dir = dir
      @deadline = deadline
      @calls = 0
    end

    def json(path)
      raise UpstreamError, "API の呼び出しが上限の #{MAX_API_CALLS} 回を超える" if @calls >= MAX_API_CALLS
      raise UpstreamError, "時間が上限の #{MAX_API_SECONDS} 秒を超える" if Time.now >= @deadline

      @calls += 1
      out, status = run_gh(["api", path])
      raise UpstreamError, "gh が失敗した" unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError
      raise UpstreamError, "gh の出力を JSON として読めない"
    end

    private

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
      raise UpstreamError, "gh を起動できない"
    ensure
      [out_r, err_r].each { |io| io&.close unless io&.closed? }
    end

    def abandon(pid, readers)
      [-pid, pid].each do |target|
        Process.kill("KILL", target)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      Process.wait(pid)
      readers.each do |reader|
        reader.kill unless reader.join(READER_GRACE_SECONDS)
        begin
          reader.join
        rescue StandardError
          nil
        end
      end
      raise UpstreamError, "時間が上限の #{MAX_API_SECONDS} 秒を超える"
    end
  end

  module_function

  def usage
    "usage: #{NAME} [--help|-h]"
  end

  def help
    <<~TEXT
      #{usage}
      今の directory の git repo の HEAD の commit にある #{CONFIG_PATH} の参照元ごとに、GitHub の API で default
      branch の先頭の tree を読み、一覧の file の blob の hash が pin のときから変わったかを見る。変わった・無くなった
      file がある参照元を所見にし、personal-repo-audit の findings.schema.json の形の JSON で stdout に出す。
      参照元の本文は読まず、何も書かない。一覧が無ければ所見なしで exit 0。
      exit: 0 = 所見なし / 1 = 所見あり / 2 = usage・一覧の形・repo を解決できない・確かめられない参照元がある
    TEXT
  end

  def main(argv)
    if argv == ["--help"] || argv == ["-h"]
      $stdout.puts help
      return EXIT_OK
    end
    raise UsageError, "引数を受け取りません: #{argv.first}" unless argv.empty?

    inherited = GIT_REPO_ENV.select { |k| ENV.key?(k) }
    unless inherited.empty?
      raise RunError, "#{inherited.join(' / ')} を継承しているので、今の directory の repo を確かめられません (外して実行してください)"
    end

    report, code = check_repo(Dir.pwd)
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
    $stderr.puts "#{NAME}: 想定外の失敗です (#{e.class})"
    EXIT_ERROR
  end

  def check_repo(dir, now: Time.now)
    upstreams = read_config(dir)
    return [report([], [], ["#{CONFIG_PATH} が無い (参照元の一覧なし)"], []), EXIT_OK] if upstreams.nil?

    api = GitHubApi.new(dir, now + MAX_API_SECONDS)
    findings = []
    seen = []
    not_seen = []
    upstreams.each do |u|
      result = check_upstream(api, u)
      seen << "#{u['name']} (#{u['repo']} の #{u['files'].size} file。先頭 #{result[:head][0, 12]})"
      findings << finding(u, result) unless result[:changed].empty? && result[:removed].empty?
    rescue UpstreamError => e
      not_seen << "#{u['name']} (#{u['repo']}): #{e.message}"
    end
    findings.each_with_index { |f, i| f["id"] = format("U%02d", i + 1) }
    code = if !not_seen.empty? then EXIT_ERROR
           elsif findings.empty? then EXIT_OK
           else EXIT_FINDINGS
           end
    [report(findings, seen, not_seen, upstreams), code]
  end

  # ---- 一覧 ----------------------------------------------------------------------------------------

  # HEAD の commit の一覧を読み、形を確かめた参照元の配列を返す。一覧が無ければ nil。
  def read_config(dir)
    git(dir, "rev-parse", "--verify", "--end-of-options", "HEAD^{commit}") # HEAD が無ければ RunError
    gh_dir = tree_entries(dir, "HEAD").find { |e| e[:name] == File.dirname(CONFIG_PATH) }
    return nil if gh_dir.nil?
    unless gh_dir[:type] == "tree" && gh_dir[:mode] == "040000"
      raise RunError, "#{File.dirname(CONFIG_PATH)} が directory ではありません"
    end

    entry = tree_entries(dir, gh_dir[:oid]).find { |e| e[:name] == File.basename(CONFIG_PATH) }
    return nil if entry.nil?
    unless entry[:type] == "blob" && REGULAR_MODES.include?(entry[:mode])
      raise RunError, "#{CONFIG_PATH} が通常の file ではありません"
    end
    raise RunError, "#{CONFIG_PATH} が #{MAX_CONFIG_BYTES} byte を超えます" if entry[:size].to_i > MAX_CONFIG_BYTES

    text = git(dir, "cat-file", "blob", entry[:oid]).dup.force_encoding(Encoding::UTF_8)
    raise RunError, "#{CONFIG_PATH} が UTF-8 として読めません" unless text.valid_encoding?

    parse_config(text)
  end

  # 一覧の text を確かめて、参照元の配列を返す。形が外れれば RunError。
  def parse_config(text)
    data = begin
      JSON.parse(text, object_class: StrictHash)
    rescue JSON::ParserError, DuplicateKeyError
      raise RunError, "#{CONFIG_PATH} が JSON として読めないか、key が重なっています"
    end
    unless data.is_a?(Hash) && data.keys.sort == %w[schema_version upstreams] && data["schema_version"] == 1
      raise RunError, "#{CONFIG_PATH} の top level は {\"schema_version\": 1, \"upstreams\": [...]} の形にしてください"
    end
    list = data["upstreams"]
    unless list.is_a?(Array) && !list.empty? && list.size <= MAX_UPSTREAMS
      raise RunError, "#{CONFIG_PATH} の upstreams は 1〜#{MAX_UPSTREAMS} 個の配列にしてください"
    end

    names = {}
    list.each_with_index.map do |u, i|
      where = "#{CONFIG_PATH} の upstreams[#{i}]"
      raise RunError, "#{where} の key は #{UPSTREAM_KEYS.join(' / ')} にしてください" unless u.is_a?(Hash) && u.keys.sort == UPSTREAM_KEYS.sort
      raise RunError, "#{where}.name の形が外れます" unless u["name"].is_a?(String) && u["name"].match?(NAME_RE)
      raise RunError, "#{where}.name が重なっています" if names[u["name"]]

      names[u["name"]] = true
      raise RunError, "#{where}.repo の形が外れます" unless u["repo"].is_a?(String) && u["repo"].match?(REPO_RE) && !u["repo"].include?("..")
      raise RunError, "#{where}.pin は 40 桁の commit の hash にしてください" unless u["pin"].is_a?(String) && u["pin"].match?(SHA_RE)
      raise RunError, "#{where}.notice の形が外れます" unless rel_path?(u["notice"])

      files = u["files"]
      unless files.is_a?(Hash) && !files.empty? && files.size <= MAX_FILES
        raise RunError, "#{where}.files は path から blob の hash への 1〜#{MAX_FILES} 個の object にしてください"
      end
      files.each do |path, sha|
        raise RunError, "#{where}.files の path の形が外れます" unless rel_path?(path)
        raise RunError, "#{where}.files の blob の hash は 40 桁にしてください" unless sha.is_a?(String) && sha.match?(SHA_RE)
      end
      u
    end
  end

  # repo 相対の path か (英数字と . _ - の segment を / でつなぐ。空・. ・.. の segment は不可)。
  def rel_path?(value)
    return false unless value.is_a?(String) && !value.empty? && value.size <= 300

    value.split("/", -1).all? { |s| s.match?(SEGMENT_RE) && s != "." && s != ".." }
  end

  # ---- 参照元 --------------------------------------------------------------------------------------

  # 参照元の default branch の先頭の tree を読み、{head:, changed:, removed:} を返す。確かめられなければ UpstreamError。
  def check_upstream(api, u)
    repo = u["repo"]
    meta = api.json("repos/#{repo}")
    branch = meta.is_a?(Hash) ? meta["default_branch"] : nil
    raise UpstreamError, "default branch を読めない" unless branch.is_a?(String) && branch.match?(BRANCH_RE)

    ref = api.json("repos/#{repo}/git/ref/heads/#{branch}")
    head = ref.is_a?(Hash) && ref["object"].is_a?(Hash) ? ref["object"]["sha"] : nil
    unless head.is_a?(String) && head.match?(SHA_RE) && ref["object"]["type"] == "commit"
      raise UpstreamError, "default branch の先頭の commit を読めない"
    end

    tree = api.json("repos/#{repo}/git/trees/#{head}?recursive=1")
    unless tree.is_a?(Hash) && tree["tree"].is_a?(Array) && tree["truncated"] == false
      raise UpstreamError, "tree を読めないか、途中で切れている"
    end

    # entry はどれも path・type・sha の形を確かめる。外れた entry が 1 つでもあれば、応答を信じず確かめられないにする
    # (sha の欠けた entry を「無くなった」、形の外れた sha を「変わった」と読み違えない)。
    blobs = {}
    tree["tree"].each do |e|
      unless e.is_a?(Hash) && e["path"].is_a?(String) && !e["path"].empty? && TREE_TYPES.include?(e["type"]) &&
             e["sha"].is_a?(String) && e["sha"].match?(SHA_RE)
        raise UpstreamError, "tree の entry の形が外れている"
      end

      blobs[e["path"]] = e["sha"] if e["type"] == "blob"
    end
    changed = []
    removed = []
    u["files"].each do |path, sha|
      if !blobs.key?(path) then removed << path
      elsif blobs[path] != sha then changed << path
      end
    end
    { head: head, changed: changed.sort, removed: removed.sort }
  end

  def finding(u, result)
    parts = []
    parts << "変わった file: #{result[:changed].join(', ')}" unless result[:changed].empty?
    parts << "無くなった file: #{result[:removed].join(', ')}" unless result[:removed].empty?
    count = result[:changed].size + result[:removed].size
    {
      "id" => "",
      "fingerprint" => "#{CONFIG_PATH}#upstream-#{u['name']}",
      "dimension" => "dependency",
      "kind" => "debt",
      "severity" => "low",
      "confidence" => "確証",
      "locations" => [u["notice"], CONFIG_PATH],
      "claim" => "参照元 #{u['name']} (#{u['repo']}) は、pin #{u['pin'][0, 12]} の後に、一覧の " \
                 "#{u['files'].size} file のうち #{count} file が変わった (先頭 #{result[:head][0, 12]})。#{parts.join('。')}。",
      "evidence" => "GitHub の API で default branch の先頭の tree を読み、#{CONFIG_PATH} の blob の hash と比べた " \
                    "(参照元の本文は読んでいない)。",
      "impact" => "手元の写しや翻案が参照元の更新から遅れる。取り込まないままだと、参照元の修正や改善が届かない。",
      "recommendation" => "差分を data として読み、取り込むかを判断する。取り込むなら写しと NOTICE を更新し、" \
                          "#{CONFIG_PATH} の pin と blob の hash を新しい commit のものにする。取り込まない差分も、" \
                          "確かめた commit を NOTICE に残して一覧を進める。",
      "needs_decision" => true,
      "decision_reason" => "取り込むかは、差分の中身と、写しの取り込み方 (無改変・翻案) で決まる。"
    }
  end

  def report(findings, seen, not_seen, upstreams)
    summary = if upstreams.empty? then "参照元の一覧が無い。"
              else "参照元 #{upstreams.size} 件のうち、更新があったのは #{findings.size} 件、確かめられないのは #{not_seen.size} 件。"
              end
    {
      "summary" => summary,
      "findings" => findings,
      "not_problems" => [],
      "decisions" => findings.map { |f| { "finding_id" => f["id"], "question" => "#{f['fingerprint'].split('#upstream-').last} の参照元の更新を取り込むか" } },
      "scope" => {
        "seen" => seen,
        "partial" => [],
        "not_seen" => not_seen,
        "uncommitted" => "読まない (HEAD の commit の一覧だけを見る)",
        "prescan" => PRESCAN
      }
    }
  end

  # ---- git -----------------------------------------------------------------------------------------

  # treeish (commit か tree の object) の直下の entry を返す。
  def tree_entries(dir, treeish)
    out = git(dir, "ls-tree", "--full-tree", "-z", "-l", "--end-of-options", treeish)
    out.split("\0").map do |raw|
      m = TREE_ENTRY_RE.match(raw)
      raise RunError, "git ls-tree の出力を解釈できません" if m.nil?

      { mode: m[1], type: m[2], oid: m[3], size: m[4] == "-" ? nil : m[4].to_i, name: m[5] }
    end
  rescue SystemCallError => e
    raise RunError, "git を起動できません (#{e.class})"
  end

  def git(dir, *args)
    out, _err, status = Open3.capture3("git", "--no-lazy-fetch", "--no-replace-objects", *args, chdir: dir, binmode: true)
    raise RunError, "git #{args.first} が失敗しました (今の directory が git repo で、HEAD に commit があるか確かめてください)" unless status.success?

    out
  rescue SystemCallError => e
    raise RunError, "git を起動できません (#{e.class})"
  end
end

exit UpstreamPinCheck.main(ARGV) if $PROGRAM_NAME == __FILE__
