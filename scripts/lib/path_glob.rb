# frozen_string_literal: true

# runtime 由来の directory (repo root / tool home / generated dir / asset の source dir) の下を
# glob で列挙する入口。directory を pattern に連結すると、path に含まれる glob の特殊文字
# (`[` `]` `{` `}` `*` `?`) が pattern として解釈され、走査が空になるか別の path に一致する
# (#427 の 1)。`base:` に渡した directory は literal として扱われるので、pattern は常に
# directory からの相対形だけを書く。
module PathGlob
  # dir の下で pattern (dir からの相対。`**/*` や `personal-*` など) に一致する path を、
  # dir を前置した絶対 path で返す。順序は Dir.glob のまま (呼び出し側が sort する)。
  # dir が無ければ空。flags は Dir.glob と同じ (File::FNM_DOTMATCH など)。
  def self.under(dir, pattern, flags = 0)
    Dir.glob(pattern, flags, base: dir).map { |rel| File.join(dir, rel) }
  end
end
