# frozen_string_literal: true

require "minitest/autorun"
require_relative "call_superclass_holders"

class CallSuperclassTest < Minitest::Test
  def test_switch
    assert InclusionValue.new(type: "switch", value: 1).switch?
    refute InclusionValue.new(type: "x", value: 1).switch?
  end

  def test_weak_runs
    InclusionValue.new(type: "weak", value: 1).weak?
  end

  def test_money
    assert Billing::Money.new(cents: 0).zero?
    refute Billing::Money.new(cents: 5).zero?
  end
end
