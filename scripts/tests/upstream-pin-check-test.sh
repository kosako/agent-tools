#!/bin/sh
# shared/scripts/personal-upstream-pin-check.rb (参照元の pin の検査, #623) の self-test。
# 一時 directory の git repo と偽の gh で、一覧の形の検査・blob の hash の比べ方・確かめられない参照元の扱いを固定し、
# 最後に実 repo の .github/upstream-pins.json の形と、各 NOTICE に pin が書かれていることを見る。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

exec ruby - "$repo_root" <<'RUBY'
require "fileutils"
require "json"
require "open3"
require "tmpdir"

repo_root = ARGV.fetch(0)
script = File.join(repo_root, "shared/scripts/personal-upstream-pin-check.rb")
load script
U = UpstreamPinCheck

$failures = []
def check(label, ok)
  $failures << label unless ok
end

SHA = ->(c) { c * 40 }
def config(upstreams)
  JSON.generate("schema_version" => 1, "upstreams" => upstreams)
end
GOOD = { "name" => "lib-a", "repo" => "o/lib", "pin" => SHA.("a"), "notice" => "shared/x/NOTICE.md",
         "files" => { "src/a.md" => SHA.("1"), "src/b.md" => SHA.("2") } }.freeze

# ---- 一覧の形 ----
check("parse: valid", U.parse_config(config([GOOD])).size == 1)
bad = {
  "duplicate key" => '{"schema_version":1,"schema_version":1,"upstreams":[]}',
  "extra top key" => JSON.generate("schema_version" => 1, "upstreams" => [GOOD], "x" => 1),
  "schema 2" => JSON.generate("schema_version" => 2, "upstreams" => [GOOD]),
  "empty upstreams" => config([]),
  "extra upstream key" => config([GOOD.merge("extra" => 1)]),
  "missing key" => config([GOOD.reject { |k, _| k == "notice" }]),
  "bad name" => config([GOOD.merge("name" => "Lib A")]),
  "duplicate name" => config([GOOD, GOOD]),
  "bad repo" => config([GOOD.merge("repo" => "o/../x")]),
  "repo without owner" => config([GOOD.merge("repo" => "lib")]),
  "short pin" => config([GOOD.merge("pin" => "abc123")]),
  "upper pin" => config([GOOD.merge("pin" => "A" * 40)]),
  "notice with .." => config([GOOD.merge("notice" => "shared/../x")]),
  "empty files" => config([GOOD.merge("files" => {})]),
  "path with .." => config([GOOD.merge("files" => { "src/../a.md" => SHA.("1") })]),
  "path with empty segment" => config([GOOD.merge("files" => { "src//a.md" => SHA.("1") })]),
  "absolute path" => config([GOOD.merge("files" => { "/etc/a" => SHA.("1") })]),
  "bad blob sha" => config([GOOD.merge("files" => { "src/a.md" => "x" })]),
  "duplicate file key" => config([GOOD]).sub('"src/b.md"', '"src/a.md"'),
  "not json" => "{",
}
bad.each do |label, text|
  raised = begin
    U.parse_config(text)
    false
  rescue U::RunError
    true
  end
  check("parse rejects #{label}", raised)
end

# ---- CLI (一時 repo と偽の gh) ----
tmp = Dir.mktmpdir
at_exit { FileUtils.rm_rf(tmp) }

def git!(dir, *args)
  _o, e, st = Open3.capture3("git", *args, chdir: dir)
  raise "git #{args.join(' ')}: #{e}" unless st.success?
end

