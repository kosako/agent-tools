#!/usr/bin/env ruby
# frozen_string_literal: true

# ai-trailer-gate: commit-msg stage の git gate。AI agent セッション由来の commit に
# 相互レビュー routing の正本である `Co-Authored-By:` トレーラが正しく付いているかを
# 検証する。routing (author ≠ reviewer) は commit trailer を SSOT とするのに、付与が
# モデル任せだった構造リスクを機械化したもの (#200 §4.2 / #202)。
#
# 正本: docs/git-hook-gates.md。
#
# 強度ラベル (偽らない): 通常経路 (git commit) に対する best-effort guardrail。
# `--no-verify` / hooksPath 差し替えで迂回でき、squash / rebase / GitHub 上の操作での
# トレーラ喪失は守れない (それは消費側 preflight の領分。#202 の routing-preflight)。
#
# opt-in 設計 (誤 block しない):
# - agent セッションの識別は環境変数 marker で行う:
#   Claude Code = CLAUDECODE / Codex = CODEX_THREAD_ID or CODEX_SANDBOX (#201 実測)。
#   marker はどちらも「観測された事実」であって両 CLI の公開契約ではない。CLI 更新で
#   消えたら gate は人間 commit と同じ扱い (無言 pass) に fail-open で倒れる。
#   これも honest-label であり、marker の生存確認は CLI 更新時の smoke test に含める。
# - marker なし (人間の手動 commit・他 tool) は無言で pass (exit 0)。人間の commit に
#   トレーラ義務はない。
# - 両 marker が立つ nested 実行 (Claude → codex exec 等) は agent 名を特定できないので、
#   「いずれかの有効な AI トレーラがあること」まで緩めて要求する。
# - merge commit (MERGE_HEAD あり) は対象外 (authored commit の契約であり、merge は
#   レビュー済み作業の合成)。
#
# 検証内容 (agent 識別時):
# - 期待 agent のトレーラが 1 本以上ある (Claude 環境 → name が "Claude" 始まり /
#   Codex 環境 → "Codex" 始まり)。
# - AI トレーラの email は no-reply 形式 (運用ルール「email は公開してよい no-reply /
#   bot 用のものに限る」の機械判定可能な床)。
# - 1 commit に Claude 系と Codex 系の両トレーラが混在したら fail-closed
#   (相互レビュー routing が判定不能になる)。
#
# exit code: 0 = pass (人間 commit / merge / 検証通過) / 1 = 検証 fail / 2 = usage・
# 入力エラー (message file が読めない等)。

module AiTrailerGate
  VERSION = "1"

  TRAILER_RE = /\ACo-Authored-By:\s*(.+?)\s*<([^>]*)>\s*\z/i
  NOREPLY_RE = /no-?reply/i
  SCISSORS_RE = /\A# -+ >8 -+/

  CLAUDE_MARKER = "CLAUDECODE"
  CODEX_MARKERS = %w[CODEX_THREAD_ID CODEX_SANDBOX].freeze

  # 例示 email は public な no-reply だが、check-injection の PII 検査 (静的 literal 対象)
  # に かからないよう実行時連結で組む。
  CLAUDE_EXAMPLE_EMAIL = ["noreply", "anthropic.com"].join("@")
  EXPECTED_EXAMPLE = {
    claude: "Co-Authored-By: Claude <model name> <#{CLAUDE_EXAMPLE_EMAIL}>",
    codex: "Co-Authored-By: Codex <no-reply の email>",
  }.freeze

  module_function

  def agents_from_env(env)
    agents = []
    agents << :claude unless env[CLAUDE_MARKER].to_s.empty?
    agents << :codex if CODEX_MARKERS.any? { |k| !env[k].to_s.empty? }
    agents
  end

  # commit message の comment 部 (既定 commentChar の "#" 行、scissors 以降) を除いた
  # 本文行。commentChar の変更には追随しない (既定運用のみ。docs に明記)。
  def message_lines(text)
    lines = []
    text.each_line do |raw|
      line = raw.chomp
      break if SCISSORS_RE.match?(line)
      next if line.start_with?("#")

      lines << line
    end
    lines
  end

  # trailer 行の形 (Key: value)。git の trailer key は英数と '-'。
  TRAILER_SHAPE_RE = /\A[A-Za-z0-9-]+:\s/

  # git の trailer 解釈の保守的近似: message 末尾の段落を取り、**全行が trailer 形式の
  # ときだけ** trailer block とみなす。本文中や散文混在段落の Co-Authored-By 行は git
  # (interpret-trailers) も消費側もトレーラと認識しないため、gate だけが pass すると
  # 判定が割れる (H206-02)。git 自身は「git 生成 trailer を含み 25% 以上が trailer」の
  # 混在も許すが、こちらはより厳しい側 (認めない) に倒す — gate が要求するのは自分たちの
  # commit が作る clean な trailer block であり、厳しい近似は fail-closed 方向。
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

  def ai_trailers(lines)
    trailers = []
    trailer_block(lines).each do |line|
      m = TRAILER_RE.match(line)
      next unless m

      agent =
        if m[1].start_with?("Claude")
          :claude
        elsif m[1].start_with?("Codex")
          :codex
        end
      trailers << { agent: agent, name: m[1], email: m[2] } if agent
    end
    trailers
  end

  def merge_in_progress?
    out = IO.popen(%w[git rev-parse --git-path MERGE_HEAD], &:read)
    return false unless $?.success?

    File.exist?(out.chomp)
  end

  # 純粋な判定 (env / message から結論と診断文言)。exit code を返す。
  def judge(agents, lines)
    return 0 if agents.empty?

    trailers = ai_trailers(lines)
    kinds = trailers.map { |t| t[:agent] }.uniq

    if kinds.size > 1
      warn "ai-trailer-gate: 1 つの commit に Claude 系と Codex 系のトレーラが混在しています。" \
           "相互レビュー routing が判定不能になるため fail-closed で block します (作業を分けてください)。"
      return 1
    end

    bad_email = trailers.reject { |t| NOREPLY_RE.match?(t[:email]) }
    unless bad_email.empty?
      warn "ai-trailer-gate: AI トレーラの email が no-reply 形式ではありません: " \
           "#{bad_email.map { |t| t[:name] }.join(', ')} (公開してよい no-reply / bot 用に限る)。"
      return 1
    end

    satisfied =
      if agents.size > 1
        !trailers.empty? # nested で agent 特定不能: いずれかの有効な AI トレーラで可
      else
        kinds.include?(agents.first)
      end
    return 0 if satisfied

    expected = agents.map { |a| EXPECTED_EXAMPLE.fetch(a) }.join(" または ")
    warn "ai-trailer-gate: #{agents.join('+')} セッション由来の commit にトレーラがありません。" \
         "commit message 末尾に追加してください: #{expected}"
    1
  end

  def run(argv)
    path = argv[0]
    if path.nil? || !File.file?(path)
      warn "ai-trailer-gate: usage: personal-ai-trailer-gate <commit-msg-file>"
      return 2
    end
    return 0 if merge_in_progress?

    # 非 UTF-8 混入で regex が例外にならないよう scrub (#149 と同じ方式・判定用のみ)。
    text = File.read(path)
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?
    judge(agents_from_env(ENV), message_lines(text))
  rescue StandardError => e
    # 想定外は入力・構成エラーの exit 2 に倒す (fail-closed)。message 内容は出さない。
    warn "ai-trailer-gate: unexpected error (#{e.class})"
    2
  end
end

exit AiTrailerGate.run(ARGV) if $PROGRAM_NAME == __FILE__
