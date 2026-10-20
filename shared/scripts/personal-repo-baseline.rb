#!/usr/bin/env ruby
# frozen_string_literal: true

# repo-baseline: GitHub の repo の設定を、あるべき姿 (baseline) と比べてずれを出す (#539)。読むだけで、GitHub
# に書かない (直す `--apply` は #539 の続きの PR)。運用 (最初に `--all` で全 repo を 1 回見て、その後は sweep が
# 今の repo だけを見る) は docs/repo-baseline.md。
#
# 対象:
# - 引数なし: 今の directory の repo (`gh repo view` が返すもの。env の GH_REPO は外して解決する)。
# - `--repo OWNER/REPO`: その repo。
# - `--all`: 認証した user が owner の repo を API で列挙し、fork・archive 済み・設定 file で除外した repo を外す。
# fork・archive 済み・設定 file で除外した repo・admin 権限の無い repo は「対象外」として確かめない。
#
# baseline は下の BASELINE (visibility ごと)。今のプランの private では ruleset と secret scanning が使えないので
# 確かめない。API で読めない項目 (Malware alerts、grouped security updates) は確かめず、「画面で確かめる」と
# 出す。Dependency graph は直接は読めないが、Dependabot alerts の前提なので alerts が on なら on。
#
# 手元の設定 file `${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/repo-baseline.json` は任意 (無ければ除外も必須の
# check も無し)。repo の名前は tracked な file に書かず、ここに置く。中身は JSON object で、key は次の 2 つだけ:
# - `exclude`: 対象から外す repo (OWNER/REPO) の配列。
# - `required_checks`: repo (OWNER/REPO) から、default branch の ruleset で必須にする check の名前 (空でない
#   文字列の配列) への object。書いた repo だけ必須の check を確かめる (CI の無い repo は書かない)。
# repo の名前は大文字小文字を区別しない。知らない key、型の外れ、制御文字は不正。XDG_CONFIG_HOME は絶対 path の
# ときだけ使い、HOME も絶対 path でなければ場所を決めずに止める (personal-usage-reader と同じ)。理由文に設定の
# 中身と path は出さない。
#
# GitHub は REST API の GET だけで読む (`gh api`。shell を通さない)。env の GH_REPO は gh に渡さない。
#
# exit:
# - 0: 確かめた repo にずれが無い (対象外だけのときを含む)。
# - 1: ずれが有る。
# - 2: usage / 設定 file が不正 / 今の repo や repo の一覧を解決できない / 確かめられない repo が有る (gh の失敗・
#   想定外の status・応答の field の欠落や null や型違い。ずれ無しや off に倒さない)。`--all` で一部の repo を確かめ
#   られないときも、残りの repo は確かめて出す。
# 結果は stdout、usage と設定 file の不正は stderr に 1 行。

