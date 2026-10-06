# frozen_string_literal: true

require "minitest/autorun"
require_relative "module_new_function"

class ModuleNewFunctionTest < Minitest::Test
  def test_calc
    assert_equal 6, ModuleNewHost::Helpers.calc(3)
  end

  def test_twice
    assert_equal 6, ModuleNewHost::Helpers.twice(3)
  end
end
