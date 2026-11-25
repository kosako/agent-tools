# frozen_string_literal: true

require "json"

# 前の turn のある case (#769) の、session の記録の扱い。2 turn 目を始めるために session を保存するので、記録が home にできる。
# この run の記録だけを読み、終わったらこの run の記録だけを消す。
#
# - Claude Code: ふだんの tool home の projects/<temp project の名前>/<id>.jsonl。id は probe が起動の前に作る。自動の memory を止めた
#   2 turn (2 turn 目に Edit を 1 回) で、id の名前のものは、この file だけだった (2.1.332 の実測)。
# - Codex: 評価用の home の sessions の下の rollout。id は CLI が決め、1 turn 目の途中で止まると分からない。そこで、先頭の session_meta の
#   作業 dir が、この run の temp project のものを自分の記録とみなす (temp project は run ごとに別)。turn ごとの実際の sandbox などが、
#   その中の turn_context に残る。
#
# 消すのは link でない通常の file と、空になった dir だけ。ほかに残っていれば、消さずに数を返す。
module SkillBehaviorSession
  # 消す file の名前に使うので、UUID の形だけを受ける。
  ID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.freeze

  def self.id?(id)
    id.is_a?(String) && id.match?(ID)
  end

  def self.claude_projects(env = ENV)
    File.join(env["CLAUDE_CONFIG_DIR"] || File.join(Dir.home, ".claude"), "projects")
  end

  # Claude Code の記録を消し、残ったもの (projects の下のどの深さでも、id を名前に含むもの) の数を返す。確かめられなければ nil。
  def self.remove_claude(projects, id)
    return nil unless id?(id)
    return 0 unless File.directory?(projects)

    dirs = children(projects).select { |d| real_dir?(d) }
    dirs.each do |d|
      next unless delete_file(File.join(d, "#{id}.jsonl"))

      Dir.rmdir(d) if Dir.empty?(d)
    end
    walk(projects).count { |f| File.basename(f).include?(id) }
  rescue SystemCallError
    nil
  end

  # 評価用の home の sessions の下の、dir でないもの (path の並び)。
  def self.codex_entries(home)
    sessions = File.join(home, "sessions")
    return [] unless real_dir?(sessions)

    walk(sessions).reject { |f| real_dir?(f) }
  end

  # この run の rollout。
  def self.codex_rollouts(home, proj)
    codex_entries(home).select { |f| File.basename(f).match?(/\Arollout-.*\.jsonl\z/) && File.lstat(f).file? && own_rollout?(f, proj) }
  end

  def self.own_rollout?(file, proj)
    e = JSON.parse(File.open(file, "r:UTF-8", &:gets).to_s)
    e.is_a?(Hash) && e["type"] == "session_meta" && e["payload"].is_a?(Hash) && same_dir?(e["payload"]["cwd"], proj)
  rescue JSON::ParserError, ArgumentError
    false
  end

  # rollout の turn_context を、並んだ順に、決まった形の文字列にする。この run の rollout が 1 つでないか、名前に session の id が
  # 無ければ nil。
  def self.codex_contexts(home, id, proj)
    files = codex_rollouts(home, proj)
    return nil unless id?(id) && files.length == 1 && File.basename(files.first).include?(id)

    File.readlines(files.first, encoding: "UTF-8").map do |line|
      e = begin
        JSON.parse(line)
      rescue JSON::ParserError, ArgumentError
        next
      end
      context_text(e["payload"], proj) if e.is_a?(Hash) && e["type"] == "turn_context" && e["payload"].is_a?(Hash)
    end.compact
  rescue SystemCallError
    nil
  end

  # 承認・作業 dir・sandbox の 3 つ。作業 dir は、temp project の実体かどうかだけを写す。
  def self.context_text(payload, proj)
    sandbox = payload["sandbox_policy"]
    sandbox = sandbox.is_a?(Hash) ? JSON.generate(sandbox.sort.map { |k, v| [plain(k), plain(v)] }.to_h) : "?"
    "approval=#{plain(payload['approval_policy'])} cwd=#{same_dir?(payload['cwd'], proj) ? 'project' : 'other'} sandbox=#{sandbox}"
  end

  # 真偽値と、英小文字の短い語だけを写す (path や自由な文字列は ? にする。記録に local の path を残さない)。
  def self.plain(value)
    case value
    when true, false then value
    when String then value.match?(/\A[a-z][a-z_-]{0,40}\z/) ? value : "?"
    else "?"
    end
  end

  def self.same_dir?(path, proj)
    path.is_a?(String) && path.start_with?("/") && File.directory?(path) && File.identical?(path, proj)
  end

  # この run の rollout を消し、空になった日付の dir も消して、残ったもの (before に無かったもの) の数を返す。確かめられなければ nil。
  # before は、run の前の codex_entries。
  def self.remove_codex(home, proj, before)
    sessions = File.join(home, "sessions")
    codex_rollouts(home, proj).each do |f|
      next unless delete_file(f)

      d = File.dirname(f)
      while d.start_with?("#{sessions}/") && Dir.empty?(d)
        Dir.rmdir(d)
        d = File.dirname(d)
      end
    end
    (codex_entries(home) - before).length
  rescue SystemCallError
    nil
  end

  # link でない通常の file だけを消す。消したら true。
  def self.delete_file(path)
    return false unless File.lstat(path).file?

    File.delete(path)
    true
  rescue Errno::ENOENT
    false
  end

  def self.real_dir?(path)
    File.lstat(path).directory?
  rescue Errno::ENOENT
    false
  end

  def self.children(dir)
    Dir.children(dir).sort.map { |n| File.join(dir, n) }
  end

  # dir の下の全部 (隠し file と dir を含む。link の先は辿らない)。読めない dir があれば SystemCallError のまま上げる (0 と数えない)。
  # 見ている間に消えた dir は、空とみなす (ほかの session が同じ home を使っていることがある)。
  def self.walk(dir)
    children(dir).flat_map { |f| real_dir?(f) ? [f, *walk(f)] : [f] }
  rescue Errno::ENOENT
    []
  end
end
