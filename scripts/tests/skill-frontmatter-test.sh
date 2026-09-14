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

native_fields = [
  "allowed-tools: Bash(*)",
  "allowed-tools: [Read, Grep]",
  "allowed-tools: null",
  "'allowed-tools': Read",
  "hooks:\n  PreToolUse:\n    - matcher: Read\n      hooks:\n        - type: command\n          command: printf fixture",
  "hooks: {}",
]
dynamic_commands = [
  "!`printf fixture`\n",
  "Context: !`printf fixture`\n",
  "\t!`printf fixture`\n",
  "\u00A0!`printf fixture`\n",
  "```!\nprintf fixture\n```\n",
  "```!\r\nprintf fixture\r\n```\r\n",
  "```!printf fixture```\n",
  "  ```!\nprintf fixture\n  ```\n",
  "```markdown\n!`printf fixture`\n```\n",
  "!`printf fixture\nprintf fixture`\n",
]
%w[directory markdown].each do |format|
  native_fields.each do |field|
    content = valid.sub("description: Public fixture", "description: Public fixture\n#{field}")
    check_case(format, field, content, %w[codex claude-code], "unsupported Claude Code skill feature")
    check_case(format, "codex-only-#{field}", content, %w[codex], nil)
  end
  dynamic_commands.each do |body|
    check_case(format, "dynamic-command", valid + body, %w[codex claude-code], "unsupported Claude Code skill feature")
    check_case(format, "codex-only-dynamic", valid + body, %w[codex], nil)
    check_case(format, "no-frontmatter-dynamic", body, %w[claude-code], "unsupported Claude Code skill feature")
  end
  ["KEY=!`printf fixture`\n", "escaped \\!`printf fixture`\n",
   "```!\nprintf fixture\n",
   "prefix\u0085!`printf fixture`\n",
   "literal: `example !`printf fixture`\n", "``!`printf fixture` ``\n",
   "!`   `\n", "```!\n \t\n```\n",
   "Use allowed-tools and hooks only after review.\n",
   "```yaml\nallowed-tools: Read\nhooks: {}\n```\n",
   "```sh\nprintf fixture\n```\n"].each do |body|
    check_case(format, "literal-example", valid + body, %w[codex claude-code], nil)
  end
  content = valid.sub("description: Public fixture", "description: Public fixture\nmetadata:\n  hooks: example\n  allowed-tools: example")
  check_case(format, "nested-metadata", content, %w[codex claude-code], nil)
end
check_case("markdown", "claude-instruction", valid + dynamic_commands.first, %w[codex claude-code], nil,
           { "claude-code" => { "artifact_kind" => "instruction" } })

# refs / evals に書いた説明は host が skill 本文として実行する入口ではない。
Dir.mktmpdir("skill-native-references-") do |root|
  fixture(root, "directory", valid, %w[codex claude-code])
  %w[references evals].each do |subdir|
    dir = File.join(root, "shared/skills/personal-frontmatter", subdir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "example.md"), "---\nallowed-tools: Read\nhooks: {}\n---\n#{dynamic_commands.join}")
  end
  _, errors = CheckManifests::Runner.new(root).run
  abort "FAIL: reference example treated as entrypoint: #{errors.inspect}" unless errors.empty?
end

# native 機能は未対応なので、content-bound 承認があっても build / register は拒否する。
require File.join(scripts, "lib/build")
%w[directory markdown].each do |format|
  [valid.sub("description: Public fixture", "description: Public fixture\nallowed-tools: Read"),
   valid.sub("description: Public fixture", "description: Public fixture\nhooks: {}"),
   valid + dynamic_commands.first, valid + dynamic_commands[4], dynamic_commands.first].each do |content|
    Dir.mktmpdir("skill-native-gate-") do |root|
      fixture(root, format, content, %w[claude-code])
      source = format == "directory" ? "shared/skills/personal-frontmatter" : "shared/skills/personal-frontmatter.md"
      manifest = format == "directory" ? "#{source}/asset.yml" : "shared/skills/personal-frontmatter.asset.yml"
      path = File.join(root, manifest)
      data = YamlUtil.load(File.read(path), manifest)
      data["review"] = {
        "human_review" => "approved", "approved_artifact_kind" => "skill",
        "approved_build_id" => Build.build_id_for(root, source, format),
      }
      File.write(path, YAML.dump(data))
      %w[build register].each do |stage|
        output, status = Open3.capture2e(File.join(scripts, "#{stage}.sh"), "--root", root)
        unless status.exitstatus == 1 && output.include?("unsupported Claude Code skill feature")
          abort "FAIL: #{stage}/#{format} accepted native feature: #{output}"
        end
      end
      abort "FAIL: native skill reached generated/" if File.exist?(File.join(root, "generated"))
    end
  end
end

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
