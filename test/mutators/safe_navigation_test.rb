# frozen_string_literal: true

require_relative "../test_helper"

class SafeNavigationTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::SafeNavigation.new.mutations_for(subject_for(source), source), source]
  end

  def test_safe_navigation_to_plain_call
    mutations, source = run_mutator("user&.name")
    assert_equal 1, mutations.size
    m = mutations.first
    assert_equal "&.", source[m.start_offset...m.end_offset]
    assert_equal ".", m.replacement
    assert_equal :safe_navigation, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_plain_call_yields_none
    mutations, = run_mutator("user.name")
    assert_empty mutations
  end

  def test_chain_yields_one_per_operator
    mutations, source = run_mutator("user&.address&.city")
    assert_equal 2, mutations.size
    mutations.each { |m| assert m.valid?(source), "mutated source should re-parse" }
  end

  def test_compound_writes_and_for_target_each_yield_one
    ["user&.visits += 1", "user&.name ||= \"Ada\"", "user&.name &&= \"Ada\"",
     "for user&.name in names; end"].each do |body|
      mutations, source = run_mutator(body)
      assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
      m = mutations.first
      assert_equal "&.", source[m.start_offset...m.end_offset]
      assert m.valid?(source), "mutated #{body.inspect} should re-parse"
    end
  end

  def test_nested_compound_writes_and_for_target_each_yield_two
    ["user&.address&.visits += 1", "user&.address&.city ||= \"Rome\"",
     "user&.address&.city &&= \"Rome\"", "for user&.address&.city in cities; end"].each do |body|
      mutations, = run_mutator(body)
      assert_equal 2, mutations.size, "expected 2 mutations for #{body.inspect}"
    end
  end

  def test_safe_navigation_setter_round_trips
    mutations, source = run_mutator("user&.name = \"Ada\"")
    assert_equal 1, mutations.size
    assert mutations.first.valid?(source), "mutated setter should re-parse"
  end
end
