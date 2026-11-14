#!/bin/sh
# personal-post-check.rb の self-test (#676)。
# 対象の script と、本物の 3 つの検査 (personal-ja-style-check・personal-work-marker-check・personal-public-safety-gate) を
# 一時 directory に配備のときの名前で置き、外から起動して確かめる。検査を使えない・gate が想定外の exit を返す、などの状態は、
# その directory の file を外す・小さな代用品に差し替えて作る。環境は空にして locale を C にする (HOME の pattern file を読ませず、
# C locale でも日本語の題名と本文を扱えることを見る)。gate を止める入力と警告させる入力は、明らかに偽の文字列を組み立てる。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

src="$repo_root/shared/scripts/personal-post-check.rb"
[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ruby -r"$script_dir/lib/check_helper" -ropen3 -rfileutils -rrbconfig - "$src" "$repo_root" "$tmp" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
src, root, tmp = ARGV
tmp = File.realpath(tmp)

TOOLS = %w[personal-ja-style-check personal-work-marker-check personal-public-safety-gate].freeze
BASE = File.join(tmp, "base")
FileUtils.mkdir_p(BASE)
TOOLS.each do |name|
  FileUtils.cp(File.join(root, "shared/scripts/#{name}.rb"), File.join(BASE, name))
  File.chmod(0o755, File.join(BASE, name))
end
FileUtils.cp(src, File.join(BASE, "personal-post-check"))
File.chmod(0o755, File.join(BASE, "personal-post-check"))

CLEAN = "確認しました。\n"
STYLE = "- **項目**: 確認しました。\n"
# 明らかに偽の値。gate の「疑わしい代入」(警告) と「private key の block」(止める) に当たる形を、ここで組み立てる。
WARNING = ["token", "=", %("POSTCHECK_ONLY_FAKE_VALUE")].join(" ") + "\n"
BLOCKED = ["-----BEGIN ", "TEST ONLY ", "PRIVATE KEY", "-----"].join + "\n"
ENVIRONMENT = { "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL" => "C" }.freeze

$case = 0
# 新しい directory に 4 つの script を置き、block で状態を作ってから post-check を起動する。[exit, stdout, stderr, dir] を返す。
def post(args, body: CLEAN, body_name: "body.txt", dir_name: "case")
  $case += 1
  dir = File.join(File.dirname(BASE), "#{dir_name}#{$case}")
  FileUtils.cp_r(BASE, dir)
  File.binwrite(File.join(dir, body_name), body) unless body.nil?
  yield dir if block_given?
  out, err, status = Open3.capture3(ENVIRONMENT, File.join(dir, "personal-post-check"), *args, chdir: dir, unsetenv_others: true)
  [status.exitstatus, out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8), dir]
end

def fake(dir, name, source)
  File.binwrite(File.join(dir, name), "#!#{RbConfig.ruby}\n#{source}\n")
  File.chmod(0o755, File.join(dir, name))
end

def last_line(out)
  out.lines.last.to_s.chomp
end

BODY = ["--body-file", "body.txt"].freeze
PR = (BODY + ["--title", "確認 (#676)", "--marker-kind", "pr"]).freeze

# ---- 通る形 (exit 0)
s, o, e, = post(BODY)
check "clean body is ok with the exact output", s == 0 && e.empty? &&
                                               o == ["style: 0 finding(s)", "  ja-style-check: 0 finding(s) in 1 input(s)", "marker: skipped", "gate: ok", "post-check: ok"].join("\n") + "\n"
s, o, e, = post(PR, body: "本文です。\n\nCloses #676\n")
check "pr with a matching title is ok", s == 0 && e.empty? && o.include?("marker: ok\n") && o.include?("  work-marker-check: pr: ok (markers v") && last_line(o) == "post-check: ok"
s, o, = post(BODY + ["--title", "題名だけ"])
check "a title without a marker kind is ok", s == 0 && o.include?("marker: skipped\n")

