# frozen_string_literal: true

require "minitest/autorun"
require_relative "const_superclass_holders"

class ConstSuperclassTest < Minitest::Test
  def test_three
    assert Row.new(3).three?
    refute Row.new(2).three?
  end

  def test_weak_runs
    Row.new(4).weak?
  end

  def test_in_block
    assert BaseRow.new(1).in_block?
    refute BaseRow.new(2).in_block?
  end

  def test_zero
    assert Ledger::Credit.new(cents: 0).zero?
    refute Ledger::Credit.new(cents: 5).zero?
  end
end
