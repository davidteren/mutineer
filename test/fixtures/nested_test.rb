# frozen_string_literal: true

require "minitest/autorun"
require_relative "nested"

class NestedTest < Minitest::Test
  def test_outer
    assert_equal 2, Nested.new.outer
  end
end
