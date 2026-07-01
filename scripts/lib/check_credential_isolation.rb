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
#   - 各チャネルは同一 operation の negative / positive ペアを1組ずつ持つ (positive control が
#     negative と別操作を叩く空振り緑を弾く)。
#   - negative probe が認証を通していない (通したら credential leak)。
#   - positive-control probe が認証を通している (通さなければ空振り緑)。
#
# 信頼境界 (honest): judge は runner が付けた operation ラベルを信頼する。negative と
# positive が「同一 operation を名乗る別コマンド」でないことを judge は構造的に検証できない
# (judge は結果を消費するだけで再実行しない)。judge が縛れるのは pair の operation 一致
# までで、その operation が実際に同一コマンドを指すことの保証は PR-2 runner の責務
# (実機ログが証跡)。
#
# exit: 0 = 隔離を確認 / 1 = 隔離の破れを検出 / 2 = usage・入力エラー

require "json"

module CheckCredentialIsolation
  class Error < StandardError; end

  # acceptance が要求する canonical な認証チャネル。呼び出し側 (PR-2 の probe runner) が
  # required set を縮めて harness を骨抜きにできないよう、契約としてここで固定する。
  CHANNELS = %w[gh git-https git-ssh curl].freeze
  MODES = %w[negative positive].freeze

  USAGE = <<~TEXT
    usage: check-credential-isolation.sh --judge <results.json>

    <results.json> shape:
      { "probes": [
          { "channel": "gh", "mode": "negative", "operation": "<op id>", "authenticated": false },
          { "channel": "gh", "mode": "positive", "operation": "<op id>", "authenticated": true } ] }

    channels (all required): #{CHANNELS.join(', ')}
    各 channel は同一 operation の negative / positive ペアを1組ずつ持つこと。
    operation は「隔離の有無だけが違う同一コマンド」を指す識別子 (真正性は runner の責務)。

    exit: 0 = isolation verified, 1 = isolation breach detected, 2 = usage/input error
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
    unless [true, false].include?(probe["authenticated"])
      raise Error, "probes[#{index}].authenticated must be a boolean"
    end
  end

  # canonical チャネルすべてを判定し、failure メッセージ列を返す (空なら隔離 OK)。
  def self.judge(probes)
    CHANNELS.flat_map { |channel| channel_failures(channel, probes) }
  end

  # 1 チャネル分の判定: 同一 operation の negative/positive ペアが1組あり、polarity が
  # 正しいこと。ペアが揃わない時点で偽の安心なので早期に fail を返す。
  def self.channel_failures(channel, probes)
    negatives = probes.select { |p| p["channel"] == channel && p["mode"] == "negative" }
    positives = probes.select { |p| p["channel"] == channel && p["mode"] == "positive" }
    unless negatives.length == 1
      return ["channel #{channel}: expected exactly one negative probe, got #{negatives.length}"]
    end
    unless positives.length == 1
      return ["channel #{channel}: expected exactly one positive-control probe, got #{positives.length}"]
    end

    pair_failures(channel, negatives.first, positives.first)
  end

  def self.pair_failures(channel, negative, positive)
    failures = []
    unless negative["operation"] == positive["operation"]
      failures << "channel #{channel}: operation mismatch " \
                  "(negative=#{negative['operation']}, positive=#{positive['operation']}); " \
                  "positive control must exercise the same operation, differing only by isolation"
    end
    if negative["authenticated"]
      failures << "credential leak: negative probe authenticated on channel #{channel} " \
                  "(operation #{negative['operation']})"
    end
    unless positive["authenticated"]
      failures << "false-green: positive-control probe failed on channel #{channel} " \
                  "(operation #{positive['operation']})"
    end
    failures
  end

  def self.main(argv)
    unless argv.length == 2 && argv[0] == "--judge"
      warn USAGE
      return 2
    end

    path = argv[1]
    raise Error, "results file not found: #{path}" unless File.file?(path)

    probes = parse_input(File.read(path))
    failures = judge(probes)
    if failures.empty?
      puts "ok: credential isolation verified (#{CHANNELS.length} channels, #{probes.length} probes)"
      0
    else
      failures.each { |failure| warn "FAIL: #{failure}" }
      1
    end
  rescue Error, JSON::ParserError => e
    warn "error: #{e.message}"
    2
  end
end

exit CheckCredentialIsolation.main(ARGV) if $PROGRAM_NAME == __FILE__
