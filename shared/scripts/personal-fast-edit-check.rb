#!/usr/bin/env ruby
# frozen_string_literal: true

# fast-edit-check: PostToolUse (Edit|Write) hook body。編集直後の変更ファイル 1 個に
# repo 宣言済みの高速 check (syntax / lint) を実行し、失敗要約だけを
# hookSpecificOutput.additionalContext でモデルに返す steering hook (#200 §4.4 / #203)。
# 「書いた直後に機械が指摘 → その場で直す」ループの機械判定部分を担う。
#
# 正本: docs/quality-loop-hooks.md。
#
# 強度ラベル (偽らない): steering / fail-open。block しない (permissionDecision を
# 付けない)。hook 内部の想定外はすべて exit 0 で透過する (編集操作を壊さない)。
# 品質の意味判断 (要求一致・最小差分) は production-rail skill の領分のまま。
#
# check コマンドの発見 (自動推測しない・#203 裁定):
# - 宣言の正本は **ユーザー所有の untracked 中央設定** ~/.config/agent-tools/checks.local.json。
#   repo の実 path をキーに edit_checks (pattern + command) を宣言した repo でだけ動き、
#   宣言が無い repo では無言 no-op。
# - repo 内の宣言ファイルは**読まない**: clone した第三者 repo が「編集のたびに実行される
#   任意コマンド」を宣言できてしまうため (宣言の所有をユーザーに固定する)。
# - 設定形式が JSON なのは、standalone 配布 script に psych 3/4 分岐 (yaml_util の領分) を
#   持ち込まないため。
#
# 設定例 (checks.local.json):
#   {
#     "/Users/<you>/src/some-repo": {
#       "edit_checks": [
#         {"name": "ruby-syntax", "pattern": "\\.rb$", "command": ["ruby", "-c"]}
#       ]
#     }
#   }
#   command には対象ファイルの絶対 path が 1 引数として追記され、cwd = repo root で実行される。
#   edit_checks は「1 ファイル・数百 ms」の高速 check だけを宣言する (PostToolUse は編集の
#   たびに同期で走る)。
#
# payload 互換: Claude Code の PostToolUse payload (tool_input.file_path) は #201 で実測済み。
# Codex (apply_patch) の payload 形は未実測で、file_path が取れない場合は無言 no-op に
# 倒れる (fail-open)。配備時に実測して追従する (honest-label)。

require "json"

module FastEditCheck
  VERSION = "1"

  CONFIG_PATH_ENV = "AGENT_TOOLS_CHECKS_CONFIG"
  DEFAULT_CONFIG = File.join(ENV["HOME"].to_s, ".config", "agent-tools", "checks.local.json")

  # モデルに返す失敗出力の上限 (context を溢れさせない)。
  OUTPUT_CAP = 2000

  module_function

  def config_path
    ENV[CONFIG_PATH_ENV].to_s.empty? ? DEFAULT_CONFIG : ENV[CONFIG_PATH_ENV]
  end

  # 設定を読む。無い = opt-in していない (nil)。壊れている = 警告文字列を返す
  # (無言で握り潰すとユーザーが設定ミスに気づけない)。
  def load_config
    return nil unless File.file?(config_path)

    data = JSON.parse(File.read(config_path))
    return "checks.local.json のトップレベルが object ではありません" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    "checks.local.json を JSON として解釈できません"
  end

  def repo_root_for(file)
    dir = File.dirname(file)
    return nil unless File.directory?(dir)

    out = IO.popen(["git", "-C", dir, "rev-parse", "--show-toplevel"], err: File::NULL, &:read)
    return nil unless $?.success?

    File.realpath(out.chomp)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  # 宣言 entry を [file に一致する有効 check, 不正 entry の名前] に分類する。
  # 不正 entry (構造不備・壊れた regex) は黙って除外せず設定エラーとして可視化する
  # (「設定済みなのに動かない」を診断可能にする)。
  def checks_for(entry, file)
    checks = entry.is_a?(Hash) ? entry["edit_checks"] : nil
    return [[], []] unless checks.is_a?(Array)

    matched = []
    invalid = []
    checks.each_with_index do |c, i|
      unless c.is_a?(Hash) && c["pattern"].is_a?(String) && c["command"].is_a?(Array) &&
             !c["command"].empty? && c["command"].all? { |a| a.is_a?(String) }
        invalid << "edit_checks[#{i}]"
        next
      end
      begin
        matched << c if Regexp.new(c["pattern"]).match?(file)
      rescue RegexpError
        invalid << (c["name"] || "edit_checks[#{i}]") + " (壊れた regex)"
      end
    end
    [matched, invalid]
  end

  def run_check(check, file, repo_root)
    out = IO.popen(check["command"] + [file], chdir: repo_root, err: %i[child out], &:read)
    status = $?.exitstatus
    { name: check["name"] || check["command"].first, ok: status == 0,
      output: out.to_s, spawn_failed: status.nil? }
  rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
    # コマンド不在だけでなく実行権限喪失・不正な実行形式も spawn 失敗として可視化する
    # (包括 rescue の無言 exit 0 に落とすと check の恒久不活性に気づけない)
    { name: check["name"] || check["command"].first, ok: false,
      output: "(check を実行できません: #{e.class})", spawn_failed: true }
  end

  def truncate(text)
    text = text.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?
    text.length > OUTPUT_CAP ? text[0, OUTPUT_CAP] + "\n…(truncated)" : text
  end

  def emit(message)
    puts JSON.generate(
      "hookSpecificOutput" => {
        "hookEventName" => "PostToolUse",
        "additionalContext" => message,
      }
    )
  end

  def run
    payload = JSON.parse($stdin.read)
    file = payload.dig("tool_input", "file_path")
    return 0 unless file.is_a?(String) && File.file?(file)

    config = load_config
    return 0 if config.nil?
    if config.is_a?(String)
      emit("fast-edit-check: 設定エラー: #{config} (#{config_path})")
      return 0
    end

    repo_root = repo_root_for(file)
    return 0 if repo_root.nil?

    entry = config[repo_root]
    checks, invalid = entry ? checks_for(entry, file) : [[], []]

    parts = []
    unless invalid.empty?
      parts << "fast-edit-check: 設定エラー: 不正な check 宣言を無視しました: " \
               "#{invalid.join(', ')} (#{config_path})"
    end

    failures = checks.map { |c| run_check(c, file, repo_root) }.reject { |r| r[:ok] }
    unless failures.empty?
      body = failures.map { |r| "[#{r[:name]}]\n#{truncate(r[:output])}" }.join("\n")
      parts << "fast-edit-check: #{File.basename(file)} への編集が repo 宣言の check に失敗しました。" \
               "いま直してください (自動修正はしません):\n#{body}"
    end
    return 0 if parts.empty?

    # 上限は check 単位だけでなく合計にも適用する (複数失敗で context を溢れさせない)
    emit(truncate(parts.join("\n")))
    0
  rescue StandardError
    0 # fail-open: hook 内部の想定外で編集操作を壊さない
  end
end

exit FastEditCheck.run if $PROGRAM_NAME == __FILE__
