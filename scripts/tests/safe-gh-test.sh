#!/bin/sh
# personal-safe-gh.rb の self-test。
# I/O (gh 呼び出し) と分離した純粋 trust/render ロジックを fixture で検証する。
# gh の実挙動は CI 外 (実機手動検証。docs/runtime-injection-defense.md「検証境界」)。
# network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-safe-gh.rb"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -f "$src" ] || { echo "FAIL: missing $src" >&2; exit 1; }

# トラストファイル fixture (self_identity の file 優先パス検証用)。
cat > "$tmp/trust.json" <<'EOF'
{"login": "owner-login", "id": 4242}
EOF

# check / @failed は lib/check_helper.rb を -r で読み込んで共有する。
ruby -r"$script_dir/lib/check_helper" - "$src" "$tmp/trust.json" <<'RUBY'
require ARGV[0]
trust_file = ARGV[1]

ME = { "login" => "me", "id" => 1 }

# ---- classify ----
check("self by id", SafeGh.classify({ "login" => "me", "id" => 1 }, ME) == "self")
# id が一致すれば login 変更後でも self (numeric id 最優先)
check("self by id despite login rename", SafeGh.classify({ "login" => "renamed", "id" => 1 }, ME) == "self")
# id が無いときだけ login 照合
check("self by login when no id", SafeGh.classify({ "login" => "me" }, { "login" => "me" }) == "self")
check("other by different id", SafeGh.classify({ "login" => "me", "id" => 2 }, ME) == "other")
check("other by different login no id", SafeGh.classify({ "login" => "x" }, { "login" => "me" }) == "other")
check("bot by login suffix", SafeGh.classify({ "login" => "dependabot[bot]", "id" => 9 }, ME) == "bot")
check("bot by type", SafeGh.classify({ "login" => "svc", "type" => "Bot", "id" => 9 }, ME) == "bot")
# bot は self id と一致しても bot 優先 (association/self より先に評価)
check("bot precedence over self", SafeGh.classify({ "login" => "x[bot]", "id" => 1 }, ME) == "bot")
# self を確定できない (me=nil) なら全 untrusted (fail-closed)
check("fail-closed when self unknown", SafeGh.classify({ "login" => "me", "id" => 1 }, nil) == "other")
# ghost (user 欠落) は other
check("nil user is other", SafeGh.classify(nil, ME) == "other")

# ---- issue_envelope: self ----
self_issue = {
  "number" => 7, "state" => "open", "title" => "my title", "body" => "my body",
  "user" => { "login" => "me", "id" => 1 }, "author_association" => "OWNER",
  "labels" => [{ "name" => "bug" }, { "name" => "p1" }],
}
env = SafeGh.issue_envelope("issue", "o/r", self_issue, ME)
check("self issue trust", env["author_trust"] == "self")
check("self issue includes title", env["title"] == "my title")
check("self issue includes body", env["body"] == "my body")
check("self issue body_trust", env["body_trust"] == "self")
check("self issue labels", env["labels"] == %w[bug p1])
check("self issue no excluded flag", !env.key?("excluded_body"))

# ---- issue_envelope: other (本文を渡さない・title すら渡さない) ----
other_issue = {
  "number" => 8, "state" => "open", "title" => "ATTACKER_TITLE_SENTINEL",
  "body" => "ATTACKER_BODY_SENTINEL",
  "user" => { "login" => "attacker", "id" => 999 }, "author_association" => "NONE",
  "labels" => [{ "name" => "question" }],
}
env = SafeGh.issue_envelope("issue", "o/r", other_issue, ME)
check("other issue trust", env["author_trust"] == "other")
check("other issue no title key", !env.key?("title"))
check("other issue no body key", !env.key?("body"))
check("other issue excluded_body", env["excluded_body"] == true)
check("other issue body_trust untrusted", env["body_trust"] == "untrusted")
# author/state/number/labels は metadata として渡す (決定 4)
check("other issue author metadata", env["author"] == "attacker")
check("other issue labels metadata", env["labels"] == %w[question])
# title/body の中身は JSON 出力に一切現れない
json = JSON.generate(env)
check("other issue title not leaked", !json.include?("ATTACKER_TITLE_SENTINEL"))
check("other issue body not leaked", !json.include?("ATTACKER_BODY_SENTINEL"))

