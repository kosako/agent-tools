# frozen_string_literal: true
# 起動のときの依頼と、回収した結果の対応を、操作の順序を並べて確かめる (#719)。
#
# personal-packet と personal-codex-worker-run を 1 つの process に読み込み、外部の command (git・herdr・preflight・gate・gh) だけを
# 差し替える。packet の読み書き、起動の記録、回収の判断は本物を通す。届く状態が尽きるまで、操作を 1 つずつ当てる。
#
# 性質と出どころ (Issue #719 の試行の決めごと):
#   P1 回収した結果は、起動したときの依頼の分だけを満たす。          (Issue の受け入れ条件。人が承認)
#   P2 起動の後に足した依頼の「次の入口」は、回収で上書きされない。  (同上)
#   P3 依頼が変わっていても、結果と古い依頼は失われない。            (同上)
#   P4 依頼が変わっていなければ、今までどおり結果で次の入口を更新し、check は通る。  (人が順序で確認)
# 起動のときの依頼の記録が無い run (古い版の起動) は、同じと確かめられないので、変わったときと同じに扱う。
# 期待値は、当てた操作の履歴だけから作る (model)。実装の判定を呼び直さない。
# 並べる操作は、packet と run directory を書く手順 (worker-update・collect・check・publish・pull・人の編集) から引く。
# 1 つの subcommand の途中に依頼が足される形は、collect・check・publish・pull の 4 つで当てる。
require "json"
require "stringio"
require "fileutils"
require "digest"
require "time"

SOURCE, ROOT = ARGV.first(2).map { |v| File.realpath(v) }
REPORT = ARGV.include?("--report")
# 返す値の形 (key と reason_code) を見ない。性質そのものの違反だけを、実装が値を返す前の版でも見られるようにする。
BEHAVIOR_ONLY = ARGV.include?("--behavior-only")
load File.join(SOURCE, "shared/scripts/personal-packet.rb")
load File.join(SOURCE, "shared/scripts/personal-codex-worker-run.rb")

FULL_KEY = ARGV.include?("--full")
MAX_LAUNCHES, MAX_CHANGES = (ARGV.find { |a| a.start_with?("--bounds=") } || "--bounds=2,1").split("=", 2).last.split(",").map { |n| Integer(n) }

ENV.keys.grep(/\A(?:GIT_|GH_|HERDR_|CODEX_)/).each { |k| ENV.delete(k) }
ENV["HOME"] = File.join(ROOT, "home")
ENV["TMPDIR"] = File.join(ROOT, "tmp")
ENV["XDG_STATE_HOME"] = File.join(ROOT, "state")
ENV["HERDR_WORKSPACE_ID"] = "ws"
MAIN = File.join(ROOT, "main")
CLONE = MAIN + "-clones/7"
PACKETS = File.join(MAIN, ".agent-packets")
PACKET = File.join(PACKETS, "7.md")
DEPLOY = File.join(ROOT, "deployed")
HOOKS = File.join(ROOT, "hooks")
BODY = File.join(ROOT, "body.md")
RUNS = File.join(ENV["XDG_STATE_HOME"], "agent-tools", "worker-runs")
[ENV["HOME"], ENV["TMPDIR"], File.join(MAIN, ".git"), PACKETS, DEPLOY, HOOKS].each { |p| FileUtils.mkdir_p(p) }
File.write(BODY, "本文\n")
executables = %w[personal-git-hook-dispatcher personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate].map { |n| File.join(DEPLOY, n) }
executables += %w[pre-commit commit-msg].map { |n| File.join(HOOKS, n) }
executables.each do |path|
  File.write(path, "#!/bin/sh\nexit 0\n")
  File.chmod(0755, path)
end

# 更新先の検査 (git で tracked でないかなど) だけを差し替える。
Packet.define_singleton_method(:packet_dir) { PACKETS }
Packet.define_singleton_method(:check_target!) { |_dir, issue| File.join(PACKETS, "#{issue}.md") }
Packet.define_singleton_method(:tracked_packet_names) { [] }
# publish と pull が呼ぶ外部 (gate・gh・safe reader) を差し替える。途中で依頼を足す操作は、ここに割り込む。
Packet.define_singleton_method(:scan) do |_text|
  World.on_scan&.call
  false
