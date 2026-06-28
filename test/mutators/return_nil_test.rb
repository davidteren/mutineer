# frozen_string_literal: true

require_relative "../test_helper"

class ReturnNilTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(source)
    [Mutineer::Mutators::ReturnNil.new.mutations_for(subject_for(source), source), source]
  end

  def tokens(mutations, source)
    mutations.map { |m| source[m.start_offset...m.end_offset] }
  end

  def test_explicit_return_expression_becomes_nil
    mutations, source = run_mutator("def f\n  return x + 1\nend\n")
    assert_equal ["x + 1"], tokens(mutations, source)
    assert_equal "nil", mutations.first.replacement
    assert_equal :return_nil, mutations.first.operator
  end

  def test_explicit_return_nil_is_skipped
    mutations, = run_mutator("def f\n  return nil\nend\n")
    assert_empty mutations
  end

  def test_final_expression_becomes_nil
    mutations, source = run_mutator("def f\n  a = 1\n  a + 2\nend\n")
    assert_equal ["a + 2"], tokens(mutations, source)
    assert_equal "nil", mutations.first.replacement
  end

  def test_final_nil_is_skipped
    mutations, = run_mutator("def f\n  nil\nend\n")
    assert_empty mutations
  end

  def test_does_not_descend_into_nested_def
    # outer's final expression is `y`; inner def is its own subject and untouched.
    mutations, source = run_mutator("def outer\n  def inner\n    return x\n  end\n  y\nend\n")
    assert_equal ["y"], tokens(mutations, source)
  end

  def test_all_emitted_mutations_are_valid
    mutations, source = run_mutator("def f\n  return compute(1, 2)\nend\n")
    mutations.each { |m| assert m.valid?(source) }
  end
end
