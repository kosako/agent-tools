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
# - 全 commit が単一 AI (トレーラの name が Claude*/Codex*) → 反対側が reviewer (exit 0)。
# - fail-closed (exit 1・自動で片側に倒さない): 1 commit に複数 AI トレーラ / 複数 AI の
#   commit 混在 / トレーラ欠落 commit (人間・不明) / AI トレーラ皆無。
# - fail-closed 後の扱い (人間の裁定・--reviewer 上書き) は skill の領分。
#
# untrusted-input 規律: commit message は fork PR では第三者が書ける untrusted data。
# この script は message を regex 分類にだけ使い、**本文・author 名・email を出力に
# 一切含めない** (出すのは commit oid の hex 短縮 + 分類ラベルのみ)。
#
# トレーラ解釈は shared/scripts/personal-ai-trailer-gate.rb と**双子ロジック** (末尾段落が
# 全行 trailer 形式のときだけ trailer block とみなす保守近似)。単一ファイル配布のため
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

  module_function

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

  # commit message (確定済み full message body) を :claude / :codex / :mixed / :none に分類。
  def classify_message(text)
    text = text.to_s.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?

    lines = text.each_line.map(&:chomp)
    kinds = []
    trailer_block(lines).each do |line|
      m = TRAILER_RE.match(line)
      next unless m

      if m[1].start_with?("Claude")
        kinds << :claude
      elsif m[1].start_with?("Codex")
        kinds << :codex
      end
    end
    kinds.uniq!
    return :none if kinds.empty?
    return :mixed if kinds.size > 1

    kinds.first
  end

  # [[oid8, kind], ...] から routing を決める。理由文は untrusted 内容を含まない定型文のみ。
  def judge(oid_kinds)
    return { verdict: :error, reason: "PR に commit がありません" } if oid_kinds.empty?

    kinds = oid_kinds.map { |_, k| k }
    if kinds.include?(:mixed)
      return { verdict: :fail_closed,
               reason: "1 つの commit に複数 AI のトレーラが混在 (単一 reviewer で author ≠ reviewer を満たせない)" }
    end
    if kinds.include?(:none)
      return { verdict: :fail_closed,
               reason: "トレーラ欠落 (人間または不明) の commit がある (自動 routing しない)" }
    end
    authors = kinds.uniq
    if authors.size > 1
      return { verdict: :fail_closed,
               reason: "複数 AI の commit が混在 (PR を著者ごとに分割するか人間が裁定)" }
    end

    author = authors.first
    { verdict: :ok, author: author, reviewer: author == :claude ? :codex : :claude }
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
      [short_oid(c["sha"]), classify_message(message)]
    end

    oid_kinds.each { |oid, kind| puts "commit #{oid}: #{kind}" }
    result = judge(oid_kinds)
    case result[:verdict]
    when :ok
      puts "reviewer: #{result[:reviewer]} (author=#{result[:author]}, #{oid_kinds.size} commit(s))"
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