end
Packet.define_singleton_method(:post_comment) do |_issue, _repo, _text|
  World.posts = World.posts.to_i + 1
  "https://example.invalid/comment"
end
Packet.define_singleton_method(:read_issue) do |verb, _issue, _repo|
  raise "差し替えていない read_issue: #{verb}" unless verb == "comments" && World.on_read

  { "comments" => [{ "author_trust" => "self", "body" => World.on_read.call }], "repo" => "owner/project" }
end

# 外部の command の代わり。知らない呼び出しは止める (実装が新しい command に頼ったら、この test の見直しになる)。
module World
  OID = "a" * 40
  BASE_OID = "b" * 40
  class << self
    attr_accessor :tabs, :panes, :on_wait, :on_gh, :on_scan, :on_read, :posts, :calls

    def ok(out = "")
      [out, 0, ""]
    end

    def command(argv, input)
      self.calls = calls.to_i + 1
      case argv.first
      when File.join(DEPLOY, "personal-packet") then packet(argv.drop(1), input)
      when File.join(DEPLOY, "personal-codex-worker-preflight") then preflight(argv.drop(1))
      when File.join(DEPLOY, "personal-public-safety-gate"), File.join(DEPLOY, "personal-work-marker-check") then ok
      when File.join(DEPLOY, "personal-ja-style-check") then ok(JSON.generate("inputs" => [{ "findings" => [] }]))
      when "herdr" then herdr(argv.drop(1))
      when "git" then git(argv.drop(1))
      when "gh" then gh(argv.drop(1))
      when "pgrep" then ["", 1, ""]
      when "tar" then ok
      else raise "差し替えていない command: #{argv.inspect}"
      end
    end

    def packet(args, input)
      old = [$stdin, $stdout, $stderr]
      $stdin, $stdout, $stderr = StringIO.new(input), StringIO.new, StringIO.new
      code = Packet.main(args)
      [$stdout.string, code, $stderr.string]
    ensure
      $stdin, $stdout, $stderr = old
    end

    def preflight(args)
      return ok if args.first == "--verify-git-snapshot"

      ok(JSON.generate("launch_argv" => ["codex", "exec", "-o", "<run dir>/result.md", "-"],
                       "clone_root" => File.realpath(CLONE), "herdr" => "running"))
    end

    def gh(args)
      case args
      when %w[repo view --json nameWithOwner]
        on_gh&.call
        ok(JSON.generate("nameWithOwner" => "owner/project"))
      when %w[api user] then ok(JSON.generate("login" => "owner"))
      when %w[api repos/owner/project] then ok(JSON.generate("owner" => { "type" => "User", "login" => "owner" }))
      else raise "差し替えていない gh: #{args.inspect}"
      end
    end

    def git(args)
      return ok(args.last + "\n") if args.first(2) == %w[check-ref-format --branch]
      if args.first == "clone"
        FileUtils.mkdir_p(CLONE)
        return ok
      end
      raise "差し替えていない git: #{args.inspect}" unless args.first == "-C"

      root, *rest = args.drop(1)
      case rest
      when %w[rev-parse --show-toplevel] then ok(root + "\n")
      when %w[rev-parse --git-common-dir] then ok(".git\n")
      when %w[config --path --get core.hooksPath] then ok(HOOKS + "\n")
      when %w[rev-parse --verify HEAD], %w[rev-parse --verify HEAD^{commit}] then ok(OID + "\n")
      when %w[remote get-url --push origin] then ok("https://github.com/owner/project\n")
      else git_rest(rest)
      end
    end

    def git_rest(rest)
      case rest.first
      when "config", "switch", "status", "diff", "ls-files", "fetch", "cat-file" then ok(rest.include?("--get") ? "worker\n" : "")
      when "rev-parse" then ok((rest.last.start_with?(BASE_OID) ? BASE_OID : OID) + "\n")
      when "merge-base" then ok(BASE_OID + "\n")
      when "rev-list" then ok(rest.include?("--count") ? "1\n" : "")
      when "log" then ok(rest.include?("-z") ? "#{OID}\0Codex <codex@example.invalid>\n\0" : "message\n")
      else raise "差し替えていない git: #{rest.inspect}"
      end
    end

    def herdr(args)
      result = case args.first(2)
               when %w[tab list] then { "tabs" => tabs }
               when %w[pane list] then { "panes" => panes }
               when %w[pane read] then return ok("pane\n")
               when %w[pane process-info] then { "process_info" => { "foreground_processes" => [{ "name" => "zsh" }] } }
               when %w[pane run] then {}
               when %w[pane rename]
                 panes.find { |p| p["pane_id"] == args[2] }["label"] = args[3]
                 {}
               when %w[pane wait-output]
                 on_wait&.call
                 {}
               when %w[tab create]
                 tabs << { "tab_id" => "t1", "label" => "#7" }
                 panes << { "pane_id" => "p1", "tab_id" => "t1" }
                 { "tab" => tabs.last, "root_pane" => panes.last }
               when %w[pane split]
                 panes << { "pane_id" => "p#{panes.size + 1}", "tab_id" => "t1" }
                 { "pane" => panes.last }
               else raise "差し替えていない herdr: #{args.inspect}"
               end
      ok(JSON.generate("result" => result))
    end
  end
