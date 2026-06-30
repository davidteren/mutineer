# frozen_string_literal: true

require_relative "../test_helper"

class CollectionMethodTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                          singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::CollectionMethod.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :collection_method, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_map_to_each     = assert_single("xs.map { |a| a }", "map", "each")
  def test_each_to_map     = assert_single("xs.each { |a| a }", "each", "map")
  def test_all_to_any      = assert_single("xs.all? { |a| a }", "all?", "any?")
  def test_any_to_all      = assert_single("xs.any? { |a| a }", "any?", "all?")
  def test_first_to_last   = assert_single("xs.first", "first", "last")
  def test_last_to_first   = assert_single("xs.last", "last", "first")
  def test_min_to_max      = assert_single("xs.min", "min", "max")
  def test_max_to_min      = assert_single("xs.max", "max", "min")
  def test_select_to_reject = assert_single("xs.select { |a| a }", "select", "reject")
  def test_reject_to_select = assert_single("xs.reject { |a| a }", "reject", "select")

  def test_unmapped_method_yields_none
    mutations, = run_mutator("xs.size")
    assert_empty mutations
  end

  def test_include_not_swapped
    mutations, = run_mutator("xs.include?(a)")
    assert_empty mutations
  end
end
