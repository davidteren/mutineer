# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# Strong suite: every input is chosen so the arithmetic mutation changes the
# result and is caught. Kills all 6 arithmetic mutants -> score 100%.
class CalculatorStrongTest < Minitest::Test
  def test_add
    assert_equal 5, Calculator.new.add(2, 3)        # +->-: 2-3=-1
  end

  def test_subtract
    assert_equal 2, Calculator.new.subtract(5, 3)   # -->+: 5+3=8
  end

  def test_multiply
    assert_equal 12, Calculator.new.multiply(3, 4)  # *->/: 3/4=0
  end

  def test_divide
    assert_equal 4, Calculator.new.divide(12, 3)    # /->*: 12*3=36
  end

  def test_modulo
    assert_equal 1, Calculator.new.modulo(7, 3)     # %->*: 7*3=21
  end

  def test_power
    assert_equal 8, Calculator.new.power(2, 3)      # **->*: 2*3=6
  end
end
