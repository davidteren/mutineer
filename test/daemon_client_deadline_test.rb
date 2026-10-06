# frozen_string_literal: true

require "open3"
require "rbconfig"

require_relative "test_helper"
require "mutineer/daemon_client"
require "mutineer/daemon_server"

# #101: a daemon that stops answering must not hang the run. These tests wire
# a client to a stand-in daemon (a plain Ruby child that reads nothing and
# replies nothing), so they need no app boot.
class DaemonClientDeadlineTest < Minitest::Test
  # A child that never replies and ignores stdin EOF, like a wedged daemon.
  WEDGED = "trap('TERM') {}; sleep"

  def setup
    @client = Mutineer::DaemonClient.allocate
    stdin, stdout, stderr, wait_thr = Open3.popen3(RbConfig.ruby, "-e", WEDGED)
    @client.instance_variable_set(:@stdin, stdin)
    @client.instance_variable_set(:@stdout, stdout)
    @client.instance_variable_set(:@stderr, stderr)
    @client.instance_variable_set(:@wait_thr, wait_thr)
    @client.instance_variable_set(:@errio, StringIO.new)
    @pid = wait_thr.pid
  end

  def teardown
    @client.send(:close_io)
  end

  def test_read_line_gives_up_after_its_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nil @client.send(:read_line, 0.2)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert @client.instance_variable_get(:@timed_out)
  end

  # The request waits for the mutant's own timeout plus REPLY_GRACE, then
  # scores the mutant error and respawns, as for a crash.
  def test_request_scores_error_and_respawns_when_the_daemon_never_replies
    waited = nil
    restarted = false
    @client.define_singleton_method(:read_line) { |timeout = nil| (waited = timeout) && super(0.2) }
    @client.define_singleton_method(:restart!) { restarted = true }
    verdict = @client.request(id: 1, payload: { "code" => "" }, tests: [], timeout: 7)
    assert_equal "error", verdict
    assert_equal 7 + Mutineer::DaemonClient::REPLY_GRACE, waited
    assert restarted
  end

  # A mutant child runs in its own process group, so killing the daemon does
  # not reach it; its watchdog must end it once the daemon is gone.
  def test_mutant_child_dies_with_its_daemon
    rd, wr = IO.pipe
    daemon = fork do
      rd.close
      child = fork do
        Process.setpgid(0, 0)
        Mutineer::DaemonServer.exit_with_parent
        sleep 60
      end
      wr.puts(child)
      exit!(0)
    end
    wr.close
    child = rd.gets.to_i
    Process.wait(daemon)
    gone = 50.times.any? do
      sleep 0.1
      !process_alive?(child)
    end
    assert gone, "mutant child #{child} outlived its daemon"
  ensure
    Process.kill(:KILL, child) rescue nil if child && child.positive? # rubocop:disable Style/RescueModifier
  end

  def test_close_io_kills_a_daemon_that_ignores_eof
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @client.send(:close_io)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_raises(Errno::ESRCH) { Process.kill(0, @pid) }
  end

  private

  # @return [Boolean] whether `pid` still exists.
  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
