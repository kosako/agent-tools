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
# frontmatter は 1 文書・明示の marker なし・重複 key なし (#427 の 4)。safe_load は最初の文書だけを返し、
# 重複 key は後勝ちなので、2 文書目の key と重複した name の先の値が allowlist と照合をすり抜けていた。
%w[directory markdown].each do |format|
  # `--- ` (末尾に空白) は閉じ marker の split (`^---\r?\n`) に当たらず、frontmatter の中で 2 文書目を始める
  check_case(format, "second-document",
             "---\nname: personal-frontmatter\ndescription: Public fixture\n--- \nallowed-tools: Read\n---\n\n# Fixture\n",
             %w[codex claude-code], "exactly one YAML document")
  check_case(format, "explicit-end",
             "---\nname: personal-frontmatter\ndescription: Public fixture\n...\n---\n\n# Fixture\n",
             %w[codex claude-code], "explicit document markers")
  # 先の値が別の identity、後の値が manifest name: safe_load の後勝ちでは照合を通っていた
  check_case(format, "duplicate-name",
             "---\nname: personal-other\nname: personal-frontmatter\ndescription: Public fixture\n---\n\n# Fixture\n",
             %w[codex claude-code], "duplicate key \"name\"")
  check_case(format, "duplicate-description",
             valid.sub("description: Public fixture", "description: Public fixture\ndescription: again"),
             %w[codex], "duplicate key \"description\"")
end
# tag の解決と merge key でも key は衝突する (#427 の 4、Codex review round 1)。
%w[directory markdown].each do |format|
  # `!!binary bmFtZQ==` は load 後に "name" になり、先の値を上書きする
  check_case(format, "tagged-key",
             "---\n!!binary bmFtZQ==: personal-other\nname: personal-frontmatter\ndescription: Public fixture\n---\n\n# Fixture\n",
             %w[codex claude-code], "explicit tags are not allowed")
  check_case(format, "omap",
             "---\n!!omap\n- name: personal-other\n- name: personal-frontmatter\n- description: Public fixture\n---\n\n# Fixture\n",
             %w[codex claude-code], "explicit tags are not allowed")
  check_case(format, "tagged-value",
             valid.sub("description: Public fixture", "description: !!str Public fixture"),
             %w[codex claude-code], "explicit tags are not allowed")
  check_case(format, "merge-key",
             "---\nname: personal-other\n<<: {name: personal-frontmatter}\ndescription: Public fixture\n---\n\n# Fixture\n",
             %w[codex claude-code], "merge keys (<<) are not allowed")
  # plain scalar の解決後の衝突 (`true` と `yes` は同じ key になる)
  check_case(format, "resolved-collision",
             valid.sub("description: Public fixture", "description: Public fixture\ntrue: a\nyes: b"),
             %w[codex claude-code], "collide after YAML resolution")
