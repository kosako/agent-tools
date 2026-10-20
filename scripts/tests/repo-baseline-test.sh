#!/bin/sh
# personal-repo-baseline.rb の self-test (#539)。
# 比べる部分 (evaluate / ruleset_facts / 設定 file / 引数) は require して直接、CLI は gh を fixture の応答を返す
# 偽物に差し替えて確かめる。偽の gh は読む形 (`gh api <path>`・`gh api -i <path>`・`gh api --paginate --slurp
# <path>`・`gh repo view --json nameWithOwner --jq .nameWithOwner`) 以外を受けず、fixture に無い path は失敗を
# 返す (想定外の API を呼ぶと「確かめられない」で落ちる)。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-repo-baseline.rb"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -f "$src" ] || fail "missing $src"

ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp" <<'RUBY'
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
src, tmp = ARGV
require src

RB = RepoBaseline

# ---- 偽の gh ----
bin = File.join(tmp, "bin")
FileUtils.mkdir_p(bin)
File.write(File.join(bin, "gh"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  dir = ENV.fetch("FAKE_GH_DIR")
  File.open(File.join(dir, "calls.log"), "a") do |f|
    f.puts(JSON.generate("args" => ARGV, "has_gh_repo" => ENV.key?("GH_REPO")))
  end
  args = ARGV
  if args == ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]
    current = ENV["FAKE_GH_CURRENT"]
    exit 1 if current.nil?
    puts current
    exit 0
  end
  mode, path =
    if args.size == 2 && args[0] == "api" then [:plain, args[1]]
    elsif args.size == 3 && args[0, 2] == ["api", "-i"] then [:include, args[2]]
    elsif args.size == 4 && args[0, 3] == ["api", "--paginate", "--slurp"] then [:slurp, args[3]]
    else
      File.write(File.join(dir, "unexpected"), JSON.generate(args))
      exit 9
    end
  route = JSON.parse(File.read(File.join(dir, "routes.json")))[path]
  exit 1 if route.nil?
  status = route.fetch("status")
  # pages を持つ route は複数ページの list。--paginate --slurp なら全ページを 1 つの配列に、それ以外は最初のページだけ。
  body = if route.key?("pages") then JSON.generate(route["pages"].first)
         elsif route.key?("body") then JSON.generate(route["body"])
         else ""
         end
  case mode
  when :include then print "HTTP/2.0 #{status} X\r\nContent-Type: application/json\r\n\r\n#{body}"
  when :slurp then print JSON.generate(route.key?("pages") ? route["pages"] : [route["body"]])
  else print body
  end
  exit(status < 300 ? 0 : 1)
FAKE
File.chmod(0o755, File.join(bin, "gh"))

def public_repo(name, overrides = {})
  {
    "full_name" => name, "visibility" => "public", "fork" => false, "archived" => false,
    "default_branch" => "main", "permissions" => { "admin" => true },
    "allow_squash_merge" => true, "allow_merge_commit" => false, "allow_rebase_merge" => false,
    "delete_branch_on_merge" => true,
    "security_and_analysis" => {
      "secret_scanning" => { "status" => "enabled" },
      "secret_scanning_push_protection" => { "status" => "enabled" },
    },
  }.merge(overrides)
end

def private_repo(name, overrides = {})
  public_repo(name, "visibility" => "private", "security_and_analysis" => nil).merge(overrides)
end

GOOD_RULES = [
  { "type" => "pull_request", "parameters" => { "required_approving_review_count" => 0 } },
  { "type" => "non_fast_forward" },
  { "type" => "deletion" },
].freeze

# baseline どおりの repo の応答。private は ruleset の path を持たない (呼ぶと失敗する)。
def routes_for(repo, rules: GOOD_RULES, alerts: 204, fixes: true, yml: 200, yaml: 404)
  name = repo["full_name"]
  r = {
    "repos/#{name}" => { "status" => 200, "body" => repo },
    "repos/#{name}/vulnerability-alerts" => { "status" => alerts },
    "repos/#{name}/automated-security-fixes" => { "status" => 200, "body" => { "enabled" => fixes, "paused" => false } },
    "repos/#{name}/contents/.github/dependabot.yml" => { "status" => yml },
    "repos/#{name}/contents/.github/dependabot.yaml" => { "status" => yaml },
  }
  r["repos/#{name}/rules/branches/main"] = { "status" => 200, "body" => rules } if repo["visibility"] == "public"
  r
end

$runs = 0
def run_cli(routes, args, config: nil, current: nil, env: {})
  $runs += 1
  dir = File.join(TMP, "run#{$runs}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "routes.json"), JSON.generate(routes))
  cfg_home = File.join(dir, "config")
  if config
    FileUtils.mkdir_p(File.join(cfg_home, "agent-tools"))
    File.write(File.join(cfg_home, "agent-tools", "repo-baseline.json"), config.is_a?(String) ? config : JSON.generate(config))
  end
  e = {
    "PATH" => "#{BIN}:#{ENV.fetch('PATH')}", "FAKE_GH_DIR" => dir, "XDG_CONFIG_HOME" => cfg_home,
    "GH_REPO" => "elsewhere/other",
  }
  e["FAKE_GH_CURRENT"] = current if current
  e.merge!(env)
  out, err, st = Open3.capture3(e, RbConfig.ruby, SRC, *args, chdir: dir)
  log = File.join(dir, "calls.log")
  calls = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  unexpected = File.exist?(File.join(dir, "unexpected"))
  { out: out, err: err, rc: st.exitstatus, calls: calls, unexpected: unexpected }
end

TMP = tmp
BIN = bin
SRC = src

# ---- valid_repo? ----
check("repo: owner/repo", RB.valid_repo?("o/r.x-y_z"))
check("repo: dotdot owner", !RB.valid_repo?("../r"))
check("repo: dot repo", !RB.valid_repo?("o/."))
check("repo: dash start", !RB.valid_repo?("-o/r"))
check("repo: dash start repo", !RB.valid_repo?("o/-r"))
check("repo: three parts", !RB.valid_repo?("o/r/x"))
check("repo: nil", !RB.valid_repo?(nil))
check("repo: newline", !RB.valid_repo?("o/r\n"))

# ---- parse_args ----
check("args: none is current", RB.parse_args([]) == :current)
check("args: --check is current", RB.parse_args(["--check"]) == :current)
check("args: --all", RB.parse_args(["--check", "--all"]) == :all)
check("args: --repo", RB.parse_args(["--repo", "o/r"]) == "o/r")
[["--apply"], ["--repo"], ["--repo", "../x"], ["--all", "--repo", "o/r"], ["--repo", "o/r", "--all"],
 ["--all", "--all"], ["--repo=o/r"], ["o/r"]].each do |args|
  raised = begin
    RB.parse_args(args)
    false
  rescue ArgumentError
    true
  end
  check("args: #{args.inspect} is usage error", raised)
end

# ---- evaluate ----
good_public = {
  "dependabot_alerts" => true, "dependabot_security_updates" => true, "merge_methods" => %w[squash],
  "delete_branch_on_merge" => true, "dependabot_yml" => true, "secret_scanning" => true,
  "secret_scanning_push_protection" => true, "ruleset_pull_request" => 0, "ruleset_non_fast_forward" => true,
  "ruleset_deletion" => true, "ruleset_required_checks" => [],
}
check("evaluate: public baseline has no drift", RB.evaluate("public", good_public, []) == [])
good_private = good_public.reject { |k, _| k.start_with?("ruleset_", "secret_") }
check("evaluate: private does not need ruleset or secret facts", RB.evaluate("private", good_private, []) == [])
check("evaluate: approve 1 is drift",
      RB.evaluate("public", good_public.merge("ruleset_pull_request" => 1), []) == [["ruleset_pull_request", 1, 0]])
check("evaluate: no PR rule is drift",
      RB.evaluate("public", good_public.merge("ruleset_pull_request" => nil), []) == [["ruleset_pull_request", nil, 0]])
check("evaluate: merge commit allowed is drift",
      RB.evaluate("private", good_private.merge("merge_methods" => ["squash", "merge commit"]), []) ==
        [["merge_methods", ["squash", "merge commit"], %w[squash]]])
check("evaluate: required checks missing one",
      RB.evaluate("public", good_public.merge("ruleset_required_checks" => %w[a]), %w[a b]) ==
        [["ruleset_required_checks", %w[a], %w[a b]]])
check("evaluate: required checks extra actual is fine",
      RB.evaluate("public", good_public.merge("ruleset_required_checks" => %w[a b c]), %w[a b]) == [])
check("evaluate: private ignores required checks", RB.evaluate("private", good_private, %w[a]) == [])

# ---- ruleset_facts ----
facts = RB.ruleset_facts([
  { "type" => "pull_request", "parameters" => { "required_approving_review_count" => 0 } },
  { "type" => "pull_request", "parameters" => { "required_approving_review_count" => 2 } },
  { "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "context" => "a" }, { "context" => "b" }] } },
  { "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "context" => "a" }] } },
  { "type" => "deletion" },
])
check("ruleset_facts: strictest approve wins", facts["ruleset_pull_request"] == 2)
check("ruleset_facts: contexts union", facts["ruleset_required_checks"] == %w[a b])
check("ruleset_facts: deletion", facts["ruleset_deletion"] == true)
check("ruleset_facts: no non_fast_forward", facts["ruleset_non_fast_forward"] == false)
check("ruleset_facts: none", RB.ruleset_facts([])["ruleset_pull_request"].nil?)
bad_pr = begin
  RB.ruleset_facts([{ "type" => "pull_request", "parameters" => {} }])
  false
rescue RB::Error
  true
end
check("ruleset_facts: PR rule without approve count is error", bad_pr)

# ---- parse_config ----
cfg = RB.parse_config(JSON.generate("exclude" => ["Owner/Hidden"], "required_checks" => { "Owner/CI" => ["test (a)"] }))
check("config: exclude is case-insensitive", cfg.excluded?("owner/hidden") && cfg.excluded?("OWNER/HIDDEN"))
check("config: required checks are case-insensitive", cfg.required_checks_for("owner/ci") == ["test (a)"])
check("config: no required checks", cfg.required_checks_for("owner/other") == [])
check("config: absent file is empty", !RB.parse_config(nil).excluded?("o/r"))
[
  ["unknown key", { "exclude" => [], "repos" => [] }],
  ["exclude not array", { "exclude" => "o/r" }],
  ["exclude bad name", { "exclude" => ["../r"] }],
  ["required not object", { "required_checks" => [] }],
  ["required bad key", { "required_checks" => { "o" => ["a"] } }],
  ["required empty list", { "required_checks" => { "o/r" => [] } }],
  ["required blank name", { "required_checks" => { "o/r" => [" "] } }],
  ["required control char", { "required_checks" => { "o/r" => ["a\tb"] } }],
  ["top-level array", []],
  ["required keys differing only in case", { "required_checks" => { "O/CI" => ["security"], "o/ci" => ["test"] } }],
].each do |label, data|
  raised = begin
    RB.parse_config(JSON.generate(data))
    false
  rescue ArgumentError
    true
  end
  check("config: #{label} is invalid", raised)
end

def lines(res)
  res[:out].lines.map(&:chomp)
end

def clean_calls?(res)
  !res[:unexpected] && res[:calls].none? { |c| c["has_gh_repo"] }
end

# ---- CLI: baseline どおりの public ----
repo = public_repo("o/good")
res = run_cli(routes_for(repo), ["--repo", "o/good"])
check("cli good: rc 0", res[:rc] == 0)
check("cli good: line", lines(res) == ["o/good (public): ずれ無し", RB::MANUAL_NOTE])
check("cli good: read-only gh calls without GH_REPO", clean_calls?(res))
check("cli good: stderr empty", res[:err].empty?)

# ---- CLI: 今の agent-tools と同じずれ ----
repo = public_repo("o/drift", "allow_merge_commit" => true, "allow_rebase_merge" => true, "delete_branch_on_merge" => false)
res = run_cli(routes_for(repo, rules: [], alerts: 404, fixes: false), ["--check", "--repo", "o/drift"])
check("cli drift: rc 1", res[:rc] == 1)
check("cli drift: lines", lines(res) == [
  "o/drift (public): ずれ 7 件",
  "  - Dependabot alerts (dependency graph を含む): 今 off / あるべき on",
  "  - Dependabot security updates: 今 off / あるべき on",
  "  - merge の方式: 今 squash、merge commit、rebase / あるべき squash だけ",
  "  - merge の後に branch を消す: 今 off / あるべき on",
  "  - default branch の ruleset: PR を必須にする: 今 無い / あるべき 有る (必要な approve 0)",
  "  - default branch の ruleset: force push の禁止: 今 off / あるべき on",
  "  - default branch の ruleset: 削除の禁止: 今 off / あるべき on",
  RB::MANUAL_NOTE,
])

# ---- CLI: secret scanning と dependabot.yml ----
repo = public_repo("o/sec", "security_and_analysis" => {
  "secret_scanning" => { "status" => "disabled" }, "secret_scanning_push_protection" => { "status" => "disabled" },
})
res = run_cli(routes_for(repo, yml: 404, yaml: 404), ["--repo", "o/sec"])
check("cli secret: rc 1", res[:rc] == 1)
check("cli secret: lines", lines(res)[1..3] == [
  "  - .github/dependabot.yml (repo ごとの PR で足す。script では書かない): 今 無い / あるべき 有る",
  "  - Secret scanning: 今 off / あるべき on",
  "  - Secret scanning の push protection: 今 off / あるべき on",
])
res = run_cli(routes_for(public_repo("o/yaml"), yml: 404, yaml: 200), ["--repo", "o/yaml"])
check("cli dependabot.yaml counts", res[:rc] == 0)
repo = public_repo("o/nosa", "security_and_analysis" => nil)
res = run_cli(routes_for(repo), ["--repo", "o/nosa"])
check("cli public without security_and_analysis is error", res[:rc] == 2 &&
  lines(res) == ["o/nosa: 確かめられない (security_and_analysis を読めません (応答の形が想定外))"])

# ---- CLI: 必須の check と approve の数 ----
rules = GOOD_RULES + [{ "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "context" => "test (a)" }] } }]
res = run_cli(routes_for(public_repo("o/ci"), rules: rules), ["--repo", "o/ci"],
              config: { "required_checks" => { "O/CI" => ["test (a)", "test (b)"] } })
check("cli required checks: rc 1", res[:rc] == 1)
check("cli required checks: line", lines(res)[1] ==
  "  - default branch の ruleset: 必須の check: 今 test (a) / あるべき test (a)、test (b) を含む")
res = run_cli(routes_for(public_repo("o/ci"), rules: rules), ["--repo", "o/ci"],
              config: { "required_checks" => { "o/ci" => ["test (a)"] } })
check("cli required checks satisfied", res[:rc] == 0)
rules = [{ "type" => "pull_request", "parameters" => { "required_approving_review_count" => 1 } }] + GOOD_RULES[1..-1]
res = run_cli(routes_for(public_repo("o/approve"), rules: rules), ["--repo", "o/approve"])
check("cli approve 1", res[:rc] == 1 && lines(res)[1] ==
  "  - default branch の ruleset: PR を必須にする: 今 有る (必要な approve 1) / あるべき 有る (必要な approve 0)")

# ---- CLI: private ----
res = run_cli(routes_for(private_repo("o/priv")), ["--repo", "o/priv"])
check("cli private: rc 0", res[:rc] == 0)
check("cli private: lines", lines(res) == ["o/priv (private): ずれ無し", RB::UNAVAILABLE_NOTE, RB::MANUAL_NOTE])
check("cli private: no ruleset call", res[:calls].none? { |c| c["args"].last.include?("/rules/") })
check("cli private: clean calls", clean_calls?(res))

# ---- CLI: 今の repo ----
res = run_cli(routes_for(public_repo("o/cur")), [], current: "o/cur")
check("cli current: rc 0", res[:rc] == 0 && lines(res).first == "o/cur (public): ずれ無し")
check("cli current: resolved by repo view without GH_REPO",
      res[:calls].first["args"][0, 2] == %w[repo view] && clean_calls?(res))
res = run_cli({}, [])
check("cli current unresolved: rc 2", res[:rc] == 2 && res[:out].empty?)
check("cli current unresolved: stderr", res[:err].include?("今の directory の repo を解決できません"))
res = run_cli({}, [], current: "../x")
check("cli current invalid name: rc 2", res[:rc] == 2 && res[:calls].size == 1)

# ---- CLI: 対象外 ----
res = run_cli(routes_for(public_repo("o/fork", "fork" => true)), ["--repo", "o/fork"])
check("cli fork: skipped", res[:rc] == 0 && lines(res) == ["o/fork: 対象外 (fork)"] && res[:calls].size == 1)
res = run_cli(routes_for(public_repo("o/arch", "archived" => true)), ["--repo", "o/arch"])
check("cli archived: skipped", res[:rc] == 0 && lines(res) == ["o/arch: 対象外 (archive 済み)"])
res = run_cli(routes_for(public_repo("o/noadmin", "permissions" => { "admin" => false })), ["--repo", "o/noadmin"])
check("cli no admin: skipped", res[:rc] == 0 && lines(res) == ["o/noadmin: 対象外 (admin 権限が無い)"])
res = run_cli({}, ["--repo", "o/Hidden"], config: { "exclude" => ["O/hidden"] })
check("cli excluded: skipped without gh", res[:rc] == 0 && lines(res) == ["o/Hidden: 対象外 (設定 file で除外)"] && res[:calls].empty?)
# rename された repo は API が新しい名前を返す。除外は新しい名前でも効く。
res = run_cli({ "repos/o/old" => { "status" => 200, "body" => public_repo("o/new") } }, ["--repo", "o/old"],
              config: { "exclude" => ["O/NEW"] })
check("cli excluded by canonical name", res[:rc] == 0 && lines(res) == ["o/new: 対象外 (設定 file で除外)"] && res[:calls].size == 1)

# ---- CLI: 想定外の応答 ----
res = run_cli(routes_for(public_repo("o/odd"), alerts: 403), ["--repo", "o/odd"])
check("cli unexpected alerts status", res[:rc] == 2 &&
  lines(res) == ["o/odd: 確かめられない (Dependabot alerts の応答が想定外です (HTTP 403))"])
routes = routes_for(public_repo("o/gone"))
routes.delete("repos/o/gone/automated-security-fixes")
res = run_cli(routes, ["--repo", "o/gone"])
check("cli gh failure", res[:rc] == 2 &&
  lines(res) == ["o/gone: 確かめられない (Dependabot security updates を読めません (gh api が失敗))"])
# system Ruby は起動に uname を使うので /usr/bin と /bin は残す (そこに gh があれば確かめられないので飛ばす)。
unless %w[/usr/bin/gh /bin/gh].any? { |p| File.exist?(p) }
  res = run_cli(routes_for(public_repo("o/nogh")), ["--repo", "o/nogh"], env: { "PATH" => "#{File.join(TMP, 'empty')}:/usr/bin:/bin" })
  check("cli gh missing", res[:rc] == 2 && lines(res) == ["o/nogh: 確かめられない (gh を起動できません)"])
end

# ---- CLI: 応答の field の欠落・null・型違いは「確かめられない」 ----
def broken(label, repo, expected_reason, **opts)
  res = run_cli(routes_for(repo, **opts), ["--repo", repo["full_name"]])
  check("cli broken #{label}", res[:rc] == 2 && lines(res) == ["#{repo['full_name']}: 確かめられない (#{expected_reason})"])
end
no_perm = public_repo("o/noperm")
no_perm.delete("permissions")
broken("permissions missing", no_perm, "permissions の field を読めません (応答の形が想定外)")
broken("admin null", public_repo("o/adminnull", "permissions" => { "admin" => nil }), "permissions.admin の field を読めません (値が無い)")
no_fork = public_repo("o/nofork")
no_fork.delete("fork")
broken("fork missing", no_fork, "fork の field を読めません (値が無い)")
broken("archived not boolean", public_repo("o/archstr", "archived" => "no"), "archived の field を読めません (値が無い)")
broken("merge field null", public_repo("o/mergenull", "allow_rebase_merge" => nil), "merge の方式 を読めません (値が無い)")
broken("secret scanning entry string", public_repo("o/secstr", "security_and_analysis" => { "secret_scanning" => "enabled" }),
       "secret_scanning を読めません (応答の形が想定外)")
broken("secret scanning status unknown",
       public_repo("o/secodd", "security_and_analysis" => {
         "secret_scanning" => { "status" => "enabled" }, "secret_scanning_push_protection" => { "status" => "maybe" },
       }),
       "secret_scanning_push_protection を読めません (応答の形が想定外)")
broken("default branch missing", public_repo("o/nobranch", "default_branch" => nil), "default branch を読めません (応答の形が想定外)")
broken("rule without type", public_repo("o/notype"), "default branch の rule を読めません (応答の形が想定外)",
       rules: [{ "parameters" => {} }])
broken("PR rule without parameters", public_repo("o/prnoparam"), "PR の rule を読めません (応答の形が想定外)",
       rules: [{ "type" => "pull_request" }])
broken("status checks rule without parameters", public_repo("o/scnoparam"), "必須の check の rule を読めません (応答の形が想定外)",
       rules: GOOD_RULES + [{ "type" => "required_status_checks" }])
broken("status checks not array", public_repo("o/scnotarray"), "必須の check の rule を読めません (応答の形が想定外)",
       rules: GOOD_RULES + [{ "type" => "required_status_checks", "parameters" => { "required_status_checks" => "a" } }])
broken("status check without context", public_repo("o/scnoctx"), "必須の check の名前 を読めません (応答の形が想定外)",
       rules: GOOD_RULES + [{ "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "integration_id" => 1 }] } }])
routes = routes_for(public_repo("o/fixarr"))
routes["repos/o/fixarr/automated-security-fixes"] = { "status" => 200, "body" => [] }
res = run_cli(routes, ["--repo", "o/fixarr"])
check("cli broken security updates not object", res[:rc] == 2 &&
  lines(res) == ["o/fixarr: 確かめられない (Dependabot security updates を読めません (応答の形が想定外))"])

# 検査が見落とした型違いの例外も、その repo だけ「確かめられない」にする。
fake = RB.clone
fake.define_singleton_method(:gh_json) { |_path, _label| public_repo("o/boom") }
fake.define_singleton_method(:collect_facts) { |*_args| raise TypeError, "boom" }
r = fake.check_repo("o/boom", RB.parse_config(nil))
check("check_repo turns TypeError into a repo error", r.status == :error && r.reason == "応答の形が想定外です (TypeError)")

# ---- CLI: --all ----
# 一覧は 2 ページ (--paginate --slurp を外すと 2 ページ目の repo を落とす)。
list_page1 = [
  public_repo("o/b-good"), private_repo("o/a-priv", "delete_branch_on_merge" => false),
  public_repo("o/fork", "fork" => true), public_repo("o/arch", "archived" => true),
]
list_page2 = [
  private_repo("o/Secret"), public_repo("o/c-err"), public_repo("o/d-noadmin"),
  public_repo("o/b-broken"), public_repo("o/e-page2"),
]
routes = {}
[list_page1[0], list_page1[1], list_page2[4]].each { |repo| routes.merge!(routes_for(repo)) }
routes.merge!(routes_for(public_repo("o/d-noadmin", "permissions" => { "admin" => false })))
routes.merge!(routes_for(public_repo("o/b-broken", "security_and_analysis" => { "secret_scanning" => "x" })))
routes[RB::LIST_PATH] = { "status" => 200, "pages" => [list_page1, list_page2] }
res = run_cli(routes, ["--all"], config: { "exclude" => ["o/secret"] })
check("cli all: rc 2 with unreadable repos", res[:rc] == 2)
check("cli all: lines", lines(res) == [
  "o/a-priv (private): ずれ 1 件",
  "  - merge の後に branch を消す: 今 off / あるべき on",
  "o/b-broken: 確かめられない (secret_scanning を読めません (応答の形が想定外))",
  "o/b-good (public): ずれ無し",
  "o/c-err: 確かめられない (repo を読めません (gh api が失敗))",
  "o/d-noadmin: 対象外 (admin 権限が無い)",
  "o/e-page2 (public): ずれ無し",
  "対象の repo: 5 件 (ずれ無し 2・ずれ有り 1・確かめられない 2) / 対象外: fork 1 件・archive 済み 1 件・設定 file で除外 1 件・admin 権限が無い 1 件",
  RB::UNAVAILABLE_NOTE,
  RB::MANUAL_NOTE,
])
check("cli all: excluded, fork, archived repos are not read",
      res[:calls].none? { |c| c["args"].last =~ %r{repos/o/(fork|arch|Secret)} })
check("cli all: clean calls", clean_calls?(res))
res = run_cli(routes.reject { |k, _| k == RB::LIST_PATH }, ["--all"])
check("cli all: list failure", res[:rc] == 2 && res[:out].empty? && res[:err].include?("repo の一覧を読めません"))
routes[RB::LIST_PATH] = { "status" => 200, "pages" => list_page1 }
res = run_cli(routes, ["--all"])
check("cli all: list pages must be arrays", res[:rc] == 2 && res[:err].include?("repo の一覧の応答が想定の形ではありません"))

# ---- CLI: 設定 file ----
res = run_cli(routes_for(public_repo("o/good")), ["--repo", "o/good"], config: { "exclude" => ["hidden-owner/hidden-name"], "x" => 1 })
check("cli bad config: rc 2", res[:rc] == 2 && res[:out].empty?)
check("cli bad config: no gh calls", res[:calls].empty?)
check("cli bad config: reason without content", res[:err].include?("知らない key") && !res[:err].include?("hidden"))
res = run_cli(routes_for(public_repo("o/good")), ["--repo", "o/good"], config: "{")
check("cli config not json", res[:rc] == 2 && res[:err].include?("JSON として読めません"))
home = File.join(TMP, "home")
FileUtils.mkdir_p(File.join(home, ".config", "agent-tools"))
File.write(File.join(home, ".config", "agent-tools", "repo-baseline.json"), JSON.generate("exclude" => ["o/viahome"]))
res = run_cli({}, ["--repo", "o/viahome"], env: { "XDG_CONFIG_HOME" => "relative/dir", "HOME" => home })
check("cli relative XDG_CONFIG_HOME falls back to HOME", lines(res) == ["o/viahome: 対象外 (設定 file で除外)"])
dirconf = File.join(TMP, "dirconf")
FileUtils.mkdir_p(File.join(dirconf, "agent-tools", "repo-baseline.json"))
res = run_cli({}, ["--repo", "o/x"], env: { "XDG_CONFIG_HOME" => dirconf })
check("cli config not regular file", res[:rc] == 2 && res[:err].include?("regular file ではありません"))

# ---- CLI: usage ----
res = run_cli({}, ["--apply"])
check("cli --apply is usage error", res[:rc] == 2 && res[:err].include?("usage:") && res[:calls].empty?)
res = run_cli({}, ["--help"])
check("cli help", res[:rc] == 0 && res[:out].start_with?(RB.usage + "\n"))

exit(@failed.zero? ? 0 : 1)
RUBY
echo "ok: repo-baseline"
