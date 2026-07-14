#!/usr/bin/env ruby
# frozen_string_literal: true

# changed-scope-qa: Stop hook body。turn の終わりに「tracked な変更があるのに repo 宣言の
# QA check (lint / typecheck / 対象テスト) が未実行 or stale」なら、一度だけ block して
# 続行させる品質 gate (#200 §4.5 / #203)。「check を忘れたまま終了」を防ぐ。
#
# 正本: docs/quality-loop-hooks.md。
#
# 強度ラベル (偽らない): 通常経路に対する best-effort gate。hook 無効化・別経路で迂回
# できる。品質の意味判断 (何が十分な検証か) は production-rail / モデルの領分のまま。
#
# check の発見は fast-edit-check と同じ中央 local 設定 (checks.local.json) の qa_checks。
# 宣言が無い repo・repo 外・変更なしでは無言 no-op (opt-in 設計)。qa_checks は
# 「repo 全体で数秒・決定的」な suite だけを宣言する (Stop のたびに走りうる)。
#
# 設定例 (checks.local.json):
#   {
#     "/Users/<you>/src/some-repo": {
#       "qa_checks": [
#         {"name": "manifests", "command": ["scripts/check-manifests.sh", "--quiet"]}
#       ]
#     }
#   }
#   command は cwd = repo root で実行される。
#
# 無限ループ対策 (仕様・#200 §4.5):
# - `stop_hook_active` が true (この turn で既に継続済み) のときは **block しない**。
#   check は走らせ、結果は additionalContext の警告で返すだけ (人間に判断が戻る)。
# - dirty scope の hash + check 結果を state file に cache し、**同一 scope を再検査しない**
#   (pass 済み → 無言 pass / fail 済み → 非ブロッキング警告のみ。block は新しい scope に
#   対して 1 回だけ)。
# - check コマンド不在・spawn 失敗は「警告に降格」して block しない (tool 欠損で
#   セッションを塞がない)。
#
# 検査対象の帰属 (#203 裁定): agent の変更とユーザーの手元変更を区別せず、**working tree の
# dirty scope 全体** (tracked の変更 + untracked) を対象にする。単純さを優先し、ユーザー
# 自身の書きかけ変更も検査対象になることを明記する。
#
# state: ~/.cache/agent-tools/changed-scope-qa/<repo path の sha256>.json
# (AGENT_TOOLS_QA_STATE_DIR で override 可・test 用)。check は決定的である前提
# (同一 scope の再実行を cache が省くため)。

require "json"
require "digest"

