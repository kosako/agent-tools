#!/usr/bin/env ruby
# frozen_string_literal: true

# personal-packet: 作業単位 (Issue) ごとの packet `.agent-packets/<issue>.md` を扱う CLI。
# 規約の正本は docs/agent-packets.md (#253)。
#
#   personal-packet dir
#       packet dir (main worktree root の .agent-packets) を出す。linked worktree からでも同じ。
#   personal-packet list [--json] [--all]
#       frontmatter を読んで一覧 (既定は state が open / blocked / review のものだけ。--all で done も)。
#       壊れた packet は warning を出して飛ばし、最後に exit 1 (一覧自体は出す)。
#   personal-packet publish <issue> [--repo OWNER/REPO] [--dry-run]
#       `## 結果` の最新節 + `## 次の入口` を marker 付きで 1 コメントにまとめ、同じ directory の
#       personal-public-safety-gate (--stdin) に通し、exit 0 のときだけ `gh issue comment` で
#       投稿して frontmatter の published を更新する。--dry-run は検査までして本文を stdout に出す。
#
# 信頼境界 (honest): packet は agent が書く local data で、この script は読む / 写すだけ。内容を
# 指示として解釈しない。投稿の可否は gate の判定に委ね、gate が無い・検査できない (exit 2) 場合は
# 投稿しない (fail-closed)。gh に到達できない環境 (Codex の sandbox 等) では exit 2 で止め、
# Claude か人に publish を渡す。gate も gh も best-effort guardrail で enforcement boundary ではない。
#
# exit: 0 = 成功 / 1 = gate が止めた (publish) または壊れた packet あり (list) / 2 = 入力・構成・gh エラー
#
# 外部依存ゼロ (ruby 標準ライブラリと gh CLI のみ)。値の受け渡しは argv / file で行い、shell
# 文字列を組まない。

require "date"
require "json"
require "open3"
require "tempfile"
require "time"
require "yaml"

