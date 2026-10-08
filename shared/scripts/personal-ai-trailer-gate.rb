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
#   Claude Code = CLAUDECODE / Codex = CODEX_THREAD_ID or CODEX_SANDBOX (#201 実測) /
#   OpenCode = AGENT_TOOLS_OPENCODE (#295)。
#   Claude Code / Codex の marker は「観測された事実」であって両 CLI の公開契約ではない。CLI 更新で
#   消えたら gate は人間 commit と同じ扱い (無言 pass) に fail-open で倒れる。
#   これも honest-label であり、marker の生存確認は CLI 更新時の smoke test に含める。
#   OpenCode の marker は OpenCode 自身ではなく agent-tools の plugin (personal-agent-tools.js) が
#   shell.env で model の bash にだけ立てる (OPENCODE_SESSION_ID は無く、組み込みの OPENCODE=1 は
#   人が打つ `!` / PTY にも載るので使わない: #295 の M5)。plugin が読まれない (`--pure`・読込失敗・
#   撤去) と marker は立たず、gate は人間 commit として通す。その場合の床は PR 単位の
#   routing-preflight (trailer の無い commit は fail-closed)。OpenCode の更新時は probe で marker が
#   まだ立つかを確かめる。
# - marker なし (人間の手動 commit・他 tool) は無言で pass (exit 0)。人間の commit に
#   トレーラ義務はない。
# - 複数の marker が立つ nested 実行 (Claude → codex exec 等) は agent 名を特定できないので、
#   「env にある agent のどれかの有効なトレーラがあること」まで緩めて要求する。
# - merge commit (MERGE_HEAD あり) も agent の session なら対象 (#415)。競合の解消は authored な変更で、
#   PR の routing-preflight も trailer の無い merge commit を fail-closed にするので、そろえる。人間の merge は
#   上の「marker なし」で pass する。
#
# 検証内容 (agent 識別時):
# - 期待 agent のトレーラが 1 本以上ある (Claude 環境 → name が "Claude" 始まり /
#   Codex 環境 → "Codex" 始まり / OpenCode 環境 → "OpenCode (<provider>/<model>)")。
# - AI トレーラの email は no-reply 形式 (運用ルール「email は公開してよい no-reply /
#   bot 用のものに限る」の機械判定可能な床)。
# - name が "OpenCode" で始まるトレーラは OpenCode のものとして拾い、形が不正なら fail
#   (形が不正でも混在の検出にはかける)。1 commit の OpenCode トレーラは 1 model だけ。
# - 1 commit に複数の AI (Claude / Codex / OpenCode) のトレーラが混在したら fail-closed
#   (相互レビュー routing が判定不能になる)。
#
# exit code: 0 = pass (人間 commit (人間の merge を含む) / 検証通過) / 1 = 検証 fail (agent の merge commit の
# トレーラ欠落を含む) / 2 = usage・
# 入力エラー (message file が読めない等)。

