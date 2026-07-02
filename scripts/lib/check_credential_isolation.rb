#!/usr/bin/env ruby
# frozen_string_literal: true

# Credential 隔離 acceptance harness の判定コア。
# Spec: docs/credential-isolation-acceptance.md / 外部 planning tool の設計メモ P3-02。
#
# この lib は network / credential にアクセスしない。probe の「実行」(隔離 session で
# gh/git を走らせ認証成否を得る = 実機・PR-2) と「判定」(ここ) を分離し、判定を
# fixture で deterministic に検証できるようにする。判定入力は probe 結果の JSON。
#
# 判定契約:
#   - canonical CHANNELS のすべてが results に揃っている (チャネル丸ごとの欠落 =
#     偽の安心 を弾く。required set は契約として固定し、呼び出し側は縮められない)。
#   - 各チャネルは同一 operation の negative / positive ペアを1組以上持つ (positive control
#     が negative と別操作を叩く空振り緑を弾く。ペアを増やす方向の拡張は妨げない)。
#   - negative probe が認証を通していない (通したら credential leak)。
#   - positive-control probe が認証を通している (通さなければ空振り緑)。
#
# exit code の分類 (incident class を混ぜない):
#   - 1 = 観測された破れ (credential leak / false-green)。probe の実行結果そのものが赤。
#   - 2 = 入力・構造エラー (JSON 不正 / スキーマ違反 / チャネル欠落 / ペア不成立 / 重複)。
#     runner 側の不備で、破れの証拠ではない。両方あるときは 1 を優先し、全 failure を報告する。
#   - 0 は完全被覆かつ全 polarity 正のときだけ。
#
# 信頼境界 (honest): judge は runner が付けた operation ラベルを信頼する。negative と
# positive が「同一 operation を名乗る別コマンド」でないことを judge は構造的に検証できない
# (judge は結果を消費するだけで再実行しない)。judge が縛れるのは pair の operation 一致
# までで、その operation が実際に同一コマンドを指すことの保証は PR-2 runner の責務
# (実機ログが証跡)。

require "json"