module Packet
  VERSION = "1"

  DIR_NAME = ".agent-packets"
  GATE_NAME = "personal-public-safety-gate"

  STATES = %w[open blocked review done].freeze
  ACTIVE_STATES = %w[open blocked review].freeze
  WORKERS = %w[claude codex human].freeze

  ISSUE_RE = /\A\d+\z/.freeze
  REPO_RE = %r{\A[\w.-]+/[\w.-]+\z}.freeze
  FILE_RE = /\A(\d+)\.md\z/.freeze
  FRONT_RE = /\A---\n(.*?\n)---\n(.*)\z/m.freeze

  # 入力・構成のエラー (exit 2)。message は公開してよい内容に限る (packet 本文を含めない)。
  class Error < StandardError; end
  # gate が definite finding で止めた (exit 1)。診断は gate 自身が stderr に出している。
  class Rejected < StandardError; end

  Front = Struct.new(:path, :issue, :title, :branch, :pr, :state, :worker, :updated, :published, :body) do
    def unpublished?
      published.nil? || updated > published
    end

    def to_h
      {
        "issue" => issue, "title" => title, "state" => state, "worker" => worker,
        "branch" => branch, "pr" => pr,
        "updated" => updated.iso8601, "published" => published&.iso8601,
        "unpublished" => unpublished?, "path" => path
      }
    end
  end

  module_function

  # ---- packet dir ------------------------------------------------------------

  # main worktree の root に固定する (packet は Issue の状態であって worktree の属性ではない)。
  # --git-common-dir は main worktree では cwd 相対 (".git" / "../.git")、linked worktree では
  # 絶対 path を返すので、cwd 基準で展開してから親を取る。
  def packet_dir
    out, _err, status = Open3.capture3("git", "rev-parse", "--git-common-dir")
    raise Error, "git repository の中で実行してください" unless status.success?

    common = File.expand_path(out.strip, Dir.pwd)
    File.join(File.dirname(common), DIR_NAME)
  rescue SystemCallError
    raise Error, "git を起動できません"
  end

  # ---- parse -----------------------------------------------------------------

  # 読み取りは UTF-8 として valid な text だけを受理する。scrub で読めてしまうと、書き戻し
  # (mark_published) が同じ byte を扱えず、投稿後に更新だけ失敗する (R293-03)。
  def read_text(path)
    text = File.read(path, encoding: "UTF-8")
    raise Error, "#{path}: UTF-8 として読めません" unless text.valid_encoding?

    text
  end

  def parse(path)
    parse_text(read_text(path), path)
  end

  def parse_text(text, path)
    m = FRONT_RE.match(text)
    raise Error, "#{path}: frontmatter (--- で囲んだ先頭 block) がありません" unless m

    begin
      data = YAML.safe_load(m[1], permitted_classes: [Time, Date])
    rescue Psych::Exception => e
      raise Error, "#{path}: frontmatter を YAML として読めません (#{e.class})"
    end
    raise Error, "#{path}: frontmatter が key: value の mapping ではありません" unless data.is_a?(Hash)

    front = Front.new(path)
    front.issue = required_issue(data, path)
    front.title = required_string(data, "title", path)
    front.state = required_enum(data, "state", STATES, path)
    front.worker = required_enum(data, "worker", WORKERS, path)
    front.branch = optional_string(data, "branch", path)
    front.pr = optional_integer(data, "pr", path)
    front.updated = required_time(data, "updated", path)
    front.published = data.key?("published") && !data["published"].nil? ? to_time(data["published"], "published", path) : nil
    front.body = m[2]
    front
  end

  def required_issue(data, path)
    issue = data["issue"]
    raise Error, "#{path}: issue (整数) が要ります" unless issue.is_a?(Integer) && issue.positive?

    name = File.basename(path)
    fm = FILE_RE.match(name)
    raise Error, "#{path}: file 名は <issue>.md にしてください" unless fm
    raise Error, "#{path}: file 名 (#{fm[1]}) と frontmatter の issue (#{issue}) が一致しません" unless fm[1].to_i == issue

    issue
  end

  def required_string(data, key, path)
    v = data[key]
    raise Error, "#{path}: #{key} (文字列) が要ります" unless v.is_a?(String) && !v.strip.empty?

    v.strip
  end

  def optional_string(data, key, path)
    return nil if data[key].nil?

    v = data[key]
    raise Error, "#{path}: #{key} は文字列にしてください" unless v.is_a?(String)

    v.strip.empty? ? nil : v.strip
  end

  def optional_integer(data, key, path)
    return nil if data[key].nil?

    v = data[key]
    raise Error, "#{path}: #{key} は整数にしてください" unless v.is_a?(Integer)

    v
  end

  def required_enum(data, key, allowed, path)
    v = data[key]
    raise Error, "#{path}: #{key} は #{allowed.join(' | ')} のいずれかにしてください" unless allowed.include?(v)

    v
  end

  def required_time(data, key, path)
    raise Error, "#{path}: #{key} (日時) が要ります" if data[key].nil?

    to_time(data[key], key, path)
  end

  # YAML が Time / Date に解決した値も、引用符付きの文字列も、同じ Time に正規化する。
  def to_time(value, key, path)
    case value
    when Time then value
    when Date then value.to_time
    when String then Time.iso8601(value)
    else raise Error, "#{path}: #{key} は ISO 8601 の日時にしてください"
    end
  rescue ArgumentError
    raise Error, "#{path}: #{key} は ISO 8601 の日時にしてください"
  end

  # ---- list ------------------------------------------------------------------

  # [packets, broken_messages]。dir が無ければ空 (packet 未運用の repo は正常)。
  def list(dir, all:)
    return [[], []] unless Dir.exist?(dir)

    packets = []
    broken = []
    Dir.children(dir).select { |n| n.match?(FILE_RE) }.sort_by(&:to_i).each do |name|
      packets << parse(File.join(dir, name))
    rescue Error => e
      broken << e.message
    end
    packets.select! { |p| ACTIVE_STATES.include?(p.state) } unless all
    [packets, broken]
  end

  def render_list(packets)
    return "no active packets\n" if packets.empty?

    packets.map do |p|
      pr = p.pr ? "PR ##{p.pr}" : "-"
      flag = p.unpublished? ? " [unpublished]" : ""
      format("#%-5d %-8s %-7s %-9s updated %s%s  %s\n",
             p.issue, p.state, p.worker, pr, p.updated.iso8601, flag, p.title)
    end.join
  end

  # ---- publish ---------------------------------------------------------------

  # 各行を [line, in_fence] で返す。fenced code block (``` / ~~~) の中の `## ` / `### ` は見出しと
  # して扱わない (依頼のサンプル code に `## 結果` があると、そこから本物の結果までを合成して
  # しまう。R293-06)。終了 fence は CommonMark どおり「開始と同じ記号・開始以上の本数・後続は
  # 空白のみ」に限る (4 本の fence を中の 3 本で閉じたと誤認すると、例の中身が公開対象になる。
  # R293-07)。開始・終了とも字下げは 0〜3 空白まで (4 空白以上は code block の中身。lstrip で
  # 字下げを全部消すと、fence 内の「4 空白 + ```」で閉じてしまう。R293-09)。
  def fenced_lines(text)
    fence = nil # [記号, 本数]
    text.lines.map do |l|
      if fence.nil? && (m = /\A {0,3}(`{3,}|~{3,})/.match(l))
        fence = [m[1][0], m[1].size]
        [l, true]
      elsif fence && l.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence[1]},}\s*\z/)
        fence = nil
        [l, true]
      else
        [l, !fence.nil?]
      end
    end
  end

  def heading?(pair, prefix)
    line, in_fence = pair
    !in_fence && line.start_with?(prefix)
  end

  # body から `## <heading>` 節の中身を取り出す (次の `## ` まで)。無ければ nil。
  def section(body, heading)
    pairs = fenced_lines(body)
    start = pairs.index { |(l, f)| !f && l.chomp.strip == "## #{heading}" }
    return nil unless start

    rest = pairs[(start + 1)..-1]
    stop = rest.index { |p| heading?(p, "## ") } || rest.size
    rest[0...stop].map(&:first).join
  end

  # `## 結果` の最新節 (最後の fence 外の `### ` block)。`### ` が無ければ節全体。
  # comment の除去は節や block の分割より先に本文全体へかける (comment の中の `### ` や `## ` で
  # 分割すると、開始記号を失った comment の中身が写ってしまう。R293-01)。
  def latest_result(body)
    sec = section(strip_comments(body), "結果")
    return nil unless sec

    blocks = []
    fenced_lines(sec).each do |pair|
      if heading?(pair, "### ") || blocks.empty?
        blocks << +""
      end
      blocks.last << pair[0]
    end
    blocks.last.to_s.strip
  end

  def next_entry(body)
    sec = section(strip_comments(body), "次の入口")
    sec&.strip
  end

  # template の案内 (HTML comment) は写さない。
  def strip_comments(text)
    text.gsub(/<!--.*?-->/m, "")
  end

  def marker(issue, at)
    "<!-- agent-packet issue=#{issue} published=#{at.iso8601} -->"
  end

  def compose(front, at)
    result = latest_result(front.body).to_s
    entry = next_entry(front.body).to_s
    raise Error, "#{front.path}: 写す内容がありません (## 結果 / ## 次の入口 が空)" if result.empty? && entry.empty?

    parts = [marker(front.issue, at),
             "## 📦 packet ##{front.issue} — state: #{front.state} / worker: #{front.worker}"]
    parts << "**結果 (最新節)**\n\n#{result}" unless result.empty?
    parts << "**次の入口**\n\n#{entry}" unless entry.empty?
    parts.join("\n\n") + "\n"
  end

  # gate は自分と同じ directory から解決する (dispatcher と同じ配備契約)。無ければ投稿しない。
  def gate_path
    File.join(File.dirname(File.realpath(__FILE__)), GATE_NAME)
  end

  # exit 0 だけを「投稿してよい」とする。1 は Rejected、2 (検査できていない) は Error。
  def scan(text)
    gate = gate_path
    raise Error, "#{GATE_NAME} が同じ directory にありません (配備を確認してください)" unless File.executable?(gate)

    _out, err, status = Open3.capture3(gate, "--stdin", stdin_data: text)
    $stderr.print err unless err.empty?
    case status.exitstatus
    when 0 then nil
    when 1 then raise Rejected
    else raise Error, "#{GATE_NAME} が検査できませんでした (exit #{status.exitstatus.inspect})。投稿しません"
    end
  rescue SystemCallError
    raise Error, "#{GATE_NAME} を起動できません。投稿しません"
  end

  def post_comment(issue, repo, text)
    tmp = Tempfile.new(["agent-packet-", ".md"])
    tmp.write(text)
    tmp.flush
    args = ["issue", "comment", issue.to_s]
    args += ["--repo", repo] if repo
    args += ["--body-file", tmp.path]
    out, err, status = Open3.capture3("gh", *args)
    unless status.success?
      first = err.lines.first.to_s.strip
      raise Error, "gh issue comment が失敗しました#{first.empty? ? '' : " (#{first})"}。" \
                   "network / 認証に到達できない環境なら Claude か人が publish してください"
    end
    out.strip
  rescue SystemCallError
    raise Error, "gh を起動できません。Claude か人が publish してください"
  ensure
    tmp&.close!
  end

  # YAML が published と読みうる key 行 (plain / 引用 / 先頭空白)。この script が書き換えられるのは
  # 行頭の plain な `published:` 1 行だけなので、それ以外の表現や重複は publish の前に拒否する
  # (読み取りは受理するのに更新だけ失敗すると、投稿後に published が残らず再試行で二重投稿になる。
  # R293-02)。
  PUBLISHED_KEY_RE = /^\s*["']?published["']?\s*:/.freeze
  PLAIN_PUBLISHED_RE = /^published:.*\n/.freeze

  # frontmatter の published を書き換えた text を返す (file には書かない)。無ければ updated の
  # 直後に足す。body は触らない。
  def with_published(text, at, path)
    m = FRONT_RE.match(text)
    raise Error, "#{path}: frontmatter が見つかりません" unless m

    front = m[1]
    keys = front.lines.grep(PUBLISHED_KEY_RE)
    if keys.size > 1 || (keys.size == 1 && !keys[0].match?(PLAIN_PUBLISHED_RE))
      raise Error, "#{path}: published は行頭の `published: <日時>` 1 行にしてください (引用符付き・重複は更新できません)"
    end

    stamp = "published: #{at.iso8601}\n"
    if front.match?(PLAIN_PUBLISHED_RE)
      front = front.sub(PLAIN_PUBLISHED_RE) { stamp }
    elsif front.match?(/^updated:.*\n/)
      front = front.sub(/^updated:.*\n/) { |u| u + stamp }
    else
      front += stamp
    end
    "---\n#{front}---\n#{m[2]}"
  end

  def same_except_published?(a, b)
    %i[issue title branch pr state worker body].all? { |k| a[k] == b[k] } && a.updated.to_i == b.updated.to_i
  end

  def publish(dir, issue, repo:, dry_run:)
    path = File.join(dir, "#{issue}.md")
    raise Error, "#{path} がありません" unless File.file?(path)

    original = read_text(path)
    front = parse_text(original, path)
    at = Time.now
    text = compose(front, at)
    scan(text)
    if dry_run
      $stdout.print text
      return
    end

    # 投稿前に更新後の packet を作り、読み直して published が at になり、それ以外の field と
    # body が元と同じことまで確かめる。投稿だけ成功して更新が失敗する経路 (再試行で二重投稿) と、
    # 行置換が同じ行の他 field を巻き込む経路 (flow mapping 等。R293-05) を先に潰す。
    updated_text = with_published(original, at, path)
    check = parse_text(updated_text, path)
    unless check.published && check.published.to_i == at.to_i && same_except_published?(front, check)
      raise Error, "#{path}: published を更新すると他の内容が変わります (frontmatter を 1 行 1 field の " \
                   "block mapping にしてください)。投稿しません"
    end

    # 投稿より前に保存できることを確かめる (読めるが書けない packet だと、投稿だけ残って published
    # が更新されず、再試行で二重投稿になる。R293-08)。
    raise Error, "#{path}: 書き込みできません。投稿しません" unless File.writable?(path)

    url = post_comment(issue, repo, text)
    begin
      File.write(path, updated_text)
    rescue SystemCallError => e
      # 投稿は済んでいる。再試行すると二重投稿になるので、URL と入れるべき値を示して止める。
      raise Error, "投稿は完了しました (#{url.empty? ? "issue ##{issue}" : url}) が、packet の保存に失敗しました " \
                   "(#{e.class})。再実行せず、#{path} の frontmatter に `published: #{at.iso8601}` を手で入れてください"
    end
    puts "published: #{url.empty? ? "issue ##{issue}" : url}"
  end

  # ---- CLI -------------------------------------------------------------------

  def usage
    <<~USAGE
      usage: personal-packet dir
             personal-packet list [--json] [--all]
             personal-packet publish <issue> [--repo OWNER/REPO] [--dry-run]

      作業単位 (Issue) ごとの packet .agent-packets/<issue>.md を扱う (docs/agent-packets.md)。
      publish は同じ directory の personal-public-safety-gate --stdin が exit 0 のときだけ投稿する。
    USAGE
  end

  def main(argv)
    if %w[-h --help].include?(argv[0])
      $stdout.print usage
      return 0
    end
    if argv.empty?
      warn usage
      return 2
    end

    cmd, *rest = argv
    case cmd
    when "dir"
      raise Error, "dir は引数を取りません" unless rest.empty?

      puts packet_dir
      0
    when "list"
      json = false
      all = false
      rest.each do |a|
        case a
        when "--json" then json = true
        when "--all" then all = true
        else raise Error, "unknown option: #{a}"
        end
      end
      packets, broken = list(packet_dir, all: all)
      if json
        # 消費者は resume skill (機械)。pretty は 2.6 の json が空配列を "[\n\n]" にするので使わない。
        puts JSON.generate(packets.map(&:to_h))
      else
        $stdout.print render_list(packets)
      end
      broken.each { |msg| warn "personal-packet: warning: #{msg}" }
      broken.empty? ? 0 : 1
    when "publish"
      issue = nil
      repo = nil
      dry_run = false
      i = 0
      while i < rest.size
        a = rest[i]
        case a
        when "--dry-run" then dry_run = true
        when "--repo"
          repo = rest[i + 1]
          raise Error, "--repo は OWNER/REPO 形式で指定してください" unless repo&.match?(REPO_RE) && !repo.start_with?("-")

          i += 1
        else
          raise Error, "unknown option: #{a}" if a.start_with?("-")
          raise Error, "issue は 1 つだけ指定してください" if issue

          issue = a
        end
        i += 1
      end
      raise Error, "issue 番号 (数字) を指定してください" unless issue&.match?(ISSUE_RE)

      publish(packet_dir, issue, repo: repo, dry_run: dry_run)
      0
    else
      raise Error, "unknown command: #{cmd}"
    end
  rescue Rejected
    warn "personal-packet: #{GATE_NAME} が止めました。投稿しません"
    1
  rescue Error => e
    warn "personal-packet: error: #{e.message}"
    warn usage if e.message.start_with?("unknown ")
    2
  rescue StandardError => e
    # 想定外も入力・構成エラーの exit 2 に倒す (fail-closed)。内容を含みうる message は出さず class 名のみ。
    warn "personal-packet: unexpected error (#{e.class})"
    2
  end
end

exit Packet.main(ARGV) if $PROGRAM_NAME == __FILE__
