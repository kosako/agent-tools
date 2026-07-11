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
#   - REQUIRED_CHANNELS のすべてが results に揃っている (チャネル丸ごとの欠落 =
#     偽の安心 を弾く。required set は契約として固定し、呼び出し側は縮められない)。
#     git-ssh / curl は KNOWN だが required floor 外の opt-in (results に有れば検証・無くても
#     欠落扱いしない。理由は KNOWN_CHANNELS の注記)。
#   - 各チャネルは同一 operation の negative / positive ペアを1組以上持つ (positive control
#     が negative と別操作を叩く空振り緑を弾く。ペアを増やす方向の拡張は妨げない)。
#   - negative probe が認証を通していない (通したら credential leak)。
#   - positive-control probe が認証を通している (通さなければ空振り緑)。
#   - 各チャネルは reachability control (隔離 session 内の認証なし同一ホストアクセス) を
#     ちょうど 1 本持つ (#185)。negative の失敗が「credential を剥いだから」なのか
#     「そもそも到達できないから」(一過性障害 / proxy が env 隔離で落ちた) なのかを分岐する:
#       - 隔離で認証あり成功 → credential leak (破れ)。
#       - 隔離で認証あり失敗 + 認証なし到達成功 → 緑 (拒否は認証由来と言える)。
#       - 隔離で認証なしも失敗 (reachable=false) → indeterminate (到達不能。緑に数えない)。
#     positive control では原理的に捕まらない「隔離側だけの非対称な到達不能」を塞ぐ。
#     エラー種別 (DNS/TLS/proxy) の解釈はしない (4-state taxonomy は不採用・#185)。
#
# exit code の分類 (incident class を混ぜない):
#   - 1 = 観測された破れ (credential leak / false-green)。probe の実行結果そのものが赤。
#   - 2 = 入力・構造エラー (JSON 不正 / スキーマ違反 / チャネル欠落 / ペア不成立 / 重複 /
#     reachability control の欠落) と indeterminate (隔離 session から到達不能で判定不能)。
#     どちらも破れの証拠ではない。破れと同居するときは 1 を優先し、全 failure を報告する。
#   - 0 は完全被覆かつ全 polarity 正かつ全チャネル到達確認済みのときだけ。
#
# 信頼境界 (honest): judge は runner が付けた operation ラベルを信頼する。negative と
# positive が「同一 operation を名乗る別コマンド」でないことを judge は構造的に検証できない
# (judge は結果を消費するだけで再実行しない)。judge が縛れるのは pair の operation 一致
# までで、その operation が実際に同一コマンドを指すことの保証は PR-2 runner の責務
# (実機ログが証跡)。

require "json"

