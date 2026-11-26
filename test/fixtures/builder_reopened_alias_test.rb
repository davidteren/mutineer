# frozen_string_literal: true

require "minitest/autorun"
require_relative "builder_reopened_alias"

class BuilderReopenedAliasTest < Minitest::Test
  def test_x_and_weak
    ReopenedPoint.new(1).weak?(4)
    assert_equal 2, ReopenedPoint.new(1).x
  end
end
