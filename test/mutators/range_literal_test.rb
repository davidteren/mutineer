# frozen_string_literal: true

require_relative "../test_helper"

class RangeLiteralTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::RangeLiteral.new.mutations_for(subject_for(source), source), source]
  end

  def test_inclusive_to_exclusive
    mutations, source = run_mutator("(1..10).to_a")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "..", source[m.start_offset...m.end_offset]
    assert_equal "...", m.replacement
    assert_equal :range, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_exclusive_to_inclusive
    mutations, source = run_mutator("(1...10).to_a")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "...", source[m.start_offset...m.end_offset]
    assert_equal "..", m.replacement
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_beginless_ranges_round_trip
    { "..5" => "...", "...5" => ".." }.each do |body, replacement|
      mutations, source = run_mutator(body)
      assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
      assert_equal replacement, mutations.first.replacement
      assert mutations.first.valid?(source), "mutated #{body.inspect} should re-parse"
    end
  end

  # A literal fixes the receiver's class, so the endless index is declined.
  def test_endless_slice_of_an_array_or_string_literal_is_declined
    ['"abcd"[1..]', '"abcd"[1...]', '"abcd"[1..nil]', "'abcd'[1..]", '"ab#{1}"[1..]',
     '%q{abcd}[1..]', '%Q{ab#{1}}[1..]', '%w[a b c][1..]', '%W[a #{1}][1..]', '%i[a b][1..]',
     '[10, 20, 30][1..]', '[10, 20, 30][1...]', '[10, 20, 30].slice(1..)',
     '[10, 20, 30].slice!(1..)', '"abcd".byteslice(1..)', '"abcd"&.byteslice(1...)',
     '"abcd".bytesplice(1.., "x")', '[10, 20, 30].values_at(1..)', '("abcd")[1..]',
     '([1, 2, 3])[1..]',      '(("abcd"))[1..]', '(1; "abcd")[1..]', '"abcd"[1..] = "x"', '[1, 2][1..] = [9]',
     '"abcd"[1..] += "x"', '[1, 2][1..] ||= [9]', '[1, 2][1..] &&= [9]',
     '[1, 2][1..], b = x, y', "begin\n    \"abcd\"\n  end[1..]"].each do |body|
      mutations, = run_mutator(body)
      assert_empty mutations, "expected no mutation for #{body.inspect}"
      assert_equal 1, declined(body), "for #{body.inspect}"
    end
    mutations, = run_mutator("[1, 2, 3].values_at(1.., 0..)")
    assert_empty mutations
    assert_equal 2, declined("[1, 2, 3].values_at(1.., 0..)")
  end

  def test_endless_ranges_outside_a_slice_are_swapped
    { "(1..)" => "...", "(1...)" => "..", "(1..nil)" => "...", "(1...nil)" => "..",
      "r = (1..)" => "...", "list.fetch(1..)" => "...", "h[:k] = 1..nil" => "...",
      "list[(1..)]" => "...", '"ab"[1..] = (2..)' => "...", "Array[1..]" => "...", "::Set[1...]" => "..",
      "Foo::Bar[1..]" => "...", "Registry[1..] ||= x" => "...", "Registry[1..] += x" => "...",
      "Registry[1..] &&= x" => "...", "Registry[1..], b = x, y" => "..." }.each do |body, replacement|
      mutations, source = run_mutator(body)
      assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
      m = mutations.first
      assert_equal Mutineer::Mutators::RangeLiteral::SWAPS.fetch(replacement), source[m.start_offset...m.end_offset]
      assert_equal replacement, m.replacement
      assert_equal :range, m.operator
      assert m.valid?(source), "mutated #{body.inspect} should re-parse"
    end
  end

  def test_index_write_mutates_the_assigned_range_not_the_index
    mutations, source = run_mutator('"ab"[1..] = (2..)')
    assert_equal 1, mutations.size
    assert_equal source.index("(2..)") + 2, mutations.first.start_offset
    assert_equal 1, declined('"ab"[1..] = (2..)')
  end

  # The receiver is not a literal, so both ranges are swapped. The index is
  # not declined just because the call is named `[]=`.
  def test_index_write_on_a_variable_swaps_the_index_and_the_value
    body = "list[1..] = (2..)"
    mutations, source = run_mutator(body)
    assert_equal 2, mutations.size
    assert_equal 0, declined(body)
    offsets = [source.index("list[1..]") + "list[1".length, source.index("(2..)") + "(2".length]
    assert_equal offsets.sort, mutations.map(&:start_offset).sort
    mutations.each do |m|
      assert_equal "..", source[m.start_offset...m.end_offset]
      assert_equal "...", m.replacement
      assert_equal :range, m.operator
      assert m.valid?(source)
    end
  end

  def test_endless_def_body_is_swapped
    source = "def r = (1..nil)\n"
    mutations = Mutineer::Mutators::RangeLiteral.new.mutations_for(subject_for(source), source)
    assert_equal 1, mutations.size
    assert_equal "...", mutations.first.replacement
    assert mutations.first.valid?(source), "mutated source should re-parse"
  end

  def test_endless_range_still_visits_its_begin
    mutations, source = run_mutator('"ab"[(1..2)..]')
    assert_equal 1, mutations.size
    assert_equal "..", source[mutations.first.start_offset...mutations.first.end_offset]
    assert_equal 2, mutations.first.start_offset - source.index("(1")
    assert_equal 1, declined('"ab"[(1..2)..]')
    assert mutations.first.valid?(source), "mutated source should re-parse"
  end

  # The outer range is an index of a variable, so it is swapped as well as the
  # inner range. The visit does not stop at the endless range.
  def test_endless_index_of_a_variable_swaps_its_begin_too
    body = "list[(1..2)..]"
    mutations, source = run_mutator(body)
    assert_equal 2, mutations.size
    assert_equal 0, declined(body)
    inner = source.index("(1..2)") + "(1".length
    outer = source.index("2)..]") + "2)".length
    assert_equal [inner, outer].sort, mutations.map(&:start_offset).sort
  end

  def test_nested_ranges_yield_one_per_operator
    mutations, source = run_mutator("(1..2)...(3..4)")
    assert_equal 3, mutations.size
    assert_equal %w[... .. ...], mutations.sort_by(&:start_offset).map(&:replacement)
    mutations.each { |m| assert m.valid?(source), "mutated source should re-parse" }
  end

  def test_flip_flop_yields_none
    mutations, = run_mutator("puts x if (x == 1)..(x == 5)")
    assert_empty mutations
  end

  # The declined count after one run on `body`.
  def declined(body)
    source = "def m\n  #{body}\nend\n"
    Mutineer::Mutators::RangeLiteral.new.tap { |op| op.mutations_for(subject_for(source), source) }.declined
  end

  def test_endless_range_counts_as_declined
    ['"abcd"[1..]', '"abcd"[1...]', "'ab'[1..nil]", '"ab".slice(1..)', "[1, 2].values_at(2..)"].each do |body|
      assert_equal 1, declined(body), "for #{body.inspect}"
    end
    ["(1..10)", "(1..)", "(1...nil)", "list[1..]", "HASH[1..]"].each do |body|
      assert_equal 0, declined(body), "for #{body.inspect}"
    end
  end

  # #344: the skip used the call name, so a Hash, a Proc, a constant, and a
  # custom receiver hid a killable mutant. The receiver node is not an array
  # or string literal, so the operator is swapped and nothing is declined.
  def test_endless_range_on_a_receiver_that_is_not_a_literal_is_swapped
    { "list[1..]" => "...", "list[1...]" => "..", "list[1..nil]" => "...",
      "h[1..]" => "...", "fn[1..]" => "...", "list = [1, 2]\n  list[1..]" => "...",
      "@list[1..]" => "...", "@@list[1..]" => "...", "$list[1..]" => "...",
      "ARGV[1..]" => "...", "::ARGV[1..]" => "...", "HASH[1..]" => "...",
      "Foo::LIST[1..]" => "...", "s.slice(1..)" => "...", "s.slice!(1..)" => "...",
      "text.byteslice(1..)" => "...", "s&.byteslice(1...)" => "..", "byteslice(1..)" => "...",
      "s.bytesplice(1.., x)" => "...", "row.values_at(1..)" => "...", "box.slice(1..)" => "...",
      "->(r) { r.exclude_end? }[1..]" => "...", "proc { |r| r }[1..]" => "...",
      "lambda { |r| r }[1..]" => "...", "list.[](1..)" => "...", "list[1..] = x" => "...",
      "list[1..] += x" => "...", "list[1..] ||= x" => "...", "list[1..] &&= x" => "...",
      "HASH[1..] ||= x" => "...", "(list)[1..]" => "...", "(h)[1..]" => "...",
      "list[1..], b = x, y" => "...", '`echo ab`[1..]' => "...",
      '`echo #{1}`[1..]' => "..." }.each do |body, replacement|
      mutations, source = run_mutator(body)
      assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
      m = mutations.first
      operator = source[m.start_offset...m.end_offset]
      assert_equal Mutineer::Mutators::RangeLiteral::SWAPS.fetch(replacement), operator
      assert_equal replacement, m.replacement
      assert_equal :range, m.operator
      assert_equal source.index(operator), m.start_offset, "operator offset for #{body.inspect}"
      assert_equal 0, declined(body), "for #{body.inspect}"
      assert m.valid?(source), "mutated #{body.inspect} should re-parse"
    end
  end

  # The index of a hash literal is a different key for `..` and `...`. Both
  # ranges are swapped: the key, and the index. The index is not declined.
  def test_hash_literal_index_is_swapped_with_its_key
    body = "{(1..) => :a}[1..]"
    mutations, source = run_mutator(body)
    assert_equal 0, declined(body)
    assert_equal 2, mutations.size
    key_at = source.index("(1..)") + "(1".length
    index_at = source.index("[1..]") + "[1".length
    assert_equal [key_at, index_at].sort, mutations.map(&:start_offset).sort
    mutations.each do |m|
      assert_equal "..", source[m.start_offset...m.end_offset]
      assert_equal "...", m.replacement
      assert_equal :range, m.operator
      assert m.valid?(source)
    end
  end

  # An earlier literal does not change the receiver node. The local is swapped
  # even when the assignment shows it holds an array or a hash.
  def test_an_assigned_literal_does_not_make_the_local_a_slice
    array = "list = [1, 2, 3]\n  list[1..]"
    mutations, source = run_mutator(array)
    assert_equal 1, mutations.size
    assert_equal 0, declined(array)
    assert_equal source.index("list[1..]") + "list[1".length, mutations.first.start_offset

    hash = "list = { (1..) => :a }\n  list[1..]"
    mutations, source = run_mutator(hash)
    assert_equal 0, declined(hash)
    assert_equal 2, mutations.size
    key_at = source.index("(1..)") + "(1".length
    index_at = source.index("list[1..]") + "list[1".length
    assert_equal [key_at, index_at].sort, mutations.map(&:start_offset).sort
  end

  # A rescue or else can return a Hash even when another branch is a string.
  # The index is swapped. A begin whose every value branch is a string stays
  # declined, and ensure does not supply the value.
  def test_begin_rescue_and_else_are_swapped_unless_every_value_is_a_literal
    rescued = "(begin\n    raise \"bad\"\n    \"ab\"\n  rescue\n    {(1..) => :open}\n  end)[1..]"
    mutations, source = run_mutator(rescued)
    assert_equal 0, declined(rescued)
    assert_equal 2, mutations.size
    key_at = source.index("(1..)") + "(1".length
    index_at = source.index("end)[1..]") + "end)[1".length
    assert_equal [key_at, index_at].sort, mutations.map(&:start_offset).sort

    other = "begin\n    \"ab\"\n  rescue\n    \"cd\"\n  else\n    {(1..) => :a}\n  end[1..]"
    mutations, source = run_mutator(other)
    assert_equal 0, declined(other)
    assert_includes mutations.map(&:start_offset), source.index("end[1..]") + "end[1".length

    chained = "begin\n    \"ab\"\n  rescue A\n    \"cd\"\n  rescue\n    {(1..) => :a}\n  end[1..]"
    mutations, source = run_mutator(chained)
    assert_equal 0, declined(chained)
    assert_includes mutations.map(&:start_offset), source.index("end[1..]") + "end[1".length

    empty = "begin\n    \"ab\"\n  rescue\n  end[1..]"
    mutations, source = run_mutator(empty)
    assert_equal 0, declined(empty)
    assert_equal 1, mutations.size
    assert_equal source.index("end[1..]") + "end[1".length, mutations.first.start_offset

    both = "begin\n    \"ab\"\n  rescue\n    \"cd\"\n  end[1..]"
    assert_empty run_mutator(both).first
    assert_equal 1, declined(both)

    ensured = "begin\n    \"abcd\"\n  ensure\n    {(1..) => :a}\n  end[1..]"
    mutations, source = run_mutator(ensured)
    assert_equal 1, declined(ensured)
    assert_equal 1, mutations.size
    assert_equal source.index("(1..)") + "(1".length, mutations.first.start_offset
    refute_includes mutations.map(&:start_offset), source.index("end[1..]") + "end[1".length
  end
end