end

# 差し替えるのは、外部の command の起動と、隣の script の置き場だけ。
CodexWorkerRun::Launcher.class_eval do
  def capture(argv, input = "")
    World.command(argv, input)
  end

  def sibling(name)
    File.join(DEPLOY, name)
  end
end

def invoke(*argv)
  old = $stdout
  $stdout = StringIO.new
  code = CodexWorkerRun::Launcher.new.run([argv.first, "--repo", MAIN, "--issue", "7", *argv.drop(1)])
  [code, JSON.parse($stdout.string)]
ensure
  $stdout = old
end

def packet_update(operation, values)
  input = { "schema" => 1, "operation" => operation, "expected_sha256" => Digest::SHA256.hexdigest(File.binread(PACKET)) }.merge(values)
  out, code, = World.packet(%w[worker-update 7 --stdin], JSON.generate(input))
  raise "操作が通らない: #{operation} #{out}" unless code == 0
end

# packet の節。実装の読み方に依らず、行頭の ## だけで分ける。
def section(name)
  File.read(PACKET, encoding: "UTF-8").split(/^(?=## )/).find { |part| part.start_with?("## #{name}\n") }.lines.drop(1).join
end

def replace_section(name, text)
  parts = File.read(PACKET, encoding: "UTF-8").split(/^(?=## )/)
  File.write(PACKET, parts.map { |part| part.start_with?("## #{name}\n") ? "## #{name}\n#{text}" : part }.join)
end

# 依頼・入口・結果は、1 つずつ別の印で見分ける。
def marks(text, kind)
  text.scan(/\[#{kind}-\w+\]/)
end

RESULT = <<~TEXT
  ### 到達点
  %<mark>s
  ### 判断
  確認済み。
  ### 未完
  なし。
  ### 停止理由 または 質問
  %<question>s
  ### commits
  なし。
  ### 次の 1 アクション
  %<next>s
TEXT

# ---- 操作 --------------------------------------------------------------------------------------
# m は、当てた操作の履歴から作る期待 (model)。@bad に [性質, 説明] を足す。
class Explorer
  # 記録の誤りは 2 つ (nonce の不一致と、読めない記録)。どちらも停止として扱う。
  STOPS = %w[question limit exit nonce unreadable].freeze

  def initialize
    @bad = []
  end
  attr_reader :bad

  def current(m)
    m["run"] && m["runs"][m["run"]]
  end

  # 依頼の節が、起動のときの byte と違うか。依頼を書き換えるたびに版を進め、元に戻すと起動のときの版に戻る。
  # 印を保った書き換え (誤字の修正) も、版が進むので変更に数える。
  def changed?(m, run)
    m["rev"] != run["rev"]
  end

  def revise(m)
    m["revs"] += 1
    m["rev"] = m["revs"]
  end

  # check が公開前の検査まで進む状態
  def checkable?(m)
    %w[open review].include?(m["state"]) && m["run"].nil? && m["last"]
  end

  # 実装が返すはずの値。起動の記録に依頼が無ければ、比べられない
  def status(m, run)
    return "unrecorded" unless run["recorded"]

    changed?(m, run) ? "changed" : "same"
  end

  def events(m)
    list = []
    run = current(m)
    waiting = run && run["done"].nil? && m["state"] == "open"
    if m["runs"].size < MAX_LAUNCHES
      list << "launch" if (m["state"] == "open" && run.nil?) || m["state"] == "blocked"
      list += %w[retry-empty manual-retry] if m["state"] == "open" && run && run["done"] == "empty" && run["retry_of"].nil?
    end
    if waiting && run["manual"]
      # 手で組んだ run は launch.json が無く、collect は使えない。caller が同じ契約で転記する
      list << "manual-collect"
      waiting = false
    end
    if waiting
      list += ["collect:normal", "collect:empty", *STOPS.map { |s| "collect:#{s}" }]
      list << "collect:normal+round" if m["changes"] < MAX_CHANGES
    end
    list << "collect:again" if m["state"] == "open" && run && run["done"] == "late"
    if m["runs"].any? && m["changes"] < MAX_CHANGES
      list << "round" << "overwrite" << "typo"
      # packet を丸ごと書き換える 2 つの操作の途中に、依頼を足す
      list << "publish+round" << "pull+round"
    end
    list << "check+round" if checkable?(m) && status(m, m["runs"][m["last"]]) == "same" && m["changes"] < MAX_CHANGES
    base = run || (m["last"] && m["runs"][m["last"]])
    list << "restore" if m["state"] == "open" && base && changed?(m, base) && m["restores"].zero?
    list << "metadata" if waiting && m["metadata"].zero?
    list << "forget" if waiting && run["recorded"] && m["forgets"].zero?
    list << "stop" if m["state"] == "open" && (run || m["last"]) && m["stops"].zero?
    list << "review" if m["state"] == "open" && run.nil? && m["last"]
    list
  end

  def violate(property, text)
    @bad << [property, text]
  end

  def apply(event, m)
    name, kind = event.split(":", 2)
    case name
    when "launch", "retry-empty" then start(name, m)
    when "collect" then collect(kind, m)
    when "manual-retry" then manual_retry(m)
    when "manual-collect" then manual_collect(m)
    when "round"
      add_round(m)
    when "overwrite"
      m["changes"] += 1
      mark = "[req-X#{m['changes']}]"
      replace_section("依頼", "\n#{mark}\n\n")
      m["request"] = [mark]
      revise(m)
    when "typo"
      # 印を変えずに、依頼の文を直す
      m["changes"] += 1
      replace_section("依頼", section("依頼") + "(誤字を直した)\n\n")
      revise(m)
    when "check+round" then check_round(m)
    when "publish+round" then publish_round(m)
    when "pull+round" then pull_round(m)
    when "restore"
      m["restores"] += 1
      base = current(m) || m["runs"][m["last"]]
      replace_section("依頼", base["bytes"])
      m["request"] = base["request"]
      m["rev"] = base["rev"]
    when "metadata"
      m["metadata"] = 1
      text = File.read(PACKET, encoding: "UTF-8").sub(/^published: .*\n/, "")
      File.write(PACKET, text.sub(/^updated: .*$/, "updated: 2026-01-02T00:00:00+09:00\npublished: 2026-01-02T00:00:00+09:00"))
    when "forget"
      # 依頼を記録しない古い版で起動した run
      m["forgets"] = 1
      run = current(m)
      run["recorded"] = false
      File.unlink(File.join(run["dir"], "request.sha256"))
    when "stop"
      m["stops"] += 1
      target = current(m) || m["runs"][m["last"]]
      mark = "[res-H#{m['stops']}]"
      packet_update("stop", "run" => target["dir"], "role" => "orchestrator/claude", "entry" => mark, "next" => "[next-H#{m['stops']}]")
      m["results"] << mark
      m["next"] = ["[next-H#{m['stops']}]"]
      m["state"] = "blocked"
    when "review"
      packet_update("review", "pr" => 17)
      m["state"] = "review"
    else raise event
    end
    invariants(m)
  end

  def add_round(m)
    m["changes"] += 1
    n = m["changes"]
    packet_update("round", "request" => "修正 round [req-R#{n}]", "next" => "[next-R#{n}]")
    m["request"] += ["[req-R#{n}]"]
    m["next"] = ["[next-R#{n}]"]
    m["state"] = "open" if m["state"] == "review"
    revise(m)
  end

  # check が依頼を比べた後、READY を返す前 (公開先の確認の間) に依頼が足される
  def check_round(m)
    fired = false
    World.on_gh = lambda do
      World.on_gh = nil
      fired = true
      add_round(m)
    end
    _code, out = invoke("check", "--title", "題名", "--body-file", BODY)
    World.on_gh = nil
    raise "check が公開先の確認に届かない: #{out}" unless fired

    violate("P1", "check+round: 検査の途中で依頼が変わったのに READY になる") if out["status"] == "READY"
    if !BEHAVIOR_ONLY && out["status"] != "READY" && out["reason_code"] != "request-changed"
      violate("P1", "check+round: 依頼が変わったことを理由に返さない (#{out['reason_code']})")
    end
  end

  # publish が packet を読んだ後、一時 file を作る前 (gate の検査の間) に依頼が足される
  def publish_round(m)
    fired = false
    World.on_scan = lambda do
      World.on_scan = nil
      fired = true
      add_round(m)
    end
    World.packet(%w[publish 7], "")
    World.on_scan = nil
    raise "publish が gate の検査に届かない" unless fired
  end

  # pull が Issue の写しを読む間に依頼が足される。pull が packet を書くのは、local に未 publish の更新が無いときだけ
  # なので、先に今の packet を publish した後の形にする。写しは、その後に別の場所で publish した形 (中身は同じ)。
  def pull_round(m)
    File.write(PACKET, Packet.with_published(File.read(PACKET, encoding: "UTF-8"), Time.now, PACKET))
    fired = false
    World.on_read = lambda do
      fired = true
      copy = Packet.compose(Packet.parse_text(File.read(PACKET, encoding: "UTF-8"), PACKET), Time.now + 60)
      add_round(m)
      copy
    end
    _out, _code, err = World.packet(%w[pull 7], "")
    World.on_read = nil
    raise "pull が Issue の写しを読まない" unless fired
    raise "pull が分岐で止まった (local を publish した形になっていない): #{err}" if err.include?("分岐")
  end

  def start(name, m)
    code, out = invoke(name)
    raise "起動できない: #{out}" unless code == 0 && out["status"] == "STARTED"

    previous = m["run"]
    run = { "dir" => out.fetch("run_dir"), "nonce" => out.fetch("nonce"), "done" => nil,
            "retry_of" => name == "retry-empty" ? previous : nil }
    if name == "retry-empty"
      # 同じ brief をもう一度使うので、依頼 (と、その記録の有無) は前の run のもの
      run["request"], run["bytes"], run["recorded"], run["rev"] = m["runs"][previous].values_at("request", "bytes", "recorded", "rev")
    else
      run["request"], run["bytes"], run["recorded"], run["rev"] = m["request"], section("依頼"), true, m["rev"]
    end
    brief = File.read(File.join(run["dir"], "brief.md"), encoding: "UTF-8")
    violate("P1", "#{name}: worker に渡した依頼が、起動のときの依頼と違う") unless marks(brief, "req") == run["request"]
    m["runs"] << run
    m["run"], m["last"], m["state"] = m["runs"].size - 1, nil, "open"
  end

  # docs の「人手実行だけの空の結果の回復」。新しい run dir に前の run の brief と依頼の記録を写し、run-start で差し替える。
  # 前の tab は、人が確かめて閉じる (手で組んだ run には tab-id が無い)。
  def manual_retry(m)
    previous = m["runs"][m["run"]]
    dir = File.join(RUNS, "7.manual#{m['runs'].size}")
    Dir.mkdir(dir, 0700)
    %w[brief.md request.sha256 preflight.json].each do |name|
      from = File.join(previous["dir"], name)
      FileUtils.cp(from, File.join(dir, name)) if File.exist?(from)
    end
    packet_update("run-start", "run" => dir, "tab" => "#7", "expected_run" => previous["dir"])
    World.tabs, World.panes = [], []
    m["runs"] << { "dir" => dir, "nonce" => "e" * 16, "done" => nil, "retry_of" => m["run"], "manual" => true,
                   "request" => previous["request"], "bytes" => previous["bytes"], "recorded" => previous["recorded"],
                   "rev" => previous["rev"] }
    m["run"] = m["runs"].size - 1
  end

  def manual_collect(m)
    run = current(m)
    number = m["run"] + 1
    finish(run, "normal", number)
    _code, out = invoke("collect")
    raise "手で組んだ run を collect が受けた: #{out}" unless out["reason_code"] == "no-launch-record"

    values = { "run" => run["dir"], "entry" => "[res-W#{number}]" }
    if status(m, run) == "same"
      values["next"] = "[next-W#{number}]"
      m["next"] = [values["next"]]
    end
    packet_update("result", values)
    run["done"] = "collected"
    m["results"] << "[res-W#{number}]"
    m["run"], m["last"] = nil, m["run"]
  end

  def finish(run, kind, number)
    write = ->(name, text) { File.write(File.join(run["dir"], name), text) }
    code = { "limit" => 17, "exit" => 17 }.fetch(kind, 0)
    nonce = kind == "nonce" ? "f" * 16 : run["nonce"]
    write.call("done.txt", kind == "unreadable" ? "broken\n" : "CODEX-WORKER-DONE-#{nonce} exit=#{code}\n")
    write.call("codex.log", kind == "limit" ? "ERROR: You've hit your usage limit\n" : "log\n")
    text = format(RESULT, mark: "[res-W#{number}]", next: "[next-W#{number}]", question: kind == "question" ? "判断が要る。" : "なし")
    write.call("result.md", kind == "empty" ? "" : text)
  end

  def collect(kind, m)
    run = current(m)
    number = m["run"] + 1
    late = kind == "normal+round"
    before = File.binread(PACKET)
    if late
      # 回収が待っている間に、依頼が足される
      World.on_wait = lambda do
        World.on_wait = nil
        add_round(m)
        finish(run, "normal", number)
      end
    elsif kind != "again"
      finish(run, kind, number)
    end
    code, out = invoke("collect")
    World.on_wait = nil
    if kind == "empty" && run["retry_of"].nil?
      run["done"] = "empty"
      raise "空の結果の 1 回目が変わった: #{out}" unless out["retryable"] == true
      violate("P3", "collect:empty: 1 回目の空の結果で packet が変わった") unless File.binread(PACKET) == before
      return
    end
    mark = kind == "empty" ? nil : "[res-W#{number}]"
    written = mark ? marks(section("結果"), "res").include?(mark) : out["status"] == "BLOCKED" && File.binread(PACKET) != before
    if late && !written
      # 待つ間に packet が変わると、書かずに止まってよい。結果は run dir に残り、もう一度回収できる
      run["done"] = "late"
      raise "途中の依頼で止まった理由が違う: #{out}" unless out["reason_code"] == "packet-update"
      return
    end

    status = status(m, run)
    stopped = STOPS.include?(kind) || kind == "empty"
    raise "回収の結果が違う: #{kind} #{out}" unless stopped ? code == 1 && out["packet"]["state"] == "blocked" : out["status"] == "DONE"

    run["done"] = "collected"
    violate("P3", "collect:#{kind}: 結果が packet に無い") unless written
    m["results"] << mark if mark
    violate(status == "same" ? "P4" : "P1", "collect:#{kind}: 依頼が #{status} と返さない") unless BEHAVIOR_ONLY || out["request"] == status
    got = section("次の入口")
    if status != "same"
      violate("P2", "collect:#{kind}: 足した依頼の次の入口を上書きした (#{status})") unless marks(got, "next") == m["next"]
      # 次の入口に書かない停止の案内を、結果から失わない
      violate("P3", "collect:#{kind}: 停止の案内が結果に無い") if kind == "empty" && !section("結果").include?("停止理由と退避した変更を確かめてから")
    else
      # 正しい形の結果は worker の次の手、書式や本文の無い停止は決まった文
      wanted = kind == "empty" ? [] : ["[next-W#{number}]"]
      violate("P4", "collect:#{kind}: 依頼が同じなのに、次の入口を更新しない") unless marks(got, "next") == wanted
      m["next"] = wanted
    end
    if stopped
      m["state"] = "blocked"
    else
      m["run"], m["last"] = nil, m["run"]
    end
  end

  # どの操作の後でも見ること
  def invariants(m)
    # 書き手の一時 file が残ると、後の書き込みがすべて止まる。性質の外の失敗として扱う。
    raise "packet の dir に一時 file などが残った: #{Dir.children(PACKETS).sort.inspect}" unless Dir.children(PACKETS) == ["7.md"]
    violate("P3", "依頼の節が、足した依頼を失った") unless marks(section("依頼"), "req") == m["request"]
    violate("P3", "結果の節が、回収した結果を失った") unless marks(section("結果"), "res") == m["results"]
    m["runs"].each_with_index do |run, i|
      brief = File.read(File.join(run["dir"], "brief.md"), encoding: "UTF-8")
      violate("P3", "起動 #{i + 1} の依頼が run dir に残っていない") unless marks(brief, "req") == run["request"]
    end
    violate("P2", "次の入口が、最後に書いたものと違う") unless marks(section("次の入口"), "next") == m["next"]
    return unless checkable?(m)

    before = File.binread(PACKET)
    _code, out = invoke("check", "--title", "題名", "--body-file", BODY)
    ready = out["status"] == "READY"
    status = status(m, m["runs"][m["last"]])
    violate("P1", "check: 依頼が #{status} なのに READY になる") if ready && status != "same"
    violate("P4", "check: 依頼が同じなのに READY にならない (#{out['reason_code']})") if !ready && status == "same"
    violate("P1", "check: 依頼が #{status} なことを理由に返さない (#{out['reason_code']})") if !BEHAVIOR_ONLY && !ready && status != "same" && out["reason_code"] != "request-#{status}"
    violate("P3", "check: packet を書いた") unless File.binread(PACKET) == before
  end
end

# ---- 状態の保存 --------------------------------------------------------------------------------
KEPT = %w[launch.json request.sha256 preflight.json brief.md done.txt result.md codex.log tab-id pane-id].freeze

def save(model)
  runs = Dir.children(RUNS).sort.map do |name|
    dir = File.join(RUNS, name)
    [name, KEPT.map { |f| File.join(dir, f) }.select { |f| File.exist?(f) }.map { |f| [File.basename(f), File.binread(f)] }]
  end
  # packet の dir は丸ごと保つ (一時 file が残る形を、別の順序へ漏らさない)
  packets = Dir.children(PACKETS).sort.map { |name| [name, File.binread(File.join(PACKETS, name))] }
  Marshal.dump([packets, runs, World.tabs, World.panes, model])
end

def restore(saved)
  packets, runs, tabs, panes, model = Marshal.load(saved)
  Dir.children(PACKETS).each { |name| File.unlink(File.join(PACKETS, name)) }
  packets.each { |name, bytes| File.binwrite(File.join(PACKETS, name), bytes) }
  FileUtils.rm_rf(RUNS)
  FileUtils.mkdir_p(RUNS, mode: 0700)
  runs.each do |name, files|
    dir = File.join(RUNS, name)
    Dir.mkdir(dir, 0700)
    files.each { |file, bytes| File.binwrite(File.join(dir, file), bytes) }
  end
  World.tabs, World.panes = tabs, panes
  model
end

# 同じ状態かを見る値。run の名前・nonce・日時は、起動の番号に置き換える。履歴は含めない。
# 既定では、後の判断に効かないと見なすもの (結果と次の入口の文面、回収し終えた run の成果物) を外す。--full は外さずに見る。
# 外してよいことは、小さい上限の --full と、見つかる違反の種類が同じことで確かめた (docs/codex-worker-run.md)。
def state_key(model)
  text = File.read(PACKET, encoding: "UTF-8")
  text = text.split(/^(?=## )/).map { |part| part =~ /\A## (?:結果|次の入口)\n/ ? part.lines.first : part }.join unless FULL_KEY
  parts = [text]
  model["runs"].each do |run|
    files = FULL_KEY || run["done"] != "collected" ? KEPT : %w[launch.json request.sha256 brief.md]
    parts << files.map { |f| File.join(run["dir"], f) }.select { |f| File.exist?(f) }.map { |f| File.read(f, encoding: "UTF-8") }.join("\0")
  end
  ignored = FULL_KEY ? %w[history] : %w[history results next]
  parts << JSON.generate([World.tabs, World.panes, model.reject { |k, _| ignored.include?(k) }])
  joined = parts.join("\1")
  model["runs"].each_with_index { |run, i| joined = joined.gsub(run["dir"], "run#{i}").gsub(run["nonce"], "nonce#{i}") }
  Digest::SHA256.hexdigest(joined.gsub(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:Z|[+-]\d\d:\d\d)/, "TIME"))
end

File.write(PACKET, <<~TEXT)
  ---
  issue: 7
  title: packet
  state: open
  worker: codex
  updated: 2026-01-01T00:00:00+09:00
  branch: feat/7-test
  ---
  ## 依頼

  [req-R0]

  ## 結果

  ## 次の入口

  [next-R0]

TEXT
FileUtils.mkdir_p(RUNS, mode: 0700)
World.tabs, World.panes = [], []
start = { "request" => ["[req-R0]"], "next" => ["[next-R0]"], "results" => [], "runs" => [], "run" => nil, "last" => nil, "state" => "open",
          "changes" => 0, "restores" => 0, "metadata" => 0, "forgets" => 0, "stops" => 0,
          "rev" => 0, "revs" => 0, "history" => [] }

began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
seen = { state_key(start) => true }
queue = [save(start)]
transitions = 0
used = Hash.new(0)
found = {}
counts = Hash.new(0)
until queue.empty?
  saved = queue.shift
  model = Marshal.load(saved).last
  explorer = Explorer.new
  explorer.events(model).each do |event|
    m = restore(saved)
    m["history"] += [event]
    explorer.bad.clear
    begin
      explorer.apply(event, m)
    rescue StandardError => e
      abort "FAIL: #{m['history'].join(' → ')}: #{e.class} #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end
    transitions += 1
    used[event] += 1
    explorer.bad.uniq.each do |violation|
      counts[violation] += 1
      found[violation] ||= m["history"]
    end
    # 性質が破れた先は、期待と実物が食い違っているので、たどらない
    next unless explorer.bad.empty?

    key = state_key(m)
    next if seen[key]

    seen[key] = true
    queue << save(m)
  end
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

if REPORT
  puts "状態 #{seen.size}、操作 #{transitions}、#{elapsed.round(1)} 秒、外部の command の代わり #{World.calls} 回"
  used.sort.each { |event, n| puts "  #{event}: #{n}" }
  found.sort_by { |(property, text), history| [property, history.size, text] }.each do |(property, text), history|
    puts "#{property} #{text} (#{counts[[property, text]]} 件)\n    #{history.join(' → ')}"
  end
end
unless found.empty?
  (property, text), history = found.min_by { |_, h| h.size }
  abort "FAIL: worker-request-order: 性質の違反 #{found.size} 種類。例: #{property} #{text} (#{history.join(' → ')})"
end
# 並べる範囲が減って気付かない形にしない。操作の種類は全部が当たり、self-test の上限では、状態と操作の数を固定する。
EVENTS = %w[launch retry-empty manual-retry manual-collect round overwrite typo restore metadata forget stop review collect:normal
            collect:normal+round collect:again collect:empty check+round publish+round pull+round]
         .concat(Explorer::STOPS.map { |s| "collect:#{s}" }).freeze
abort "FAIL: worker-request-order: 当たらない操作 #{(EVENTS - used.keys).inspect}、一覧に無い操作 #{(used.keys - EVENTS).inspect}" unless used.keys.sort == EVENTS.sort
if [MAX_LAUNCHES, MAX_CHANGES] == [2, 1] && !FULL_KEY && !BEHAVIOR_ONLY && [seen.size, transitions] != [2408, 5604]
  abort "FAIL: worker-request-order: 状態と操作の数が変わった (#{seen.size}、#{transitions})"
end
puts "ok: worker-request-order (状態 #{seen.size}、操作 #{transitions})"
