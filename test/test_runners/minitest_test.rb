# frozen_string_literal: true

require_relative "../test_helper"

# The Minitest runner (wrapping MinitestIntegration) must keep its 0/1 contract.
# Run in a fork because the runner manipulates global Minitest state (autorun,
# runnables) that only makes sense in a throwaway child.
class TestRunnersMinitestTest < Minitest::Test
  FIX     = File.expand_path("../fixtures", __dir__)
  PASSING = File.join(FIX, "calculator_strong_test.rb")
  FAILING = File.join(FIX, "failing_minitest_test.rb")

  def fork_status
    pid = fork { exit!(yield) }
    _, status = Process.waitpid2(pid)
    status.exitstatus
  end

  def test_passing_suite_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([PASSING]) }
  end

  def test_failing_suite_returns_one
    assert_equal 1, fork_status { Mutineer::TestRunners::Minitest.run([FAILING]) }
  end
end