module CheckCredentialIsolation
  class Error < StandardError; end

  # acceptance が要求する canonical な認証チャネル。呼び出し側 (PR-2 の probe runner) が
  # required set を縮めて harness を骨抜きにできないよう、契約としてここで固定する。
  # 同時に閉語彙 (typo guard) でもある: 未知の channel は入力エラーで弾く。チャネルを
  # 増やすのは意図的な契約変更としてこの定数の PR 修正で行う (results.json 側から足せない)。
  CHANNELS = %w[gh git-https git-ssh curl].freeze
  MODES = %w[negative positive].freeze

  USAGE = <<~TEXT
    usage: check-credential-isolation.sh --judge <results.json>

    <results.json> shape:
      { "probes": [
          { "channel": "gh", "mode": "negative", "operation": "<op id>", "authenticated": false },
          { "channel": "gh", "mode": "positive", "operation": "<op id>", "authenticated": true } ] }

    channels (all required): #{CHANNELS.join(', ')}
    各 channel は同一 operation の negative / positive ペアを1組以上持つこと。
    operation は「隔離の有無だけが違う同一コマンド」を指す識別子 (真正性は runner の責務)。

    exit: 0 = isolation verified,
          1 = breach observed (credential leak / false-green),
          2 = usage / input / structural error (missing channel, incomplete pair, duplicate)
  TEXT

  # results JSON を検証済みの probes 配列に変換する。
  # 不正な形は silent skip せず Error にする (fail fast)。
  def self.parse_input(raw)
    data = JSON.parse(raw)
    raise Error, "input must be a JSON object" unless data.is_a?(Hash)

    probes = data["probes"]
    raise Error, "probes must be an array" unless probes.is_a?(Array)
    probes.each_with_index { |probe, i| validate_probe!(probe, i) }

    probes
  end

  def self.validate_probe!(probe, index)
    raise Error, "probes[#{index}] must be an object" unless probe.is_a?(Hash)
    unless CHANNELS.include?(probe["channel"])
      raise Error, "probes[#{index}].channel must be one of #{CHANNELS.join(', ')}"
    end
    unless MODES.include?(probe["mode"])
      raise Error, "probes[#{index}].mode must be one of #{MODES.join(', ')}"
    end
    unless probe["operation"].is_a?(String) && !probe["operation"].empty?
      raise Error, "probes[#{index}].operation must be a non-empty string"
    end
    # operation は failure メッセージへ interpolate される唯一の自由文字列。改行や ANSI
    # エスケープで出力 (成功バナー等) を偽造できないよう、制御文字を入力エラーで弾く。
    if probe["operation"] =~ /[[:cntrl:]]/
      raise Error, "probes[#{index}].operation must not contain control characters"
    end
    unless [true, false].include?(probe["authenticated"])
      raise Error, "probes[#{index}].authenticated must be a boolean"
    end
  end

  # 判定本体。[breaches, structural] の 2 配列を返す (両方空なら隔離 OK)。
  # polarity (leak / false-green) は構造の成否と独立に全 probe を検査する。構造不備の
  # 陰で同居する破れの証跡が報告から漏れないようにするため (early return しない)。
  def self.judge(probes)
    [polarity_failures(probes), structural_failures(probes)]
  end

  def self.polarity_failures(probes)
    probes.flat_map do |probe|
      channel = probe["channel"]
      operation = probe["operation"]
      if probe["mode"] == "negative" && probe["authenticated"]
        ["credential leak: negative probe authenticated on channel #{channel} " \
         "(operation #{operation})"]
      elsif probe["mode"] == "positive" && !probe["authenticated"]
        ["false-green: positive-control probe failed on channel #{channel} " \
         "(operation #{operation})"]
      else
        []
      end
    end
  end

  # 構造検査: (channel, operation) group ごとに negative / positive がちょうど 1 本ずつ
  # (重複は曖昧なので不成立)、かつ canonical チャネルすべてに完全ペアが 1 組以上あること。
  def self.structural_failures(probes)
    groups = probes.group_by { |p| [p["channel"], p["operation"]] }
    failures = groups.flat_map { |(channel, operation), members| group_failures(channel, operation, members) }
    CHANNELS.each do |channel|
      next if groups.any? { |(ch, _), members| ch == channel && complete_pair?(members) }
      failures << "channel #{channel}: no complete negative/positive probe pair"
    end
    failures
  end

  def self.group_failures(channel, operation, members)
    failures = []
    negatives = members.count { |p| p["mode"] == "negative" }
    positives = members.count { |p| p["mode"] == "positive" }
    unless negatives == 1
      failures << "channel #{channel} (operation #{operation}): " \
                  "expected exactly one negative probe, got #{negatives}"
    end
    unless positives == 1
      failures << "channel #{channel} (operation #{operation}): " \
                  "expected exactly one positive-control probe, got #{positives}"
    end
    failures
  end

  def self.complete_pair?(members)
    members.count { |p| p["mode"] == "negative" } == 1 &&
      members.count { |p| p["mode"] == "positive" } == 1
  end

  def self.main(argv)
    if argv.length == 1 && %w[-h --help].include?(argv[0])
      puts USAGE
      return 0
    end
    unless argv.length == 2 && argv[0] == "--judge"
      warn USAGE
      return 2
    end

    path = argv[1]
    raise Error, "results file not found: #{path}" unless File.file?(path)

    probes = parse_input(File.read(path))
    breaches, structural = judge(probes)
    if breaches.empty? && structural.empty?
      puts "ok: credential isolation verified (#{CHANNELS.length} channels, #{probes.length} probes)"
      return 0
    end

    (breaches + structural).each { |failure| warn "FAIL: #{failure}" }
    breaches.empty? ? 2 : 1
  rescue Error, JSON::ParserError, SystemCallError => e
    warn "error: #{e.message}"
    2
  end
end

exit CheckCredentialIsolation.main(ARGV) if $PROGRAM_NAME == __FILE__
