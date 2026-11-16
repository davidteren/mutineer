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

  # #469: a heredoc line or an interpolated-string part has no quotes of its
  # own. Writing "" over it broke the parse, so the part is declined instead.
  def test_heredoc_and_interpolated_parts_are_declined
    src = <<~'SRC'
      def prompt(x)
        <<~PROMPT
          You are a helper.
          Answer briefly.
        PROMPT
        %(Saved (was: "#{x}"))
      end
    SRC
    op = Mutineer::Mutators::LiteralMutation.new
    assert_empty op.mutations_for(subject_for(src), src)
    assert_equal 4, op.declined
  end

  # The parts are visited directly, so literals inside an interpolation still
  # get their own mutants.
  def test_literals_inside_an_interpolation_still_mutate
    src = "def f(x)\n  \"a \#{x + 1} b\"\nend\n"
    mutations = Mutineer::Mutators::LiteralMutation.new.mutations_for(subject_for(src), src)
    assert_equal ["a ", "1", "1", " b"], mutations.map { |m| src[m.start_offset...m.end_offset] }
  end

  # Every other string form with no quotes of its own is declined too, one
  # decline per non-empty text part, even when the text is `""` itself.
  def test_every_unquoted_string_form_is_declined
    {
      '%Q(a #{x})' => 1, "%w[a b]" => 2, '%W[a#{x} b]' => 2, '/a#{x}/' => 1,
      '`echo #{x}`' => 1, ':"a#{x}"' => 1, '%I[a#{x}]' => 1, '%w[""]' => 1
    }.each do |expr, count|
      src = "def f(x)\n  #{expr}\nend\n"
      op = Mutineer::Mutators::LiteralMutation.new
      assert_empty op.mutations_for(subject_for(src), src), expr
      assert_equal count, op.declined, expr
    end
  end

  # In a "..." string, "" closes and reopens the string, so the part empties.
  def test_double_quoted_interpolated_part_still_mutates
    src = "def f(name)\n  \"Hello, \#{name}\"\nend\n"
    mutations = Mutineer::Mutators::LiteralMutation.new.mutations_for(subject_for(src), src)
    assert_equal ["Hello, "], mutations.map { |m| src[m.start_offset...m.end_offset] }
    mutated = src.byteslice(0, mutations.first.start_offset) + '""' + src.byteslice(mutations.first.end_offset..)
    assert Prism.parse(mutated).success?
  end

  def test_quoted_string_inside_interpolation_still_mutates
    src = "def f(x)\n  \"a \#{g('b')} c\"\nend\n"
    mutations = Mutineer::Mutators::LiteralMutation.new.mutations_for(subject_for(src), src)
    assert_equal ["a ", "'b'", " c"], mutations.map { |m| src[m.start_offset...m.end_offset] }
  end
end
