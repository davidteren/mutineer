# frozen_string_literal: true

require "minitest/autorun"
require_relative "call_superclass_shapes"

class CallSuperclassShapesTest < Minitest::Test
  def test_block_struct
    assert BlockStruct.new(1).in_block?
    refute BlockStruct.new(3).in_block?
    assert BlockStruct.new(2).in_body?
    refute BlockStruct.new(3).in_body?
  end

  def test_wrapped
    assert Wrapped.new([1, 2, 3]).big?
    refute Wrapped.new([1]).big?
  end

  def test_made
    assert Made.new("x").loud?
    refute Made.new("y").loud?
  end

  def test_nested_and_pathed
    assert Outer::Inner.new(1).one?
    refute Outer::Inner.new(2).one?
    assert Outer::Pathed.new(2).two?
    refute Outer::Pathed.new(1).two?
  end

  def test_rooted
    assert Rooted.new(3).three?
    refute Rooted.new(1).three?
  end

  def test_spread
    assert Spread.new(true, true).both?
    refute Spread.new(true, false).both?
    refute Spread.new(false, true).both?
  end
end
