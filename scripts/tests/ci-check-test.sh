#!/bin/sh
# personal-ci-check.rb の self-test (#541)。
# 規則の判定 (check_workflow) は require して直接、CLI は tmp の git repo に commit した workflow で確かめる。CLI の
# 出力は personal-repo-audit の findings.schema.json に当て (型・required・additionalProperties・enum)、HEAD の
# commit だけを読む (作業ツリーの未 commit の変更を読まない) ことも確かめる。git の global / system の設定と hook は
# tmp の設定に差し替える。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-ci-check.rb"
schema="$repo_root/shared/skills/personal-repo-audit/findings.schema.json"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -f "$src" ] || fail "missing $src"
[ -f "$schema" ] || fail "missing $schema"

GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_SYSTEM
GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_GLOBAL
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile /dev/null

ruby -r"$script_dir/lib/check_helper" - "$src" "$schema" "$tmp" <<'RUBY'
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"
require "time"
src, schema_path, tmp = ARGV
require src

CC = CiCheck
SCHEMA = JSON.parse(File.read(schema_path))

# ---- 規則の判定 (check_workflow) ----

def check_wf(content, path = ".github/workflows/ci.yml")
  CC.check_workflow(path, content)
end

def file_error(content)
  check_wf(content)
  nil
rescue CC::FileError => e
  e.message
end

def fps(result)
  result[:findings].map { |f| f["fingerprint"] }
end

# timeout の無い job は所見。場所は jobs の key の行、fingerprint は path@job#topic。
r = check_wf(<<~YAML)
  name: ci
  on: push
  jobs:
    build:
      runs-on: ubuntu-latest
      timeout-minutes: 10
      steps: [{ run: "true" }]
    test:
      runs-on: ubuntu-latest
      steps: [{ run: "true" }]
YAML
check("timeout-missing: only the job without timeout-minutes", fps(r) == [".github/workflows/ci.yml@test#timeout-missing"])
f = r[:findings].first
check("timeout-missing: location is the job key line", f["locations"] == [".github/workflows/ci.yml:8"])
check("timeout-missing: kind/severity/confidence/dimension",
      [f["kind"], f["severity"], f["confidence"], f["dimension"]] == ["debt", "medium", "確証", "ci"])
check("timeout-missing: no decision needed", f["needs_decision"] == false && f["decision_reason"] == "")
check("push-only workflow: no concurrency proposal", r[:not_problems].empty?)

# 値が空 (null) の timeout-minutes は無いとみなす。式の値は在るとみなす。
r = check_wf(<<~YAML)
  on: push
  jobs:
    a:
      runs-on: ubuntu-latest
      timeout-minutes:
    b:
      runs-on: ubuntu-latest
      timeout-minutes: ${{ inputs.minutes }}
YAML
check("null timeout-minutes is missing, expression is present", fps(r) == [".github/workflows/ci.yml@a#timeout-missing"])

# reusable workflow を呼ぶ job は timeout を書けないので所見にせず、not_problems に出す。
r = check_wf(<<~YAML)
  on: push
  jobs:
    call:
      uses: ./.github/workflows/reusable.yml
    remote:
      uses: example/other/.github/workflows/x.yml@v1
YAML
check("reusable caller jobs: no finding", r[:findings].empty?)
check("reusable caller jobs: not_problems with the job line",
      r[:not_problems].map { |n| n["location"] } == [".github/workflows/ci.yml:3", ".github/workflows/ci.yml:5"])
check("reusable caller jobs: the uses value is not echoed",
      !JSON.generate(r).include?("example/other"))

# pull_request の workflow に concurrency が無ければ proposal (判断が要る)。
pr_jobs = <<~YAML
  jobs:
    a:
      runs-on: ubuntu-latest
      timeout-minutes: 5
    b:
      runs-on: ubuntu-latest
      timeout-minutes: 5
YAML
r = check_wf("on: [push, pull_request]\n" + pr_jobs)
check("pull_request without concurrency: proposal", fps(r) == [".github/workflows/ci.yml#concurrency-missing"])
f = r[:findings].first
check("concurrency-missing: kind/severity", [f["kind"], f["severity"]] == ["proposal", "low"])
check("concurrency-missing: needs a decision", f["needs_decision"] == true && !f["decision_reason"].empty?)
check("concurrency-missing: location is the file", f["locations"] == [".github/workflows/ci.yml"])

# on の書き方 (文字列・配列・mapping) のどれでも pull_request を読む。
check("on as a string", fps(check_wf("on: pull_request\n" + pr_jobs)) == [".github/workflows/ci.yml#concurrency-missing"])
check("on as a mapping", fps(check_wf("on:\n  pull_request:\n    branches: [main]\n  push:\n" + pr_jobs)) ==
      [".github/workflows/ci.yml#concurrency-missing"])
check("on as a quoted key", fps(check_wf("\"on\": pull_request\n" + pr_jobs)) == [".github/workflows/ci.yml#concurrency-missing"])
check("pull_request_target alone is not pull_request", check_wf("on: pull_request_target\n" + pr_jobs)[:findings].empty?)

# concurrency は top level か、すべての job にあれば足りる。一部の job だけなら proposal。
check("top-level concurrency", check_wf("on: pull_request\nconcurrency: ci-${{ github.ref }}\n" + pr_jobs)[:findings].empty?)
all_jobs = <<~YAML
  on: pull_request
  jobs:
    a:
      runs-on: ubuntu-latest
      timeout-minutes: 5
      concurrency: a-${{ github.ref }}
    b:
      runs-on: ubuntu-latest
      timeout-minutes: 5
      concurrency:
        group: b-${{ github.ref }}
        cancel-in-progress: true
YAML
check("concurrency on every job", check_wf(all_jobs)[:findings].empty?)
some_jobs = all_jobs.sub("    concurrency: a-${{ github.ref }}\n", "")
check("fixture: the job-level concurrency was removed", some_jobs != all_jobs)
check("concurrency on only some jobs: proposal", fps(check_wf(some_jobs)) == [".github/workflows/ci.yml#concurrency-missing"])

# anchor と alias を受け付ける (GitHub が workflow で受け付ける)。日付の literal も読める。
r = check_wf(<<~YAML)
  on: push
  env:
    since: 2026-01-01
  jobs:
    a:
      runs-on: ubuntu-latest
      timeout-minutes: &t 5
    b:
      runs-on: ubuntu-latest
      timeout-minutes: *t
YAML
check("aliases and date literals are accepted", r[:findings].empty?)

