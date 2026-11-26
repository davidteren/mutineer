# frozen_string_literal: true

require_relative "../test_helper"

class OperatorAssignmentTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::OperatorAssignment.new.mutations_for(subject_for(source), source), source]
  end

  def assert_swap(body, token, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal token, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :operator_assignment, m.operator
    assert_parses_like_original(m, source, body)
  end

  # The mutant parses exactly as the original does. Prism 2 reports a bare
  # constant op-assign inside a def as "dynamic constant assignment" (Prism 1
  # and Ruby 3.4 accept it), so the original's errors are the baseline.
  def assert_parses_like_original(mutation, source, body)
    original = Mutineer::Parser.parse_string(source).errors.map(&:message)
    mutant = Mutineer::Parser.parse_string(mutation.apply(source)).errors.map(&:message)
    assert_equal original, mutant, "mutated #{body.inspect} should parse as the original does"
  end

  def test_plus_assign_to_minus_assign
    assert_swap("t += x", "+=", "-=")
  end

  def test_minus_assign_to_plus_assign
    assert_swap("t -= x", "-=", "+=")
  end

  def test_times_assign_to_divide_assign
    assert_swap("t *= x", "*=", "/=")
  end

  def test_divide_assign_to_times_assign
    assert_swap("t /= x", "/=", "*=")
  end

  def test_modulo_assign_to_times_assign
    assert_swap("t %= x", "%=", "*=")
  end

  def test_power_assign_to_times_assign
    assert_swap("t **= x", "**=", "*=")
  end

  def test_instance_variable
    assert_swap("@t += 1", "+=", "-=")
  end

  def test_class_variable
    assert_swap("@@t += 1", "+=", "-=")
  end

  def test_global_variable
    assert_swap("$t += 1", "+=", "-=")
  end

  def test_constant
    assert_swap("T += 1", "+=", "-=")
  end

  def test_constant_path
    assert_swap("A::T += 1", "+=", "-=")
  end

  def test_top_level_constant_path
    assert_swap("::T += 1", "+=", "-=")
  end

  def test_call
    assert_swap("a.b += 1", "+=", "-=")
  end

  def test_safe_navigation_call
    assert_swap("a&.b += 1", "+=", "-=")
  end

  def test_index
    assert_swap("a[i] += 1", "+=", "-=")
  end

  def test_index_with_many_arguments
    assert_swap("a[i, j] -= 1", "-=", "+=")
  end

  def test_or_and_and_assign_yield_none
    ["t ||= 1", "@t ||= 1", "a.b ||= 1", "a[i] ||= 1", "t &&= 1", "@t &&= 1"].each do |body|
      mutations, = run_mutator(body)
      assert_empty mutations, "expected no mutation for #{body.inspect}"
    end
  end

  def test_bitwise_and_shift_assign_yield_none
    ["t |= 1", "t &= 1", "t ^= 1", "t <<= 1", "t >>= 1"].each do |body|
      mutations, = run_mutator(body)
      assert_empty mutations, "expected no mutation for #{body.inspect}"
    end
  end

  def test_plain_assignment_and_binary_call_yield_none
    ["t = 1", "t = t + 1", "a.b = 1", "a[i] = 1"].each do |body|
      mutations, = run_mutator(body)
      assert_empty mutations, "expected no mutation for #{body.inspect}"
    end
  end

  def test_block_body_is_visited
    assert_swap("items.each { |item| total += item }", "+=", "-=")
  end

  def test_nested_writes_yield_one_per_operator
    mutations, source = run_mutator("t += (u *= 2)")
    assert_equal 2, mutations.size
    assert_equal %w[-= /=], mutations.sort_by(&:start_offset).map(&:replacement)
    mutations.each { |m| assert m.valid?(source), "mutated source should re-parse" }
  end

  def test_every_form_visits_its_value
    ["t += (u *= 2)", "@t += (u *= 2)", "@@t += (u *= 2)", "$t += (u *= 2)", "T += (u *= 2)",
     "A::T += (u *= 2)", "a.b += (u *= 2)", "a[i] += (u *= 2)"].each do |body|
      mutations, = run_mutator(body)
      assert_equal %w[-= /=], mutations.sort_by(&:start_offset).map(&:replacement),
                   "expected the outer and the nested write in #{body.inspect}"
    end
  end

  def test_nested_def_skipped
    mutations, = run_mutator("def inner\n    t += 1\n  end")
    assert_empty mutations
  end

  def test_every_form_round_trips
    ["t += 1", "t -= 1", "t *= 2", "t /= 2", "t %= 2", "t **= 2", "@t += 1", "@@t -= 1",
     "$t *= 2", "T /= 2", "A::T %= 2", "::T **= 2", "a.b += 1", "a&.b -= 1", "a[i] *= 2",
     "a[] += 1", "s += <<~TEXT\n    hi\n  TEXT"].each do |body|
      mutations, source = run_mutator(body)
      assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
      assert_parses_like_original(mutations.first, source, body)
    end
  end
end
