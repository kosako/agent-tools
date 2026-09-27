#!/bin/sh
# scripts/tests/ の sync / status / doctor / setup の呼び出しが --opencode-home を渡していることの
# 静的な検査 (#295)。読み取りの call site (status / doctor) は canary
# (scripts/tests/lib/opencode-home-canary.sh、書き込みの検出) では捕まらないので、ここで守る。
#
# 判定: 行末 \ の継続行をつないだ 1 行のうち、sync / status / doctor / setup を参照し
# ($sync / $status_sh / $doctor / $setup の変数か <name>.sh の file 名)、--codex-home か --claude-home
# を渡していて connect を呼んでいない行は、--opencode-home も渡していること。connect は instruction を
# 配らない opencode の home を受け取らない (渡すと exit 2) ので除く。home flag を 1 つも渡さない
# 呼び出し (cli-args の parse 段の case、HOME を差し替える doctor-test の XDG case) と、別 script
# (codex-worker-preflight 等) の --codex-home は対象外。
# 対象は scripts/tests/*.sh と scripts/tests/lib/*.sh (この test 自身を除く)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
self=$(basename -- "$0")

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

set --
for f in "$script_dir"/*.sh "$script_dir"/lib/*.sh; do
  [ "$(basename -- "$f")" = "$self" ] && continue
  set -- "$@" "$f"
done

# 継続行をつないでから検査し、行番号は元の file のもの (つないだ最初の行) で報告する。
# 検査した呼び出しが 1 つも無い suite があれば、判定の regex が壊れて素通りしている疑いなので fail。
ruby -e '
  required = %w[sync-test.sh status-test.sh doctor-test.sh setup-test.sh root-default-test.sh]
  offenders = []
  checked = Hash.new(0)
  ARGV.each do |path|
    lines = File.readlines(path)
    i = 0
    while i < lines.size
      start = i + 1
      joined = lines[i].chomp
      while joined.end_with?("\\") && i + 1 < lines.size
        i += 1
        joined = joined.chomp("\\") + " " + lines[i].chomp.lstrip
      end
      i += 1
      next unless joined =~ /--(codex|claude)-home\b/
      next unless joined =~ /\$\{?(sync|status_sh|status|doctor|setup)\b|\b(sync|status|doctor|setup)\.sh\b/
      next if joined.include?("connect")

      checked[File.basename(path)] += 1
      offenders << "#{path}:#{start}: #{joined.strip}" unless joined.include?("--opencode-home")
    end
  end
  missing = required.reject { |name| checked[name] > 0 }
  unless missing.empty?
    warn "no home-flag call sites found in: #{missing.join(", ")} (is the detection regex broken?)"
    exit 1
  end
  unless offenders.empty?
    warn "call sites passing --codex-home / --claude-home without --opencode-home:"
    offenders.each { |o| warn "  #{o}" }
    exit 1
  end
  puts "checked #{checked.values.sum} call site(s) in #{checked.size} file(s)"
' "$@" || fail "static --opencode-home check failed"

echo "ok: opencode-home call-site check passed"
