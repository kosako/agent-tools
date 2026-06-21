#!/usr/bin/env ruby
# frozen_string_literal: true

# Static prompt injection checker for shared assets.
# Spec: docs/prompt-injection-check.md
#
# deterministic で、外部依存ゼロ・network access なしで実行できること。
# 対象は shared/ 配下の asset files のみ。policy docs (docs/) は対象外。

require_relative "assets"
require_relative "artifact_targets"

module CheckInjection
  Pattern = Struct.new(:category, :risk, :regexp, :message)

  PATTERNS = [
    # system / developer instructions の override 試行
    Pattern.new("override", "high",
                /ignore\s+(?:all\s+|any\s+)?(?:previous|prior|above|earlier|preceding)\s+(?:instructions?|messages?|rules?|prompts?)/i,
                "attempts to override prior instructions"),
    Pattern.new("override", "high",
                /disregard\s+(?:the\s+|your\s+)?(?:system|developer)\s+(?:prompt|instructions?|messages?)/i,
                "attempts to disregard system or developer instructions"),
    Pattern.new("override", "high",
                /override\s+(?:the\s+)?(?:system|developer|safety)\s+(?:prompt|instructions?|polic(?:y|ies))/i,
                "attempts to override system or safety policy"),
    Pattern.new("override", "high",
                /you\s+are\s+now\s+(?:in\s+)?(?:developer|jailbreak|god|dan)\s*mode/i,
                "jailbreak mode switch attempt"),

    # secrets / credentials の開示・収集要求
    Pattern.new("secrets", "high",
                /(?:reveal|print|show|display|output|send|leak|exfiltrate|dump|paste)\b.{0,60}\b(?:secrets?|credentials?|api[\s_-]?keys?|tokens?|private\s+keys?|passwords?)/i,
                "requests disclosure or collection of secrets"),
    Pattern.new("private-key", "high",
                /-----BEGIN\s[A-Z ]*PRIVATE KEY-----/,
                "contains private key material"),

    # hidden instruction patterns
    Pattern.new("hidden", "medium",
                /[\u200B\u200C\u200D\u2060\uFEFF]/,
                "contains invisible zero-width characters"),
    Pattern.new("hidden", "medium",
                /<!--(?:(?!-->).){0,400}\b(?:ignore|instruction|system\s+prompt|do\s+not\s+tell|secretly)\b(?:(?!-->).){0,400}-->/im,
                "HTML comment containing instruction-like content"),

    # tool permission / approval policy の bypass 試行
    Pattern.new("bypass", "high",
                /(?:bypass|disable|skip|circumvent|turn\s+off)\b.{0,50}\b(?:permissions?|approvals?|sandbox|safety|guardrails?)/i,
                "attempts to bypass permissions or safety gates"),
    Pattern.new("bypass", "high",
                /dangerously[-_]skip[-_]permissions/i,
                "references a permission bypass flag"),

    # external exfiltration / network tunnel / production access
    Pattern.new("exfiltration", "high",
                /(?:exfiltrate|reverse\s+shell|network\s+tunnel|beacon\s+to)/i,
                "exfiltration or tunneling instruction"),
    Pattern.new("exfiltration", "medium",
                /(?:upload|post|send)\b.{0,60}\b(?:external|remote|attacker|third[- ]party)\s+(?:server|endpoint|host)/i,
                "sends content to an external endpoint"),
    Pattern.new("exfiltration", "medium",
                /\bproduction\s+(?:access|credentials?|database)\b/i,
                "requests production access"),

    # tool-managed / runtime state の変更指示
    Pattern.new("runtime-state", "medium",
                %r{~/\.(?:codex|claude)/(?:auth\.json|config\.toml|cache|sessions?|projects|plugins)},
                "references tool-managed or runtime state paths"),
    Pattern.new("runtime-state", "medium",
                /(?:modify|write\s+to|edit|delete)\b.{0,50}\b(?:tool-managed|company-managed|auth|session|runtime\s+state)/i,
                "instructs modification of managed or runtime state"),

    # public repository に出してはいけない個人環境・個人情報の混入。
    # absolute path と email は asset 種別によらず high。
    Pattern.new("absolute-path", "high",
                %r{(?:/Users|/home)/[A-Za-z0-9._-]+|/root(?![A-Za-z0-9_])},
                "contains a user-specific absolute path"),
    # Windows の user-specific path (例 C:\Users\<name>\...) も検知する。
    Pattern.new("absolute-path", "high",
                /[A-Za-z]:\\Users\\[^\\\r\n]+/,
                "contains a user-specific absolute path"),
    Pattern.new("pii", "high",
                /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
                "contains an email address (possible PII)"),
    # external URL は検知するが現状 low (gate を通す)。artifact_kind 別 policy
    # (instruction=strict で high に昇格) は後続の artifact kind 対応で導入する。
    Pattern.new("external-url", "low",
                %r{https?://[^\s)>"'\]]+}i,
                "contains an external URL"),
  ].freeze

  RISK_ORDER = { "high" => 2, "medium" => 1, "low" => 0 }.freeze

  # evals/ でも scan する category。evals は injection 攻撃文字列を「skill が転記/実行
  # しないこと」を検証するテスト材料として意図的に含み、その攻撃文字列には fake な絶対パス
  # (例 /Users/me/secrets/key.pem) や email も含まれる。よって absolute-path / pii は
  # evals では正当な fixture として現れうるため抑止する。一方、inline の private key
  # 本体 (-----BEGIN ... PRIVATE KEY-----) は fixture では path 参照で代替され実体を
  # 置く必要がないため、evals に在れば真の leak とみなして必ず scan する。
  LEAK_CATEGORIES = %w[private-key].freeze

  Finding = Struct.new(:path, :line, :risk, :category, :message) do
    def to_s
      "#{path}:#{line}: [#{risk}] #{category}: #{message}"
    end
  end

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
    end

    # shared/ 配下のすべての text files を scan する。manifest も text として含める。
    # directory skill の evals/ (テスト材料。意図的に攻撃的文字列を含みうる) は
    # injection 攻撃文字列の scan からは外すが、privacy/secret leak は引き続き scan する
    # (run で per-file に判定する)。
    def target_files
      Dir.glob(File.join(@root, "shared/**/*"), File::FNM_DOTMATCH)
         .select { |p| File.file?(p) }
         .reject { |p| File.basename(p) == ".gitkeep" }
         .sort
    end

    def run
      instruction_sources = instruction_source_paths
      eval_prefixes = skill_eval_dir_prefixes
      findings = []
      count = 0
      target_files.each do |full|
        content = File.read(full, mode: "rb").force_encoding(Encoding::UTF_8)
        next if content.include?("\x00") # binary は対象外

        content = content.scrub("�")
        count += 1
        rel_path = rel(full)
        # evals/ は injection 攻撃文字列をテスト材料として含むため leak のみ scan する。
        leak_only = eval_prefixes.any? { |pre| full.start_with?(pre) }
        file_findings = scan(rel_path, content, leak_only)
        # instruction asset の source は external URL を strict (high) に昇格する。
        # instruction は具体参照先を書かない方針なので、URL 混入は方針違反として止める。
        file_findings = file_findings.map { |f| strict_instruction(f) } if instruction_sources.include?(rel_path)
        findings.concat(file_findings)
      end
      [count, findings]
    end

    private

    def strict_instruction(finding)
      return finding unless finding.category == "external-url"

      Finding.new(finding.path, finding.line, "high", finding.category, finding.message)
    end

    # instruction artifact を生成する asset の source path 一覧。
    # 壊れた manifest では昇格しない (gate の check-manifests が別途 fail させる)。
    def instruction_source_paths
      paths = []
      Assets.load_all(@root).each do |asset|
        next unless asset[:source].is_a?(Hash)
        next unless asset[:targets].is_a?(Array)

        instruction = asset[:targets].any? { |t| ArtifactTargets.resolve(asset, t) == "instruction" }
        paths << asset[:source]["path"] if instruction
      end
      paths
    rescue Psych::Exception
      []
    end

    # directory skill の evals/ 配下を leak_only 判定するための絶対 path prefix 一覧。
    # (evals は injection 攻撃文字列を抑止し leak (private-key) のみ scan する。run が使う。)
    # 壊れた manifest では prefix を出さない (gate の check-manifests が別途 fail させる)。
    def skill_eval_dir_prefixes
      prefixes = []
      Assets.load_all(@root).each do |asset|
        source = asset[:source]
        next unless source.is_a?(Hash) && source["format"] == "directory"
        next unless source["path"].is_a?(String)
        next unless asset[:targets].is_a?(Array)

        is_skill = asset[:targets].any? { |t| ArtifactTargets.resolve(asset, t) == "skill" }
        next unless is_skill

        ArtifactTargets::SKILL_NON_DEPLOY_DIRS.each do |sub|
          prefixes << "#{File.join(@root, source['path'], sub)}/"
        end
      end
      prefixes
    rescue Psych::Exception
      []
    end

    def rel(path)
      path.sub(%r{\A#{Regexp.escape(@root)}/}, "")
    end

    # leak_only=true (evals/) のときは privacy/secret leak の category だけを当てる。
    def scan(path, content, leak_only = false)
      patterns = leak_only ? PATTERNS.select { |p| LEAK_CATEGORIES.include?(p.category) } : PATTERNS
      patterns.flat_map do |pattern|
        positions = []
        pos = 0
        while (match = pattern.regexp.match(content, pos))
          positions << match.begin(0)
          pos = match.begin(0) + [match[0].length, 1].max
        end
        positions.map do |offset|
          line = content[0...offset].count("\n") + 1
          Finding.new(path, line, pattern.risk, pattern.category, pattern.message)
        end
      end
    end
  end

  def self.main(argv)
    root = Dir.pwd
    quiet = false
    until argv.empty?
      case (arg = argv.shift)
      when "--root"
        root = argv.shift or abort_usage
      when "--quiet"
        quiet = true
      when "-h", "--help"
        print_usage
        return 0
      else
        warn "unknown option: #{arg}"
        abort_usage
      end
    end

    count, findings = Runner.new(root).run
    findings.sort_by! { |f| [f.path, f.line, -RISK_ORDER.fetch(f.risk)] }
    findings.each { |f| puts f }

    highest = findings.map { |f| RISK_ORDER.fetch(f.risk) }.max || 0
    if highest >= RISK_ORDER.fetch("high")
      warn "fail: high risk findings present (registration fail)"
      1
    elsif highest >= RISK_ORDER.fetch("medium")
      warn "warn: medium risk findings present (human review required)"
      3
    elsif findings.empty?
      puts "ok: #{count} file(s) scanned, no findings" unless quiet
      0
    else
      puts "ok: #{count} file(s) scanned, #{findings.size} low-risk finding(s)" unless quiet
      0
    end
  end

  def self.print_usage
    puts "usage: check-injection.sh [--root DIR] [--quiet]"
  end

  def self.abort_usage
    print_usage
    exit 2
  end
end

exit CheckInjection.main(ARGV) if $PROGRAM_NAME == __FILE__
