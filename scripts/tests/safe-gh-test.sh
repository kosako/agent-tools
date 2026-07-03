#!/bin/sh
# personal-safe-gh.rb の self-test。
# I/O (gh 呼び出し) と分離した純粋 trust/render ロジックを fixture で検証する。
# gh の実挙動は CI 外 (実機手動検証。docs/runtime-injection-defense.md「検証境界」)。
# network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
src="$repo_root/shared/scripts/personal-safe-gh.rb"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -f "$src" ] || { echo "FAIL: missing $src" >&2; exit 1; }

# トラストファイル fixture (self_identity の file 優先パス検証用)。
cat > "$tmp/trust.json" <<'EOF'
{"login": "owner-login", "id": 4242}
EOF

ruby - "$src" "$tmp/trust.json" <<'RUBY'
require ARGV[0]
trust_file = ARGV[1]

@failed = 0
def check(name, cond)
  if cond
    # pass
  else
    warn "FAIL: #{name}"
    @failed += 1
  end
end

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

# ---- 引数バリデーション ----
check("valid invocation", SafeGh.valid_invocation?("issue", "view", "12"))
check("invalid number", !SafeGh.valid_invocation?("issue", "view", "abc"))
check("invalid noun", !SafeGh.valid_invocation?("foo", "view", "1"))
check("invalid verb", !SafeGh.valid_invocation?("issue", "bogus", "1"))
check("missing number", !SafeGh.valid_invocation?("issue", "view", nil))

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

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: safe-gh self-test passed"
