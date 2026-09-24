# frozen_string_literal: true

require_relative "../test_helper"

class NegationRemovalTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::NegationRemoval.new.mutations_for(subject_for(source), source), source]
  end

  def test_bang_removed
    mutations, source = run_mutator("!x")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "!", source[m.start_offset...m.end_offset]
    assert_equal "", m.replacement
    assert_equal :negation_removal, m.operator
  end

  def test_not_removed
    mutations, source = run_mutator("not x")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "not", source[m.start_offset...m.end_offset]
    assert_equal "", m.replacement
  end

  def test_double_bang_yields_two
    mutations, source = run_mutator("!!x")
    assert_equal 2, mutations.size
    assert_equal ["!", "!"], mutations.map { |m| source[m.start_offset...m.end_offset] }
  end

  def test_explicit_bang_call_skipped
    mutations, = run_mutator("x.!")
    assert_empty mutations
  end

  def test_safe_navigation_bang_call_skipped
    mutations, = run_mutator("x&.!")
    assert_empty mutations
  end

  def test_not_equal_yields_none
    mutations, = run_mutator("x != y")
    assert_empty mutations
  end

  def test_mutants_round_trip
    ["!x", "not x", "!!x", "not(x)", "!(a && b)", "a && !b", "foo !x", "!x ? 1 : 2"].each do |body|
      mutations, source = run_mutator(body)
      refute_empty mutations, "expected a mutation for #{body.inspect}"
      mutations.each { |m| assert m.valid?(source), "mutated #{body.inspect} should re-parse" }
    end
  end
end
