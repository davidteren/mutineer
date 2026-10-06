# frozen_string_literal: true

require "minitest/autorun"
require_relative "gate"

# Under `>=` in big?, test_a fails first, then test_b reaches exit(0). The run
# without --matrix stops at test_a and scores the mutant killed.
class MatrixGateTest < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_boundary
    refute MatrixGate.big?(5)
  end

  def test_b_run_at_limit
    assert_equal 10, MatrixGate.run(5)
  end
end
