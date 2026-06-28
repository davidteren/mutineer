# frozen_string_literal: true

require_relative "../test_helper"

class ConditionNegationTest < Minitest::Test
  def subject_for(source)
    def_node = Brutus::Parser.parse_string(source).value.statements.body.first
    Brutus::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(source)
    [Brutus::Mutators::ConditionNegation.new.mutations_for(subject_for(source), source), source]
  end

  def test_if_condition_wrapped
    mutations, source = run_mutator("def f\n  if x > 0\n    y\n  end\nend\n")
    assert_equal 1, mutations.size
    assert_equal "!( x > 0 )", mutations.first.replacement
    assert_equal "x > 0", source[mutations.first.start_offset...mutations.first.end_offset]
    assert_equal :condition_negation, mutations.first.operator
  end

  def test_unless_condition_wrapped
    mutations, = run_mutator("def f\n  process unless done\nend\n")
    assert_equal 1, mutations.size
    assert_equal "!( done )", mutations.first.replacement
  end

  def test_ternary_condition_wrapped
    mutations, = run_mutator("def f\n  flag ? a : b\nend\n")
    assert_equal 1, mutations.size
    assert_equal "!( flag )", mutations.first.replacement
  end

  def test_nested_conditions_each_wrapped
    mutations, = run_mutator("def f\n  if a && b\n    if c\n      d\n    end\n  end\nend\n")
    assert_equal 2, mutations.size
  end

  def test_wrapped_condition_round_trips
    mutations, source = run_mutator("def f\n  if x > 0\n    y\n  end\nend\n")
    mutations.each { |m| assert m.valid?(source), "wrapped condition must re-parse" }
  end
end