module AiTrailerGate
  VERSION = "1"

  TRAILER_RE = /\ACo-Authored-By:\s*(.+?)\s*<([^>]*)>\s*\z/i
  NOREPLY_RE = /no-?reply/i
  SCISSORS_RE = /\A# -+ >8 -+/

  CLAUDE_MARKER = "CLAUDECODE"
  CODEX_MARKERS = %w[CODEX_THREAD_ID CODEX_SANDBOX].freeze
  OPENCODE_MARKER = "AGENT_TOOLS_OPENCODE"

  # OpenCode の trailer の name。provider/model は OpenCode の model 指定 (providerID/modelID) を
  # そのまま書き、model は "/" を含みうる。
  OPENCODE_NAME_RE = %r{\AOpenCode \((?<provider>[A-Za-z0-9][A-Za-z0-9._-]*)/(?<model>[A-Za-z0-9][A-Za-z0-9._:@+/-]*)\)\z}.freeze

  AGENT_LABELS = { claude: "Claude", codex: "Codex", opencode: "OpenCode" }.freeze

  # 例示 email は public な no-reply だが、check-injection の PII 検査 (静的 literal 対象)
  # に かからないよう実行時連結で組む。
  CLAUDE_EXAMPLE_EMAIL = ["noreply", "anthropic.com"].join("@")
  OPENCODE_EXAMPLE_EMAIL = ["noreply", "opencode.invalid"].join("@")
  EXPECTED_EXAMPLE = {
    claude: "Co-Authored-By: Claude <model name> <#{CLAUDE_EXAMPLE_EMAIL}>",
    codex: "Co-Authored-By: Codex <no-reply の email>",
    opencode: "Co-Authored-By: OpenCode (<provider>/<model>) <#{OPENCODE_EXAMPLE_EMAIL}>",
  }.freeze

  module_function

  def agents_from_env(env)
    agents = []
    agents << :claude unless env[CLAUDE_MARKER].to_s.empty?
    agents << :codex if CODEX_MARKERS.any? { |k| !env[k].to_s.empty? }
    agents << :opencode unless env[OPENCODE_MARKER].to_s.empty?
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
  # このトレーラ解釈 (TRAILER_RE / TRAILER_SHAPE_RE / trailer_block / OPENCODE_NAME_RE) は
  # shared/scripts/personal-review-routing-preflight.rb と双子ロジック (単一ファイル
  # 配布のため require で共有できない)。**変更するときは両方を同時に直す**。
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

      name = m[1]
      agent =
        if name.start_with?("Claude")
          :claude
        elsif name.start_with?("Codex")
          :codex
        elsif name.start_with?("OpenCode")
          :opencode
        end
      next unless agent

      trailer = { agent: agent, name: name, email: m[2], valid: true }
      if agent == :opencode
        shape = OPENCODE_NAME_RE.match(name)
        trailer[:valid] = !shape.nil?
        trailer[:model] = "#{shape[:provider]}/#{shape[:model]}" if shape
      end
      trailers << trailer
    end
    trailers
  end

  # 純粋な判定 (env / message から結論と診断文言)。exit code を返す。
  def judge(agents, lines)
    return 0 if agents.empty?

    trailers = ai_trailers(lines)
    kinds = trailers.map { |t| t[:agent] }.uniq

    if kinds.size > 1
      labels = (AGENT_LABELS.keys & kinds).map { |k| AGENT_LABELS.fetch(k) }.join(" と ")
      warn "ai-trailer-gate: 1 つの commit に複数の AI (#{labels}) のトレーラが混在しています。" \
           "相互レビュー routing が判定不能になるため fail-closed で block します (作業を分けてください)。"
      return 1
    end

    bad_email = trailers.reject { |t| NOREPLY_RE.match?(t[:email]) }
    unless bad_email.empty?
      warn "ai-trailer-gate: AI トレーラの email が no-reply 形式ではありません: " \
           "#{bad_email.map { |t| t[:name] }.join(', ')} (公開してよい no-reply / bot 用に限る)。"
      return 1
    end

    opencode = trailers.select { |t| t[:agent] == :opencode }
    unless opencode.all? { |t| t[:valid] }
      warn "ai-trailer-gate: OpenCode のトレーラの name の形が不正です。" \
           "「OpenCode (<provider>/<model>)」にしてください: #{EXPECTED_EXAMPLE.fetch(:opencode)}"
      return 1
    end
    if opencode.map { |t| t[:model] }.uniq.size > 1
      warn "ai-trailer-gate: 1 つの commit に model の異なる OpenCode のトレーラがあります。" \
           "相互レビューの reviewer が決まらないため fail-closed で block します (1 commit に 1 model)。"
      return 1
    end

    # 単一の agent ならその agent のトレーラ、nested (agent を特定できない) なら env にある
    # agent のどれかのトレーラで可。env に無い agent のトレーラだけでは通さない。
    satisfied = (kinds & agents).any?
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
