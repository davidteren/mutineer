# frozen_string_literal: true

require "test_helper"

# #132: test helpers that fork wait with a deadline instead of forever.
class ChildWaitTest < Minitest::Test
  def test_returns_the_status_of_a_child_that_exits
    assert_equal 3, wait_child(fork { exit!(3) }).exitstatus
  end

  def test_kills_and_fails_on_a_child_that_outlives_the_deadline
    pid = fork { sleep 30; exit! }
    error = assert_raises(Minitest::Assertion) { wait_child(pid, timeout: 0.2) }
    assert_match(/did not exit within 0.2s/, error.message)
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_kills_the_process_group_of_a_child_that_leads_one
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      Process.setpgid(0, 0)
      wr.puts(fork { sleep 30; exit! })
      sleep 30
      exit!
    end
    wr.close
    assert rd.wait_readable(5), "the child did not report its grandchild"
    grandchild = rd.gets.to_i
    assert_predicate grandchild, :positive?, "the child did not report its grandchild"
    begin
      assert_raises(Minitest::Assertion) { wait_child(pid, timeout: 0.2) }
    ensure
      pid = nil # wait_child reaped it, so its number may now belong to another process
    end
    gone = 50.times.any? do
      sleep 0.05
      !process_alive?(grandchild)
    end
    assert gone, "the group kill left the grandchild running"
  ensure
    # A failed step above must not leave a sleeper running. Pid 0 would kill
    # this run's own process group, so only positive pids are signalled.
    unless gone
      Process.kill(:KILL, -pid) rescue nil if pid # rubocop:disable Style/RescueModifier
      Process.kill(:KILL, pid) rescue nil if pid # rubocop:disable Style/RescueModifier
      Process.kill(:KILL, grandchild) rescue nil if grandchild&.positive? # rubocop:disable Style/RescueModifier
      Process.waitpid(pid) rescue nil if pid # rubocop:disable Style/RescueModifier
    end
  end
end
