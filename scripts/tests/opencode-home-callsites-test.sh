#!/bin/sh
# scripts/tests/ の sync / status / doctor / setup の呼び出しが --opencode-home を渡していることの
# 静的な検査 (#295)。読み取りの call site (status / doctor) は canary
# (scripts/tests/lib/opencode-home-canary.sh、書き込みの検出) では捕まらないので、ここで守る。
#
# 判定: 行末 \ の継続行をつないだ 1 行のうち、sync / status / doctor / setup の呼び出しの token
# ("$sync" / "$status_sh" / "$doctor" / "$setup" か <name>.sh の file 名) を含む行は、すべて
# --opencode-home を渡していること。token は行頭だけでなく、command 置換の中 (`out=$("$setup" …)`)、
# 関数本体の 1 行定義 (`run15() { "$sync" …; }`)、pipeline / `&&` の後ろでも拾う (#338 review round 2)。
# 変数の定義行 (`sync=…`) と `for … in` の列挙行は呼び出しではないので除く。home flag を 1 つも渡さない
# 呼び出しも対象に含める (既定の home を読むので、読み取りでも実物の ~/.config/opencode に触る。
# #338 review)。除外は、行末の注記 `# no-opencode-home: <理由>` を付けた呼び出しだけ (HOME を偽に差し替えた
# doctor-test の XDG case、usage で止まる parse-only の case)。connect は instruction を配らない
# opencode の home を受け取らない (渡すと exit 2) ので対象外。helper 経由の呼び出し (root-default-test の
# `run_script status.sh …`) は script 名で拾う。cli-args-test の "$cmd" 経由の loop は
# 変数名が違うので対象に入らない (parse 段で止まる case のみ)。
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
  exempt = []
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
      next if joined =~ /\A\s*#/ || joined =~ /\A\s*for\s/
      # 呼び出しの token: "$sync" 等の変数 (行頭、$(、{、;、&&、||、| の後ろ)、<dir>/sync.sh 等の
      # file 名、helper 経由 (run_script status.sh …)。変数の定義行は token の後ろが `="` なので当たらない。
      next unless joined =~ /(?:\A|[\s(;{&|])"?\$\{?(sync|status_sh|doctor|setup)\}?"?(?=[\s)]|\z)/ ||
                  joined =~ /(?:\A|[\s(;{&|])(?:\w+\s+)?\S*?(sync|status|doctor|setup)\.sh(?=[\s)]|\z)/

      if joined.include?("--opencode-home")
        checked[File.basename(path)] += 1
        next
      end
      if joined =~ /#\s*no-opencode-home:\s*\S/
        exempt << "#{path}:#{start}"
        next
      end
      offenders << "#{path}:#{start}: #{joined.strip}"
    end
  end
  # 注記で除外した呼び出しは数えない (除外だけの suite で「検査した」ことにならないように)。
  missing = required.reject { |name| checked[name] > 0 }
  unless missing.empty?
    warn "no flag-carrying call sites found in: #{missing.join(", ")} (is the detection regex broken?)"
    exit 1
  end
  unless offenders.empty?
    warn "sync / status / doctor / setup call sites without --opencode-home (add the flag, or `# no-opencode-home: <reason>` for a parse-only / fake-HOME case):"
    offenders.each { |o| warn "  #{o}" }
    exit 1
  end
  puts "checked #{checked.values.sum} call site(s) in #{checked.size} file(s), #{exempt.size} exempt by annotation"
' "$@" || fail "static --opencode-home check failed"

echo "ok: opencode-home call-site check passed"
