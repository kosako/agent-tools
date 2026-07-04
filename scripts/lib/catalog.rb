# frozen_string_literal: true

require "json"

require_relative "artifact_targets"

# generated/catalog.json の共有 reader。register が書き、sync / connect / status /
# doctor が読む。parse + catalog_version 照合の 4 重実装を 1 箇所に集約する (#152)。
#
# 消費者ごとに「読めない理由」の扱いが違う (doctor は 3 段階で報告、sync / status は
# 不在扱い) ため、理由を潰さず state で返す。
module Catalog
  # 読み取り結果。state は :ok / :missing / :version_mismatch / :unreadable のいずれか。
  # entries は :ok のときだけ catalog の target-artifact entry 配列、それ以外は空。
  Result = Struct.new(:state, :entries) do
    def present?
      state == :ok
    end
  end

  # catalog を読む。存在しない (:missing) / catalog_version 不一致 (:version_mismatch) /
  # JSON として壊れている (:unreadable) は entries を空にして返す (fail-closed)。
  def self.read(root)
    path = File.join(root, ArtifactTargets::CATALOG_PATH)
    return Result.new(:missing, []) unless File.file?(path)

    data = JSON.parse(File.read(path))
    return Result.new(:version_mismatch, []) unless data["catalog_version"] == ArtifactTargets::CATALOG_VERSION

    Result.new(:ok, data.fetch("assets", []))
  rescue JSON::ParserError
    Result.new(:unreadable, [])
  end
end
