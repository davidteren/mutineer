# frozen_string_literal: true

require_relative "../test_helper"

class ComparisonTest < Minitest::Test
  def subject_for(source)
    def_node = Brutus::Parser.parse_string(source).value.statements.body.first
    Brutus::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Brutus::Mutators::Comparison.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :comparison, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_gte_to_gt   = assert_single("price >= 100", ">=", ">")
  def test_lte_to_lt   = assert_single("price <= 100", "<=", "<")
  def test_lt_to_lte   = assert_single("a < b", "<", "<=")
  def test_gt_to_gte   = assert_single("a > b", ">", ">=")
  def test_eq_to_neq   = assert_single("x == y", "==", "!=")
  def test_neq_to_eq   = assert_single("x != y", "!=", "==")

  def test_arithmetic_yields_none
    mutations, = run_mutator("a + b")
    assert_empty mutations
  end

  def test_nested_yields_two
    mutations, = run_mutator("a >= b && c <= d")
    assert_equal 2, mutations.size
  end
end
