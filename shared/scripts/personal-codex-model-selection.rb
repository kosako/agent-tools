#!/usr/bin/env ruby
# frozen_string_literal: true

# codex-model-selection: Codex を `--ignore-user-config` で起動する caller (personal-codex-review の LAUNCH、
# personal-maintenance-sweep の BUDGET、grill の CONSULT) が、user の model / effort を `-c` で再指定する
# ために読む CLI (#364)。重ね方 (config.toml の top-level を base に `<profile>.config.toml` の top-level の
# 同じ key を key ごとに重ねる) と TOML の読み方は、同じ directory に配備された
# personal-codex-worker-preflight の `layered_model_selection` を load して使い、ここには写さない (worker
# の preflight も同じ関数で読む)。
#
# 引数は列挙だけを受け付ける: `--profile review|worker` (公開契約の file 名 agent-tools-review.config.toml /
# agent-tools-worker.config.toml に固定し、任意の path は受け取らない) と `--format json|model`。Codex home
# は `$CODEX_HOME` (空なら ~/.codex)。
#
# 出力 (exit 0):
# - json: {"selection": {key: value}, "sources": {key: "user config" | "<profile> profile"}}。無い key は
#   含めない (Codex の既定に委ねる)。config に選ばれたプロバイダ (model_provider) があれば、さらに
#   "provider": {`-c` の key: value} と "provider_sources": {key: 出所} を足す (#543。`--ignore-user-config` で外れる
#   プロバイダの設定のうち、引き継ぐ key だけ。読み方は preflight の layered_provider_selection)。caller は provider
#   の key をすべて `-c key="value"` で渡す。
# - model: model の値を 1 行 (無ければ空行)。provider があれば引き継げないので exit 2。
# effort をどう使うかは caller が決める (review は選択のまま、sweep はプリセット、consult は独自の値)。
#
# exit 2: usage / preflight を load できない / top-level に解釈できない行 / 値が形に合わない / file は在るが
# regular file でない / 在るかを確かめられない・読めない。理由は stderr に出し、stdout には何も出さない。
# 理由文に file の中身と path は出さない。

require "json"

# C locale (LC_ALL=C や LANG の未設定) でも、読む text (stdin・file・git や gh の出力) を UTF-8 として扱う (#432)。
# 既定の external encoding が US-ASCII のままだと、日本語を含む値への正規表現や連結が例外で落ちる。
# scripts/lib/cli.rb (#418) と同じ固定。ENV と ARGV の encoding は変わらない。
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

module CodexModelSelection
  PREFLIGHT_NAME = "personal-codex-worker-preflight"
  # `--profile` の値 => Codex home の `<name>.config.toml` の name。
  PROFILES = { "review" => "agent-tools-review", "worker" => "agent-tools-worker" }.freeze
  FORMATS = %w[json model].freeze

  module_function

  def usage
    "usage: personal-codex-model-selection --profile review|worker --format json|model"
  end

  def parse_args(argv)
    flags = { "--profile" => :profile, "--format" => :format }
    opts = {}
    args = argv.dup
    until args.empty?
      key = flags[args.shift]
      value = args.shift
      raise ArgumentError, usage if key.nil? || value.nil? || opts.key?(key)

      opts[key] = value
    end
    raise ArgumentError, usage unless PROFILES.key?(opts[:profile]) && FORMATS.include?(opts[:format])

    opts
  end

  def load_preflight
    load File.join(File.dirname(File.realpath(__FILE__)), PREFLIGHT_NAME)
  rescue ScriptError
    raise ArgumentError, "#{PREFLIGHT_NAME} を load できません (同じ directory に配備されているか確かめてください)"
  end

  # provider は [{key => value}, {key => 出所}] (選ばれたプロバイダを引き継ぐ `-c`。無ければ空。#543)。
  def render(opts, selection, sources, provider)
    overrides, provider_sources = provider
    if opts[:format] == "model"
      # model だけを渡す caller はプロバイダを引き継げないので、黙って OpenAI の既定に倒さず止める。
      raise ArgumentError, "provider の設定があるので、--format json で provider も読んでください" unless overrides.empty?

      return selection.fetch("model", "")
    end

    labels = { "config" => "user config", "profile" => "#{opts[:profile]} profile" }
    out = { "selection" => selection, "sources" => sources.transform_values { |s| labels.fetch(s) } }
    unless overrides.empty?
      out["provider"] = overrides
      out["provider_sources"] = provider_sources.transform_values { |s| labels.fetch(s) }
    end
    JSON.generate(out)
  end

  def run(argv)
    opts = parse_args(argv)
    load_preflight
    home = CodexWorkerPreflight.codex_home(nil)
    profile = PROFILES.fetch(opts[:profile])
    selection, sources = CodexWorkerPreflight.layered_model_selection(home, profile)
    provider = CodexWorkerPreflight.layered_provider_selection(home, profile)
    puts render(opts, selection, sources, provider)
    0
  rescue ArgumentError => e
    warn "personal-codex-model-selection: #{e.message}"
    2
  rescue StandardError => e
    warn "personal-codex-model-selection: unexpected error (#{e.class})"
    2
  end
end

exit CodexModelSelection.run(ARGV) if $PROGRAM_NAME == __FILE__
