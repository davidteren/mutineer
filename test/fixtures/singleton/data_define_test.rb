# frozen_string_literal: true

require "minitest/autorun"
require_relative "data_define"

class DataDefineTest < Minitest::Test
  def test_scaled
    assert_equal 6, DataDefineOuter::Point.new(x: 2).scaled
  end

  def test_sum
    assert_equal 5, DataDefinePair.sum(2, 3)
    assert_equal 7, DataDefinePair.sum(5, 2)
  end
end
