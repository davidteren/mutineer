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
    rd.close
    assert_raises(Minitest::Assertion) { wait_child(pid, timeout: 0.2) }
    gone = 50.times.any? do
      sleep 0.05
      gone?(grandchild)
    end
    assert gone, "the group kill left the grandchild running"
  ensure
    # A failed assertion above must not leave either sleeper running.
    [pid, grandchild].compact.each { |stray| Process.kill(:KILL, stray) rescue nil } # rubocop:disable Style/RescueModifier
    Process.waitpid(pid) rescue nil if pid # rubocop:disable Style/RescueModifier
  end

  private

  def gone?(pid)
    Process.kill(0, pid)
    false
  rescue Errno::ESRCH
    true
  end
end
