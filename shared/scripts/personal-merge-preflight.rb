#!/usr/bin/env ruby
# frozen_string_literal: true

# personal-merge-preflight: 個人 project の PR を agent が merge してよいかを、運用 instruction の「個人 project の GitHub の
# 操作と merge」(#563) の条件で確かめる (#662)。判定だけで、merge も書き込みもしない。確かめるのは次のとおり。
#
# 1. 対象: repo の owner の type が User で、その login が gh で認証している user の login と一致する。外れたら、ほかの
#    条件は見ない (agent が merge してよい repo ではない)。
# 2. PR の状態: open で、merge されていない。
# 3. routing: 同じ directory の personal-review-routing-preflight を、PR の今の base / head に固定して起動し
#    (`--expect-base` / `--expect-head`)、exit 0 (author を単一の AI か表の bot と判定した) と reviewer を読む。
# 4. review の結果: gh で認証している user のコメントのうち、最後の結果コメントの候補 (決まった 3 行のどれかに近い行を持つ
#    もの。RESULT_NEAR) を読む。
#    同じ directory の personal-work-marker-check --kind review-result で形が合い (exit 0)、見出しの reviewer が routing の
#    reviewer と合い (bot(dependabot) の PR では personal-dependabot-pin-check も可)、verdict が APPROVE で、Target の行が
#    今の PR と合う。合うとは、base ref と head が同じで、review の base OID と head の merge-base が、base の branch の今の
#    先端と head の merge-base と同じこと (base を付け替えた・親の branch を rebase した・commit を足したときは合わない)。
# 5. CI: base の branch の今の先端の `.github/repo-baseline.json` の `required_checks` を必要な集合とし、head の check-runs で
#    各 check が completed かつ success (file か key が無ければ not ok。file が不正なら判定できない。読み方は
#    personal-repo-baseline と personal-dependabot-pin-check と同じで、test で一致を固定する)。
# 6. merge state: 最後に読んだ `pulls/<n>` の mergeable_state が clean。unknown (GitHub がまだ計算していない) は判定できない。
# 7. snapshot: 最初と最後に `pulls/<n>` と base の branch の先端を読み、head・base・コメントの数が動いていないこと。
#
# 結果コメントは agent が gh で認証した user として投稿したものだけを読み、本文は出力に載せない (コメントの id・閉じた表の
# label・規則の形に合う check の名前と OID だけを出す)。他の author のコメントは、同じ形でも読まない (運用 instruction の
# 「外部入力の信頼境界」)。
#
# 使い方: personal-merge-preflight <PR番号> --repo owner/repo (--repo は必須。merge の command にも同じ値を渡す)
# 出力: 条件ごとの label の行 (stdout)。merge してよいときは、最後の 2 行が `head: <full の OID>` と
# `merge-preflight: ok`。merge の `--match-head-commit` には、この head を渡す。
# 依存: gh (認証済み)。読み取りは REST の GET だけ (user、repos/<r>、pulls/<n>、issues/<n>/comments、git/ref/heads/<ref>、
# compare、contents、commits/<sha>/check-runs)。API の呼び出しは 1 回の実行で 80 回まで (隣の script の分は数えない)。
# exit: 0 = merge してよい / 1 = 条件を満たさない (理由は stdout の label。merge しない) / 2 = usage・gh の失敗・判定できない
# (応答の形が外れる、検査の途中で PR が動いた、mergeable_state が unknown、隣の script が無いか判定できない)。

require "erb"
require "json"
require "open3"
require "uri"