# ---- issue_envelope: bot ----
bot_issue = {
  "number" => 9, "state" => "open", "title" => "t", "body" => "b",
  "user" => { "login" => "renovate[bot]", "id" => 5, "type" => "Bot" },
  "author_association" => "NONE", "labels" => [],
}
env = SafeGh.issue_envelope("pr", "o/r", bot_issue, ME)
check("bot issue trust", env["author_trust"] == "bot")
check("bot issue no body", !env.key?("body"))
check("bot issue source pr", env["source"] == "pr")

# ---- labels: envelope に残る唯一の free-text metadata。制御文字除去・長さ制限・非文字列除外 ----
ctrl_issue = {
  "number" => 10, "state" => "open", "title" => "t", "body" => "b",
  "user" => { "login" => "attacker", "id" => 999 }, "author_association" => "NONE",
  "labels" => [
    { "name" => "ok-label" },
    { "name" => "evil\nok: fake success line\e[31m" },
    { "name" => 123 },
    { "name" => "L" * 300 },
  ],
}
env = SafeGh.issue_envelope("issue", "o/r", ctrl_issue, ME)
check("labels keep plain name", env["labels"].include?("ok-label"))
check("labels contain no control chars", env["labels"].none? { |l| l =~ /[[:cntrl:]]/ })
check("labels drop non-string name", env["labels"].none? { |l| !l.is_a?(String) })
check("labels are length-capped", env["labels"].all? { |l| l.length <= 100 })
json = JSON.generate(env)
check("label escape sequence not in JSON output", !json.include?("\\u001b") && !json.include?("\\n"))

# ---- comments_envelope: self 通過 / other・bot 除外 (count のみ・著者名も漏らさない) ----
comments = [
  { "user" => { "login" => "me", "id" => 1 }, "body" => "MY_COMMENT" },
  { "user" => { "login" => "attacker", "id" => 999 }, "body" => "EVIL_COMMENT_SENTINEL" },
  { "user" => { "login" => "spam[bot]", "type" => "Bot" }, "body" => "BOT_SENTINEL" },
]
env = SafeGh.comments_envelope("issue", "o/r", 8, comments, ME)
check("comments included count", env["comments"].length == 1)
check("comments self body included", env["comments"][0]["body"] == "MY_COMMENT")
check("comments self author", env["comments"][0]["author"] == "me")
check("comments excluded count", env["excluded_comments_count"] == 2)
check("comments excluded reason present", !env["excluded_comments_reason"].nil?)
json = JSON.generate(env)
check("excluded comment body not leaked", !json.include?("EVIL_COMMENT_SENTINEL"))
check("excluded bot body not leaked", !json.include?("BOT_SENTINEL"))
check("excluded comment author not leaked", !json.include?("attacker"))
check("excluded bot author not leaked", !json.include?("spam[bot]"))

# 除外が無いときは reason を付けない
env = SafeGh.comments_envelope("issue", "o/r", 8, [comments[0]], ME)
check("no excluded -> no reason", !env.key?("excluded_comments_reason"))
check("no excluded -> count 0", env["excluded_comments_count"] == 0)

# ---- inline review comments は comments_envelope 共用 (source だけ pr_review_comments) (#189(3)) ----
env = SafeGh.comments_envelope("pr_review", "o/r", 8, comments, ME)
check("review comments source", env["source"] == "pr_review_comments")
check("review comments same trust filtering", env["comments"].length == 1 && env["excluded_comments_count"] == 2)

# self の inline comment でも body 以外の PR 由来 metadata (path/line/diff_hunk = fork PR では
# attacker 制御の free-text) を出力に載せない (allowlist 構築の回帰 pin)
inline_self = [{
  "user" => { "login" => "me", "id" => 1 }, "body" => "MY_INLINE",
  "path" => "EVIL_PATH_SENTINEL.rb", "line" => 42, "diff_hunk" => "EVIL_HUNK_SENTINEL",
}]
env = SafeGh.comments_envelope("pr_review", "o/r", 8, inline_self, ME)
check("self inline body included", env["comments"][0]["body"] == "MY_INLINE")
json = JSON.generate(env)
check("inline path not leaked", !json.include?("EVIL_PATH_SENTINEL"))
check("inline diff_hunk not leaked", !json.include?("EVIL_HUNK_SENTINEL"))
check("inline comment keys are allowlisted", env["comments"][0].keys.sort == %w[author author_trust body])

