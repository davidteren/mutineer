# frozen_string_literal: true

require_relative "test_helper"

class StatementLinesTest < Minitest::Test
  def lines_at(source, snippet)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::StatementLines.for(def_node, source, source.index(snippet))
  end

  def test_a_later_entry_of_a_hash_belongs_to_the_hash
    source = <<~'RUBY'
      def f
        {
          a: 1,
          b: 2
        }
      end
    RUBY
    assert_equal 2..5, lines_at(source, "2")
  end

  def test_a_later_argument_of_a_call_belongs_to_the_call
    source = <<~'RUBY'
      def f
        build(
          a: 1,
          b: 2
        )
      end
    RUBY
    assert_equal 2..5, lines_at(source, "2")
  end

  def test_a_statement_inside_a_block_is_its_own_statement
    source = <<~'RUBY'
      def f(list)
        list.each do |x|
          puts(x,
            x)
        end
      end
    RUBY
    assert_equal 3..4, lines_at(source, "x)")
  end

  def test_the_other_branch_of_a_ternary_is_its_own_statement
    source = <<~'RUBY'
      def f
        value = true ?
          20 :
          raise("x")
      end
    RUBY
    assert_equal 4..4, lines_at(source, "raise")
  end

  def test_an_interpolation_in_a_heredoc_belongs_to_the_statement_with_the_opener
    source = <<~'RUBY'
      def f
        puts(<<~TXT)
          #{false}
        TXT
      end
    RUBY
    assert_equal 2..2, lines_at(source, "false")
  end

  def test_a_call_inside_a_heredoc_interpolation_belongs_to_the_statement_with_the_opener
    source = <<~'RUBY'
      def f
        puts(<<~TXT)
          #{g(
            1)}
        TXT
      end
    RUBY
    assert_equal 2..2, lines_at(source, "1)")
  end

  def test_the_body_of_an_endless_method_belongs_to_the_def
    source = <<~'RUBY'
      def f =
        false
    RUBY
    assert_equal 1..2, lines_at(source, "false")
  end
end