# ---- 文体の指摘 (exit 3 と --style-reviewed)
s, o, e, = post(PR, body: STYLE + "\nCloses #676\n")
check "unreviewed style findings exit 3", s == 3 && e.empty? && o.include?("style: 1 finding(s)\n") && o.include?("marker: ok\n") && o.include?("gate: ok\n")
check "the exit 3 line names the count and the flag", last_line(o).match?(/\Apost-check: style-findings \(1 件。.*--style-reviewed.*\)\z/)
check "the finding is shown indented with the line in the combined input", o.include?("  -:3: [bold-label] ")
s, o, e, = post(PR + ["--style-reviewed"], body: STYLE + "\nCloses #676\n")
check "--style-reviewed turns the findings into ok", s == 0 && e.empty? && o.include?("style: 1 finding(s)\n") && last_line(o) == "post-check: ok"
s, o, = post(BODY + ["--style-reviewed"])
check "--style-reviewed without findings is ok", s == 0 && last_line(o) == "post-check: ok"

# ---- 止める (exit 1)。文体の指摘の exit 3 や --style-reviewed は、止める理由を上書きしない。
[
  ["a gate warning alone", 676, WARNING, "gate-warning", "gate: warning"],
  ["a gate block", 676, BLOCKED, "gate", "gate: stop (exit 1)"],
  ["a marker mismatch", 677, "", "marker", "gate: ok"],
  ["everything at once", 677, WARNING + BLOCKED, "gate, gate-warning, marker", "gate: stop (exit 1)"],
].each do |label, issue, extra, reasons, gate|
  [[], ["--style-reviewed"]].each do |flag|
    s, o, e, = post(PR + flag, body: STYLE + "\nCloses ##{issue}\n" + extra)
    check "#{label} stops#{flag.empty? ? '' : ' even when reviewed'}",
          s == 1 && e.empty? && last_line(o) == "post-check: stop (#{reasons})" && o.include?("#{gate}\n") && o.include?("style: 1 finding(s)\n")
    check "#{label}: the marker heading#{flag.empty? ? '' : ' (reviewed)'}", o.include?(issue == 676 ? "marker: ok\n" : "marker: 1 error(s)\n")
    check "#{label}: the gate lines are shown indented", extra.empty? || o.include?("  public-safety-gate: ")
  end
end
s, o, = post(PR, body: "本文です。\n\nCloses #677\n")
check "a marker error is shown with the checker's own lines", s == 1 && o.include?("  -:5: [issue-mismatch] ") && o.include?("  work-marker-check: pr: 1 error(s) (markers v")
s, o, = post(BODY + ["--marker-kind", "review-result"])
check "a review result without the marker lines stops", s == 1 && o.match?(/^marker: \d+ error\(s\)$/) && last_line(o) == "post-check: stop (marker)"
s, o, = post(BODY + ["--marker-kind", "escape-issue"], body: "本文。\n\n元の PR: #654\n")
check "an escape issue with the origin line is ok", s == 0 && o.include?("marker: ok\n")

