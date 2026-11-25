#!/bin/sh
# scripts/lib/auto_memory.rb の self-test (#770)。init の event の形ごとの状態、run ごとの状態のまとめ、judge の入力の形を見る。
# CLI は起動しない。probe が環境と記録を渡すことは probe-skill-behavior-test.sh と probe-skill-routing-test.sh が見る。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/scripts/lib/auto_memory.rb"
[ -f "$src" ] || fail "missing $src"

ruby -r"$script_dir/lib/check_helper" - "$src" <<'RUBY'
load ARGV[0]
A = AutoMemory
check("渡す環境は 1 つ", A::ENV_OFF == { "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1" } && A::ENV_OFF.frozen?)

# init の event の memory_paths の形
init = { "type" => "system", "subtype" => "init", "model" => "m" }
check("memory_paths が無ければ not-listed", A.state(init) == "not-listed")
{
  nil => "not-listed", {} => "not-listed", { "team" => "/x" } => "not-listed", { "auto" => nil } => "not-listed",
  { "auto" => nil, "team" => "/x" } => "not-listed",
  { "auto" => "/x" } => "listed", { "auto" => "" } => "listed", { "auto" => 0 } => "listed", { "auto" => false } => "listed",
  { "auto" => [] } => "listed", { "auto" => {} } => "listed", { "auto" => "/x", "team" => "/y" } => "listed",
  [] => "unknown", ["/x"] => "unknown", "" => "unknown", "/x" => "unknown", 0 => "unknown", false => "unknown", true => "unknown",
}.each do |paths, want|
  got = A.state(init.merge("memory_paths" => paths))
  check("memory_paths が #{paths.inspect} なら #{want} (#{got})", got == want)
end

# run ごとの状態のまとめ
n, l, u = %w[not-listed listed unknown]
{
  [] => u, [[]] => u, [[n]] => n, [[n], [n]] => n, [[l], [l]] => l, [[u], []] => u, [[n], [n, n]] => n,
  [[n], [l]] => "mixed:not-listed,listed", [[l], [n]] => "mixed:listed,not-listed", [[n], []] => "mixed:not-listed,unknown",
  [[n, l]] => "mixed:not-listed,listed", [[n], [l], [n], []] => "mixed:not-listed,listed,unknown",
}.each do |runs, want|
  got = A.record(runs)
  check("#{runs.inspect} は #{want} (#{got.inspect})", got == { "requested" => "off", "init" => want })
end
# 緑にするのは、全部の run に init があり、どれも not-listed のときだけ (3 run までの全部の組)
shapes = [[], [n], [l], [u], [n, n], [n, l], [l, n]]
runs = (1..3).flat_map { |k| shapes.repeated_permutation(k).to_a }
check("まとめの組の数", runs.length == 7 + 49 + 343)
bad = runs.reject { |r| A.off?(A.record(r)) == r.all? { |s| s == [n] || s == [n, n] } }
check("まとめを緑にする組 #{bad.first(3).inspect}", bad.empty?)
check("まとめの値は、judge の入力の形に合う", runs.all? { |r| A.valid?(A.record(r)) })

# judge の入力の形
{
  { "requested" => "off", "init" => n } => true, { "init" => l, "requested" => "off" } => true,
  { "requested" => "off", "init" => "mixed:not-listed,listed" } => true, { "requested" => "off", "init" => "x" } => true,
  nil => false, "off" => false, [] => false, {} => false, true => false, { "requested" => "off" } => false, { "init" => n } => false,
  { "requested" => "off", "init" => n, "x" => 1 } => false, { "requested" => "on", "init" => n } => false,
  { "requested" => nil, "init" => n } => false, { "requested" => "", "init" => n } => false, { "requested" => true, "init" => n } => false,
  { "requested" => "off", "init" => "" } => false, { "requested" => "off", "init" => nil } => false,
  { "requested" => "off", "init" => 1 } => false, { "requested" => "off", "init" => [n] } => false,
}.each { |v, want| check("形 #{v.inspect} は #{want}", A.valid?(v) == want) }
exit(@failed.zero? ? 0 : 1)
RUBY

echo "auto-memory-test: ok"
