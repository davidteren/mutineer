# frozen_string_literal: true

require "minitest/autorun"
require_relative "module_func_scope"

class ModuleFuncScopeTest < Minitest::Test
  def test_helper
    assert_equal 5, ScopeHelper.compute(2, 3)
  end

  def test_calculator
    assert_equal 5, ScopeCalculator.new.compute(2, 3)
    assert_equal 7, ScopeCalculator.new.compute(5, 2)
  end
end
