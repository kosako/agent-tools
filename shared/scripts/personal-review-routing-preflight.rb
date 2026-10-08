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
# 依存: gh (認証済み)。読み取りは pulls/<n>/commits の REST のみ。`gh pr view --json
# commits` は先頭 100 commit しか返さない (pagination なし) ため使わない — 全件を
# `gh api --paginate --slurp` で取る (plain --paginate は array endpoint でページ境界に
# `][` を挟み不正 JSON になる既知の落とし穴があるため --slurp + flatten。#160 の前例)。
# exit: 0 = routing 確定 / 1 = fail-closed / 2 = usage・入力・gh エラー。

require "json"

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

  # 著者の分類 → reviewer (閉じた表)。表に無い分類 (:opencode_unknown を含む) は fail-closed。
  REVIEWER = {
    claude: :codex,
    codex: :claude,
    opencode_anthropic: :codex,
    opencode_openai: :claude,
    opencode_other: :claude,
  }.freeze

  # 出力に使う label (閉じた表)。trailer の生の provider/model は出さない。
  LABELS = {
    claude: "claude",
    codex: "codex",
    opencode_anthropic: "opencode(anthropic)",
    opencode_openai: "opencode(openai)",
    opencode_other: "opencode(other)",
    opencode_unknown: "opencode(unknown)",
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

  # PR の全 commit を REST + pagination で取得する。repo 省略時は gh の placeholder
  # (`{owner}/{repo}` = cwd の origin) に解決を委ねる。
  def fetch_commits(pr_number, repo)
    path = "repos/#{repo || '{owner}/{repo}'}/pulls/#{pr_number}/commits"
    argv = ["gh", "api", "--paginate", "--slurp", path]
    out = IO.popen(argv, &:read)
    raise ArgumentError, "gh api が失敗しました (PR 番号 / 認証 / --repo を確認)" unless $?.success?

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

    commits = fetch_commits(pr_number, repo)
    oid_kinds = commits.map do |c|
      message = c["commit"].is_a?(Hash) ? c["commit"]["message"] : nil
      kind = classify_message(message)
      # トレーラの無い merge commit (親が 2 つ以上) は、理由を分けて示す (#415)。
      kind = :merge_none if kind == :none && c["parents"].is_a?(Array) && c["parents"].size > 1
      [short_oid(c["sha"]), kind]
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