# gate が想定外の exit を返す・検査が想定外の形で終わる。
s, o, = post(PR + ["--style-reviewed"], body: CLEAN + "\nCloses #676\n") { |dir| fake(dir, TOOLS[2], %q(warn "GATE_FAILURE"; exit 2)) }
check "a gate exit 2 stops", s == 1 && o.include?("gate: stop (exit 2)\n") && o.include?("  GATE_FAILURE\n") && last_line(o) == "post-check: stop (gate)"
s, o, = post(BODY) { |dir| fake(dir, TOOLS[2], %q(warn "GATE_NOTE")) }
check "gate stderr without a warning line does not stop", s == 0 && o.include?("gate: ok\n  GATE_NOTE\n")
s, o, = post(BODY) { |dir| fake(dir, TOOLS[2], %q($stdout.puts "GATE_STDOUT"; $stdout.flush; warn "GATE_STDERR")) }
check "the gate lines are its stderr and then its stdout", s == 0 && o.include?("gate: ok\n  GATE_STDERR\n  GATE_STDOUT\npost-check: ok\n")
s, o, = post(BODY) { |dir| fake(dir, TOOLS[2], %q(warn "note: public-safety-gate: warning: not at the line start")) }
check "a warning mark inside a line is not a warning", s == 0 && o.include?("gate: ok\n")
s, o, = post(BODY + ["--marker-kind", "review-result"]) { |dir| fake(dir, TOOLS[1], %q(warn "work-marker-check: error: x"; exit 2)) }
check "a marker exit 2 stops with its exit code", s == 1 && o.include?("marker: stop (exit 2)\n") && last_line(o) == "post-check: stop (marker)"
s, o, = post(BODY + ["--marker-kind", "review-result"]) { |dir| fake(dir, TOOLS[1], %q(puts "no count line"; exit 1)) }
check "a marker exit 1 without a count line still stops", s == 1 && o.include?("marker: stop (exit 1)\n")
s, o, = post(BODY + ["--marker-kind", "review-result"]) { |dir| fake(dir, TOOLS[1], %q(puts "work-marker-check: review-result: 1 error(s) (markers v4)"; exit 2)) }
check "a count line with an exit other than 1 is shown as the exit", s == 1 && o.include?("marker: stop (exit 2)\n") && last_line(o) == "post-check: stop (marker)"
# signal で終わった検査 (exit code が無い)。
killed = %q(Process.kill("KILL", Process.pid); sleep 5)
s, o, = post(BODY) { |dir| fake(dir, TOOLS[2], killed) }
check "a gate ended by a signal stops", s == 1 && o.include?("gate: stop (signal)\n") && last_line(o) == "post-check: stop (gate)"
s, o, = post(BODY + ["--marker-kind", "review-result"]) { |dir| fake(dir, TOOLS[1], killed) }
check "a marker check ended by a signal stops", s == 1 && o.include?("marker: stop (signal)\n") && last_line(o) == "post-check: stop (marker)"
s, o, = post(BODY) { |dir| fake(dir, TOOLS[0], %q(puts "ja-style-check: 0 finding(s) in 1 input(s)"; $stdout.flush; ) + killed) }
check "a style check ended by a signal is unavailable", s == 1 && o.include?("style: unavailable\n") && last_line(o) == "post-check: stop (unavailable)"
# 置き場の path に空白や shell の記号があっても、検査を argv で起動する (shell を通さない)。
s, o, e, dir = post(BODY, dir_name: "dir with $(touch PWNED) space;")
check "a directory with spaces and shell characters works", s == 0 && e.empty? && last_line(o) == "post-check: ok"
check "nothing in the path was run by a shell", Dir.glob(File.join(File.dirname(BASE), "**", "PWNED")).empty? && !File.exist?(File.join(dir, "PWNED"))
s, o, = post(BODY) { |dir| fake(dir, TOOLS[0], %q(puts "no count line")) }
check "a style check without a count line is unavailable", s == 1 && o.include?("style: unavailable\n") && last_line(o) == "post-check: stop (unavailable)"

# ---- 検査を使えない (file が無い・起動できない・文体の検査が exit 2)。残りの検査はかける。--style-reviewed でも通さない。
stopping = STYLE + "\nCloses #677\n" + WARNING
TOOLS.each_with_index do |name, index|
  %w[missing launch].each do |mode|
    s, o, e, = post(PR + ["--style-reviewed"], body: stopping) do |dir|
      File.delete(File.join(dir, name))
      if mode == "launch"
        File.binwrite(File.join(dir, name), "#!#{File.join(dir, 'NO_SUCH_INTERPRETER')}\n")
        File.chmod(0o755, File.join(dir, name))
      end
    end
    reasons = []
    reasons << "gate-warning" unless index == 2
    reasons << "marker" unless index == 1
    reasons << "unavailable"
    check "#{name} #{mode}: stops with unavailable", s == 1 && e.empty? && last_line(o) == "post-check: stop (#{reasons.join(', ')})"
    check "#{name} #{mode}: its heading says unavailable", o.include?("#{%w[style marker gate][index]}: unavailable\n")
    check "#{name} #{mode}: the other checks still ran",
          (index == 0 || o.include?("style: 1 finding(s)\n")) && (index == 1 || o.include?("  work-marker-check: pr: 1 error(s)")) &&
          (index == 2 || o.include?("  public-safety-gate: warning:"))
  end
