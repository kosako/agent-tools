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
# block / 2 = usage・構成エラー (未知 stage・gate 欠損・git 情報取得失敗)。chain 先が
# ある場合は exec で置き換わるため chain 先の exit code がそのまま返る。

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
      system(gate_path, *args)
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
      exec({ guard_key(stage) => "1" }, chain, *args)
    end
    0
  end
end

exit GitHookDispatcher.run(ARGV) if $PROGRAM_NAME == __FILE__
