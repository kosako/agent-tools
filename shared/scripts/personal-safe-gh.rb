#!/usr/bin/env ruby
# frozen_string_literal: true

# safe-gh: GitHub の Issue / PR / コメントを「untrusted data」として安全に読むための
# steering wrapper。生の `gh ... --comments` を agent に直接実行させる代わりにこれへ寄せ、
# 第三者が混入させた指示が agent の命令として解釈されるのを防ぐ (runtime prompt injection)。
#
# 正本: docs/runtime-injection-defense.md / 外部 planning tool の設計メモ (8 決定)。
#
# 強度ラベル (偽らない): これは **steering** であって enforcement boundary ではない。
# `$(gh ...)` 直実行 / `gh api` / `curl` / MCP github tool などで容易に迂回でき、PreToolUse
# hook も subagent に不発・fail-open。hard な防御は床 (credential 隔離 + egress) が担う。
# safe-gh が買うのは「安全な読み方を便利にし、untrusted content を data として扱わせる」こと。
#
# 設計 (決定 3/4/5 を実装):
# - 他人の Issue/PR は metadata のみ (number/state/author/labels)。title すら親に渡さない
#   (title は attacker 制御の free-text = injection 面)。本文も渡さない。
# - 他人コメントは count + 固定理由のみ。著者名・プレビュー・untrusted 由来の文字列を
#   出力に一切混ぜない。
# - bot は全 untrusted。is_bot を association より先に評価する (bot は association が NONE に
#   化けるため)。
# - 自分 (is_self) の Issue/PR 本文・自分のコメントだけ trusted として本文を渡す。
# - self を確定できなければ全 untrusted に倒す (fail-closed)。
#
# I/O (gh 呼び出し) と純粋な trust/render ロジックを分離し、ロジックは fixture で test する
# (gh の実挙動は CI 外 = 実機手動検証。docs/runtime-injection-defense.md「検証境界」)。
#
# 外部依存ゼロ (ruby 標準ライブラリと gh CLI のみ)。

require "json"
require "open3"

