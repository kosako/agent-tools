# frozen_string_literal: true

require "digest"

require_relative "yaml_util"

# shared asset の discovery と load を 1 箇所に集約する。
# manifest glob / parse / 正規化を各 script で重複させない。
module Assets
  # manifest file bytes の SHA256。register が catalog に記録し、reader が現在の
  # manifest と照合して「登録判断 (risk / review / targets) が古い catalog」を検出する
  # (docs/register-catalog.md)。register と読む側で計算が割れないようここに一元化する。
  def self.manifest_digest(root, manifest_rel)
    Digest::SHA256.hexdigest(File.read(File.join(File.expand_path(root), manifest_rel)))
  end

  # catalog entry の manifest_digest が現在の manifest と一致するか。manifest の欠落・
  # 読めない・digest 未記録 (旧 catalog) はすべて false = fail-closed。
  # 配置系 reader (sync / connect) と doctor で判定を共有する (#148)。
  def self.manifest_fresh?(root, entry)
    path = entry["manifest_path"]
    return false unless path.is_a?(String)

    entry["manifest_digest"] == manifest_digest(root, path)
  rescue SystemCallError, IOError
    false
  end
  # 絶対 path を root 相対に変換する (root prefix のみ剥がす)。root は File.expand_path
  # 済みであることが前提 (呼び出し側の責務。生の相対 root を渡すと prefix が一致せず
  # 絶対 path のまま返る)。build / check-manifests / check-injection の表示 path と
  # manifest_path の正規化が共有する (#192)。
  def self.rel(root, path)
    path.sub(%r{\A#{Regexp.escape(root)}/}, "")
  end

  # sidecar manifest と directory manifest を sort して返す (絶対 path)。
  # glob は `foo.asset.yml` という名前の directory にもマッチしうるため、File.read で
  # EISDIR を踏まないよう file だけに絞る (directory manifest は File.file? で残る)。
  def self.manifest_paths(root)
    root = File.expand_path(root)
    (Dir.glob(File.join(root, "shared/**/*.asset.yml")) +
     Dir.glob(File.join(root, "shared/**/asset.yml")))
      .select { |p| File.file?(p) }
      .sort
  end

  # すべての asset を正規化した hash で返す。
  def self.load_all(root)
    root = File.expand_path(root)
    manifest_paths(root).map do |full|
      rel = Assets.rel(root, full)
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
      # parse 可能だが型不正な manifest (scalar の review / risk) でも落ちないよう、
      # Hash でなければ nil / [] に正規化する (検証は check-manifests が担う)。
      human_review: data["review"].is_a?(Hash) ? data["review"]["human_review"] : nil,
      approved_build_id: data["review"].is_a?(Hash) ? data["review"]["approved_build_id"] : nil,
      approved_artifact_kind: data["review"].is_a?(Hash) ? data["review"]["approved_artifact_kind"] : nil,
      declared_risks: data["risk"].is_a?(Hash) ? data["risk"].values : [],
      manifest_path: rel,
    }
  end
  private_class_method :from_manifest
end
