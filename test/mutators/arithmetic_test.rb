# frozen_string_literal: true

require_relative "../test_helper"

class ArithmeticTest < Minitest::Test
  # Build a Subject directly from a parsed snippet (no file needed).
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::Arithmetic.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :arithmetic, m.operator
  end

  def test_plus
    assert_single("a + b", "+", "-")
  end

  def test_minus
    assert_single("a - b", "-", "+")
  end

  def test_times
    assert_single("a * b", "*", "/")
  end

  def test_divide
    assert_single("a / b", "/", "*")
  end

  def test_modulo
    assert_single("a % b", "%", "*")
  end

  def test_power
    assert_single("a ** b", "**", "*")
  end

  def test_nested_yields_two
    mutations, = run_mutator("a + (b * c)")
    assert_equal 2, mutations.size
  end

  def test_no_arithmetic_yields_none
    mutations, = run_mutator("foo(bar)")
    assert_empty mutations
  end

  def test_empty_body_yields_none
    def_node = Mutineer::Parser.parse_string("def m\nend\n").value.statements.body.first
    subject = Mutineer::Subject.new(file: "s.rb", namespace: [], name: :m,
                                  singleton: false, def_node: def_node)
    assert_empty Mutineer::Mutators::Arithmetic.new.mutations_for(subject, "def m\nend\n")
  end
end
