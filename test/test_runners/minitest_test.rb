# frozen_string_literal: true

require_relative "../test_helper"

# The Minitest runner (wrapping MinitestIntegration) must keep its 0/1 contract.
# Run in a fork because the runner manipulates global Minitest state (autorun,
# runnables) that only makes sense in a throwaway child.
class TestRunnersMinitestTest < Minitest::Test
  FIX     = File.expand_path("../fixtures", __dir__)
  PASSING = File.join(FIX, "calculator_strong_test.rb")
  FAILING = File.join(FIX, "failing_minitest_test.rb")
  # Wraps each assertion in capture_subprocess_io, which reopens $stdout.
  SUBPROCESS_IO = File.join(FIX, "calculator_subprocess_io_test.rb")
  # Leaves $stdout as a StringIO, at load time and inside a test.
  STDOUT_SWAP = File.join(FIX, "calculator_stdout_swap_test.rb")

  # The child silences stdout first, as every real fork boundary does (see
  # Mutineer::ChildStdout). Silencing itself is tested at the boundaries, in
  # isolation_test.rb and coverage_map_test.rb.
  def fork_status
    pid = fork do
      Mutineer::ChildStdout.silence
      exit!(yield)
    end
    _, status = Process.waitpid2(pid)
    status.exitstatus
  end

  def test_passing_suite_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([PASSING]) }
  end

  def test_suite_that_reopens_stdout_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([SUBPROCESS_IO]) }
  end

  def test_suite_that_swaps_stdout_for_a_stringio_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([STDOUT_SWAP]) }
  end

  def test_failing_suite_returns_one
    assert_equal 1, fork_status { Mutineer::TestRunners::Minitest.run([FAILING]) }
  end
end
