#!/usr/bin/env ruby
# frozen_string_literal: true

# review-routing-preflight: 相互レビューの reviewer routing を PR 単位で機械判定する
# 決定的 script。personal-review-request skill の「レビュアーの決定」(規範の正本) を
# 実装に落としたもの (#200 §4.3 / #202)。レビュー依頼時 (消費側) に PR の全 commit の
# `Co-Authored-By:` トレーラを検査する — commit 作成時の gate (ai-trailer-gate) は
# ローカル commit しか守れず、squash / rebase / 他環境 push でトレーラは失われうるため、
# 消費側の検査が routing 契約に直結する。
#
# 判定規則 (personal-review-request と同一):
# - 全 commit が単一 AI → reviewer は閉じた表 REVIEWER で決める (exit 0)。Claude* → Codex、
#   Codex* → Claude。OpenCode (<provider>/<model>) は中身の model の系列で決める (#295): Anthropic
#   系 → Codex、OpenAI 系 → Claude、それ以外 → Claude。
# - fail-closed (exit 1・自動で片側に倒さない): 1 commit に複数 AI トレーラ (1 commit に model の
#   異なる OpenCode トレーラを含む) / 複数 AI の commit 混在 / トレーラ欠落 commit (人間・不明) /
#   AI トレーラ皆無 / OpenCode トレーラの形が不正か系列が曖昧 / 表に無い分類。
# - fail-closed 後の扱い (元の author を確かめられる trailer の付け直し・分割・human review。reviewer の上書きは無い。#415) は skill の領分。
# - bot の PR (#553): PR の author (`pulls/<n>` の user) が閉じた表 BOTS の bot なら、trailer ではなく GitHub の API の
#   印で判定する。全 commit が「author が同じ bot (login / id / type)、committer が GitHub (web-flow)、GitHub の署名が
#   verified かつ valid、親が 1 つ、message に Co-Authored-By が無い」で、head と base の repository が id と full_name で一致し (fork は拒否)、
#   取得した commit が PR の commits の数と head.sha に一致するときだけ `bot(<name>)` → reviewer は表のとおり (exit 0)。
#   1 つでも外れれば fail-closed で、trailer の route へは戻さない (表に無い bot の PR も fail-closed)。表は github.com の
#   account に対するもので、GH_HOST が別の host なら当てない。この印は「GitHub が bot として作った commit」の確認で、
#   変更を生成した主体の証明ではない。PR の author が bot でなければ従来どおり trailer だけで判定する (出力は不変)。
# - 系列の判定は provider/model の文字列への regex で、alias で系列が隠れた model は「それ以外」
#   (reviewer = Claude) に倒れる (honest-label)。
#
# untrusted-input 規律: commit message は fork PR では第三者が書ける untrusted data。
# この script は message を regex 分類にだけ使い、**本文・author 名・email・OpenCode の
# provider/model を出力に一切含めない** (出すのは commit oid の hex 短縮 + 閉じた表の分類ラベルのみ)。
#
# トレーラ解釈は shared/scripts/personal-ai-trailer-gate.rb と**双子ロジック** (末尾段落が
# 全行 trailer 形式のときだけ trailer block とみなす保守近似、OpenCode の name の形
# OPENCODE_NAME_RE)。単一ファイル配布のため
# require で共有できない。**変更するときは両方を同時に直す**。
#
# 依存: gh (認証済み)。読み取りは pulls/<n> (PR の author と head / base) と pulls/<n>/commits の REST のみ。`gh pr view --json
# commits` は先頭 100 commit しか返さない (pagination なし) ため使わない — 全件を
# `gh api --paginate --slurp` で取る (plain --paginate は array endpoint でページ境界に
# `][` を挟み不正 JSON になる既知の落とし穴があるため --slurp + flatten。#160 の前例)。
# exit: 0 = routing 確定 / 1 = fail-closed / 2 = usage・入力・gh エラー。

