# scripts/tests/*.sh の Ruby heredoc program が共有する check ハーネス。
# suite 側から
#   ruby -r"$script_dir/lib/check_helper" - ... <<'RUBY'
# で読み込む契約。top-level main の instance 変数 @failed は require 先と
# stdin program で共有される (macOS system ruby 2.6 で動作確認済み)。
# 終了判定 exit(@failed.zero? ? 0 : 1) は各 suite の program 末尾に残す。

@failed = 0

def check(name, cond)
  return if cond

  warn "FAIL: #{name}"
  @failed += 1
end
