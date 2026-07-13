#!/usr/bin/env ruby
# frozen_string_literal: true

# public-safety-gate: pre-commit stage の git gate。staged diff の追加行を scan し、
# public repo に入れてはならないもの (secret / 実 home path / 個人用 local file) を
# commit 前に block する。6 つの skill / instruction が繰り返し宣言してきた
# 「commit 前 public safety check」の機械判定可能な部分を決定的実行に出したもの (#202)。
#
# 正本: docs/git-hook-gates.md。#200 §4.1。
#
# 強度ラベル (偽らない): 通常経路 (git commit) に対する best-effort guardrail。
# `--no-verify` / hooksPath 差し替え / 別 client で迂回できる。検出も列挙依存の
# regex なので網羅ではない (「秘密は書かない」判断そのものは人間 / skill の領分)。
# 公開前の最終確認点は push / CI 側に置く。
#
# 検出クラス:
# - definite (exit 1 で block): private key block / 既知 token 形 / 実 HOME path の
#   literal 混入 / 個人用 local file (*.local / *.local.md) の staged 追加 /
#   local pattern file の追加パターン一致
# - suspicious (警告のみ・block しない): 汎用 credential 代入ヒューリスティック。
#   「疑わしいだけの finding は block でなく明示確認に落とす」(#200 §4.1) の実装。
# 誤検知の escape: 該当行に `public-safety: allow` を含める (レビュー済みの明示)。
#
# 秘匿出力規律: finding の値そのものは出力しない (file:line と種別のみ)。
#
# 私物パターン (planning tool の domain 等、public repo に書けないもの) は tracked な
# 本体に持たず、untracked の local pattern file から読む:
#   ~/.config/agent-tools/public-safety-patterns.local (1 行 1 Ruby regex、# コメント可)
# 不在は「追加パターンなし」として扱う (設計上 optional)。読めるのに parse できない
# regex は exit 2 で止める (ユーザー設定の壊れを黙って無視しない)。
#
# 副作用ゼロ・network なし。読むのは `git diff --cached` / staged file 一覧 /
# local pattern file のみ。