# 確かめられない形は FileError (ずれ無しに倒さない)。
check("invalid YAML", file_error("on: [push\njobs: {}\n") == "YAML として読めない (Psych::SyntaxError)")
check("ruby object tag", file_error("on: push\njobs: !ruby/object:Object {}\n") == "明示の tag は読まない")
check("empty file", file_error("") == "YAML の文書が 1 つでない")
# safe_load は先頭の文書しか読まないので、後ろの文書の構文の誤りも、2 つ目の文書も確かめられないにする。
ok_doc = "on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n"
check("a broken second document", file_error(ok_doc + "---\n[\n") == "YAML として読めない (Psych::SyntaxError)")
check("two documents", file_error(ok_doc + "---\n" + ok_doc) == "YAML の文書が 1 つでない")
# 書かれた key と load 後の key が 1 対 1 でない形 (後の値で上書き・解決で衝突・merge key)。
check("duplicate plain on", file_error("on: pull_request\non: push\n" + pr_jobs) == "key が重なる")
check("plain on and quoted on", file_error("on: push\n\"on\": pull_request\n" + pr_jobs) == "key が重なる")
check("on and true collide", file_error("on: push\ntrue: pull_request\n" + pr_jobs) == "key が YAML の解決で重なる")
# 衝突が mapping の最後にあると、並びがずれても後ろに mapping が無い (件数の比較だけが止める)。
check("on and true collide at the end", file_error(pr_jobs + "on: push\ntrue: pull_request\n") == "key が YAML の解決で重なる")
check("duplicate job ids", file_error("on: push\njobs:\n  a:\n    runs-on: x\n  a:\n    runs-on: y\n") == "key が重なる")
check("duplicate nested key", file_error("on: push\njobs:\n  a:\n    timeout-minutes: 5\n    timeout-minutes:\n") == "key が重なる")
check("merge key", file_error("base: &b {runs-on: x}\non: push\njobs:\n  a:\n    <<: *b\n    timeout-minutes: 5\n") ==
      "merge key (<<) は読まない")
check("alias key", file_error("k: &k name\non: push\njobs:\n  a:\n    *k : x\n    timeout-minutes: 5\n") ==
      "mapping の key が scalar でない")
# 明示の tag は型や構造を変えるので、どこにあっても読まない (!!omap の sequence は mapping に読まれ、重なった key が
# 後の値で上書きされる)。
omap = "!!omap\n- on: pull_request\n- on: push\n- jobs:\n    build:\n      runs-on: x\n      timeout-minutes: 5\n"
check("!!omap", file_error(omap) == "明示の tag は読まない")
check("tag on a value", file_error("on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: !!str 5\n") == "明示の tag は読まない")
check("tag on a key", file_error("!!str on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n") == "明示の tag は読まない")
# 深い入れ子は、再帰する読み込みの前に止める (SystemStackError にしない)。workflow の普通の深さは読める。
nested = ->(n) { "on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n    env:\n      X: " + ("[" * n) + ("]" * n) + "\n" }
check("deep nesting", file_error(nested.call(100_000)) == "入れ子が深すぎる (64 段まで)")
check("moderate nesting is read", file_error(nested.call(40)).nil?)
check("top level is a list", file_error("- a\n") == "top level が mapping でない")
check("jobs missing", file_error("on: push\n") == "jobs が mapping でない")
check("jobs empty", file_error("on: push\njobs: {}\n") == "jobs が mapping でない")
check("job id outside the rule", file_error("on: push\njobs:\n  \"bad id\":\n    runs-on: x\n") == "job の名前が規則の外")
check("job id not a string", file_error("on: push\njobs:\n  1:\n    runs-on: x\n") == "job の名前が規則の外")
check("job not a mapping", file_error("on: push\njobs:\n  a: x\n") == "job `a` が mapping でない")
check("on missing", file_error("jobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n") == "on が無い")
# 引用した "on" は文字列のまま、plain の yes は true に読まれる (key は 1 対 1 だが、on として読める key が 2 つ)。
check("on twice (quoted on and yes)", file_error("\"on\": push\nyes: pull_request\njobs:\n  a:\n    runs-on: x\n") == "on が 2 つある")
check("on event not a string", file_error("on: [1]\njobs:\n  a:\n    runs-on: x\n") == "on の event が文字列でない")

# ---- run の記録の判定 (evaluate_events。network なし) ----

# 変換で情報が落ちる job の名前の slug には、元の名前の hash を添える。
SLUG34 = "self-tests-3-4-#{Digest::SHA256.hexdigest('self-tests (3.4)')[0, 6]}"
TIMEOUT_FP = ".github/workflows/test.yml@#{SLUG34}#job-timed-out"
WINDOW = CC.parse_window(%w[--since 2026-10-15T00:00:00Z --until 2026-10-22T00:00:00Z])
check("window parsed", WINDOW[:since_s] == "2026-10-15T00:00:00Z" && WINDOW[:until_s] == "2026-10-22T00:00:00Z")
check("window is (since, until]", !CC.in_window?("2026-10-15T00:00:00Z", WINDOW) && CC.in_window?("2026-10-22T00:00:00Z", WINDOW))

def ev_run(id, path: ".github/workflows/test.yml", event: "pull_request", branch: "feat", conclusion: "success",
           attempt: 1, updated: "2026-10-18T00:00:00Z", status: "completed")
  { "id" => id, "path" => path, "event" => event, "head_branch" => branch, "status" => status,
    "conclusion" => conclusion, "run_attempt" => attempt, "updated_at" => updated }
end

def ev_job(id, name, conclusion, attempt: 1, completed: "2026-10-18T00:00:00Z")
  { "id" => id, "name" => name, "status" => "completed", "conclusion" => conclusion, "run_attempt" => attempt,
    "completed_at" => completed }
end

def ann(level, message)
  { "annotation_level" => level, "message" => message }
end

