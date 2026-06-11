# frozen_string_literal: true

require "yaml"

# psych 3 (positional args) と psych 4 (keyword args) の両方で動く safe_load。
module YamlUtil
  def self.load(content, path)
    if Psych::VERSION.split(".").first.to_i >= 4
      YAML.safe_load(content, filename: path)
    else
      YAML.safe_load(content, [], [], false, path)
    end
  end
end