require "json"
require "open3"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (stdin・file・git や gh の出力) を UTF-8 として扱う (#432)。
# 既定の external encoding が US-ASCII のままだと、日本語を含む値への正規表現や連結が例外で落ちる。
# scripts/lib/cli.rb (#418) と同じ固定。ENV と ARGV の encoding は変わらない。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module ReviewRoutingPreflight
  VERSION = "1"

  # --- ai-trailer-gate と双子のトレーラ解釈 (変更時は両方を直す) ---
  TRAILER_RE = /\ACo-Authored-By:\s*(.+?)\s*<([^>]*)>\s*\z/i
  TRAILER_SHAPE_RE = /\A[A-Za-z0-9-]+:\s/
  OPENCODE_NAME_RE = %r{\AOpenCode \((?<provider>[A-Za-z0-9][A-Za-z0-9._-]*)/(?<model>[A-Za-z0-9][A-Za-z0-9._:@+/-]*)\)\z}.freeze

  # --- OpenCode の model の系列表 (正本はここ 1 か所。skill には書き写さない) ---
  # provider/model の全体に当て、両方に当たれば曖昧 (:opencode_unknown)。
  ANTHROPIC_RE = /claude|anthropic/i.freeze
  OPENAI_RE = %r{openai|chatgpt|gpt|codex|(?:\A|[/.:_-])o[1-9](?:\z|[-.])}i.freeze

  # --- bot の PR (#553) の閉じた表。key は github.com の login、id は account の numeric ID (login の変更に追従しない) ---
  # Dependabot の PR の commit は GitHub が app として作り、committer は GitHub (web-flow) で署名は verified。
  BOTS = {
    "dependabot[bot]" => { id: 49_699_333, kind: :bot_dependabot },
  }.freeze
  BOT_COMMITTER_LOGIN = "web-flow"
  # bot の commit の message に在ってはならない語 (大文字小文字を問わず、どの行でも)。
  CO_AUTHOR_RE = /co-authored-by/i.freeze
  GITHUB_COM = "github.com"

  # 著者の分類 → reviewer (閉じた表)。表に無い分類 (:opencode_unknown / :bot_unverified を含む) は fail-closed。
  # bot 著は author ≠ reviewer をどちらの AI でも満たすので、枠の大きい Claude を reviewer にする (#553)。
  REVIEWER = {
    claude: :codex,
    codex: :claude,
    opencode_anthropic: :codex,
    opencode_openai: :claude,
    opencode_other: :claude,
    bot_dependabot: :claude,
  }.freeze

  # 出力に使う label (閉じた表)。trailer の生の provider/model は出さない。
  LABELS = {
    claude: "claude",
    codex: "codex",
    opencode_anthropic: "opencode(anthropic)",
    opencode_openai: "opencode(openai)",
    opencode_other: "opencode(other)",
    opencode_unknown: "opencode(unknown)",
    bot_dependabot: "bot(dependabot)",
    bot_unverified: "bot(unverified)",
    mixed: "mixed",
    none: "none",
    merge_none: "none (merge commit)",
  }.freeze

  module_function

  def label(kind)
    LABELS.fetch(kind)
  end

  # OpenCode の trailer の name を [分類, provider/model] にする。形が不正なら [:opencode_unknown, nil]。
  def classify_opencode(name)
    shape = OPENCODE_NAME_RE.match(name)
    return [:opencode_unknown, nil] unless shape

    id = "#{shape[:provider]}/#{shape[:model]}"
    anthropic = ANTHROPIC_RE.match?(id)
    openai = OPENAI_RE.match?(id)
    kind =
      if anthropic && openai
        :opencode_unknown
      elsif anthropic
        :opencode_anthropic
      elsif openai
        :opencode_openai
      else
        :opencode_other
      end
    [kind, id]
  end

  def trailer_block(lines)
    trimmed = lines.dup
    trimmed.pop while !trimmed.empty? && trimmed.last.strip.empty?
    block = []
    trimmed.reverse_each do |line|
      break if line.strip.empty?

      block.unshift(line)
    end
    return [] unless !block.empty? && block.all? { |l| TRAILER_SHAPE_RE.match?(l) }

    block
  end

  # commit message (確定済み full message body) を LABELS の key (:claude / :codex /
  # :opencode_* / :mixed / :none) に分類。
  def classify_message(text)
    text = text.to_s.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?

    lines = text.each_line.map(&:chomp)
    kinds = []
    opencode_models = []
    trailer_block(lines).each do |line|
      m = TRAILER_RE.match(line)
      next unless m

      name = m[1]
      if name.start_with?("Claude")
        kinds << :claude
      elsif name.start_with?("Codex")
        kinds << :codex
      elsif name.start_with?("OpenCode")
        kind, id = classify_opencode(name)
        kinds << kind
        opencode_models << id if id
      end
    end
    kinds.uniq!
    return :none if kinds.empty?
    return :mixed if kinds.size > 1
    # 同じ系列でも model の異なる OpenCode トレーラが 1 commit にあれば混在 (gate と揃える)。
    return :mixed if opencode_models.uniq.size > 1

    kinds.first
  end

  # [[oid8, kind], ...] から routing を決める。理由文は untrusted 内容を含まない定型文のみ。
  def judge(oid_kinds)
    return { verdict: :error, reason: "PR に commit がありません" } if oid_kinds.empty?

    kinds = oid_kinds.map { |_, k| k }
    if kinds.include?(:mixed)
      return { verdict: :fail_closed,
               reason: "1 つの commit に複数 AI (または model の異なる OpenCode) のトレーラが混在 (単一 reviewer で author ≠ reviewer を満たせない)" }
    end
    if kinds.include?(:bot_unverified)
      return { verdict: :fail_closed,
               reason: "bot の PR に bot の印 (bot の author・GitHub の署名・親 1 つ・トレーラ無し) を満たさない commit がある (人が commit を足した可能性。trailer では routing せず、人が review する)" }
    end
    if kinds.include?(:merge_none)
      return { verdict: :fail_closed,
               reason: "トレーラの無い merge commit がある (PR の branch は rebase で更新するか、merge commit を作った author を確かめられるときだけトレーラを付ける)" }
    end
    if kinds.include?(:none)
      return { verdict: :fail_closed,
               reason: "トレーラ欠落 (人間または不明) の commit がある (自動 routing しない)" }
    end
    authors = kinds.uniq
    if authors.size > 1
      return { verdict: :fail_closed,
               reason: "複数 AI の commit が混在 (PR を著者ごとに分割する)" }
    end

    author = authors.first
    reviewer = REVIEWER[author]
    if reviewer.nil?
      return { verdict: :fail_closed,
               reason: "著者の分類から reviewer を決められない (OpenCode のトレーラの形が不正か model の系列が曖昧。元の author を確かめられればトレーラを直し、確かめられなければ人が review する)" }
    end

    { verdict: :ok, author: author, reviewer: reviewer }
  end

  # gh を起動して stdout を返す。stderr は捕捉して捨てる (GH_DEBUG=api などで gh が HTTP の応答 (PR の title / body / login
  # を含む) を stderr に出しても、親の出力に流さない。#553 round 1)。失敗は定型の文言だけにする。
  def gh_api(argv)
    out, _err, status = Open3.capture3(*argv, in: File::NULL)
    raise ArgumentError, "gh api が失敗しました (PR 番号 / 認証 / --repo を確認)" unless status.success?

    out
  rescue SystemCallError
    raise ArgumentError, "gh を起動できません"
  end

  # PR (`pulls/<n>`) を 1 回読む。bot の判定に使う user / head / base / commits だけを見る。
  def fetch_pull(pr_number, repo)
    path = "repos/#{repo || '{owner}/{repo}'}/pulls/#{pr_number}"
    out = gh_api(["gh", "api", path])
    pull = JSON.parse(out)
    raise ArgumentError, "gh の応答が PR の object ではありません" unless pull.is_a?(Hash)

    pull
  rescue JSON::ParserError
    raise ArgumentError, "gh の応答を JSON として解釈できません"
  end

  # user object が閉じた表の bot (login・numeric id・type の 3 つ) に一致するか。id は Integer に限る (Ruby の == は 49699333.0
  # を同じとみなす。#553 round 2)。
  def bot_user?(user, login, id)
    user.is_a?(Hash) && user["login"] == login && user["id"].is_a?(Integer) && user["id"] == id && user["type"] == "Bot"
  end

  # PR の author の分類: [:human, nil] / [:bot, [login, entry]] / [:unregistered_bot, nil] / [:foreign_host_bot, nil]。
  # user が無い・login や type が文字列でない応答は、bot でないことを確かめられないので判定できない (ArgumentError = exit 2。
  # trailer の route へ進めない。#553 round 2)。bot の表は github.com の account のものなので、GH_HOST が別の host を指す
  # ときは当てない。
  def classify_pull(pull, gh_host)
    user = pull["user"]
    unless user.is_a?(Hash) && user["login"].is_a?(String) && user["type"].is_a?(String)
      raise ArgumentError, "PR の author を読めません (応答に user が無いか形が外れる。bot でないことを確かめられない)"
    end
    return [:human, nil] unless user["type"] == "Bot" || user["login"].end_with?("[bot]")
    return [:foreign_host_bot, nil] unless gh_host.to_s.empty? || gh_host == GITHUB_COM

    login = user["login"]
    entry = BOTS[login]
    return [:unregistered_bot, nil] unless entry && bot_user?(user, login, entry[:id])

    [:bot, [login, entry]]
  end

  # head / base の repository の identity (numeric id と full_name)。形が外れれば nil。
  def repo_identity(side)
    repo = side.is_a?(Hash) ? side["repo"] : nil
    return nil unless repo.is_a?(Hash) && repo["id"].is_a?(Integer) && repo["full_name"].is_a?(String)

    [repo["id"], repo["full_name"]]
  end

  def same_repository?(pull)
    head = repo_identity(pull["head"])
    base = repo_identity(pull["base"])
    !head.nil? && head == base
  end

  # 取得した commit の列が PR の状態 (commits の数と head.sha) と一致するか (取得の途中で head が動いていない)。
  def snapshot_consistent?(pull, commits)
    head_sha = pull["head"].is_a?(Hash) ? pull["head"]["sha"] : nil
    return false unless head_sha.is_a?(String) && head_sha.match?(/\A[0-9a-f]{40}\z/)
    return false unless pull["commits"].is_a?(Integer) && pull["commits"] == commits.size

    !commits.empty? && commits.last["sha"] == head_sha
  end

  # bot の PR の 1 commit が bot の印をすべて満たすか: author が同じ bot、committer が GitHub (web-flow)、GitHub の署名が
  # verified かつ valid、親が 1 つ、message が在って `Co-Authored-By` を含まない。trailer の分類 (classify_message) が
  # :none であることでは足りない (折り返した trailer など、parser が認識しない形を不在として許可しない。#553 round 1)
  # ので、語の有無で見る。bot の message に co-author は無い。
  def bot_commit?(c, login, id)
    return false unless c.is_a?(Hash) && c["commit"].is_a?(Hash)
    message = c["commit"]["message"]
    return false unless message.is_a?(String) && !message.match?(CO_AUTHOR_RE)
    return false unless bot_user?(c["author"], login, id)

    committer = c["committer"]
    return false unless committer.is_a?(Hash) && committer["login"] == BOT_COMMITTER_LOGIN

    verification = c["commit"]["verification"]
    return false unless verification.is_a?(Hash) && verification["verified"] == true && verification["reason"] == "valid"

    parents = c["parents"]
    parents.is_a?(Array) && parents.size == 1
  end

  # PR の全 commit を REST + pagination で取得する。repo 省略時は gh の placeholder
  # (`{owner}/{repo}`) に解決を委ねる。gh は現在の directory の repository に解決し、env の
  # `GH_REPO` などが効くので origin とは限らない。
  def fetch_commits(pr_number, repo)
    path = "repos/#{repo || '{owner}/{repo}'}/pulls/#{pr_number}/commits"
    out = gh_api(["gh", "api", "--paginate", "--slurp", path])
    pages = JSON.parse(out)
    raise ArgumentError, "gh の応答が page 配列ではありません" unless pages.is_a?(Array)

    commits = pages.flatten(1)
    raise ArgumentError, "gh の応答に commit がありません" unless commits.all? { |c| c.is_a?(Hash) }

    commits
  rescue JSON::ParserError
    raise ArgumentError, "gh の応答を JSON として解釈できません"
  end

  def short_oid(raw)
    oid = raw.to_s
    oid.match?(/\A[0-9a-f]{7,40}\z/) ? oid[0, 8] : "unknown"
  end

  def run(argv)
    args = argv.dup
    repo = nil
    if (i = args.index("--repo"))
      repo = args[i + 1]
      if repo.nil? || !repo.match?(%r{\A[\w.-]+/[\w.-]+\z})
        warn "review-routing-preflight: --repo は owner/repo 形式で指定してください"
        return 2
      end
      args.slice!(i, 2)
    end
    pr_number = args[0]
    unless args.size == 1 && pr_number.to_s.match?(/\A\d+\z/)
      warn "usage: personal-review-routing-preflight <PR番号> [--repo owner/repo]"
      return 2
    end

    pull = fetch_pull(pr_number, repo)
    pull_kind, bot = classify_pull(pull, ENV["GH_HOST"])
    case pull_kind
    when :unregistered_bot
      warn "review-routing-preflight: fail-closed: 閉じた表に無い bot の PR (trailer では routing しない。人が review する)"
      return 1
    when :foreign_host_bot
      warn "review-routing-preflight: fail-closed: bot の PR だが GH_HOST が github.com でない (bot の表は github.com の account のもの。人が review する)"
      return 1
    end

    commits = fetch_commits(pr_number, repo)
    oid_kinds =
      if pull_kind == :bot
        unless snapshot_consistent?(pull, commits)
          warn "review-routing-preflight: error: 取得した commit が PR の状態 (commits の数と head) と一致しません (やり直す)"
          return 2
        end
        unless same_repository?(pull)
          warn "review-routing-preflight: fail-closed: bot の PR の head が base と別の repository (fork)。人が review する"
          return 1
        end
        login, entry = bot
        commits.map { |c| [short_oid(c["sha"]), bot_commit?(c, login, entry[:id]) ? entry[:kind] : :bot_unverified] }
      else
        commits.map do |c|
          message = c["commit"].is_a?(Hash) ? c["commit"]["message"] : nil
          kind = classify_message(message)
          # トレーラの無い merge commit (親が 2 つ以上) は、理由を分けて示す (#415)。
          kind = :merge_none if kind == :none && c["parents"].is_a?(Array) && c["parents"].size > 1
          [short_oid(c["sha"]), kind]
        end
      end

    oid_kinds.each { |oid, kind| puts "commit #{oid}: #{label(kind)}" }
    result = judge(oid_kinds)
    case result[:verdict]
    when :ok
      puts "reviewer: #{label(result[:reviewer])} (author=#{label(result[:author])}, #{oid_kinds.size} commit(s))"
      0
    when :fail_closed
      warn "review-routing-preflight: fail-closed: #{result[:reason]}"
      1
    else
      warn "review-routing-preflight: error: #{result[:reason]}"
      2
    end
  rescue ArgumentError => e
    warn "review-routing-preflight: error: #{e.message}"
    2
  rescue StandardError => e
    warn "review-routing-preflight: unexpected error (#{e.class})"
    2
  end
end

exit ReviewRoutingPreflight.run(ARGV) if $PROGRAM_NAME == __FILE__
