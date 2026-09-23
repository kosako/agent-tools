# frozen_string_literal: true

# CLI 引数解析の共通 boilerplate (#192)。8 entrypoint (sync / connect / status / doctor /
# build / register / check-manifests / check-injection) の同型 parse loop を宣言 spec で
# 置き換える。挙動の正本は characterization test (scripts/tests/cli-args-test.sh):
#
# - 左から 1 token ずつ読み、同一 flag の重複は後勝ち。
# - -h / --help は usage を stdout に出して即 :help を返す (以降の token は読まない。
#   exit フローは main 側の return 0 に残す)。
# - 未知 option は "unknown option: <arg>" を stderr、usage を stdout に出して exit 2。
# - value flag の値欠落 (argv 枯渇 = nil) は unknown 行なしで usage を stdout に出して exit 2。
# - 値の加工 (File.expand_path 等) は呼び出し元の責務 (--root を生値のまま使う既存挙動を
#   変えないため)。
# - --root を省略したときの root は DEFAULT_ROOT (script の属する repo) で、cwd には依存しない
#   (#305)。
#
# check_credential_isolation.rb は error 時 usage を stderr に出す別契約のため対象外。
module Cli
  # --root 省略時の repo root。この file (scripts/lib/cli.rb) の 2 つ上。__dir__ は realpath
  # なので、symlink 経由で起動しても実体の repo を指す。repo 外の cwd から絶対 path で
  # 起動したときに cwd を root とみなして空ツリーを処理しないため、cwd は使わない (#305)。
  DEFAULT_ROOT = File.expand_path("../..", __dir__)

  # argv を { "--flag" => true | "<value>" } に解析して返す。-h / --help は :help を返す。
  def self.parse(argv, usage:, bool_flags: [], value_flags: [])
    opts = {}
    until argv.empty?
      arg = argv.shift
      case arg
      when "-h", "--help"
        puts usage
        return :help
      when *bool_flags
        opts[arg] = true
      when *value_flags
        value = argv.shift
        if value.nil?
          puts usage
          exit 2
        end
        opts[arg] = value
      else
        warn "unknown option: #{arg}"
        puts usage
        exit 2
      end
    end
    opts
  end
end
