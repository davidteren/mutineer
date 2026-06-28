# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# Weak suite: add/subtract use a 0 operand, so `+`<->`-` produce the same value
# and survive undetected. multiply/divide/modulo/power use inputs that DO
# distinguish the operator pair, so those 4 are killed. -> exactly 2 survivors.
class CalculatorWeakTest < Minitest::Test
  def test_add
    assert_equal 5, Calculator.new.add(5, 0)        # +->-: 5-0=5 (survives)
  end

  def test_subtract
    assert_equal 5, Calculator.new.subtract(5, 0)   # -->+: 5+0=5 (survives)
  end

  def test_multiply
    assert_equal 6, Calculator.new.multiply(2, 3)   # *->/: 2/3=0 (killed)
  end

  def test_divide
    assert_equal 3, Calculator.new.divide(6, 2)     # /->*: 6*2=12 (killed)
  end

  def test_modulo
    assert_equal 1, Calculator.new.modulo(7, 3)     # %->*: 7*3=21 (killed)
  end

  def test_power
    assert_equal 8, Calculator.new.power(2, 3)      # **->*: 2*3=6 (killed)
  end
end
