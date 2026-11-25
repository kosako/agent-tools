# frozen_string_literal: true

require "json"

# 前の turn のある case (#769) の、session の記録の扱い。2 turn 目を始めるために session を保存するので、記録が home にできる。
# 自分の session の id の記録だけを読み、終わったら自分の id の記録だけを消す。
#
# - Claude Code: ふだんの tool home の projects/<temp project の名前>/<id>.jsonl。id は probe が作る。自動の memory を止めた 2 turn
#   (2 turn 目に Edit を 1 回) で、id の名前のものは、この file だけだった (2.1.332 の実測)。
# - Codex: 評価用の home の sessions の下の、名前に id を含む rollout。turn ごとの実際の sandbox などが、その中の turn_context に残る。
#
# 消すのは link でない通常の file と、空になった dir だけ。id の名前のものがほかに残っていれば、消さずに数を返す。
module SkillBehaviorSession
  # 消す file の名前に使うので、UUID の形だけを受ける。
  ID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.freeze

  def self.id?(id)
    id.is_a?(String) && id.match?(ID)
  end

  def self.claude_projects(env = ENV)
    File.join(env["CLAUDE_CONFIG_DIR"] || File.join(Dir.home, ".claude"), "projects")
  end

  # Claude Code の記録を消し、残った (id を名前に含む) ものの数を返す。確かめられなければ nil。
  def self.remove_claude(projects, id)
    return nil unless id?(id)
    return 0 unless File.directory?(projects)

    dirs = children(projects).select { |d| real_dir?(d) }
    dirs.each do |d|
      next unless delete_file(File.join(d, "#{id}.jsonl"))

      Dir.rmdir(d) if Dir.empty?(d)
    end
    dirs.select { |d| real_dir?(d) }.sum { |d| Dir.children(d).count { |n| n.include?(id) } }
  rescue SystemCallError
    nil
  end

  # Codex の rollout (名前に id を含む .jsonl)。
  def self.codex_rollouts(home, id)
    sessions = File.join(home, "sessions")
    return [] unless id?(id) && real_dir?(sessions)

    Dir.glob("**/*#{id}*", File::FNM_DOTMATCH, base: sessions).sort.map { |f| File.join(sessions, f) }
  end

  # rollout の turn_context を、並んだ順に、決まった形の文字列にする。rollout が 1 つの通常の file でなければ nil。
  def self.codex_contexts(home, id, proj)
    files = codex_rollouts(home, id)
    return nil unless files.length == 1 && File.lstat(files.first).file?

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

  # Codex の rollout を消し、空になった日付の dir も消して、残ったものの数を返す。確かめられなければ nil。
  def self.remove_codex(home, id)
    return nil unless id?(id)

    sessions = File.join(home, "sessions")
    codex_rollouts(home, id).each do |f|
      next unless f.end_with?(".jsonl") && delete_file(f)

      d = File.dirname(f)
      while d.start_with?("#{sessions}/") && Dir.empty?(d)
        Dir.rmdir(d)
        d = File.dirname(d)
      end
    end
    codex_rollouts(home, id).length
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
end
