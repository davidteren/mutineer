# frozen_string_literal: true

require "minitest/autorun"
require_relative "nested_builder"

class NestedBuilderTest < Minitest::Test
  def test_extra
    assert_equal 6, NestedBuilderHost::Other.new.extra(3)
  end

  def test_twice
    assert_equal 6, NestedBuilderHost::HELPER.twice(3)
    assert_equal 9, NestedBuilderHost::HELPER.thrice(3)
  end
end
