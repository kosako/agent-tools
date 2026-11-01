#!/bin/sh
# personal-ja-reply-guard.rb の self-test (#588)。判定 (JaReplyGuard) は require して直接、hook は ruby で起動して stdin の
# JSON と exit code と stderr を確かめる。network access なし。何も書かない (stdout は空)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
src="$repo_root/shared/scripts/personal-ja-reply-guard.rb"

[ -f "$src" ] || fail "missing $src"
[ -x "$src" ] || fail "not executable: $src"

# 親の環境の閾値の env を継承しない (test の既定の判定が変わる)。
unset AGENT_TOOLS_JA_GUARD_RATIO AGENT_TOOLS_JA_GUARD_MIN_LATIN AGENT_TOOLS_JA_GUARD_DISABLE

ruby -r"$script_dir/lib/check_helper" -rjson -ropen3 - "$src" <<'RUBY'
src = ARGV[0]
require src

english = "Done. I merged the pull request, deployed the changes, and doctor reports ok. Nothing is left to do."
japanese = "PR を merge して配備まで終えました。doctor は ok で、残りの作業はありません。"
drift = ->(text, **kw) { JaReplyGuard.drift?(text, **kw) }

# ---- 判定 ----
check("英語の答えは逸れ", drift.call(english))
check("日本語の答えは逸れでない", !drift.call(japanese))
check("英字が 25 字未満の英語は対象外", !drift.call("Done. All good."))
check("英字がちょうど 25 字なら対象", drift.call("a" * 25))
check("英字 24 字は対象外", !drift.call("a" * 24))
code = "変更の要点です。\n\n```ruby\n" + ("def example_method(argument)\n  puts argument.inspect\nend\n" * 20) + "```\n\n以上です。"
check("code の多い日本語の答えは逸れでない (fenced code を数えない)", !drift.call(code))
check("閉じていない fenced code も末尾まで数えない", !drift.call("見てください。\n```\n" + english * 3))
idents = "test-preflight・test-gclone・test-shell-syntax も pass しました。残りは数件です。"
check("backtick の外の識別子の形を数えない (path・test の名前)", !drift.call(idents))
check("inline code を数えない", !drift.call("`#{english}` を確かめました。"))
check("URL を数えない", !drift.call("https://example.com/#{"a" * 80} を見ました。"))
check("mail を数えない", !drift.call("#{"a" * 40}@example.com に送りました。"))
check("Markdown の link の行き先は数えない", !drift.call("[資料](https://example.com/#{"b" * 80}) を読みました。"))
check("Markdown の link の本文は数える", drift.call("[#{english}](https://example.com) を見て"))
check("日本語を少し含む英語の答えは逸れ (英語の文に日本語の語を引く)", drift.call("I updated the 「次セッションの入口」 section and the work log, and everything is merged now."))
# 比の境界: 英字が日本語の 3 倍を超えたら逸れ (ちょうど 3 倍は逸れでない)
check("英字がちょうど日本語の 3 倍は逸れでない", !drift.call(("a" * 30) + ("あ" * 10)))
check("英字が日本語の 3 倍を超えたら逸れ", drift.call(("a" * 31) + ("あ" * 10)))
# backtick の数を合わせる inline code (#606 の review の F1)
check("二重の backtick の inline code を数えない", !drift.call("``#{english}`` を確認しました。"))
check("二重の backtick の中の 1 つの ` も区間の中", !drift.call("``#{english} ` #{english}`` を確認しました。"))
check("閉じの無い backtick の並びの後ろは数える", drift.call("`` #{english}"))
# fence は開いた記号と同じ記号で閉じる (F2)
check("~~~ の fence の中の ``` の行で、後ろの英語を消さない", drift.call("~~~\n```\n~~~\n#{english}"))
check("``` の fence の中の ~~~ の行で、後ろの英語を消さない", drift.call("```\n~~~\n```\n#{english}"))
check("短い記号の行では長い fence を閉じない", !drift.call("見てください。\n````\n```\n#{english}\n````\n以上です。"))
check("行の頭の ```x``` は fence でなく inline code", drift.call("```x```\n#{english}"))
check("字下げした fence も除く", !drift.call("1. 手順です。\n    ```sh\n    #{english}\n    ```\n"))
check("行の途中の ``` は fence を開かない", drift.call("見て ```\n#{english}"))
# 行をまたぐ inline code・引用の中の fence・URL の終わり (#606 の review の F6〜F8)
check("段落の中で行をまたぐ inline code を数えない", !drift.call("例です。`Run the command shown below.\nCheck the result before proceeding.`以上です。"))
check("空行をまたいで inline code を対にしない", drift.call("見て ` です。\n\n#{english}\n\n` 以上"))
check("引用の中の fence を除く", !drift.call("確認結果です。\n> ~~~text\n> #{english}\n> ~~~\n完了しました。"))
check("引用の中の fence の後ろの英語は数える", drift.call("> ```\n> x\n> ```\n#{english}"))
check("autolink の URL の後ろの日本語を消さない", !drift.call("GitHub Actions workflow permissions は <https://example.com>。更新と動作確認を済ませました。"))
check("URL の直後の日本語を消さない", !drift.call("GitHub Actions workflow permissions は https://example.com/settingsで更新と動作確認を済ませました。"))