# ---- reviews_envelope: self は state+body / other・bot は count + state 内訳のみ (#189(3)) ----
reviews = [
  { "user" => { "login" => "me", "id" => 1 }, "state" => "COMMENTED", "body" => "MY_REVIEW" },
  { "user" => { "login" => "attacker", "id" => 999 }, "state" => "CHANGES_REQUESTED",
    "body" => "EVIL_REVIEW_SENTINEL" },
  { "user" => { "login" => "spam[bot]", "type" => "Bot" }, "state" => "APPROVED",
    "body" => "BOT_REVIEW_SENTINEL" },
  { "user" => { "login" => "attacker2", "id" => 998 }, "state" => "INJECTED_STATE\nok: fake",
    "body" => "x" },
]
env = SafeGh.reviews_envelope("o/r", 12, reviews, ME)
check("reviews source", env["source"] == "pr_reviews")
check("reviews included count", env["reviews"].length == 1)
check("reviews self body included", env["reviews"][0]["body"] == "MY_REVIEW")
check("reviews self state kept", env["reviews"][0]["state"] == "COMMENTED")
check("reviews excluded count", env["excluded_reviews_count"] == 3)
check("reviews excluded state breakdown",
      env["excluded_review_states"] == { "CHANGES_REQUESTED" => 1, "APPROVED" => 1, "other" => 1 })
check("reviews excluded reason present", !env["excluded_reviews_reason"].nil?)
json = JSON.generate(env)
check("excluded review body not leaked", !json.include?("EVIL_REVIEW_SENTINEL"))
check("excluded bot review body not leaked", !json.include?("BOT_REVIEW_SENTINEL"))
check("excluded review author not leaked", !json.include?("attacker"))
# 未知 state (attacker が API 外の値を混ぜた将来ケース) は free-text として出力に現れない
check("unknown review state not leaked", !json.include?("INJECTED_STATE"))

# 除外が無いときは state 内訳・reason を付けない
env = SafeGh.reviews_envelope("o/r", 12, [reviews[0]], ME)
check("no excluded reviews -> no states key", !env.key?("excluded_review_states"))
check("no excluded reviews -> no reason", !env.key?("excluded_reviews_reason"))
check("no excluded reviews -> count 0", env["excluded_reviews_count"] == 0)

# self review でも state は whitelist を通す (未知 enum を素通ししない)
env = SafeGh.reviews_envelope("o/r", 12,
                              [{ "user" => { "login" => "me", "id" => 1 }, "state" => "WEIRD", "body" => "b" }], ME)
check("self review unknown state whitelisted to other", env["reviews"][0]["state"] == "other")

# ---- self_identity: override file 優先 (gh を呼ばない) ----
ident = SafeGh.self_identity(env: { "SAFE_GH_TRUST_FILE" => trust_file })
check("self_identity from file login", ident && ident["login"] == "owner-login")
check("self_identity from file id", ident && ident["id"] == 4242)

# ---- id 正規化: trust file に文字列 id を書いても integer 比較で self になる ----
str_id = SafeGh.normalize_identity({ "login" => "me", "id" => "1" })
check("string id normalized to integer", str_id["id"] == 1)
check("self by normalized string id", SafeGh.classify({ "login" => "me", "id" => 1 }, str_id) == "self")
check("integer id passthrough", SafeGh.normalize_identity({ "login" => "me", "id" => 1 })["id"] == 1)
# 非数値 id はそのまま (integer と一致せず fail-closed)
weird = SafeGh.normalize_identity({ "login" => "me", "id" => "abc" })
check("non-numeric id kept (fail-closed)", SafeGh.classify({ "login" => "me", "id" => 1 }, weird) == "other")
# 存在しない file は nil (file パス単体)
check("self_identity file missing -> nil", SafeGh.self_identity_from_file({ "SAFE_GH_TRUST_FILE" => "#{trust_file}.nope" }).nil?)

