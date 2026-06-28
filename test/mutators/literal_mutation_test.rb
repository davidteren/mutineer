# frozen_string_literal: true

require_relative "../test_helper"

class LiteralMutationTest < Minitest::Test
  def subject_for(source)
    def_node = Brutus::Parser.parse_string(source).value.statements.body.first
    Brutus::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def replacements(source)
    Brutus::Mutators::LiteralMutation.new.mutations_for(subject_for(source), source).map(&:replacement)
  end

  def test_integer_five_yields_zero_one_six
    assert_equal %w[0 1 6], replacements("def f\n  x = 5\nend\n")
  end

  def test_integer_zero_skips_zero
    assert_equal %w[1 1], replacements("def f\n  x = 0\nend\n")
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
    op = Brutus::Mutators::LiteralMutation.new.mutations_for(subject_for(src), src).first.operator
    assert_equal :literal_mutation, op
  end
end
