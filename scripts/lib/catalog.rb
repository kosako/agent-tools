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
  # JSON として壊れている・shape 不正・entry の必須項目の欠けや不正 (:unreadable) は entries を空にして返す
  # (fail-closed)。
  def self.read(root)
    path = File.join(root, ArtifactTargets::CATALOG_PATH)
    return Result.new(:missing, []) unless File.file?(path)

    data = JSON.parse(File.read(path))
    # 型不正な catalog を fail-closed で弾く (#179 M-06)。top-level が object でないと
    # data["catalog_version"] 参照自体が TypeError になり JSON::ParserError の rescue を
    # 抜けてしまうため、まず shape を検証する。assets も entry も、下流が Hash#[] を
    # 前提に読む (target / name / build_id) ので Array of Hash を要求し、entry の項目も確かめる (valid_entry?)。
    return Result.new(:unreadable, []) unless data.is_a?(Hash)
    return Result.new(:version_mismatch, []) unless data["catalog_version"] == ArtifactTargets::CATALOG_VERSION

    assets = data.fetch("assets", [])
    return Result.new(:unreadable, []) unless assets.is_a?(Array) && assets.all? { |entry| valid_entry?(entry) }

    Result.new(:ok, assets)
  rescue JSON::ParserError
    Result.new(:unreadable, [])
  end

  # register が書く registration の値 (docs/register-catalog.md の `registration`)。
  REGISTRATIONS = %w[registered human_review_required unsupported].freeze

  # 下流 (sync の plan / status / doctor / connect) が前提に読む項目の型と値 (#515)。ここで弾かないと、例えば target が
  # 無い registered の entry で sync の配置先の解決が KeyError になり、status / doctor も契約の出力を返せない。
  # name と manifest_path は path の組み立てに入るので、name は manifest と同じ形 (NAME_PATTERN)、manifest_path は
  # NUL を含まない文字列に限る (NUL は File.join / File.read が ArgumentError で止まる。#521 review)。personal- の接頭辞は
  # 今どおり sync の conflict が扱う。artifact_kind は register が対応外の kind (unsupported) も書くので、既知の値に
  # 限らず文字列であることだけを見る。
  def self.valid_entry?(entry)
    return false unless entry.is_a?(Hash)
    return false unless entry["name"].is_a?(String) && entry["name"].match?(ArtifactTargets::NAME_PATTERN)
    return false unless ArtifactTargets::TOOLS.include?(entry["target"])
    return false unless entry["artifact_kind"].is_a?(String)
    return false unless REGISTRATIONS.include?(entry["registration"])
    return false unless entry["manifest_path"].is_a?(String) && !entry["manifest_path"].include?("\0")

    entry["registration"] != "registered" || entry["build_id"].is_a?(String)
  end
  private_class_method :valid_entry?
end