# ---- pagination: --slurp 出力 (array-of-pages) を flatten して全件返す ----
# gh_capture を stub して 2 ページ分 (--slurp 形式 [[..],[..]]) を返す。
module SafeGh
  def self.gh_capture(args)
    raise "expected --paginate --slurp for comments" unless args.include?("--slurp") && args.include?("--paginate")
    ['[[{"user":{"login":"me","id":1},"body":"c1"}],[{"user":{"login":"me","id":1},"body":"c2"}]]', true]
  end
end
paged = SafeGh.fetch_comments("o/r", 5)
check("paginated comments flattened to 2", paged.length == 2)
check("paginated first comment body", paged[0]["body"] == "c1")
check("paginated second comment body", paged[1]["body"] == "c2")

# ---- fetch path: review comments / reviews は pulls 側 endpoint を paginate 付きで叩く (#189(3)) ----
module SafeGh
  def self.gh_capture(args)
    @last_args = args
    ["[[]]", true]
  end

  def self.last_args
    @last_args
  end
end
SafeGh.fetch_review_comments("o/r", 7)
check("review comments endpoint", SafeGh.last_args.include?("repos/o/r/pulls/7/comments"))
check("review comments paginated", SafeGh.last_args.include?("--paginate") && SafeGh.last_args.include?("--slurp"))
SafeGh.fetch_reviews("o/r", 7)
check("reviews endpoint", SafeGh.last_args.include?("repos/o/r/pulls/7/reviews"))
check("reviews paginated", SafeGh.last_args.include?("--paginate") && SafeGh.last_args.include?("--slurp"))

# ---- 引数バリデーション ----
check("valid invocation", SafeGh.valid_invocation?("issue", "view", "12"))
check("invalid number", !SafeGh.valid_invocation?("issue", "view", "abc"))
check("invalid noun", !SafeGh.valid_invocation?("foo", "view", "1"))
check("invalid verb", !SafeGh.valid_invocation?("issue", "bogus", "1"))
check("missing number", !SafeGh.valid_invocation?("issue", "view", nil))
# review-comments / reviews は pr 専用 (issue には無い endpoint = fail-closed) (#189(3))
check("pr review-comments valid", SafeGh.valid_invocation?("pr", "review-comments", "1"))
check("pr reviews valid", SafeGh.valid_invocation?("pr", "reviews", "1"))
check("issue reviews invalid", !SafeGh.valid_invocation?("issue", "reviews", "1"))
check("issue review-comments invalid", !SafeGh.valid_invocation?("issue", "review-comments", "1"))
check("review-comments needs number", !SafeGh.valid_invocation?("pr", "review-comments", "abc"))

# ---- -R フラグ抽出 ----
args = ["-R", "o/r", "issue", "view", "1"]
repo, ok = SafeGh.extract_repo_flag(args)
check("extract -R value", repo == "o/r")
check("extract -R ok", ok == true)
check("extract -R leaves args", args == ["issue", "view", "1"])
args2 = ["issue", "view", "1"]
repo2, ok2 = SafeGh.extract_repo_flag(args2)
check("no -R returns nil repo", repo2.nil?)
check("no -R is ok", ok2 == true)
check("no -R leaves args", args2 == ["issue", "view", "1"])
# 末尾 -R (値欠落) は malformed: 現在 repo へ黙って fallback させない
args3 = ["issue", "view", "1", "-R"]
repo3, ok3 = SafeGh.extract_repo_flag(args3)
check("trailing -R is malformed", ok3 == false)
check("trailing -R repo nil", repo3.nil?)
check("trailing -R removes flag", args3 == ["issue", "view", "1"])

# ---- repo slug の検証 (#270): 明示値と解決値の両方 ----
check("repo slug valid", SafeGh.valid_repo?("owner/repo"))
check("repo slug with dot/dash/underscore", SafeGh.valid_repo?("o-w.n_er/re.po-1"))
check("repo slug nil rejected", !SafeGh.valid_repo?(nil))
check("repo slug empty rejected", !SafeGh.valid_repo?(""))
check("repo slug without slash rejected", !SafeGh.valid_repo?("owner"))
check("repo slug extra segment rejected", !SafeGh.valid_repo?("owner/repo/extra"))
check("repo slug with query rejected", !SafeGh.valid_repo?("owner/repo?x=1"))
check("repo slug with traversal rejected", !SafeGh.valid_repo?("owner/../other"))
check("repo slug with space rejected", !SafeGh.valid_repo?("owner/re po"))

