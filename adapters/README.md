# Adapters

Adapters は、shared assets を tool-specific artifacts に変換する方法を記述します。

v1 で想定する targets:

- Codex
- Claude Code

adapter specs:

- [codex/README.md](codex/README.md)
- [claude-code/README.md](claude-code/README.md)

build logic は `scripts/build.sh` (`scripts/lib/build.rb`) にあります。
v1 で生成する artifact kind は `skill` / `instruction` / `script` です。