module SafeGh
  # 出力に埋める safe reader version。出力契約が変わったら上げる。
  VERSION = "1"

  # self identity の任意 override file。dotfiles が非コミットで置く場合に優先して読む
  # (実値は public repo にハードコードしない)。env で path を上書きできる。
  # 信頼境界 (honest): この file / env を書ける主体は任意 login/id を self と宣言でき、
  # その author の body withhold が外れる。local file/env の改変は本 wrapper の脅威モデル外
  # (steering であり enforcement boundary ではない。床は実行環境側の責務)。
  SELF_TRUST_FILE_ENV = "SAFE_GH_TRUST_FILE"
  DEFAULT_SELF_TRUST_FILE = File.join(Dir.home, ".config", "dotfiles", "github-trust.local")

  # 除外理由は固定文字列にする。untrusted 由来の文字列を出力へ混ぜない (決定 5)。
  EXCLUDED_BODY_REASON =
    "author is not the trusted self; title and body withheld to avoid runtime injection"
  EXCLUDED_COMMENTS_REASON =
    "non-self comments withheld (count only) to avoid runtime injection"

  class Error < StandardError; end

  module_function

  # ---- 純粋ロジック: trust 判定 ----------------------------------------------

  # user (GitHub REST の user object: {"login","id","type"}) の trust を判定する。
  # me = self identity {"login","id"} か、確定できないとき nil。
  # bot を最初に評価する (決定 3)。self を確定できなければ self になり得ない (fail-closed)。
  def classify(user, me)
    user ||= {}
    return "bot" if bot?(user)
    return "self" if me && self_authored?(user, me)

    "other"
  end

  def bot?(user)
    user["login"].to_s.end_with?("[bot]") || user["type"].to_s == "Bot"
  end

  # numeric id を最優先で照合する (login rename に強い・最堅信号)。両者に id があれば
  # id 一致のみを self とする。id が欠ける場合に限り login で照合する。
  def self_authored?(user, me)
    if me["id"] && user["id"]
      user["id"] == me["id"]
    else
      !user["login"].to_s.empty? && user["login"] == me["login"]
    end
  end

  # ---- 純粋ロジック: envelope rendering --------------------------------------

  # Issue/PR 本体の envelope。self なら title/body を渡し、それ以外 (other/bot) は
  # metadata のみで title/body を渡さない (決定 4)。
  # kind は "issue" / "pr"。data は GitHub REST の issue/pr object。
  def issue_envelope(kind, repo, data, me)
    user = data["user"]
    trust = classify(user, me)
    env = {
      "safe_reader_version" => VERSION,
      "source" => kind,
      "repo" => repo,
      "number" => data["number"],
      "state" => data["state"],
      "author" => user && user["login"],
      "author_trust" => trust,
      # author_association は補助信号 (単体の許可ソースにしない)。GitHub の enum なので
      # free-text injection 面ではない。
      "author_association" => data["author_association"],
      "labels" => label_names(data["labels"]),
    }
    if trust == "self"
      env["title"] = data["title"]
      env["body"] = data["body"]
      env["body_trust"] = "self"
    else
      env["body_trust"] = "untrusted"
      env["excluded_body"] = true
      env["excluded_body_reason"] = EXCLUDED_BODY_REASON
    end
    env
  end

  # コメントの envelope。self コメントだけ body を渡し、それ以外は count + 固定理由のみ。
  # 除外コメントの著者名・本文・プレビューは出力に一切含めない (決定 5)。
  def comments_envelope(kind, repo, number, comments, me)
    included = []
    excluded = 0
    (comments || []).each do |c|
      if classify(c["user"], me) == "self"
        included << {
          "author" => c["user"]["login"],
          "author_trust" => "self",
          "body" => c["body"],
        }
      else
        excluded += 1
      end
    end
    env = {
      "safe_reader_version" => VERSION,
      "source" => "#{kind}_comments",
      "repo" => repo,
      "number" => number,
      "comments" => included,
      "excluded_comments_count" => excluded,
    }
    env["excluded_comments_reason"] = EXCLUDED_COMMENTS_REASON if excluded.positive?
    env
  end

  # label 名は envelope に残す唯一の free-text metadata (付与には triage/write 権限が要る
  # ため attacker 制御性は低いが、ゼロではない)。制御文字を除去し長さを制限してから渡す。
  def label_names(labels)
    (labels || []).map { |l| l.is_a?(Hash) ? l["name"] : l }
                  .select { |name| name.is_a?(String) }
                  .map { |name| name.gsub(/[[:cntrl:]]/, "")[0, 100] }
  end

  # ---- I/O: gh 呼び出し ------------------------------------------------------

  # self identity を取得する。任意 override file を優先し、無ければ `gh api user`。
  # どちらも取れなければ nil (= 全 untrusted = fail-closed)。
  def self_identity(env: ENV)
    from_file = self_identity_from_file(env)
    return from_file if from_file

    out, ok = gh_capture(["api", "user", "--jq", "{login: .login, id: .id}"])
    return nil unless ok

    parsed = parse_json(out)
    normalize_identity(parsed)
  end

  def self_identity_from_file(env)
    path = env[SELF_TRUST_FILE_ENV]
    path = DEFAULT_SELF_TRUST_FILE if path.nil? || path.empty?
    return nil unless File.file?(path)

    normalize_identity(parse_json(File.read(path)))
  end

  def normalize_identity(data)
    return nil unless data.is_a?(Hash)
    return nil if data["login"].nil? && data["id"].nil?

    # id は GitHub API では integer。trust file に文字列 "12345" で書かれても integer 比較で
    # 一致するよう正規化する (不一致だと自分の投稿まで恒久 untrusted に化ける)。
    { "login" => data["login"], "id" => normalize_id(data["id"]) }
  end

  # numeric id を Integer に正規化する。integer / 数字文字列は Integer 化、nil は nil、
  # 非数値はそのまま返す (integer と一致せず fail-closed のまま)。
  def normalize_id(id)
    return nil if id.nil?
    return id if id.is_a?(Integer)

    Integer(id.to_s, 10)
  rescue ArgumentError, TypeError
    id
  end

  def parse_json(text)
    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  def gh_capture(args)
    out, _err, status = Open3.capture3("gh", *args)
    [out, status.success?]
  rescue SystemCallError
    ["", false]
  end

  # gh REST を叩いて JSON を返す。失敗 (network/auth/not found) は Error。安全側に倒すため
  # 部分的な envelope は作らず止める。
  #
  # paginate=true は配列を返す list endpoint (comments 等) の全ページを取得する
  # (30 件で切れると excluded count が過少になり自分の comment 本文も落ちる)。plain
  # `--paginate` は array endpoint でページ境界に `][` を挟み単一 JSON として不正になり得る
  # ため、`--slurp` で各ページを 1 要素とする配列にまとめ、flatten(1) で平坦化する
  # (single page でも `[[...]]` を平坦化するので結果は常に flat な配列)。
  def gh_api(path, paginate: false)
    args = ["api"]
    args += ["--paginate", "--slurp"] if paginate
    args << path
    out, ok = gh_capture(args)
    raise Error, "gh api #{path} failed (gh が未認証 / network / 対象が存在しない可能性)" unless ok

    data = parse_json(out) || raise(Error, "gh api #{path} returned invalid JSON")
    paginate ? data.flatten(1) : data
  end

  # owner/repo を解決する。-R で明示されていればそれを、無ければ現在の repo を gh から引く。
  def resolve_repo(explicit)
    return explicit if explicit && !explicit.empty?

    out, ok = gh_capture(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])
    raise Error, "repository を解決できない (-R OWNER/REPO で指定してください)" unless ok

    name = out.strip
    raise Error, "repository を解決できない (-R OWNER/REPO で指定してください)" if name.empty?

    name
  end

  # PR の会話コメントは issue comments endpoint に乗る (PR は issue でもある)。
  def fetch(kind, repo, number)
    case kind
    when "issue" then gh_api("repos/#{repo}/issues/#{number}")
    when "pr" then gh_api("repos/#{repo}/pulls/#{number}")
    end
  end

  def fetch_comments(repo, number)
    gh_api("repos/#{repo}/issues/#{number}/comments", paginate: true)
  end

  # ---- entrypoint ------------------------------------------------------------

  def run(noun, verb, number, repo, me)
    case [noun, verb]
    when %w[issue view]
      issue_envelope("issue", repo, fetch("issue", repo, number), me)
    when %w[pr view]
      issue_envelope("pr", repo, fetch("pr", repo, number), me)
    when %w[issue comments]
      comments_envelope("issue", repo, number, fetch_comments(repo, number), me)
    when %w[pr comments]
      comments_envelope("pr", repo, number, fetch_comments(repo, number), me)
    else
      raise Error, "unknown command: #{noun} #{verb}"
    end
  end

  def main(argv)
    args = argv.dup
    if args.include?("-h") || args.include?("--help")
      print_usage
      return 0
    end

    repo, repo_ok = extract_repo_flag(args)
    noun, verb, number = args
    unless repo_ok && valid_invocation?(noun, verb, number)
      print_usage
      return 2
    end

    me = self_identity
    warn "warn: self identity を確定できないため全 author を untrusted として扱います" unless me

    repo = resolve_repo(repo)
    puts JSON.pretty_generate(run(noun, verb, number, repo, me))
    0
  rescue Error => e
    warn "fail: #{e.message}"
    1
  end

  # `-R OWNER/REPO` / `--repo OWNER/REPO` を args から取り除き、[repo, ok] を返す。
  # -R 無し: [nil, true] (repo は後で resolve)。-R に値が無い (末尾フラグ): [nil, false]
  # で malformed を示し、呼び出し側が usage exit に倒す (現在 repo へ黙って fallback しない)。
  def extract_repo_flag(args)
    idx = args.index { |a| a == "-R" || a == "--repo" }
    return [nil, true] unless idx

    args.delete_at(idx)         # フラグ
    value = args.delete_at(idx) # 値 (末尾フラグなら nil)
    [value, !value.nil?]
  end

  def valid_invocation?(noun, verb, number)
    %w[issue pr].include?(noun) &&
      %w[view comments].include?(verb) &&
      !number.nil? && number.match?(/\A\d+\z/)
  end

  def print_usage
    warn <<~USAGE
      usage: personal-safe-gh [-R OWNER/REPO] <issue|pr> <view|comments> <number>

      GitHub の Issue/PR/コメントを untrusted data として安全に読む steering wrapper。
      他人の Issue/PR は metadata のみ、他人コメントは count のみを出力する。
    USAGE
  end
end

exit SafeGh.main(ARGV) if $PROGRAM_NAME == __FILE__
