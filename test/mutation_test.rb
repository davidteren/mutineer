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

  # C1: Prism offsets are BYTE offsets. A multibyte char before the mutation
  # point shifts char index off byte offset; byte-correct apply must still splice
  # the right token. With char slicing this corrupts the output.
  def test_apply_is_byte_correct_with_multibyte_prefix
    source = "# café\n  a + b\n" # 'é' is 2 bytes => byte offset > char offset
    off = source.byteindex("+")
    m = Brutus::Mutation.new(start_offset: off, end_offset: off + 1,
                             replacement: "-", operator: :arithmetic)
    assert_equal "# café\n  a - b\n", m.apply(source)
  end

  def test_valid_is_byte_correct_with_multibyte_prefix
    source = "# café\n  a + b\n"
    off = source.byteindex("+")
    m = Brutus::Mutation.new(start_offset: off, end_offset: off + 1,
                             replacement: "*", operator: :arithmetic)
    assert m.valid?(source), "byte-correct mutant 'a * b' must reparse clean"
  end

  def test_fields_are_immutable
    m = Brutus::Mutation.new(start_offset: 0, end_offset: 1, replacement: "-", operator: :arithmetic)
    assert_raises(NoMethodError) { m.replacement = "x" }
  end
end
