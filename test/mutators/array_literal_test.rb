# frozen_string_literal: true

require_relative "../test_helper"

class ArrayLiteralTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::ArrayLiteral.new.mutations_for(subject_for(source), source), source]
  end

  def test_array_emptied
    mutations, source = run_mutator("[a, b]")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "[a, b]", source[m.start_offset...m.end_offset]
    assert_equal "[]", m.replacement
    assert_equal :array_literal, m.operator
  end

  def test_percent_array_emptied
    mutations, = run_mutator("%i[a b]")
    assert_equal ["[]"], mutations.map(&:replacement)
  end

  def test_nested_arrays_each_emptied
    mutations, source = run_mutator("[[1], [2]]")
    assert_equal ["[[1], [2]]", "[1]", "[2]"], mutations.map { |m| source[m.start_offset...m.end_offset] }
  end

  def test_empty_array_skipped
    ["[]", "%w[]"].each do |body|
      mutations, = run_mutator(body)
      assert_empty mutations, body
    end
  end

  def test_implicit_array_skipped
    mutations, = run_mutator("x = 1, 2")
    assert_empty mutations
  end

  def test_array_with_heredoc_skipped
    mutations, = run_mutator("[<<~A, b]\n    text\n  A")
    assert_empty mutations
  end

  def test_nested_def_skipped
    mutations, = run_mutator("def inner\n    [a, b]\n  end")
    assert_empty mutations
  end

  def test_mutants_round_trip
    ["[a, b]", "%i[a b]", "%w[x y]", "[*a]", "foo [a, b]", "[[1], [2]]", "[a].each { }",
     "a, b = [1, 2]", "[a,\n    b,\n  ]", "x[[1, 2]]"].each do |body|
      mutations, source = run_mutator(body)
      refute_empty mutations, "expected a mutation for #{body.inspect}"
      mutations.each { |m| assert m.valid?(source), "mutated #{body.inspect} should re-parse" }
    end
  end
end
