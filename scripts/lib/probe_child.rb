# frozen_string_literal: true

# probe (skill routing の probe と OpenCode plugin の probe) が CLI を起動するときの、子 process の扱いの共通部分 (#568)。
# argv を配列のまま専用の process group (pgroup: true) で起動し、期限を過ぎたら group 全体へ TERM → KILL を送る。
# CLI の子孫 (codex の command 実行、claude の hook、OpenCode の bash / git など) は stdout / stderr の pipe を継承する
# ので、CLI の PID だけを止めても孫が pipe を握ったままだと read が返らない。reader の join は猶予つきにし、閉じない
# pipe は runner 側で閉じる。
# env・stdin の中身・出力の解析・観測の成否の判定は各 probe に残す (この module は終了の状態を返すだけ)。

require "open3"

module ProbeChild
  # 正常終了の後も reader が返らない (pipe を孫 process が握っている) 場合に、runner 自体がハングしないための床。
  READER_GRACE = 5
  # 期限を過ぎたときに TERM から KILL までに待つ秒数。
  TERM_GRACE = 1

  # 上限つきで読むときの 1 回の量。
  READ_CHUNK = 16_384

  # completed: 期限の中で子が終わった。drained: stdout / stderr を EOF まで読み切った。
  # status: 子の終了の状態 (Process::Status)。終わったと確かめられなければ nil。
  # truncated: max_bytes を越えたので、途中までしか残していない (上限を渡さなければ false)。
  Result = Struct.new(:out, :err, :status, :completed, :drained, :truncated, keyword_init: true)

  # pgroup: true なので pgid == 子の pid。負の pid で group 全体に送る。止めるものが無ければ何もしない
  # (group が空なら ESRCH、macOS は中が zombie だけの group に EPERM を返す)。
  def self.kill_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  # runner 側で pipe を閉じると、read 中の thread は IOError で抜ける。それは意図した打ち切りなので握り (join で
  # 再送出させない)、読めた分だけを残す。
  # max_bytes があれば、越えたところで読むのをやめて口を閉じる (書き続ける子は EPIPE を受ける)。
  def self.reader(io, buf, max_bytes = nil)
    buf.force_encoding(Encoding::BINARY) if max_bytes
    t = Thread.new do
      if max_bytes
        buf << io.readpartial(READ_CHUNK) while buf.bytesize <= max_bytes
        io.close
      else
        buf << io.read
      end
    rescue IOError
      nil
    end
    t.report_on_exception = false
    t
  end

  # max_bytes は、stdout と stderr のそれぞれで残す量の上限 (byte)。渡さなければ、全部を残す。
  def self.run(argv, env:, chdir:, timeout:, stdin: nil, unsetenv_others: false, max_bytes: nil)
    out = +""
    err = +""
    status = nil
    completed = false
    drained = false
    spawn_opts = { chdir: chdir, pgroup: true }
    spawn_opts[:unsetenv_others] = true if unsetenv_others
    Open3.popen3(env, *argv, **spawn_opts) do |i, o, e, wait|
      readers = []
      begin
        # 先に reader を起こしてから stdin を書く (子が stdin を読む前に出力の pipe を埋めても詰まらない)。
        readers = [reader(o, out, max_bytes), reader(e, err, max_bytes)]
        i.write(stdin) if stdin
        i.close
        completed = !wait.join(timeout).nil?
        unless completed
          kill_group(wait.pid, "TERM")
          sleep TERM_GRACE
          kill_group(wait.pid, "KILL")
        end
        # 正常終了でも、CLI が残した孫 process が pipe を継承していると read が返らない。共通の deadline で
        # 猶予つきに待ち、閉じなければ group を KILL して、読めた分を回収する。
        deadline = Time.now + READER_GRACE
        drained = readers.map { |t| t.join([deadline - Time.now, 0].max) }.all?
        unless drained
          kill_group(wait.pid, "KILL")
          readers.each { |t| t.join(1) }
        end
        wait.join(READER_GRACE)
        status = wait.value unless wait.alive?
      ensure
        # 正常終了・timeout・中断 (Ctrl-C)・例外のどれでも、子の process group を残さない。pgroup: true なので
        # 端末の SIGINT は子に届かず、ここで止めないと Open3 の終了待ちで runner も止まる。CLI が detach したまま
        # 残した process もここで回収する (残っていなければ no-op)。
        kill_group(wait.pid, "KILL")
        [i, o, e].each { |io| io.close unless io.closed? }
        readers.each { |t| t.join(1) }
      end
    end
    truncated = false
    if max_bytes
      truncated = [out, err].any? { |b| b.bytesize > max_bytes }
      # 越えたところで口を閉じているので、EOF まで読み切っていない。
      drained = false if truncated
      out, err = [out, err].map { |b| b.byteslice(0, max_bytes).force_encoding(Encoding.default_external) }
    end
    Result.new(out: out, err: err, status: status, completed: completed, drained: drained, truncated: truncated)
  end
end
