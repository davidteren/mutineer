# frozen_string_literal: true

require "minitest/autorun"
require_relative "builder_constant_holders"

# Reaches `one?` only through the subclass and the instance of another file.
class BuilderConstantSubclassTest < Minitest::Test
  def test_one_through_the_subclass
    assert BuilderSubPoint.new(1).one?
    refute BuilderSubPoint.new(2).one?
  end

  def test_one_through_the_held_instance
    assert BUILDER_ORIGIN.one?
  end
end