# 明示値: 不正なら gh を呼ばずに Error (現在 repo へ黙って倒さない)
module SafeGh
  def self.gh_capture(_args)
    @resolve_called = true
    ["o/r", true]
  end

  def self.resolve_called?
    @resolve_called ? true : false
  end

  def self.reset_resolve!
    @resolve_called = false
  end
end
SafeGh.reset_resolve!
begin
  SafeGh.resolve_repo("owner/repo/extra")
  check("explicit malformed repo raises", false)
rescue SafeGh::Error
  check("explicit malformed repo raises", true)
end
check("explicit malformed repo does not call gh", !SafeGh.resolve_called?)

SafeGh.reset_resolve!
begin
  SafeGh.resolve_repo("")
  check("empty repo raises instead of falling back", false)
rescue SafeGh::Error
  check("empty repo raises instead of falling back", true)
end
check("empty repo does not fall back to gh", !SafeGh.resolve_called?)

check("valid explicit repo passes through", SafeGh.resolve_repo("owner/repo") == "owner/repo")

# 解決値: gh が返した値が不正なら fail-closed
module SafeGh
  def self.gh_capture(_args)
    [JSON.generate("nameWithOwner" => "not-a-slug", "url" => "https://github.com/not-a-slug"), true]
  end
end
begin
  SafeGh.resolve_repo(nil)
  check("malformed resolved repo raises", false)
rescue SafeGh::Error
  check("malformed resolved repo raises", true)
end

module SafeGh
  def self.gh_capture(_args)
    [JSON.generate("nameWithOwner" => "owner/repo", "url" => "https://github.com/owner/repo") + "\n", true]
  end
end
check("valid resolved repo is used", SafeGh.resolve_repo(nil) == "owner/repo")

# ---- main 経由の契約 (#270): 不正な明示値は usage exit 2 で gh を呼ばない ----
# resolve_repo を直接叩くだけでは main 側の検証を外しても通ってしまうため、CLI 入口で pin する。
module SafeGh
  def self.gh_capture(args)
    (@calls ||= []) << args
    ["", false]
  end

  def self.calls
    @calls ||= []
  end

  def self.reset_calls!
    @calls = []
  end
end

def silently
  orig = $stderr.dup
  $stderr.reopen(File::NULL, "w")
  yield
ensure
  $stderr.reopen(orig)
end

SafeGh.reset_calls!
rc_bad = silently { SafeGh.main(["-R", "owner/repo/extra", "issue", "view", "1"]) }
check("main rejects malformed -R with usage exit 2", rc_bad == 2)
check("main does not call gh for malformed -R", SafeGh.calls.empty?)

SafeGh.reset_calls!
rc_empty = silently { SafeGh.main(["-R", "", "issue", "view", "1"]) }
check("main rejects empty -R with usage exit 2", rc_empty == 2)
check("main does not call gh for empty -R", SafeGh.calls.empty?)

# 余分な引数・連結形の -R・2 個目の -R・`-` で始まる残りの token は usage exit 2 (#429)。黙って無視すると
# 指定した repo ではなく cwd の repo の同じ番号を読む。
[
  ["pr", "view", "12", "--repo=other/repo"],
  ["-Rother/repo", "pr", "view", "12"],
  ["issue", "view", "12", "13"],
  ["pr", "view", "12", "--comments"],
  ["-R", "a/b", "-R", "c/d", "pr", "view", "12"],
].each do |argv|
  SafeGh.reset_calls!
  rc = silently { SafeGh.main(argv) }
  check("main rejects `#{argv.join(' ')}` with usage exit 2 (#429)", rc == 2)
  check("main does not call gh for `#{argv.join(' ')}` (#429)", SafeGh.calls.empty?)
end

# 解決値が不正なら exit 1 (fail-closed) で、対象 API へは到達しない。
module SafeGh
  def self.gh_capture(args)
    (@calls ||= []) << args
    args.include?("user") ? ['{"login":"me","id":1}', true] : ["not-a-slug", true]
  end
