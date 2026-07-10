# frozen_string_literal: true

require "yaml"

require_relative "yaml_util"

# agent-tools の YAML 管理 marker (skill の dir 直下 / script の sidecar) の format 知識を
# 1 箇所に集約する (instruction の HTML コメント marker = InstructionMarker と対称, #192)。
# build (生成)・sync (所有判定)・status (鮮度判定) が同じ生成・読取・判定を共有する。
# marker format の正本は docs/status-manifest-contract.md。
module YamlMarker
  # marker 本文。directory marker (skill) と sidecar marker (script) が共有する。
  # キー順 (repo/name/target/source/build_id) は配備済み marker との byte 一致に効くため
  # 変えない。
  def self.render(name:, target:, source:, build_id:)
    YAML.dump(
      "repo" => "agent-tools",
      "name" => name,
      "target" => target,
      "source" => source,
      "build_id" => build_id,
    )
  end

  # marker file を読む。不在 / 非 mapping / YAML parse 失敗はすべて nil。
  # nil をどう扱うか (unmanaged / conflict / stale) は呼び出し側の fail-closed 判定に委ねる。
  def self.read_file(path)
    return nil unless File.file?(path)

    data = YamlUtil.load(File.read(path), path)
    data.is_a?(Hash) ? data : nil
  rescue Psych::Exception
    nil
  end

  # marker が agent-tools 管理で tool / name に一致するか (marker-gated 判定)。
  def self.managed?(marker, tool, name)
    marker &&
      marker["repo"] == "agent-tools" &&
      marker["target"] == tool &&
      marker["name"] == name
  end
end
