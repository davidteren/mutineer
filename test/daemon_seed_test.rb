# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "mutineer/daemon_server"
require "mutineer/minitest_integration"

# #282: the `--daemon` mutant run uses the seed of the clean check, so each
# mutant fork runs the tests in the same order. Rails-free, so it stays in the
# default suite.
class DaemonSeedTest < Minitest::Test
  SEED_FIXTURE = File.expand_path("fixtures/stop_at_first_failure_seed_test.rb", __dir__)

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
end