end
SafeGh.reset_calls!
rc_resolved = silently { SafeGh.main(["issue", "view", "1"]) }
check("main fails closed on malformed resolved repo", rc_resolved == 1)
check("main does not reach the target API", SafeGh.calls.none? { |a| a.any? { |x| x.to_s.include?("repos/") } })

# ---- github.com 専用 (#721) の純粋な部分 ----
check("host constant is github.com", SafeGh::HOST == "github.com")
# E01〜E04: どの envelope にも host があり、版は "1" のまま
issue_env = SafeGh.issue_envelope("issue", "o/r", self_issue, ME)
comments_env = SafeGh.comments_envelope("issue", "o/r", 7, [], ME)
reviews_env = SafeGh.reviews_envelope("o/r", 7, [], ME)
[issue_env, comments_env, reviews_env].each_with_index do |e, i|
  check("envelope #{i} has host github.com (E01-E03)", e["host"] == "github.com")
  check("envelope #{i} keeps safe_reader_version 1 (E04)", e["safe_reader_version"] == "1")
end
# R02 の url の形: https、host は github.com、port なし、path は nameWithOwner と同じ (大文字小文字は問わない)
check("url github.com matches", SafeGh.github_com_url?("https://github.com/o/r", "o/r"))
check("url case-insensitive path", SafeGh.github_com_url?("https://github.com/O/R", "o/r"))
[nil, "", 7, "not a url", "http://github.com/o/r", "https://github.com:8443/o/r", "https://github.com:443/o/r",
 "https://GITHUB.COM/o/r", "https://ghe.example.invalid/o/r", "https://github.com/x/y", "https://github.com/o/r/extra",
 "https://github.com/o/r?x=1", "https://github.com/o/r#x", "https://api.github.com/o/r", "https://github.com.evil/o/r"].each do |url|
  check("url rejected: #{url.inspect}", !SafeGh.github_com_url?(url, "o/r"))
end
# H07〜H14: 環境の検査
refused = lambda do |env|
  SafeGh.check_host_env!(env)
  false
rescue SafeGh::Refused
  true
end
[{}, { "GH_HOST" => "" }, { "GH_HOST" => "github.com" }, { "GH_REPO" => "o/r" }, { "GH_REPO" => "github.com/o/r" },
 { "GH_REPO" => "" }].each do |env|
  check("host env accepted: #{env.inspect}", !refused.call(env))
end
[{ "GH_HOST" => "ghe.example.invalid" }, { "GH_HOST" => "GITHUB.COM" }, { "GH_HOST" => "https://github.com" },
 { "GH_HOST" => "github.com/" }, { "GH_HOST" => "api.github.com" }, { "GH_HOST" => "github.com:443" },
 { "GH_HOST" => " github.com" }, { "GH_REPO" => "ghe.example.invalid/o/r" }, { "GH_REPO" => "https://ghe.example.invalid/o/r" },
 { "GH_REPO" => "GITHUB.COM/o/r" }].each do |env|
  check("host env refused: #{env.inspect}", refused.call(env))
end
# API は github.com に固定し、repo の解決は GH_HOST を外して gh に選ばせる
check("api env pins GH_HOST", SafeGh.gh_env(["api", "--hostname", "github.com", "user"]) == { "GH_HOST" => "github.com" })
check("repo view env unsets GH_HOST", SafeGh.gh_env(["repo", "view"]) == { "GH_HOST" => nil })

exit(@failed.zero? ? 0 : 1)
RUBY

