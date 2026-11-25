# frozen_string_literal: true

# 評価の run で Claude Code の自動の memory を止める設定と、その記録の形 (#770)。skill の挙動の評価と routing の評価の、
# probe (書く側) と judge (読む側) が共有する。
#
# 止めないと、run ごとに ~/.claude/projects の下に空の memory の dir ができ、model に memory の置き場が示される
# (Claude Code 2.1.331 で確かめた)。
#
# 記録は、渡した設定と、run で見えた状態を分けて残す。
#   requested: 子 process に渡した設定。いつも off。
#   init: init の event に見えた状態。listed (memory の置き場が示されている)、not-listed (示されていない)、unknown (init が
#         無い、または形が読めない)。run の間で食い違えば mixed: の後に並べる。
# not-listed は、init に置き場が示されていないことだけを言う。この field を出さない版の CLI でも not-listed になる。
module AutoMemory
  # Claude Code の子 process にだけ足す環境。親の環境の値より優先する。
  ENV_OFF = { "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1" }.freeze
  REQUESTED = "off"
  NOT_LISTED = "not-listed"

  # init の event (type=system、subtype=init の Hash) から、1 つの状態を決める。
  def self.state(event)
    paths = event["memory_paths"]
    return NOT_LISTED if paths.nil?
    return "unknown" unless paths.is_a?(Hash)

    paths["auto"].nil? ? NOT_LISTED : "listed"
  end

  # run ごとの状態の並び (init の event ごとに 1 つ。init の無い run は空の配列) から、results に書く値を作る。
  def self.record(states_by_run)
    states = states_by_run.flat_map { |s| s.empty? ? ["unknown"] : s }.uniq
    states = ["unknown"] if states.empty?
    { "requested" => REQUESTED, "init" => states.length == 1 ? states.first : "mixed:#{states.join(',')}" }
  end

  # results の値の形 (judge の入力の検査)。
  def self.valid?(value)
    value.is_a?(Hash) && value.keys.sort == %w[init requested] && value["requested"] == REQUESTED &&
      value["init"].is_a?(String) && !value["init"].empty?
  end

  # どの run の init にも、memory の置き場が示されていなかったか。
  def self.off?(value)
    value["init"] == NOT_LISTED
  end
end