# ---- hook の入出力 ----
run = lambda do |payload, env = {}|
  input = payload.is_a?(String) ? payload : JSON.generate(payload)
  out, err, status = Open3.capture3(env, "ruby", src, stdin_data: input)
  [status.exitstatus, out, err]
end
stop = ->(message, active: false) { { "hook_event_name" => "Stop", "stop_hook_active" => active, "last_assistant_message" => message } }

code_, out, err = run.call(stop.call(english))
check("英語の答えで exit 2", code_ == 2)
check("止めるときは stderr に日本語の理由", err.include?("日本語で書き直してください"))
check("理由に答えの text を載せない", !err.include?("merged the pull request"))
check("stdout には何も出さない", out.empty?)
code_, out, err = run.call(stop.call(japanese))
check("日本語の答えで exit 0 と出力なし", code_ == 0 && out.empty? && err.empty?)
code_, = run.call(stop.call(english, active: true))
check("stop_hook_active が true なら止めない (1 turn に 1 回だけ)", code_ == 0)
code_, = run.call(stop.call(english).merge("hook_event_name" => "SubagentStop"))
check("Stop でない event では止めない", code_ == 0)
code_, = run.call("not json")
check("JSON でない入力では止めない", code_ == 0)
code_, = run.call("[1,2]")
check("object でない JSON では止めない", code_ == 0)
code_, = run.call({ "hook_event_name" => "Stop", "stop_hook_active" => false })
check("last_assistant_message が無い (古い Claude Code) なら止めない", code_ == 0)
code_, = run.call(stop.call(nil).merge("last_assistant_message" => ["x"]))
check("last_assistant_message が文字列でないなら止めない", code_ == 0)
code_, = run.call(stop.call(english + ("a" * (4 * 1024 * 1024))))
check("4 MiB を超える入力では止めない", code_ == 0)
code_, out, err = run.call(JSON.generate(stop.call(english)).b.sub("Done.", "Done.\xff".b).force_encoding(Encoding::UTF_8))
check("不正な UTF-8 の入力では止めず、何も出さない (読めない入力は通す)", code_ == 0 && out.empty? && err.empty?)
bad = "#{english}\xff".dup.force_encoding(Encoding::UTF_8)
check("不正な UTF-8 の答えは decide でも通す", JaReplyGuard.decide(JSON.generate(stop.call("x")).sub('"x"', "\"#{bad}\""), {}) == [0, nil])
# JSON の対の無い surrogate の扱いは json の版で違う (Ruby 2.6 は ? に置き換える)。どちらでも例外で落ちないこと。
code_, out, = run.call(JSON.generate(stop.call(english)).sub("Done.", "Done.\\ud800"))
check("JSON の対の無い surrogate でも落ちない (exit 0 か 2)", [0, 2].include?(code_) && out.empty?)

