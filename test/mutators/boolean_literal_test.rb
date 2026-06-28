# frozen_string_literal: true

require_relative "../test_helper"

class BooleanLiteralTest < Minitest::Test
  def subject_for(source)
    def_node = Brutus::Parser.parse_string(source).value.statements.body.first
    Brutus::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Brutus::Mutators::BooleanLiteral.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :boolean_literal, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_true_to_false = assert_single("true", "true", "false")
  def test_false_to_true = assert_single("false", "false", "true")
  def test_nil_to_true   = assert_single("nil", "nil", "true")

  def test_nil_in_argument
    assert_single("foo(nil)", "nil", "true")
  end

  def test_two_literals_yield_two
    mutations, = run_mutator("x = true\n  y = false")
    assert_equal 2, mutations.size
  end

  def test_no_literal_yields_none
    mutations, = run_mutator("a + b")
    assert_empty mutations
  end
end
