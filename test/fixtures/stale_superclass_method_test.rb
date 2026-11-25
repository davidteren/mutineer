# frozen_string_literal: true

require "minitest/autorun"
require_relative "stale_superclass_method"

class StaleSuperclassMethodTest < Minitest::Test
  def test_big_and_small
    assert BuiltPoint.new(2).big?
    refute BuiltPoint.new(1).big?
    assert BuiltPoint.new(0).small?
    refute BuiltPoint.new(1).small?
  end
end