module PublicSafetyGate
  VERSION = "1"

  ALLOW_PRAGMA = "public-safety: allow"

  LOCAL_PATTERNS_PATH = File.join(ENV["HOME"].to_s, ".config", "agent-tools",
                                  "public-safety-patterns.local")

  # 既知の token 形。誤検知が実質出ない精度の高いものだけを definite に置く。
  # 汎用の「それっぽい代入」は SUSPICIOUS_PATTERN (警告どまり) 側。
  DEFINITE_PATTERNS = {
    "private-key-block" => /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    "github-token" => /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b/,
    "aws-access-key" => /\bAKIA[0-9A-Z]{16}\b/,
    "slack-token" => /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/,
    "anthropic-key" => /\bsk-ant-[A-Za-z0-9_-]{20,}\b/,
    "openai-key" => /\bsk-proj-[A-Za-z0-9_-]{20,}\b/,
    "stripe-key" => /\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b/,
  }.freeze

  # 「credential らしき代入」ヒューリスティック。過検出しうるので suspicious (警告のみ)。
  SUSPICIOUS_PATTERN =
    /(?:password|passwd|secret|api[_-]?key|token)["']?\s*[:=]\s*["'][^"'\s]{8,}["']/i

  # ユーザー正本・個人メモの命名規約 (このリポジトリ群のローカル慣行)。
  # .gitignore が第一防衛だが、`git add -f` の事故をここで止める。
  LOCAL_ONLY_FILE = /(?:\.local|\.local\.md)\z/

  Finding = Struct.new(:file, :line, :name, :severity)

  module_function

  # 個人 home directory の親 (この下 1 段が個人名になる)。regex は実行時に組む
  # (静的 literal だと check-injection の absolute-path 検査自身にかかるため)。
  HOME_PARENTS = %w[Users home].freeze

  # 実 home path の literal 混入だけを見る (汎用の例示 path は文書として正当)。
  # HOME が個人 home の形をしていないとき (CI 等) は対象外。
  def home_needle
    home = ENV["HOME"].to_s
    home if home.match?(%r{\A/(?:#{HOME_PARENTS.join('|')})/[^/]+})
  end

  def load_local_patterns(path)
    return [] unless File.file?(path)

    patterns = []
    File.readlines(path).each_with_index do |raw, i|
      line = raw.chomp.strip
      next if line.empty? || line.start_with?("#")

      begin
        patterns << [format("local-pattern:%d", i + 1), Regexp.new(line)]
      rescue RegexpError
        # RegexpError#message は regex 本文を含む。private パターン置き場の内容を
        # 出力しない契約 (H206-03) のため、位置情報だけを出す。
        raise ArgumentError, "#{path}:#{i + 1}: invalid regex (パターン内容は表示しません)"
      end
    end
    patterns
  end

  def scan_line(content, extra_patterns, home)
    return [] if content.include?(ALLOW_PRAGMA)

    names = []
    DEFINITE_PATTERNS.each { |name, re| names << [name, :definite] if content.match?(re) }
    extra_patterns.each { |name, re| names << [name, :definite] if content.match?(re) }
    names << ["home-path", :definite] if home && content.include?(home)
    names << ["credential-assignment", :suspicious] if content.match?(SUSPICIOUS_PATTERN)
    names
  end

  # git の quoted path ("b/na\tme" 形式) を復号する。quote されていなければそのまま。
  def unquote_path(target)
    return target unless target.start_with?('"') && target.end_with?('"') && target.size >= 2

    target[1..-2].gsub(/\\(?:[abfnrtv\\"]|\d{1,3})/) do |esc|
      body = esc[1..-1]
      case body
      when "\\" then "\\"
      when '"' then '"'
      when "n" then "\n"
      when "t" then "\t"
      when "a" then "\a"
      when "b" then "\b"
      when "f" then "\f"
      when "r" then "\r"
      when "v" then "\v"
      else body.to_i(8).chr
      end
    end
  end

  # unified diff の追加行を (file, 新 line 番号, 内容) で走査する。
  # hunk 内の行 (+ / - / 空白 / "\" 始まり) を先に処理し、ヘッダー解釈 (--- / +++) は
  # hunk 外に限定する。追加行の内容が "++ " で始まると "+++ " に見えるため (H206-01)。
  def scan_diff(diff_text, extra_patterns, home)
    findings = []
    file = nil
    lineno = nil
    in_hunk = false
    expect_new_path = false
    diff_text.each_line do |raw|
      line = raw.chomp
      if in_hunk
        case line[0]
        when "+"
          if file && lineno
            scan_line(line[1..-1].to_s, extra_patterns, home).each do |name, severity|
              findings << Finding.new(file, lineno, name, severity)
            end
            lineno += 1
          end
          next
        when "-", "\\" then next
        when " ", nil
          lineno += 1 if lineno
          next
        end
        in_hunk = false # hunk の終端 (次の header 類) — fall through して header を解釈する
      end
      if line.start_with?("diff --git ")
        file = nil
        lineno = nil
        expect_new_path = false
      elsif line.start_with?("--- ")
        expect_new_path = true
      elsif expect_new_path && line.start_with?("+++ ")
        target = unquote_path(line[4..-1])
        file = target == "/dev/null" ? nil : target.sub(%r{\Ab/}, "")
        expect_new_path = false
      elsif (m = /\A@@ -[^ ]+ \+(\d+)/.match(line))
        lineno = Integer(m[1])
        in_hunk = true
      end
    end
    findings
  end

  def staged_local_only_files(added_paths)
    added_paths.select { |p| p.match?(LOCAL_ONLY_FILE) }
  end

  # 出力形式を pin した diff 用の共通 flag (parser の前提を git 設定から独立させる)。
  GIT_DIFF_PIN = %w[git -c diff.noprefix=false -c diff.mnemonicprefix=false
                    -c core.quotepath=true diff --cached --no-color --no-ext-diff].freeze

  def git_read(argv)
    out = IO.popen(argv, &:read)
    raise ArgumentError, "#{argv.join(' ')} failed" unless $?.success?

    # 非 UTF-8 の混入 (binary 混じりの text 等) で regex が例外にならないよう scrub する
    # (#149 と同じ方式)。判定用のみで書き込み経路はない。
    out.force_encoding(Encoding::UTF_8)
    out.valid_encoding? ? out : out.scrub("�")
  end

  def run
    extra = load_local_patterns(LOCAL_PATTERNS_PATH)
    diff = git_read(GIT_DIFF_PIN)
    # rename / copy でも新 path を検査対象にする (A のみだと git mv で素通り。H206-06)。
    added = git_read(GIT_DIFF_PIN + %w[--name-only --diff-filter=ACR -z]).split("\0")

    findings = scan_diff(diff, extra, home_needle)
    staged_local_only_files(added).each do |path|
      findings << Finding.new(path, 0, "local-only-file", :definite)
    end

    blocked = findings.select { |f| f.severity == :definite }
    warned = findings.select { |f| f.severity == :suspicious }

    warned.each do |f|
      warn "public-safety-gate: warning: #{f.file}:#{f.line}: [#{f.name}] " \
           "credential らしき代入があります。意図した内容か確認してください (block はしません)。"
    end
    unless blocked.empty?
      blocked.each do |f|
        warn "public-safety-gate: blocked: #{f.file}:#{f.line}: [#{f.name}]"
      end
      warn "public-safety-gate: #{blocked.size} finding(s)。値は表示しません。該当行を直すか、" \
           "レビュー済みの誤検知なら該当行に `#{ALLOW_PRAGMA}` を書いて再 commit してください。"
      return 1
    end
    0
  rescue ArgumentError => e
    warn "public-safety-gate: error: #{e.message}"
    2
  rescue StandardError => e
    # 想定外も入力・構成エラーの exit 2 に倒す (fail-closed)。内容を含みうる message は
    # 出さず class 名のみ。
    warn "public-safety-gate: unexpected error (#{e.class})"
    2
  end
end

exit PublicSafetyGate.run if $PROGRAM_NAME == __FILE__
