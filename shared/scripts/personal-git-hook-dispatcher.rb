#!/usr/bin/env ruby
# frozen_string_literal: true

# git-hook-dispatcher: global `core.hooksPath` から呼ばれる git hook の入口。
# stage (pre-commit / commit-msg) ごとの personal gate を順に実行し、全部通れば
# その repo 自身の hook (`$(git rev-parse --git-common-dir)/hooks/<stage>`) に chain する。
# global hooksPath が per-repo hook を「置換」してしまう git の仕様 (#201 実測) を、
# dispatcher 側の chain で「合成」に変えるのが存在理由。
#
# 正本: docs/git-hook-gates.md。#200 §4.1-4.2 / #202。
#
# 強度ラベル (偽らない): これは通常経路 (git commit) に対する best-effort guardrail。
# `--no-verify` / core.hooksPath の差し替え (husky 等の local 設定を含む) / 別 client で
# 迂回できる。enforcement boundary ではない。
#
# 呼び出し契約 (dotfiles 側 shim):
#   pre-commit:  exec <deploy path>/personal-git-hook-dispatcher pre-commit "$@"
#   commit-msg:  exec <deploy path>/personal-git-hook-dispatcher commit-msg "$@"
# gate 本体は dispatcher と同じ directory に配備されている前提 (sync の script 配備先)。
# gate が欠けているときは fail-closed (exit 2) で commit を止める。配備欠損を黙って
# 素通りさせない。
#
# exit code: 0 = 全 gate pass (+ chain 先の exit 0 / chain なし) / 1 = gate の finding で
# block / 2 = usage・構成エラー (未知 stage・gate 欠損・gate 起動失敗・git 情報取得失敗・
# その他の例外)。chain 先がある場合は exec で置き換わるため chain 先の exit code がそのまま
# 返る。run 内で起きた例外は捕捉して 2 に正規化し、backtrace は出さず原因を 1 行 warn する
# (#274。Ruby 既定の例外終了は exit 1 で、gate の finding による block と区別がつかない)。

module GitHookDispatcher
  STAGE_GATES = {
    "pre-commit" => %w[personal-public-safety-gate],
    "commit-msg" => %w[personal-ai-trailer-gate],
  }.freeze

  # 再入 sentinel (stage 単位)。repo hook が shim (→ dispatcher) を指す誤設定でも、
  # realpath 比較では検出できない間接参照で無限再帰になる (H206-04)。chain 実行時に
  # この env を立て、再入を検出したら gate 済みとして即 exit 0 する。副作用として、
  # chain 先 hook が別 repo へ「同 stage の commit」を行う場合その commit は gate を
  # 通らない (docs に明記の既知限界)。
  GUARD_PREFIX = "AGENT_TOOLS_GIT_HOOK_ACTIVE_"

  module_function

  def guard_key(stage)
    GUARD_PREFIX + stage.upcase.tr("-", "_")
  end

  # repo 自身の hooks directory。core.hooksPath を経由すると dispatcher 自身に戻って
  # しまうため、必ず common dir 直下の hooks/ を見る (worktree でも共有側が正、#201 実測)。
  def repo_hook_path(stage)
    out = IO.popen(%w[git rev-parse --git-common-dir], &:read)
    return nil unless $?.success?

    File.join(File.expand_path(out.chomp), "hooks", stage)
  end

  def run(argv)
    stage = argv[0]
    unless STAGE_GATES.key?(stage)
      warn "git-hook-dispatcher: unknown stage #{stage.inspect} " \
           "(expected: #{STAGE_GATES.keys.join(' / ')})"
      return 2
    end

    if ENV[guard_key(stage)] == "1"
      warn "git-hook-dispatcher: re-entrant #{stage} invocation detected; " \
           "skipping (loop guard, gates already ran)"
      return 0
    end

    args = argv[1..-1] || []
    own_dir = File.dirname(File.realpath(__FILE__))

    STAGE_GATES.fetch(stage).each do |gate|
      gate_path = File.join(own_dir, gate)
      unless File.executable?(gate_path)
        warn "git-hook-dispatcher: gate #{gate} is missing or not executable at #{gate_path}; " \
             "refusing to proceed (fail-closed). Re-run agent-tools sync."
        return 2
      end
      # Ruby は引数が 1 個だけの system / exec を単一 command 文字列として扱い、空白で
      # 分割するか metacharacter があれば /bin/sh に渡す。判定は引数の「個数」であって
      # 中身ではないので、args が空になる stage (pre-commit は引数ゼロ) では gate path が
      # そのまま shell 解釈される。[cmdname, argv0] の 2 要素配列形なら引数ゼロでも
      # shell に path を解釈させない (shebang 無し実行ファイルの ENOEXEC で /bin/sh に
      # 落ちる経路は残るが、その場合も path は script file 名の引数として渡され、
      # command 文字列として parse されない)。この冗長に見える形は #267 の回帰防止
      # なので単純化しない。
      started = system([gate_path, gate_path], *args)
      if started.nil?
        # spawn 自体の失敗 (executable? 確認後に gate が消えた / 実行不能になった TOCTOU)。
        # このとき $?.exitstatus は nil ではなく 127 なので、下の nil guard (signal 死) では
        # 拾えず契約外の 127 がそのまま返る。gate の finding ではなく構成エラーとして 2 に
        # 正規化する (#274)。gate 自身が返した exit code は等値で伝播する (gate 契約の責務)。
        warn "git-hook-dispatcher: gate #{gate} could not be started at #{gate_path}; " \
             "refusing to proceed (fail-closed)"
        return 2
      end
      status = $?.exitstatus
      return status.nil? ? 2 : status unless status == 0
    end

    chain = repo_hook_path(stage)
    if chain.nil?
      # chain 解決不能を黙って素通りさせない (repo hook の silent 迂回になる。H206-05)。
      warn "git-hook-dispatcher: cannot resolve git common dir; failing closed"
      return 2
    end
    if File.executable?(chain)
      # 直接 link の自己参照は即 skip (間接参照は上の再入 sentinel が止める)。
      if File.realpath(chain) == File.realpath(__FILE__)
        warn "git-hook-dispatcher: repo hook #{chain} resolves to the dispatcher itself; skipping chain"
        return 0
      end
      # 同上 (#267)。引数ゼロでも shell に path を解釈させないため [cmdname, argv0] 形で
      # 渡す。env Hash は exec の第 1 引数のままにする (配列形と併用するとき末尾に置くと
      # `ArgumentError: wrong exec option` で落ち、chain 自体が走らない。2.6.10 で実測)。
      # 配列に *args を畳み込まない。3 要素以上の配列は [cmdname, argv0] 形ではなくなり、
      # commit-msg stage (引数 1 個) の chain が壊れる。
      exec({ guard_key(stage) => "1" }, [chain, chain], *args)
    end
    0
  rescue StandardError => e
    # git 不在 (IO.popen の ENOENT) / chain 先の消失・実行 bit 喪失 (realpath / exec の
    # ENOENT・EACCES) など、途中で起きた例外を Ruby 既定の exit 1 + backtrace で抜けさせない
    # (#274)。原因は 1 行だけ出し、疑わしいときは commit を止める (fail-closed)。
    # SystemExit / Interrupt は StandardError ではないので従来どおり素通し。
    warn "git-hook-dispatcher: #{e.class}: #{e.message}; failing closed (exit 2)"
    2
  end
end

exit GitHookDispatcher.run(ARGV) if $PROGRAM_NAME == __FILE__