end
# 値の後の同じ行の YAML のコメントは拒む (#417)。引用符の無い値は空白の後の `#` で黙って切れ、配布先の一覧にも
# 切れたまま載る (personal-codex-worker の description が「packet #N」の手前で切れていた)。
comment = "a YAML comment follows the value"
%w[directory markdown].each do |format|
  check_case(format, "plain-trailing-comment",
             valid.sub("description: Public fixture", "description: 「packet #N を」委譲する"),
             %w[codex claude-code], comment)
  check_case(format, "quoted-trailing-comment",
             valid.sub("description: Public fixture", "description: \"Public fixture\" # note"),
             %w[codex claude-code], comment)
  check_case(format, "multiline-plain-comment",
             valid.sub("description: Public fixture", "description: Public\n  fixture #N here"),
             %w[codex claude-code], comment)
  check_case(format, "name-trailing-comment",
             valid.sub("name: personal-frontmatter", "name: personal-frontmatter # x"),
             %w[codex claude-code], comment)
  check_case(format, "crlf-trailing-comment",
             valid.sub("description: Public fixture", "description: Public #fixture").gsub("\n", "\r\n"),
             %w[codex claude-code], comment)
  # `#` を含んでも値を切らない形は通す: 引用符で囲んだ値、前に空白の無い `#`、block scalar の中の `#` の行、
  # 行全体のコメント
  check_case(format, "quoted-hash",
             valid.sub("description: Public fixture", "description: \"「packet #N を」委譲する\""),
             %w[codex claude-code], nil)
  check_case(format, "hash-without-space",
             valid.sub("description: Public fixture", "description: issue#417 fixture"),
             %w[codex claude-code], nil)
  check_case(format, "folded-hash",
             valid.sub("description: Public fixture", "description: >\n  # not a comment\n  Public fixture"),
             %w[codex claude-code], nil)
  check_case(format, "whole-line-comment",
             valid.sub("name: personal-frontmatter\n", "# a whole-line comment\nname: personal-frontmatter\n"),
             %w[codex claude-code], nil)
  # block scalar の終わりの位置は次の行の先頭になる。直後の行全体のコメントを、値の後ろのコメントと取り違えない
  # (Codex review round 1 の F1)。block の indicator の後のコメントも値を切らない。
  %w[> |].each do |indicator|
    check_case(format, "block-#{indicator}-then-whole-line-comment",
               "---\nname: personal-frontmatter\ndescription: #{indicator}\n  Public fixture\n# a whole-line comment\n---\n\n# Fixture\n",
               %w[codex claude-code], nil)
  end
  check_case(format, "block-header-comment",
             valid.sub("description: Public fixture", "description: > # header comment\n  Public fixture"),
             %w[codex claude-code], nil)
  # flow の collection の後のコメントと、block の collection の中の値の後のコメントも拒む (round 1 の F2)。
  # description の型を見ない Claude-only の skill で、コメントの検査が単独で当たることを確かめる。
  check_case(format, "flow-sequence-trailing-comment",
             valid.sub("description: Public fixture", "description: [Public fixture] # note"),
             %w[claude-code], comment)
  check_case(format, "flow-mapping-trailing-comment",
             valid.sub("description: Public fixture", "description: {text: Public fixture} # note"),
             %w[claude-code], comment)
  check_case(format, "block-sequence-item-comment",
             valid.sub("description: Public fixture", "description:\n  - Public #fixture"),
             %w[claude-code], comment)
  # flow の collection は中の値もたどる (round 2 の F3)。frontmatter 全体を flow の mapping で書き、中の plain な値が
  # コメントで切れる形を拒む。flow の sequence の中の要素も同じ。
  check_case(format, "flow-root-inner-comment",
             "---\n{\n  name: personal-frontmatter,\n  description: packet #N を委譲する\n}\n---\n\n# Fixture\n",
             %w[codex claude-code], comment)
  check_case(format, "flow-sequence-inner-comment",
             valid.sub("description: Public fixture", "description: [Public #fixture\n  , more]"),
             %w[claude-code], comment)
  # 空の値の後のコメント (値が `#` で始まり、値ごとコメントになる) も拒む (round 3 の F4)。flow の mapping では、空の
  # 値の終わりの位置が次の行の `}` を指すので、key の後ろを見る。コメントの無い空の値と、key の後のコメントに続く
  # block の値は通す。
  check_case(format, "flow-empty-value-comment",
             "---\n{name: personal-frontmatter,\n description: #N を委譲する\n}\n---\n\n# Fixture\n",
             %w[claude-code], comment)
  check_case(format, "block-empty-value-comment",
             valid.sub("description: Public fixture", "description: #N を委譲する"),
             %w[claude-code], comment)
  check_case(format, "quoted-empty-value-comment",
             valid.sub("description: Public fixture", "description: \"\" # note"),
             %w[claude-code], comment)
  # `:` が key と別の行にある明示の key と、anchor の後のコメント (round 4 の F5)
  check_case(format, "explicit-key-empty-value-comment",
             valid.sub("description: Public fixture", "? description\n: #N を委譲する"),
             %w[claude-code], comment)
  check_case(format, "anchor-then-comment",
             valid.sub("description: Public fixture", "description: &d #N を委譲する"),
             %w[claude-code], comment)
  # 明示の key の後のコメントは、引用符で囲んだ空の値を切らないので通す (空の plain な値とは区別する)
  check_case(format, "explicit-key-comment-quoted-empty",
             valid.sub("description: Public fixture", "? description # note\n: \"\""),
             %w[claude-code], nil)
  # 空の値の後の行全体のコメントは、値を切らないので通す
  check_case(format, "empty-value-then-whole-line-comment",
             "---\nname: personal-frontmatter\ndescription:\n# a whole-line comment\n---\n\n# Fixture\n",
             %w[claude-code], nil)
  # YAML が改行とみなす LF 以外の文字 (単独の CR・NEL・LS・PS) があると、行番号が食い違うので拒む (round 4 の F6)。
  # CRLF は通す (上の crlf の case)。
  ["\r", "\u0085", " ", " "].each_with_index do |br, i|
    check_case(format, "other-line-break-#{i}",
               "---\nname: personal-frontmatter#{br}description: packet #N を委譲する\n---\n\n# Fixture\n",
               %w[codex claude-code], "line break other than LF / CRLF")
  end
  check_case(format, "flow-empty-value",
             "---\n{name: personal-frontmatter, description: }\n---\n\n# Fixture\n",
             %w[claude-code], nil)
  check_case(format, "key-comment-then-block-value",
             valid.sub("description: Public fixture", "description: # note\n  - Public fixture"),
             %w[claude-code], nil)
  check_case(format, "block-sequence-then-whole-line-comment",
             valid.sub("description: Public fixture", "description:\n  - Public fixture\n# a whole-line comment"),
             %w[claude-code], nil)
end
# Psych の column は文字の単位。C locale で読んだ (US-ASCII の) 文字列でも、行を UTF-8 として切って当てる
# (byte の単位で切ると、日本語の後の ` #` を見落とす)。
require File.join(scripts, "lib/yaml_util")
ascii = lambda { |s| s.dup.force_encoding(Encoding::US_ASCII) }
begin
  YamlUtil.load_frontmatter(ascii.call("name: personal-frontmatter\ndescription: 日本語の「packet #N を」\n"), "fm")
  abort "FAIL: a trailing comment after a non-ASCII plain value read as US-ASCII must be rejected"
rescue YamlUtil::DocumentError => e
  abort "FAIL: the comment must be located by characters: #{e.message}" unless e.message.include?("line 2 column 26;")
end
YamlUtil.load_frontmatter(ascii.call("name: personal-frontmatter\ndescription: \"日本語の「packet #N を」\"\n"), "fm")
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
