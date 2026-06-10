#!/usr/bin/env ruby
# frozen_string_literal: true

# Static prompt injection checker for shared assets.
# Spec: docs/prompt-injection-check.md
#
# deterministic で、外部依存ゼロ・network access なしで実行できること。
# 対象は shared/ 配下の asset files のみ。policy docs (docs/) は対象外。

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
    Pattern.new("secrets", "high",
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
  ].freeze

  RISK_ORDER = { "high" => 2, "medium" => 1, "low" => 0 }.freeze

  Finding = Struct.new(:path, :line, :risk, :category, :message) do
    def to_s
      "#{path}:#{line}: [#{risk}] #{category}: #{message}"
    end
  end

  class Runner
    def initialize(root)
      @root = File.expand_path(root)
    end

    # shared/ 配下のすべての text files を scan する。
    # manifest も text として scan 対象に含める。
    def target_files
      Dir.glob(File.join(@root, "shared/**/*"), File::FNM_DOTMATCH)
         .select { |p| File.file?(p) }
         .reject { |p| File.basename(p) == ".gitkeep" }
         .sort
    end

    def run
      findings = []
      count = 0
      target_files.each do |full|
        content = File.read(full, mode: "rb").force_encoding(Encoding::UTF_8)
        next if content.include?("\x00") # binary は対象外

        content = content.scrub("�")
        count += 1
        findings.concat(scan(rel(full), content))
      end
      [count, findings]
    end

    private

    def rel(path)
      path.sub(%r{\A#{Regexp.escape(@root)}/}, "")
    end

    def scan(path, content)
      PATTERNS.flat_map do |pattern|
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
    else
      puts "ok: #{count} file(s) scanned, no findings" unless quiet
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
