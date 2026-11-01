#!/usr/bin/env ruby
# frozen_string_literal: true

# dependabot-pin-check: Dependabot の PR のうち GitHub Actions の pin (`uses: owner/repo@<sha> # <tag>`) の bump だけを、
# 決まった処理で確かめる (#553 の C)。AI を使わず、何も書かない。確かめるのは次の 4 つ。
#
# 1. 変更の範囲: PR の全 file が `.github/workflows/` 直下の `*.yml` / `*.yaml` の modified で、変わった行が `uses` の
#    pin の行だけ (旧 file の変わった `uses` の行を新 file の行に置き換えると、新 file と byte 単位で一致する)。
#    job と step の構造は前後で同じで、各 `uses` の owner/repo/path も同じ。sha か tag の変わる行が 1 つ以上ある。
# 2. pin の整合: 新しい sha が、その action の repository の tag (`# <tag>` のコメント) の commit と一致する (annotated tag
#    は type が commit になるまで解く。深さ 3 まで)。版 (数値の tuple) は前に進む。
# 3. CI: base の `.github/repo-baseline.json` の `required_checks` を必要な集合とし (file か key が無ければ not ok。file は
#    personal-repo-baseline と同じ規則で読み、空の一覧を含む不正は判定できない = exit 2。#573)、head の check-runs で各 check が
#    completed かつ success。
# 4. snapshot: 最初と最後に `pulls/<n>` を読み、head が動いていないこと。
#
# この検査は参照の整合性と変更の範囲の確認で、依存先 (action の中身) の安全の証明ではない。tag は動かせるので、結果は
# 観測時点のもの。routing (PR の author が bot であること) は personal-review-routing-preflight が決め、この script は
# 再判定しない。C (AI の review を省く) は、preflight が bot を返した同じ head でこの script が ok のときだけ成立する
# (規範の正本は personal-review-request の「bot の PR」)。
#
# untrusted-input 規律: PR の file の path・patch・コメントは bot (または第三者) が書く untrusted data。出力に載せるのは
# 規則の形に合う path と行番号、閉じた表の label、規則の形に合う tag と check の名前だけ。patch や file の本文は出さない。
#
# 依存: gh (認証済み)。読み取りは REST の GET だけ (pulls/<n>、pulls/<n>/files、contents、git/ref/tags、git/tags、
# commits/<sha>/check-runs)。repo 省略時は gh の placeholder (`{owner}/{repo}`) に解決を委ねる (preflight と同じ。gh は
# 現在の directory の repository に解決し、env の GH_REPO などが効く)。API の呼び出しは 1 回の実行で 80 回まで。
# exit: 0 = ok / 1 = not ok (理由は stdout の label) / 2 = usage・gh の失敗・判定できない (head が動いた、応答の形が外れる)。

require "date"
require "json"
require "open3"
require "psych"
require "yaml"
require "uri"

