# frozen_string_literal: true

require "minitest/autorun"
require_relative "wrapped_builder"

class WrappedBuilderTest < Minitest::Test
  def test_point
    assert_equal 6, WrappedPoint.new(x: 3).m
  end

  def test_or_a
    assert_equal 6, WrappedOrA.new(x: 3).m
  end
end