TIMEOUT_ANN = ann("failure", "The job has exceeded the maximum execution time of 15m0s")
NOT_ACQUIRED = ann("failure", "The job was not acquired by Runner of type hosted even after multiple attempts")
SENTINEL = "SENTINEL-free-text-do-not-echo"
runs = [
  ev_run(1, conclusion: "cancelled", updated: "2026-10-19T00:00:00Z"),                          # timeout
  ev_run(2, attempt: 2), ev_run(3, attempt: 2), ev_run(4, attempt: 2),                          # やり直し
  ev_run(5, attempt: 2),                                                                         # runner を確保できない → やり直し
  ev_run(6, path: "dynamic/dependabot/dependabot-updates", event: "dynamic", conclusion: "cancelled"),
  ev_run(7, event: "push", branch: "main", updated: "2026-10-20T00:00:00Z"),                     # deprecation
  ev_run(8, conclusion: "cancelled", updated: "2026-10-14T12:00:00Z"),                           # 窓の外
  ev_run(9, conclusion: "cancelled", updated: "2026-10-19T00:00:00Z"),                           # 規則の外の job の名前
]
data = {
  runs: runs.select { |r| CC.workflow_run?(r) },
  jobs: {
    1 => [ev_job(11, "self-tests (3.4)", "cancelled", completed: "2026-10-19T00:00:00Z"), ev_job(12, "self-tests (system)", "success")],
    2 => [ev_job(21, "check", "failure"), ev_job(22, "check", "success", attempt: 2), ev_job(23, "lint", "success"),
          ev_job(24, "lint", "success", attempt: 2)],
    3 => [ev_job(31, "check", "failure"), ev_job(32, "check", "success", attempt: 2)],
    4 => [ev_job(41, "other", "failure"), ev_job(42, "other", "success", attempt: 2)],
    5 => [ev_job(51, "bash32 (others)", "cancelled"), ev_job(52, "bash32 (others)", "success", attempt: 2)],
    7 => [ev_job(71, "a", "success", completed: "2026-10-20T00:00:00Z"), ev_job(72, "b", "success", completed: "2026-10-20T00:00:00Z")],
    8 => [ev_job(81, "self-tests (3.4)", "cancelled", completed: "2026-10-14T12:00:00Z")],
    9 => [ev_job(91, "bad\u0007name #{SENTINEL}", "cancelled", completed: "2026-10-19T00:00:00Z")],
  },
  annotations: {
    11 => [TIMEOUT_ANN], 51 => [NOT_ACQUIRED], 91 => [TIMEOUT_ANN],
    71 => [ann("warning", "Node.js 20 is deprecated. The following actions target Node.js 20 #{SENTINEL}"),
           ann("notice", "\"The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026. #{SENTINEL}"),
           ann("notice", "Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times."),
           ann("warning", "This input will be removed in the next major version #{SENTINEL}")],
    72 => [ann("warning", "Node.js 20 is deprecated. The following actions target Node.js 20 #{SENTINEL}")],
  },
  skipped: 0,
}
result = CC.evaluate_events("o/r", "main", WINDOW, data)
by_fp = result[:findings].map { |f| [f["fingerprint"], f] }.to_h
hashed_job = "job-#{Digest::SHA256.hexdigest("bad\u0007name #{SENTINEL}")[0, 8]}"
check("events: fingerprints (#{by_fp.keys.sort.inspect})", by_fp.keys.sort == [
  ".github/workflows/test.yml#deprecation-annotation-#{Digest::SHA256.hexdigest("this input will be removed in the next major version #{SENTINEL}".downcase)[0, 8]}",
  ".github/workflows/test.yml#deprecation-node-20",
  ".github/workflows/test.yml#deprecation-runner-label-ubuntu-latest",
  ".github/workflows/test.yml@#{hashed_job}#job-timed-out",
  ".github/workflows/test.yml@check#flaky-rerun",
  TIMEOUT_FP,
].sort)
t = by_fp[TIMEOUT_FP]
check("timeout: kind/severity/confidence", t && [t["kind"], t["severity"], t["confidence"]] == ["defect", "medium", "確証"])
check("timeout: links the job", t && t["evidence"].include?("https://github.com/o/r/actions/runs/1/job/11") && t["claim"].include?("(1 回)"))
f = by_fp[".github/workflows/test.yml@check#flaky-rerun"]
check("flaky: counts runs, links the passing attempt", f && f["claim"].include?("2 回") &&
      f["evidence"].include?("runs/2/job/22") && f["evidence"].include?("runs/3/job/32"))
check("flaky: a single rerun is only counted", !by_fp.keys.any? { |k| k.include?("@other#") } && result[:summary].include?("1 回だけの job 1 件"))
check("flaky: a cancelled first attempt is not a failure", !by_fp.keys.any? { |k| k.include?("bash32") })
n = by_fp[".github/workflows/test.yml#deprecation-node-20"]
check("deprecation: grouped by kind across jobs", n && n["evidence"].include?("runs/7/job/71") && n["evidence"].include?("runs/7/job/72") &&
      n["claim"].include?("Node.js 20 の deprecation の予告") && n["claim"].include?("(warning)"))
check("deprecation: kind/severity", n && [n["kind"], n["severity"], n["confidence"]] == ["debt", "low", "有力"])
check("events: free text is not echoed", !JSON.generate(result).include?(SENTINEL) && !JSON.generate(result).include?("\u0007"))
check("events: hashed job name", by_fp.key?(".github/workflows/test.yml@#{hashed_job}#job-timed-out") &&
      by_fp[".github/workflows/test.yml@#{hashed_job}#job-timed-out"]["claim"].include?("名前は規則の外"))
check("events: summary counts (#{result[:summary]})",
      result[:summary].include?("timeout に当たった job 2 回") && result[:summary].include?("やり直しで通った job 3 回") &&
        result[:summary].include?("それ以外の cancelled の job 1 回") && result[:summary].include?("deprecation の annotation 3 種類"))
check("events: dynamic and out-of-window runs are ignored", !JSON.generate(result).include?("runs/6/") && !JSON.generate(result).include?("runs/8/"))
missing = data.merge(annotations: data[:annotations].reject { |k, _| k == 11 })
check("events: a cancelled job without annotations fails closed",
      begin
        CC.evaluate_events("o/r", "main", WINDOW, missing)
        false
      rescue CC::EventError
        true
      end)
many = (1..7).map { |i| ev_run(100 + i, event: "push", branch: "main", updated: "2026-10-1#{6 + i % 3}T0#{i}:00:00Z") }
check("deprecation runs: the latest 5 per workflow",
      CC.deprecation_runs(many, "main", WINDOW).map { |r| r["id"] }.sort ==
        many.sort_by { |r| [Time.iso8601(r["updated_at"]), r["id"]] }.last(5).map { |r| r["id"] }.sort)
%w[--until\ 2026-10-22T00:00:00Z --since\ 2026-10-22 --since\ 2026-10-22T00:00:00Z\ --until\ 2026-10-21T00:00:00Z].each do |args|
  check("usage: #{args}", begin
    CC.parse_window(args.split(" "))
    false
  rescue CC::UsageError
    true
  end)
end
check("usage: no --since means no events", CC.parse_window([]).nil?)

# 実行中の run も job を読み、窓の中に終わった job (timeout) は今の窓で拾う。次の窓では二重に数えない (F01)。
running = ev_run(60, status: "in_progress", conclusion: nil, updated: "2026-10-21T00:00:00Z")
check("job runs: an unfinished run is read", CC.job_run?(running))
check("job runs: a finished clean run is not read", !CC.job_run?(ev_run(61)))
running_jobs = { 60 => [ev_job(601, "self-tests (3.4)", "cancelled", completed: "2026-10-20T00:00:00Z"),
                        { "id" => 602, "name" => "lint", "status" => "in_progress", "conclusion" => nil, "run_attempt" => 1, "completed_at" => nil }] }
now_data = { runs: [running], jobs: running_jobs, annotations: { 601 => [TIMEOUT_ANN] }, skipped: 0 }
check("adjacent windows: the timeout in a running run is found now",
      CC.evaluate_events("o/r", "main", WINDOW, now_data)[:findings].map { |x| x["fingerprint"] } == [TIMEOUT_FP])
next_window = CC.parse_window(%w[--since 2026-10-22T00:00:00Z --until 2026-10-29T00:00:00Z])
later = { runs: [ev_run(60, conclusion: "failure", updated: "2026-10-23T00:00:00Z")],
          jobs: { 60 => [running_jobs[60][0], ev_job(602, "lint", "success", completed: "2026-10-23T00:00:00Z")] },
          annotations: { 601 => [TIMEOUT_ANN] }, skipped: 0 }
