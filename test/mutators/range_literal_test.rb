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

  def test_endless_ranges_yield_none
    ["(1..)", "(1...)", "list[1..]", "(1..nil)", "(1...nil)"].each do |body|
      mutations, = run_mutator(body)
      assert_empty mutations, "expected no mutation for #{body.inspect}"
    end
  end

  def test_endless_range_still_visits_its_begin
    mutations, source = run_mutator("((1..2)..)")
    assert_equal 1, mutations.size
    assert_equal "..", source[mutations.first.start_offset...mutations.first.end_offset]
    assert_equal 2, mutations.first.start_offset - source.index("(1")
    assert mutations.first.valid?(source), "mutated source should re-parse"
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
end
