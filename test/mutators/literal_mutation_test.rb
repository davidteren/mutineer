# frozen_string_literal: true

require_relative "../test_helper"

class LiteralMutationTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def replacements(source)
    Mutineer::Mutators::LiteralMutation.new.mutations_for(subject_for(source), source).map(&:replacement)
  end

  def test_integer_five_yields_zero_one_six
    assert_equal %w[0 1 6], replacements("def f\n  x = 5\nend\n")
  end

  # #159: "change to 1" and "add 1" give the same edit on 0, so it is emitted once.
  def test_integer_zero_skips_zero_and_emits_one_once
    assert_equal %w[1], replacements("def f\n  x = 0\nend\n")
  end

  def test_integer_one_skips_one
    assert_equal %w[0 2], replacements("def f\n  x = 1\nend\n")
  end

  def test_string_collapses_to_empty
    assert_equal ['""'], replacements("def f\n  s = \"hello\"\nend\n")
  end

  def test_empty_string_skipped
    assert_empty replacements("def f\n  s = \"\"\nend\n")
  end

  def test_single_quoted_string_collapses
    assert_equal ['""'], replacements("def f\n  s = 'hi'\nend\n")
  end

  def test_operator_name
    src = "def f\n  x = 5\nend\n"
    op = Mutineer::Mutators::LiteralMutation.new.mutations_for(subject_for(src), src).first.operator
    assert_equal :literal_mutation, op
  end

  def test_heredoc_is_not_emptied
    src = <<~RUBY
      def f
        n = 1
        <<~X
          hi
        X
      end
    RUBY
    mutations = Mutineer::Mutators::LiteralMutation.new.mutations_for(subject_for(src), src)
    replaced = mutations.map { |m| src[m.start_offset...m.end_offset] }
    refute_includes replaced, "<<~X"
    assert_includes replaced, "1"
  end
end
