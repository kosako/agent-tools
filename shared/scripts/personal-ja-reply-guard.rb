#!/usr/bin/env ruby
# frozen_string_literal: true
#
# personal-ja-reply-guard: Claude Code の Stop hook。turn の最後の答えが英語に逸れていたら、1 回だけ終了を止めて
# 日本語で書き直させる (#588)。運用 instruction は対話を日本語にすると決めているが、答えがたまに英語になる
# (instruction だけでは止められない)。
#
# 正本: docs/ja-reply-guard.md。仕組みと閾値は外部の claude-code-japanese-guard (Apache-2.0) を参考にした。code は
# 写していない (出典は docs)。
#
# 判定: Stop の入力の `last_assistant_message` (最後の答えの text) を読み、code と識別子を除いてから、英字
# ([A-Za-z]) と日本語の文字 (ひらがな・カタカナ・漢字・長音) を数える。英字が MIN_LATIN 字以上で、日本語の
# RATIO 倍を超えたら逸れとみなす。除くもの: fenced code block・inline code・URL・mail・Markdown の link の行き先・
# 識別子の形 (英数字の並びを - _ . / : でつないだもの。path・flag・test の名前など)。どれも入力の長さに対して
# 線形の時間で数える。閾値は手元の transcript の 2421 の答えで測って決めた (docs)。
#
# 止め方: 逸れていたら stderr に理由を書いて exit 2 (Claude は stderr を続ける理由として受け取る)。書き直しは
# 1 turn に 1 回だけ: `stop_hook_active` が true (stop hook で既に続けている) なら止めない。2 回目も英語なら
# そのまま通す (loop しない)。
#
# 失敗のとき: 何も止めない (exit 0)。入力が JSON でない・UTF-8 として不正・Stop でない・`last_assistant_message` が
# 無い (古い Claude Code) ・想定外の例外のどれでも、turn を通す。答えの言語の steering であって、品質や安全の gate では
# ないので、hook の失敗で session を塞がない。transcript の file は読まない (Stop の時点で最後の答えがまだ
# 書かれていないことがある。docs)。
#
# env (どれも省略可。形が外れる値は既定に戻す):
# - AGENT_TOOLS_JA_GUARD_RATIO: 英字が日本語の何倍を超えたら逸れか (既定 3。1 以上の数)。
# - AGENT_TOOLS_JA_GUARD_MIN_LATIN: 判定の対象にする英字の最小の数 (既定 25。1 以上の整数)。
# - AGENT_TOOLS_JA_GUARD_DISABLE: 空でなければ何もしない。
#
# exit: 0 = 通す / 2 = 逸れていたので止める。stderr の理由に答えの text は載せない。
#
# C locale でも読む text を UTF-8 として扱う (#432。personal-public-safety-gate と同じ固定)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

require "json"