module ChangedScopeQa
  VERSION = "1"

  CONFIG_PATH_ENV = "AGENT_TOOLS_CHECKS_CONFIG"
  DEFAULT_CONFIG = File.join(ENV["HOME"].to_s, ".config", "agent-tools", "checks.local.json")
  STATE_DIR_ENV = "AGENT_TOOLS_QA_STATE_DIR"
  DEFAULT_STATE_DIR = File.join(ENV["HOME"].to_s, ".cache", "agent-tools", "changed-scope-qa")

  OUTPUT_CAP = 2000

  module_function

  def config_path
    ENV[CONFIG_PATH_ENV].to_s.empty? ? DEFAULT_CONFIG : ENV[CONFIG_PATH_ENV]
  end

  def state_dir
    ENV[STATE_DIR_ENV].to_s.empty? ? DEFAULT_STATE_DIR : ENV[STATE_DIR_ENV]
  end

  def load_config
    return nil unless File.file?(config_path)

    data = JSON.parse(File.read(config_path))
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil # 設定エラーの steer は fast-edit-check 側が担う (二重に騒がない)
  end

  def repo_root
    out = IO.popen(%w[git rev-parse --show-toplevel], err: File::NULL, &:read)
    return nil unless $?.success?

    File.realpath(out.chomp)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def qa_checks(entry)
    checks = entry.is_a?(Hash) ? entry["qa_checks"] : nil
    return [] unless checks.is_a?(Array)

    checks.select do |c|
      c.is_a?(Hash) && c["command"].is_a?(Array) && !c["command"].empty? &&
        c["command"].all? { |a| a.is_a?(String) }
    end
  end

  # dirty scope の指紋。tracked の変更 (staged + unstaged) と untracked の一覧を含む。
  # 空文字列 = clean。
  def scope_fingerprint(root)
    status = IO.popen(["git", "-C", root, "status", "--porcelain", "-z"], &:read)
    return nil unless $?.success?
    return "" if status.empty?

    diff = IO.popen(["git", "-C", root, "diff", "HEAD", "--no-color", "--no-ext-diff"],
                    err: File::NULL, &:read)
    # unborn HEAD 等で diff が失敗しても status だけで指紋は成立する (弱い指紋に降格)
    Digest::SHA256.hexdigest(status + "\0" + diff.to_s)
  end

  def state_path(root)
    File.join(state_dir, Digest::SHA256.hexdigest(root) + ".json")
  end

  def read_state(root)
    path = state_path(root)
    return nil unless File.file?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  def write_state(root, fingerprint, outcome)
    require "fileutils"
    FileUtils.mkdir_p(state_dir)
    File.write(state_path(root), JSON.generate("fingerprint" => fingerprint, "outcome" => outcome))
  end

  def run_check(check, root)
    out = IO.popen(check["command"], chdir: root, err: %i[child out], &:read)
    status = $?.exitstatus
    { name: check["name"] || check["command"].first, ok: status == 0,
      output: out.to_s, spawn_failed: status.nil? }
  rescue Errno::ENOENT
    { name: check["name"] || check["command"].first, ok: false, output: "", spawn_failed: true }
  end

  def truncate(text)
    text = text.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?
    text.length > OUTPUT_CAP ? text[0, OUTPUT_CAP] + "\n…(truncated)" : text
  end

  def emit_context(message)
    puts JSON.generate(
      "hookSpecificOutput" => {
        "hookEventName" => "Stop",
        "additionalContext" => message,
      }
    )
  end

  def run
    payload = JSON.parse($stdin.read) rescue {}
    already_continued = payload["stop_hook_active"] == true

    config = load_config
    return 0 if config.nil?

    root = repo_root
    return 0 if root.nil?

    checks = qa_checks(config[root])
    return 0 if checks.empty?

    fingerprint = scope_fingerprint(root)
    return 0 if fingerprint.nil? || fingerprint.empty? # clean or 判定不能 → gate しない

    state = read_state(root)
    if state && state["fingerprint"] == fingerprint
      case state["outcome"]
      when "pass"
        return 0
      else
        # 同一 scope の失敗は再 block しない (人間判断へ)。無言だと状態が見えないので
        # 非ブロッキングの一言だけ残す。
        emit_context("changed-scope-qa: 前回と同一の変更 scope で未解消の check 失敗があります " \
                     "(再 block はしません。人間の判断に委ねます)。")
        return 0
      end
    end

    results = checks.map { |c| run_check(c, root) }
    missing = results.select { |r| r[:spawn_failed] }
    failures = results.reject { |r| r[:ok] || r[:spawn_failed] }

    unless missing.empty?
      emit_context("changed-scope-qa: check を実行できませんでした (コマンド不在?): " \
                   "#{missing.map { |r| r[:name] }.join(', ')} — block はしません。")
      # 実行不能は cache しない (環境が直れば次の Stop で再試行される)
      return 0 if failures.empty?
    end

    if failures.empty?
      write_state(root, fingerprint, "pass")
      return 0
    end

    write_state(root, fingerprint, "fail")
    summary = failures.map { |r| "[#{r[:name]}]\n#{truncate(r[:output])}" }.join("\n")
    if already_continued
      emit_context("changed-scope-qa: check がまだ失敗しています (この turn では再 block " \
                   "しません):\n#{summary}")
      return 0
    end

    warn "changed-scope-qa: 変更 scope に対する repo 宣言の check が失敗しています。" \
         "終了する前に修正してください:\n#{summary}"
    2
  rescue StandardError
    0 # fail-open: hook 内部の想定外でセッションを塞がない
  end
end

exit ChangedScopeQa.run if $PROGRAM_NAME == __FILE__
