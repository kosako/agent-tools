# frozen_string_literal: true

# 分類器の不変条件の試行 (#754) の判定。Spec: docs/classifier-invariants.md の「判定」。
#
# 走らせる前と後に一時 dir の全体の snapshot を取り、差分と canary の印から、不変条件の違反を決める。
#   I1: read と区分した command は、fixture の tree (fx) を変えない。
#   I2: read と区分した command は、canary を走らせない。
# 違反は終わり方に依らず判定する (期限で止めた回も、差分と印を見る)。
#
# 責務の境界:
#   - ここは見た事実から決めるだけ。走らせるのは isolation.rb で、分類は呼ぶ側が別の process で行う。
#   - 違反の候補は、新しい一時 dir で走らせ直して同じ種類が出たときだけ、反例に数える。
#   - 人が見て決めるもの (fx の外の変化、拒まれた起動、予約語の名前の canary など) は、違反に数えずに分けて返す。
#   - stderr の照合 (終わり方の区分、拒まれた起動の名前) は近似。集計と、人に出す枠にだけ使う。
#   - 見ないもの: atime、ctime、xattr、ACL、flag、所有者。一時 dir の外。group を抜けた子が後から書く変化。

require "digest"
require_relative "isolation"

module ProbeClassifier
  module Judge
    # --- snapshot ---------------------------------------------------------------------------
    # type は file、dir、symlink、other。mtime は [秒, ナノ秒]。sha256 は regular file の中身、target は symlink の先。
    Entry = Struct.new(:type, :mode, :size, :mtime, :ino, :sha256, :target, keyword_init: true)
    # 読めなかった中身の印。読めない entry を黙って飛ばすと、そこへの書き込みが差分から消える。
    UNREADABLE = "unreadable"

    # base の下の全部の entry を、base からの相対 path で返す。symlink はたどらない。
    # 中身を読むのは regular file だけ (FIFO を開くと、書く側が来るまで止まる)。
    def self.snapshot(base)
      entries = {}
      walk(base, "", entries)
      entries
    end

    def self.walk(dir, prefix, entries)
      Dir.children(dir).sort.each do |name|
        rel = prefix.empty? ? name : "#{prefix}/#{name}"
        path = File.join(dir, name)
        entry = stat_entry(path)
        entries[rel] = entry
        next unless entry.type == "dir"

        begin
          walk(path, rel, entries)
        rescue SystemCallError
          entry.sha256 = UNREADABLE
        end
      end
    end

    def self.stat_entry(path)
      stat = File.lstat(path)
      entry = Entry.new(type: entry_type(stat), mode: stat.mode & 0o7777, size: stat.size,
                        mtime: [stat.mtime.to_i, stat.mtime.nsec], ino: stat.ino)
      entry.sha256 = file_digest(path) if entry.type == "file"
      entry.target = File.readlink(path) if entry.type == "symlink"
      entry
    rescue SystemCallError
      # lstat と読み取りの間に消えた、など。在ったことだけを残す。
      Entry.new(type: "other", sha256: UNREADABLE)
    end

    def self.entry_type(stat)
      return "symlink" if stat.symlink?
      return "dir" if stat.directory?

      stat.file? ? "file" : "other"
    end

    def self.file_digest(path)
      Digest::SHA256.file(path).hexdigest
    rescue SystemCallError
      UNREADABLE
    end

    # --- 差分 -------------------------------------------------------------------------------
    # 差分の種類。dir-mtime は「dir の mtime だけが違う」で、ほかの種類とは併記しない。
    #   created / deleted: entry が増えた、減った。
    #   type:    同じ名前で、種類が入れ替わった (file が dir や symlink になった、など)。
    #   content: 中身 (file) か、先 (symlink) が違う。
    #   mode:    mode が違う。
    #   rewrite: 中身は同じで、mtime か inode が違う (同じ中身での書き直し、入れ替え)。
    KINDS = %w[created deleted type content mode rewrite dir-mtime].freeze
    # 6 つの区画の外 (一時 dir の直下) に出来た entry の区画の名前。
    BASE_ZONE = "base"

    # path は一時 dir からの相対 (fx/-c)。replaced は、その名前の entry が別の実体になったか
    # (親の dir の mtime が変わる理由になる)。
    Change = Struct.new(:path, :zone, :kinds, :replaced, keyword_init: true)

    def self.zone_of(rel)
      head = rel.split("/", 2).first
      Isolation::ZONES.include?(head) ? head : BASE_ZONE
    end

    def self.diff(before, after)
      changes = []
      (before.keys | after.keys).sort.each do |rel|
        a = before[rel]
        b = after[rel]
        kinds, replaced = entry_kinds(a, b)
        next if kinds.empty?

        changes << Change.new(path: rel, zone: zone_of(rel), kinds: kinds, replaced: replaced)
      end
      changes
    end

    # [種類の並び, 別の実体になったか] を返す。
    def self.entry_kinds(a, b)
      return [["created"], true] if a.nil?
      return [["deleted"], true] if b.nil?
      return [["type"], true] if a.type != b.type

      replaced = a.ino != b.ino
      kinds = []
      if a.type == "dir"
        kinds << "mode" if a.mode != b.mode
        kinds << "rewrite" if replaced
        kinds << "content" if a.sha256 != b.sha256
        kinds << "dir-mtime" if kinds.empty? && a.mtime != b.mtime
      else
        same = a.sha256 == b.sha256 && a.size == b.size && a.target == b.target
        kinds << "content" unless same
        kinds << "mode" if a.mode != b.mode
        kinds << "rewrite" if same && (replaced || a.mtime != b.mtime)
      end
      [kinds, replaced]
    end

    def self.sort_kinds(kinds)
      kinds.uniq.sort_by { |k| KINDS.index(k) || KINDS.length }
    end

    # dir の mtime だけの変化のうち、直下の entry の作成、削除、入れ替えで説明できないもの。
    # 説明できないものは、作って消した跡かもしれないので、人に出す。
    def self.unexplained_dir_mtimes(changes)
      touched = changes.select(&:replaced).map { |c| File.dirname(c.path) }
      changes.select { |c| c.kinds == ["dir-mtime"] && !touched.include?(c.path) }
    end

    # --- 終わり方 ---------------------------------------------------------------------------
    # 集計のための区分 (近似)。違反の判定には使わない。unknown は、終わりを確かめられなかった回と、
    # signal で終わった回。
    ENDINGS = %w[ok nonzero usage 127 126 nomatch syntax timeout unknown].freeze
    # ok と nonzero だけを「効いた read」に数える。
    EFFECTIVE_ENDINGS = %w[ok nonzero].freeze
    NOMATCH = /no matches found/.freeze
    SYNTAX = /syntax error|parse error|unexpected EOF|unmatched ['"`]/i.freeze
    USAGE = /\busage:|illegal option|invalid option|unknown option|unrecognized option|bad option|option requires an argument/i.freeze

    def self.ending(run)
      return "timeout" if run.timed_out
      return "unknown" if run.exit_code.nil?
      return "ok" if run.exit_code.zero?
      return run.exit_code.to_s if [126, 127].include?(run.exit_code)

      err = run.err.to_s
      return "nomatch" if err.match?(NOMATCH)
      return "syntax" if err.match?(SYNTAX)
      return "usage" if err.match?(USAGE)

      "nonzero"
    end

    # --- 拒まれた起動 -------------------------------------------------------------------------
    # sandbox が拒んだ起動と、見つからなかった名前を、stderr の行から拾う (近似)。
    #   zsh:         zsh:1: operation not permitted: NAME     /  zsh:1: command not found: NAME
    #   sh, bash:    /bin/sh: NAME: Operation not permitted   /  /bin/sh: NAME: command not found
    #   xargs など:  xargs: NAME: Operation not permitted     /  xargs: NAME: No such file or directory
    #   script:      NAME: /bin/sh: bad interpreter: Operation not permitted
    #   exec:        /bin/sh: line 0: exec: NAME: not found
    DENIED = Isolation::DENIED_EXEC
    # program を起動する道具。「No such file or directory」が、起動する名前を指しうるもの
    # (find は、探す先が無いときも同じ字面になる。見分けずに人に出す)。
    LAUNCHERS = %w[env xargs find nohup nice time].freeze
    LAUNCHER_MISSING = /\A(?:#{LAUNCHERS.join('|')}): (.+): No such file or directory\z/.freeze
    # 名前として出す字。stderr の中身を、そのまま結果に写さないため。
    NAME_CHARS = %r{\A[A-Za-z0-9_.+<>/=:@%,!{}\[\]^-]{1,120}\z}.freeze
    UNNAMED = "?"
    MAX_NAMES = 20

    def self.clean_name(text)
      name = text.to_s.strip
      name.match?(NAME_CHARS) ? name : UNNAMED
    end

    def self.denied_name(line)
      if (m = line.match(/\A(.*?): \S+: bad interpreter/i))
        clean_name(m[1].split(": ").last)
      elsif (m = line.match(/operation not permitted: (.+)\z/i))
        clean_name(m[1])
      elsif (m = line.match(/\A(.*): operation not permitted\z/i))
        clean_name(m[1].split(": ").last)
      else
        UNNAMED
      end
    end

    def self.not_found_name(line)
      if (m = line.match(/command not found: (.+)\z/))
        clean_name(m[1])
      elsif (m = line.match(/\A(.*): command not found\z/))
        clean_name(m[1].split(": ").last)
      elsif (m = line.match(/: exec: (.+): not found\z/))
        # type や command -v の「not found」は起動ではないので、exec の字面だけを拾う。
        clean_name(m[1])
      elsif (m = line.match(LAUNCHER_MISSING))
        clean_name(m[1])
      end
    end

    # 拒まれた起動の事実。denied は sandbox が拒んだ名前、missing は見つからなかった名前のうち表の道具でないもの。
    # by_exit は、stderr に行が無いのに終了 code が 126 か 127 の回 (2>/dev/null を付けた起動は、字面が残らない)。
    def self.denied_exec(run, tool_names)
      denied = []
      missing = []
      listed_missing = false
      run.err.to_s.each_line do |raw|
        line = raw.chomp.strip
        if line.match?(DENIED)
          denied << denied_name(line)
        elsif (name = not_found_name(line))
          tool_names.include?(File.basename(name)) ? listed_missing = true : missing << name
        end
      end
      by_exit = [126, 127].include?(run.exit_code) && denied.empty? && missing.empty? && !listed_missing
      { denied: denied.uniq.first(MAX_NAMES), missing: missing.uniq.first(MAX_NAMES), by_exit: by_exit }
    end

    # --- 判定 -------------------------------------------------------------------------------
    # 1 回の起動の判定。violations と human は、結果の file に書く形の Hash (key は文字列) の並び。
    # unmeasured は、測れなかった理由 (測れたら nil)。未測定の回は、違反が無くても「違反なし」に数えない。
    Verdict = Struct.new(:variant, :ending, :exit_code, :timed_out, :unmeasured, :violations, :human, :changes,
                         keyword_init: true) do
      def clean?
        violations.empty? && human.empty? && unmeasured.nil?
      end
    end

    def self.table_tool_names
      Isolation::REQUIRED_TOOLS.keys + Isolation::OPTIONAL_TOOLS.keys
    end

    def self.unmeasured_reason(run)
      return "sandbox-error" if run.sandbox_error
      return "group-not-empty" unless run.group_empty

      nil
    end

    # 印の dir の変化を、canary の印 (印の形の名前で、新しく出来た regular file) と、それ以外に分ける。
    def self.split_marks(changes, after)
      hits = []
      rest = []
      changes.each do |c|
        m = Isolation::MARK_NAME.match(File.basename(c.path))
        canary = m && File.dirname(c.path) == "marks" && Isolation.canary(m[:id])
        canary && c.kinds == ["created"] && after[c.path].type == "file" ? hits << canary : rest << c
      end
      [hits.uniq, rest]
    end

    def self.canary_path(canary)
      "#{canary.zone}/#{canary.rel}"
    end

    def self.judge(before:, after:, run:, tool_names: table_tool_names)
      changes = diff(before, after)
      loose = unexplained_dir_mtimes(changes)
      solid = changes.reject { |c| c.kinds == ["dir-mtime"] }
      by_zone = solid.group_by(&:zone)
      hits, mark_rest = split_marks(by_zone.fetch("marks", []), after)
      by_zone["marks"] = mark_rest

      violations = []
      human = []
      fx = by_zone.fetch("fx", [])
      unless fx.empty?
        violations << { "invariant" => "I1", "kinds" => sort_kinds(fx.flat_map(&:kinds)), "paths" => fx.map(&:path) }
      end
      counted, reserved = hits.partition { |c| c.kind != :reserved }
      unless counted.empty?
        violations << { "invariant" => "I2", "kinds" => counted.map { |c| c.kind.to_s }.uniq.sort,
                        "paths" => counted.map { |c| canary_path(c) }.sort, "canaries" => counted.map(&:id).sort }
      end
      unless reserved.empty?
        human << { "reason" => "reserved-canary", "paths" => reserved.map { |c| canary_path(c) }.sort,
                   "canaries" => reserved.map(&:id).sort }
      end
      (Isolation::ZONES + [BASE_ZONE] - ["fx"]).each do |zone|
        list = by_zone.fetch(zone, [])
        next if list.empty?

        human << { "reason" => "zone", "zone" => zone, "kinds" => sort_kinds(list.flat_map(&:kinds)),
                   "paths" => list.map(&:path) }
      end
      human << { "reason" => "dir-mtime", "paths" => loose.map(&:path) } unless loose.empty?
      human.concat(denied_items(run, tool_names))

      Verdict.new(variant: run.variant, ending: ending(run), exit_code: run.exit_code, timed_out: run.timed_out,
                  unmeasured: unmeasured_reason(run), violations: violations, human: human, changes: changes)
    end

    def self.denied_items(run, tool_names)
      # sandbox-exec 自体が失敗した回は、command が走っていない。その stderr を、中の起動の拒否と読まない。
      return [] if run.sandbox_error

      facts = denied_exec(run, tool_names)
      names = (facts[:denied] + facts[:missing]).uniq
      return [] if names.empty? && !facts[:by_exit]

      [{ "reason" => "denied-exec", "names" => names, "exit_code" => run.exit_code }]
    end

    # --- 走らせて判定する -----------------------------------------------------------------------
    # 1 件の command を新しい一時 dir で走らせ、前後の snapshot から判定する。一時 dir は、判定の後に消す。
    # guarded が false のときは guard を通さない (終わらない形など、検査のための入口)。
    def self.observe(session, command, variant: Isolation::DEFAULT_VARIANT, timeout: Isolation::DEFAULT_TIMEOUT,
                     guarded: true)
      before = nil
      layout = nil
      take = lambda do |l|
        layout = l
        before = snapshot(l.base)
      end
      run = if guarded
              session.run_command(command, variant: variant, timeout: timeout, &take)
            else
              take.call(session.prepare)
              session.launch(layout, command, variant: variant, timeout: timeout)
            end
      judge(before: before, after: snapshot(layout.base), run: run)
    ensure
      session.cleanup(layout) if layout
    end

    # --- 確かめ直し ---------------------------------------------------------------------------
    # 違反の「種類」。変わった path は比べない (pid を含む名前など、回ごとに変わりうる)。
    def self.signature(violation)
      [violation["invariant"], violation["kinds"]]
    end

    RERUNS = 2
    # confirmed は、どの回にも同じ種類で出た違反 (最初の回の形で持つ)。flaky は、出た回と出ない回があった違反。
    Settled = Struct.new(:confirmed, :flaky, :verdicts, keyword_init: true)

    # first の違反の候補を、block (新しい一時 dir で単独に 1 回走らせて Verdict を返す) で確かめ直す。
    # 候補が無ければ、走らせ直さない。
    def self.settle(first, reruns: RERUNS)
      return Settled.new(confirmed: [], flaky: [], verdicts: [first]) if first.violations.empty?

      verdicts = [first] + Array.new(reruns) { yield }
      seen = verdicts.map { |v| v.violations.map { |x| signature(x) } }
      every = verdicts.flat_map(&:violations).uniq { |x| signature(x) }
      confirmed, flaky = every.partition { |x| seen.all? { |s| s.include?(signature(x)) } }
      Settled.new(confirmed: confirmed, flaky: flaky, verdicts: verdicts)
    end

    # violations は反例 (exit 1 にする)。human は人に出すもの。unmeasured は未測定の回が在ったか。
    # runs は、起動ごとの終わり方 (結果の file に書く形)。
    Outcome = Struct.new(:violations, :human, :unmeasured, :runs, keyword_init: true)

    def self.run_row(verdict)
      { "variant" => verdict.variant, "ending" => verdict.ending, "exit_code" => verdict.exit_code,
        "timed_out" => verdict.timed_out, "unmeasured" => verdict.unmeasured }
    end

    def self.flaky_item(violation)
      { "reason" => "flaky" }.merge(violation)
    end

    # 1 件の command の結論。observe は、変種の名前を受けて 1 回走らせ、Verdict を返す。
    #   1. 最初の回の違反の候補を、同じ変種でさらに 2 回走らせて確かめる。
    #   2. 既定でない変種の反例は、同じ shell の既定の変種でも同じ手順で確かめる。そこで出なければ人に出す。
    def self.examine(variant, observe)
      first = observe.call(variant.name)
      settled = settle(first) { observe.call(variant.name) }
      verdicts = settled.verdicts.dup
      human = first.human + settled.flaky.map { |x| flaky_item(x) }
      violations = settled.confirmed
      unless variant.default || violations.empty?
        base = settle(observe.call(variant.base)) { observe.call(variant.base) }
        verdicts.concat(base.verdicts)
        kept, only_here = violations.partition { |x| base.confirmed.any? { |b| signature(b) == signature(x) } }
        violations = kept
        human.concat(only_here.map { |x| { "reason" => "non-default-variant" }.merge(x) })
      end
      unmeasured = verdicts.map(&:unmeasured).compact.uniq
      human << { "reason" => "unmeasured", "why" => unmeasured } unless unmeasured.empty?
      Outcome.new(violations: violations, human: human, unmeasured: !unmeasured.empty?, runs: verdicts.map { |v| run_row(v) })
    end

    # 反例があれば 1、人に出すものだけなら 3、どちらも無ければ 0。
    def self.exit_code(outcome)
      return 1 unless outcome.violations.empty?

      outcome.human.empty? ? 0 : 3
    end
  end
end
