# frozen_string_literal: true

require "minitest/autorun"
require_relative "stale_superclass_constant"

class StaleSuperclassConstantTest < Minitest::Test
  def test_total_and_three
    assert_equal 2, ConstDeep.new(1).total
    assert ConstDeep.new(3).three?
    refute ConstDeep.new(2).three?
  end
end
