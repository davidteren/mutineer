# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "calculator"

# The weak suite, with `$stdout` left as a StringIO: once at load time and once
# inside a test that never restores it. Same verdicts as calculator_weak_test.rb
# -> exactly 2 survivors.
$stdout = StringIO.new

class CalculatorStdoutSwapTest < Minitest::Test
  def test_add
    $stdout = StringIO.new
    assert_equal 5, Calculator.new.add(5, 0)        # survives
  end

  def test_subtract
    assert_equal 5, Calculator.new.subtract(5, 0)   # survives
  end

  def test_multiply
    assert_equal 6, Calculator.new.multiply(2, 3)   # killed
  end

  def test_divide
    assert_equal 3, Calculator.new.divide(6, 2)     # killed
  end

  def test_modulo
    assert_equal 1, Calculator.new.modulo(7, 3)     # killed
  end

  def test_power
    assert_equal 8, Calculator.new.power(2, 3)      # killed
  end
end