check("adjacent windows: not counted again in the next window",
      CC.evaluate_events("o/r", "main", next_window, later)[:findings].empty?)

# 終わった job と run の要る値の欠け、key の欠けは確かめられない (正当な null とは区別する) (F02)。
def event_error?
  yield
  false
rescue CC::EventError
  true
end
done_job = ev_job(1, "a", "cancelled")
check("valid job: a finished job without completed_at", event_error? { CC.valid_job!(done_job.merge("completed_at" => nil)) })
check("valid job: a finished job without conclusion", event_error? { CC.valid_job!(done_job.merge("conclusion" => nil)) })
check("valid job: a missing key", event_error? { CC.valid_job!(done_job.reject { |k, _| k == "completed_at" }) })
# 終わっていない job の completed_at は null でよいが、key そのものの欠けは確かめられない (値の規則では捕まらない)。
check("valid job: a missing key on an unfinished job",
      event_error? { CC.valid_job!(done_job.merge("status" => "in_progress", "conclusion" => nil).reject { |k, _| k == "completed_at" }) })
check("valid job: an unfinished job may have nulls",
      !event_error? { CC.valid_job!(done_job.merge("status" => "in_progress", "conclusion" => nil, "completed_at" => nil)) })
check("valid run: a finished run without conclusion", event_error? { CC.valid_run!(ev_run(1, conclusion: nil)) })
check("valid run: a missing key", event_error? { CC.valid_run!(ev_run(1).reject { |k, _| k == "head_branch" }) })
check("valid run: an unfinished run may lack a conclusion", !event_error? { CC.valid_run!(running) })

# job の slug: 変換で情報が落ちる名前には hash を添え、違う名前がぶつからない (F06)。
check("slug: a plain name stays", CC.job_label("check") == %w[check check])
check("slug: lossy names get a hash", CC.job_label("test (a.b)")[1] != CC.job_label("test (a-b)")[1] &&
      CC.job_label("test (a.b)")[1].start_with?("test-a-b-"))
check("slug: case is lossy too", CC.job_label("Build")[1] != CC.job_label("build")[1])

# ---- CLI ----

RUBY_BIN = RbConfig.ruby
SRC = src
# repo を選ぶ git の環境変数は、この test の外から継承しても CLI の結果が変わらないように外す。
CLEAN_ENV = CC::GIT_REPO_ENV.map { |k| [k, nil] }.to_h

def git!(dir, *args)
  out, err, status = Open3.capture3("git", *args, chdir: dir)
  raise "git #{args.join(' ')} failed: #{err}" unless status.success?

  out
end

def make_repo(dir, files)
  FileUtils.mkdir_p(dir)
  git!(dir, "init", "-q")
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
  git!(dir, "commit", "-q", "-m", "init")
  dir
end

def run_cli(dir, *args, env: {})
  Open3.capture3(CLEAN_ENV.merge(env), RUBY_BIN, SRC, *args, chdir: dir)
end

# 時間の上限つきで CLI を起動する。上限までに終わらなければ止めて nil を返す (load の処理量を抑える検査が外れると
# 終わらない入力に使う)。
def run_cli_timed(dir, seconds)
  out_r, out_w = IO.pipe
  err_r, err_w = IO.pipe
  pid = Process.spawn(CLEAN_ENV, RUBY_BIN, SRC, chdir: dir, out: out_w, err: err_w)
  out_w.close
  err_w.close
  readers = [Thread.new { out_r.read }, Thread.new { err_r.read }]
  deadline = Time.now + seconds
  status = nil
  until (status = Process.wait2(pid, Process::WNOHANG)&.last)
    if Time.now > deadline
      Process.kill("KILL", pid)
      Process.wait(pid)
      readers.each(&:join)
      return nil
    end
    sleep 0.1
  end
  [readers[0].value, readers[1].value, status]
end

# schema の instance の検証 (型・required・additionalProperties: false・enum)。違反を配列で返す。
def schema_errors(node, value, path = "$", errors = [])
  case node["type"]
  when "object"
    return errors << "#{path}: not an object" unless value.is_a?(Hash)

    (node["required"] || []).each { |k| errors << "#{path}.#{k}: missing" unless value.key?(k) }
    (value.keys - node["properties"].keys).each { |k| errors << "#{path}.#{k}: extra" } if node["additionalProperties"] == false
    node["properties"].each { |k, sub| schema_errors(sub, value[k], "#{path}.#{k}", errors) if value.key?(k) }
  when "array"
    return errors << "#{path}: not an array" unless value.is_a?(Array)

    value.each_with_index { |v, i| schema_errors(node["items"], v, "#{path}[#{i}]", errors) }
  when "string"
    errors << "#{path}: not a string" unless value.is_a?(String)
    errors << "#{path}: not in enum" if node["enum"] && !node["enum"].include?(value)
  when "boolean"
    errors << "#{path}: not a boolean" unless [true, false].include?(value)
  end
  errors
end

ci_yml = <<~YAML
  name: test
  on:
    push:
      branches: [main]
    pull_request:
  jobs:
    self-tests:
      runs-on: macos-latest
      steps: [{ run: "true" }]
YAML
reuse_yaml = <<~YAML
  on: workflow_call
  jobs:
    smoke:
      runs-on: ubuntu-latest
      timeout-minutes: 5
YAML

# 所見のある repo: exit 1、schema に適合、id は深刻度順、.yaml も読み、workflow でない file と subdirectory は見ない。
repo = make_repo(File.join(tmp, "repo"), {
  ".github/workflows/test.yml" => ci_yml,
  ".github/workflows/reuse.yaml" => reuse_yaml,
  ".github/workflows/README.md" => "not a workflow\n",
  ".github/workflows/sub/nested.yml" => "on: push\njobs:\n  x:\n    runs-on: x\n",
  ".github/workflows/archive.yml/nested.yml" => "on: push\njobs:\n  x:\n    runs-on: x\n",
  "README.md" => "x\n",
})
out, err, st = run_cli(repo)
check("cli findings: exit 1", st.exitstatus == 1)
check("cli findings: no stderr", err.empty?)
report = JSON.parse(out)
check("cli findings: matches findings.schema.json (#{schema_errors(SCHEMA, report).join(', ')})", schema_errors(SCHEMA, report).empty?)
check("cli findings: ids in severity order",
      report["findings"].map { |x| [x["id"], x["fingerprint"]] } ==
        [["F01", ".github/workflows/test.yml@self-tests#timeout-missing"], ["F02", ".github/workflows/test.yml#concurrency-missing"]])
check("cli findings: decision for the proposal", report["decisions"] == [{ "finding_id" => "F02", "question" => report["findings"][1]["decision_reason"] }])
check("cli findings: seen lists the workflow files only",
      report["scope"]["seen"] == [".github/workflows/reuse.yaml", ".github/workflows/test.yml"])
check("cli findings: nothing unverifiable", report["scope"]["not_seen"].empty?)
check("cli findings: summary counts", report["summary"].include?("2 本") && report["summary"].include?("medium 1 / low 1 (判断が要る 1)"))

