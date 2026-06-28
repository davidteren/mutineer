# frozen_string_literal: true

require_relative "../test_helper"

class StatementRemovalTest < Minitest::Test
  def subject_for(source)
    def_node = Brutus::Parser.parse_string(source).value.statements.body.first
    Brutus::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(source)
    [Brutus::Mutators::StatementRemoval.new.mutations_for(subject_for(source), source), source]
  end

  def test_single_statement_yields_none
    mutations, = run_mutator("def f\n  x\nend\n")
    assert_empty mutations
  end

  def test_two_statements_yield_one
    mutations, source = run_mutator("def f\n  side_effect\n  x\nend\n")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "side_effect", source[m.start_offset...m.end_offset]
    assert_equal "nil", m.replacement
    assert_equal :statement_removal, m.operator
    assert m.valid?(source)
  end

  def test_three_statements_yield_two_last_skipped
    src = "def f\n  a = compute\n  logger.info(a)\n  a\nend\n"
    mutations, source = run_mutator(src)
    assert_equal 2, mutations.size
    removed = mutations.map { |m| source[m.start_offset...m.end_offset] }
    assert_equal ["a = compute", "logger.info(a)"], removed
    mutations.each { |m| assert m.valid?(source), "removal should stay parseable" }
  end

  def test_empty_body_yields_none
    mutations, = run_mutator("def f\nend\n")
    assert_empty mutations
  end

  def test_endless_def_yields_none
    mutations, = run_mutator("def f(x) = x + 1\n")
    assert_empty mutations
  end
end
