# frozen_string_literal: true

# repo の外の local な file に人が置く、private な指示の断片 (#689)。instruction の所有ファイル (claude-code の
# <claude home>/agent-tools/CLAUDE.md と codex の <codex home>/AGENTS.md) に置く内容は、generated の後ろにこの断片の
# 節を足したものになる。
#
# - 置き場所は ${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/instructions.local.md に固定する。XDG_CONFIG_HOME は絶対
#   path のときだけ使い、HOME も絶対 path でなければ場所を決めない (invalid。personal-usage-reader と同じ)。
# - 読むのは sync (置く内容を組む) と doctor (状態を出す) だけ。build・generated・catalog は断片を読まない
#   (public な内容だけを持たせ、tracked な catalog に machine ごとの差を出さない)。
# - 中身は出力しない。doctor が出すのは状態と、invalid のときの理由だけ。
# - 書くのは人だけ (agent は書かない)。static な injection の検査はかけず、形だけを確かめる: regular file で
#   symlink でない、UTF-8 として読める、MAX_BYTES 以下。満たさないときの扱いは呼び出し側が決める (sync は
#   instruction の plan を conflict にする)。
module LocalInstructions
  BASENAME = "instructions.local.md"
  # Codex は instruction の file を合計で project_doc_max_bytes (既定 32 KiB) まで読む。global な AGENTS.md
  # (約 20 KB) に足しても収まる大きさにする。
  MAX_BYTES = 8 * 1024
  # 足す節の見出し (1 行)。repo の外の local な file から足した節だと分かる文言にする。
  HEADING = "# この machine の local の指示 (repo の外の local な file から、agent-tools の sync が足した節)"

  # state: :absent (file が無い) / :empty (空白だけ。何も足さない) / :present / :invalid (reason つき)。
  # content は :present のときだけ (UTF-8 の String)。
  Result = Struct.new(:state, :content, :reason)

  module_function

  # 断片の file の path。場所を決められなければ nil。
  def path(env = ENV)
    xdg = env["XDG_CONFIG_HOME"].to_s
    base =
      if xdg.start_with?("/")
        xdg
      else
        home = env["HOME"].to_s
        return nil unless home.start_with?("/")

        File.join(home, ".config")
      end
    File.join(base, "agent-tools", BASENAME)
  end

  # 断片を読んで状態を返す。例外は投げない (読めないものは :invalid にする)。
  def read(env = ENV)
    file = path(env)
    return invalid("cannot locate the file (HOME is not an absolute path)") if file.nil?

    data = nil
    # NOFOLLOW で symlink を開かずに弾き、NONBLOCK で FIFO の open を待たない。種類は開いた fd で確かめる
    # (lstat の後に開くと、間に差し替えられうる)。
    File.open(file, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |f|
      return invalid("the file is not a regular file") unless f.stat.file?

      # 空の file では read(n) が nil を返す。
      data = f.read(MAX_BYTES + 1) || +""
    end
    return invalid("the file is larger than #{MAX_BYTES} bytes") if data.bytesize > MAX_BYTES

    data.force_encoding(Encoding::UTF_8)
    return invalid("the file is not valid UTF-8") unless data.valid_encoding?
    return Result.new(:empty, nil, nil) if data.strip.empty?

    Result.new(:present, data, nil)
  rescue Errno::ENOENT
    Result.new(:absent, nil, nil)
  rescue Errno::ELOOP
    invalid("the file is a symlink")
  rescue SystemCallError, IOError => e
    invalid("cannot read the file (#{e.class})")
  end

  def invalid(reason)
    Result.new(:invalid, nil, reason)
  end

  # 所有ファイルに置く内容 (bytes)。断片が無い (:present でない) ときは generated と同じ bytes。在るときは、
  # generated の後ろに空行、見出し 1 行、空行、断片の本文を続ける (本文の末尾に改行が無ければ足す)。
  def deployed_content(generated, result)
    gen = generated.b
    return gen unless result && result.state == :present

    body = result.content.b
    body += "\n".b unless body.end_with?("\n")
    sep = gen.end_with?("\n") ? "".b : "\n".b
    [gen, sep, "\n", HEADING, "\n\n", body].map(&:b).join
  end
end
