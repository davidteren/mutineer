# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class ConditionForcingTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  # Each mutation of `klass` as `token -> replacement`, in emission order.
  def forced(klass, body)
    source = "def m\n  #{body}\nend\n"
    mutations = klass.new.mutations_for(subject_for(source), source)
    mutations.each { |m| assert m.valid?(source), "mutated #{body.inspect} should re-parse" }
    mutations.map { |m| "#{source[m.start_offset...m.end_offset]} -> #{m.replacement}" }
  end

  def both(body)
    [forced(Mutineer::Mutators::ConditionTrue, body), forced(Mutineer::Mutators::ConditionFalse, body)]
  end

  def test_operator_names
    source = "def m\n  a ? b : c\nend\n"
    { Mutineer::Mutators::ConditionTrue => :condition_true,
      Mutineer::Mutators::ConditionFalse => :condition_false }.each do |klass, operator|
      assert_equal [operator], klass.new.mutations_for(subject_for(source), source).map(&:operator)
    end
  end

  def test_if_elsif_else_forces_each_condition
    body = "if a\n    b\n  elsif c\n    d\n  else\n    e\n  end"
    assert_equal [["a -> true", "c -> true"], ["a -> false", "c -> false"]], both(body)
  end

  def test_unless_with_else_and_ternary
    assert_equal [["f -> true"], ["f -> false"]], both("unless f then g else h end")
    assert_equal [["ready? -> true"], ["ready? -> false"]], both("ready? ? 1 : 2")
  end

  def test_modifier_guard_in_a_block
    assert_equal [["row.ok? -> true"], ["row.ok? -> false"]], both("rows.each { |row| save(row) if row.ok? }")
  end

  def test_case_in_guards
    body = "case v\n  in Integer => n if n > 0 then 1\n  in String unless v.empty? then 2\n  end"
    assert_equal [["n > 0 -> true", "v.empty? -> true"], ["n > 0 -> false", "v.empty? -> false"]], both(body)
  end

  def test_whole_condition_is_replaced
    assert_equal [["(a && b) -> (true)"], ["(a && b) -> (false)"]], both("(a && b) ? 1 : 2")
  end

  def test_literal_conditions_are_left_to_boolean_literal
    %w[true false nil].each do |literal|
      assert_equal [[], []], both("if #{literal} then 1 else 2 end")
    end
  end

  # A parenthesized literal is still a literal: `boolean_literal` flips it.
  def test_parenthesized_literal_conditions_are_left_to_boolean_literal
    assert_equal [[], []], both("if (true) then 1 else 2 end")
    assert_equal [[], []], both("((false)) ? 1 : 2")
  end

  # A parenthesized condition keeps its parentheses, so `x if(y)` does not
  # become `x iftrue`, a call to an undefined method.
  def test_parenthesized_condition_keeps_its_parentheses
    assert_equal [["(y) -> (true)"], ["(y) -> (false)"]], both("x if(y)")
    assert_equal [["(a) -> (true)"], ["(a) -> (false)"]], both("(a)?1:2")
  end

  # A space goes between the value and a word character next to it, so a
  # condition that only starts with `(` or `@` does not fuse with the keyword.
  def test_value_is_spaced_from_a_neighbouring_word
    assert_equal [["(a) && b ->  true"], ["(a) && b ->  false"]], both("x if(a) && b")
    assert_equal [["@a ->  true"], ["@a ->  false"]], both("x if@a")
    assert_equal [["foo(a) -> true "], ["foo(a) -> false "]], both("if foo(a)then 1 end")
  end

  # A condition that assigns a local still runs, so later code sees the
  # variable; only the value is forced.
  def test_condition_that_assigns_a_local_keeps_the_assignment
    assert_equal [["(m = s.match(re)) -> ((m = s.match(re)); true)"], ["(m = s.match(re)) -> ((m = s.match(re)); false)"]],
                 both("if (m = s.match(re)) then m[0] end\n  m")
    assert_equal [["/(?<x>a)/ =~ s -> (/(?<x>a)/ =~ s; true)"], ["/(?<x>a)/ =~ s -> (/(?<x>a)/ =~ s; false)"]],
                 both("return 1 unless /(?<x>a)/ =~ s\n  x")
  end

  def test_condition_with_a_heredoc_is_skipped
    assert_equal [[], []], both("if foo(<<~X)\n    hi\n  X\n    1\n  end")
  end

  # Both sides are made even when statement_removal or return_nil would put
  # nil in place of the whole conditional: this operator's mutants must not
  # depend on which other operators run or what the user suppressed.
  def test_never_runs_side_is_always_made
    assert_equal [["a -> true"], ["a -> false"]], both("return :none if a\n  b")
    assert_equal [["b -> true"], ["b -> false"]], both("audit! unless b\n  c")
    assert_equal [["f -> true"], ["f -> false"]], both("x\n  done if f")
    assert_equal [["c -> true"], ["c -> false"]], both("foo = bar if c\n  foo")
    assert_equal [["c -> true"], ["c -> false"]], both("x\n  if c then d else e end")
  end

  def test_runner_makes_the_same_mutants_with_or_without_statement_removal
    Dir.mktmpdir do |dir|
      path = File.join(dir, "guard.rb")
      File.write(path, "def m(a)\n  return :none if a\n  :some\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: dir)
      forced = lambda do |names|
        jobs, = Mutineer::Runner.collect_jobs(config, Mutineer::MutatorRegistry.resolve(names))
        jobs.filter_map { |_, m, id| [m.operator, id] if m.operator == :condition_false }
      end
      assert_equal 1, forced.(%w[condition_false]).size
      assert_equal forced.(%w[condition_false]), forced.(%w[condition_false statement_removal])
    end
  end

  def test_true_and_false_mutants_have_distinct_ids
    source = "def m\n  a ? b : c\nend\n"
    subject = subject_for(source)
    mutations = [Mutineer::Mutators::ConditionTrue, Mutineer::Mutators::ConditionFalse]
                .flat_map { |klass| klass.new.mutations_for(subject, source) }
    assert_equal 2, Mutineer::MutantId.for_subject(subject, source, mutations, path: "snippet.rb").uniq.size
  end

  def test_nested_def_is_its_own_subject
    assert_equal [[], []], both("def inner = (a if b)")
  end
end
