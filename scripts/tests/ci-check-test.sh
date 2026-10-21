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
  CC.define_singleton_method(:check_repo) { |_dir| raise klass, "boom" }
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
