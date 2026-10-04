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
# 単一 file の skill も directory と同じ規則 (build は frontmatter を生成しない、#376)。
%w[directory markdown].each do |format|
  check_case(format, "codex-frontmatter-required", "# Fixture\n", %w[codex], "must contain YAML frontmatter")
  check_case(format, "codex-and-claude-frontmatter-required", "# Fixture\n", %w[codex claude-code], "must contain YAML frontmatter")
  check_case(format, "claude-frontmatter-optional", "# Fixture\n", %w[claude-code], nil)
end
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
    key = field[/\A'?([a-z-]+)/, 1]
    check_case(format, field, content, %w[codex claude-code], "unsupported Claude Code skill feature: #{key} ")
    # Claude 固有の診断は Claude Code に配るときだけ。Codex のみでも frontmatter の allowlist で拒否する (#217)。
    check_case(format, "codex-only-#{field}", content, %w[codex], "unsupported skill frontmatter key: #{key.inspect}")
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
  # metadata の中の同名 key は Claude の native 機能ではないが、metadata 自体が allowlist の外 (#217)。
  content = valid.sub("description: Public fixture", "description: Public fixture\nmetadata:\n  hooks: example\n  allowed-tools: example")
  check_case(format, "nested-metadata", content, %w[codex claude-code], "unsupported skill frontmatter key: \"metadata\"")
end
check_case("markdown", "claude-instruction", valid + dynamic_commands.first, %w[codex claude-code], nil,
           { "claude-code" => { "artifact_kind" => "instruction" } })

# shared の skill source は target metadata を所有しない。frontmatter の key は name と description だけを許し、
# それ以外は target によらず拒否して、どの key かを診断に出す (#217)。
target_metadata_fields = [
  ["model", "model: fable"],
  ["context", "context: fork"],
  ["disable-model-invocation", "disable-model-invocation: true"],
  ["x-unknown", "x-unknown: value"],
  ["Description", "Description: Public fixture"],
  [42, "42: numeric"],
  [nil, "~: null-key"],
]
%w[directory markdown].each do |format|
  target_metadata_fields.each do |key, field|
    content = valid.sub("description: Public fixture", "description: Public fixture\n#{field}")
    [%w[codex claude-code], %w[codex], %w[claude-code]].each do |targets|
      check_case(format, "target-metadata-#{key.inspect}-#{targets.join('+')}", content, targets,
                 "unsupported skill frontmatter key: #{key.inspect} ")
    end
  end
  check_case(format, "target-metadata-without-name", "---\nmodel: fable\n---\n", %w[claude-code],
             "unsupported skill frontmatter key: \"model\" ")
end
# Claude Code に配る allowed-tools は #233 の診断で 1 度だけ報告し、allowlist の診断と二重にしない。
Dir.mktmpdir("skill-native-single-") do |root|
  fixture(root, "directory", valid.sub("description: Public fixture", "description: Public fixture\nallowed-tools: Read"),
          %w[codex claude-code])
  _, errors = CheckManifests::Runner.new(root).run
  abort "FAIL: allowed-tools must be reported once: #{errors.inspect}" unless errors.size == 1
end

# directory skill の top-level の agents/ (Codex の agents/openai.yaml 等) も target metadata なので、
# target によらず拒否する。大文字小文字だけが違う名前も同じ扱い (#217)。
[%w[codex claude-code], %w[codex], %w[claude-code]].each do |targets|
  %w[agents Agents].each do |dirname|
    Dir.mktmpdir("skill-target-metadata-dir-") do |root|
      fixture(root, "directory", valid, targets)
      dir = File.join(root, "shared/skills/personal-frontmatter", dirname)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "openai.yaml"), "policy:\n  allow_implicit_invocation: false\n")
      _, errors = CheckManifests::Runner.new(root).run
      expected = "shared/skills/personal-frontmatter/#{dirname}/: unsupported skill target metadata directory"
      abort "FAIL: #{dirname}/ accepted for #{targets.join('+')}: #{errors.inspect}" unless errors.any? { |e| e.include?(expected) }
    end
    # 拒否するのは directory だけ。同名の通常の file は target metadata の dir ではないので通す。
    %w[agents Agents].each do |filename|
      Dir.mktmpdir("skill-target-metadata-file-") do |root|
        fixture(root, "directory", valid, targets)
        File.write(File.join(root, "shared/skills/personal-frontmatter", filename), "policy: example\n")
        _, errors = CheckManifests::Runner.new(root).run
        abort "FAIL: regular file #{filename} rejected for #{targets.join('+')}: #{errors.inspect}" unless errors.empty?
      end
    end
  end
