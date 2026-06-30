# frozen_string_literal: true

require "minitest/autorun"
require_relative "def_self"

class SingletonDefSelfTest < Minitest::Test
  def test_calc
    assert_equal 5, SingletonDefSelf.calc(2, 3)
    assert_equal 7, SingletonDefSelf.calc(5, 2)
  end
end
