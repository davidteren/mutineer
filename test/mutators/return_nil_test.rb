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

  def test_heredoc_return_value_and_final_expression_are_skipped
    returned, source = run_mutator(<<~RUBY)
      def f
        return <<~X
          hi
        X
        1
      end
    RUBY
    assert_equal ["1"], tokens(returned, source)

    final, = run_mutator(<<~RUBY)
      def f
        <<~X
          hi
        X
      end
    RUBY
    assert_empty final

    call, = run_mutator(<<~RUBY)
      def f
        foo(<<~X)
          hi
        X
      end
    RUBY
    assert_empty call
  end

  # #418: a def-level rescue makes the body a BeginNode. Each value the method
  # can return becomes nil: the body's (or else's) and each rescue clause's.
  def test_def_level_rescue_final_expressions_become_nil
    mutations, source = run_mutator("def day\n  a = 1\n  Time.parse(@day)\nrescue ArgumentError\n  head :not_found\nend\n")
    assert_equal ["Time.parse(@day)", "head :not_found"], tokens(mutations, source)
  end

  def test_def_level_rescue_with_several_clauses
    mutations, source = run_mutator("def f\n  g\nrescue KeyError\n  :missing\nrescue IOError => e\n  log(e)\n  :io\nend\n")
    assert_equal ["g", ":missing", ":io"], tokens(mutations, source)
  end

  def test_def_level_else_is_the_value_and_ensure_is_not
    mutations, source = run_mutator("def f\n  g\nrescue IOError\n  :io\nelse\n  :ok\nensure\n  close\nend\n")
    assert_equal [":ok", ":io"], tokens(mutations, source)
  end

  def test_def_level_ensure_without_rescue
    mutations, source = run_mutator("def f\n  g\nensure\n  close\nend\n")
    assert_equal ["g"], tokens(mutations, source)
  end

  def test_def_level_rescue_skips_nil_return_and_empty_clauses
    mutations, source = run_mutator("def f\n  return g\nrescue KeyError\n  nil\nrescue IOError\nend\n")
    assert_equal ["g"], tokens(mutations, source)
  end

  def test_rescue_modifier_final_expression_becomes_nil_whole
    mutations, source = run_mutator("def f\n  Integer(@x) rescue 0\nend\n")
    assert_equal ["Integer(@x) rescue 0"], tokens(mutations, source)
  end

  def test_dangling_heredoc_drop_counts_as_declined
    source = "def f\n  return <<~X\n    hi\n  X\n  1\nend\n"
    op = Mutineer::Mutators::ReturnNil.new
    op.mutations_for(subject_for(source), source)
    assert_equal 1, op.declined
  end
end
