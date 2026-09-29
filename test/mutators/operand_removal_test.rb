# frozen_string_literal: true

require_relative "../test_helper"

class OperandRemovalTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::OperandRemoval.new.mutations_for(subject_for(source), source), source]
  end

  def test_and_keeps_each_operand
    mutations, source = run_mutator("a && b")
    assert_equal ["(a)", "(b)"], mutations.map(&:replacement)
    mutations.each do |m|
      assert_equal "a && b", source[m.start_offset...m.end_offset]
      assert_equal :operand_removal, m.operator
    end
  end

  def test_twin_mutants_get_distinct_ids
    source = "def m\n  a && b\nend\n"
    subject = subject_for(source)
    mutations = Mutineer::Mutators::OperandRemoval.new.mutations_for(subject, source)
    ids = Mutineer::MutantId.for_subject(subject, source, mutations, path: "snippet.rb")
    assert_equal 2, ids.uniq.size
  end

  def test_or_keeps_each_operand
    mutations, = run_mutator("a || b")
    assert_equal ["(a)", "(b)"], mutations.map(&:replacement)
  end

  def test_keyword_connectors_keep_each_operand
    %w[and or].each do |connector|
      mutations, = run_mutator("a #{connector} b")
      assert_equal ["(a)", "(b)"], mutations.map(&:replacement), connector
    end
  end

  def test_chain_yields_four
    mutations, source = run_mutator("a && b && c")
    got = mutations.map { |m| [source[m.start_offset...m.end_offset], m.replacement] }
    assert_equal [["a && b && c", "(a && b)"], ["a && b && c", "(c)"],
                  ["a && b", "(a)"], ["a && b", "(b)"]], got
  end

  def test_or_chain_yields_four
    mutations, = run_mutator("a || b || c")
    assert_equal ["(a || b)", "(c)", "(a)", "(b)"], mutations.map(&:replacement)
  end

  def test_jump_operand_is_not_kept
    mutations, = run_mutator("x = (a or return)")
    assert_equal ["(a)"], mutations.map(&:replacement)
  end

  def test_heredoc_operand_is_not_removed
    mutations, = run_mutator("a && <<~EOS\n    text\n  EOS")
    assert_equal ["(<<~EOS)"], mutations.map(&:replacement)
  end

  # Known weak case: the removed operand assigns `m`, so a later read of `m`
  # calls a method that does not exist. The mutant parses, and any test that
  # runs the line kills it.
  def test_removed_local_assignment_still_emits
    mutations, source = run_mutator("(m = r.match(s)) && m[1]")
    assert_equal ["((m = r.match(s)))", "(m[1])"], mutations.map(&:replacement)
    mutations.each { |m| assert m.valid?(source) }
  end

  def test_nested_def_skipped
    mutations, = run_mutator("def inner\n    a && b\n  end")
    assert_empty mutations
  end

  def test_no_connector_yields_none
    mutations, = run_mutator("a & b")
    assert_empty mutations
  end

  def test_mutants_round_trip
    ["a && b", "a or b", "x = a and b", "foo(a && b)", "a &&\n    # why\n    b", "not a and b",
     "a or return", "a || raise(ArgumentError)", "return a && b", "a && b ? 1 : 2", "x ||= a && b",
     "a && b rescue c", "{k: a || b}", "<<~EOS && b\n    text\n  EOS"].each do |body|
      mutations, source = run_mutator(body)
      refute_empty mutations, "expected a mutation for #{body.inspect}"
      mutations.each { |m| assert m.valid?(source), "mutated #{body.inspect} should re-parse" }
    end
  end
end