# C locale でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module MergePreflight
  NAME = "personal-merge-preflight"
  EXIT_OK = 0
  EXIT_NOT_OK = 1
  EXIT_ERROR = 2

  ROUTING_NAME = "personal-review-routing-preflight"
  MARKER_NAME = "personal-work-marker-check"

  REPO_RE = %r{\A[\w.-]+/[\w.-]+\z}.freeze
  SHA_RE = /\A[0-9a-f]{40}\z/.freeze
  # 出力にそのまま載せてよい base の branch の名前 (外れる名前も受け付けるが、出力では名前を出さない。URL には
  # percent-encode して埋める)。
  SAFE_BRANCH_RE = %r{\A[A-Za-z0-9_][A-Za-z0-9_./-]{0,99}\z}.freeze
  MAX_API_CALLS = 80
  PER_PAGE = 100
  MAX_COMMENT_BODY = 1024 * 1024

  # 結果コメントの決まった行 (docs/work-markers.md の v3)。personal-work-marker-check の形と同じで、ここでは値を取り出す
  # ために名前つきの group を持つ (test で同じ形であることを固定する)。
  RESULT_HEADING = /\A## 📋 レビュー結果（by (?<reviewer>Codex|Claude|personal-dependabot-pin-check)）/
  VERDICT_LINE = /\A\*\*Review process verdict: (?<verdict>REJECT|Warning|APPROVE)\*\*[ \t]*\z/
  TARGET_LINE = %r{\A\*\*Target: base (?<ref>\S+) (?<base>[0-9a-f]{40}) / head (?<head>[0-9a-f]{40})\*\*[ \t]*\z}
  # 結果コメントの候補を見分ける形 (#665 の review の F1・F4・F7)。候補は「決まった 3 行 (見出し・verdict・Finding summary)
  # のどれかに近い行を持つコメント」で、近い行とは、行の頭 (空白・引用・list・番号・太字や code の印の後) に、見出しの印 `#`
  # に続く `レビュー結果`、または `Review process verdict` か `Finding summary` の label とコロンがある行。行は NFKC にし、
  # 書式文字 (BOM・ゼロ幅の文字など) と異体字の選択子を除いてから見る (絵文字・空白・括弧・全角・太字・list・字下げの揺れを
  # 問わない)。崩れた結果を読み飛ばして前の結果を使わないため、検査が受け付ける形はすべて候補になる。一方、普通の文の中の
  # 言及 (「レビュー結果を確認した」など) は行の形が違うので候補にせず、merge してよい PR を規則に無い理由で止めない。
  LINE_HEAD = %q{[\s>*_`+\-\d.)]*}
  RESULT_NEAR = [
    /\A#{LINE_HEAD}#+[^\p{L}]*レビュー結果/,                       # 見出し
    /\A#{LINE_HEAD}review\s*process\s*verdict[\s*_`]*:/i,          # verdict の行
    /\A#{LINE_HEAD}finding\s*summary[\s*_`]*:/i,                   # Finding summary の行
  ].freeze
  IGNORABLE = /[\p{Cf}\u{FE00}-\u{FE0F}]/.freeze

  # routing preflight の最後の行。author と reviewer は閉じた表 ROUTES の組で、commit は 1 つ以上 (外れたら判定できない)。
  ROUTING_LINE = /\Areviewer: (?<reviewer>codex|claude) \(author=(?<author>[a-z]+(?:\([a-z]+\))?), (?<count>\d+) commit\(s\)\)\z/
  # author の label と reviewer の閉じた表 (personal-review-request の「レビュアーの決定」の表。正本は routing preflight)。
  ROUTES = {
    "claude" => "codex", "codex" => "claude", "opencode(anthropic)" => "codex", "opencode(openai)" => "claude",
    "opencode(other)" => "claude", "bot(dependabot)" => "claude",
  }.freeze
  # routing の reviewer と、結果の見出しの reviewer の対応。bot(dependabot) の PR では pin-check の結果も使える (#553 の C)。
  HEADING_FOR = { "codex" => %w[Codex], "claude" => %w[Claude] }.freeze
  BOT_EXTRA_HEADINGS = { "bot(dependabot)" => %w[personal-dependabot-pin-check] }.freeze

  # GitHub の mergeable_state の閉じた表 (clean 以外は merge しない)。表に無い値は other と出す。
  MERGE_STATES = %w[clean unknown blocked behind dirty draft unstable has_hooks].freeze

  # base の repo-baseline.json の読み方は personal-repo-baseline と personal-dependabot-pin-check と同じ (#573)。script は
  # 1 file ずつ配備されるので code は共有せず、同じ本文の組を当てる test で一致を固定する。
  BASELINE_PATH = ".github/repo-baseline.json"
  BASELINE_MAX = 64 * 1024
  BASELINE_KEYS = %w[skip required_checks].freeze
  BASELINE_SKIPPABLE = %w[dependabot_yml].freeze
  # 出力にそのまま載せてよい check の名前 (personal-dependabot-pin-check と同じ形)。外れる名前も、baseline が受け付けるなら
  # 確かめる (受け付ける条件は baseline の規則のまま。規則を狭めない)。出力では名前の代わりに番号を出す。
  SAFE_CHECK_NAME_RE = %r{\A[A-Za-z0-9_][A-Za-z0-9 _.()/,:+-]{0,99}\z}.freeze

  class UsageError < StandardError; end
  # gh の失敗・応答の形の外れ・途中の変化・隣の script の失敗 (判定できない。exit 2)。
  class RunError < StandardError; end
  class BaselineDuplicateKeyError < StandardError; end
  # 同じ key が重なったら、後の値で前の値を消さずに不正にする (JSON.parse は既定で後の値を残す)。
  class BaselineStrictHash < Hash
    def []=(key, value)
      raise BaselineDuplicateKeyError if key?(key)

      super
    end
  end

  # GitHub の API を gh で読む (GET だけ)。回数に上限を置く。stderr は gh の固定の文言だけを見て 404 を分ける。
  class GitHubApi
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def get(path, allow_404: false)
      raise RunError, "API の呼び出しが上限の #{MAX_API_CALLS} 回を超える" if @calls >= MAX_API_CALLS

      @calls += 1
      out, err, status = begin
        Open3.capture3("gh", "api", path, in: File::NULL)
      rescue SystemCallError
        raise RunError, "gh を起動できません"
      end
      unless status.success?
        return nil if allow_404 && err.include?("HTTP 404")

        raise RunError, "gh api が失敗しました (PR 番号 / 認証 / --repo を確認)"
      end
      obj = begin
        JSON.parse(out)
      rescue JSON::ParserError
        raise RunError, "gh の応答を JSON として解釈できません"
      end
      raise RunError, "gh の応答の形が外れます (成功の応答の本文が null)" if obj.nil?

      obj
    end
  end

  # 条件ごとの結果を集める。ok でない label が 1 つでもあれば not ok。
  class Report
    attr_reader :lines

    def initialize
      @lines = []
      @ok = true
    end

    def add(ok, text)
      @ok &&= ok
      @lines << text
    end

    def ok?
      @ok
    end
  end

  module_function

  def usage
    "usage: #{NAME} <PR番号> --repo owner/repo"
  end

  def run(argv)
    pr_number, repo = parse_args(argv)
    report = check(GitHubApi.new, repo, pr_number, script_dir)
    report.lines.each { |line| $stdout.puts line }
    if report.ok?
      $stdout.puts "merge-preflight: ok"
      EXIT_OK
    else
      $stdout.puts "merge-preflight: not ok"
      EXIT_NOT_OK
    end
  rescue UsageError => e
    $stderr.puts "#{NAME}: #{e.message}"
    $stderr.puts usage
    EXIT_ERROR
  rescue RunError => e
    $stderr.puts "#{NAME}: error: #{e.message}"
    EXIT_ERROR
  rescue StandardError, SystemStackError => e
    $stderr.puts "#{NAME}: unexpected error (#{e.class})"
    EXIT_ERROR
  end

  def parse_args(argv)
    args = argv.dup
    i = args.index("--repo")
    raise UsageError, "--repo owner/repo を付けてください (merge の command にも同じ値を渡す)" if i.nil?

    repo = args[i + 1]
    raise UsageError, "--repo は owner/repo 形式で指定してください" if repo.nil? || !repo.match?(REPO_RE) || repo.start_with?("-")

    args.slice!(i, 2)
    raise UsageError, "PR 番号は数字だけで指定してください" unless args.size == 1 && args[0].match?(/\A\d+\z/)

    [args[0], repo]
  end

  def script_dir
    File.dirname(File.realpath(__FILE__))
  end

  # 検査の本体。Report を返す。判定できないときは RunError。
  def check(api, repo, pr_number, dir)
    base_path = "repos/#{repo}"
    report = Report.new

    login = read_login(api)
    owner = read_owner(api, base_path)
    unless owner[:type] == "User" && owner[:login] == login
      report.add(false, "owner: not-personal (owner が gh で認証している user の個人の account ではない。merge は人に確認する)")
      return report
    end
    report.add(true, "owner: ok")

    pull = read_pull(api, base_path, pr_number)
    tip = read_branch_tip(api, base_path, pull[:base_ref])
    report.add(true, "target: base #{display_branch(pull[:base_ref])} #{tip} / head #{pull[:head_sha]}")
    unless pull[:state] == "open" && !pull[:merged]
      report.add(false, "pr: not-open")
      return report
    end

    routing = run_routing(dir, repo, pr_number, pull)
    report.add(routing[:ok], routing[:text])

    if routing[:ok]
      comments = read_result_candidate(api, base_path, pr_number, pull[:comments], login)
      check_review(api, base_path, dir, report, comments, routing, pull, tip)
    else
      report.add(false, "review: skipped (routing が確定していない)")
    end

    check_ci(api, base_path, report, tip, pull[:head_sha])

    after = read_pull(api, base_path, pr_number)
    after_tip = read_branch_tip(api, base_path, pull[:base_ref])
    unless snapshot(after) == snapshot(pull) && after_tip == tip
      raise RunError, "検査の途中で PR か base の branch が動きました (やり直す)"
    end

    state = after[:mergeable_state]
    raise RunError, "mergeable_state が unknown です (GitHub が計算中。数秒おいてやり直す)" if state == "unknown"

    label = MERGE_STATES.include?(state) ? state : "other"
    report.add(state == "clean", "merge-state: #{label}")
    report.add(true, "head: #{pull[:head_sha]}") if report.ok?
    report
  end

  def read_login(api)
    user = api.get("user")
    login = user.is_a?(Hash) ? user["login"] : nil
    raise RunError, "gh で認証している user の login を読めません" unless login.is_a?(String) && !login.empty?

    login
  end

  def read_owner(api, base_path)
    obj = api.get(base_path)
    owner = obj.is_a?(Hash) ? obj["owner"] : nil
    raise RunError, "repository の owner を読めません" unless owner.is_a?(Hash) && owner["login"].is_a?(String) && owner["type"].is_a?(String)

    { login: owner["login"], type: owner["type"] }
  end

  # pulls/<n> から、判定に使う値を読む。形が外れれば RunError。
  def read_pull(api, base_path, pr_number)
    pull = api.get("#{base_path}/pulls/#{pr_number}")
    raise RunError, "gh の応答が PR の object ではありません" unless pull.is_a?(Hash)

    head = pull["head"]
    base = pull["base"]
    raise RunError, "PR の head / base を読めません" unless head.is_a?(Hash) && base.is_a?(Hash)

    head_sha = head["sha"]
    base_sha = base["sha"]
    base_ref = base["ref"]
    raise RunError, "PR の head / base の sha の形が外れます" unless head_sha.is_a?(String) && head_sha.match?(SHA_RE) &&
                                                                     base_sha.is_a?(String) && base_sha.match?(SHA_RE)
    # 名前は git の規則のまま受け付ける (文字の種類で狭めない)。空・制御文字・不正な UTF-8 だけを判定できないとする。
    unless base_ref.is_a?(String) && !base_ref.empty? && base_ref.valid_encoding? && base_ref !~ /[[:cntrl:]]/
      raise RunError, "PR の base の branch の名前を読めません"
    end
    raise RunError, "PR の state を読めません" unless pull["state"].is_a?(String) && [true, false].include?(pull["merged"])
    raise RunError, "PR のコメントの数を読めません" unless pull["comments"].is_a?(Integer) && pull["comments"] >= 0

    state = pull["mergeable_state"]
    raise RunError, "PR の mergeable_state を読めません" unless state.is_a?(String)

    { head_sha: head_sha, base_sha: base_sha, base_ref: base_ref, state: pull["state"], merged: pull["merged"],
      comments: pull["comments"], mergeable_state: state }
  end

  def snapshot(pull)
    pull.values_at(:head_sha, :base_sha, :base_ref, :state, :merged, :comments)
  end

  # 出力に載せる base の branch の名前 (規則の形の外なら名前を出さない)。
  def display_branch(ref)
    ref.match?(SAFE_BRANCH_RE) ? ref : "(規則の形の外の名前)"
  end

  # base の branch の今の先端の OID。名前は "/" で分けた各部分を percent-encode して path に埋める。
  def read_branch_tip(api, base_path, ref)
    encoded = ref.split("/", -1).map { |part| ERB::Util.url_encode(part) }.join("/")
    obj = api.get("#{base_path}/git/ref/heads/#{encoded}")
    object = obj.is_a?(Hash) ? obj["object"] : nil
    unless obj.is_a?(Hash) && obj["ref"] == "refs/heads/#{ref}" && object.is_a?(Hash) && object["type"] == "commit" &&
           object["sha"].is_a?(String) && object["sha"].match?(SHA_RE)
      raise RunError, "base の branch の先端を読めません"
    end

    object["sha"]
  end

  # 隣の script の path。無い・実行できないときは判定できない。
  def sibling(dir, name)
    path = File.join(dir, name)
    raise RunError, "#{name} が同じ directory にありません (配備を確認してください)" unless File.file?(path) && File.executable?(path)

    path
  end

  def capture(argv, stdin_data: "")
    Open3.capture3(*argv, stdin_data: stdin_data, binmode: true)
  rescue SystemCallError
    raise RunError, "#{File.basename(argv.first)} を起動できません"
  end

  # routing preflight を PR の今の base / head に固定して起動し、{ok:, text:, reviewer:, author:} を返す。
  def run_routing(dir, repo, pr_number, pull)
    argv = [sibling(dir, ROUTING_NAME), pr_number, "--repo", repo, "--expect-base", pull[:base_sha], "--expect-head", pull[:head_sha]]
    out, _err, status = capture(argv)
    case status.exitstatus
    when 0
      last = out.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).last.to_s
      m = ROUTING_LINE.match(last)
      raise RunError, "#{ROUTING_NAME} の出力の形が外れます" if m.nil?
      unless ROUTES[m[:author]] == m[:reviewer] && m[:count].to_i.positive?
        raise RunError, "#{ROUTING_NAME} の author と reviewer の組が表に無いか、commit が 0 です"
      end

      { ok: true, text: "routing: ok (author=#{m[:author]}, reviewer=#{m[:reviewer]})", reviewer: m[:reviewer], author: m[:author] }
    when 1
      { ok: false, text: "routing: fail-closed (#{ROUTING_NAME} が exit 1。人が review する)" }
    else
      raise RunError, "#{ROUTING_NAME} が判定できませんでした (exit #{status.exitstatus.inspect})"
    end
  end

  # gh で認証している user のコメントのうち、最後の結果コメントの候補 ({id:, body:}) を返す (無ければ nil)。コメントは
  # page ごとに読み、数が PR のコメントの数と合わなければ判定しない。
  def read_result_candidate(api, base_path, pr_number, count, login)
    comments = []
    page = 1
    loop do
      obj = api.get("#{base_path}/issues/#{pr_number}/comments?per_page=#{PER_PAGE}&page=#{page}")
      raise RunError, "コメントの応答が配列ではありません" unless obj.is_a?(Array)

      comments.concat(obj)
      break if obj.size < PER_PAGE

      page += 1
    end
    raise RunError, "コメントの数が PR のコメントの数と合いません (全件を読めない)" unless comments.size == count

    comments.each do |c|
      user = c.is_a?(Hash) ? c["user"] : nil
      unless c.is_a?(Hash) && c["id"].is_a?(Integer) && user.is_a?(Hash) && user["login"].is_a?(String) && c["body"].is_a?(String)
        raise RunError, "コメントの応答の形が外れます"
      end
    end
    # 全コメントの id が重なりなく増える (page の境界の重なりや並びの乱れで、最後の結果を取り違えないため)。
    ids = comments.map { |c| c["id"] }
    raise RunError, "コメントの id が重なりなく増える順になっていません" unless ids.each_cons(2).all? { |a, b| a < b }

    mine = comments.select { |c| c["user"]["login"] == login }.map { |c| { id: c["id"], body: c["body"] } }
    mine.reverse.find { |c| result_candidate?(c[:body]) }
  end

  # 結果コメントの候補か (RESULT_NEAR の注を参照)。UTF-8 として読めない本文は候補にする (形の検査で止める)。
  def result_candidate?(body)
    return true unless body.valid_encoding?

    marker_lines(body).any? do |line|
      loose = line.unicode_normalize(:nfkc).gsub(IGNORABLE, "")
      RESULT_NEAR.any? { |re| re.match?(loose) }
    end
  end

  # 最後の結果コメントを確かめ、report に足す。
  def check_review(api, base_path, dir, report, candidate, routing, pull, tip)
    if candidate.nil?
      report.add(false, "review: no-result (gh で認証している user の結果コメントが無い)")
      return
    end
    body = candidate[:body]
    raise RunError, "結果コメントが大きすぎます" if body.bytesize > MAX_COMMENT_BODY

    where = "comment #{candidate[:id]}"
    _out, _err, status = capture([sibling(dir, MARKER_NAME), "--kind", "review-result", "--stdin"], stdin_data: body)
    case status.exitstatus
    when 0 then nil
    when 1
      report.add(false, "review: result-form-broken (#{where}。#{MARKER_NAME} が exit 1)")
      return
    else
      raise RunError, "#{MARKER_NAME} が判定できませんでした (exit #{status.exitstatus.inspect})"
    end

    lines = marker_lines(body)
    heading = lines.map { |l| RESULT_HEADING.match(l) }.compact.first
    verdict = lines.map { |l| VERDICT_LINE.match(l) }.compact.first
    target = lines.map { |l| TARGET_LINE.match(l) }.compact.first
    raise RunError, "結果コメントの決まった行を読めません" if heading.nil? || verdict.nil? || target.nil?

    allowed = HEADING_FOR.fetch(routing[:reviewer]) + BOT_EXTRA_HEADINGS.fetch(routing[:author], [])
    unless allowed.include?(heading[:reviewer])
      report.add(false, "review: reviewer-mismatch (#{where}。結果の reviewer が #{heading[:reviewer]}、routing は #{routing[:reviewer]})")
      return
    end
    unless verdict[:verdict] == "APPROVE"
      report.add(false, "review: not-approved (#{where}。最後の verdict が #{verdict[:verdict]})")
      return
    end
    unless target[:ref] == pull[:base_ref]
      report.add(false, "review: target-base-ref-mismatch (#{where}。review をやり直す)")
      return
    end
    unless target[:head] == pull[:head_sha]
      report.add(false, "review: target-head-mismatch (#{where}。review の後に head が変わった。review をやり直す)")
      return
    end
    reviewed = merge_base(api, base_path, target[:base], pull[:head_sha])
    if reviewed.nil?
      report.add(false, "review: target-base-unknown (#{where}。review の base OID を読めない。review をやり直す)")
      return
    end
    now = merge_base(api, base_path, tip, pull[:head_sha])
    raise RunError, "base の branch の先端と head の merge-base を読めません" if now.nil?

    unless reviewed == now
      report.add(false, "review: target-base-mismatch (#{where}。差分の基点が変わった。review をやり直す)")
      return
    end
    report.add(true, "review: ok (APPROVE by #{heading[:reviewer]}、#{where})")
  end

  # 結果コメントの本文を行に分ける。personal-work-marker-check と同じ (先頭の BOM を除き、CRLF と LF で分ける)。候補の
  # 見分けと決まった行の読み取りの両方で使い、読み方をずらさない。
  def marker_lines(body)
    body.sub(/\A\u{FEFF}/, "").split(/\r?\n/, -1)
  end

  # base と head の merge-base の OID。base を読めない (404) なら nil。
  def merge_base(api, base_path, base, head)
    obj = api.get("#{base_path}/compare/#{base}...#{head}?per_page=1", allow_404: true)
    return nil if obj.nil?

    commit = obj.is_a?(Hash) ? obj["merge_base_commit"] : nil
    raise RunError, "compare の応答の形が外れます" unless commit.is_a?(Hash) && commit["sha"].is_a?(String) && commit["sha"].match?(SHA_RE)

    commit["sha"]
  end

  # base の branch の今の先端の required_checks を、head の check-runs で確かめて report に足す。
  def check_ci(api, base_path, report, tip, head_sha)
    names = required_checks(api, base_path, tip)
    if names.nil?
      report.add(false, "ci: ci-undefined (#{BASELINE_PATH} か、その required_checks が無い)")
      return
    end
    names.each_with_index do |name, i|
      state = check_run_state(api, base_path, head_sha, name)
      shown = name.match?(SAFE_CHECK_NAME_RE) ? name : "required_checks の #{i + 1} 番目 (規則の形の外の名前)"
      report.add(state == "success", "ci #{shown}: #{state}")
    end
  end

  # file が無い (404) か required_checks の key が無ければ nil (ci-undefined)。file が不正なら RunError (判定できない)。
  # 名前は baseline の規則で受け付けたものをそのまま使う (出力の形は check_ci が決める)。
  def required_checks(api, base_path, sha)
    obj = api.get("#{base_path}/contents/#{BASELINE_PATH}?ref=#{sha}", allow_404: true)
    return nil if obj.nil?

    size = obj.is_a?(Hash) ? obj["size"] : nil
    unless obj.is_a?(Hash) && obj["type"] == "file" && obj["encoding"] == "base64" && obj["content"].is_a?(String) &&
           size.is_a?(Integer) && size >= 0
      raise RunError, "#{BASELINE_PATH} を読めません (応答の形が想定外)"
    end
    raise RunError, "#{BASELINE_PATH} が大きすぎます" if size > BASELINE_MAX

    names = parse_baseline(decode_baseline(obj["content"], size))
    names
  end

  # contents API の base64 (60 文字ごとに改行が入る) を厳密に decode し、本文の byte 数が size と合うことを求める。
  def decode_baseline(content, size)
    text = begin
      content.delete("\n").unpack1("m0")
    rescue ArgumentError
      raise RunError, "#{BASELINE_PATH} を読めません (base64 が壊れている)"
    end
    raise RunError, "#{BASELINE_PATH} を読めません (size が本文と合わない)" unless text.bytesize == size

    text
  end

  # 本文 (JSON の text) から required_checks を返す (key が無ければ nil)。規則は personal-repo-baseline と同じ。
  def parse_baseline(text)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise RunError, "#{BASELINE_PATH} が UTF-8 として読めません" unless text.valid_encoding?

    data = begin
      JSON.parse(text, object_class: BaselineStrictHash)
    rescue JSON::ParserError
      raise RunError, "#{BASELINE_PATH} が JSON として読めません"
    rescue BaselineDuplicateKeyError
      raise RunError, "#{BASELINE_PATH} に重なった key があります"
    end
    raise RunError, "#{BASELINE_PATH} の top-level が object ではありません" unless data.is_a?(Hash)
    raise RunError, "#{BASELINE_PATH} に知らない key があります" unless (data.keys - BASELINE_KEYS).empty?

    if data.key?("skip")
      skip = data["skip"]
      unless skip.is_a?(Array) && !skip.empty? && skip.all? { |item| BASELINE_SKIPPABLE.include?(item) }
        raise RunError, "#{BASELINE_PATH} の skip が外せる項目の空でない配列ではありません"
      end
      raise RunError, "#{BASELINE_PATH} の skip に重なった値があります" if skip.uniq.size != skip.size
    end
    return nil unless data.key?("required_checks")

    checks = data["required_checks"]
    unless checks.is_a?(Array) && !checks.empty? && checks.all? { |c| baseline_check_name?(c) }
      raise RunError, "#{BASELINE_PATH} の required_checks が空でない check の名前の配列ではありません"
    end
    raise RunError, "#{BASELINE_PATH} の required_checks に重なった値があります" if checks.uniq.size != checks.size

    checks
  end

  def baseline_check_name?(name)
    name.is_a?(String) && name.valid_encoding? && !name.strip.empty? && name !~ /[[:cntrl:]]/
  end

  # head の check-runs のうち名前が一致するもの (最新の attempt) を page ごとに読む (personal-dependabot-pin-check と同じ)。
  # check_name の絞り込みは完全一致なので、要素の name が文字列でない・名前が違うときは応答の形の外れ (判定できない)。
  # 黙って除いて、残りだけで success にしない。無ければ missing、1 つでも終わっていなければ pending、1 つでも success で
  # なければ failure。
  def check_run_state(api, base_path, head_sha, name)
    runs = []
    total = nil
    page = 1
    loop do
      query = URI.encode_www_form("check_name" => name, "per_page" => PER_PAGE, "page" => page)
      obj = api.get("#{base_path}/commits/#{head_sha}/check-runs?#{query}")
      unless obj.is_a?(Hash) && obj["check_runs"].is_a?(Array) && obj["total_count"].is_a?(Integer) && obj["check_runs"].all? { |r| r.is_a?(Hash) }
        raise RunError, "check-runs の応答の形が外れます"
      end

      total ||= obj["total_count"]
      raise RunError, "check-runs の total_count が page で変わりました (やり直す)" unless obj["total_count"] == total

      runs.concat(obj["check_runs"])
      break if runs.size >= total || obj["check_runs"].empty?

      page += 1
    end
    raise RunError, "check-runs の件数が total_count と一致しません (全件を読めない)" unless runs.size == total
    raise RunError, "check-runs の要素の名前が問い合わせた名前と合いません" unless runs.all? { |r| r["name"] == name }

    return "missing" if runs.empty?
    return "pending" unless runs.all? { |r| r["status"] == "completed" }
    return "failure" unless runs.all? { |r| r["conclusion"] == "success" }

    "success"
  end
end

exit MergePreflight.run(ARGV) if $PROGRAM_NAME == __FILE__