# id は file の順ではなく深刻度順に振る (先の file の low が、後の file の medium より後になる)。
order = make_repo(File.join(tmp, "order"), {
  ".github/workflows/a.yml" => "on: pull_request\njobs:\n  x:\n    runs-on: x\n    timeout-minutes: 5\n",
  ".github/workflows/b.yml" => "on: push\njobs:\n  y:\n    runs-on: x\n",
})
out, _err, st = run_cli(order)
check("cli ids: severity first, then fingerprint",
      st.exitstatus == 1 && JSON.parse(out)["findings"].map { |x| [x["id"], x["fingerprint"]] } ==
        [["F01", ".github/workflows/b.yml@y#timeout-missing"], ["F02", ".github/workflows/a.yml#concurrency-missing"]])

# 作業ツリーの未 commit の変更は読まない (HEAD の commit だけ)。
File.write(File.join(repo, ".github/workflows/test.yml"), ci_yml.sub("runs-on: macos-latest\n", "runs-on: macos-latest\n    timeout-minutes: 15\n"))
out2, _err2, st2 = run_cli(repo)
check("cli reads HEAD only: same result with a dirty work tree", st2.exitstatus == 1 && JSON.parse(out2) == report)
git!(repo, "checkout", "--", ".")

# subdirectory から起動しても、repo の root の workflow を読む。
out3, _err3, st3 = run_cli(File.join(repo, ".github"))
check("cli from a subdirectory: same result", st3.exitstatus == 1 && JSON.parse(out3) == report)

# 所見の無い repo は exit 0。workflow の file が無い repo も exit 0。
clean = make_repo(File.join(tmp, "clean"), { ".github/workflows/reuse.yaml" => reuse_yaml })
out, err, st = run_cli(clean)
check("cli clean: exit 0", st.exitstatus == 0 && err.empty? && JSON.parse(out)["findings"].empty?)
none = make_repo(File.join(tmp, "none"), { "README.md" => "x\n" })
out, _err, st = run_cli(none)
report = JSON.parse(out)
check("cli no workflows: exit 0", st.exitstatus == 0 && report["findings"].empty? && report["scope"]["seen"].empty?)
check("cli no workflows: summary says so", report["summary"].include?("workflow の file") && report["summary"].include?("無い"))
check("cli no workflows: matches the schema", schema_errors(SCHEMA, report).empty?)

# 確かめられない file があれば exit 2。残りの file は確かめて出し、名前が規則の外の file は名前を出さない。
mixed = make_repo(File.join(tmp, "mixed"), {
  ".github/workflows/test.yml" => ci_yml,
  ".github/workflows/broken.yml" => "on: [push\n",
  ".github/workflows/link.yml" => { symlink: "test.yml" },
  ".github/workflows/big.yml" => "on: push\n" + ("# x\n" * 300_000),
  ".github/workflows/sp ace.yml" => "on: push\n",
  ".github/workflows/日本語.yml" => "on: push\n",
})
out, err, st = run_cli(mixed)
check("cli unverifiable: exit 2", st.exitstatus == 2)
check("cli unverifiable: no stderr", err.empty?)
report = JSON.parse(out)
check("cli unverifiable: matches the schema", schema_errors(SCHEMA, report).empty?)
check("cli unverifiable: other files are still checked", report["findings"].map { |x| x["fingerprint"] }.include?(".github/workflows/test.yml@self-tests#timeout-missing"))
ns = report["scope"]["not_seen"]
check("cli unverifiable: broken YAML", ns.include?(".github/workflows/broken.yml (YAML として読めない (Psych::SyntaxError))"))
check("cli unverifiable: symlink", ns.include?(".github/workflows/link.yml (通常の file でない)"))
check("cli unverifiable: too large", ns.include?(".github/workflows/big.yml (1048576 byte を超える)"))
check("cli unverifiable: unsafe names are counted without the name",
      ns.count { |x| x.include?("名前に規則の外の文字を含む") } == 2 && !out.include?("sp ace") && !out.include?("日本語.yml"))
check("cli unverifiable: summary mentions it", report["summary"].include?("確かめられない file が 5 件"))

# 後ろの文書の構文の誤りで落ちず (exit 1 = 所見あり と取り違えない)、確かめられない file として残りを出す。
multidoc = make_repo(File.join(tmp, "multidoc"), {
  ".github/workflows/test.yml" => ci_yml,
  ".github/workflows/two.yml" => "on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n---\n[\n",
})
out, err, st = run_cli(multidoc)
report = JSON.parse(out) rescue nil
check("cli broken second document: exit 2 with JSON (#{err})", st.exitstatus == 2 && report.is_a?(Hash))
check("cli broken second document: listed and others checked",
      report && report["scope"]["not_seen"] == [".github/workflows/two.yml (YAML として読めない (Psych::SyntaxError))"] &&
        report["scope"]["seen"] == [".github/workflows/test.yml"])

# 深い入れ子の file も、落ちずに (exit 1 と取り違えずに) 確かめられない file として残りを出す。libyaml の parse は
# 深さに対して二乗の時間がかかる (50 万段なら数分) ので、上限の時間内に終わることも確かめる。
deep_body = nested.call(500_000)
check("fixture: the deep file is within the size limit", deep_body.bytesize <= CC::MAX_FILE_BYTES)
deep = make_repo(File.join(tmp, "deep"), {
  ".github/workflows/test.yml" => ci_yml,
  ".github/workflows/deep.yml" => deep_body,
})
res = run_cli_timed(deep, 30)
check("cli deep nesting: finishes in time", !res.nil?)
if res
  report = JSON.parse(res[0]) rescue nil
  check("cli deep nesting: exit 2 with JSON (#{res[1]})", res[2].exitstatus == 2 && report.is_a?(Hash))
  check("cli deep nesting: listed and others checked",
        report && report["scope"]["not_seen"] == [".github/workflows/deep.yml (入れ子が深すぎる (64 段まで))"] &&
          report["scope"]["seen"] == [".github/workflows/test.yml"])
end

# alias で共有した配列を重ねて mapping の key にすると、load で Hash に入れるときの hash の計算が指数的に増える。
# load の前に止め、上限の時間内に exit 2 で残りの file を出す (検査が load の後なら終わらない)。
chain = (1..40).map { |i| "a#{i}: &a#{i} [*a#{i - 1}, *a#{i - 1}]\n" }.join
alias_bomb = "a0: &a0 [x]\n" + chain + "on: push\njobs:\n  j:\n    runs-on: x\n    timeout-minutes: 5\nk:\n  ? *a40\n  : v\n"
bomb = make_repo(File.join(tmp, "bomb"), {
  ".github/workflows/test.yml" => ci_yml,
  ".github/workflows/bomb.yml" => alias_bomb,
})
res = run_cli_timed(bomb, 30)
check("cli alias key bomb: finishes in time", !res.nil?)
if res
  report = JSON.parse(res[0]) rescue nil
  check("cli alias key bomb: exit 2, listed, others checked",
        res[2].exitstatus == 2 && report &&
          report["scope"]["not_seen"] == [".github/workflows/bomb.yml (mapping の key が scalar でない)"] &&
          report["scope"]["seen"] == [".github/workflows/test.yml"])
