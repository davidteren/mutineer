# frozen_string_literal: true

require "minitest/autorun"
require_relative "nested_deep"

class NestedDeepOuterTest < Minitest::Test
  def test_a_then_b
    deep = Deep.new
    deep.a
    assert_equal 2, deep.b
  end
end
