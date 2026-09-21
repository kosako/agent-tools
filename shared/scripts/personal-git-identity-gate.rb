#!/usr/bin/env ruby
# frozen_string_literal: true

# git-identity-gate: pre-commit stage の git gate。commit に使われる author / committer の
# identity が name / email とも非空であることを検証し、partial な identity (空 email) の
# commit を止める (#281)。
#
# 正本: docs/git-hook-gates.md。
#
# 背景: Git は空の name を拒否する (`empty ident name ... not allowed`) が、空の email は
# 受理して `Name <>` の commit を作る (git 2.50.1 で実測)。`user.useConfigOnly` は「未設定」
# を止めるだけで「明示的に空」は止められず、gitconfig の include 順や値でも表現できない。
# dotfiles 側の identity reset (非 personal context で `[user] name = / email =` の空値を
# 挟む設計) と、context の identity file が name だけの partial な状態が重なると、この穴を
# 踏む。可視化 (prompt / doctor) は既にあるので、機械的に止める最後の 1 段がこの gate。
#
# 強度ラベル (偽らない): 通常経路 (git commit) に対する best-effort guardrail。
# `--no-verify` / repo local の core.hooksPath / hook gates を無効化した環境では守れない。
# enforcement boundary ではない。
#
# 検査内容:
# - `git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT` を解決し、name / email が両方
#   非空であること。git が identity を解決できない (空 name 等で rc≠0) 場合も block。
# - context 一致 (repo の場所と email の対応) は検査しない。dotfiles 側の layout 規約に
#   依存するため実体 (この gate) には持たず、必要なら別 Issue で扱う。
# - 環境変数 / `git -c` による identity 上書きは `git var` の解決結果に含まれる。上書き自体を
#   検出・拒否はしない (現行の分離方針と同じ)。
#
# 出力の規律: identity の**値** (name / email) は stdout / stderr に出さない。出すのは key 名
# (author name / author email / committer name / committer email) と「空」であることだけ。
# git の stderr も値 (`for <email>`) を含みうるので捨てる。
#
# exit code: 0 = pass / 1 = identity が不完全 (partial / 解決不能) / 2 = usage・構成エラー
# (git 不在等の想定外)。引数は取らない (pre-commit は引数ゼロ)。

module GitIdentityGate
  VERSION = "1"

  # `git var GIT_*_IDENT` の形: `<name> <<email>> <timestamp> <tz>`。name / email は空でも
  # 形は保たれる (`Name <> 1700000000 +0900` / ` <a@b> ...` は git 側で拒否されるが念のため)。
  IDENT_RE = /\A(?<name>.*?) <(?<email>[^>]*)> \d+ [-+]\d{4}\z/

  KINDS = %w[AUTHOR COMMITTER].freeze

  module_function

  # git var の 1 行を name / email に分解する。形が合わなければ nil。
  def parse(line)
    m = IDENT_RE.match(line.to_s.chomp)
    return nil unless m

    { name: m[:name], email: m[:email] }
  end

  # 解決結果から finding (key 名と「空」であること) を列挙する。値は含めない。
  # resolved: { "AUTHOR" => { name:, email: } | nil, "COMMITTER" => ... }。nil は git が
  # identity を解決できなかった (rc≠0 / 形が合わない) ことを表す。
  def findings(resolved)
    resolved.flat_map do |kind, ident|
      label = kind.downcase
      next ["#{label} identity could not be resolved by git (name or email missing)"] if ident.nil?

      found = []
      found << "#{label} name is empty" if ident[:name].strip.empty?
      found << "#{label} email is empty" if ident[:email].strip.empty?
      found
    end
  end

  # git に identity を解決させる。stderr は値 (`for <email>`) を含みうるので捨てる。
  def resolve(kind)
    out = IO.popen(["git", "var", "GIT_#{kind}_IDENT"], err: File::NULL, &:read)
    return nil unless $?.success?

    parse(out)
  end

  # 純粋な判定。exit code を返す。
  def judge(resolved)
    found = findings(resolved)
    return 0 if found.empty?

    warn "git-identity-gate: blocked: partial identity: #{found.join('; ')}."
    warn "git-identity-gate: set user.name and user.email in the git config that applies to " \
         "this repository (context gitconfig), then retry. Values are never printed here."
    1
  end

  def run(_argv = [])
    judge(KINDS.map { |kind| [kind, resolve(kind)] }.to_h)
  rescue StandardError => e
    # 想定外は入力・構成エラーの exit 2 に倒す (fail-closed)。値を含みうる message は出さず
    # class 名のみ。
    warn "git-identity-gate: unexpected error (#{e.class})"
    2
  end
end

exit GitIdentityGate.run(ARGV) if $PROGRAM_NAME == __FILE__