require "erb"
require "json"
require "open3"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (file・gh の出力) を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module RepoBaseline
  EXIT_OK = 0
  EXIT_DRIFT = 1
  EXIT_ERROR = 2

  # baseline (あるべき姿)。visibility ごとに、確かめる項目とその期待値を持つ。ここに無い項目は確かめない。
  # - merge_methods: 許す merge の方式 (squash だけ)。
  # - ruleset_pull_request: default branch の ruleset で PR を必須にし、必要な approve の数は 0 (自分の PR は
  #   自分で approve できないので、1 以上にすると merge できなくなる)。
  # - ruleset_required_checks: 設定 file の required_checks に書いた check を必須にする (書いた repo だけ)。
  BASELINE = {
    "public" => {
      "dependabot_alerts" => true,
      "dependabot_security_updates" => true,
      "merge_methods" => %w[squash].freeze,
      "delete_branch_on_merge" => true,
      "dependabot_yml" => true,
      "secret_scanning" => true,
      "secret_scanning_push_protection" => true,
      "ruleset_pull_request" => 0,
      "ruleset_non_fast_forward" => true,
      "ruleset_deletion" => true,
      "ruleset_required_checks" => :config,
    }.freeze,
    "private" => {
      "dependabot_alerts" => true,
      "dependabot_security_updates" => true,
      "merge_methods" => %w[squash].freeze,
      "delete_branch_on_merge" => true,
      "dependabot_yml" => true,
    }.freeze,
  }.freeze

  LABELS = {
    "dependabot_alerts" => "Dependabot alerts (dependency graph を含む)",
    "dependabot_security_updates" => "Dependabot security updates",
    "merge_methods" => "merge の方式",
    "delete_branch_on_merge" => "merge の後に branch を消す",
    "dependabot_yml" => ".github/dependabot.yml (repo ごとの PR で足す。script では書かない)",
    "secret_scanning" => "Secret scanning",
    "secret_scanning_push_protection" => "Secret scanning の push protection",
    "ruleset_pull_request" => "default branch の ruleset: PR を必須にする",
    "ruleset_non_fast_forward" => "default branch の ruleset: force push の禁止",
    "ruleset_deletion" => "default branch の ruleset: 削除の禁止",
    "ruleset_required_checks" => "default branch の ruleset: 必須の check",
  }.freeze

  # repo の設定の field と merge の方式の対応。
  MERGE_FIELDS = {
    "allow_squash_merge" => "squash",
    "allow_merge_commit" => "merge commit",
    "allow_rebase_merge" => "rebase",
  }.freeze

  MANUAL_NOTE = "画面で確かめる (API で読めない): Malware alerts、Grouped security updates"
  UNAVAILABLE_NOTE = "private では確かめない (今のプランで使えない): default branch の ruleset、Secret scanning"
  # --all の集計の行で数える結果の status。
  SUMMARY_STATUSES = { ok: "ずれ無し", drift: "ずれ有り", error: "確かめられない" }.freeze
  CONFIG_KEYS = %w[exclude required_checks].freeze
  REPO_RE = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}.freeze
  LIST_PATH = "user/repos?affiliation=owner&per_page=100"
  # gh へ渡す env。GH_REPO は今の repo の解決を別の repo に向けるので外す。
  GH_ENV = { "GH_REPO" => nil }.freeze

  # repo を確かめられないことを表す (その repo の結果は「確かめられない」、全体の exit は 2)。
  class Error < StandardError; end

  # 1 repo の結果。status は :ok / :drift / :skipped / :error。findings は [項目, 今, あるべき] の配列。
  Result = Struct.new(:name, :visibility, :status, :findings, :reason)

  # 設定 file の JSON の object。同じ key が重なったら、後の値で前の値を消さずに不正にする (JSON.parse は既定で後の
  # 値を残すので、object_class で受ける)。
  class StrictHash < Hash
    def []=(key, value)
      raise ArgumentError, "設定 file に重なった key があります" if key?(key)

      super
    end
  end

  # 手元の設定。repo の名前は小文字にそろえて持つ。
  class Config
    def initialize(exclude, required_checks)
      @exclude = exclude
      @required_checks = required_checks
    end

    def excluded?(name)
      @exclude.include?(name.downcase)
    end

    def required_checks_for(name)
      @required_checks.fetch(name.downcase, [])
    end
  end

  module_function

  def usage
    "usage: personal-repo-baseline [--help] [--check] [--repo OWNER/REPO | --all]"
  end

  def help
    <<~TEXT
      #{usage}
      GitHub の repo の設定を baseline と比べてずれを出す (読むだけ。GitHub に書かない)。
      対象: 引数なし = 今の directory の repo / --repo = その repo / --all = 自分が owner の repo
      (fork・archive 済み・設定 file で除外した repo を除く)。
      exit 0 = ずれ無し / 1 = ずれ有り / 2 = usage・設定 file が不正・確かめられない repo が有る。
      設定 file (任意): ${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/repo-baseline.json
      (key は exclude と required_checks。docs/repo-baseline.md)。
    TEXT
  end

  # OWNER/REPO の形。`.` / `..` の成分と `-` 始まりは、API の path を別の場所へ向けうるので受けない。
  def valid_repo?(name)
    return false unless name.is_a?(String) && name.match?(REPO_RE)

    name.split("/").none? { |part| part.start_with?("-") || %w[. ..].include?(part) }
  end

  def parse_args(args)
    target = nil
    rest = args.dup
    until rest.empty?
      arg = rest.shift
      case arg
      when "--check"
        next
      when "--all"
        raise ArgumentError, usage unless target.nil?

        target = :all
      when "--repo"
        raise ArgumentError, usage unless target.nil? && !rest.empty?

        value = rest.shift
        raise ArgumentError, "--repo の値が OWNER/REPO の形ではありません" unless valid_repo?(value)

        target = value
      else
        raise ArgumentError, usage
      end
    end
    target || :current
  end

  # ---- 設定 file ----

  def config_path
    base = ENV["XDG_CONFIG_HOME"].to_s
    base = File.join(Dir.home, ".config") unless base.start_with?("/")
    raise ArgumentError, "設定 file の場所を決められません (HOME が絶対 path ではありません)" unless base.start_with?("/")

    File.join(base, "agent-tools", "repo-baseline.json")
  end

  # 無い file は nil (設定なし)。在るのに regular file でない・確かめられない・読めない file は不正。symlink は辿った
  # 先で判定する (personal-usage-reader と同じ扱い)。
  def read_config(path)
    begin
      stat = File.stat(path)
    rescue Errno::ENOENT
      return nil
    end
    raise ArgumentError, "設定 file が regular file ではありません" unless stat.file?

    File.read(path, encoding: "UTF-8")
  rescue SystemCallError => e
    raise ArgumentError, "設定 file を確かめられないか読めません (#{e.class})"
  end

  def parse_config(text)
    return Config.new([], {}) if text.nil?
    raise ArgumentError, "設定 file が UTF-8 として読めません" unless text.valid_encoding?

    data = begin
      JSON.parse(text, object_class: StrictHash)
    rescue JSON::ParserError
      raise ArgumentError, "設定 file が JSON として読めません"
    end
    raise ArgumentError, "設定 file の top-level が object ではありません" unless data.is_a?(Hash)
    raise ArgumentError, "設定 file に知らない key があります" unless (data.keys - CONFIG_KEYS).empty?

    exclude = data.fetch("exclude", [])
    unless exclude.is_a?(Array) && exclude.all? { |name| valid_repo?(name) }
      raise ArgumentError, "設定 file の exclude が OWNER/REPO の配列ではありません"
    end

    required = data.fetch("required_checks", {})
    raise ArgumentError, "設定 file の required_checks が object ではありません" unless required.is_a?(Hash)

    checks = {}
    required.each do |name, list|
      raise ArgumentError, "設定 file の required_checks の key が OWNER/REPO の形ではありません" unless valid_repo?(name)
      unless list.is_a?(Array) && !list.empty? && list.all? { |c| valid_check_name?(c) }
        raise ArgumentError, "設定 file の required_checks の値が空でない check の名前の配列ではありません"
      end
      # 大文字小文字だけ違う key は同じ repo なので、後の値で前の値を消さずに不正にする。
      raise ArgumentError, "設定 file の required_checks に大文字小文字だけ違う key が重なっています" if checks.key?(name.downcase)

      checks[name.downcase] = list
    end
    Config.new(exclude.map(&:downcase), checks)
  end

  def valid_check_name?(name)
    name.is_a?(String) && !name.strip.empty? && name.valid_encoding? && name !~ /[[:cntrl:]]/
  end

  def load_config
    parse_config(read_config(config_path))
  end

  # ---- gh ----

  def gh(args)
    out, _err, status = Open3.capture3(GH_ENV, "gh", *args)
    [out, status]
  rescue SystemCallError
    raise Error, "gh を起動できません"
  end

  def gh_json(path, label)
    out, status = gh(["api", path])
    raise Error, "#{label} を読めません (gh api が失敗)" unless status.success?

    JSON.parse(out)
  rescue JSON::ParserError
    raise Error, "#{label} の応答が JSON ではありません"
  end

  # 応答の status code だけを読む (`gh api -i` の 1 行目)。gh は 4xx・5xx でも status 行を stdout に出して非 0 で
  # 終わるので、終了状態だけでは失敗と分けられない。2xx なのに gh が失敗したとき (受信の途中の失敗など) は、
  # 応答を受け取れていないので確かめられないにする。
  def gh_status(path, label)
    out, status = gh(["api", "-i", path])
    code = out[%r{\AHTTP/\S+ (\d{3})}, 1]
    raise Error, "#{label} を読めません (応答に status が無い)" if code.nil?
    raise Error, "#{label} を読めません (gh api が失敗)" if code.to_i < 300 && !status.success?

    code.to_i
  end

  # ページングされる list の API を全ページ読む (`--slurp` で各ページを 1 要素にまとめ、平坦にする)。
  def gh_list(path, label)
    out, status = gh(["api", "--paginate", "--slurp", path])
    raise Error, "#{label} を読めません (gh api が失敗)" unless status.success?

    pages = JSON.parse(out)
    unless pages.is_a?(Array) && pages.all? { |page| page.is_a?(Array) }
      raise Error, "#{label} を読めません (応答の形が想定外)"
    end

    pages.flatten(1)
  rescue JSON::ParserError
    raise Error, "#{label} の応答が JSON ではありません"
  end

  def current_repo
    out, status = gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])
    name = out.strip
    unless status.success? && valid_repo?(name)
      raise Error, "今の directory の repo を解決できません (--repo OWNER/REPO で指定してください)"
    end

    name
  end

  # 自分が owner の repo を全ページ読む。
  def owned_repos
    repos = gh_list(LIST_PATH, "repo の一覧 (user/repos)")
    raise Error, "repo の一覧 (user/repos) を読めません (応答の形が想定外)" unless repos.all? { |r| r.is_a?(Hash) && valid_repo?(r["full_name"]) }

    repos
  end

  # ---- 設定を読む ----

  def enabled_by_status(code, label, on, off)
    return true if code == on
    return false if code == off

    raise Error, "#{label} の応答が想定外です (HTTP #{code})"
  end

  # GitHub の応答の field は、欠落・null・型違いを「確かめられない」(Error) にする。ずれ無しや off に倒さない。
  def boolean!(value, label)
    raise Error, "#{label} を読めません (値が無い)" unless value == true || value == false

    value
  end

  def hash!(value, label)
    raise Error, "#{label} を読めません (応答の形が想定外)" unless value.is_a?(Hash)

    value
  end

  def string!(value, label)
    raise Error, "#{label} を読めません (応答の形が想定外)" unless value.is_a?(String) && !value.empty?

    value
  end

  def merge_methods(repo)
    MERGE_FIELDS.select { |field, _| boolean!(repo[field], "merge の方式") }.values
  end

  def dependabot_yml?(name)
    %w[dependabot.yml dependabot.yaml].any? do |file|
      enabled_by_status(gh_status("repos/#{name}/contents/.github/#{file}", ".github/#{file}"), ".github/#{file}", 200, 404)
    end
  end

  def secret_scanning(repo, key)
    sa = hash!(repo["security_and_analysis"], "security_and_analysis")
    status = hash!(sa[key], key)["status"]
    raise Error, "#{key} を読めません (応答の形が想定外)" unless %w[enabled disabled].include?(status)

    status == "enabled"
  end

  # default branch に効く rule (全 ruleset の和) を全ページ読む。branch の名前は 1 つの path の成分に encode する
  # (`/` も %2F に)。`.` / `..` は API の path を別の場所へ向けうるので受けない。
  def branch_rules(name, branch)
    string!(branch, "default branch")
    raise Error, "default branch を読めません (応答の形が想定外)" if %w[. ..].include?(branch)

    path = "repos/#{name}/rules/branches/#{ERB::Util.url_encode(branch)}?per_page=100"
    rules = gh_list(path, "default branch の rule")
    unless rules.is_a?(Array) && rules.all? { |r| r.is_a?(Hash) && r["type"].is_a?(String) }
      raise Error, "default branch の rule を読めません (応答の形が想定外)"
    end

    rules
  end

  def ruleset_facts(rules)
    # 複数の ruleset が PR の rule を持つときは、いちばん厳しい (approve の数が多い) ものが効く。
    approvals = rules.select { |r| r["type"] == "pull_request" }.map do |r|
      count = hash!(r["parameters"], "PR の rule")["required_approving_review_count"]
      raise Error, "PR の rule の必要な approve の数を読めません" unless count.is_a?(Integer)

      count
    end
    contexts = rules.select { |r| r["type"] == "required_status_checks" }.flat_map do |r|
      checks = hash!(r["parameters"], "必須の check の rule")["required_status_checks"]
      raise Error, "必須の check の rule を読めません (応答の形が想定外)" unless checks.is_a?(Array)

      checks.map { |c| string!(hash!(c, "必須の check")["context"], "必須の check の名前") }
    end
    {
      "ruleset_pull_request" => approvals.max,
      "ruleset_non_fast_forward" => rules.any? { |r| r["type"] == "non_fast_forward" },
      "ruleset_deletion" => rules.any? { |r| r["type"] == "deletion" },
      "ruleset_required_checks" => contexts.uniq,
    }
  end

  # baseline の項目のうち、その visibility で確かめるものだけを GitHub から読む。
  def collect_facts(name, repo, visibility)
    items = BASELINE.fetch(visibility).keys
    facts = {
      "dependabot_alerts" => enabled_by_status(
        gh_status("repos/#{name}/vulnerability-alerts", "Dependabot alerts"), "Dependabot alerts", 204, 404
      ),
      "merge_methods" => merge_methods(repo),
      "delete_branch_on_merge" => boolean!(repo["delete_branch_on_merge"], "merge の後に branch を消す設定"),
      "dependabot_yml" => dependabot_yml?(name),
    }
    fixes = hash!(gh_json("repos/#{name}/automated-security-fixes", "Dependabot security updates"), "Dependabot security updates")
    facts["dependabot_security_updates"] = boolean!(fixes["enabled"], "Dependabot security updates")
    if items.include?("secret_scanning")
      facts["secret_scanning"] = secret_scanning(repo, "secret_scanning")
      facts["secret_scanning_push_protection"] = secret_scanning(repo, "secret_scanning_push_protection")
    end
    facts.merge!(ruleset_facts(branch_rules(name, repo["default_branch"]))) if items.any? { |i| i.start_with?("ruleset_") }
    facts
  end

  # ---- 比べる (純粋) ----

  # facts を baseline と比べて、ずれ ([項目, 今, あるべき]) を返す。
  def evaluate(visibility, facts, required_checks)
    BASELINE.fetch(visibility).each_with_object([]) do |(item, expected), findings|
      actual = facts.fetch(item)
      if expected == :config
        next if required_checks.empty?

        findings << [item, actual, required_checks] unless (required_checks - actual).empty?
      elsif actual != expected
        findings << [item, actual, expected]
      end
    end
  end

  def describe(item, value)
    case item
    when "merge_methods"
      value.empty? ? "無し" : value.join("、")
    when "dependabot_yml"
      value ? "有る" : "無い"
    when "ruleset_pull_request"
      value.nil? ? "無い" : "有る (必要な approve #{value.inspect})"
    when "ruleset_required_checks"
      value.empty? ? "無い" : value.join("、")
    else
      value ? "on" : "off"
    end
  end

  def describe_expected(item, value)
    case item
    when "merge_methods" then "#{value.join('、')} だけ"
    when "ruleset_required_checks" then "#{value.join('、')} を含む"
    else describe(item, value)
    end
  end

  # ---- 1 repo を確かめる ----

  def skipped(name, reason)
    Result.new(name, nil, :skipped, [], reason)
  end

  def check_repo(name, config)
    return skipped(name, "設定 file で除外") if config.excluded?(name)

    repo = hash!(gh_json("repos/#{name}", "repo"), "repo")
    raise Error, "repo を読めません (応答の形が想定外)" unless valid_repo?(repo["full_name"])

    name = repo["full_name"]
    return skipped(name, "設定 file で除外") if config.excluded?(name)
    return skipped(name, "fork") if boolean!(repo["fork"], "fork の field")
    return skipped(name, "archive 済み") if boolean!(repo["archived"], "archived の field")
    permissions = hash!(repo["permissions"], "permissions の field")
    return skipped(name, "admin 権限が無い") unless boolean!(permissions["admin"], "permissions.admin の field")

    visibility = repo["visibility"]
    raise Error, "baseline の無い visibility です" unless BASELINE.key?(visibility)

    findings = evaluate(visibility, collect_facts(name, repo, visibility), config.required_checks_for(name))
    Result.new(name, visibility, findings.empty? ? :ok : :drift, findings, nil)
  rescue Error => e
    Result.new(name, nil, :error, [], e.message)
  rescue TypeError, NoMethodError => e
    # 上の検査が見落とした応答の型違い。その repo だけ「確かめられない」にして、--all の残りを続ける。
    Result.new(name, nil, :error, [], "応答の形が想定外です (#{e.class})")
  end

  # 全 repo。fork・archive 済み・設定 file で除外した repo は一覧の段で外す (一覧の field が欠けていれば
  # check_repo が改めて読んで確かめる)。対象外は、一覧の段と check_repo の段の両方を理由ごとに数える。
  def check_all(config)
    counts = { "fork" => 0, "archive 済み" => 0, "設定 file で除外" => 0 }
    targets = []
    owned_repos.each do |repo|
      name = repo["full_name"]
      if repo["fork"] == true
        counts["fork"] += 1
      elsif repo["archived"] == true
        counts["archive 済み"] += 1
      elsif config.excluded?(name)
        counts["設定 file で除外"] += 1
      else
        targets << name
      end
    end
    results = targets.sort_by(&:downcase).map { |name| check_repo(name, config) }
    results.select { |r| r.status == :skipped }.each { |r| counts[r.reason] = counts.fetch(r.reason, 0) + 1 }
    [results, counts]
  end

  def summary_line(results, counts)
    targets = results.reject { |r| r.status == :skipped }
    detail = SUMMARY_STATUSES.map { |status, label| "#{label} #{targets.count { |r| r.status == status }}" }.join("・")
    skipped = counts.map { |reason, n| "#{reason} #{n} 件" }.join("・")
    "対象の repo: #{targets.size} 件 (#{detail}) / 対象外: #{skipped}"
  end

  # ---- 出す ----

  def render(results, counts)
    lines = []
    results.each do |r|
      case r.status
      when :ok
        lines << "#{r.name} (#{r.visibility}): ずれ無し"
      when :drift
        lines << "#{r.name} (#{r.visibility}): ずれ #{r.findings.size} 件"
        r.findings.each do |item, actual, expected|
          lines << "  - #{LABELS.fetch(item)}: 今 #{describe(item, actual)} / あるべき #{describe_expected(item, expected)}"
        end
      when :skipped
        lines << "#{r.name}: 対象外 (#{r.reason})"
      else
        lines << "#{r.name}: 確かめられない (#{r.reason})"
      end
    end
    lines << summary_line(results, counts) if counts
    checked = results.select { |r| %i[ok drift].include?(r.status) }
    lines << UNAVAILABLE_NOTE if checked.any? { |r| r.visibility == "private" }
    lines << MANUAL_NOTE unless checked.empty?
    lines.map { |line| "#{line}\n" }.join
  end

  def exit_code(results)
    return EXIT_ERROR if results.any? { |r| r.status == :error }
    return EXIT_DRIFT if results.any? { |r| r.status == :drift }

    EXIT_OK
  end

  def run(args)
    if args == ["--help"]
      $stdout.write(help)
      return EXIT_OK
    end
    target = parse_args(args)
    config = load_config
    results, counts =
      case target
      when :all then check_all(config)
      when :current then [[check_repo(current_repo, config)], nil]
      else [[check_repo(target, config)], nil]
      end
    $stdout.write(render(results, counts))
    exit_code(results)
  rescue ArgumentError, Error => e
    warn "personal-repo-baseline: #{e.message}"
    EXIT_ERROR
  rescue SignalException => e
    warn "personal-repo-baseline: signal (SIG#{Signal.signame(e.signo)}) で中断しました"
    EXIT_ERROR
  rescue StandardError => e
    warn "personal-repo-baseline: unexpected error (#{e.class})"
    EXIT_ERROR
  end
end

exit RepoBaseline.run(ARGV) if $PROGRAM_NAME == __FILE__
