#!/usr/bin/env ruby
# frozen_string_literal: true

# merged-branch-cleanup: merge 済みの自分の branch を、消してよい条件を機械で確かめてから消す (#640)。squash merge の branch は
# `git branch -d` では消せず、`-D` は host の ask 規則で毎回確認になる。運用ルール (#563) が確認なしで許す条件をここで確かめ、
# この script だけを host の allow に置く。ask 規則そのものは、未 merge の作業を人に確かめるために残す。
#
# 正本: docs/merged-branch-cleanup.md。
#
# 消すのは、次をすべて満たす branch だけ。
# 1. repo の owner の type が User で、login が gh で認証している user と一致する (運用ルールの「個人 project」の判定)。
# 2. default branch でなく、どの worktree でも checkout されていない。
# 3. merged の PR のうちに、head が同じ repo の同じ名前で、head の OID が local の tip と一致し、base が default branch の
#    ものがある (stacked の親に入っただけの branch は、default branch に届いていないので消さない)。
# 4. --remote のとき: origin が同じ repo を指し、remote の branch の OID が同じか、branch が無い。
#
# 削除は期待する OID を指定した比較つきで行う (local は update-ref、remote は --force-with-lease)。確かめた後に tip が動くと
# 失敗し、branch は残る。local を消すのは remote の削除が済んだ後。
#
# 強度ラベル (偽らない): 手順の守りであって境界ではない。script は agent と同じ OS user が書き換えられ、gh の応答をそのまま
# 信じる。PR の head が merge されたことまでを確かめ、merge commit の中身は確かめない。
#
# untrusted-input 規律: 読むのは PR の OID・branch 名・状態の field だけで、title や本文は取らない。出力に載せるのは、規則の形に
# 合う branch 名、PR の番号、閉じた表の label だけ。gh と git の stderr は出さない。
#
# exit: 0 = すべて消した (または消す branch が無い) / 1 = 消さなかった branch がある (理由は stdout の label) /
# 2 = usage・gh か git の失敗・判定できない。

require "json"
require "open3"

