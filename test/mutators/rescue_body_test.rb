# frozen_string_literal: true

require_relative "../test_helper"

# #418: no operator mutated a one-statement rescue body.
class RescueBodyTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                          singleton: false, def_node: def_node)
  end

  def run_mutator(source)
    mutator = Mutineer::Mutators::RescueBody.new
    mutations = mutator.mutations_for(subject_for(source), source)
    mutations.each do |m|
      assert m.valid?(source), "invalid mutant #{source[m.start_offset...m.end_offset].inspect}"
      assert_equal "nil", m.replacement
      assert_equal :rescue_body, m.operator
    end
    [mutations, source, mutator]
  end

  def tokens(mutations, source)
    mutations.map { |m| source[m.start_offset...m.end_offset] }
  end

  def test_one_statement_def_level_rescue_body_becomes_nil
    mutations, source = run_mutator("def day\n  Time.parse(@day)\nrescue ArgumentError\n  head :not_found\nend\n")
    assert_equal ["head :not_found"], tokens(mutations, source)
  end

  def test_multi_statement_body_is_replaced_whole
    mutations, source = run_mutator("def f\n  g\nrescue\n  log(1)\n  :failed\nend\n")
    assert_equal ["log(1)\n  :failed"], tokens(mutations, source)
  end

  def test_each_rescue_clause_gets_its_own_mutation
    mutations, source = run_mutator(<<~RUBY)
      def f
        g
      rescue KeyError
        :missing
      rescue ArgumentError, TypeError => e
        e.message
      end
    RUBY
    assert_equal [":missing", "e.message"], tokens(mutations, source)
  end

  def test_begin_rescue_else_ensure_mutates_only_the_rescue_body
    mutations, source = run_mutator(<<~RUBY)
      def f
        begin
          g
        rescue IOError
          retry_later
        else
          :ok
        ensure
          close
        end
        h
      end
    RUBY
    assert_equal ["retry_later"], tokens(mutations, source)
  end

  def test_rescue_in_a_block_is_mutated
    mutations, source = run_mutator("def f\n  items.each do |i|\n    i.call\n  rescue StandardError\n    skip(i)\n  end\nend\n")
    assert_equal ["skip(i)"], tokens(mutations, source)
  end

  def test_re_raise_and_retry_are_mutated
    mutations, source = run_mutator("def f\n  g\nrescue IOError\n  raise\nrescue KeyError\n  retry\nend\n")
    assert_equal %w[raise retry], tokens(mutations, source)
  end

  def test_rescue_modifier_value_becomes_nil
    mutations, source = run_mutator("def f\n  Integer(@x) rescue 0\nend\n")
    assert_equal ["0"], tokens(mutations, source)
  end

  def test_nothing_to_change_gives_no_mutant
    [
      "def f\n  g\nrescue\nend\n",                 # empty body
      "def f\n  g\nrescue\n  nil\nend\n",          # body already nil
      "def f\n  Integer(@x) rescue nil\nend\n",    # modifier value already nil
      "def f\n  g\nensure\n  close\nend\n"         # ensure is not a rescue body
    ].each do |source|
      mutations, _, mutator = run_mutator(source)
      assert_empty mutations, source
      assert_equal 0, mutator.declined, source
    end
  end

  def test_nested_rescue_bodies_each_get_a_mutation
    mutations, source = run_mutator(<<~RUBY)
      def f
        g
      rescue IOError
        begin
          h
        rescue KeyError
          :inner
        end
      end
    RUBY
    assert_equal ["begin\n    h\n  rescue KeyError\n    :inner\n  end", ":inner"], tokens(mutations, source)
  end

  def test_heredoc_body_that_would_dangle_is_declined
    mutations, _, mutator = run_mutator(<<~RUBY)
      def f
        g
      rescue
        <<~MSG
          failed
        MSG
      end
    RUBY
    assert_empty mutations
    assert_equal 1, mutator.declined
  end
end
