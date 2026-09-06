#!/bin/sh
# generated skill の target 別 frontmatter 契約を pipeline の入口で検証する。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ruby - "$script_dir/.." <<'RUBY'
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "open3"

scripts = File.expand_path(ARGV.fetch(0))
require File.join(scripts, "lib/check_manifests")

def fixture(root, format, content, targets, compatibility = nil)
  name = "personal-frontmatter"
  source = format == "directory" ? "shared/skills/#{name}" : "shared/skills/#{name}.md"
  entry = format == "directory" ? "#{source}/SKILL.md" : source
  manifest = format == "directory" ? "#{source}/asset.yml" : "shared/skills/#{name}.asset.yml"
  FileUtils.mkdir_p(File.dirname(File.join(root, entry)))
  File.write(File.join(root, entry), content)
  data = {
    "schema_version" => 1, "name" => name, "kind" => "skill", "visibility" => "public",
    "targets" => targets, "risk" => { "prompt_injection" => "low", "privacy" => "low" },
    "source" => { "path" => source, "format" => format }, "summary" => "Generated fixture description",
  }
  data["compatibility"] = compatibility if compatibility
  File.write(File.join(root, manifest), YAML.dump(data))
end

def check_case(format, label, content, targets, expected_error, compatibility = nil)
  Dir.mktmpdir("skill-frontmatter-") do |root|
    fixture(root, format, content, targets, compatibility)
    _, errors = CheckManifests::Runner.new(root).run
    entry = format == "directory" ? "shared/skills/personal-frontmatter/SKILL.md" : "shared/skills/personal-frontmatter.md"
    valid = expected_error ? errors.any? { |e| e.include?(expected_error) && e.include?(entry) } : errors.empty?
    abort "FAIL: #{format}/#{label}: #{errors.inspect}" unless valid
  end
end

valid = "---\nname: personal-frontmatter\ndescription: Public fixture\n---\n\n# Fixture\n"
missing_description = "---\nname: personal-frontmatter\n---\n\n# Fixture\n"
%w[directory markdown].each do |format|
  check_case(format, "valid", valid, %w[codex claude-code], nil)
  check_case(format, "crlf", valid.gsub("\n", "\r\n"), %w[codex], nil)
  check_case(format, "missing-description", missing_description, %w[codex], "non-empty string description")
  check_case(format, "claude-description-optional", missing_description, %w[claude-code], nil)
  ["''", "'   '", "null", "42", "[]", "{}"].each do |value|
    content = valid.sub("description: Public fixture", "description: #{value}")
    check_case(format, "description-#{value}", content, %w[codex], "non-empty string description")
  end
  check_case(format, "missing-name", valid.sub("name: personal-frontmatter\n", ""), %w[codex], "non-empty string name")
  check_case(format, "name-type", valid.sub("name: personal-frontmatter", "name: []"), %w[codex], "non-empty string name")
  check_case(format, "identity", valid.sub("name: personal-frontmatter", "name: personal-other"), %w[claude-code], "does not match manifest name")
  check_case(format, "closing-marker", "---\nname: personal-frontmatter\n", %w[codex], "closing --- marker")
  check_case(format, "yaml", "---\nname: [\n---\n", %w[codex], "YAML error")
  check_case(format, "mapping", "---\n- item\n---\n", %w[codex], "YAML mapping")
  check_case(format, "alias", "---\nname: &name personal-frontmatter\ndescription: *name\n---\n", %w[codex], "YAML error")
end
check_case("directory", "codex-frontmatter-required", "# Fixture\n", %w[codex], "must contain YAML frontmatter")
check_case("directory", "claude-frontmatter-optional", "# Fixture\n", %w[claude-code], nil)
check_case("markdown", "codex-instruction", missing_description, %w[codex claude-code], nil,
           { "codex" => { "artifact_kind" => "instruction" } })

# build と register は同じ gate を使い、必須 metadata の欠落を登録・生成前に拒否する。
%w[directory markdown].each do |format|
  Dir.mktmpdir("skill-frontmatter-gate-") do |root|
    fixture(root, format, missing_description, %w[codex claude-code])
    %w[build register].each do |stage|
      output, status = Open3.capture2e(File.join(scripts, "#{stage}.sh"), "--root", root)
      abort "FAIL: #{stage}/#{format} accepted missing description: #{output}" unless status.exitstatus == 1
    end
    abort "FAIL: invalid skill reached generated/" if File.exist?(File.join(root, "generated"))
  end
end

# source の拒否より先に symlink の中身を frontmatter として読み込まない。
Dir.mktmpdir("skill-frontmatter-source-") do |root|
  fixture(root, "markdown", valid, %w[codex])
  source = File.join(root, "shared/skills/personal-frontmatter.md")
  File.rename(source, File.join(root, "outside.md"))
  File.write(File.join(root, "outside.md"), "---\nname: [\n---\n")
  File.symlink("../../outside.md", source)
  _, errors = CheckManifests::Runner.new(root).run
  abort "FAIL: source symlink accepted" unless errors.any? { |e| e.include?("must not be a symlink") }
  abort "FAIL: rejected source was parsed" if errors.any? { |e| e.include?("frontmatter has a YAML error") }
end

# frontmatter を持たない単一 source は既存の adapter 補完で有効になる。
Dir.mktmpdir("skill-frontmatter-generated-") do |root|
  fixture(root, "markdown", "# Fixture\n", %w[codex claude-code])
  %w[build register].each do |stage|
    output, status = Open3.capture2e(File.join(scripts, "#{stage}.sh"), "--root", root)
    abort "FAIL: #{stage} rejected generated frontmatter: #{output}" unless status.success?
  end
  %w[codex claude-code].each do |target|
    content = File.read(File.join(root, "generated", target, "skills/personal-frontmatter/SKILL.md"))
    fm = YamlUtil.load(content.split(/^---\n/, 3)[1], "generated SKILL.md")
    abort "FAIL: generated metadata differs" unless fm == {
      "name" => "personal-frontmatter", "description" => "Generated fixture description",
    }
  end
  catalog = JSON.parse(File.read(File.join(root, "generated/catalog.json")))
  abort "FAIL: valid skill not registered" unless catalog.fetch("assets").all? { |a| a["registration"] == "registered" }
end
puts "ok: skill frontmatter self-test passed"
RUBY
