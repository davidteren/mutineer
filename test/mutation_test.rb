# frozen_string_literal: true

require_relative "test_helper"

class MutationTest < Minitest::Test
  def test_apply_substitutes_byte_range
    source = "a + b"
    m = Brutus::Mutation.new(start_offset: 2, end_offset: 3, replacement: "-", operator: :arithmetic)
    assert_equal "a - b", m.apply(source)
  end

  def test_apply_is_pure
    source = "a + b"
    m = Brutus::Mutation.new(start_offset: 2, end_offset: 3, replacement: "-", operator: :arithmetic)
    m.apply(source)
    assert_equal "a + b", source
  end

  def test_valid_true_for_well_formed_mutation
    source = "a + b"
    m = Brutus::Mutation.new(start_offset: 2, end_offset: 3, replacement: "-", operator: :arithmetic)
    assert m.valid?(source)
  end

  def test_valid_false_for_broken_replacement
    source = "a + b"
    m = Brutus::Mutation.new(start_offset: 2, end_offset: 3, replacement: "(", operator: :arithmetic)
    refute m.valid?(source)
  end

  def test_fields_are_immutable
    m = Brutus::Mutation.new(start_offset: 0, end_offset: 1, replacement: "-", operator: :arithmetic)
    assert_raises(NoMethodError) { m.replacement = "x" }
  end
end