end

# replacement ref (refs/replace/) を当てず、HEAD の実体を読む (commit の置き換えも blob の置き換えも)。
replaced = make_repo(File.join(tmp, "replaced"), { ".github/workflows/test.yml" => ci_yml })
out_before, _err, st_before = run_cli(replaced)
empty_tree = git!(replaced, "hash-object", "-w", "-t", "tree", "/dev/null").strip
bare_commit = git!(replaced, "commit-tree", empty_tree, "-m", "no workflows").strip
git!(replaced, "replace", git!(replaced, "rev-parse", "HEAD").strip, bare_commit)
check("fixture: the replacement ref hides the workflows", git!(replaced, "ls-tree", "-r", "HEAD").strip.empty?)
out, _err, st = run_cli(replaced)
check("cli replaced commit: reads the real HEAD", st.exitstatus == st_before.exitstatus && JSON.parse(out) == JSON.parse(out_before))
git!(replaced, "replace", "-d", git!(replaced, "--no-replace-objects", "rev-parse", "HEAD").strip)
clean_blob_file = File.join(tmp, "clean-blob.yml")
File.write(clean_blob_file, reuse_yaml)
clean_blob = git!(replaced, "hash-object", "-w", clean_blob_file).strip
orig_blob = git!(replaced, "rev-parse", "HEAD:.github/workflows/test.yml").strip
git!(replaced, "replace", orig_blob, clean_blob)
check("fixture: the replacement ref swaps the blob", git!(replaced, "cat-file", "blob", orig_blob) == reuse_yaml)
out, _err, st = run_cli(replaced)
check("cli replaced blob: reads the real blob", st.exitstatus == st_before.exitstatus && JSON.parse(out) == JSON.parse(out_before))

# 今の directory の repo を読む。path の末尾の空白を削って隣の repo を読まない。
make_repo(File.join(tmp, "adjacent"), { ".github/workflows/reuse.yaml" => reuse_yaml })
spaced = make_repo(File.join(tmp, "adjacent "), { ".github/workflows/test.yml" => ci_yml })
out, _err, st = run_cli(spaced)
check("cli path with a trailing space: reads that repo",
      st.exitstatus == 1 && JSON.parse(out)["scope"]["seen"] == [".github/workflows/test.yml"])

