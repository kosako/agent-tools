#!/bin/sh
# personal-repo-baseline.rb の self-test (#539)。
# 比べる部分 (evaluate / ruleset_facts / fix_actions / 設定 file / 引数) は require して直接、CLI は gh を fixture
# の応答を返す偽物に差し替えて確かめる。偽の gh は読む形 (`gh api <path>`・`gh api -i <path>`・`gh api --paginate
# --slurp <path>`・`gh repo view --json nameWithOwner --jq .nameWithOwner`) と書く形 (`gh api -X <method> <path>
# [--input -]`) 以外を受けず、fixture に無い path は失敗を返す (想定外の API を呼ぶと「確かめられない」で落ちる)。
# 書く形は fixture の __writes__ に有るものだけ成功し、その set で以後の応答を変える (直した後の読み直しを確かめる)。
# --check は書く形を 1 度も呼ばないことも確かめる。network access なし。
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
  args = ARGV
  # 書く形は body を stdin から読む (`--input -`)。
  write = args.size >= 4 && args[0, 2] == ["api", "-X"] && (args.size == 4 || args[4, 2] == ["--input", "-"])
  input = write && args.size == 6 ? JSON.parse(STDIN.read) : nil
  File.open(File.join(dir, "calls.log"), "a") do |f|
    f.puts(JSON.generate("args" => args, "has_gh_repo" => ENV.key?("GH_REPO"), "body" => input))
  end
  if write
    exit 9 unless [4, 6].include?(args.size)
    routes = JSON.parse(File.read(File.join(dir, "routes.json")))
    hit = routes.fetch("__writes__", {})["#{args[2]} #{args[3]}"]
    exit 1 if hit.nil?
    routes.merge!(hit.fetch("set", {}))
    File.write(File.join(dir, "routes.json"), JSON.generate(routes))
    exit(hit.fetch("status") < 300 ? 0 : 1)
  end
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
  # exit を持つ route は gh の終了状態を status と別に決める (2xx の status 行を出した後の失敗など)。
  exit(route.key?("exit") ? route["exit"] : (status < 300 ? 0 : 1))
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

# repo の設定 file (.github/repo-baseline.json) の contents API の応答。overrides で field を壊す。
def repo_file_route(text, overrides = {})
  body = { "type" => "file", "encoding" => "base64", "content" => [text].pack("m"), "size" => text.bytesize }
  { "status" => 200, "body" => body.merge(overrides) }
end

