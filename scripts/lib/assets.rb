# frozen_string_literal: true

require_relative "yaml_util"

# shared asset の discovery と load を 1 箇所に集約する。
# manifest glob / parse / 正規化を各 script で重複させない。
module Assets
  # sidecar manifest と directory manifest を sort して返す (絶対 path)。
  def self.manifest_paths(root)
    root = File.expand_path(root)
    (Dir.glob(File.join(root, "shared/**/*.asset.yml")) +
     Dir.glob(File.join(root, "shared/**/asset.yml"))).sort
  end

  # すべての asset を正規化した hash で返す。
  def self.load_all(root)
    root = File.expand_path(root)
    manifest_paths(root).map do |full|
      rel = full.sub(%r{\A#{Regexp.escape(root)}/}, "")
      from_manifest(YamlUtil.load(File.read(full), rel), rel)
    end
  end

  # name => source の hash。stale 判定で source を引くのに使う。
  def self.sources_by_name(root)
    load_all(root).each_with_object({}) do |a, map|
      next unless a[:name] && a[:source].is_a?(Hash)

      map[a[:name]] = a[:source]
    end
  end

  def self.from_manifest(data, rel)
    data = {} unless data.is_a?(Hash)
    {
      name: data["name"],
      kind: data["kind"],
      visibility: data["visibility"],
      targets: data["targets"],
      source: data["source"],
      compatibility: data["compatibility"],
      summary: data["summary"],
      description: data["description"],
      human_review: data.dig("review", "human_review"),
      declared_risks: (data["risk"] || {}).values,
      manifest_path: rel,
    }
  end
end
