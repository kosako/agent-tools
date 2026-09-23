# frozen_string_literal: true

require_relative "assets"
require_relative "check_manifests"
require_relative "check_injection"

# 安全判定の source of truth。build と register が共有する致命 gate。
# ここを通った asset だけが生成・登録に進んでよい。
module Gate
  # pass なら []、fail なら human-readable な error message の配列を返す。
  # 致命 = shared/ の無い root / manifest validation error / injection high /
  #        宣言 risk high / human_review: rejected。
  def self.fatal_errors(root)
    root = File.expand_path(root)

    # shared/ の無い root は agent-tools の repo ではない。0 件のまま生成・登録に進むと、
    # 空の generated/ と catalog で正しい状態を上書きするので、ここで止める (#305)。
    unless File.directory?(File.join(root, "shared"))
      return ["no shared/ directory under root: #{root} (not an agent-tools repository; check --root)"]
    end

    _, manifest_errors = CheckManifests::Runner.new(root).run
    # manifest が壊れていると以降の判定が不正確なので、ここで打ち切る。
    return manifest_errors + ["manifest validation failed"] unless manifest_errors.empty?

    errors = []
    findings = CheckInjection::Runner.new(root).run.last
    findings.select { |f| f.risk == "high" }.each { |f| errors << "high risk finding: #{f}" }

    assets = Assets.load_all(root)
    rejected = assets.select { |a| a[:human_review] == "rejected" }.map { |a| a[:name] }
    errors << "rejected asset(s) still present: #{rejected.join(', ')}" unless rejected.empty?

    declared_high = assets.select { |a| a[:declared_risks].include?("high") }.map { |a| a[:name] }
    errors << "declared high risk asset(s): #{declared_high.join(', ')}" unless declared_high.empty?

    errors
  end
end
