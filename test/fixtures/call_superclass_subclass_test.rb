# frozen_string_literal: true

require "minitest/autorun"
require_relative "call_superclass_holders"

# Reaches the method only through a subclass that another file defines.
class CallSuperclassSubclassTest < Minitest::Test
  def test_switch_through_the_subclass
    assert SpecialValue.new(type: "switch", value: 1).switch?
    refute SpecialValue.new(type: "x", value: 1).switch?
  end
end
