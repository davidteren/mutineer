# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "mutineer/daemon_server"
require "mutineer/minitest_integration"

# #282: the `--daemon` mutant run uses the seed of the clean check, so each
# mutant fork runs the tests in the same order. #490: it also stops at the
# first failing test, as the in-process mutant run does. Rails-free, so it
# stays in the default suite.
class DaemonSeedTest < Minitest::Test
  SEED_FIXTURE = File.expand_path("fixtures/stop_at_first_failure_seed_test.rb", __dir__)
  STOP_FIXTURE = File.expand_path("fixtures/stop_at_first_failure_test.rb", __dir__)

  def test_daemon_mutant_run_pins_the_seed
    Dir.mktmpdir("mutineer-daemon-seed") do |dir|
      marker = File.join(dir, "seed")
      pid = fork do
        Process.setpgid(0, 0)
        Mutineer::ChildStdout.silence
        ENV.delete("SEED")
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        Mutineer::DaemonServer.instance_variable_set(:@framework, "minitest")
        exit!(Mutineer::DaemonServer.send(:run_tests, [SEED_FIXTURE]))
      rescue Exception # rubocop:disable Lint/RescueException
        exit!(2)
      end
      assert_equal 0, wait_child(pid).exitstatus
      assert_equal Mutineer::MinitestIntegration::PINNED_SEED.to_s, File.read(marker)
    end
  end

  def test_daemon_mutant_run_stops_at_the_first_failing_test
    Dir.mktmpdir("mutineer-daemon-stop") do |dir|
      # The second test writes the marker. A passing first test lets it run,
      # so a missing marker after a failure means the run stopped there.
      ran = File.join(dir, "after_pass")
      assert_equal 0, run_stop_fixture("pass", ran)
      assert_path_exists ran

      stopped = File.join(dir, "after_fail")
      assert_equal 1, run_stop_fixture("fail", stopped)
      refute_path_exists stopped, "the daemon mutant run went on after the first failing test"
    end
  end

  private

  def run_stop_fixture(first, marker)
    pid = fork do
      Process.setpgid(0, 0)
      Mutineer::ChildStdout.silence
      ENV["MUTINEER_FIXTURE_FIRST"] = first
      ENV["MUTINEER_FIXTURE_MARKER"] = marker
      Mutineer::DaemonServer.instance_variable_set(:@framework, "minitest")
      exit!(Mutineer::DaemonServer.send(:run_tests, [STOP_FIXTURE]))
    rescue Exception # rubocop:disable Lint/RescueException
      exit!(2)
    end
    wait_child(pid).exitstatus
  end
end
