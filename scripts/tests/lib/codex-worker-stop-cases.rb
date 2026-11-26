# frozen_string_literal: true
require "ripper"
require "set"

# Source の停止点を抽出する。CLI は実行しない。
# 呼出し元の段と rescue による吸収は下の context で明示する。
# 未知の停止点・動的引数・段は推測で通さず、対応の見直しを求める。
module CodexWorkerStopCases
  module_function

  def walk(node, &block)
    return unless node.is_a?(Array)
    yield node if node.first.is_a?(Symbol)
    node.each { |child| walk(child, &block) if child.is_a?(Array) }
  end

  def literal(node)
    return unless node && node[0] == :string_literal
    content = node[1]
    return unless content && content[0] == :string_content && content.size == 2 && content[1][0] == :@tstring_content
    content[1][1]
  end

  def call(node)
    return unless node[0] == :method_add_arg && node[2][0] == :arg_paren
    callee = node[1]
    name = if callee[0] == :fcall
             callee[1][1]
           elsif callee[0] == :call && callee[1][0] == :var_ref && callee[1].dig(1, 0) == :@const && callee[1].dig(1, 1) == "Stop" && callee[3][1] == "new"
             "Stop.new"
           end
    return unless %w[stop command json Stop.new stage stop_executor update_packet].include?(name)
    args = node[2][1]
    raise "未対応の引数: #{name}" unless args && args[0] == :args_add_block
    [name, args[1]]
  end

  def calls(body)
    out = []
    walk(body) do |node|
      entry = call(node)
      out << entry if entry && entry.first != "update_packet"
    end
    out
  end

  def extract(source)
    ast = Ripper.sexp(source) or raise "Ruby の解析失敗"
    methods = {}
    walk(ast) { |n| methods[n[1][1]] = n[3] if n[0] == :def }
    assignments = {}
    methods.each do |name, body|
      walk(body) do |node|
        next unless %i[assign massign].include?(node[0])
        variables = []
        walk(node[1]) { |part| variables << part[1] if part[0] == :@ivar }
        next unless variables.include?("@blocked_at")
        values = []
        walk(node[2]) { |part| value = literal(part); values << value if value }
        (assignments[name] ||= []) << values
      end
    end
    expected_assignments = {
      "initialize" => [%w[input authorization]], "stage" => [[]],
      "read_packet" => [["authorization"], ["launch-record"]],
      "check_other_records" => [["launch-path"]], "resolve_branch" => [["launch-record"]],
      "stop_executor" => [["completion"]],
      "collect" => [%w[completion executor-result], ["executor-result"]]
    }
    raise "blocked_at の代入と context を見直す" unless assignments == expected_assignments
    # context を上書きする method は停止点・段・packet 更新との構文上の順序も固定する。
    # 分岐条件や別 subcommand からの呼出し経路まで証明する検査ではない。
    expected_order = {
      "read_packet" => %w[command:packet-check assign:authorization stop:packet-missing stop:packet-state
                          stop:request-empty assign:launch-record stop:packet-list],
      "check_other_records" => %w[assign:launch-path stop:worker-running stop:run-unconfirmed],
      "resolve_branch" => %w[stop:branch assign:launch-record update_packet:branch],
      "stop_executor" => %w[stage:snapshot stage:backup stage:transcription update_packet:stop assign:completion stop:*],
      "collect" => %w[stage:records stage:wait stop_executor:* stop_executor:* stop_executor:empty-result
                      assign:completion,executor-result stop:empty-result stage:pane-log command:pane-log stop:pane-log
                      stage:snapshot stage:commits stage:transcription
                      update_packet:stop assign:executor-result stop:worker-question update_packet:result stop:run-record]
    }
    expected_order.each do |name, expected|
      order = []
      walk(methods.fetch(name)) do |node|
        if %i[assign massign].include?(node[0])
          variables = []
          walk(node[1]) { |part| variables << part[1] if part[0] == :@ivar }
          if variables.include?("@blocked_at")
            values = []
            walk(node[2]) { |part| value = literal(part); values << value if value }
            order << "assign:#{values.join(',')}"
          end
        end
        entry = call(node)
        next unless entry
        callee, args = entry
        index = %w[command json].include?(callee) ? 1 : 0
        order << "#{callee}:#{literal(args[index]) || '*'}"
      end
      raise "blocked_at と停止点の順序を見直す: #{name}" unless order == expected
    end
    # 段の変更を検出する。追加時には呼出し元の context と回復表も見直す。
    stages = methods.values.flat_map { |body| calls(body).select { |n, _| n == "stage" }.map { |_, a| a.map { |v| literal(v) } } }.uniq.sort
    expected_stages = {
      "environment" => "preflight", "packet" => "launch-record", "records" => "launch-record",
      "workspace" => "launch-path", "branch" => "authorization", "run-directory" => "launch-path",
      "clone" => "clone", "commit-prerequisites" => "clone", "preflight" => "preflight",
      "run-location" => "launch-path", "artifacts" => "launch-path", "run-record" => "launch-record",
      "herdr" => "launch-path", "wait" => "executor-exit", "backup" => "clone",
      "transcription" => "transcription", "pane-log" => "transcription", "commits" => "clone",
      "fetch" => "fetch", "trailer" => "trailer", "merge-commits" => "public-safety",
      "style" => "public-safety", "publish-gate" => "public-safety", "destination" => "public-safety", "marker" => "public-safety",
      "packet-again" => "launch-record", "clone-state" => "fetch", "fetched-head" => "fetch"
    }.to_a + [["snapshot", "clone"], ["snapshot", "fetch"]]
    raise "stage の context を見直す" unless stages == expected_stages.sort

    all = %w[launch collect retry-empty check]
    start = %w[launch retry-empty]
    read = %w[launch collect retry-empty]
    contexts = {}
    add = lambda { |names, commands, at| names.split.each { |name| (contexts[name] ||= []).concat(commands.map { |c| [c, at] }) } }
    add.call("parse read_publish_input", all, "authorization")
    add.call("packet_rows target", all, "launch-record")
    add.call("packet_rows target", ["collect"], "transcription")
    add.call("read_packet", read, "launch-record") # 下で reason ごとに authorization を選ぶ。
    add.call("read_check_record check_request recheck_record", ["check"], "launch-record")
    add.call("check_records", ["launch"], "launch-record")
    add.call("check_other_records", start, "launch-record") # worker-running は launch-path。
    add.call("check_workspace herdr identifier panes foreground matching_tabs owned_tab_panes check_retry_tab launch_pane make_run check_run_location", start, "launch-path")
    add.call("resolve_branch", start, "authorization")
    add.call("update_packet", start, "launch-record")
    add.call("update_packet", ["collect"], "transcription")
    add.call("record_run", start, "launch-record")
    add.call("prepare_clone ref_exists?", ["launch"], "clone")
    add.call("hooks commit_prerequisites", start, "clone")
    add.call("preflight", start, "preflight")
    add.call("read_launch_record", ["collect"], "launch-record") # retry は not-retryable に変換。
    add.call("prepare_retry", ["retry-empty"], "launch-record")
    add.call("verify_snapshot", read, "clone")
    add.call("verify_snapshot", ["check"], "fetch")
    add.call("clone_state", ["collect"], "clone")
    add.call("clone_state check_clone_state", ["check"], "fetch")
    add.call("wait_completion", ["collect"], "executor-exit")
    add.call("result_sections gated_result", ["collect"], "transcription")
    add.call("backup_changes commits_this_run", ["collect"], "clone")
    add.call("check", ["check"], "fetch")
    add.call("check_trailers", ["check"], "trailer")
    add.call("publish_git check_merges check_style check_publish_gate check_destination check_marker", ["check"], "public-safety")
    cases = Set.new
    generic_io = false
    methods.each do |method, body|
      calls(body).each do |name, args|
        next if %w[stage stop_executor].include?(name)
        code = literal(args[name == "command" || name == "json" ? 1 : 0])
        if code.nil?
          # 引数をそのまま伝える helper と停止区分の選択だけを許す。
          allowed = { "stop" => %w[Stop.new], "command" => %w[stop], "json" => %w[stop], "stop_executor" => %w[stop] }
          raise "動的な停止点: #{method}/#{name}" unless allowed.fetch(method, []).include?(name)
          next
        end
        next if method == "leftovers" # Stop は観測不能へ変換し、CLI の停止にしない。
        status = name == "Stop.new" ? (literal(args[1]) || "BLOCKED") : "BLOCKED"
        routes = contexts[method]
        if method == "run"
          routes = code == "gh-repo" ? all.map { |c| [c, "preflight"] } : nil
          # run の直書き HEAD 検査は commit-prerequisites 段。
          routes = start.map { |c| [c, "clone"] } if code == "clone-command"
          if code == "io" # rescue StandardError は全ての実行中の区分に対応する。
            generic_io = true
            next
          end
        elsif method == "collect"
          at = { "empty-result" => "executor-result", "pane-log" => "transcription", "clone-command" => "clone",
                 "worker-question" => "executor-result", "run-record" => "transcription" }.fetch(code)
          routes = [["collect", at]]
        end
        raise "停止点の context が無い: #{method}/#{code}" unless routes
        routes.each do |cmd, at|
          at = "authorization" if method == "read_packet" && %w[packet-missing packet-state request-empty].include?(code)
          at = "launch-path" if method == "check_other_records" && code == "worker-running"
          at = "-" if status == "RUNNING"
          cases << [cmd, status, at, code]
        end
      end
    end
    # completion の error 値は stop_executor に渡される。文字列を source から読む。
    completion_codes = []
    %w[completion wait_completion].each do |method|
      walk(methods.fetch(method)) do |node|
        next unless node[0] == :assoc_new && literal(node[1]) == "error"
        walk(node[2]) { |part| value = literal(part); completion_codes << value if value }
      end
    end
    # その他の stop_executor 引数 (三項演算子を含む) も source から読む。
    stop_codes = calls(methods.fetch("collect")).select { |name, _| name == "stop_executor" }.flat_map do |_, args|
      first = args.first
      if literal(first)
        [literal(first)]
      elsif first[0] == :ifop
        first.drop(2).map { |value| literal(value) || raise("動的な停止理由") }
      elsif first[0] == :aref
        [] # completion の error 値。上で抽出する。
      else
        raise "stop_executor の引数を見直す"
      end
    end
    # stop_executor が code から選ぶ区分も case 式から抽出する。
    categories = {}
    fallback = nil
    walk(methods.fetch("stop_executor")) do |node|
      next unless node[0] == :case && node.dig(1, 0) == :var_ref && node.dig(1, 1, 1) == "code"
      arm = node[2]
      while arm && arm[0] == :when
        value = literal(arm[2].first) or raise "動的な停止区分"
        arm[1].each { |key| categories[literal(key) || raise("動的な停止条件")] = value }
        arm = arm[3]
      end
      raise "停止区分の else が無い" unless arm && arm[0] == :else
      fallback = literal(arm[1].first)
    end
    raise "停止区分の case が無い" unless fallback
    (completion_codes + stop_codes).uniq.each do |code|
      at = categories.fetch(code, fallback)
      cases << ["collect", "BLOCKED", at, code]
    end
    # io は全段で起こり得る。RUNNING は blocked_at を JSON から除く。
    cases.to_a.each do |cmd, status, at, _code|
      next if status == "RUNNING" || !generic_io
      cases << [cmd, "BLOCKED", at, "io"]
    end
    declared = source[/  REASONS = \{(.*?)^  \}.freeze/m, 1].scan(/"([a-z-]+)" =>/).flatten.to_set
    raise "理由の抽出漏れ" unless declared == cases.map(&:last).to_set
    cases.to_a.sort
  end
end
