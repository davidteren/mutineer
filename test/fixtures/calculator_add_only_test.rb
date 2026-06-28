# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# Partial-coverage fixture: exercises only #add, so #modulo's line stays
# uncovered. Used by coverage_map_test for the no-coverage path (the M4 strong
# suite now covers all 6 methods, so it can no longer serve that role).
class CalculatorAddOnlyTest < Minitest::Test
  def test_add
    assert_equal 5, Calculator.new.add(2, 3)
  end
end
