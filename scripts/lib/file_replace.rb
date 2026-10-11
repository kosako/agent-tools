# frozen_string_literal: true

# 配置先の file を一時 file + rename で入れ替える helper。sync の apply / prune と connect の所有ファイルの作成が
# 共有する (#431 の 3, #482)。書き込みが途中で止まっても、切れた file を配置先に置かない (先頭行の marker だけで
# up-to-date / 接続済みを決める kind を守る)。require 時の副作用はない。

require "fileutils"

module FileReplace
  # 配置先を安全に入れ替えられない・撤去しきれないときの error: 前回の残り (一時 dir / file、退避した旧 dir) や、
  # 新版を置いた後の退避した旧 dir、prune の消し残しを消しきれない。sync / connect の main が `fail:` の行と
  # exit 1 で止める (build の OutputPathError と同じ伝え方)。
  class ApplyError < StandardError; end

  module_function

  # apply の作業用 path (一時 dir / file = staging、退避した旧 dir = old)。配置先と同じ親 dir に置く (rename が
  # 同じ filesystem の中で済む)。`personal-` で始めないので plan / prune / status / doctor の走査 (personal-*)
  # には拾われない。pid を含めず固定の名前にして、前回の中断 (kill 等で ensure が走らなかったとき) の残りを
  # 次の run が同じ名前で見つけて消せるようにする (同時実行は前提にしない。docs/sync-policy.md の TOCTOU の項と
  # 同じ立場)。
  def work_path(target, label)
    File.join(File.dirname(target), ".agent-tools-#{label}-#{File.basename(target)}")
  end

  # 単一 file の create / update。一時 file に copy し、mode があれば付けてから rename で入れ替える。cp は
  # 新規 file の mode を source に合わせる (umask で落とす) ので、mode を渡さない sidecar marker は従来の
  # cp と同じ mode になる。一時 file の path に directory や消せない file があれば止める (rm_f は失敗を
  # 握りつぶし、cp は directory の中へ入れ子に copy して、create なら rename が配置先に directory を置く)。
  # 例外のときも一時 file は片付ける (#431 の 3, #469 review)。
  def replace_file(gen, target, mode = nil)
    staging = work_path(target, "staging")
    FileUtils.rm_f(staging)
    if File.exist?(staging)
      raise ApplyError, "could not remove the leftover staging file #{staging}; the new version was not applied"
    end
    begin
      FileUtils.cp(gen, staging)
      File.chmod(mode, staging) if mode
      File.rename(staging, target)
    ensure
      FileUtils.rm_f(staging)
    end
  end

  # 配置先の今の mode (permission bits)。無ければ nil。instruction の所有ファイルは、配置先へ直接 cp していた頃と
  # 同じく、入れ替えの後も既存の file の mode を保つ (replace_file に渡す。nil なら cp の既定の mode になる)。
  def existing_mode(path)
    File.exist?(path) ? File.stat(path).mode & 0o7777 : nil
  end

  # rm_rf は削除の失敗 (書き込み不可の dir の中の file など) を握りつぶすので、消えたことを返り値で確かめる
  # (build.rb の旧い出力 dir の検査と同じ)。
  def removed?(path)
    FileUtils.rm_rf(path)
    !File.exist?(path)
  end
end