# ---- 長い非一致の入力 (F3) ----
# どの区間の正規表現も線形の時間で終わること。二次の時間なら 1 MiB で何分もかかる。上限は CI の遅さを見込んで広く取る。
# 正規表現の engine は必ず要る文字列 (:// や @) が無い入力をすぐ諦めるので、入力にはそれを含める。
big = 1024 * 1024
{
  "識別子の形の後ろが区切りだけ" => ("a" * big) + "-",
  "URL の scheme の後ろに区切りの外の文字" => ("a" * big) + "_://",
  "mail の domain が無い" => ("a" * big) + "@",
  "link の [ だけ" => "[" * big,
  "link の行き先が閉じない" => "[a](" * (big / 4),
  "長さの違う backtick の並び" => (1..1400).map { |n| "`" * n }.join("a"),
  "日本語の短い inline code の連なり" => "`あ` " * 170_000,
  "日本語の短い inline code の連なり (行ごと)" => "`あ`\n" * 200_000,
  "閉じない fence の後ろの長い行" => "```\n" + ("a" * big),
}.each do |label, text|
  # 子で判定し、上限を過ぎたら止めて FAIL にする (退行で test 自体が何十分も止まらないように)。
  pid = fork do
    JaReplyGuard.drift?(text)
    exit!(0)
  end
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  status = nil
  while (status = Process.wait2(pid, Process::WNOHANG)).nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    sleep 0.05
  end
  if status.nil?
    Process.kill("KILL", pid)
    Process.wait(pid)
  end
  check("#{label} (1 MiB 前後) が 15 秒以内に終わる", status && status[1].success?)
end

# ---- env ----
code_, = run.call(stop.call(english), "AGENT_TOOLS_JA_GUARD_DISABLE" => "1")
check("DISABLE が空でなければ何もしない", code_ == 0)
code_, = run.call(stop.call(english), "AGENT_TOOLS_JA_GUARD_DISABLE" => "")
check("DISABLE が空なら効かない", code_ == 2)
code_, = run.call(stop.call(english), "AGENT_TOOLS_JA_GUARD_MIN_LATIN" => "1000")
check("MIN_LATIN を上げると短い英語は対象外", code_ == 0)
mixed = ("a" * 50) + ("あ" * 10) # 英字が日本語の 5 倍
code_, = run.call(stop.call(mixed), "AGENT_TOOLS_JA_GUARD_RATIO" => "10")
check("RATIO を上げると混ざった答えは逸れでない", code_ == 0)
%w[abc 0.5 0 -3 NaN Infinity].each do |bad|
  code_, = run.call(stop.call(mixed), "AGENT_TOOLS_JA_GUARD_RATIO" => bad)
  check("形の外れる RATIO (#{bad}) は既定の 3 に戻す", code_ == 2)
end
%w[abc 0 -1 2.5].each do |bad|
  code_, = run.call(stop.call("a" * 25), "AGENT_TOOLS_JA_GUARD_MIN_LATIN" => bad)
  check("形の外れる MIN_LATIN (#{bad}) は既定の 25 に戻す", code_ == 2)
end

# ---- 失敗のとき (fail-open) ----
require "stringio"
broken_io = Object.new
def broken_io.read(*_args)
  raise IOError, "boom"
end
err_io = StringIO.new
check("想定外の例外では止めない (exit 0)", JaReplyGuard.run(stdin: broken_io, env: {}, err: err_io) == 0)
check("想定外の例外では何も出さない", err_io.string.empty?)
exit(@failed.zero? ? 0 : 1)
RUBY

# C locale でも日本語を数える (#432)。
out=$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"PR を merge して配備まで終えました。doctor は ok で、残りの作業はありません。"}' \
  | LC_ALL=C LANG=C ruby "$src" 2>&1) || fail "C locale: a Japanese answer must pass (exit 0): $out"
[ -z "$out" ] || fail "C locale: a Japanese answer must produce no output: $out"

echo "ok: ja-reply-guard"