# C locale でも、読む text を UTF-8 として扱う (#432)。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module DependabotPinCheck
  NAME = "personal-dependabot-pin-check"
  EXIT_OK = 0
  EXIT_NOT_OK = 1
  EXIT_ERROR = 2

  REPO_RE = %r{\A[\w.-]+/[\w.-]+\z}.freeze
  SHA_RE = /\A[0-9a-f]{40}\z/.freeze
  WORKFLOW_DIR = ".github/workflows"
  # 出力に載せてよい file の path (workflow の直下の file。名前は規則の文字だけ)。外れる path は確かめず、名前も出さない。
  SAFE_PATH_RE = %r{\A\.github/workflows/[A-Za-z0-9][A-Za-z0-9._-]*\.(?:yml|yaml)\z}.freeze
  BASELINE_PATH = ".github/repo-baseline.json"
  # YAML (libyaml) が改行とみなす文字のうち LF 以外 (CR・NEL・LS・PS)。含む file は読まない: 行の添字 (LF で分ける) と AST の
  # 行番号がずれ、別の行を uses の行として検査しうる (#553 round 2)。CRLF の workflow は通常の bot の route に落ちる。
  LINE_BREAK_RE = /[\r\u0085  ]/.freeze
  # GitHub の PR の file の status の閉じた表 (modified 以外。出力に載せるため)。表に無い値は unknown と出す。
  FILE_STATUSES = %w[added removed renamed copied changed unchanged].freeze
  # GitHub の job の名前の規則と、出力に載せてよい check の名前 (ci-check と同じ)。
  JOB_ID_RE = /\A[A-Za-z_][A-Za-z0-9_-]*\z/.freeze
  SAFE_CHECK_NAME_RE = %r{\A[A-Za-z0-9_][A-Za-z0-9 _.()/,:+-]{0,99}\z}.freeze
  # pin の行: `uses: owner/repo[/path]@<40 桁 sha> # <tag>`。tag は v の有無と数字と点だけ (prerelease などは対象外)。
  USES_LINE_RE = %r{\A\s*(?:-\s+)?uses:\s*(?<ref>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]*)?)@(?<sha>[0-9a-f]{40})\s+#\s*(?<tag>v?\d+(?:\.\d+){0,3})\s*\z}.freeze
  MAX_FILE_BYTES = 1024 * 1024
  MAX_FILES = 50
  MAX_DEPTH = 64
  MAX_TAG_DEPTH = 3
  MAX_API_CALLS = 80
  PER_PAGE = 100

  class UsageError < StandardError; end
  # gh の失敗・応答の形の外れ・head の移動 (判定できない。exit 2)。
  class RunError < StandardError; end
  # 1 つの file を確かめられない (YAML として読めない、など。not ok の label になる)。
  class FileError < StandardError; end

  # base の repo-baseline.json は personal-repo-baseline と同じ規則で読む (#573。script は 1 file ずつ配備されるので
  # code は共有せず、同じ fixture を両方に当てる test で一致を固定する)。外れたら RunError (判定できない)。
  BASELINE_MAX = 64 * 1024
  BASELINE_KEYS = %w[skip required_checks].freeze
  BASELINE_SKIPPABLE = %w[dependabot_yml].freeze
  class BaselineDuplicateKeyError < StandardError; end
  # 同じ key が重なったら、後の値で前の値を消さずに不正にする (JSON.parse は既定で後の値を残す)。
  class BaselineStrictHash < Hash
    def []=(key, value)
      raise BaselineDuplicateKeyError if key?(key)

      super
    end
  end

  # YAML の collection の入れ子の深さを parse の event で数える (ci-check と同じ)。
  class DepthGuard < Psych::Handler
    def initialize
      super
      @depth = 0
    end

    def start_sequence(*)
      enter
    end

    def start_mapping(*)
      enter
    end

    def end_sequence
      @depth -= 1
    end

    def end_mapping
      @depth -= 1
    end

    private

    def enter
      @depth += 1
      raise FileError, "YAML の入れ子が #{MAX_DEPTH} 段を超える" if @depth > MAX_DEPTH
    end
  end

  # GitHub の API を gh で読む (GET だけ)。回数に上限を置く。stderr は gh の固定の文言だけを見て 404 を分ける。
  class GitHubApi
    attr_reader :calls

    def initialize
      @calls = 0
    end

    # 1 object を返す。404 なら nil (allow_404 のとき)。成功の応答の本文が JSON の null なら、404 の nil と取り違えない
    # ように応答の形の外れにする (読む endpoint はどれも null を返さない。#608 の review)。
    def get(path, allow_404: false)
      out, err, status = run(["gh", "api", path])
      unless status.success?
        return nil if allow_404 && err.include?("HTTP 404")

        raise RunError, "gh api が失敗しました (PR 番号 / 認証 / --repo を確認)"
      end
      obj = parse(out)
      raise RunError, "gh の応答の形が外れます (成功の応答の本文が null)" if obj.nil?

      obj
    end

    private

    def run(argv)
      raise RunError, "API の呼び出しが上限の #{MAX_API_CALLS} 回を超える" if @calls >= MAX_API_CALLS

      @calls += 1
      Open3.capture3(*argv, in: File::NULL)
    rescue SystemCallError
      raise RunError, "gh を起動できません"
    end

    def parse(out)
      JSON.parse(out)
    rescue JSON::ParserError
      raise RunError, "gh の応答を JSON として解釈できません"
    end
  end

  module_function

  def usage
    "usage: #{NAME} <PR番号> [--repo owner/repo]"
  end

  def run(argv)
    args = argv.dup
    repo = nil
    if (i = args.index("--repo"))
      repo = args[i + 1]
      raise UsageError, "--repo は owner/repo 形式で指定してください" if repo.nil? || !repo.match?(REPO_RE) || repo.start_with?("-")

      args.slice!(i, 2)
    end
    pr_number = args[0]
    raise UsageError, "PR 番号は数字だけで指定してください" unless args.size == 1 && pr_number.to_s.match?(/\A\d+\z/)

    api = GitHubApi.new
    result = check(api, repo, pr_number)
    result[:lines].each { |line| $stdout.puts line }
    if result[:ok]
      $stdout.puts "pin-check: ok (#{result[:pins]} pin(s), #{result[:checks]} check(s))"
      EXIT_OK
    else
      $stdout.puts "pin-check: not ok"
      EXIT_NOT_OK
    end
  rescue UsageError => e
    $stderr.puts "#{NAME}: #{e.message}"
    $stderr.puts usage
    EXIT_ERROR
  rescue RunError => e
    $stderr.puts "#{NAME}: error: #{e.message}"
    EXIT_ERROR
  rescue StandardError, SystemStackError => e
    $stderr.puts "#{NAME}: unexpected error (#{e.class})"
    EXIT_ERROR
  end

  # 検査の本体。{ok:, lines:, pins:, checks:} を返す。判定できないときは RunError。
  def check(api, repo, pr_number)
    base_path = "repos/#{repo || '{owner}/{repo}'}"
    pull = read_pull(api, base_path, pr_number)
    lines = ["target: base #{pull[:base_sha]} / head #{pull[:head_sha]}"]
    ok = true
    pins = 0

    files = read_files(api, base_path, pr_number, pull[:changed_files])
    bumps = []
    files.each do |file|
      verdicts, file_bumps = check_file(api, base_path, pull, file)
      verdicts.each do |label|
        ok = false unless label[:ok]
        lines << label[:text]
      end
      bumps.concat(file_bumps)
    end
    if bumps.empty?
      lines << "pins: no pin bump"
      ok = false
    end
    bumps.each do |bump|
      label = check_bump(api, bump)
      ok = false unless label[:ok]
      lines << label[:text]
      pins += 1 if label[:ok]
    end

    checks, ci_lines, ci_ok = check_ci(api, base_path, pull)
    lines.concat(ci_lines)
    ok = false unless ci_ok

    # snapshot: 読んでいる間に head が動いていないこと。動いていれば判定できない (exit 2)。
    after = read_pull(api, base_path, pr_number)
    raise RunError, "PR の head が検査の途中で動きました (やり直す)" unless after[:head_sha] == pull[:head_sha] && after[:base_sha] == pull[:base_sha]

    { ok: ok, lines: lines, pins: pins, checks: checks }
  end

  # pulls/<n> から head / base の sha・repository・changed_files を読む。形が外れれば RunError。
  def read_pull(api, base_path, pr_number)
    pull = api.get("#{base_path}/pulls/#{pr_number}")
    raise RunError, "gh の応答が PR の object ではありません" unless pull.is_a?(Hash)

    head = pull["head"]
    base = pull["base"]
    raise RunError, "PR の head / base を読めません" unless head.is_a?(Hash) && base.is_a?(Hash)

    head_sha = head["sha"]
    base_sha = base["sha"]
    raise RunError, "PR の head / base の sha の形が外れます" unless head_sha.is_a?(String) && head_sha.match?(SHA_RE) &&
                                                                     base_sha.is_a?(String) && base_sha.match?(SHA_RE)

    base_repo = base["repo"]
    raise RunError, "PR の base の repository を読めません" unless base_repo.is_a?(Hash) && base_repo["full_name"].is_a?(String) &&
                                                                 base_repo["full_name"].match?(REPO_RE)

    changed = pull["changed_files"]
    raise RunError, "PR の changed_files を読めません" unless changed.is_a?(Integer) && changed >= 0

    { head_sha: head_sha, base_sha: base_sha, base_repo: base_repo["full_name"], changed_files: changed }
  end

  # pulls/<n>/files を全件読み、数を照合する。
  def read_files(api, base_path, pr_number, changed_files)
    raise RunError, "PR の file が #{MAX_FILES} を超えます (この検査の対象外)" if changed_files > MAX_FILES

    # file は MAX_FILES (< PER_PAGE) までなので 1 page で全件が読める。数は changed_files と照合する。
    files = api.get("#{base_path}/pulls/#{pr_number}/files?per_page=#{PER_PAGE}")
    raise RunError, "PR の file の応答が配列ではありません" unless files.is_a?(Array)
    raise RunError, "PR の file の数が changed_files と一致しません" unless files.size == changed_files
    raise RunError, "PR に file がありません" if files.empty?

    files.each do |f|
      raise RunError, "PR の file の応答の形が外れます" unless f.is_a?(Hash) && f["filename"].is_a?(String) && f["status"].is_a?(String)
    end
    names = files.map { |f| f["filename"] }
    raise RunError, "PR の file の一覧に重なりがあります" unless names.uniq.size == names.size

    files
  end

  # 1 つの file を確かめ、[label の配列, bump の配列] を返す。file の中身は base と head の tree から読む。
  def check_file(api, base_path, pull, file)
    path = file["filename"]
    unless path.match?(SAFE_PATH_RE)
      return [[label(false, "#{WORKFLOW_DIR}/ の外か名前が規則の外の file 1 つ: not-workflow-file (名前は出さない)")], []]
    end
    unless file["status"] == "modified"
      status = FILE_STATUSES.include?(file["status"]) ? file["status"] : "unknown"
      return [[label(false, "#{path}: not-modified (#{status})")], []]
    end

    begin
      old_text = read_content(api, base_path, path, pull[:base_sha])
      new_text = read_content(api, base_path, path, pull[:head_sha])
      old_uses = uses_lines(old_text, path)
      new_uses = uses_lines(new_text, path)
      raise FileError, "structure-changed" unless old_uses.keys == new_uses.keys

      old_lines = old_text.split("\n", -1)
      new_lines = new_text.split("\n", -1)
      bumps = []
      rebuilt = old_lines.dup
      old_uses.each do |key, old_node|
        new_node = new_uses[key]
        old_line = old_lines[old_node[:line] - 1]
        new_line = new_lines[new_node[:line] - 1]
        next if old_line == new_line && old_node[:line] == new_node[:line]

        old_m = USES_LINE_RE.match(old_line.to_s)
        new_m = USES_LINE_RE.match(new_line.to_s)
        raise FileError, "non-pin-change" if old_m.nil? || new_m.nil?
        raise FileError, "non-pin-change" unless old_node[:value] == "#{old_m[:ref]}@#{old_m[:sha]}" &&
                                                 new_node[:value] == "#{new_m[:ref]}@#{new_m[:sha]}"
        raise FileError, "ref-changed" unless old_m[:ref] == new_m[:ref]
        raise FileError, "non-pin-change" unless old_node[:line] == new_node[:line]

        rebuilt[old_node[:line] - 1] = new_line
        bumps << { path: path, line: new_node[:line], ref: new_m[:ref], old_sha: old_m[:sha], new_sha: new_m[:sha],
                   old_tag: old_m[:tag], new_tag: new_m[:tag] }
      end
      raise FileError, "non-pin-change" unless rebuilt.join("\n") == new_text
      raise FileError, "no-pin-bump" if bumps.empty?

      [[label(true, "#{path}: pin-only-change (#{bumps.size} line(s))")], bumps]
    rescue FileError => e
      [[label(false, "#{path}: #{e.message}")], []]
    end
  end

  # contents API で file の本文を読む (1 MiB まで、UTF-8)。path は SAFE_PATH_RE か BASELINE_PATH に限る。
  def read_content(api, base_path, path, sha)
    obj = api.get("#{base_path}/contents/#{path}?ref=#{sha}", allow_404: true)
    raise FileError, "file-missing" if obj.nil?
    raise FileError, "not-a-file" unless obj.is_a?(Hash) && obj["type"] == "file"
    raise FileError, "file-too-large" unless obj["size"].is_a?(Integer) && obj["size"] <= MAX_FILE_BYTES
    raise FileError, "content-unreadable" unless obj["encoding"] == "base64" && obj["content"].is_a?(String)

    text = obj["content"].unpack1("m").force_encoding(Encoding::UTF_8)
    raise FileError, "content-unreadable" unless text.valid_encoding?
    raise FileError, "line-endings-unsupported" if text.match?(LINE_BREAK_RE)

    text
  end

  # workflow の `uses` の scalar を、位置の key ("jobs.<id>.uses" / "jobs.<id>.steps[<i>].uses") => {line: (1 始まり),
  # value:} で返す。YAML の読み方は ci-check と同じ (文書 1 つ、深さの上限、tag なし、scalar の key、key の重なりなし)。
  def uses_lines(content, path)
    root, doc = load_yaml(content, path)
    raise FileError, "yaml-not-workflow" unless doc.is_a?(Hash) && doc["jobs"].is_a?(Hash) && !doc["jobs"].empty?

    jobs_node = mapping_value(root, "jobs")
    raise FileError, "yaml-not-workflow" unless jobs_node.is_a?(Psych::Nodes::Mapping)

    uses = {}
    jobs_node.children.each_slice(2) do |key, job|
      id = key.value
      raise FileError, "yaml-not-workflow" unless id.match?(JOB_ID_RE) && job.is_a?(Psych::Nodes::Mapping)

      job_uses = mapping_value(job, "uses")
      uses["jobs.#{id}.uses"] = scalar_entry(job_uses) if job_uses
      steps = mapping_value(job, "steps")
      next if steps.nil?
      raise FileError, "yaml-not-workflow" unless steps.is_a?(Psych::Nodes::Sequence)

      steps.children.each_with_index do |step, i|
        raise FileError, "yaml-not-workflow" unless step.is_a?(Psych::Nodes::Mapping)

        step_uses = mapping_value(step, "uses")
        uses["jobs.#{id}.steps[#{i}].uses"] = scalar_entry(step_uses) if step_uses
      end
    end
    uses
  end

  def scalar_entry(node)
    raise FileError, "uses-not-scalar" unless node.is_a?(Psych::Nodes::Scalar) && node.start_line == node.end_line

    { line: node.start_line + 1, value: node.value }
  end

  def load_yaml(content, path)
    Psych::Parser.new(DepthGuard.new).parse(content, path)
    documents = Psych.parse_stream(content, filename: path).children
    raise FileError, "yaml-unreadable" unless documents.size == 1

    root = documents.first.root
    check_ast!(root)
    doc = if Psych::VERSION.split(".").first.to_i >= 4
            YAML.safe_load(content, permitted_classes: [Date, Time], aliases: true, filename: path)
          else
            YAML.safe_load(content, [Date, Time], [], true, path)
          end
    check_keys!(root, doc)
    [root, doc]
  rescue Psych::Exception, ArgumentError
    raise FileError, "yaml-unreadable"
  end

  def check_ast!(root)
    stack = [root]
    until stack.empty?
      node = stack.pop
      raise FileError, "yaml-unreadable" if node.respond_to?(:tag) && node.tag

      if node.is_a?(Psych::Nodes::Mapping)
        node.children.each_slice(2) do |key, _child|
          raise FileError, "yaml-unreadable" unless key.is_a?(Psych::Nodes::Scalar) && key.value != "<<"
        end
      end
      node.children&.each { |child| stack.push(child) }
    end
  end

  def check_keys!(node, value)
    case node
    when Psych::Nodes::Mapping
      pairs = node.children.each_slice(2).to_a
      seen = {}
      pairs.each do |key, _child|
        raise FileError, "yaml-unreadable" if seen.key?(key.value)

        seen[key.value] = true
      end
      raise FileError, "yaml-unreadable" unless value.is_a?(Hash) && value.size == pairs.size

      values = value.values
      pairs.each_with_index { |(_key, child), i| check_keys!(child, values[i]) }
    when Psych::Nodes::Sequence
      raise FileError, "yaml-unreadable" unless value.is_a?(Array) && value.size == node.children.size

      node.children.each_with_index { |child, i| check_keys!(child, value[i]) }
    end
  end

  def mapping_value(node, name)
    return nil unless node.is_a?(Psych::Nodes::Mapping)

    pair = node.children.each_slice(2).find { |key, _value| key.is_a?(Psych::Nodes::Scalar) && key.value == name }
    pair&.last
  end

  # 1 つの bump を確かめる: 版が前に進み、新しい sha が action の repository の tag の commit と一致する。
  def check_bump(api, bump)
    where = "#{bump[:path]}:#{bump[:line]}"
    tags = "#{bump[:old_tag]} -> #{bump[:new_tag]}"
    return label(false, "#{where}: version-not-forward (#{tags})") unless version_forward?(bump[:old_tag], bump[:new_tag])

    owner_repo = bump[:ref].split("/", 3)[0, 2].join("/")
    resolved = resolve_tag(api, owner_repo, bump[:new_tag])
    return label(false, "#{where}: tag-not-found (#{tags})") if resolved == :not_found
    return label(false, "#{where}: tag-not-commit (#{tags})") if resolved == :not_commit
    return label(false, "#{where}: pin-mismatch (#{tags})") unless resolved == bump[:new_sha]

    label(true, "#{where}: pin-ok (#{tags})")
  end

  # tag を数値の tuple に (v は無視)。同じ版 (sha だけが変わる) は前に進んだとみなさない。
  def version_forward?(old_tag, new_tag)
    (version_tuple(new_tag) <=> version_tuple(old_tag)) == 1
  end

  def version_tuple(tag)
    tag.sub(/\Av/, "").split(".").map(&:to_i)
  end

  # action の repository の tag を commit の sha に解く。lightweight なら commit、annotated なら tag object を commit に
  # なるまで解く (深さ MAX_TAG_DEPTH まで)。無ければ :not_found、commit に解けなければ :not_commit。
  def resolve_tag(api, owner_repo, tag)
    ref = api.get("repos/#{owner_repo}/git/ref/tags/#{tag}", allow_404: true)
    return :not_found if ref.nil?

    object = ref.is_a?(Hash) ? ref["object"] : nil
    depth = 0
    loop do
      raise RunError, "tag の応答の形が外れます" unless object.is_a?(Hash) && object["sha"].is_a?(String) && object["sha"].match?(SHA_RE)
      return object["sha"] if object["type"] == "commit"
      # tag object の解決は MAX_TAG_DEPTH 回まで。解いた先の確認は回数と分けて行う (3 段の tag の先の commit も確かめる)。
      return :not_commit unless object["type"] == "tag" && depth < MAX_TAG_DEPTH

      depth += 1
      tag_obj = api.get("repos/#{owner_repo}/git/tags/#{object['sha']}", allow_404: true)
      return :not_commit if tag_obj.nil?

      object = tag_obj.is_a?(Hash) ? tag_obj["object"] : nil
    end
  end

  # base の repo-baseline.json の required_checks を必要な集合とし、head の check-runs で各 check の結果を見る。
  # [確かめた check の数, label の行, ok] を返す。
  def check_ci(api, base_path, pull)
    names = required_checks(api, base_path, pull[:base_sha])
    return [0, ["ci: ci-undefined (#{BASELINE_PATH} か、その required_checks が無い)"], false] if names.nil?

    lines = []
    ok = true
    names.each do |name|
      state = check_run_state(api, base_path, pull[:head_sha], name)
      ok = false unless state == "success"
      lines << "ci #{name}: #{state}"
    end
    [names.size, lines, ok]
  end

  # file が無い (404) か required_checks の key が無ければ nil (ci-undefined)。file が不正なら RunError (判定できない。
  # 規則は personal-repo-baseline と同じ)。名前は出力に載せるので、さらに規則の形に合うものだけ (外れれば RunError)。
  def required_checks(api, base_path, base_sha)
    obj = api.get("#{base_path}/contents/#{BASELINE_PATH}?ref=#{base_sha}", allow_404: true)
    return nil if obj.nil?

    size = obj.is_a?(Hash) ? obj["size"] : nil
    unless obj.is_a?(Hash) && obj["type"] == "file" && obj["encoding"] == "base64" && obj["content"].is_a?(String) &&
           size.is_a?(Integer) && size >= 0
      raise RunError, "#{BASELINE_PATH} を読めません (応答の形が想定外)"
    end
    raise RunError, "#{BASELINE_PATH} が大きすぎます" if size > BASELINE_MAX

    names = parse_baseline(decode_baseline(obj["content"], size))
    return nil if names.nil?
    raise RunError, "required_checks の名前が規則の外です" unless names.all? { |n| n.match?(SAFE_CHECK_NAME_RE) }

    names
  end

  # contents API の base64 (60 文字ごとに改行が入る) を厳密に decode し、本文の byte 数が size と合うことを求める
  # (`unpack1("m")` は alphabet の外の文字や padding の誤りを読み飛ばす)。
  def decode_baseline(content, size)
    text = begin
      content.delete("\n").unpack1("m0")
    rescue ArgumentError
      raise RunError, "#{BASELINE_PATH} を読めません (base64 が壊れている)"
    end
    raise RunError, "#{BASELINE_PATH} を読めません (size が本文と合わない)" unless text.bytesize == size

    text
  end

  # 本文 (JSON の text) から required_checks を返す (key が無ければ nil)。key は skip と required_checks だけで、書くなら
  # 空でない配列 (null も不正)。skip は外せる項目だけ、check の名前は空白だけでない文字列で制御文字を含まない。値の
  # 重なりも不正。理由に中身は出さない。
  def parse_baseline(text)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise RunError, "#{BASELINE_PATH} が UTF-8 として読めません" unless text.valid_encoding?

    data = begin
      JSON.parse(text, object_class: BaselineStrictHash)
    rescue JSON::ParserError
      raise RunError, "#{BASELINE_PATH} が JSON として読めません"
    rescue BaselineDuplicateKeyError
      raise RunError, "#{BASELINE_PATH} に重なった key があります"
    end
    raise RunError, "#{BASELINE_PATH} の top-level が object ではありません" unless data.is_a?(Hash)
    raise RunError, "#{BASELINE_PATH} に知らない key があります" unless (data.keys - BASELINE_KEYS).empty?

    if data.key?("skip")
      skip = data["skip"]
      unless skip.is_a?(Array) && !skip.empty? && skip.all? { |item| BASELINE_SKIPPABLE.include?(item) }
        raise RunError, "#{BASELINE_PATH} の skip が外せる項目の空でない配列ではありません"
      end
      raise RunError, "#{BASELINE_PATH} の skip に重なった値があります" if skip.uniq.size != skip.size
    end
    return nil unless data.key?("required_checks")

    checks = data["required_checks"]
    unless checks.is_a?(Array) && !checks.empty? && checks.all? { |c| baseline_check_name?(c) }
      raise RunError, "#{BASELINE_PATH} の required_checks が空でない check の名前の配列ではありません"
    end
    raise RunError, "#{BASELINE_PATH} の required_checks に重なった値があります" if checks.uniq.size != checks.size

    checks
  end

  # valid_encoding? を先に見る (JSON の孤立した surrogate は不正な UTF-8 の文字列になり、strip や正規表現が例外を出す)。
  def baseline_check_name?(name)
    name.is_a?(String) && name.valid_encoding? && !name.strip.empty? && name !~ /[[:cntrl:]]/
  end

  # head の check-runs のうち名前が一致するもの (最新の attempt) を page ごとに読む (1 page = gh の 1 回で、回数の上限は呼ぶ前に
  # 数える)。page ごとの total_count が一致し、件数が total_count と合わなければ判定しない。無ければ missing、1 つでも終わって
  # いなければ pending、1 つでも success でなければ failure、すべて completed + success なら success。
  def check_run_state(api, base_path, head_sha, name)
    runs = []
    total = nil
    page = 1
    loop do
      query = URI.encode_www_form("check_name" => name, "per_page" => PER_PAGE, "page" => page)
      obj = api.get("#{base_path}/commits/#{head_sha}/check-runs?#{query}")
      unless obj.is_a?(Hash) && obj["check_runs"].is_a?(Array) && obj["total_count"].is_a?(Integer) && obj["check_runs"].all? { |r| r.is_a?(Hash) }
        raise RunError, "check-runs の応答の形が外れます"
      end

      total ||= obj["total_count"]
      raise RunError, "check-runs の total_count が page で変わりました (やり直す)" unless obj["total_count"] == total

      runs.concat(obj["check_runs"])
      break if runs.size >= total || obj["check_runs"].empty?

      page += 1
    end
    raise RunError, "check-runs の件数が total_count と一致しません (全件を読めない)" unless runs.size == total

    runs = runs.select { |r| r["name"] == name }
    return "missing" if runs.empty?
    return "pending" unless runs.all? { |r| r["status"] == "completed" }
    return "failure" unless runs.all? { |r| r["conclusion"] == "success" }

    "success"
  end

  def label(ok, text)
    { ok: ok, text: text }
  end
end

exit DependabotPinCheck.run(ARGV) if $PROGRAM_NAME == __FILE__
