# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# The weak suite, with every assertion inside `capture_subprocess_io`. That
# helper calls `$stdout.reopen(tempfile)`, so it needs `$stdout` to be a real
# IO. Same verdicts as calculator_weak_test.rb -> exactly 2 survivors.
class CalculatorSubprocessIoTest < Minitest::Test
  def test_add
    capture_subprocess_io { assert_equal 5, Calculator.new.add(5, 0) }        # survives
  end

  def test_subtract
    capture_subprocess_io { assert_equal 5, Calculator.new.subtract(5, 0) }   # survives
  end

  def test_multiply
    capture_subprocess_io { assert_equal 6, Calculator.new.multiply(2, 3) }   # killed
  end

  def test_divide
    capture_subprocess_io { assert_equal 3, Calculator.new.divide(6, 2) }     # killed
  end

  def test_modulo
    capture_subprocess_io { assert_equal 1, Calculator.new.modulo(7, 3) }     # killed
  end

  def test_power
    capture_subprocess_io { assert_equal 8, Calculator.new.power(2, 3) }      # killed
  end
end
