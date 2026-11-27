# frozen_string_literal: true

require "minitest/autorun"
require_relative "builder_alias_block"

class BuilderAliasBlockTest < Minitest::Test
  def test_x_and_weak
    AliasPoint.new(1).weak?(4)
    assert_equal 2, AliasPoint.new(1).x
  end
end