# partial clone で取得していない object は取りに行かず (network に触れず、object database に書かない)、exit 2。
promisor = make_repo(File.join(tmp, "promisor"), { ".github/workflows/test.yml" => ci_yml })
git!(promisor, "config", "uploadpack.allowFilter", "true")
partial = File.join(tmp, "partial")
git!(tmp, "clone", "-q", "--filter=blob:none", "--no-checkout", "file://#{promisor}", partial)
blob = git!(partial, "--no-lazy-fetch", "ls-tree", "HEAD:.github/workflows").split.at(2)
missing = ->(oid) { !Open3.capture3("git", "--no-lazy-fetch", "cat-file", "-e", oid, chdir: partial)[2].success? }
check("fixture: the partial clone lacks the workflow blob", missing.call(blob))
out, err, st = run_cli(partial)
check("cli partial clone: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.lines.size == 1)
check("cli partial clone: the blob was not fetched", missing.call(blob))

# .github や .github/workflows が directory でなければ確かめられない。
link_dir = make_repo(File.join(tmp, "linkdir"), { "ci" => "x\n", ".github" => { symlink: "ci" } })
out, _err, st = run_cli(link_dir)
check("cli .github not a directory: exit 2", st.exitstatus == 2 && JSON.parse(out)["scope"]["not_seen"] == [".github (directory でない)"])
wf_file = make_repo(File.join(tmp, "wffile"), { ".github/workflows" => "x\n" })
out, _err, st = run_cli(wf_file)
check("cli workflows not a directory: exit 2", st.exitstatus == 2 && JSON.parse(out)["scope"]["not_seen"] == [".github/workflows (directory でない)"])

# run 全体の失敗は stdout を空にして stderr に 1 行、exit 2。
CC::GIT_REPO_ENV.each do |k|
  out, err, st = run_cli(repo, env: { k => "" })
  check("cli #{k} inherited (even empty): exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.include?(k))
end
plain = File.join(tmp, "plain")
FileUtils.mkdir_p(plain)
out, err, st = run_cli(plain, env: { "GIT_CEILING_DIRECTORIES" => tmp })
check("cli outside a git repo: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.lines.size == 1)
empty_repo = File.join(tmp, "empty")
FileUtils.mkdir_p(empty_repo)
git!(empty_repo, "init", "-q")
out, err, st = run_cli(empty_repo)
check("cli without a commit: exit 2 with stderr only", st.exitstatus == 2 && out.empty? && err.lines.size == 1)
out, err, st = run_cli(repo, "--check")
check("cli unknown argument: exit 2 with usage", st.exitstatus == 2 && out.empty? && err.include?("usage:"))
out, _err, st = run_cli(repo, "--help")
check("cli --help: exit 0", st.exitstatus == 0 && out.start_with?("usage:"))

# ---- CLI: run の記録 (偽の gh) ----
# 偽の gh は、`repo view --json nameWithOwner,defaultBranchRef` と `api <path>` だけを受け、routes.json の応答を返す
# (無い route は失敗)。呼ばれた引数と、env に GH_REPO があったかを calls.log に残す。

gh_dir = File.join(tmp, "fake-gh")
gh_bin = File.join(gh_dir, "bin")
FileUtils.mkdir_p(gh_bin)
File.write(File.join(gh_bin, "gh"), <<~'FAKE')
  #!/usr/bin/env ruby
  require "json"
  dir = ENV.fetch("FAKE_GH_DIR")
  File.open(File.join(dir, "calls.log"), "a") { |f| f.puts(JSON.generate("args" => ARGV, "gh_repo" => ENV.key?("GH_REPO"))) }
  routes = JSON.parse(File.read(File.join(dir, "routes.json")))
  key = if ARGV == ["repo", "view", "--json", "nameWithOwner,defaultBranchRef"] then "repo-view"
        elsif ARGV.size == 2 && ARGV[0] == "api" then ARGV[1]
        end
  route = key && routes[key]
  exit 1 if route.nil?
  sleep route["sleep"] if route["sleep"]
  if route["orphan"]
    # stdout を握った子を残して、本体だけが先に終わる (子は同じ process group)。子の pid を file に残す。
    child = Process.spawn("sleep", route["orphan"].to_s)
    File.write(File.join(dir, "orphan.pid"), child.to_s)
    Process.detach(child)
  end
  print JSON.generate(route["body"])
FAKE
File.chmod(0o755, File.join(gh_bin, "gh"))
GH_ENV = { "PATH" => "#{gh_bin}:#{ENV.fetch('PATH')}", "FAKE_GH_DIR" => gh_dir, "GH_REPO" => "evil/elsewhere" }.freeze
EVENT_ARGS = %w[--since 2026-10-15T00:00:00Z --until 2026-10-22T00:00:00Z].freeze
# 作成の範囲は [since の 7 日前, until] (窓の後に作られた run は API の側で除く)。
RUNS_PATH = ->(page) { "repos/o/r/actions/runs?created=2026-10-08T00:00:00Z..2026-10-22T00:00:00Z&per_page=100&page=#{page}" }
JOBS_PATH = ->(id) { "repos/o/r/actions/runs/#{id}/jobs?filter=all&per_page=100&page=1" }
ANN_PATH = ->(id) { "repos/o/r/check-runs/#{id}/annotations?per_page=100&page=1" }

def set_routes(dir, routes)
  File.write(File.join(dir, "routes.json"), JSON.generate(routes))
  FileUtils.rm_f(File.join(dir, "calls.log"))
end

def gh_calls(dir)
  path = File.join(dir, "calls.log")
  File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
end

base_routes = {
  "repo-view" => { "body" => { "nameWithOwner" => "o/r", "defaultBranchRef" => { "name" => "main" } } },
  RUNS_PATH.call(1) => { "body" => { "total_count" => 3, "workflow_runs" => [
    ev_run(1, conclusion: "cancelled", updated: "2026-10-19T00:00:00Z"),
    ev_run(6, path: "dynamic/dependabot/dependabot-updates", event: "dynamic", conclusion: "cancelled"),
    ev_run(7, event: "push", branch: "main", updated: "2026-10-20T00:00:00Z"),
  ] } },
  JOBS_PATH.call(1) => { "body" => { "total_count" => 1, "jobs" => [ev_job(11, "self-tests (3.4)", "cancelled", completed: "2026-10-19T00:00:00Z")] } },
  JOBS_PATH.call(7) => { "body" => { "total_count" => 1, "jobs" => [ev_job(71, "a", "success", completed: "2026-10-20T00:00:00Z")] } },
  ANN_PATH.call(11) => { "body" => [TIMEOUT_ANN] },
  ANN_PATH.call(71) => { "body" => [ann("warning", "Node.js 20 is deprecated. #{SENTINEL}")] },
}.freeze

# 正常: 点検の所見が出て、schema に適合し、GH_REPO は gh に渡らず、dynamic な run の job は読まない。
set_routes(gh_dir, base_routes)
out, err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli events: exit 1 with JSON (#{err})", st.exitstatus == 1 && report.is_a?(Hash))
check("cli events: matches the schema", report && schema_errors(SCHEMA, report).empty?)
check("cli events: findings", report && report["findings"].map { |x| x["fingerprint"] }.sort ==
      [".github/workflows/test.yml#deprecation-node-20", TIMEOUT_FP])
check("cli events: scope.seen has the window", report && report["scope"]["seen"].include?("run の記録 (2026-10-15T00:00:00Z〜2026-10-22T00:00:00Z)"))
calls = gh_calls(gh_dir)
check("cli events: GH_REPO is not passed to gh", !calls.empty? && calls.none? { |c| c["gh_repo"] })
check("cli events: dynamic runs are not read", calls.none? { |c| c["args"].join(" ").include?("runs/6/") })
check("cli events: free text is not echoed", !out.include?(SENTINEL))
check("cli events: summary counts the calls", report && report["summary"].include?("API の呼び出し #{calls.size} 回"))

# --since が無ければ gh を呼ばない (network に触れない)。
set_routes(gh_dir, base_routes)
out, _err, st = run_cli(clean, env: GH_ENV)
check("cli without --since: gh is not called", st.exitstatus == 0 && gh_calls(gh_dir).empty?)

# gh の失敗: 点検の所見は捨て、静的な検査の結果は出し、run の記録を確かめられないにする。
set_routes(gh_dir, base_routes.reject { |k, _| k == ANN_PATH.call(71) })
out, _err, st = run_cli(repo, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli events failure: exit 2", st.exitstatus == 2 && report.is_a?(Hash))
check("cli events failure: event findings are dropped, static kept", report &&
      report["findings"].map { |x| x["fingerprint"] }.sort ==
        [".github/workflows/test.yml#concurrency-missing", ".github/workflows/test.yml@self-tests#timeout-missing"])
check("cli events failure: not_seen line", report &&
      report["scope"]["not_seen"] == ["run の記録 (2026-10-15T00:00:00Z〜2026-10-22T00:00:00Z。gh が失敗した)"] &&
      report["summary"].include?("run の記録を確かめられない"))

# 呼び出しの上限: 200 回で止め、それ以上は呼ばない。
failing = (1..250).map { |i| ev_run(1000 + i, conclusion: "failure") }
capped = base_routes.merge(
  RUNS_PATH.call(1) => { "body" => { "total_count" => 250, "workflow_runs" => failing[0, 100] } },
  RUNS_PATH.call(2) => { "body" => { "total_count" => 250, "workflow_runs" => failing[100, 100] } },
  RUNS_PATH.call(3) => { "body" => { "total_count" => 250, "workflow_runs" => failing[200, 50] } },
)
failing.each { |r| capped[JOBS_PATH.call(r["id"])] = { "body" => { "total_count" => 0, "jobs" => [] } } }
set_routes(gh_dir, capped)
out, _err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli call cap: exit 2 with the reason", st.exitstatus == 2 && report &&
      report["scope"]["not_seen"] == ["run の記録 (2026-10-15T00:00:00Z〜2026-10-22T00:00:00Z。API の呼び出しが上限の 200 回を超える)"])
check("cli call cap: stops at 200 calls (#{gh_calls(gh_dir).size})", gh_calls(gh_dir).size == 200)

# 一覧の上限 (created で絞ると 1000 本まで) を超える窓は読まない。
set_routes(gh_dir, base_routes.merge(RUNS_PATH.call(1) => { "body" => { "total_count" => 1001, "workflow_runs" => [] } }))
out, _err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli too many runs: exit 2", st.exitstatus == 2 && report && report["scope"]["not_seen"].first.to_s.include?("1000 本まで"))

# 応答の形が違えば (field の欠け) 所見なしに倒さない。
broken = base_routes.merge(JOBS_PATH.call(1) => { "body" => { "total_count" => 1, "jobs" => [{ "id" => 11 }] } })
set_routes(gh_dir, broken)
out, _err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli malformed response: exit 2", st.exitstatus == 2 && report && report["scope"]["not_seen"].first.to_s.include?("job の応答の形が想定と違う"))

# total_count に届かない一覧 (短い応答) や、読む間に total_count が変わる一覧は、確かめられない (F05)。
short = base_routes.merge(RUNS_PATH.call(1) => { "body" => { "total_count" => 4, "workflow_runs" => base_routes[RUNS_PATH.call(1)]["body"]["workflow_runs"] } })
set_routes(gh_dir, short)
out, _err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli short run list: exit 2", st.exitstatus == 2 && report && report["scope"]["not_seen"].first.to_s.include?("total_count と合わない"))
short_jobs = base_routes.merge(JOBS_PATH.call(1) => { "body" => { "total_count" => 2, "jobs" => base_routes[JOBS_PATH.call(1)]["body"]["jobs"] } })
set_routes(gh_dir, short_jobs)
out, _err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli short job list: exit 2", st.exitstatus == 2 && report && report["scope"]["not_seen"].first.to_s.include?("job の一覧が total_count と合わない"))
moving = (1..150).map { |i| ev_run(2000 + i) }
changed = base_routes.merge(
  RUNS_PATH.call(1) => { "body" => { "total_count" => 150, "workflow_runs" => moving[0, 100] } },
  RUNS_PATH.call(2) => { "body" => { "total_count" => 151, "workflow_runs" => moving[100, 50] } },
)
set_routes(gh_dir, changed)
out, _err, st = run_cli(clean, *EVENT_ARGS, env: GH_ENV)
report = JSON.parse(out) rescue nil
check("cli list changed while paging: exit 2", st.exitstatus == 2 && report && report["scope"]["not_seen"].first.to_s.include?("読む間に変わった"))

# 引数の誤りは run 全体の失敗 (stdout は空、usage を stderr に)。
[%w[--until 2026-10-22T00:00:00Z], %w[--since 2026-10-22], %w[--since 2026-10-22T00:00:00Z --since 2026-10-22T00:00:00Z]].each do |args|
  out, err, st = run_cli(clean, *args, env: GH_ENV)
  check("cli usage #{args.inspect}: exit 2 with usage", st.exitstatus == 2 && out.empty? && err.include?("usage:"))
end

# 時間の上限: 上限の時刻を過ぎた gh は止め、待ち続けない (GitHubApi を直接使う)。
set_routes(gh_dir, { "repo-view" => { "sleep" => 30, "body" => {} } })
saved_env = ENV.to_h.slice("PATH", "FAKE_GH_DIR")
ENV["PATH"] = GH_ENV["PATH"]
ENV["FAKE_GH_DIR"] = gh_dir
begin
  started = Time.now
  api = CC::GitHubApi.new(clean, Time.now + 1)
  err = begin
    api.json("repo", "view", "--json", "nameWithOwner,defaultBranchRef")
    nil
  rescue CC::EventError => e
    e.message
  end
  check("time cap: a hanging gh is stopped (#{err.inspect}, #{(Time.now - started).round(1)}s)",
        err.to_s.include?("時間が上限") && Time.now - started < 10)
  # gh の本体は終わったが、子が stdout を握ったまま: pipe の待ちも期限で止め、子 (同じ group) も止める (F03)。
  set_routes(gh_dir, { "repo-view" => { "orphan" => 30, "body" => {} } })
  started = Time.now
  orphan_api = CC::GitHubApi.new(clean, Time.now + 2)
  err = begin
    orphan_api.json("repo", "view", "--json", "nameWithOwner,defaultBranchRef")
    nil
  rescue CC::EventError => e
    e.message
  end
  check("time cap: a pipe held by a child is bounded (#{err.inspect}, #{(Time.now - started).round(1)}s)",
        err.to_s.include?("時間が上限") && Time.now - started < 10)
  orphan_pid = File.read(File.join(gh_dir, "orphan.pid")).to_i
  orphan_alive = begin
    Process.kill(0, orphan_pid)
    true
  rescue Errno::ESRCH
    false
  end
  check("time cap: the child holding the pipe is stopped", !orphan_alive)
  past = CC::GitHubApi.new(clean, Time.now - 1)
  check("time cap: no call after the deadline", begin
    past.json("repo", "view", "--json", "nameWithOwner,defaultBranchRef")
    false
  rescue CC::EventError
    past.calls.zero?
  end)
ensure
  saved_env.each { |k, v| ENV[k] = v }
  ENV.delete("FAKE_GH_DIR") unless saved_env.key?("FAKE_GH_DIR")
end

# 1 つの file の想定外の失敗は、その file を確かめられないにして、残りの file の結果を出す。
require "stringio"
orig_check_workflow = CC.method(:check_workflow)
CC.define_singleton_method(:check_workflow) do |path, content|
  raise NoMethodError, "boom" if path.end_with?("/reuse.yaml")

  orig_check_workflow.call(path, content)
end
saved_out, saved_err = $stdout, $stderr
$stdout, $stderr = StringIO.new, StringIO.new
saved_dir = Dir.pwd
begin
  Dir.chdir(repo)
  code = CC.main([])
  captured = [$stdout.string, $stderr.string]
ensure
  Dir.chdir(saved_dir)
  $stdout, $stderr = saved_out, saved_err
  CC.define_singleton_method(:check_workflow, orig_check_workflow)
end
report = JSON.parse(captured[0]) rescue nil
check("per-file unexpected exception: exit 2 with the other files",
      code == 2 && report && report["scope"]["not_seen"] == [".github/workflows/reuse.yaml (想定外の失敗 (NoMethodError))"] &&
        report["scope"]["seen"] == [".github/workflows/test.yml"] && !captured[0].include?("boom"))

# 想定外の例外は、Ruby の既定の exit 1 (所見あり と同じ値) でなく exit 2 で、stdout を空にする。
orig_check_repo = CC.method(:check_repo)
[NoMethodError, SystemStackError].each do |klass|
  CC.define_singleton_method(:check_repo) { |*_args| raise klass, "boom" }
  saved_out, saved_err = $stdout, $stderr
  $stdout, $stderr = StringIO.new, StringIO.new
  begin
    code = CC.main([])
    captured = [$stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = saved_out, saved_err
    CC.define_singleton_method(:check_repo, orig_check_repo)
  end
  check("main #{klass}: exit 2, stdout empty, class on stderr",
        code == 2 && captured[0].empty? && captured[1].include?(klass.name) && !captured[1].include?("boom"))
end

# key の多い mapping でも、key の対応の検査は load 後の値の並びを 1 度だけ作る (key の数の二乗にしない)。時間では
# なく Hash#values の呼び出し回数で確かめる (in-process の検査の最後に置く。prepend はこの process の以後の Hash に
# 残るため。後ろの CLI の検査は別 process)。
module ValuesCounter
  class << self
    attr_accessor :count
  end
  self.count = 0

  def values
    ValuesCounter.count += 1
    super
  end
end
Hash.prepend(ValuesCounter)
many = "on: push\njobs:\n  j:\n    runs-on: x\n    timeout-minutes: 5\n    env:\n" +
       (1..2000).map { |i| "      K#{i}: v\n" }.join
ValuesCounter.count = 0
check("many keys: read", file_error(many).nil?)
check("many keys: values built once per mapping (#{ValuesCounter.count})", ValuesCounter.count < 20)

# C locale でも日本語の出力が壊れない。
out, err, st = run_cli(repo, env: { "LC_ALL" => "C", "LANG" => "C", "LC_CTYPE" => "C" })
check("cli under LC_ALL=C: exit 1 with valid JSON (#{err})", st.exitstatus == 1 && JSON.parse(out)["summary"].include?("確かめた"))

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: ci-check-test"
