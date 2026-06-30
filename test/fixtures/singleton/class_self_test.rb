# frozen_string_literal: true

require "minitest/autorun"
require_relative "class_self"

class SingletonClassSelfTest < Minitest::Test
  def test_calc
    assert_equal 5, SingletonClassSelf.calc(2, 3)
    assert_equal 7, SingletonClassSelf.calc(5, 2)
  end
end
