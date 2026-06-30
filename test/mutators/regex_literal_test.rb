# frozen_string_literal: true

require_relative "../test_helper"

class RegexLiteralTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                          singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::RegexLiteral.new.mutations_for(subject_for(source), source), source]
  end

  def mutation_tokens(body)
    mutations, source = run_mutator(body)
    mutations.map do |m|
      assert_equal :regex, m.operator
      assert m.valid?(source), "mutated source should re-parse: #{body.inspect}"
      [source[m.start_offset...m.end_offset], m.replacement]
    end
  end

  def test_drop_leading_anchor
    assert_equal [["^", ""]], mutation_tokens('x = /^abc/')
  end

  def test_drop_trailing_anchor
    assert_equal [["$", ""]], mutation_tokens('x = /abc$/')
  end

  def test_both_anchors
    assert_equal [["^", ""], ["$", ""]], mutation_tokens('x = /^abc$/')
  end

  def test_swap_plus_to_star
    assert_equal [["+", "*"]], mutation_tokens('x = /a+/')
  end

  def test_swap_star_to_plus
    assert_equal [["*", "+"]], mutation_tokens('x = /a*/')
  end

  def test_escaped_quantifier_ignored
    assert_empty mutation_tokens('x = /a\+/')
  end

  def test_escaped_trailing_dollar_ignored
    assert_empty mutation_tokens('x = /a\$/')
  end

  def test_plain_pattern_yields_none
    assert_empty mutation_tokens('x = /abc/')
  end
end
