# frozen_string_literal: true

require "minitest/autorun"
require_relative "module_func"

class SingletonModuleFuncTest < Minitest::Test
  def test_calc
    assert_equal 5, SingletonModuleFunc.calc(2, 3)
    assert_equal 7, SingletonModuleFunc.calc(5, 2)
  end
end