# ---- github.com 専用 (#721) の CLI の契約。fake の gh を PATH に置いて、本物の process として走らせる ----
# fake の gh は、呼ばれた argv と、受け取った GH_HOST・GH_REPO を 1 行の JSON で log に足す。
mkdir -p "$tmp/bin" "$tmp/home"
ruby - "$src" "$tmp" <<'RUBY'
require "json"
require "open3"
require "rbconfig"
src, tmp = ARGV
bin = File.join(tmp, "bin")
log = File.join(tmp, "gh.log")
fake = File.join(bin, "gh")
File.write(fake, <<~FAKE)
  #!#{RbConfig.ruby}
  require "json"
  File.open(#{log.inspect}, "a") { |f| f.puts(JSON.generate("argv" => ARGV, "GH_HOST" => ENV["GH_HOST"], "GH_REPO" => ENV["GH_REPO"])) }
  if ARGV.first == "repo"
    print ENV.fetch("FAKE_REPO_JSON", "")
    exit Integer(ENV.fetch("FAKE_REPO_EXIT", "0"))
  elsif ARGV.include?("user")
    print JSON.generate("login" => "me", "id" => 4242)
  elsif ARGV.any? { |a| a.end_with?("/issues/7") }
    # 別の host で同じ数値の ID を持つ account を模す author (github.com では self と同じ ID)
    print JSON.generate("number" => 7, "state" => "open", "title" => "T-SENTINEL", "body" => "B-SENTINEL",
                        "user" => { "login" => "someone", "id" => 4242 }, "author_association" => "NONE", "labels" => [])
  else
    exit 1
  end
FAKE
File.chmod(0o755, fake)
@failed = 0
def check(name, ok)
  return if ok

  @failed += 1
  warn "FAIL: #{name}"
end
BASE = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "HOME" => File.join(tmp, "home"), "GH_HOST" => nil, "GH_REPO" => nil,
         "GH_ENTERPRISE_TOKEN" => nil, "SAFE_GH_TRUST_FILE" => nil, "FAKE_REPO_JSON" => nil, "FAKE_REPO_EXIT" => nil }.freeze
def run(argv, env = {})
  File.write(LOG, "")
  out, _err, status = Open3.capture3(BASE.merge(env), RbConfig.ruby, SRC, *argv)
  calls = File.read(LOG).lines.map { |l| JSON.parse(l) }
  [status.exitstatus, out, calls]
end
SRC = src
LOG = log
api_ok = ->(calls) { calls.select { |c| c["argv"].first == "api" }.all? { |c| c["argv"][1, 2] == ["--hostname", "github.com"] && c["GH_HOST"] == "github.com" } }
targets = ->(calls) { calls.select { |c| c["argv"].any? { |a| a.start_with?("repos/") } } }
gh_url = JSON.generate("nameWithOwner" => "o/r", "url" => "https://github.com/o/r")
ghe_url = JSON.generate("nameWithOwner" => "o/r", "url" => "https://ghe.example.invalid/o/r")

# H07・H08・S01 と H09〜H13・H14: 別の host を指す環境では、gh を一度も呼ばずに exit 2
["ghe.example.invalid", "GITHUB.COM", "https://github.com", "github.com/", "api.github.com", "github.com:443"].each do |host|
  [["-R", "o/r", "issue", "view", "7"], ["issue", "view", "7"]].each do |argv|
    rc, out, calls = run(argv, "GH_HOST" => host, "FAKE_REPO_JSON" => gh_url)
    check("GH_HOST=#{host} #{argv.join(' ')}: exit 2 (H07-H13)", rc == 2)
    check("GH_HOST=#{host} #{argv.join(' ')}: no gh call", calls.empty?)
    check("GH_HOST=#{host} #{argv.join(' ')}: no body leaked (S01)", !out.include?("B-SENTINEL"))
  end
end
["ghe.example.invalid/o/r", "https://ghe.example.invalid/o/r"].each do |gh_repo|
  [["-R", "o/r", "issue", "view", "7"], ["issue", "view", "7"]].each do |argv|
    rc, _out, calls = run(argv, "GH_REPO" => gh_repo, "FAKE_REPO_JSON" => gh_url)
    check("GH_REPO=#{gh_repo} #{argv.join(' ')}: exit 2 without gh (H14)", rc == 2 && calls.empty?)
  end
end
# H01・H03・H05・H15・H16: github.com を指す環境と -R では、API を github.com に固定して読む
[{}, { "GH_HOST" => "" }, { "GH_HOST" => "github.com" }, { "GH_REPO" => "github.com/o/r" }, { "GH_REPO" => "o/r" },
 { "GH_ENTERPRISE_TOKEN" => "x" }].each do |env|
  rc, out, calls = run(["-R", "o/r", "issue", "view", "7"], env)
  check("#{env.inspect} -R: exit 0 (H01/H03/H05/H15/H16)", rc == 0)
  check("#{env.inspect} -R: api pinned to github.com", !calls.empty? && api_ok.call(calls))
  check("#{env.inspect} -R: no repo view", calls.none? { |c| c["argv"].first == "repo" })
  check("#{env.inspect} -R: envelope host", JSON.parse(out)["host"] == "github.com")
