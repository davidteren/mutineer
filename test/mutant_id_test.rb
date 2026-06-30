# frozen_string_literal: true

require_relative "test_helper"

class MutantIdTest < Minitest::Test
  ID = Mutineer::MutantId

  def subject(name: :total, namespace: ["Pricing"], singleton: false)
    Mutineer::Subject.new(file: "x.rb", namespace: namespace, name: name,
                          singleton: singleton, def_node: nil)
  end

  def mutation(src, token, op: :arithmetic, replacement: "-")
    off = src.index(token)
    Mutineer::Mutation.new(start_offset: off, end_offset: off + token.length,
                           replacement: replacement, operator: op)
  end

  def test_deterministic_across_calls
    src = "def total(a, b)\n  a + b\nend\n"
    m = mutation(src, "+")
    assert_equal ID.for(subject, m, src), ID.for(subject, m, src)
  end

  def test_fixed_length_lowercase_hex
    src = "a + b"
    id = ID.for(subject, mutation(src, "+"), src)
    assert_equal 12, id.length
    assert_match(/\A[0-9a-f]{12}\z/, id)
  end

  def test_differs_by_operator
    src = "a + b"
    m1 = mutation(src, "+", op: :arithmetic)
    m2 = mutation(src, "+", op: :literal_mutation)
    refute_equal ID.for(subject, m1, src), ID.for(subject, m2, src)
  end

  def test_differs_by_token
    src = "a + b - c"
    refute_equal ID.for(subject, mutation(src, "+"), src),
                 ID.for(subject, mutation(src, "-"), src)
  end

  def test_differs_by_subject
    src = "a + b"
    m = mutation(src, "+")
    refute_equal ID.for(subject(name: :total), m, src),
                 ID.for(subject(name: :other), m, src)
  end

  def test_differs_by_occurrence
    src = "a + b"
    m = mutation(src, "+")
    refute_equal ID.for(subject, m, src, 0), ID.for(subject, m, src, 1)
  end

  # The core invariant: inserting an unrelated leading line shifts every byte
  # offset, but the id is unchanged because it is keyed on token CONTENT, not the
  # offset — an offset-keyed id would break here.
  def test_invariant_to_leading_inserted_line
    src1 = "a + b"
    src2 = "# an unrelated new comment\na + b"
    assert_equal ID.for(subject, mutation(src1, "+"), src1),
                 ID.for(subject, mutation(src2, "+"), src2)
  end

  # for_subject assigns occurrence so identical (operator, token) twins get
  # distinct ids — e.g. the two `+` in `a + b + c`.
  def test_for_subject_disambiguates_twin_tokens
    src = "a + b + c"
    first = mutation(src, "+")
    second_off = src.index("+", first.start_offset + 1)
    second = Mutineer::Mutation.new(start_offset: second_off, end_offset: second_off + 1,
                                    replacement: "-", operator: :arithmetic)
    ids = ID.for_subject(subject, src, [first, second])
    assert_equal 2, ids.length
    assert_equal 2, ids.uniq.length
  end
end
