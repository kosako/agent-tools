# frozen_string_literal: true

# sync / connect の main が共有する epilogue (#192): plan の表示 → conflict fail →
# apply / dry-run の集計行。require 時の副作用はない (status.rb が sync 経由で load する)。
module PlanReport
  # plans を表示し、conflict なら 1 / 正常なら 0 を返す (main がそのまま exit code に使う)。
  # change_actions は「変更として数える action」(sync: create/update/delete、
  # connect: create/add-import)。plans 空の分岐は文言が tool ごとに違うため main に残す。
  # notes は plan の行の後に出す行、applied_notes は apply の書き込みが終わった後に出す行 (sync の配備の報告。#688)。
  # どちらも conflict で止まるときと quiet のときは出さない。
  def self.finish(plans, runner, apply:, quiet:, change_actions:, notes: [], applied_notes: [])
    # 表示は tilde 表記に正規化する (docs/status-manifest-contract.md)。
    plans.each { |p| puts p.to_s.sub(Dir.home, "~") }

    conflicts = plans.select { |p| p.action == "conflict" }
    unless conflicts.empty?
      warn "fail: #{conflicts.size} conflict(s); nothing was applied"
      return 1
    end

    notes.each { |line| puts line } unless quiet
    changes = plans.count { |p| change_actions.include?(p.action) }
    if apply
      runner.apply(plans)
      applied_notes.each { |line| puts line } unless quiet
      puts "ok: applied #{changes} change(s)" unless quiet
    else
      puts "ok: dry-run only, #{changes} change(s) pending (use --apply to write)" unless quiet
    end
    0
  end
end
