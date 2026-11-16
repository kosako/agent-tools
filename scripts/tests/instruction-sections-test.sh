#!/bin/sh
# 節の分け方の 2 つの写しが同じ本文であることの self-test (#688)。sync の配備の報告が使う
# scripts/lib/instruction_sections.rb (InstructionSections) と、配備する hook の中の
# InstructionUpdateNotice::Sections は、module の本文を一字一句同じに保つ (hook は単独で配備されるので scripts/lib を
# require できず、scripts/ は shared/ の特定の asset を require できない)。挙動の test は、hook の側の
# scripts/tests/instruction-update-notice-test.sh にある。network access なし。何も書かない。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
lib="$repo_root/scripts/lib/instruction_sections.rb"
hook="$repo_root/shared/scripts/personal-instruction-update-notice.rb"

[ -f "$lib" ] || fail "missing $lib"
[ -f "$hook" ] || fail "missing $hook"

ruby -r"$script_dir/lib/check_helper" - "$lib" "$hook" "$repo_root" <<'RUBY'
lib, hook, repo_root = ARGV

# file の中の、opening の行から、同じ字下げの end の行までの間 (module の本文) を、字下げを外して返す。
def module_body(file, opening)
  lines = File.readlines(file, encoding: "UTF-8")
  start = lines.index(opening)
  return nil if start.nil?

  indent = opening[/\A */]
  stop = ((start + 1)...lines.size).find { |i| lines[i] == "#{indent}end\n" }
  return nil if stop.nil?

  lines[(start + 1)...stop].map { |line| line == "\n" ? line : line.sub(/\A#{indent}/, "") }.join
end

lib_body = module_body(lib, "module InstructionSections\n")
hook_body = module_body(hook, "  module Sections\n")
check("lib の module の本文を取り出せる", !lib_body.nil? && lib_body.include?("def digests(content)"))
check("hook の module の本文を取り出せる", !hook_body.nil? && hook_body.include?("def digests(content)"))
check("2 つの module の本文は一字一句同じ (直すときは両方を直す)", lib_body == hook_body)
unless lib_body == hook_body || lib_body.nil? || hook_body.nil?
  a = lib_body.lines
  b = hook_body.lines
  i = (0...[a.size, b.size].max).find { |n| a[n] != b[n] }
  warn "  最初に違う行 (本文の #{i + 1} 行目): lib=#{a[i].inspect} hook=#{b[i].inspect}"
end

require lib
require hook
require File.join(repo_root, "scripts", "lib", "local_instructions")
check("local の断片の見出しの写しは、sync が足す見出しと同じ (lib)", InstructionSections::LOCAL_HEADING == LocalInstructions::HEADING)
sample = "<!-- agent-tools:managed x -->\n# a\n\n## b\n\n```\n## c\n```\n\n#{LocalInstructions::HEADING}\n\n## d\n"
check("2 つの module は同じ結果を返す",
      InstructionSections.digests(sample) == InstructionUpdateNotice::Sections.digests(sample) &&
      InstructionSections.digests(sample).map(&:first) == ["a", "b", "local instructions"])

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: instruction-sections-test"