end
s, o, = post(PR + ["--style-reviewed"], body: stopping) { |dir| fake(dir, TOOLS[0], %q(warn "STYLE_FAILURE"; exit 2)) }
check "a style check exit 2 is unavailable and the later checks ran",
      s == 1 && last_line(o) == "post-check: stop (gate-warning, marker, unavailable)" && o.include?("style: unavailable\n  STYLE_FAILURE\n") &&
      o.include?("  work-marker-check: pr: 1 error(s)") && o.include?("  public-safety-gate: warning:")
s, o, = post(BODY) { |dir| File.delete(File.join(dir, TOOLS[1])) }
check "a missing marker checker does not matter without --marker-kind", s == 0 && o.include?("marker: skipped\n")

# symlink から起動しても、検査は実体の隣から探す (配備先の外の file を検査として起動しない)。
# 実体 (と本物の検査) を real/ に移し、起動する場所には symlink と、動けば印を残して止める代用品を置く。
s, o, e, dir = post(BODY) do |d|
  Dir.mkdir(File.join(d, "real"))
  (TOOLS + ["personal-post-check"]).each { |name| File.rename(File.join(d, name), File.join(d, "real", name)) }
  File.symlink(File.join(d, "real", "personal-post-check"), File.join(d, "personal-post-check"))
  TOOLS.each { |name| fake(d, name, %q(File.write(File.join(__dir__, "RAN"), ""); exit 1)) }
end
check "a symlinked launch uses the checks next to the real file", s == 0 && e.empty? && last_line(o) == "post-check: ok" && !File.exist?(File.join(dir, "RAN"))

# ---- 検査に渡す入力と argv、実行の順 (記録する代用品)
recorder = <<~'RB'
  name = File.basename(__FILE__)
  File.open("calls", "a") { |f| f.puts name }
  File.binwrite(name + ".input", STDIN.read)
  File.binwrite(name + ".args", ARGV.join("\n"))
  case name
  when "personal-ja-style-check" then puts "ja-style-check: 0 finding(s) in 1 input(s)"
  when "personal-work-marker-check" then puts "work-marker-check: #{ARGV[1]}: ok (markers v4)"
  end
RB
body = "BODY_ONLY 本文\n"
[[nil, nil], [nil, "TITLE 題名"], ["pr", "TITLE 題名 (#676)"], ["review-result", "TITLE 題名"], ["escape-issue", "TITLE 題名"]].each do |kind, title|
  args = BODY.dup
  args += ["--title", title] if title
  args += ["--marker-kind", kind] if kind
  s, o, e, dir = post(args, body: body) { |d| TOOLS.each { |name| fake(d, name, recorder) } }
  combined = title ? "#{title}\n\n#{body}" : body
  active = kind ? TOOLS : [TOOLS[0], TOOLS[2]]
  label = "kind=#{kind.inspect} title=#{title ? 'yes' : 'no'}"
  check "#{label}: ok", s == 0 && e.empty?
  check "#{label}: the checks run in the order style, marker, gate", File.read(File.join(dir, "calls")).lines.map(&:chomp) == active
  active.each do |name|
    marker = name == TOOLS[1]
    check "#{label}: stdin of #{name}", File.binread(File.join(dir, name + ".input")) == (marker && kind != "pr" ? body : combined).b
    check "#{label}: argv of #{name}", File.binread(File.join(dir, name + ".args")) == (marker ? ["--kind", kind, "--stdin"] : ["--stdin"]).join("\n").b
  end
  check "#{label}: the output adds neither the title nor the body", !o.include?("TITLE") && !o.include?("BODY_ONLY")
end

