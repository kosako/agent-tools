# frozen_string_literal: true

# OpenCode plugin probe (#295 PR 0) の子 process と serve の HTTP client。
# 子 process は argv 配列で起動し、env は allowlist だけを渡す (unsetenv_others: true)。
# timeout したら process group ごと kill する (OpenCode が起動した bash / git の孫を残さないため)。

require "json"
require "net/http"
require "open3"

module ProbeOpencode
  module Child
    READER_GRACE = 5

    Result = Struct.new(:out, :err, :exitstatus, :timed_out, :duration_ms, keyword_init: true)

    def self.kill_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def self.run(argv, env:, chdir:, timeout:)
      started = Time.now
      out = +""
      err = +""
      exitstatus = nil
      timed_out = false
      Open3.popen3(env, *argv, chdir: chdir, pgroup: true, unsetenv_others: true) do |i, o, e, wait|
        i.close
        readers = [[o, out], [e, err]].map do |io, buf|
          t = Thread.new do
            buf << io.read
          rescue IOError
            nil
          end
          t.report_on_exception = false
          t
        end
        unless wait.join(timeout)
          timed_out = true
          kill_group(wait.pid, "TERM")
          sleep 1
          kill_group(wait.pid, "KILL")
        end
        deadline = Time.now + READER_GRACE
        drained = readers.map { |t| t.join([deadline - Time.now, 0].max) }.all?
        unless drained
          kill_group(wait.pid, "KILL")
          [o, e].each { |io| io.close unless io.closed? }
          readers.each { |t| t.join(1) }
        end
        wait.join(READER_GRACE)
        exitstatus = wait.value&.exitstatus unless timed_out
        kill_group(wait.pid, "KILL")
      end
      Result.new(out: out, err: err, exitstatus: exitstatus, timed_out: timed_out,
                 duration_ms: ((Time.now - started) * 1000).round)
    end

    # `opencode serve` を起動し、stdout の listen URL を待つ。stop で process group ごと止める。
    class Serve
      LISTEN_RE = %r{https?://127\.0\.0\.1:(\d+)}.freeze

      attr_reader :port, :err

      def initialize(argv, env:, chdir:, timeout:)
        @argv = argv
        @env = env
        @chdir = chdir
        @timeout = timeout
        @err = +""
      end

      def start
        @stdin, @stdout, @stderr, @wait = Open3.popen3(@env, *@argv, chdir: @chdir, pgroup: true, unsetenv_others: true)
        @stdin.close
        found = Queue.new
        @out_thread = Thread.new do
          @stdout.each_line do |line|
            m = line.match(LISTEN_RE)
            found << m[1].to_i if m && @port.nil?
          end
        rescue IOError
          nil
        end
        @err_thread = Thread.new do
          @err << @stderr.read
        rescue IOError
          nil
        end
        [@out_thread, @err_thread].each { |t| t.report_on_exception = false }
        waiter = Thread.new { found.pop }
        @port = waiter.join(@timeout) ? waiter.value : nil
        waiter.kill
        @port
      end

      def alive?
        @wait.alive?
      end

      def exitstatus
        @wait.alive? ? nil : @wait.value&.exitstatus
      end

      def stop
        Child.kill_group(@wait.pid, "TERM")
        Child.kill_group(@wait.pid, "KILL") unless @wait.join(3)
        @wait.join(READER_GRACE)
        [@stdout, @stderr].each { |io| io.close unless io.closed? }
        [@out_thread, @err_thread].each { |t| t.join(1) }
      end
    end

    # serve の API を basic auth で呼ぶ。返り値は [status, parsed JSON または nil]。
    # 接続できないときは [nil, nil] (serve が落ちた、を観測として残すため)。
    class Client
      def initialize(port:, password:, directory:, timeout:)
        @port = port
        @auth = "Basic " + ["opencode:#{password}"].pack("m0")
        @directory = directory
        @timeout = timeout
      end

      def get(path)
        request(Net::HTTP::Get.new(uri(path)))
      end

      def post(path, body)
        req = Net::HTTP::Post.new(uri(path))
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        request(req)
      end

      def delete(path)
        request(Net::HTTP::Delete.new(uri(path)))
      end

      private

      def uri(path)
        URI("http://127.0.0.1:#{@port}#{path}?directory=#{URI.encode_www_form_component(@directory)}")
      end

      def request(req)
        req["Authorization"] = @auth
        res = Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: @timeout) { |http| http.request(req) }
        body = begin
          JSON.parse(res.body.to_s)
        rescue JSON::ParserError
          nil
        end
        [res.code.to_i, body]
      rescue IOError, SystemCallError, Net::ReadTimeout, Net::OpenTimeout
        [nil, nil]
      end
    end
  end
end
