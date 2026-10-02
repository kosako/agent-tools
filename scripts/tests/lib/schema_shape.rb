# JSON schema の形を、期待する key と型の木 (shape) と比べる test 用の helper (#347)。
# Codex の --output-schema に渡す schema が、strict な structured output の前提 (どの object も
# additionalProperties: false で、全 key が required) を満たし、consumer が読む形と一致するかを確かめる。
#
# shape の書き方: object は key => 子の shape の Hash、array は [要素の shape]、葉は型の名前 ("string" など)。
module SchemaShape
  module_function

  # 違反を文字列の配列で返す (空なら一致)。
  def check(node, shape, path = "$", errors = [])
    unless node.is_a?(Hash)
      errors << "#{path}: schema の node が object でない"
      return errors
    end
    case shape
    when Hash
      errors << "#{path}: type が object でない (#{node["type"].inspect})" unless node["type"] == "object"
      errors << "#{path}: additionalProperties が false でない" unless node["additionalProperties"] == false
      props = node["properties"].is_a?(Hash) ? node["properties"] : {}
      unless props.keys.sort == shape.keys.sort
        errors << "#{path}: properties #{props.keys.sort} が期待 #{shape.keys.sort} と一致しない"
      end
      req = node["required"].is_a?(Array) ? node["required"].sort : []
      errors << "#{path}: required #{req} が properties #{props.keys.sort} と一致しない" unless req == props.keys.sort
      shape.each { |k, sub| check(props[k], sub, "#{path}.#{k}", errors) if props.key?(k) }
    when Array
      errors << "#{path}: type が array でない (#{node["type"].inspect})" unless node["type"] == "array"
      check(node["items"], shape.first, "#{path}[]", errors)
    else
      errors << "#{path}: type が #{shape} でない (#{node["type"].inspect})" unless node["type"] == shape
    end
    errors
  end

  # REPORT-FORMAT.md の「所見の欄」の表から、欄の値の集合を読む (2 列目を " / " で分ける)。行が無ければ nil。
  def table_values(markdown, label)
    row = markdown.lines.find { |l| l.start_with?("| #{label} |") }
    return nil unless row
    row.split("|")[2].strip.split(" / ").map(&:strip)
  end
end
