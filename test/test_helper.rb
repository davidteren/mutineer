# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "mutineer"

# A commit can start git's auto-maintenance as a detached background process.
# In a test's temp repo it can still write into .git while Dir.mktmpdir deletes
# the directory, which fails the test with ENOTEMPTY (#174). Turn it off for
# the git processes the suite starts, after any GIT_CONFIG_* entries already
# set. A push to a local bare repo drops this env on the receiving side, so a
# test that creates a bare repo sets maintenance.auto there as well.
git_config_count = ENV.fetch("GIT_CONFIG_COUNT", "0").to_i
ENV["GIT_CONFIG_KEY_#{git_config_count}"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_#{git_config_count}"] = "false"
ENV["GIT_CONFIG_COUNT"] = (git_config_count + 1).to_s

# A trace2 consumer configured globally (for example a daemon on
# trace2.eventtarget) sees every git command and can write into a temp repo
# after the test ends, with the same ENOTEMPTY result (#174). The env setting
# overrides the config, so the suite's git processes send no trace2 events.
%w[GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF].each { |key| ENV[key] = "0" }

# Waits for a test's child process with a deadline, so a hung child fails the
# test instead of hanging the whole run (#132).
module ChildWait
  # Returns the Process::Status of +pid+. Past +timeout+ seconds it kills the
  # child (and its process group, if it leads one), reaps it, and fails.
  def wait_child(pid, timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if status

      sleep 0.01
    end
    begin
      Process.kill(:KILL, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
    end
    Process.waitpid(pid)
    flunk "child process #{pid} did not exit within #{timeout}s, so it was killed"
  end

  # @return [Boolean] whether `pid` still runs. A zombie waiting for init to
  # reap it counts as gone.
  def process_alive?(pid)
    Process.kill(0, pid)
    !`ps -o stat= -p #{pid}`.strip.start_with?("Z")
  rescue Errno::ESRCH
    false
  end
end
Minitest::Test.include(ChildWait)
