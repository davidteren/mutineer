# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# Weak suite: only exercises #add with inputs where `+` and `-` yield the same
# value (0 + 0 == 0 - 0), so the `+` -> `-` mutation survives undetected.
class CalculatorWeakTest < Minitest::Test
  def test_add
    assert_equal 0, Calculator.new.add(0, 0)
  end
end