# C locale でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module MergedBranchCleanup
  NAME = "personal-merged-branch-cleanup"
  EXIT_OK = 0
  EXIT_NOT_OK = 1
  EXIT_ERROR = 2

  USAGE = "usage: #{NAME} [--repo owner/repo] [--remote] [--dry-run] <branch>..."
  REPO_RE = %r{\A[\w.][\w.-]*/[\w.][\w.-]*\z}.freeze
  # 出力に載せ、ref の組み立てに使う branch 名の形。`@{-1}` のような省略形と、先頭の `-` を入れない。
  BRANCH_RE = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}.freeze
  OID_RE = /\A[0-9a-f]{40}\z/.freeze
  ORIGIN_RE = %r{\A(?:https://(?:[^/@]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?/?\z}.freeze
  PR_FIELDS = "number,headRefName,headRefOid,baseRefName,isCrossRepository,mergedAt"
  PR_LIMIT = "100"

  # 判定できないとき (gh や git の失敗、応答の形が外れる)。
  class Undecidable < StandardError; end

  module_function

  def main(argv, env: ENV, out: $stdout, err: $stderr)
    options = parse_args(argv, env)
    target = resolve_target(options[:repo])
    return report_all(options[:branches], target[:refusal], out) if target[:refusal]

    origin_ok = !options[:remote] || origin_matches?(target[:full_name])
    worktree_refs = checked_out_refs
    results = options[:branches].uniq.map do |branch|
      cleanup(branch, target, options, origin_ok, worktree_refs, out)
    end
    results.all? ? EXIT_OK : EXIT_NOT_OK
  rescue ArgumentError => e
    err.puts "#{NAME}: #{e.message}"
    err.puts USAGE
    EXIT_ERROR
  rescue Undecidable => e
    err.puts "#{NAME}: #{e.message}"
    EXIT_ERROR
  end

  def parse_args(argv, env)
    options = { repo: nil, remote: false, dry_run: false, branches: [] }
    args = argv.dup
    until args.empty?
      arg = args.shift
      case arg
      when "--repo"
        options[:repo] = args.shift
        raise ArgumentError, "--repo needs owner/repo" unless options[:repo].to_s.match?(REPO_RE)
      when "--remote" then options[:remote] = true
      when "--dry-run" then options[:dry_run] = true
      else
        raise ArgumentError, "bad branch name or option" unless arg.match?(BRANCH_RE) && valid_ref?(arg)

        options[:branches] << arg
      end
    end
    raise ArgumentError, "no branch given" if options[:branches].empty?
    # GH_REPO があると、gh の読み先と git の作業先が別の repo になりうる (#528 と同じ扱い)。
    raise ArgumentError, "GH_REPO is set; unset it or pass --repo" if options[:repo].nil? && !env["GH_REPO"].to_s.empty?

    options
  end

  def valid_ref?(branch)
    _out, _err, status = Open3.capture3("git", "check-ref-format", "refs/heads/#{branch}")
    status.success?
  end

  # 対象の repo の名前と default branch。個人の repo でなければ :refusal を返す (何も消さない)。
  def resolve_target(repo)
    path = repo ? "repos/#{repo}" : "repos/{owner}/{repo}"
    data = gh_json("api", path)
    user = gh_json("api", "user")
    owner = data.is_a?(Hash) ? data["owner"] : nil
    full_name = data.is_a?(Hash) ? data["full_name"] : nil
    default = data.is_a?(Hash) ? data["default_branch"] : nil
    login = user.is_a?(Hash) ? user["login"] : nil
    unless owner.is_a?(Hash) && owner["type"].is_a?(String) && owner["login"].is_a?(String) &&
           full_name.to_s.match?(REPO_RE) && default.to_s.match?(BRANCH_RE) && login.is_a?(String) && !login.empty?
      raise Undecidable, "unexpected response shape from gh api"
    end

    return { refusal: "not-personal-repo" } unless owner["type"] == "User" && owner["login"] == login

    { full_name: full_name, default: default }
  end

  # 個人の repo でないときは、どの branch も消さない。
  def report_all(branches, label, out)
    branches.uniq.each { |branch| out.puts "refused: #{branch} (#{label})" }
    EXIT_NOT_OK
  end

  # 1 つの branch を処理する。消した・消す branch が無いときは true、消さなかったときは false。
  def cleanup(branch, target, options, origin_ok, worktree_refs, out)
    ref = "refs/heads/#{branch}"
    refusal = nil
    refusal ||= "default-branch" if branch == target[:default]
    refusal ||= "checked-out" if worktree_refs.include?(ref)
    refusal ||= "origin-is-another-repo" unless origin_ok
    return refuse(branch, refusal, out) if refusal

    local = rev_parse(ref)
    remote = options[:remote] ? remote_oid(ref) : nil
    if local.nil? && remote.nil?
      out.puts "absent: #{branch}"
      return true
    end
    return refuse(branch, "remote-differs", out) if local && remote && local != remote

    oid = local || remote
    verdict = merged_pr(branch, oid, target)
    return refuse(branch, verdict[:refusal], out) if verdict[:refusal]

    pr = verdict[:number]
    if options[:dry_run]
      out.puts "would-delete: #{branch} (merged in ##{pr})"
      return true
    end
    return refuse(branch, "remote-delete-failed", out) if remote && !delete_remote(ref, oid)
    return refuse(branch, "local-delete-failed", out) if local && !delete_local(branch, ref, oid)

    out.puts "deleted: #{branch} (merged in ##{pr}#{remote ? ', remote too' : ''})"
    true
  end

  def refuse(branch, label, out)
    out.puts "refused: #{branch} (#{label})"
    false
  end

  # OID が一致する merged の PR を探す。無ければ、いちばん条件に近いものの理由を返す。
  def merged_pr(branch, oid, target)
    rows = gh_json("pr", "list", "--repo", target[:full_name], "--head", branch, "--state", "merged",
                   "--json", PR_FIELDS, "--limit", PR_LIMIT)
    raise Undecidable, "unexpected response shape from gh pr list" unless rows.is_a?(Array) && rows.all? { |r| valid_pr?(r) }

    own = rows.select { |r| r["headRefName"] == branch && r["isCrossRepository"] == false && r["mergedAt"].is_a?(String) }
    return { refusal: "no-merged-pr" } if own.empty?

    same = own.select { |r| r["headRefOid"] == oid }
    return { refusal: "tip-is-not-merged-head" } if same.empty?

    hit = same.find { |r| r["baseRefName"] == target[:default] }
    return { refusal: "base-is-not-default-branch" } if hit.nil?

    { number: hit["number"] }
  end

  def valid_pr?(row)
    row.is_a?(Hash) && row["number"].is_a?(Integer) && row["headRefName"].is_a?(String) &&
      row["headRefOid"].to_s.match?(OID_RE) && row["baseRefName"].is_a?(String)
  end

  # 消す前に、origin が対象の repo かを確かめる (gh の応答と別の repo の branch を消さない)。
  def origin_matches?(full_name)
    url = git_out("remote", "get-url", "origin")
    return false if url.nil?

    match = ORIGIN_RE.match(url.strip)
    !match.nil? && match[1].casecmp?(full_name)
  end

  # どの worktree でも checkout されている branch の ref の一覧。
  def checked_out_refs
    text = git_out("worktree", "list", "--porcelain")
    raise Undecidable, "could not list worktrees" if text.nil?

    text.lines.map(&:strip).select { |l| l.start_with?("branch ") }.map { |l| l.delete_prefix("branch ") }
  end

  def rev_parse(ref)
    text = git_out("rev-parse", "--verify", "--quiet", ref)
    return nil if text.nil?

    oid = text.strip
    raise Undecidable, "unexpected oid from git rev-parse" unless oid.match?(OID_RE)

    oid
  end

  # remote の branch の OID。無ければ nil。読めなければ判定できない。
  def remote_oid(ref)
    text = git_out("ls-remote", "--refs", "origin", ref)
    raise Undecidable, "could not read origin" if text.nil?

    line = text.lines.map(&:strip).find { |l| l.end_with?("\t#{ref}") }
    return nil if line.nil?

    oid = line.split("\t").first
    raise Undecidable, "unexpected oid from git ls-remote" unless oid.match?(OID_RE)

    oid
  end

  def delete_remote(ref, oid)
    git_ok("push", "--quiet", "origin", "--force-with-lease=#{ref}:#{oid}", ":#{ref}")
  end

  # 比較つきで ref を消してから、branch の設定を外す (`git branch -D` と同じ後始末)。設定が無いときの失敗は気にしない。
  def delete_local(branch, ref, oid)
    return false unless git_ok("update-ref", "-d", ref, oid)

    git_ok("config", "--remove-section", "branch.#{branch}")
    true
  end

  def git_out(*args)
    out, _err, status = Open3.capture3("git", *args)
    status.success? ? out.scrub : nil
  rescue SystemCallError
    raise Undecidable, "could not run git"
  end

  def git_ok(*args)
    _out, _err, status = Open3.capture3("git", *args)
    status.success?
  rescue SystemCallError
    raise Undecidable, "could not run git"
  end

  def gh_json(*args)
    out, _err, status = Open3.capture3("gh", *args)
    raise Undecidable, "gh failed (#{args.first(2).join(' ').gsub(/[^a-z ]/, '')})" unless status.success?

    JSON.parse(out.scrub)
  rescue JSON::ParserError
    raise Undecidable, "gh returned invalid JSON"
  rescue SystemCallError
    raise Undecidable, "could not run gh"
  end
end

exit MergedBranchCleanup.main(ARGV) if $PROGRAM_NAME == __FILE__
