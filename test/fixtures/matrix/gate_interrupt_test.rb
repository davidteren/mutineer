# frozen_string_literal: true

require "minitest/autorun"
require_relative "gate"

# Under `>=` (or with MATRIX_FIXTURE_INTERRUPT set), test_a fails and test_b raises
# Interrupt. Minitest catches it and returns, with test_c never started.
class MatrixGateInterruptTest < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_boundary
    refute MatrixGate.big?(5)
    flunk "probe" if ENV["MATRIX_FIXTURE_INTERRUPT"]
  end

  def test_b_interrupted
    raise Interrupt if ENV["MATRIX_FIXTURE_INTERRUPT"] || MatrixGate.big?(5)
  end

  def test_c_after
    assert_equal 4, MatrixGate.run(2)
  end
end
