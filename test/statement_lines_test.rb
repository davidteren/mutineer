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
    assert_equal (2..5).to_a, lines_at(source, "2")
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
    assert_equal (2..5).to_a, lines_at(source, "2")
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
    assert_equal (3..4).to_a, lines_at(source, "x)")
  end

  def test_the_other_branch_of_a_ternary_is_its_own_statement
    source = <<~'RUBY'
      def f
        value = true ?
          20 :
          raise("x")
      end
    RUBY
    assert_equal (4..4).to_a, lines_at(source, "raise")
  end

  # A heredoc body lies below its opener. Ruby counts the body line for an
  # assigned heredoc, and the opener line for a call such as `puts`.
  def test_a_heredoc_statement_spans_the_heredoc_body
    source = <<~'RUBY'
      def f
        puts(<<~TXT)
          #{false}
        TXT
      end
    RUBY
    assert_equal [2, 3, 4], lines_at(source, "false")
  end

  def test_an_assigned_heredoc_spans_the_interpolation_line
    source = <<~'RUBY'
      def f(count)
        s = <<~TXT
          #{count > 0}
        TXT
      end
    RUBY
    assert_equal [2, 3, 4], lines_at(source, "count > 0")
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
    assert_equal [2, 3, 4, 5], lines_at(source, "1)")
  end

  def test_a_statement_on_its_own_line_inside_an_interpolation_is_its_own_statement
    source = <<~'RUBY'
      def f(flag)
        x = "#{ if flag
          never
        end }"
      end
    RUBY
    assert_equal [3], lines_at(source, "never")
  end

  # The `def` line is counted when the file loads, so it is not a statement of the body.
  def test_the_body_of_an_endless_method_has_no_lines
    source = <<~'RUBY'
      def f =
        false
    RUBY
    assert_empty lines_at(source, "false")
  end

  # PR #188 review: code inside the statement that runs only sometimes gets no
  # lines, because the tests that ran the statement need not have run it.
  {
    "a later when condition" => ["case v\n  when :p then 1\n  when :q,\n       :r then 2\n  end", ":r"],
    "a later in pattern" => ["case v\n  in Integer then 1\n  in String |\n     Symbol then 2\n  end", "Symbol"],
    "a rescue class list" => ["begin\n    g\n  rescue ArgumentError,\n         TypeError\n    nil\n  end", "TypeError"],
    "a lambda default" => ["l = ->(a = g(\n    :m)) { a }", ":m"],
    "a block default" => ["list.each do |a = g(\n    :m)|\n    a\n  end", ":m"],
    "a rescue modifier" => ["x = a rescue g(\n    :m)", ":m"],
    "an or-assign value" => ["@x ||= g(\n    :m)", ":m"],
    "an and-assign value" => ["@x &&= g(\n    :m)", ":m"],
    "a defined? operand" => ["ok = defined?(g(\n    :m))", ":m"],
    "the right side of or" => ["ok = v ||\n    :m", ":m"],
    "the right side of and" => ["ok = v &&\n    :m", ":m"],
    "a safe navigation argument" => ["v&.g(:a,\n    :m)", ":m"],
    "a safe navigation operator-assign value" => ["v&.n += g(\n    :m)", ":m"],
    "an if modifier body" => ["g(:a,\n    :m) if v", ":m"],
    "an unless modifier body" => ["g(:a,\n    :m) unless v", ":m"],
    "an else branch" => ["x = if v then 1 else g(:a,\n    :m) end", ":m"],
    "a later pattern alternative" => ["ok = v in 1 |\n    :m", ":m"],
    "a later element of a required pattern" => ["v => [Integer,\n    :m]", ":m"]
  }.each do |shape, (body, snippet)|
    define_method("test_#{shape.tr(' ?-', '___')}_has_no_lines") do
      source = "def f(v, list)\n  #{body}\nend\n"
      assert_empty lines_at(source, snippet), shape
    end
  end

  # The condition of a modifier `if` runs whenever the statement does.
  def test_a_multi_line_condition_of_an_if_modifier_belongs_to_the_statement
    source = "def f(v)\n  g if h(:a,\n    :b)\nend\n"
    assert_equal [2, 3], lines_at(source, ":b")
  end

  def test_a_later_argument_in_a_when_body_still_belongs_to_its_statement
    source = "def f(v)\n  case v\n  when :p\n    g(1,\n      2)\n  end\nend\n"
    assert_equal [4, 5], lines_at(source, "2)")
  end

  def test_a_default_argument_has_no_lines
    source = <<~'RUBY'
      def work(a =
                sent)
        a
      end
    RUBY
    assert_empty lines_at(source, "sent")
  end

  # A line that holds code outside the statement is counted without the statement.
  def test_a_statement_on_the_def_line_drops_the_def_line_and_the_end_line
    source = <<~'RUBY'
      def f; g(:a,
        :b); end
    RUBY
    assert_empty lines_at(source, ":b")
  end

  def test_a_statement_after_another_on_its_first_line_drops_that_line
    source = <<~'RUBY'
      def f(done)
        return 0 if done; g(:a,
          :b)
      end
    RUBY
    assert_equal [3], lines_at(source, ":b")
  end

  def test_a_statement_in_a_one_line_brace_block_drops_the_shared_lines
    source = <<~'RUBY'
      def f(list)
        list.each { |x| g(x,
          :b) }
      end
    RUBY
    assert_empty lines_at(source, ":b")
  end

  def test_a_statement_in_a_lambda_drops_the_line_of_the_lambda
    source = <<~'RUBY'
      def f
        cb = ->(x) { g(x,
          :b)
        }
      end
    RUBY
    assert_equal [3], lines_at(source, ":b")
  end

  def test_a_statement_in_a_one_line_loop_drops_the_line_of_the_condition
    source = <<~'RUBY'
      def f(c)
        while c; g(:a,
          :b); end
      end
    RUBY
    assert_empty lines_at(source, ":b")
  end

  def test_a_comment_after_a_statement_keeps_its_last_line
    source = <<~'RUBY'
      def f
        g(:a,
          :b) # why
      end
    RUBY
    assert_equal [2, 3], lines_at(source, ":b")
  end

  # Ruby counts the line when it checks the condition, also when the body never runs.
  def test_the_body_of_a_while_modifier_has_no_lines
    source = <<~'RUBY'
      def f(flag)
        g(:a,
          :b) while flag
      end
    RUBY
    assert_empty lines_at(source, ":b")
  end

  def test_the_body_of_an_until_modifier_has_no_lines
    source = <<~'RUBY'
      def f(flag)
        g(:a,
          :b,
          :c) until flag
      end
    RUBY
    assert_empty lines_at(source, ":b")
  end

  def test_the_body_of_a_begin_end_while_runs_with_its_statement
    source = <<~'RUBY'
      def f(flag)
        begin
          g(:a,
            :b)
        end while flag
      end
    RUBY
    assert_equal [3, 4], lines_at(source, ":b")
  end

  # #209: the code of a one-line def that runs each time the method runs.
  def test_runs_with_method_only_for_code_that_runs_on_every_call
    {
      ["def f(c) = c + 1", "c + 1"] => true,
      ["def f(c); c + 1; end", "c + 1"] => true,
      ["def f(c); a; b; end", "a"] => true,
      ["def f(c); a; b; end", "b"] => false, # not the first statement
      ["def f(c) = (c + 1)", "c + 1"] => true, # parentheses run their first statement
      ["def f(c) = begin; c + 1; end", "c + 1"] => true,
      ["def f(c) = (a; b)", "a"] => true,
      ["def f(c) = (a; b)", "b"] => false, # not the first statement in them
      ["def f(c) = c.map { _1 * 2 }", "_1 * 2"] => false, # a block body
      ["def f(c); a += 1 while c; end", "1"] => false, # a loop body
      ["def f(c); a += 1 while c; end", "c;"] => true, # the loop condition
      ["def f(c); 7 if c; end", "7"] => false,
      ["def f(c) = c ? 1 : 2", "1"] => false,
      ["def f(c) = case c when 1 then :x end", ":x"] => false,
      ["def f(c) = g(c) rescue 1", "1"] => false,
      ["def f(c) = g(c) rescue 1", "g(c)"] => true,
      ["def f(c = 1) = c", "1"] => false # a default parameter
    }.each do |(source, snippet), expected|
      def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
      actual = Mutineer::StatementLines.runs_with_method?(def_node, source.index(snippet))
      assert_equal expected, actual, "#{source} at #{snippet}"
    end
  end
end