end
# host が metadata として読むのは skill root 直下の agents/ だけ。references / evals の下は対象外。
Dir.mktmpdir("skill-target-metadata-nested-") do |root|
  fixture(root, "directory", valid, %w[codex claude-code])
  %w[references/agents evals/agents].each do |sub|
    dir = File.join(root, "shared/skills/personal-frontmatter", sub)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "openai.yaml"), "policy:\n  allow_implicit_invocation: false\n")
  end
  _, errors = CheckManifests::Runner.new(root).run
  abort "FAIL: nested agents/ treated as target metadata: #{errors.inspect}" unless errors.empty?
end

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

# native 機能と target metadata は未対応なので、content-bound 承認があっても build / register は拒否する。
require File.join(scripts, "lib/build")
native = "unsupported Claude Code skill feature"
%w[directory markdown].each do |format|
  gate_cases = [valid.sub("description: Public fixture", "description: Public fixture\nallowed-tools: Read"),
                valid.sub("description: Public fixture", "description: Public fixture\nhooks: {}"),
                valid + dynamic_commands.first, valid + dynamic_commands[4], dynamic_commands.first].map { |c| [c, native, nil] }
  gate_cases << [valid.sub("description: Public fixture", "description: Public fixture\nmodel: fable"),
                 "unsupported skill frontmatter key: \"model\"", nil]
  gate_cases << [valid, "unsupported skill target metadata directory", "agents"] if format == "directory"
  gate_cases.each do |content, expected, metadata_dir|
    Dir.mktmpdir("skill-native-gate-") do |root|
      fixture(root, format, content, %w[claude-code])
      if metadata_dir
        dir = File.join(root, "shared/skills/personal-frontmatter", metadata_dir)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "openai.yaml"), "policy:\n  allow_implicit_invocation: false\n")
      end
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
        unless status.exitstatus == 1 && output.include?(expected)
          abort "FAIL: #{stage}/#{format} accepted unsupported skill content (#{expected}): #{output}"
        end
      end
      abort "FAIL: unsupported skill reached generated/" if File.exist?(File.join(root, "generated"))
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

# 単一 file の skill の source は byte のまま配る。frontmatter を生成しないので、manifest の summary は配る内容に
# 入らず、承認した bytes (build_id の対象) と配る bytes が一致する (#376)。Codex 向けで frontmatter が無ければ
# build も register も止まり、generated/ に届かない。
Dir.mktmpdir("skill-frontmatter-no-generation-") do |root|
  fixture(root, "markdown", "# Fixture\n", %w[codex claude-code])
  %w[build register].each do |stage|
    output, status = Open3.capture2e(File.join(scripts, "#{stage}.sh"), "--root", root)
    abort "FAIL: #{stage} accepted a Codex skill without frontmatter: #{output}" if status.success?
    abort "FAIL: #{stage} should name the missing frontmatter: #{output}" unless output.include?("must contain YAML frontmatter")
  end
  abort "FAIL: rejected skill reached generated/" if Dir.exist?(File.join(root, "generated", "codex", "skills"))
end
Dir.mktmpdir("skill-frontmatter-claude-as-is-") do |root|
  fixture(root, "markdown", "# Fixture\n", %w[claude-code])
  %w[build register].each do |stage|
    output, status = Open3.capture2e(File.join(scripts, "#{stage}.sh"), "--root", root)
    abort "FAIL: #{stage} rejected a Claude-only skill without frontmatter: #{output}" unless status.success?
  end
  content = File.binread(File.join(root, "generated/claude-code/skills/personal-frontmatter/SKILL.md"))
  abort "FAIL: Claude-only source must be deployed as-is: #{content.inspect}" unless content == "# Fixture\n"
end
Dir.mktmpdir("skill-frontmatter-bytes-") do |root|
  fixture(root, "markdown", valid, %w[codex claude-code])
  deployed = lambda do
    output, status = Open3.capture2e(File.join(scripts, "build.sh"), "--root", root)
    abort "FAIL: build rejected a valid skill: #{output}" unless status.success?
    %w[codex claude-code].map { |t| File.binread(File.join(root, "generated", t, "skills/personal-frontmatter/SKILL.md")) }
  end
  abort "FAIL: deployed bytes differ from the source" unless deployed.call.all? { |c| c == valid }
  manifest = File.join(root, "shared/skills/personal-frontmatter.asset.yml")
  File.write(manifest, File.read(manifest).sub("Generated fixture description", "Changed summary"))
  abort "FAIL: manifest summary leaked into the deployed bytes" unless deployed.call.all? { |c| c == valid }
  output, status = Open3.capture2e(File.join(scripts, "register.sh"), "--root", root)
  abort "FAIL: valid skill not registered: #{output}" unless status.success?
end
puts "ok: skill frontmatter self-test passed"
RUBY
