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

  module_function

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
      warn "git-hook-dispatcher: cannot resolve git common dir; skipping repo-hook chain"
      return 0
    end
    if File.executable?(chain)
      # 誤設定で repo hook 自体が dispatcher (への link) だと無限 chain になるので識別して skip。
      if File.realpath(chain) == File.realpath(__FILE__)
        warn "git-hook-dispatcher: repo hook #{chain} resolves to the dispatcher itself; skipping chain"
        return 0
      end
      exec(chain, *args)
    end
    0
  end
end

exit GitHookDispatcher.run(ARGV) if $PROGRAM_NAME == __FILE__
