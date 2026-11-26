# frozen_string_literal: true

require "minitest/autorun"
require_relative "call_superclass_holders"

# Data#== compares classes, so a new class object would fail this assertion.
class CallSuperclassHolderEqTest < Minitest::Test
  def test_the_kept_instance_equals_a_new_one
    assert_equal DEFAULT_VALUE, InclusionValue.new(type: "switch", value: 1)
    InclusionValue.new(type: "weak", value: 1).weak?
  end
end
