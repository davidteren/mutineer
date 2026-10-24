# frozen_string_literal: true

require "minitest/autorun"
require_relative "nested_deep"

class NestedDeepTest < Minitest::Test
  def test_b
    assert_equal 2, Deep.new.b
  end
end
