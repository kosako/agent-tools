# Adapters

Adapters は、shared assets を tool-specific artifacts に変換する方法を記述します。

v1 で想定する targets:

- Codex
- Claude Code
- OpenCode (plugin のみ, #295)

adapter specs:

- [codex/README.md](codex/README.md)
- [claude-code/README.md](claude-code/README.md)
- [opencode/README.md](opencode/README.md)

build logic は `scripts/build.sh` (`scripts/lib/build.rb`) にあります。
v1 で生成する artifact kind は `skill` / `instruction` / `script` / `plugin` です。tool ごとに
配れる kind は `scripts/lib/artifact_targets.rb` の `TOOL_KINDS` で決まります (Codex / Claude Code
は skill / instruction / script、OpenCode は plugin だけ。
[Tool Compatibility 方針](../docs/tool-compatibility.md))。
