# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# Strong suite: non-symmetric inputs so the `+` -> `-` mutation on #add changes
# the result and is caught (add(2, 3) becomes -1, not 5).
class CalculatorStrongTest < Minitest::Test
  def test_add
    assert_equal 5, Calculator.new.add(2, 3)
  end

  def test_subtract
    assert_equal 1, Calculator.new.subtract(3, 2)
  end

  def test_multiply
    assert_equal 6, Calculator.new.multiply(2, 3)
  end

  def test_divide
    assert_equal 2, Calculator.new.divide(6, 3)
  end
end