# ---- 入力の誤り (exit 2。stdout は空、stderr は 1 行)。検査は 1 つもかけない。
counting = %q(File.open("calls", "a") { |f| f.puts File.basename(__FILE__) })
usage = lambda do |label, args, body = CLEAN, &setup|
  s, o, e, dir = post(args, body: body) do |d|
    TOOLS.each { |name| fake(d, name, counting) }
    setup&.call(d)
  end
  check "usage error (#{label}) exits 2 with one stderr line and no stdout", s == 2 && o.empty? && e.lines.size == 1 && e.start_with?("personal-post-check: ")
  check "usage error (#{label}) is not reported as an unexpected error", !e.include?("unexpected error")
  check "usage error (#{label}) runs no check", !File.exist?(File.join(dir, "calls"))
end
usage.call("no arguments", [])
usage.call("--body-file without a value", ["--body-file"])
usage.call("unknown option", BODY + ["--unknown"])
usage.call("duplicate option", BODY + BODY)
usage.call("duplicate flag", BODY + ["--style-reviewed", "--style-reviewed"])
usage.call("unknown marker kind", BODY + ["--marker-kind", "comment"])
usage.call("pr without a title", BODY + ["--marker-kind", "pr"])
usage.call("empty title", BODY + ["--title", ""])
usage.call("blank title", BODY + ["--title", " 　"])
usage.call("multi-line title", BODY + ["--title", "一行目\n二行目"])
usage.call("title with a carriage return", BODY + ["--title", "一行目\r"])
usage.call("missing file", ["--body-file", "nope.txt"])
usage.call("directory", ["--body-file", "."])
usage.call("empty body", BODY + ["--style-reviewed"], "")
usage.call("blank body", BODY, " \t\r\n")
usage.call("full-width blank body", BODY, "　\n")
usage.call("invalid UTF-8", BODY, "\xFF".b)
unless Process.euid.zero?
  usage.call("unreadable file", BODY) { |d| File.chmod(0o000, File.join(d, "body.txt")) }
end
# FIFO は読みに行かない (書き手を待って止まらない)。止まったときに test ごと待たないよう、期限を付けて起動する。
$case += 1
fifo_dir = File.join(File.dirname(BASE), "fifo#{$case}")
FileUtils.cp_r(BASE, fifo_dir)
File.mkfifo(File.join(fifo_dir, "fifo"))
pid = Process.spawn(ENVIRONMENT, File.join(fifo_dir, "personal-post-check"), "--body-file", "fifo",
                    chdir: fifo_dir, unsetenv_others: true, out: File::NULL, err: File::NULL)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
fifo_status = nil
until fifo_status || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  _, fifo_status = Process.wait2(pid, Process::WNOHANG)
  sleep 0.1 unless fifo_status
end
unless fifo_status
  Process.kill("KILL", pid)
  Process.wait(pid)
end
check "a FIFO is rejected without waiting for a writer", fifo_status && fifo_status.exitstatus == 2

# ---- 大きさの上限 (byte で数える。題名と本文を合わせて 1 MiB まで)
limit = 1024 * 1024
fence = ["```\n", "\n```\n"]
room = limit - fence.sum(&:bytesize)
exact = fence[0] + "あ" * (room / 3) + "a" * (room % 3) + fence[1]
check "the fixture is exactly 1 MiB", exact.bytesize == limit
s, o, e, dir = post(["--body-file", "body file.txt"], body: exact, body_name: "body file.txt")
check "a body of exactly 1 MiB is ok (C locale, a space in the name)", s == 0 && e.empty? && o.include?("style: 0 finding(s)\n") && last_line(o) == "post-check: ok"
check "the body file is left unchanged", File.binread(File.join(dir, "body file.txt")) == exact.b
usage.call("a body one byte over the limit", BODY, exact + "a")
usage.call("a title that pushes the input over the limit", BODY + ["--title", "題名"], exact)
# 上限の 1 byte 先が文字の途中でも、大きさの誤りとして返す (UTF-8 として読めない、とは言わない)。
check "the cut for the size check falls inside a character", (limit + 1) % 3 != 0
s, o, e, = post(BODY, body: "あ" * (limit / 3 + 10))
check "an oversized body is reported as too large", s == 2 && o.empty? && e.lines.size == 1 && e.include?("byte を超える")

exit(@failed.zero? ? 0 : 1)
RUBY

echo "ok: post-check-test"
