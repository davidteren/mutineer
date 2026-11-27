# frozen_string_literal: true

require "minitest/autorun"
require_relative "stale_superclass_literal"

class StaleSuperclassLiteralTest < Minitest::Test
  def test_total_and_three
    assert_equal 2, LiteralRow.new(1).total
    assert LiteralRow.new(3).three?
    refute LiteralRow.new(2).three?
  end
end
