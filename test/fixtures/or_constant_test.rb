# frozen_string_literal: true

require "minitest/autorun"
require_relative "or_constant"

class OrConstantTest < Minitest::Test
  def test_each_predicate
    assert OrCell.new(1).one?
    refute OrCell.new(2).one?
    assert GuardedCell.new(2).two?
    refute GuardedCell.new(1).two?
    assert BlockedCell.new(3).three?
    refute BlockedCell.new(2).three?
    assert StatedCell.new.four?(4)
    refute StatedCell.new.four?(3)
    assert NegatedCell.new.five?(5)
    refute NegatedCell.new.five?(4)
    assert ShimmedCell.new.six?(6)
    refute ShimmedCell.new.six?(5)
  end
end