end
# -R なしで GH_REPO があるとき (#799 の review): gh は GH_REPO の宛先を選ぶので、GH_REPO を子 process にそのまま渡し、
# その宛先の url を確かめる。github.com の url なら読み、別 host の url なら読まない
["github.com/o/r", "o/r"].each do |gh_repo|
  rc, _out, calls = run(["issue", "view", "7"], "GH_REPO" => gh_repo, "FAKE_REPO_JSON" => gh_url)
  view = calls.find { |c| c["argv"].first == "repo" }
  check("GH_REPO=#{gh_repo} no -R: exit 0", rc == 0)
  check("GH_REPO=#{gh_repo} no -R: repo view gets GH_REPO", view && view["GH_REPO"] == gh_repo && view["GH_HOST"].nil?)
  rc, _out, calls = run(["issue", "view", "7"], "GH_REPO" => gh_repo, "FAKE_REPO_JSON" => ghe_url)
  check("GH_REPO=#{gh_repo} no -R with other-host url: exit 2 without target", rc == 2 && targets.call(calls).empty?)
end
# H02: -R なしで、gh が github.com の repo を選べば読む。repo view の子 process には GH_HOST を渡さない
rc, _out, calls = run(["issue", "view", "7"], "GH_HOST" => "github.com", "FAKE_REPO_JSON" => gh_url)
view = calls.find { |c| c["argv"].first == "repo" }
check("no -R with github.com repo: exit 0 (H02)", rc == 0)
check("repo view asks for nameWithOwner and url", view && view["argv"] == ["repo", "view", "--json", "nameWithOwner,url"])
check("repo view runs without GH_HOST", view && view["GH_HOST"].nil?)
check("no -R: target api pinned", targets.call(calls).size == 1 && api_ok.call(calls))
# H04・H06・R01・R02: gh が選んだ repo を github.com のものと確かめられなければ、対象を読まずに exit 2
bad_urls = [ghe_url, JSON.generate("nameWithOwner" => "o/r"), JSON.generate("nameWithOwner" => "o/r", "url" => ""),
            JSON.generate("nameWithOwner" => "o/r", "url" => "https://github.com/x/y"),
            JSON.generate("nameWithOwner" => "o/r", "url" => "https://github.com:8443/o/r")]
bad_urls.each do |json|
  [{}, { "GH_HOST" => "" }, { "GH_HOST" => "github.com" }].each do |env|
    rc, out, calls = run(["issue", "view", "7"], env.merge("FAKE_REPO_JSON" => json))
    check("repo #{json} #{env.inspect}: exit 2 (R01/R02)", rc == 2)
    check("repo #{json} #{env.inspect}: target not read", targets.call(calls).empty?)
    check("repo #{json} #{env.inspect}: no body leaked", !out.include?("B-SENTINEL"))
  end
end
# R03: repo を解決できなければ、今までどおり exit 1
rc, _out, calls = run(["issue", "view", "7"], "FAKE_REPO_EXIT" => "1")
check("unresolvable repo: exit 1 (R03)", rc == 1 && targets.call(calls).empty?)
# S02・S03: trust file があれば gh api user を呼ばない。無ければ github.com に固定して呼ぶ
trust = File.join(tmp, "trust.json")
_rc, _out, calls = run(["-R", "o/r", "issue", "view", "7"], "SAFE_GH_TRUST_FILE" => trust)
check("trust file skips gh api user (S02)", calls.none? { |c| c["argv"].include?("user") })
_rc, _out, calls = run(["-R", "o/r", "issue", "view", "7"])
user = calls.find { |c| c["argv"].include?("user") }
check("no trust file calls gh api user pinned (S03)", user && user["argv"][0, 3] == ["api", "--hostname", "github.com"] && user["GH_HOST"] == "github.com")
# N03: host つきの -R は、今までどおり gh を呼ばずに exit 2
rc, _out, calls = run(["-R", "ghe.example.invalid/o/r", "issue", "view", "7"])
check("-R with host: exit 2 without gh (N03)", rc == 2 && calls.empty?)
exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: safe-gh self-test passed"
