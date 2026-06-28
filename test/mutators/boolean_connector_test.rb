# frozen_string_literal: true

require_relative "../test_helper"

class BooleanConnectorTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::BooleanConnector.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :boolean_connector, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_and_symbolic = assert_single("a && b", "&&", "||")
  def test_or_symbolic  = assert_single("a || b", "||", "&&")
  def test_and_keyword  = assert_single("a and b", "and", "or")
  def test_or_keyword   = assert_single("a or b", "or", "and")

  def test_form_preserved
    # keyword stays keyword (no cross-form mixing that would change precedence)
    _mutations, = run_mutator("a and b")
    mutations, = run_mutator("a and b")
    assert_equal "or", mutations.first.replacement
  end

  def test_chained_and_yields_two
    mutations, = run_mutator("a && b && c")
    assert_equal 2, mutations.size
  end

  def test_mixed_yields_two
    mutations, = run_mutator("a && b || c")
    assert_equal 2, mutations.size
  end

  def test_no_connector_yields_none
    mutations, = run_mutator("a + b")
    assert_empty mutations
  end
end
