# frozen_string_literal: true

require_relative "../test_helper"

# The RSpec runner mirrors the Minitest runner's contract: 0 = all passed,
# 1 = any failure, output silenced, and RSpec state reset between runs so
# examples never bleed across successive invocations in one process.
#
# Each case forks (mirroring real per-mutant isolation); the child reopens its
# real stdout to a pipe so we can prove the runner silenced RSpec's formatter.
class TestRunnersRSpecTest < Minitest::Test
  FIX  = File.expand_path("../fixtures/rspec", __dir__)
  PASS = File.join(FIX, "passing_spec.rb")
  FAIL = File.join(FIX, "failing_spec.rb")

  # Returns [exitstatus, captured_real_stdout]. The block runs in the child and
  # returns the integer exit code.
  def in_fork
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      $stdout.reopen(wr) # capture anything written to the real fd 1
      code = yield
      $stdout.flush
      wr.close
      exit!(code)
    end
    wr.close
    out = rd.read
    rd.close
    _, status = Process.waitpid2(pid)
    [status.exitstatus, out]
  end

  def test_passing_spec_returns_zero_and_is_silent
    code, out = in_fork { Mutineer::TestRunners::RSpec.run([PASS]) }
    assert_equal 0, code
    assert_empty out.strip, "RSpec output should be silenced, got: #{out.inspect}"
  end

  def test_failing_spec_returns_one
    code, = in_fork { Mutineer::TestRunners::RSpec.run([FAIL]) }
    assert_equal 1, code
  end

  # Run two different specs sequentially in ONE process; RSpec.reset (inside the
  # runner) must prevent the first run's example from leaking into the second.
  def test_resets_state_between_runs
    _, out = in_fork do
      r1 = Mutineer::TestRunners::RSpec.run([PASS])
      c1 = ::RSpec.world.example_count
      r2 = Mutineer::TestRunners::RSpec.run([FAIL])
      c2 = ::RSpec.world.example_count
      $stdout.puts [r1, c1, r2, c2].join(",")
      0
    end
    r1, c1, r2, c2 = out.strip.split(",").map(&:to_i)
    assert_equal 0, r1, "passing spec should return 0"
    assert_equal 1, c1, "first run should hold exactly its 1 example"
    assert_equal 1, r2, "failing spec should return 1"
    assert_equal 1, c2, "second run must NOT accumulate the first run's example"
  end
end
