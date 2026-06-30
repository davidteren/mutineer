# frozen_string_literal: true

require_relative "../test_helper"

class StringLiteralTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                          singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::StringLiteral.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :string_literal, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_non_empty_double_quote = assert_single('x = "hello"', "hello", "")
  def test_non_empty_single_quote = assert_single("x = 'hi'", "hi", "")
  def test_empty_double_quote     = assert_single('x = ""', "", "mutineer")
  def test_empty_single_quote     = assert_single("x = ''", "", "mutineer")

  def test_interpolated_yields_none
    mutations, = run_mutator('x = "hi #{y}"')
    assert_empty mutations
  end

  def test_word_array_yields_none
    mutations, = run_mutator("x = %w[a b]")
    assert_empty mutations
  end

  def test_integer_yields_none
    mutations, = run_mutator("x = 5")
    assert_empty mutations
  end
end