# baseline どおりの repo の応答。private は ruleset の path を持たない (呼ぶと失敗する)。settings は repo の設定
# file の中身 (Hash は JSON にする、String はそのまま。nil は file が無い = 404)。
def routes_for(repo, rules: GOOD_RULES, alerts: 204, fixes: true, yml: 200, yaml: 404, settings: nil)
  name = repo["full_name"]
  r = {
    "repos/#{name}" => { "status" => 200, "body" => repo },
    "repos/#{name}/vulnerability-alerts" => { "status" => alerts },
    "repos/#{name}/automated-security-fixes" => { "status" => 200, "body" => { "enabled" => fixes, "paused" => false } },
    "repos/#{name}/contents/.github/dependabot.yml" => { "status" => yml },
    "repos/#{name}/contents/.github/dependabot.yaml" => { "status" => yaml },
    "repos/#{name}/contents/.github/repo-baseline.json" =>
      settings.nil? ? { "status" => 404 } : repo_file_route(settings.is_a?(String) ? settings : JSON.generate(settings)),
  }
  r["repos/#{name}/rules/branches/main?per_page=100"] = { "status" => 200, "body" => rules } if repo["visibility"] == "public"
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
check("args: none is current check", RB.parse_args([]).to_a == [:check, :current])
check("args: --check is current check", RB.parse_args(["--check"]).to_a == [:check, :current])
check("args: --all", RB.parse_args(["--check", "--all"]).to_a == [:check, :all])
check("args: --repo", RB.parse_args(["--repo", "o/r"]).to_a == [:check, "o/r"])
check("args: --apply", RB.parse_args(["--apply"]).to_a == [:apply, :current])
check("args: --apply --all", RB.parse_args(["--all", "--apply"]).to_a == [:apply, :all])
check("args: --apply --repo", RB.parse_args(["--apply", "--repo", "o/r"]).to_a == [:apply, "o/r"])
[["--check", "--apply"], ["--apply", "--check"], ["--apply", "--apply"], ["--check", "--check"], ["--repo"], ["--repo", "../x"], ["--all", "--repo", "o/r"], ["--repo", "o/r", "--all"],
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
check("evaluate: skipped item is not compared",
      RB.evaluate("public", good_public.merge("dependabot_yml" => false), [], %w[dependabot_yml]) == [])
check("evaluate: skipped item needs no fact",
      RB.evaluate("public", good_public.reject { |k, _| k == "dependabot_yml" }, [], %w[dependabot_yml]) == [])
check("evaluate: skip leaves other drift",
      RB.evaluate("private", good_private.merge("dependabot_yml" => false, "delete_branch_on_merge" => false), [], %w[dependabot_yml]) ==
        [["delete_branch_on_merge", false, true]])

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

# ---- parse_config (手元の設定 file。key は exclude だけ) ----
cfg = RB.parse_config(JSON.generate("exclude" => ["Owner/Hidden"]))
check("config: exclude is case-insensitive", cfg.excluded?("owner/hidden") && cfg.excluded?("OWNER/HIDDEN"))
check("config: absent file is empty", !RB.parse_config(nil).excluded?("o/r"))
check("config: empty object is fine", !RB.parse_config("{}").excluded?("o/r"))
[
  ["unknown key", { "exclude" => [], "repos" => [] }],
  ["exclude not array", { "exclude" => "o/r" }],
  ["exclude bad name", { "exclude" => ["../r"] }],
  ["top-level array", []],
].each do |label, data|
  raised = begin
    RB.parse_config(JSON.generate(data))
    false
  rescue ArgumentError
    true
  end
  check("config: #{label} is invalid", raised)
end
# 移行は切り替え (#545): 手元に残った required_checks は、移った先を添えて不正にする。
moved = begin
  RB.parse_config(JSON.generate("exclude" => [], "required_checks" => { "o/r" => ["a"] }))
  nil
rescue ArgumentError => e
  e.message
end
check("config: required_checks moved to the repo file", moved == "設定 file の required_checks は、各 repo の .github/repo-baseline.json に移しました")
# 同じ綴りの key の重なりは、Hash から作れないので生の JSON で確かめる (JSON.parse は既定で後の値を残す)。
message = begin
  RB.parse_config('{"exclude":["o/a"],"exclude":[]}')
  nil
rescue ArgumentError => e
  e.message
end
check("config: duplicate top-level key is invalid", message == "設定 file に重なった key があります")
check("config: objects are still hashes", RB.parse_config('{"exclude":["o/r"]}').excluded?("o/r"))

# ---- parse_repo_settings (repo の設定 file。key は skip と required_checks) ----
s = RB.parse_repo_settings('{"skip":["dependabot_yml"],"required_checks":["test (a)","test (b)"]}')
check("repo file: skip and required checks", s.skip == %w[dependabot_yml] && s.required_checks == ["test (a)", "test (b)"])
s = RB.parse_repo_settings("{}")
check("repo file: empty object has no settings", s.skip == [] && s.required_checks == [])
check("repo file: binary text is read as UTF-8", RB.parse_repo_settings('{"required_checks":["テスト"]}'.b).required_checks == ["テスト"])
# 不正なら理由の文言。想定外の例外 (検査の漏れで nil を触るなど) も、test を止めずに assertion で落とす。
def repo_file_error(text)
  RB.parse_repo_settings(text)
  nil
rescue RB::Error => e
  e.message
rescue StandardError => e
  "unexpected #{e.class}"
end
label = "repo の設定 file (.github/repo-baseline.json)"
[
  ["unknown key", '{"exclude":["o/r"]}', "#{label} に知らない key があります"],
  ["skip not array", '{"skip":"dependabot_yml"}', "#{label} の skip が外せる項目 (dependabot_yml) の空でない配列ではありません"],
  ["skip null", '{"skip":null}', "#{label} の skip が外せる項目 (dependabot_yml) の空でない配列ではありません"],
  ["required null", '{"required_checks":null}', "#{label} の required_checks が空でない check の名前の配列ではありません"],
  ["skip empty", '{"skip":[]}', "#{label} の skip が外せる項目 (dependabot_yml) の空でない配列ではありません"],
  ["skip security item", '{"skip":["ruleset_pull_request"]}', "#{label} の skip が外せる項目 (dependabot_yml) の空でない配列ではありません"],
  ["skip alerts", '{"skip":["dependabot_alerts"]}', "#{label} の skip が外せる項目 (dependabot_yml) の空でない配列ではありません"],
  ["skip unknown item", '{"skip":["dependabot_yml","nope"]}', "#{label} の skip が外せる項目 (dependabot_yml) の空でない配列ではありません"],
  ["skip duplicate value", '{"skip":["dependabot_yml","dependabot_yml"]}', "#{label} の skip に重なった値があります"],
  ["required not array", '{"required_checks":"a"}', "#{label} の required_checks が空でない check の名前の配列ではありません"],
  ["required empty", '{"required_checks":[]}', "#{label} の required_checks が空でない check の名前の配列ではありません"],
  ["required blank", '{"required_checks":[" "]}', "#{label} の required_checks が空でない check の名前の配列ではありません"],
  ["required control char", "{\"required_checks\":[\"a\\tb\"]}", "#{label} の required_checks が空でない check の名前の配列ではありません"],
  ["required not string", '{"required_checks":[1]}', "#{label} の required_checks が空でない check の名前の配列ではありません"],
  ["required duplicate value", '{"required_checks":["a","a"]}', "#{label} の required_checks に重なった値があります"],
  ["duplicate key", '{"skip":["dependabot_yml"],"skip":["dependabot_yml"]}', "#{label} に重なった key があります"],
  ["top-level array", "[]", "#{label} の top-level が object ではありません"],
  ["not json", "{", "#{label} が JSON として読めません"],
  ["not utf-8", "{\"required_checks\":[\"\xff\"]}".b, "#{label} が UTF-8 として読めません"],
].each do |name, text, expected|
  check("repo file: #{name} is invalid", repo_file_error(text) == expected)
end
# JSON の孤立した surrogate (\uDC00) は、parse の後で不正な UTF-8 の文字列になりうる (Ruby 2.6 の json)。strip や
# 正規表現で例外にせず、repo の設定 file の不正にする (json の版で parse の失敗になっても、不正であることは同じ)。
SURROGATE = "\\" + "uDC00"
[["required_checks", "{\"required_checks\":[\"#{SURROGATE}\"]}"], ["skip", "{\"skip\":[\"#{SURROGATE}\"]}"]].each do |key, text|
  message = repo_file_error(text).to_s
  check("repo file: lone surrogate in #{key} is invalid",
        message.start_with?(label) && !message.start_with?("unexpected"))
end
check("repo file: reason without content",!repo_file_error('{"required_checks":["secret-check\u0001"]}').include?("secret-check"))

def lines(res)
  res[:out].lines.map(&:chomp)
end

# 想定外の形の呼び出しが無く、GH_REPO を gh に渡していない。writes が false なら書く形も呼んでいない (--check)。
def clean_calls?(res, writes: false)
  !res[:unexpected] && res[:calls].none? { |c| c["has_gh_repo"] } &&
    (writes || res[:calls].none? { |c| c["args"].include?("-X") })
end

# --apply の書き込み ([method, path, body]) を呼んだ順に。
def writes(res)
  res[:calls].select { |c| c["args"].include?("-X") }.map { |c| [c["args"][2], c["args"][3], c["body"]] }
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
res = run_cli(routes_for(public_repo("o/ci"), rules: rules, settings: { "required_checks" => ["test (a)", "test (b)"] }),
              ["--repo", "o/ci"])
check("cli required checks: rc 1", res[:rc] == 1)
check("cli required checks: line", lines(res)[1] ==
  "  - default branch の ruleset: 必須の check: 今 test (a) / あるべき test (a)、test (b) を含む")
res = run_cli(routes_for(public_repo("o/ci"), rules: rules, settings: { "required_checks" => ["test (a)"] }), ["--repo", "o/ci"])
check("cli required checks satisfied", res[:rc] == 0)
# 手元の設定 file の required_checks は読まない (移行は切り替え)。残っていれば gh を呼ばずに止める。
res = run_cli(routes_for(public_repo("o/ci"), rules: rules), ["--repo", "o/ci"],
              config: { "required_checks" => { "o/ci" => ["test (a)", "test (b)"] } })
check("cli local required_checks is refused", res[:rc] == 2 && res[:out].empty? && res[:calls].empty? &&
  res[:err] == "personal-repo-baseline: 設定 file の required_checks は、各 repo の .github/repo-baseline.json に移しました\n")

# ---- CLI: repo の設定 file ----
OMIT_LINE = "  - repo の設定 file (.github/repo-baseline.json) で外した: .github/dependabot.yml"
# skip した dependabot.yml は読まず (route を外しても確かめられないにならない)、外したことを出す。
routes = routes_for(public_repo("o/skip"), settings: { "skip" => ["dependabot_yml"] })
routes.delete("repos/o/skip/contents/.github/dependabot.yml")
routes.delete("repos/o/skip/contents/.github/dependabot.yaml")
res = run_cli(routes, ["--repo", "o/skip"])
check("cli skip: rc 0 with the item omitted", res[:rc] == 0 && lines(res) == ["o/skip (public): ずれ無し", OMIT_LINE, RB::MANUAL_NOTE])
check("cli skip: dependabot.yml is not read", res[:calls].none? { |c| c["args"].last.include?("dependabot.y") } && clean_calls?(res))
check("cli skip: repo file is read from contents API",
      res[:calls].any? { |c| c["args"] == %w[api repos/o/skip/contents/.github/repo-baseline.json] })
# skip しても他の項目のずれは残る。
res = run_cli(routes_for(private_repo("o/skipdrift", "delete_branch_on_merge" => false), yml: 404, settings: { "skip" => ["dependabot_yml"] }),
              ["--repo", "o/skipdrift"])
check("cli skip keeps other drift", res[:rc] == 1 && lines(res)[0, 3] == [
  "o/skipdrift (private): ずれ 1 件", "  - merge の後に branch を消す: 今 off / あるべき on", OMIT_LINE,
])
# file が無い repo は今と同じ (dependabot.yml を確かめる)。
res = run_cli(routes_for(public_repo("o/nofile"), yml: 404), ["--repo", "o/nofile"])
check("cli no repo file: dependabot.yml is checked", res[:rc] == 1 && lines(res)[1] ==
  "  - .github/dependabot.yml (repo ごとの PR で足す。script では書かない): 今 無い / あるべき 有る")
# 不正な repo の file はその repo を確かめられないにする (設定なしやずれ無しに倒さない)。
def repo_file_broken(label, route, expected)
  routes = routes_for(public_repo("o/rf"))
  routes["repos/o/rf/contents/.github/repo-baseline.json"] = route
  res = run_cli(routes, ["--repo", "o/rf"])
  check("cli repo file #{label}", res[:rc] == 2 &&
    lines(res) == ["o/rf: 確かめられない (repo の設定 file (.github/repo-baseline.json) #{expected})"])
end
repo_file_broken("bad skip", repo_file_route('{"skip":["secret_scanning"]}'), "の skip が外せる項目 (dependabot_yml) の空でない配列ではありません")
repo_file_broken("unexpected status", { "status" => 500 }, "の応答が想定外です (HTTP 500)")
repo_file_broken("2xx with gh failure", { "status" => 200, "exit" => 1 }, "を読めません (gh api が失敗)")
repo_file_broken("directory", { "status" => 200, "body" => [] }, "を読めません (応答の形が想定外)")
# 成功の応答の本文が null も、file が無い (404) と取り違えない (pin-check と同じ。#608 の review)
repo_file_broken("null body", { "status" => 200, "body" => nil }, "を読めません (応答の形が想定外)")
repo_file_broken("symlink", repo_file_route("{}", "type" => "symlink"), "を読めません (応答の形が想定外)")
repo_file_broken("not base64", repo_file_route("{}", "encoding" => "none", "content" => ""), "を読めません (応答の形が想定外)")
repo_file_broken("size missing", repo_file_route("{}", "size" => nil), "を読めません (応答の形が想定外)")
repo_file_broken("size negative", repo_file_route("{}", "size" => -1), "を読めません (応答の形が想定外)")
repo_file_broken("too large by size", repo_file_route("{}", "size" => 64 * 1024 + 1), "が大きすぎます")
# size は本文の byte 数と合うことを求める (大きい本文に小さい size を付けても、上限の検査をすり抜けない)。
repo_file_broken("size larger than content", repo_file_route("{}", "size" => 100), "を読めません (size が本文と合わない)")
repo_file_broken("size smaller than content", repo_file_route("{}", "size" => 1), "を読めません (size が本文と合わない)")
repo_file_broken("large content with small size", repo_file_route("{\"skip\":[\"dependabot_yml\"]#{' ' * (64 * 1024)}}", "size" => 2),
                 "を読めません (size が本文と合わない)")
# base64 は厳密に decode する (alphabet の外の文字や padding の誤りを読み飛ばして {} にしない)。
repo_file_broken("corrupt base64", repo_file_route("{}", "content" => "e!30=", "size" => 2), "を読めません (base64 が壊れている)")
repo_file_broken("base64 without padding", repo_file_route("{}", "content" => "e30", "size" => 2), "を読めません (base64 が壊れている)")
# API の base64 は 60 文字ごとに改行が入る。改行は除いて読む。
long = { "required_checks" => ["a-long-check-name (matrix row 1)", "another-long-check-name (matrix row 2)"] }
check("fixture: long repo file is multi-line base64", [JSON.generate(long)].pack("m").count("\n") > 1)
long_rules = GOOD_RULES + [{ "type" => "required_status_checks", "parameters" => {
  "required_status_checks" => long["required_checks"].map { |c| { "context" => c } },
} }]
res = run_cli(routes_for(public_repo("o/long"), rules: long_rules, settings: long), ["--repo", "o/long"])
check("cli repo file with multi-line base64", res[:rc] == 0 && lines(res).first == "o/long (public): ずれ無し")
# 不正な UTF-8 になる repo の設定 file でも、--all はその repo を確かめられないにして次の repo を続ける。
list = [public_repo("o/a-sur"), public_repo("o/b-ok")]
routes = routes_for(list[0], settings: "{\"required_checks\":[\"#{SURROGATE}\"]}").merge(routes_for(list[1]))
routes[RB::LIST_PATH] = { "status" => 200, "body" => list }
res = run_cli(routes, ["--all"])
check("cli all: broken repo file does not stop the run", res[:rc] == 2 && res[:err].empty? &&
  lines(res)[0].start_with?("o/a-sur: 確かめられない (repo の設定 file (.github/repo-baseline.json) ") &&
  lines(res)[1] == "o/b-ok (public): ずれ無し" &&
  lines(res)[2] == "対象の repo: 2 件 (ずれ無し 1・ずれ有り 0・確かめられない 1) / 対象外: fork 0 件・archive 済み 0 件・設定 file で除外 0 件")
# 確かめる途中で止まっても、repo の設定 file を読めていれば外した項目を出す。
res = run_cli(routes_for(public_repo("o/skiperr"), alerts: 403, settings: { "skip" => ["dependabot_yml"] }), ["--repo", "o/skiperr"])
check("cli skip with a repo error keeps the omitted line", res[:rc] == 2 && lines(res) == [
  "o/skiperr: 確かめられない (Dependabot alerts の応答が想定外です (HTTP 403))", OMIT_LINE,
])
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
fake.define_singleton_method(:repo_settings) { |_name| RB::NO_SETTINGS }
fake.define_singleton_method(:collect_facts) { |*_args| raise TypeError, "boom" }
r = begin
  fake.check_repo("o/boom", RB.parse_config(nil))
rescue StandardError => e
  e
end
check("check_repo turns TypeError into a repo error",
      r.is_a?(RB::Result) && r.status == :error && r.reason == "応答の形が想定外です (TypeError)")
# --apply の確かめ直しで ArgumentError が出ても、書いた項目を添えて止める (書いた範囲を失わない)。
fake2 = RB.clone
fake2.define_singleton_method(:gh_write) { |_action| nil }
fake2.define_singleton_method(:read_repo) { |name| public_repo(name) }
fake2.define_singleton_method(:collect_facts) { |*_args| raise ArgumentError, "invalid byte sequence" }
# 想定外の例外は test を止めずに assertion で落とす (捕まえ損ねた例外も、どの check かが出るように)。
apply_err = begin
  fake2.apply_fixes("o/reverify", "public", [["delete_branch_on_merge", false, true]], RB::NO_SETTINGS)
  nil
rescue RB::ApplyError => e
  e
rescue StandardError => e
  e
end
check("apply re-read ArgumentError keeps written",
      apply_err.is_a?(RB::ApplyError) && apply_err.message == "確かめ直せません: 応答の形が想定外です (ArgumentError)" &&
      apply_err.written == %w[delete_branch_on_merge])
# 不正な UTF-8 の文字列への strip・正規表現 (ArgumentError) や encoding の不一致 (EncodingError) も同じ。
[ArgumentError, Encoding::CompatibilityError].each do |klass|
  fake.define_singleton_method(:collect_facts) { |*_args| raise klass, "boom" }
  r = begin
    fake.check_repo("o/boom", RB.parse_config(nil))
  rescue StandardError => e
    e
  end
  check("check_repo turns #{klass} into a repo error",
        r.is_a?(RB::Result) && r.status == :error && r.reason == "応答の形が想定外です (#{klass})")
end

# ---- CLI: branch の rule は全ページを読む ----
# 2 ページ目に approve 2 の PR の rule がある (最初のページだけ読むと見落とす)。
routes = routes_for(public_repo("o/rulepages"))
routes["repos/o/rulepages/rules/branches/main?per_page=100"] = {
  "status" => 200,
  "pages" => [GOOD_RULES, [{ "type" => "pull_request", "parameters" => { "required_approving_review_count" => 2 } }]],
}
res = run_cli(routes, ["--repo", "o/rulepages"])
check("cli rules from all pages", res[:rc] == 1 && lines(res)[1] ==
  "  - default branch の ruleset: PR を必須にする: 今 有る (必要な approve 2) / あるべき 有る (必要な approve 0)")

# branch の名前は 1 つの path の成分に encode する。`.` / `..` は受けない。
routes = routes_for(public_repo("o/rel", "default_branch" => "release/1.0"))
routes["repos/o/rel/rules/branches/release%2F1.0?per_page=100"] = { "status" => 200, "body" => GOOD_RULES }
res = run_cli(routes, ["--repo", "o/rel"])
check("cli branch with slash is encoded", res[:rc] == 0 &&
  res[:calls].any? { |c| c["args"].last == "repos/o/rel/rules/branches/release%2F1.0?per_page=100" })
%w[. ..].each do |branch|
  res = run_cli(routes_for(public_repo("o/dot", "default_branch" => branch)), ["--repo", "o/dot"])
  check("cli default branch #{branch} is refused", res[:rc] == 2 &&
    lines(res) == ["o/dot: 確かめられない (default branch を読めません (応答の形が想定外))"] &&
    res[:calls].none? { |c| c["args"].last.include?("/rules/") })
end

# ---- CLI: status 行が 2xx でも gh が失敗したら確かめられない ----
routes = routes_for(public_repo("o/halfyml"))
routes["repos/o/halfyml/contents/.github/dependabot.yml"] = { "status" => 200, "exit" => 1 }
res = run_cli(routes, ["--repo", "o/halfyml"])
check("cli 2xx with gh failure is error", res[:rc] == 2 &&
  lines(res) == ["o/halfyml: 確かめられない (.github/dependabot.yml を読めません (gh api が失敗))"])
routes = routes_for(public_repo("o/halfalerts"))
routes["repos/o/halfalerts/vulnerability-alerts"] = { "status" => 204, "exit" => 1 }
res = run_cli(routes, ["--repo", "o/halfalerts"])
check("cli 204 with gh failure is error", res[:rc] == 2 &&
  lines(res) == ["o/halfalerts: 確かめられない (Dependabot alerts を読めません (gh api が失敗))"])

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
check("cli all: list failure", res[:rc] == 2 && res[:out].empty? && res[:err] == "personal-repo-baseline: repo の一覧 (user/repos) を読めません (gh api が失敗)\n")
routes[RB::LIST_PATH] = { "status" => 200, "pages" => list_page1 }
res = run_cli(routes, ["--all"])
check("cli all: list pages must be arrays", res[:rc] == 2 && res[:err] == "personal-repo-baseline: repo の一覧 (user/repos) を読めません (応答の形が想定外)\n")

# ---- CLI: 設定 file ----
res = run_cli(routes_for(public_repo("o/good")), ["--repo", "o/good"], config: { "exclude" => ["hidden-owner/hidden-name"], "x" => 1 })
check("cli bad config: rc 2", res[:rc] == 2 && res[:out].empty?)
check("cli bad config: no gh calls", res[:calls].empty?)
check("cli bad config: reason without content", res[:err].include?("知らない key") && !res[:err].include?("hidden"))
res = run_cli(routes_for(public_repo("o/good")), ["--repo", "o/good"], config: "{")
check("cli config not json", res[:rc] == 2 && res[:err].include?("JSON として読めません"))
res = run_cli(routes_for(public_repo("o/good")), ["--repo", "o/good"],
              config: '{"required_checks":{"o/good":["security"],"o/good":["test"]}}')
check("cli config duplicate key", res[:rc] == 2 && res[:out].empty? && res[:calls].empty? &&
  res[:err] == "personal-repo-baseline: 設定 file に重なった key があります\n")
home = File.join(TMP, "home")
FileUtils.mkdir_p(File.join(home, ".config", "agent-tools"))
File.write(File.join(home, ".config", "agent-tools", "repo-baseline.json"), JSON.generate("exclude" => ["o/viahome"]))
res = run_cli({}, ["--repo", "o/viahome"], env: { "XDG_CONFIG_HOME" => "relative/dir", "HOME" => home })
check("cli relative XDG_CONFIG_HOME falls back to HOME", lines(res) == ["o/viahome: 対象外 (設定 file で除外)"])
dirconf = File.join(TMP, "dirconf")
FileUtils.mkdir_p(File.join(dirconf, "agent-tools", "repo-baseline.json"))
res = run_cli({}, ["--repo", "o/x"], env: { "XDG_CONFIG_HOME" => dirconf })
check("cli config not regular file", res[:rc] == 2 && res[:err].include?("regular file ではありません"))

# ---- fix_actions (純粋) ----
check("fix_actions: dependabot.yml only has no write", RB.fix_actions("o/r", %w[dependabot_yml], [], nil) == [])
acts = RB.fix_actions("o/r", %w[dependabot_security_updates merge_methods dependabot_alerts], [], nil)
check("fix_actions: alerts before security updates", acts.map(&:label) == ["Dependabot alerts", "Dependabot security updates", "merge の設定"])
acts = RB.fix_actions("o/r", %w[ruleset_deletion], [], 12)
check("fix_actions: existing ruleset is updated", acts.map { |a| [a.method, a.path] } == [["PUT", "repos/o/r/rulesets/12"]])

# ---- CLI: --apply ----
EXPECTED_PR_RULE = {
  "type" => "pull_request",
  "parameters" => {
    "dismiss_stale_reviews_on_push" => false, "require_code_owner_review" => false, "require_last_push_approval" => false,
    "required_approving_review_count" => 0, "required_review_thread_resolution" => false,
  },
}.freeze
def expected_ruleset(checks = [])
  rules = [EXPECTED_PR_RULE, { "type" => "non_fast_forward" }, { "type" => "deletion" }]
  unless checks.empty?
    rules << { "type" => "required_status_checks", "parameters" => {
      "strict_required_status_checks_policy" => false, "required_status_checks" => checks.map { |c| { "context" => c } },
    } }
  end
  {
    "name" => "personal-repo-baseline", "target" => "branch", "enforcement" => "active", "bypass_actors" => [],
    "conditions" => { "ref_name" => { "include" => ["~DEFAULT_BRANCH"], "exclude" => [] } }, "rules" => rules,
  }
end
GOOD_FIXES = { "status" => 200, "body" => { "enabled" => true, "paused" => false } }.freeze
MERGE_BODY = {
  "allow_squash_merge" => true, "allow_merge_commit" => false, "allow_rebase_merge" => false, "delete_branch_on_merge" => true,
}.freeze
def rulesets_route(name, list)
  { "repos/#{name}/rulesets?includes_parents=false&per_page=100" => { "status" => 200, "body" => list } }
end

# 今の agent-tools と同じずれ。他の名前の ruleset は持ち主でないので触らず、新しく作る。
before = public_repo("o/ap", "allow_merge_commit" => true, "allow_rebase_merge" => true, "delete_branch_on_merge" => false)
routes = routes_for(before, rules: [], alerts: 404, fixes: false).merge(rulesets_route("o/ap", [{ "id" => 7, "name" => "someone-else" }]))
routes["__writes__"] = {
  "PUT repos/o/ap/vulnerability-alerts" => { "status" => 204, "set" => { "repos/o/ap/vulnerability-alerts" => { "status" => 204 } } },
  "PUT repos/o/ap/automated-security-fixes" => { "status" => 204, "set" => { "repos/o/ap/automated-security-fixes" => GOOD_FIXES } },
  "PATCH repos/o/ap" => { "status" => 200, "set" => { "repos/o/ap" => { "status" => 200, "body" => public_repo("o/ap") } } },
  "POST repos/o/ap/rulesets" => {
    "status" => 201, "set" => { "repos/o/ap/rules/branches/main?per_page=100" => { "status" => 200, "body" => GOOD_RULES } },
  },
}
res = run_cli(routes, ["--apply", "--repo", "o/ap"])
check("apply: rc 0", res[:rc] == 0)
check("apply: lines", lines(res) == [
  "o/ap (public): 直した 7 件 (ずれ無し)",
  "  - 直した: Dependabot alerts (dependency graph を含む)",
  "  - 直した: Dependabot security updates",
  "  - 直した: merge の方式",
  "  - 直した: merge の後に branch を消す",
  "  - 直した: default branch の ruleset: PR を必須にする",
  "  - 直した: default branch の ruleset: force push の禁止",
  "  - 直した: default branch の ruleset: 削除の禁止",
  RB::MANUAL_NOTE,
])
check("apply: writes in order", writes(res) == [
  ["PUT", "repos/o/ap/vulnerability-alerts", nil],
  ["PUT", "repos/o/ap/automated-security-fixes", nil],
  ["PATCH", "repos/o/ap", MERGE_BODY],
  ["POST", "repos/o/ap/rulesets", expected_ruleset],
])
check("apply: clean calls", clean_calls?(res, writes: true))

# ずれの無い repo には書かない (何度実行しても同じ結果)。ruleset の一覧も読まない。
res = run_cli(routes_for(public_repo("o/same")), ["--apply", "--repo", "o/same"])
check("apply: no drift no write", res[:rc] == 0 && lines(res) == ["o/same (public): ずれ無し", RB::MANUAL_NOTE] &&
  clean_calls?(res) && res[:calls].none? { |c| c["args"].last.include?("/rulesets") })

# 持ち主の ruleset が有れば更新し、repo の設定 file の必須の check を入れる。
checks_rules = GOOD_RULES + [{ "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "context" => "test (a)" }] } }]
routes = routes_for(public_repo("o/rs"), settings: { "required_checks" => ["test (a)"] })
         .merge(rulesets_route("o/rs", [{ "id" => 3, "name" => "other" }, { "id" => 12, "name" => "personal-repo-baseline" }]))
routes["__writes__"] = {
  "PUT repos/o/rs/rulesets/12" => {
    "status" => 200, "set" => { "repos/o/rs/rules/branches/main?per_page=100" => { "status" => 200, "body" => checks_rules } },
  },
}
res = run_cli(routes, ["--apply", "--repo", "o/rs"])
check("apply ruleset update: rc 0", res[:rc] == 0 && lines(res)[0, 2] == [
  "o/rs (public): 直した 1 件 (ずれ無し)", "  - 直した: default branch の ruleset: 必須の check",
])
check("apply ruleset update: body", writes(res) == [["PUT", "repos/o/rs/rulesets/12", expected_ruleset(["test (a)"])]])

# private: ruleset と secret scanning は書かない。dependabot.yml は直さずに残る。
routes = routes_for(private_repo("o/pv", "delete_branch_on_merge" => false), yml: 404)
routes["__writes__"] = { "PATCH repos/o/pv" => { "status" => 200, "set" => { "repos/o/pv" => { "status" => 200, "body" => private_repo("o/pv") } } } }
res = run_cli(routes, ["--apply", "--repo", "o/pv"])
check("apply private: rc 1 with remaining drift", res[:rc] == 1)
check("apply private: lines", lines(res) == [
  "o/pv (private): 直した 1 件 / 残りのずれ 1 件",
  "  - 直した: merge の後に branch を消す",
  "  - .github/dependabot.yml (repo ごとの PR で足す。script では書かない): 今 無い / あるべき 有る",
  RB::UNAVAILABLE_NOTE,
  RB::MANUAL_NOTE,
])
check("apply private: only merge settings written", writes(res) == [["PATCH", "repos/o/pv", MERGE_BODY]] &&
  res[:calls].none? { |c| c["args"].last.include?("/rules") })

# skip した dependabot.yml は、確かめ直しでも読まない。外した項目しか残らなければ直し終えた (exit 0)。
routes = routes_for(private_repo("o/pskip", "delete_branch_on_merge" => false), settings: { "skip" => ["dependabot_yml"] })
routes.delete("repos/o/pskip/contents/.github/dependabot.yml")
routes.delete("repos/o/pskip/contents/.github/dependabot.yaml")
routes["__writes__"] = { "PATCH repos/o/pskip" => { "status" => 200, "set" => { "repos/o/pskip" => { "status" => 200, "body" => private_repo("o/pskip") } } } }
res = run_cli(routes, ["--apply", "--repo", "o/pskip"])
check("apply skip: fixed with the item omitted", res[:rc] == 0 && lines(res)[0, 3] == [
  "o/pskip (private): 直した 1 件 (ずれ無し)", "  - 直した: merge の後に branch を消す", OMIT_LINE,
])
# repo の設定 file は 1 回だけ読む (status と中身で gh を 2 回)。確かめ直しでは読み直さない。
check("apply skip: repo file is read once and dependabot.yml never",
      res[:calls].count { |c| c["args"].last.include?("repo-baseline.json") } == 2 &&
      res[:calls].none? { |c| c["args"].last.include?("dependabot.y") })

# --apply の書き込みが失敗しても、外した項目を出す。
routes = routes_for(public_repo("o/askip", "delete_branch_on_merge" => false), settings: { "skip" => ["dependabot_yml"] })
res = run_cli(routes, ["--apply", "--repo", "o/askip"])
check("apply skip with a write failure keeps the omitted line", res[:rc] == 2 && lines(res) == [
  "o/askip: 確かめられないか直せない (直せません: merge の設定 (gh api が失敗))", OMIT_LINE,
])

# public の secret scanning は security_and_analysis を PATCH する。
sec_off = { "secret_scanning" => { "status" => "disabled" }, "secret_scanning_push_protection" => { "status" => "disabled" } }
routes = routes_for(public_repo("o/sec", "security_and_analysis" => sec_off))
routes["__writes__"] = { "PATCH repos/o/sec" => { "status" => 200, "set" => { "repos/o/sec" => { "status" => 200, "body" => public_repo("o/sec") } } } }
res = run_cli(routes, ["--apply", "--repo", "o/sec"])
check("apply secret scanning", res[:rc] == 0 && writes(res) == [["PATCH", "repos/o/sec", {
  "security_and_analysis" => { "secret_scanning" => { "status" => "enabled" }, "secret_scanning_push_protection" => { "status" => "enabled" } },
}]])

# script が直さないずれ (dependabot.yml) だけなら書かない。
res = run_cli(routes_for(public_repo("o/yml"), yml: 404), ["--apply", "--repo", "o/yml"])
check("apply unfixable only: no write", res[:rc] == 1 && writes(res).empty? && lines(res)[0] == "o/yml (public): ずれ 1 件")
# 書かないので読み直しもしない (repo を読むのは確かめるときの 1 回だけ)。
check("apply unfixable only: no re-read", res[:calls].count { |c| c["args"] == %w[api repos/o/yml] } == 1)

# 書き込みが途中で失敗したら、それまでに直したものを添えて止め、後の書き込みはしない。
before = public_repo("o/half", "delete_branch_on_merge" => false)
routes = routes_for(before, alerts: 404, fixes: false)
routes["__writes__"] = { "PUT repos/o/half/vulnerability-alerts" => { "status" => 204, "set" => { "repos/o/half/vulnerability-alerts" => { "status" => 204 } } } }
res = run_cli(routes, ["--apply", "--repo", "o/half"])
check("apply write failure: rc 2", res[:rc] == 2 && lines(res) == [
  "o/half: 確かめられないか直せない (直せません: Dependabot security updates (gh api が失敗))",
  "  - 書いた: Dependabot alerts (dependency graph を含む)",
])
check("apply write failure: stops", writes(res).map { |w| w[0, 2] } == [
  ["PUT", "repos/o/half/vulnerability-alerts"], ["PUT", "repos/o/half/automated-security-fixes"],
])

# 書き込みが成功しても読み直してずれが残れば止める (他の ruleset が厳しくしているなど)。
routes = routes_for(public_repo("o/stuck", "delete_branch_on_merge" => false))
routes["__writes__"] = { "PATCH repos/o/stuck" => { "status" => 200 } }
res = run_cli(routes, ["--apply", "--repo", "o/stuck"])
check("apply verify failure", res[:rc] == 2 && lines(res) == [
  "o/stuck: 確かめられないか直せない (直した後もずれが残っています: merge の後に branch を消す)",
  "  - 書いた: merge の後に branch を消す",
])

# 書いた後の読み直しが失敗しても、書いた項目は出す。
routes = routes_for(public_repo("o/reread", "delete_branch_on_merge" => false), alerts: 404)
routes["__writes__"] = {
  "PUT repos/o/reread/vulnerability-alerts" => { "status" => 204, "set" => { "repos/o/reread/vulnerability-alerts" => { "status" => 204 } } },
  "PATCH repos/o/reread" => { "status" => 200, "set" => { "repos/o/reread" => { "status" => 500 } } },
}
res = run_cli(routes, ["--apply", "--repo", "o/reread"])
check("apply re-read failure keeps written", res[:rc] == 2 && lines(res) == [
  "o/reread: 確かめられないか直せない (確かめ直せません: repo を読めません (gh api が失敗))",
  "  - 書いた: Dependabot alerts (dependency graph を含む)",
  "  - 書いた: merge の後に branch を消す",
])

# 持ち主の ruleset の更新は置き換え: repo の設定 file の一覧に無い check (画面で足した lint) は外れる。
old_rules = [EXPECTED_PR_RULE, { "type" => "non_fast_forward" },
             { "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "context" => "ci" }, { "context" => "lint" }] } }]
new_rules = GOOD_RULES + [{ "type" => "required_status_checks", "parameters" => { "required_status_checks" => [{ "context" => "ci" }] } }]
routes = routes_for(public_repo("o/repl"), rules: old_rules, settings: { "required_checks" => ["ci"] })
         .merge(rulesets_route("o/repl", [{ "id" => 5, "name" => "personal-repo-baseline" }]))
routes["__writes__"] = {
  "PUT repos/o/repl/rulesets/5" => { "status" => 200, "set" => { "repos/o/repl/rules/branches/main?per_page=100" => { "status" => 200, "body" => new_rules } } },
}
res = run_cli(routes, ["--apply", "--repo", "o/repl"])
check("apply ruleset update replaces checks with config", res[:rc] == 0 &&
  writes(res) == [["PUT", "repos/o/repl/rulesets/5", expected_ruleset(["ci"])]] &&
  lines(res)[0, 2] == ["o/repl (public): 直した 1 件 (ずれ無し)", "  - 直した: default branch の ruleset: 削除の禁止"])

# 持ち主の ruleset が 2 つあれば、どちらを直すか決められないので書かない。
routes = routes_for(public_repo("o/dup"), rules: []).merge(rulesets_route("o/dup", [
  { "id" => 1, "name" => "personal-repo-baseline" }, { "id" => 2, "name" => "personal-repo-baseline" },
]))
res = run_cli(routes, ["--apply", "--repo", "o/dup"])
check("apply duplicate managed ruleset", res[:rc] == 2 && writes(res).empty? &&
  lines(res) == ["o/dup: 確かめられないか直せない (personal-repo-baseline という名前の ruleset が複数あります)"])

# --all --apply: 直せない repo があっても残りを続ける。
list = [public_repo("o/a-fix", "delete_branch_on_merge" => false), public_repo("o/b-stuck", "delete_branch_on_merge" => false)]
routes = routes_for(list[0]).merge(routes_for(list[1]))
routes[RB::LIST_PATH] = { "status" => 200, "body" => list }
routes["__writes__"] = {
  "PATCH repos/o/a-fix" => { "status" => 200, "set" => { "repos/o/a-fix" => { "status" => 200, "body" => public_repo("o/a-fix") } } },
}
res = run_cli(routes, ["--all", "--apply"])
check("apply all: lines", res[:rc] == 2 && lines(res) == [
  "o/a-fix (public): 直した 1 件 (ずれ無し)",
  "  - 直した: merge の後に branch を消す",
  "o/b-stuck: 確かめられないか直せない (直せません: merge の設定 (gh api が失敗))",
  "対象の repo: 2 件 (ずれ無し 0・直した 1・ずれ有り 0・確かめられないか直せない 1) / 対象外: fork 0 件・archive 済み 0 件・設定 file で除外 0 件",
  RB::MANUAL_NOTE,
])

# ---- CLI: usage ----
res = run_cli({}, ["--check", "--apply"])
check("cli --check --apply is usage error", res[:rc] == 2 && res[:err].include?("usage:") && res[:calls].empty?)
res = run_cli({}, ["--help"])
check("cli help", res[:rc] == 0 && res[:out].start_with?(RB.usage + "\n"))

exit(@failed.zero? ? 0 : 1)
RUBY
echo "ok: repo-baseline"