def make_repo(dir, files)
  FileUtils.mkdir_p(dir)
  git!(dir, "init", "-q")
  git!(dir, "config", "user.email", "t@example.invalid")
  git!(dir, "config", "user.name", "t")
  files.each do |rel, body|
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    if body.is_a?(Hash) && body[:symlink]
      File.symlink(body[:symlink], path)
    else
      File.write(path, body)
    end
  end
  git!(dir, "add", "-A")
  git!(dir, "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "fixture")
end

gh_dir = File.join(tmp, "fake-gh")
gh_bin = File.join(gh_dir, "bin")
FileUtils.mkdir_p(gh_bin)
File.write(File.join(gh_bin, "gh"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  dir = ENV.fetch("FAKE_GH_DIR")
  File.open(File.join(dir, "calls.log"), "a") { |f| f.puts(JSON.generate("args" => ARGV, "gh_repo" => ENV.key?("GH_REPO"))) }
  routes = JSON.parse(File.read(File.join(dir, "routes.json")))
  route = ARGV.size == 2 && ARGV[0] == "api" ? routes[ARGV[1]] : nil
  exit 1 if route.nil?
  print route.is_a?(String) ? route : JSON.generate(route)
FAKE
File.chmod(0o755, File.join(gh_bin, "gh"))
ENV_GH = { "PATH" => "#{gh_bin}:#{ENV.fetch('PATH')}", "FAKE_GH_DIR" => gh_dir, "GH_REPO" => "evil/elsewhere" }.freeze

def routes_for(repo, head, blobs, truncated: false, branch: "main")
  {
    "repos/#{repo}" => { "default_branch" => branch },
    "repos/#{repo}/git/ref/heads/#{branch}" => { "object" => { "sha" => head, "type" => "commit" } },
    "repos/#{repo}/git/trees/#{head}?recursive=1" => {
      "truncated" => truncated,
      "tree" => blobs.map { |p, s| { "path" => p, "type" => "blob", "sha" => s } } + [{ "path" => "src", "type" => "tree", "sha" => SHA.("f") }]
    }
  }
end

def set_routes(dir, routes)
  File.write(File.join(dir, "routes.json"), JSON.generate(routes))
  FileUtils.rm_f(File.join(dir, "calls.log"))
end

def calls(dir)
  path = File.join(dir, "calls.log")
  File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
end

def run_cli(dir, env: {})
  Open3.capture3(env, "ruby", $script_path, chdir: dir)
end
$script_path = script

# 一覧が無い repo: 所見なしで exit 0、gh を呼ばない。
none = File.join(tmp, "none")
make_repo(none, "README.md" => "x\n")
set_routes(gh_dir, {})
out, _err, st = run_cli(none, env: ENV_GH)
rep = JSON.parse(out) rescue nil
check("no config: exit 0", st.exitstatus == 0 && rep && rep["findings"] == [] && rep["scope"]["not_seen"].size == 1)
check("no config: gh is not called", calls(gh_dir).empty?)

# 変わっていない: exit 0。gh に GH_REPO を渡さない。
repo = File.join(tmp, "repo")
other = GOOD.merge("name" => "lib-b", "repo" => "o/other", "files" => { "docs/c.md" => SHA.("3") })
make_repo(repo, ".github/upstream-pins.json" => config([GOOD, other]))
same = routes_for("o/lib", SHA.("b"), { "src/a.md" => SHA.("1"), "src/b.md" => SHA.("2") })
       .merge(routes_for("o/other", SHA.("c"), { "docs/c.md" => SHA.("3") }))
set_routes(gh_dir, same)
out, _err, st = run_cli(repo, env: ENV_GH)
rep = JSON.parse(out)
check("unchanged: exit 0 and no findings", st.exitstatus == 0 && rep["findings"].empty? && rep["scope"]["seen"].size == 2)
check("unchanged: gh never sees GH_REPO", !calls(gh_dir).empty? && calls(gh_dir).none? { |c| c["gh_repo"] })
check("unchanged: only GET api calls", calls(gh_dir).all? { |c| c["args"].size == 2 && c["args"][0] == "api" })

# 変わった file と無くなった file: exit 1、参照元ごとに 1 件。
changed = routes_for("o/lib", SHA.("b"), { "src/a.md" => SHA.("9") })
          .merge(routes_for("o/other", SHA.("c"), { "docs/c.md" => SHA.("3") }))
set_routes(gh_dir, changed)
out, _err, st = run_cli(repo, env: ENV_GH)
rep = JSON.parse(out)
f = rep["findings"].first
check("changed: exit 1 with one finding", st.exitstatus == 1 && rep["findings"].size == 1)
check("changed: fingerprint and id", f && f["fingerprint"] == ".github/upstream-pins.json#upstream-lib-a" && f["id"] == "U01")
check("changed: claim names changed and removed files", f && f["claim"].include?("変わった file: src/a.md") && f["claim"].include?("無くなった file: src/b.md"))
check("changed: locations are notice and config", f && f["locations"] == ["shared/x/NOTICE.md", ".github/upstream-pins.json"])
check("changed: needs decision", f && f["needs_decision"] == true && rep["decisions"].size == 1)
required = %w[id fingerprint dimension kind severity confidence locations claim evidence impact recommendation needs_decision decision_reason]
check("changed: finding has the schema keys", f && (required - f.keys).empty?)

# tree の中の同じ path でも、blob でない entry は無くなったものとして扱う。
dir_only = routes_for("o/lib", SHA.("b"), { "src/b.md" => SHA.("2") })
dir_only["repos/o/lib/git/trees/#{SHA.('b')}?recursive=1"]["tree"] << { "path" => "src/a.md", "type" => "tree", "sha" => SHA.("1") }
set_routes(gh_dir, dir_only.merge(routes_for("o/other", SHA.("c"), { "docs/c.md" => SHA.("3") })))
out, _err, st = run_cli(repo, env: ENV_GH)
rep = JSON.parse(out)
check("non-blob entry counts as removed", st.exitstatus == 1 && rep["findings"].first["claim"].include?("無くなった file: src/a.md"))

# 1 つの参照元を確かめられない: exit 2 でも JSON を出し、残りは確かめる。
partial = routes_for("o/other", SHA.("c"), { "docs/c.md" => SHA.("4") })
set_routes(gh_dir, partial)
out, _err, st = run_cli(repo, env: ENV_GH)
rep = JSON.parse(out) rescue nil
check("one upstream unverifiable: exit 2 with JSON", st.exitstatus == 2 && rep && rep["scope"]["not_seen"].size == 1)
check("one upstream unverifiable: the other is still checked", rep && rep["findings"].size == 1 && rep["findings"][0]["fingerprint"].end_with?("lib-b"))

# 途中で切れた tree、形の外れた応答は確かめられない。
{
  "truncated tree" => routes_for("o/lib", SHA.("b"), { "src/a.md" => SHA.("1") }, truncated: true),
  "branch outside the form" => routes_for("o/lib", SHA.("b"), { "src/a.md" => SHA.("1") }, branch: "a/b"),
  "short head sha" => routes_for("o/lib", "abc", { "src/a.md" => SHA.("1") }),
  "not json" => { "repos/o/lib" => "not json" },
}.each do |label, r|
  set_routes(gh_dir, r.merge(routes_for("o/other", SHA.("c"), { "docs/c.md" => SHA.("3") })))
  out, _err, st = run_cli(repo, env: ENV_GH)
  rep = JSON.parse(out) rescue nil
  check("#{label}: exit 2 and not_seen", st.exitstatus == 2 && rep && rep["scope"]["not_seen"].any? { |l| l.start_with?("lib-a") })
end

# 一覧が symlink・形が外れる: stdout を出さず exit 2。
link = File.join(tmp, "link")
make_repo(link, "real.json" => config([GOOD]), ".github/upstream-pins.json" => { symlink: "../real.json" })
set_routes(gh_dir, same)
out, err, st = run_cli(link, env: ENV_GH)
check("symlinked config: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.lines.size == 1 && err.include?("通常の file"))
broken = File.join(tmp, "broken")
make_repo(broken, ".github/upstream-pins.json" => "{")
out, err, st = run_cli(broken, env: ENV_GH)
check("broken config: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.lines.size == 1)

# 一覧は HEAD の commit から読み、作業ツリーの変更は読まない。
File.write(File.join(repo, ".github/upstream-pins.json"), "{")
set_routes(gh_dir, same)
_out, _err, st = run_cli(repo, env: ENV_GH)
check("reads HEAD, not the work tree", st.exitstatus == 0)
git!(repo, "checkout", "-q", "--", ".github/upstream-pins.json")

# repo を選ぶ git の環境変数、引数、git repo の外。
out, err, st = run_cli(repo, env: ENV_GH.merge("GIT_DIR" => File.join(repo, ".git")))
check("inherited GIT_DIR: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.include?("GIT_DIR"))
out, err, st = Open3.capture3(ENV_GH, "ruby", script, "--since", chdir: repo)
check("unknown argument: exit 2 with usage", st.exitstatus == 2 && out.empty? && err.include?("usage:"))
out, _err, st = Open3.capture3("ruby", script, "--help", chdir: repo)
check("--help: exit 0", st.exitstatus == 0 && out.start_with?("usage:"))
plain = File.join(tmp, "plain")
FileUtils.mkdir_p(plain)
out, err, st = run_cli(plain, env: ENV_GH.merge("GIT_CEILING_DIRECTORIES" => tmp))
check("outside a git repo: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.lines.size == 1)

# ---- 実 repo の一覧 ----
real = File.join(repo_root, ".github/upstream-pins.json")
ups = U.parse_config(File.read(real))
check("real config parses", !ups.empty?)
ups.each do |u|
  notice = File.join(repo_root, u["notice"])
  check("real config: #{u['name']} notice exists", File.file?(notice))
  check("real config: #{u['name']} pin is written in the notice", File.file?(notice) && File.read(notice).include?(u["pin"]))
end

if $failures.empty?
  puts "ok: upstream-pin-check"
else
  $failures.each { |l| warn "FAIL: #{l}" }
  exit 1
end
RUBY