module CheckCredentialIsolation
  class Error < StandardError; end

  # acceptance が **必ず** 完全ペアを要求する canonical チャネル (required floor)。呼び出し側
  # (probe runner) が required set を縮めて harness を骨抜きにできないよう、契約としてここで
  # 固定する。gh (keyring) と git-https (osxkeychain) は **この Mac に永続的に** 存在する
  # keychain-backed な認証源で、どのセッションでも positive control が立つ = 再現可能な床。
  REQUIRED_CHANNELS = %w[gh git-https].freeze

  # 既知チャネルの閉語彙 (typo guard)。未知の channel 名は入力エラーで弾く。git-ssh と curl は
  # 既知だが required floor には含めない (opt-in): それぞれの ambient 認証源 (ssh-agent /
  # ~/.netrc) は **セッション・設定依存** で、ロードされていないと positive control が立たず
  # (空振り緑)、required にすると「credential 捏造」か「vacuous pass」のどちらかを強いる。
  # opt-in は results に含めれば pair / polarity を検証する (含めたなら完全ペア必須で骨抜けに
  # しない) が、無くても required 欠落にはしない。ambient credential がアクティブな環境では
  # config に足せばそのチャネルも検証される。この分界は PR-2 で env 隔離の実機現実 (ambient
  # 認証源が永続か否か) に合わせた honest-label な調整 (#129 P3-02)。
  KNOWN_CHANNELS = (REQUIRED_CHANNELS + %w[git-ssh curl]).freeze
  MODES = %w[negative positive reachability].freeze

  USAGE = <<~TEXT
    usage: check-credential-isolation.sh --judge <results.json>

    <results.json> shape:
      { "probes": [
          { "channel": "gh", "mode": "negative",     "operation": "<op id>", "authenticated": false },
          { "channel": "gh", "mode": "positive",     "operation": "<op id>", "authenticated": true },
          { "channel": "gh", "mode": "reachability", "operation": "<op id>", "reachable": true } ] }

    required channels: #{REQUIRED_CHANNELS.join(', ')}
    optional channels: git-ssh, curl (含めれば検証・無くても欠落扱いしない。ambient 認証源
                       = ssh-agent / ~/.netrc がセッション依存のため)
    各 channel は同一 operation の negative / positive ペアを1組以上持つこと。
    operation は「隔離の有無だけが違う同一コマンド」を指す識別子 (真正性は runner の責務)。
    さらに各 channel は reachability control (隔離 session 内の認証なし同一ホストアクセス)
    をちょうど 1 本持つこと (#185)。reachable=false は indeterminate (到達不能・判定不能) で、
    緑に数えず exit 2 に倒す。

    exit: 0 = isolation verified,
          1 = breach observed (credential leak / false-green),
          2 = usage / input / structural error (missing channel, incomplete pair, duplicate,
              missing reachability control) or indeterminate (isolated session unreachable)
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
    unless KNOWN_CHANNELS.include?(probe["channel"])
      raise Error, "probes[#{index}].channel must be one of #{KNOWN_CHANNELS.join(', ')}"
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
    # mode ごとに観測 field を 1 つに固定する (reachability は reachable / それ以外は
    # authenticated)。他方の field の混入は曖昧なので入力エラー (fail-closed)。
    if probe["mode"] == "reachability"
      unless [true, false].include?(probe["reachable"])
        raise Error, "probes[#{index}].reachable must be a boolean"
      end
      if probe.key?("authenticated")
        raise Error, "probes[#{index}]: reachability probe must not carry authenticated"
      end
    else
      unless [true, false].include?(probe["authenticated"])
        raise Error, "probes[#{index}].authenticated must be a boolean"
      end
      if probe.key?("reachable")
        raise Error, "probes[#{index}]: #{probe['mode']} probe must not carry reachable"
      end
    end
  end

  # 判定本体。[breaches, structural, indeterminates] の 3 配列を返す (すべて空なら隔離 OK)。
  # polarity (leak / false-green) は構造の成否と独立に全 probe を検査する。構造不備の
  # 陰で同居する破れの証跡が報告から漏れないようにするため (early return しない)。
  # indeterminate (到達不能) は破れでも runner の不備でもない第 3 の結果だが、
  # exit class は 2 (緑に数えない・破れの証拠にもしない, #185)。
  def self.judge(probes)
    [polarity_failures(probes), structural_failures(probes), indeterminate_failures(probes)]
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
  # (重複は曖昧なので不成立)、かつ REQUIRED_CHANNELS すべてに完全ペアが 1 組以上あること。
  # 完全ペア要求は全 group にかかる (curl を含めたなら curl も完全ペアが要る = opt-in でも
  # 骨抜けにしない) が、「チャネル欠落」の判定は required floor のみ (curl 不在は許す)。
  # reachability control はペアの operation に束縛しない別コマンドなので、pair group の
  # 検査から分離し、チャネル単位でちょうど 1 本を要求する (#185)。
  def self.structural_failures(probes)
    pair_probes, reach_probes = probes.partition { |p| p["mode"] != "reachability" }
    groups = pair_probes.group_by { |p| [p["channel"], p["operation"]] }
    failures = groups.flat_map { |(channel, operation), members| group_failures(channel, operation, members) }
    REQUIRED_CHANNELS.each do |channel|
      next if groups.any? { |(ch, _), members| ch == channel && complete_pair?(members) }
      failures << "channel #{channel}: no complete negative/positive probe pair"
    end
    failures + reachability_structural_failures(pair_probes, reach_probes)
  end

  # reachability control の被覆検査: probe pair を持つ全チャネルにちょうど 1 本 (欠落 =
  # 到達不能由来の false-green を見分けられない / 重複 = 曖昧)。pair の無いチャネルへの
  # reachability だけの混入も曖昧なので弾く (fail-closed)。
  def self.reachability_structural_failures(pair_probes, reach_probes)
    failures = []
    pair_channels = pair_probes.map { |p| p["channel"] }.uniq
    reach_by_channel = reach_probes.group_by { |p| p["channel"] }
    pair_channels.each do |channel|
      count = reach_by_channel.fetch(channel, []).length
      if count.zero?
        failures << "channel #{channel}: no reachability control probe " \
                    "(unreachable-host false-green cannot be ruled out)"
      elsif count > 1
        failures << "channel #{channel}: expected exactly one reachability probe, got #{count}"
      end
    end
    (reach_by_channel.keys - pair_channels).each do |channel|
      failures << "channel #{channel}: reachability probe without a negative/positive probe pair"
    end
    failures
  end

  # 到達不能 (reachable=false) = indeterminate。negative の失敗を「隔離が効いた」と
  # 解釈できない (一過性障害 / proxy-delta の窓, #185)。緑に数えず exit 2 に倒す。
  def self.indeterminate_failures(probes)
    probes.select { |p| p["mode"] == "reachability" && p["reachable"] == false }.map do |p|
      "indeterminate: channel #{p['channel']} unreachable from isolated session " \
        "(operation #{p['operation']}); negative failure cannot be attributed to isolation"
    end
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
    breaches, structural, indeterminates = judge(probes)
    if breaches.empty? && structural.empty? && indeterminates.empty?
      channels = probes.map { |p| p["channel"] }.uniq.length
      puts "ok: credential isolation verified (#{channels} channels, #{probes.length} probes)"
      return 0
    end

    (breaches + structural + indeterminates).each { |failure| warn "FAIL: #{failure}" }
    breaches.empty? ? 2 : 1
  rescue Error, JSON::ParserError, SystemCallError => e
    warn "error: #{e.message}"
    2
  end
end

exit CheckCredentialIsolation.main(ARGV) if $PROGRAM_NAME == __FILE__
