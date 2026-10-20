#!/usr/bin/env ruby
# frozen_string_literal: true

# repo-baseline: GitHub の repo の設定を、あるべき姿 (baseline) と比べてずれを出し、`--apply` のときだけ直す (#539)。
# 既定 (`--check`) は読むだけで、GitHub に書かない。運用 (最初に `--all` で全 repo を 1 回見て、その後は sweep が
# 今の repo だけを見る。直すのは人が承認したときだけ) は docs/repo-baseline.md。
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
# 設定は 2 か所 (#545):
# - 手元の設定 file `${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/repo-baseline.json` (任意)。key は `exclude`
#   (対象から外す repo (OWNER/REPO) の配列) だけ。「この repo には触らない」は人の判断なので repo には書かず、repo の
#   名前は tracked な file に書かないのでここに置く。repo の名前は大文字小文字を区別しない。知らない key と型の外れは
#   不正。`required_checks` は repo の設定 file に移したので不正 (移行は切り替え)。XDG_CONFIG_HOME は絶対 path の
#   ときだけ使い、HOME も絶対 path でなければ場所を決めずに止める (personal-usage-reader と同じ)。理由文に設定の
#   中身と path は出さない。
# - repo の設定 file `.github/repo-baseline.json` (任意。default branch のものを contents API で読む)。repo ごとの
#   事実を、その repo の PR で変える。key は `skip` (確かめない項目。外せるのは SKIPPABLE だけ) と `required_checks`
#   (default branch の ruleset で必須にする check の名前)。書くなら空でない配列。知らない key、型の外れ、知らない
#   項目の名前、制御文字、値や key の重なり、大きすぎる file は、その repo を確かめられないにする。
#
# GitHub は REST API で読み書きする (`gh api`。shell を通さない)。env の GH_REPO は gh に渡さない。`--check` は GET
# だけ。
#
# `--apply`: 確かめてずれていた項目のうち、API で直せるものだけを直し、直した後に読み直してずれが消えたことを
# 確かめる。ずれの無い repo には書かない (何度実行しても同じ結果)。直すもの:
# - Dependabot alerts (dependency graph も有効になる) → security updates の順に PUT。
# - merge の方式と merge の後に branch を消す設定 → repo を PATCH (4 つの field をまとめて)。
# - public の secret scanning と push protection → repo の security_and_analysis を PATCH。
# - public の default branch の ruleset → この script が持つ名前 (RULESET_NAME) の ruleset だけを作るか更新する
#   (PR の必須 (approve 0)・force push と削除の禁止・repo の設定 file の必須の check。bypass は無し)。他の ruleset は
#   触らない (他の ruleset が厳しくしているずれは、直した後も残るので「確かめられないか直せない」になる)。
# `.github/dependabot.yml` は書かない (repo ごとの PR で足す)。API で変えられない項目は「画面で確かめる」のまま。
#
# exit:
# - 0: 確かめた repo にずれが無い (対象外だけのときを含む。`--apply` では、直してずれが無くなったときを含む)。
# - 1: ずれが有る (`--apply` では、script が直さない項目 (dependabot.yml) のずれが残る)。
# - 2: usage / 手元の設定 file が不正 / 今の repo や repo の一覧を解決できない / 確かめられない repo が有る (gh の
#   失敗・想定外の status・応答の field の欠落や null や型違い・repo の設定 file の不正。ずれ無しや off に倒さない) /
#   `--apply` で直せない (書き込みの失敗、直した後もずれが残る)。`--all` で一部の repo を確かめられないときも、残りの
#   repo は確かめて出す。
# 結果は stdout (repo ごとの「確かめられない」の理由もその repo の行)。run 全体の失敗 (usage・手元の設定 file の不正・
# 今の repo や repo の一覧を解決できない) は stderr に 1 行。

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
  # - ruleset_required_checks: repo の設定 file の required_checks に書いた check を必須にする (書いた repo だけ)。
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
  SUMMARY_STATUSES = { ok: "ずれ無し", fixed: "直した", drift: "ずれ有り", error: "確かめられない" }.freeze
  # --apply が作って更新する ruleset の名前。この名前の ruleset だけを持ち主として扱い、他の ruleset は触らない。
  RULESET_NAME = "personal-repo-baseline"
  # merge の設定の field のあるべき値 (--apply が PATCH する)。
  MERGE_SETTINGS = {
    "allow_squash_merge" => true,
    "allow_merge_commit" => false,
    "allow_rebase_merge" => false,
    "delete_branch_on_merge" => true,
  }.freeze
  SECRET_SCANNING_ITEMS = %w[secret_scanning secret_scanning_push_protection].freeze
  RULESET_ITEMS = %w[ruleset_pull_request ruleset_non_fast_forward ruleset_deletion ruleset_required_checks].freeze
  CONFIG_KEYS = %w[exclude].freeze
  # repo ごとの設定 file (任意)。default branch のものを contents API で読む。
  REPO_FILE = ".github/repo-baseline.json"
  REPO_FILE_LABEL = "repo の設定 file (#{REPO_FILE})"
  REPO_FILE_MAX = 64 * 1024
  REPO_KEYS = %w[skip required_checks].freeze
  # repo の設定 file の skip で外せる項目。security に関わる項目は、repo の PR 1 本で守りを外せることになるので
  # 外せない (#545)。
  SKIPPABLE = %w[dependabot_yml].freeze
  OMIT_LABELS = { "dependabot_yml" => ".github/dependabot.yml" }.freeze
  REPO_RE = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}.freeze
  LIST_PATH = "user/repos?affiliation=owner&per_page=100"
  # gh へ渡す env。GH_REPO は今の repo の解決を別の repo に向けるので外す。
  GH_ENV = { "GH_REPO" => nil }.freeze

  # repo を確かめられないことを表す (その repo の結果は「確かめられない」、全体の exit は 2)。
  class Error < StandardError; end

  # --apply が書いた後に止まったことを表す。written は書き込みが成功した項目 (結果に「書いた」として残し、戻すときに
  # 変えた範囲を追えるようにする)。
  class ApplyError < Error
    attr_reader :written

    def initialize(message, written)
      super(message)
      @written = written
    end
  end

  # 1 repo の結果。status は :ok / :fixed / :drift / :skipped / :error。findings は [項目, 今, あるべき] の配列
  # (--apply では直した後に残ったずれ)。fixed は --apply が直した項目。omitted は repo の設定 file の skip で外した
  # 項目 (確かめた repo だけ。出力に外したことを出す)。
  Result = Struct.new(:name, :visibility, :status, :findings, :reason, :fixed, :omitted)

  # repo の設定 file の中身。skip は確かめない項目、required_checks は default branch の ruleset で必須にする check。
  RepoSettings = Struct.new(:skip, :required_checks)
  NO_SETTINGS = RepoSettings.new([].freeze, [].freeze).freeze

  # 引数の解釈の結果。mode は :check / :apply、target は :current / :all / OWNER/REPO。
  Options = Struct.new(:mode, :target)

  # --apply の 1 回の書き込み。items はこの書き込みで直す baseline の項目。
  Action = Struct.new(:items, :method, :path, :body, :label)

  # JSON の object の key の重なり (StrictHash が出す。読んだ file ごとに理由を付け直す)。
  class DuplicateKeyError < StandardError; end

  # 設定 file の JSON の object。同じ key が重なったら、後の値で前の値を消さずに不正にする (JSON.parse は既定で後の
  # 値を残すので、object_class で受ける)。
  class StrictHash < Hash
    def []=(key, value)
      raise DuplicateKeyError if key?(key)

      super
    end
  end

  # 手元の設定。repo の名前は小文字にそろえて持つ。
  class Config
    def initialize(exclude)
      @exclude = exclude
    end

    def excluded?(name)
      @exclude.include?(name.downcase)
    end
  end

  module_function

  def usage
    "usage: personal-repo-baseline [--help] [--check | --apply] [--repo OWNER/REPO | --all]"
  end

  def help
    <<~TEXT
      #{usage}
      GitHub の repo の設定を baseline と比べてずれを出す。--check (既定) は読むだけで GitHub に書かない。
      --apply はずれのうち API で直せるものだけを直し、直した後に読み直して確かめる (dependabot.yml は書かない)。
      対象: 引数なし = 今の directory の repo / --repo = その repo / --all = 自分が owner の repo
      (fork・archive 済み・設定 file で除外した repo を除く)。
      exit 0 = ずれ無し (--apply で直し終えたときを含む) / 1 = ずれ有り / 2 = usage・設定 file が不正・
      確かめられないか直せない repo が有る。
      手元の設定 file (任意): ${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/repo-baseline.json (key は exclude)。
      repo の設定 file (任意): 各 repo の .github/repo-baseline.json (key は skip と required_checks)。
      docs/repo-baseline.md。
    TEXT
  end

  # OWNER/REPO の形。`.` / `..` の成分と `-` 始まりは、API の path を別の場所へ向けうるので受けない。
  def valid_repo?(name)
    return false unless name.is_a?(String) && name.match?(REPO_RE)

    name.split("/").none? { |part| part.start_with?("-") || %w[. ..].include?(part) }
  end

  def parse_args(args)
    mode = nil
    target = nil
    rest = args.dup
    until rest.empty?
      arg = rest.shift
      case arg
      when "--check", "--apply"
        raise ArgumentError, usage unless mode.nil?

        mode = arg == "--apply" ? :apply : :check
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
    Options.new(mode || :check, target || :current)
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
    return Config.new([]) if text.nil?
    raise ArgumentError, "設定 file が UTF-8 として読めません" unless text.valid_encoding?

    data = begin
      JSON.parse(text, object_class: StrictHash)
    rescue JSON::ParserError
      raise ArgumentError, "設定 file が JSON として読めません"
    rescue DuplicateKeyError
      raise ArgumentError, "設定 file に重なった key があります"
    end
    raise ArgumentError, "設定 file の top-level が object ではありません" unless data.is_a?(Hash)
    # 移行は切り替え (#545): 手元に残った required_checks は、どちらが効くのかが曖昧になるので読まずに止める。
    if data.key?("required_checks")
      raise ArgumentError, "設定 file の required_checks は、各 repo の #{REPO_FILE} に移しました"
    end
    raise ArgumentError, "設定 file に知らない key があります" unless (data.keys - CONFIG_KEYS).empty?

    exclude = data.fetch("exclude", [])
    unless exclude.is_a?(Array) && exclude.all? { |name| valid_repo?(name) }
      raise ArgumentError, "設定 file の exclude が OWNER/REPO の配列ではありません"
    end

    Config.new(exclude.map(&:downcase))
  end

  # repo の設定 file の中身 (JSON の text) を読む。不正なら、その repo を確かめられないにする (Error)。理由に中身は
  # 出さない。key は skip と required_checks だけで、書くなら空でない配列。
  def parse_repo_settings(text)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise Error, "#{REPO_FILE_LABEL} が UTF-8 として読めません" unless text.valid_encoding?

    data = begin
      JSON.parse(text, object_class: StrictHash)
    rescue JSON::ParserError
      raise Error, "#{REPO_FILE_LABEL} が JSON として読めません"
    rescue DuplicateKeyError
      raise Error, "#{REPO_FILE_LABEL} に重なった key があります"
    end
    raise Error, "#{REPO_FILE_LABEL} の top-level が object ではありません" unless data.is_a?(Hash)
    raise Error, "#{REPO_FILE_LABEL} に知らない key があります" unless (data.keys - REPO_KEYS).empty?

    # key を書いたら値は空でない配列 (null も不正。省略と区別し、設定なしに倒さない)。
    skip = data.key?("skip") ? data["skip"] : []
    unless !data.key?("skip") || (skip.is_a?(Array) && !skip.empty? && skip.all? { |item| SKIPPABLE.include?(item) })
      raise Error, "#{REPO_FILE_LABEL} の skip が外せる項目 (#{SKIPPABLE.join('、')}) の空でない配列ではありません"
    end
    checks = data.key?("required_checks") ? data["required_checks"] : []
    unless !data.key?("required_checks") || (checks.is_a?(Array) && !checks.empty? && checks.all? { |c| valid_check_name?(c) })
      raise Error, "#{REPO_FILE_LABEL} の required_checks が空でない check の名前の配列ではありません"
    end
    [["skip", skip], ["required_checks", checks]].each do |key, list|
      raise Error, "#{REPO_FILE_LABEL} の #{key} に重なった値があります" if list.uniq.size != list.size
    end
    RepoSettings.new(skip.freeze, checks.freeze)
  end

  # valid_encoding? を先に見る (JSON の \uDC00 のような孤立した surrogate は不正な UTF-8 の文字列になり、strip や
  # 正規表現が ArgumentError を出す)。
  def valid_check_name?(name)
    name.is_a?(String) && name.valid_encoding? && !name.strip.empty? && name !~ /[[:cntrl:]]/
  end

  def load_config
    parse_config(read_config(config_path))
  end

  # ---- gh ----

  def gh(args, stdin: "")
    out, _err, status = Open3.capture3(GH_ENV, "gh", *args, stdin_data: stdin)
    [out, status]
  rescue SystemCallError
    raise Error, "gh を起動できません"
  end

  # --apply の書き込み。body は JSON にして stdin から渡す (`--input -`。command 行に値を埋め込まない)。
  def gh_write(action)
    args = ["api", "-X", action.method, action.path]
    args += ["--input", "-"] if action.body
    _out, status = gh(args, stdin: action.body ? JSON.generate(action.body) : "")
    raise Error, "直せません: #{action.label} (gh api が失敗)" unless status.success?
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

  # repo の設定 file (任意) を default branch から読む。無ければ (404) 設定なし。file でない (directory・symlink・
  # submodule)、base64 でない・壊れた base64、size が負・本文と合わない、大きすぎる応答は確かめられないにする (設定
  # なしに倒さない)。
  def repo_settings(name)
    path = "repos/#{name}/contents/#{REPO_FILE}"
    code = gh_status(path, REPO_FILE_LABEL)
    return NO_SETTINGS if code == 404
    raise Error, "#{REPO_FILE_LABEL} の応答が想定外です (HTTP #{code})" unless code == 200

    entry = hash!(gh_json(path, REPO_FILE_LABEL), REPO_FILE_LABEL)
    size = entry["size"]
    unless entry["type"] == "file" && entry["encoding"] == "base64" && entry["content"].is_a?(String) &&
           size.is_a?(Integer) && size >= 0
      raise Error, "#{REPO_FILE_LABEL} を読めません (応答の形が想定外)"
    end
    raise Error, "#{REPO_FILE_LABEL} が大きすぎます" if size > REPO_FILE_MAX

    parse_repo_settings(decode_content(entry["content"], size))
  end

  # contents API の base64 (60 文字ごとに改行が入る) を厳密に decode する。改行のほかの alphabet の外の文字や
  # padding の誤りは、読み飛ばさずに確かめられないにする (`unpack1("m")` は読み飛ばす)。本文の byte 数は size と
  # 合うことを求める。
  def decode_content(content, size)
    text = begin
      content.delete("\n").unpack1("m0")
    rescue ArgumentError
      raise Error, "#{REPO_FILE_LABEL} を読めません (base64 が壊れている)"
    end
    raise Error, "#{REPO_FILE_LABEL} を読めません (size が本文と合わない)" unless text.bytesize == size

    text
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

  # baseline の項目のうち、その visibility で確かめるものだけを GitHub から読む。skip (repo の設定 file で外した
  # 項目) は読まない。
  def collect_facts(name, repo, visibility, skip = [])
    items = BASELINE.fetch(visibility).keys - skip
    facts = {
      "dependabot_alerts" => enabled_by_status(
        gh_status("repos/#{name}/vulnerability-alerts", "Dependabot alerts"), "Dependabot alerts", 204, 404
      ),
      "merge_methods" => merge_methods(repo),
      "delete_branch_on_merge" => boolean!(repo["delete_branch_on_merge"], "merge の後に branch を消す設定"),
    }
    facts["dependabot_yml"] = dependabot_yml?(name) if items.include?("dependabot_yml")
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

  # facts を baseline と比べて、ずれ ([項目, 今, あるべき]) を返す。skip (repo の設定 file で外した項目) は比べない。
  def evaluate(visibility, facts, required_checks, skip = [])
    BASELINE.fetch(visibility).each_with_object([]) do |(item, expected), findings|
      next if skip.include?(item)

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

  # ---- 直す (--apply) ----

  # --apply が作る / 更新する ruleset (default branch に、PR の必須 (approve 0)・force push と削除の禁止・repo の設定
  # file の必須の check)。bypass は持たない。
  def desired_ruleset(required_checks)
    rules = [
      {
        "type" => "pull_request",
        "parameters" => {
          "dismiss_stale_reviews_on_push" => false,
          "require_code_owner_review" => false,
          "require_last_push_approval" => false,
          "required_approving_review_count" => 0,
          "required_review_thread_resolution" => false,
        },
      },
      { "type" => "non_fast_forward" },
      { "type" => "deletion" },
    ]
    unless required_checks.empty?
      rules << {
        "type" => "required_status_checks",
        "parameters" => {
          "strict_required_status_checks_policy" => false,
          "required_status_checks" => required_checks.map { |c| { "context" => c } },
        },
      }
    end
    {
      "name" => RULESET_NAME,
      "target" => "branch",
      "enforcement" => "active",
      "bypass_actors" => [],
      "conditions" => { "ref_name" => { "include" => ["~DEFAULT_BRANCH"], "exclude" => [] } },
      "rules" => rules,
    }
  end

  # この script が持つ ruleset (RULESET_NAME) の id。無ければ nil。同じ名前が複数あれば持ち主を決められないので止める。
  def managed_ruleset_id(name)
    rulesets = gh_list("repos/#{name}/rulesets?includes_parents=false&per_page=100", "ruleset の一覧 (rulesets)")
    unless rulesets.all? { |r| r.is_a?(Hash) && r["name"].is_a?(String) }
      raise Error, "ruleset の一覧 (rulesets) を読めません (応答の形が想定外)"
    end

    owned = rulesets.select { |r| r["name"] == RULESET_NAME }
    raise Error, "#{RULESET_NAME} という名前の ruleset が複数あります" if owned.size > 1
    return nil if owned.empty?

    id = owned.first["id"]
    raise Error, "ruleset の id を読めません (応答の形が想定外)" unless id.is_a?(Integer) && id.positive?

    id
  end

  # ずれの項目から、直す書き込みを依存の順 (alerts → security updates) に組む (純粋)。直せない項目
  # (dependabot_yml) には書き込みを作らない。
  def fix_actions(name, items, required_checks, ruleset_id)
    actions = []
    if items.include?("dependabot_alerts")
      actions << Action.new(%w[dependabot_alerts], "PUT", "repos/#{name}/vulnerability-alerts", nil, "Dependabot alerts")
    end
    if items.include?("dependabot_security_updates")
      actions << Action.new(%w[dependabot_security_updates], "PUT", "repos/#{name}/automated-security-fixes", nil,
                            "Dependabot security updates")
    end
    merge = items & %w[merge_methods delete_branch_on_merge]
    actions << Action.new(merge, "PATCH", "repos/#{name}", MERGE_SETTINGS, "merge の設定") unless merge.empty?
    secret = items & SECRET_SCANNING_ITEMS
    unless secret.empty?
      body = { "security_and_analysis" => SECRET_SCANNING_ITEMS.map { |key| [key, { "status" => "enabled" }] }.to_h }
      actions << Action.new(secret, "PATCH", "repos/#{name}", body, "Secret scanning")
    end
    rules = items & RULESET_ITEMS
    unless rules.empty?
      method, path = ruleset_id ? ["PUT", "repos/#{name}/rulesets/#{ruleset_id}"] : ["POST", "repos/#{name}/rulesets"]
      actions << Action.new(rules, method, path, desired_ruleset(required_checks), "default branch の ruleset")
    end
    actions
  end

  # ずれのうち API で直せるものを直し、読み直して確かめる。書き込みの失敗、読み直しの失敗、直したはずの項目のずれの
  # 残り (他の ruleset が厳しくしているなど) のどれで止まっても、書き込みが成功した項目を ApplyError に添える。
  def apply_fixes(name, visibility, findings, settings)
    items = findings.map(&:first)
    ruleset_id = (items & RULESET_ITEMS).empty? ? nil : managed_ruleset_id(name)
    actions = fix_actions(name, items, settings.required_checks, ruleset_id)
    return Result.new(name, visibility, :drift, findings, nil, []) if actions.empty?

    written = []
    actions.each do |action|
      begin
        gh_write(action)
      rescue Error => e
        raise ApplyError.new(e.message, written)
      end
      written.concat(action.items)
    end
    remaining = begin
      facts = collect_facts(name, read_repo(name), visibility, settings.skip)
      evaluate(visibility, facts, settings.required_checks, settings.skip)
    rescue Error, TypeError, NoMethodError, ArgumentError, EncodingError => e
      reason = e.is_a?(Error) ? e.message : "応答の形が想定外です (#{e.class})"
      raise ApplyError.new("確かめ直せません: #{reason}", written)
    end
    left = remaining.map(&:first) & written
    unless left.empty?
      raise ApplyError.new("直した後もずれが残っています: #{left.map { |item| LABELS.fetch(item) }.join('、')}", written)
    end

    Result.new(name, visibility, remaining.empty? ? :fixed : :drift, remaining, nil, written)
  end

  # ---- 1 repo を確かめる ----

  def skipped(name, reason)
    Result.new(name, nil, :skipped, [], reason, [])
  end

  def read_repo(name)
    repo = hash!(gh_json("repos/#{name}", "repo"), "repo")
    raise Error, "repo を読めません (応答の形が想定外)" unless valid_repo?(repo["full_name"])

    repo
  end

  # 1 repo を確かめる。mode が :apply なら、ずれのうち直せるものを直して確かめ直す。
  def check_repo(name, config, mode = :check)
    return skipped(name, "設定 file で除外") if config.excluded?(name)

    repo = read_repo(name)
    name = repo["full_name"]
    return skipped(name, "設定 file で除外") if config.excluded?(name)
    return skipped(name, "fork") if boolean!(repo["fork"], "fork の field")
    return skipped(name, "archive 済み") if boolean!(repo["archived"], "archived の field")
    permissions = hash!(repo["permissions"], "permissions の field")
    return skipped(name, "admin 権限が無い") unless boolean!(permissions["admin"], "permissions.admin の field")

    visibility = repo["visibility"]
    raise Error, "baseline の無い visibility です" unless BASELINE.key?(visibility)

    settings = repo_settings(name)
    facts = collect_facts(name, repo, visibility, settings.skip)
    findings = evaluate(visibility, facts, settings.required_checks, settings.skip)
    result =
      if findings.empty? then Result.new(name, visibility, :ok, [], nil, [])
      elsif mode == :apply then apply_fixes(name, visibility, findings, settings)
      else Result.new(name, visibility, :drift, findings, nil, [])
      end
    result.omitted = settings.skip
    result
  # repo の設定 file を読めた後に止まったときも、外した項目を出す (settings は読めていなければ nil)。
  rescue ApplyError => e
    Result.new(name, nil, :error, [], e.message, e.written, settings&.skip)
  rescue Error => e
    Result.new(name, nil, :error, [], e.message, [], settings&.skip)
  rescue TypeError, NoMethodError, ArgumentError, EncodingError => e
    # 上の検査が見落とした応答の型違いや不正な文字列 (不正な UTF-8 への strip・正規表現など)。その repo だけ
    # 「確かめられない」にして、--all の残りを続ける。
    Result.new(name, nil, :error, [], "応答の形が想定外です (#{e.class})", [], settings&.skip)
  end

  # 全 repo。fork・archive 済み・設定 file で除外した repo は一覧の段で外す (一覧の field が欠けていれば
  # check_repo が改めて読んで確かめる)。対象外は、一覧の段と check_repo の段の両方を理由ごとに数える。
  def check_all(config, mode = :check)
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
    results = targets.sort_by(&:downcase).map { |name| check_repo(name, config, mode) }
    results.select { |r| r.status == :skipped }.each { |r| counts[r.reason] = counts.fetch(r.reason, 0) + 1 }
    [results, counts]
  end

  # 失敗の呼び方。--apply では、読めなかったのか直せなかったのかを 1 つの語でまとめる。
  def error_label(mode)
    mode == :apply ? "確かめられないか直せない" : "確かめられない"
  end

  def summary_line(results, counts, mode)
    targets = results.reject { |r| r.status == :skipped }
    statuses = SUMMARY_STATUSES.reject { |status, _| status == :fixed && mode != :apply }
    detail = statuses.map do |status, label|
      label = error_label(mode) if status == :error
      "#{label} #{targets.count { |r| r.status == status }}"
    end.join("・")
    skipped = counts.map { |reason, n| "#{reason} #{n} 件" }.join("・")
    "対象の repo: #{targets.size} 件 (#{detail}) / 対象外: #{skipped}"
  end

  # ---- 出す ----

  def finding_line(item, actual, expected)
    "  - #{LABELS.fetch(item)}: 今 #{describe(item, actual)} / あるべき #{describe_expected(item, expected)}"
  end

  def render(results, counts, mode = :check)
    lines = []
    results.each do |r|
      case r.status
      when :ok
        lines << "#{r.name} (#{r.visibility}): ずれ無し"
      when :fixed
        lines << "#{r.name} (#{r.visibility}): 直した #{r.fixed.size} 件 (ずれ無し)"
        r.fixed.each { |item| lines << "  - 直した: #{LABELS.fetch(item)}" }
      when :drift
        if r.fixed.empty?
          lines << "#{r.name} (#{r.visibility}): ずれ #{r.findings.size} 件"
        else
          lines << "#{r.name} (#{r.visibility}): 直した #{r.fixed.size} 件 / 残りのずれ #{r.findings.size} 件"
          r.fixed.each { |item| lines << "  - 直した: #{LABELS.fetch(item)}" }
        end
        r.findings.each { |item, actual, expected| lines << finding_line(item, actual, expected) }
      when :skipped
        lines << "#{r.name}: 対象外 (#{r.reason})"
      else
        lines << "#{r.name}: #{error_label(mode)} (#{r.reason})"
        # --apply が止まる前に書き込みが成功した項目 (戻すときに変えた範囲を追えるように)。
        r.fixed.each { |item| lines << "  - 書いた: #{LABELS.fetch(item)}" }
      end
      # repo の設定 file で外した項目 (黙ってずれ無しにしない)。
      Array(r.omitted).each { |item| lines << "  - #{REPO_FILE_LABEL} で外した: #{OMIT_LABELS.fetch(item)}" }
    end
    lines << summary_line(results, counts, mode) if counts
    checked = results.select { |r| %i[ok fixed drift].include?(r.status) }
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
    options = parse_args(args)
    config = load_config
    results, counts =
      case options.target
      when :all then check_all(config, options.mode)
      when :current then [[check_repo(current_repo, config, options.mode)], nil]
      else [[check_repo(options.target, config, options.mode)], nil]
      end
    $stdout.write(render(results, counts, options.mode))
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
