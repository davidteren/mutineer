# frozen_string_literal: true

require "minitest/autorun"
require_relative "stale_superclass_local"

class StaleSuperclassLocalTest < Minitest::Test
  def test_total_and_three
    assert_equal 2, LocalDeep.new(1).total
    assert LocalDeep.new(3).three?
    refute LocalDeep.new(2).three?
  end
end