module JaReplyGuard
  RATIO = 3.0
  MIN_LATIN = 25
  MAX_INPUT_BYTES = 4 * 1024 * 1024

  REASON = "最後の答えが英語になっています。運用 instruction は対話を日本語にすると決めています。" \
           "同じ内容を日本語で書き直してください (code・command・path・識別子は元のままで構いません)。"

  # fenced code の開きの行 (行の頭の空白の後に ``` か ~~~ が 3 つ以上)。
  FENCE_OPEN = /\A[ \t]*(`{3,}|~{3,})/.freeze
  # 行の中で数えない区間。どの正規表現も token の頭 (直前が同じ種類の文字でない位置) からだけ始め、入力の長さに
  # 対して線形の時間で終わる形にする (長い非一致の入力で hook を待たせない)。
  LINK = /\[([^\[\]]*)\]\([^()\s]*\)/.freeze                                 # Markdown の link は本文だけ残す
  URL = %r{(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://\S+}.freeze
  MAIL = /(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)+/.freeze
  IDENT = %r{(?<![A-Za-z0-9])[A-Za-z0-9]+(?:[-_./:][A-Za-z0-9]+)+}.freeze  # 識別子の形 (path・flag・test の名前など)
  JA = /[\p{Hiragana}\p{Katakana}\p{Han}ー]/.freeze

  # 数えない区間を空白に置き換える。fenced code は行ごとに読み、開いた記号と同じ記号が同じ数以上並ぶ行で閉じる
  # (閉じていなければ末尾まで)。``` の fence の開きの行に ` がまだあれば、fence ではなく inline code として読む。
  def self.mask(text)
    fence = nil # 閉じの行の正規表現
    text.split("\n", -1).map do |line|
      if fence
        fence = nil if fence.match?(line)
        next ""
      end
      m = FENCE_OPEN.match(line)
      if m && !(m[1].start_with?("`") && m.post_match.include?("`"))
        fence = /\A[ \t]*#{Regexp.escape(m[1][0])}{#{m[1].length},}[ \t\r]*\z/
        next ""
      end
      mask_line(line)
    end.join("\n")
  end

  def self.mask_line(line)
    t = mask_code_spans(line)
    t.gsub!(LINK, '\1')
    t.gsub!(URL, " ")
    t.gsub!(MAIL, " ")
    t.gsub!(IDENT, " ")
    t
  end

  # inline code を空白にする。開きの ` の並びと同じ長さの並びで閉じる (`` a`b `` も 1 つの区間)。閉じの無い並びは
  # そのまま残す。並びごとに、同じ長さの次の並びを後ろから引いておき、一度の走査で済ませる。
  def self.mask_code_spans(line)
    return line.dup unless line.include?("`")

    runs = []
    line.scan(/`+/) { runs << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
    following = Array.new(runs.size)
    last = {}
    (runs.size - 1).downto(0) do |i|
      length = runs[i][1] - runs[i][0]
      following[i] = last[length]
      last[length] = i
    end
    t = line.dup
    i = 0
    while i < runs.size
      j = following[i]
      if j
        t[runs[i][0]...runs[j][1]] = " " * (runs[j][1] - runs[i][0]) # 長さを保ち、後ろの位置をずらさない
        i = j + 1
      else
        i += 1
      end
    end
    t
  end

  # [英字の数, 日本語の文字の数]
  def self.counts(text)
    masked = mask(text)
    [masked.count("A-Za-z"), masked.length - masked.gsub(JA, "").length]
  end

  def self.drift?(text, ratio: RATIO, min_latin: MIN_LATIN)
    latin, ja = counts(text)
    latin >= min_latin && latin > ratio * ja
  end

  def self.ratio_from(env)
    value = Float(env["AGENT_TOOLS_JA_GUARD_RATIO"].to_s, exception: false)
    value && value.finite? && value >= 1 ? value : RATIO
  end

  def self.min_latin_from(env)
    value = Integer(env["AGENT_TOOLS_JA_GUARD_MIN_LATIN"].to_s, 10, exception: false)
    value && value >= 1 ? value : MIN_LATIN
  end

  # [exit code, stderr に出す理由 (nil 可)]
  def self.decide(input, env)
    return [0, nil] unless env["AGENT_TOOLS_JA_GUARD_DISABLE"].to_s.empty?

    payload = JSON.parse(input)
    return [0, nil] unless payload.is_a?(Hash) && payload["hook_event_name"] == "Stop"
    return [0, nil] if payload["stop_hook_active"] == true

    message = payload["last_assistant_message"]
    return [0, nil] unless message.is_a?(String) && message.valid_encoding?

    return [0, nil] unless drift?(message, ratio: ratio_from(env), min_latin: min_latin_from(env))

    [2, REASON]
  rescue JSON::ParserError, EncodingError
    [0, nil]
  end

  def self.run(stdin: $stdin, env: ENV, err: $stderr)
    input = stdin.read(MAX_INPUT_BYTES + 1).to_s
    return 0 if input.bytesize > MAX_INPUT_BYTES

    input = input.dup.force_encoding(Encoding::UTF_8)
    return 0 unless input.valid_encoding? # 読めない入力は通す

    code, reason = decide(input, env)
    err.puts(reason) if reason
    code
  rescue StandardError
    0 # fail-open: hook の想定外で turn を塞がない
  end
end

exit JaReplyGuard.run if $PROGRAM_NAME == __FILE__
