# frozen_string_literal: true

require "minitest/autorun"
require_relative "nested_deep"

# `b` runs once at load, so `c` exists before the mutant loads.
NestedRedefineDepthFixture.new.b

class NestedDeepInnerTest < Minitest::Test
  def test_c
    assert_equal 2, NestedRedefineDepthFixture.new.c
  end
end
