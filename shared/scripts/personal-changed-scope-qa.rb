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
# - scope 指紋 + 結果を state file に cache し、**同一 scope への block は 1 回だけ**。
#   pass 済み scope は無言 pass / fail 済み scope は非ブロッキング警告のみ。
# - check コマンドの spawn 失敗 (不在 ENOENT・権限 EACCES・不正形式 ENOEXEC) は
#   「警告に降格」して block しない。起動した check が signal で終わったのは spawn 失敗ではなく
#   実 failure (#373)。spawn 失敗した check は cache で確定させず、
#   state に missing として分離保持して cache-hit 時にもそれだけ再試行する
#   (環境が直れば拾われる。実 failure の再 block はしない)。
#
# scope 指紋 (false pass を防ぐため QA の実入力を全部含める):
#   HEAD sha + `git status --porcelain -z -uall` + `git diff HEAD` + untracked file の
#   内容 digest + 宣言 check 定義の JSON。untracked の内容変更・dirty を保った branch
#   切替・check 定義の変更のどれでも指紋が変わり、再検査される。初回 commit 前 (HEAD が無い)
#   は `git diff HEAD` の代わりに stage 済み (`--cached`) と未 stage の diff を使う。材料の git が
#   失敗したら判定不能として gate しない (#373)。
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

  def check_name(check)
    check["name"] || check["command"].first
  end

  # [有効 check, 不正 entry の名前]。不正 entry は黙って除外せず警告で可視化する。
  def qa_checks(entry)
    checks = entry.is_a?(Hash) ? entry["qa_checks"] : nil
    return [[], []] unless checks.is_a?(Array)

    valid = []
    invalid = []
    checks.each_with_index do |c, i|
      if c.is_a?(Hash) && c["command"].is_a?(Array) && !c["command"].empty? &&
         c["command"].all? { |a| a.is_a?(String) }
        valid << c
      else
        invalid << "qa_checks[#{i}]"
      end
    end
    [valid, invalid]
  end

  # status --porcelain -z -uall の untracked ("?? ") entry の内容 digest。
  # rename / copy entry は path が 2 要素 (新\0旧) なので旧側を読み飛ばす。
  def untracked_digest(status_z, root)
    tokens = status_z.split("\0")
    parts = []
    i = 0
    while i < tokens.length
      token = tokens[i]
      i += 1
      next if token.nil? || token.length < 4

      xy = token[0, 2]
      path = token[3..-1]
      i += 1 if xy.start_with?("R", "C") # 旧 path token を消費
      next unless xy == "??"

      full = File.join(root, path)
      digest =
        begin
          if File.symlink?(full)
            # File.file? / SHA256.file はリンク先を評価する (dangling だと常に non-file)。
            # リンクの向き先そのものを指紋に含め、種別も区別する (R2 指摘)。
            "symlink:" + Digest::SHA256.hexdigest(File.readlink(full))
          elsif File.file?(full)
            Digest::SHA256.file(full).hexdigest
          else
            "non-file"
          end
        rescue StandardError
          "unreadable"
        end
      parts << "#{path}=#{digest}"
    end
    parts.join("\n")
  end

  # dirty scope の指紋。nil = 判定不能 / 空 = clean。材料の git のどれかが失敗したら判定不能にする
  # (空の diff として指紋を作ると、変わった内容を同じ scope とみなして cache に当たる。#373)。
  def scope_fingerprint(root, checks)
    status = git_output(root, "status", "--porcelain", "-z", "-uall")
    return nil if status.nil?
    return "" if status.empty?

    head, head_status = git_run(root, "rev-parse", "--verify", "-q", "HEAD")
    # `--verify -q` は HEAD が無い (初回 commit 前) ときだけ exit 1 になる。それ以外の失敗 (128 や signal) は
    # unborn と区別して判定不能にする。
    unborn = head_status.exitstatus == 1
    return nil unless head_status.success? || unborn

    # --no-ext-diff: 外部 diff の出力を指紋に使うと、内容が変わっても指紋が同じになり cache で false pass になる。
    # --no-color: 色の設定で指紋が変わらないようにする (test で固定。#430 の 5)
    diff = unborn ? unborn_diff(root) : git_output(root, "diff", "HEAD", "--no-color", "--no-ext-diff")
    return nil if diff.nil?

    Digest::SHA256.hexdigest(
      [unborn ? "unborn" : head.chomp, status, diff, untracked_digest(status, root),
       JSON.generate(checks)].join("\0")
    )
  end

  # 初回 commit 前 (HEAD が無い) は `git diff HEAD` が使えない。stage 済み (index と空の tree の差) と
  # 未 stage (作業ツリーと index の差) を合わせて読む (#373)。どちらかが失敗したら nil。
  def unborn_diff(root)
    staged = git_output(root, "diff", "--cached", "--no-color", "--no-ext-diff")
    unstaged = git_output(root, "diff", "--no-color", "--no-ext-diff")
    staged && unstaged && "#{staged}\0#{unstaged}"
  end

  # git の出力と終了状態。
  def git_run(root, *args)
    out = IO.popen(["git", "-C", root, *args], err: File::NULL, &:read)
    [out, $?]
  end

  # git の出力 (exit 0 のときだけ)。失敗は nil。
  def git_output(root, *args)
    out, status = git_run(root, *args)
    status.success? ? out : nil
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

  def write_state(root, fingerprint, outcome, missing)
    require "fileutils"
    FileUtils.mkdir_p(state_dir)
    File.write(state_path(root),
               JSON.generate("fingerprint" => fingerprint, "outcome" => outcome,
                             "missing" => missing))
  end

  # 起動の失敗は spawn 時の例外だけで判定する。起動した check が signal で終わったのは、実行して異常
  # 終了した (crash や外からの kill) ので実 failure として扱い、終了の理由に signal 名を残す (#373。hook の
  # timeout や中断では hook 自身も止まるので、ここで観測するのは check だけが落ちたとき)。
  def run_check(check, root)
    out = IO.popen(check["command"], chdir: root, err: %i[child out], &:read)
    status = $?
    reason = status.signaled? ? "terminated by SIG#{Signal.signame(status.termsig)}" : "exit #{status.exitstatus}"
    { name: check_name(check), ok: status.success?, output: out.to_s, reason: reason, spawn_failed: false }
  rescue SystemCallError => e
    # 不在だけでなく権限喪失・不正形式・path の途中が file (ENOTDIR)・symlink の loop (ELOOP) など、起動時の
    # SystemCallError はすべて spawn 失敗として可視化する (包括 rescue の無言 exit 0 に落とすと、その repo の
    # 他の check の結果も出ないまま恒久不活性になる。#430 の 4)
    { name: check_name(check), ok: false, output: "(#{e.class})", reason: "spawn failed (#{e.class})",
      spawn_failed: true }
  end

  def truncate(text)
    text = text.dup
    text.force_encoding(Encoding::UTF_8)
    text = text.scrub("�") unless text.valid_encoding?
    text.length > OUTPUT_CAP ? text[0, OUTPUT_CAP] + "\n…(truncated)" : text
  end

  # Stop の additionalContext は Claude を再継続させる。警告はユーザーにだけ届ける。
  def emit_warning(message)
    puts JSON.generate("systemMessage" => truncate(message))
  end

  # 失敗した check の名前と終了の理由を先にまとめ、ログはその後ろに置く。呼び出し側は要約全体を先頭から
  # 打ち切るので、長いログの後ろにある check の理由が消えないようにする (#381 review CSQA-02)。
  def failure_summary(failures)
    reasons = failures.map { |r| "- #{r[:name]}: #{r[:reason]}" }
    logs = failures.map { |r| "[#{r[:name]}]\n#{truncate(r[:output])}" }
    (reasons + logs).join("\n")
  end

  # 同一 scope の cache hit。block は消費済みなので二度と block しない。
  # missing として保持した check だけ再試行し (環境が直れば拾う)、state を更新して
  # [exit code, ユーザー向け警告 (nil 可)] を返す。
  def handle_cached(root, fingerprint, state, checks)
    missing_names = state["missing"].is_a?(Array) ? state["missing"] : []
    return [0, nil] if state["outcome"] == "pass" && missing_names.empty?

    retried = checks.select { |c| missing_names.include?(check_name(c)) }
                    .map { |c| run_check(c, root) }
    still_missing = retried.select { |r| r[:spawn_failed] }.map { |r| r[:name] }
    new_failures = retried.reject { |r| r[:ok] || r[:spawn_failed] }

    if state["outcome"] == "fail" || !new_failures.empty?
      write_state(root, fingerprint, "fail", still_missing)
      [0, "changed-scope-qa: 前回と同一の変更 scope で未解消の check 失敗があります " \
          "(再 block はしません。人間の判断に委ねます)。" +
          (new_failures.empty? ? "" : "\n#{failure_summary(new_failures)}")]
    elsif still_missing.empty?
      write_state(root, fingerprint, "pass", [])
      [0, nil]
    else
      write_state(root, fingerprint, "pass", still_missing)
      [0, "changed-scope-qa: check を実行できませんでした: " \
          "#{still_missing.join(', ')} — block はしません。"]
    end
  end

  # stdout の JSON emission は 1 回だけに保つ (複数 JSON 行は runner の parse を壊しうる)。
  # notes に非ブロッキングの伝達事項を集め、最後にまとめて 1 回 emit する。
  def run
    payload = JSON.parse($stdin.read) rescue {}
    already_continued = payload["stop_hook_active"] == true
    notes = []

    config = load_config
    return 0 if config.nil?

    root = repo_root
    return 0 if root.nil?

    checks, invalid = qa_checks(config[root])
    return 0 if checks.empty? && invalid.empty?

    unless invalid.empty?
      notes << "changed-scope-qa: 設定エラー: 不正な check 宣言を無視しました: " \
               "#{invalid.join(', ')} (#{config_path})"
    end

    code = gate(root, checks, already_continued, notes) unless checks.empty?
    code ||= 0
    emit_warning(notes.join("\n")) unless notes.empty? || code != 0
    code
  rescue StandardError
    0 # fail-open: hook 内部の想定外でセッションを塞がない
  end

  # gate 本体。非ブロッキングの伝達事項は notes に追記し、block するときだけ
  # stderr + exit 2 を使う (block 時は stdout JSON が無視されるため notes は出さない)。
  def gate(root, checks, already_continued, notes)
    fingerprint = scope_fingerprint(root, checks)
    return 0 if fingerprint.nil? || fingerprint.empty? # clean or 判定不能 → gate しない

    state = read_state(root)
    if state && state["fingerprint"] == fingerprint
      code, message = handle_cached(root, fingerprint, state, checks)
      notes << message if message
      return code
    end

    results = checks.map { |c| run_check(c, root) }
    missing = results.select { |r| r[:spawn_failed] }
    failures = results.reject { |r| r[:ok] || r[:spawn_failed] }
    missing_names = missing.map { |r| r[:name] }

    if failures.empty?
      if missing.empty?
        write_state(root, fingerprint, "pass", [])
      else
        # 実行できた check は全 pass だが未実行が残る: pass + missing で保持し、
        # cache-hit 時に missing だけ再試行される (block はしない)
        notes << "changed-scope-qa: check を実行できませんでした: " \
                 "#{missing_names.join(', ')} — block はしません。"
        write_state(root, fingerprint, "pass", missing_names)
      end
      return 0
    end

    # 実 failure あり: この scope への block を 1 回だけ消費する (missing は分離保持)
    write_state(root, fingerprint, "fail", missing_names)
    summary = failure_summary(failures)
    summary += "\n(未実行の check: #{missing_names.join(', ')})" unless missing.empty?
    if already_continued
      notes << "changed-scope-qa: check がまだ失敗しています (この turn では再 block " \
               "しません):\n#{summary}"
      return 0
    end

    warn truncate("changed-scope-qa: 変更 scope に対する repo 宣言の check が失敗しています。" \
                  "終了する前に修正してください:\n#{summary}")
    2
  end
end

exit ChangedScopeQa.run if $PROGRAM_NAME == __FILE__
