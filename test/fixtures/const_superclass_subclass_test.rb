# frozen_string_literal: true

require "minitest/autorun"
require_relative "const_superclass_holders"

# Reaches `three?` only through a subclass that another file defines, and
# checks that the kept constant is the class the held instance has.
class ConstSuperclassSubclassTest < Minitest::Test
  def test_three_through_the_subclass
    assert SpecialRow.new(3).three?
    refute SpecialRow.new(2).three?
  end

  def test_the_held_instance_keeps_its_class
    # A new BaseRow object would make both false for every mutant.
    assert_kind_of BaseRow, DEFAULT_ROW
    assert_equal DEFAULT_ROW, Row.new(3)
  end
end
