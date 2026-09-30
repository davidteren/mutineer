# frozen_string_literal: true

require_relative "../test_helper"

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
    assert_equal [["(a && b) -> true"], ["(a && b) -> false"]], both("(a && b) ? 1 : 2")
  end

  def test_literal_conditions_are_left_to_boolean_literal
    %w[true false nil].each do |literal|
      assert_equal [[], []], both("if #{literal} then 1 else 2 end")
    end
  end

  # `return :none if a` is a non-final statement, so statement_removal already
  # replaces it with nil — the same program as `return :none if false`.
  def test_never_runs_side_skipped_when_statement_removal_nils_the_conditional
    assert_equal [["a -> true"], []], both("return :none if a\n  b")
    assert_equal [[], ["b -> false"]], both("audit! unless b\n  c")
  end

  # The final expression is replaced by return_nil.
  def test_never_runs_side_skipped_when_return_nil_nils_the_conditional
    assert_equal [["f -> true"], []], both("x\n  done if f")
  end

  # A parenthesized literal is still a literal: `boolean_literal` flips it.
  def test_parenthesized_literal_conditions_are_left_to_boolean_literal
    assert_equal [[], []], both("if (true) then 1 else 2 end")
    assert_equal [[], []], both("((false)) ? 1 : 2")
  end
  
  # The nil twin exists only when statement_removal or return_nil runs.
  # With neither enabled, the never-runs side is the only such mutant.
  def test_never_runs_side_kept_when_no_nil_operator_runs
    source = "def m\n  return :none if a\n  b\nend\n"
    mutations = Mutineer::Mutators::ConditionFalse.new(nilled_by: []).mutations_for(subject_for(source), source)
    assert_equal ["a -> false"], mutations.map { |m| "#{source[m.start_offset...m.end_offset]} -> #{m.replacement}" }
  end
  
  def test_runner_passes_only_the_enabled_nil_operators
    Dir.mktmpdir do |dir|
      path = File.join(dir, "guard.rb")
      File.write(path, "def m(a)\n  return :none if a\n  :some\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: dir)
      ops = ->(names) { Mutineer::Runner.collect_jobs(config, Mutineer::MutatorRegistry.resolve(names)).first.map { |_, m| m.operator } }
      assert_equal %i[condition_false], ops.(%w[condition_false])
      assert_equal %i[statement_removal], ops.(%w[condition_false statement_removal]).uniq
    end
  end
  
  # `foo = bar if c` declares `foo` even when the branch never runs, so the
  # program differs from the nil twin, where a later `foo` is a method call.
  def test_never_runs_side_kept_when_the_conditional_writes_a_local
    assert_equal [["c -> true"], ["c -> false"]], both("foo = bar if c\n  foo")
    assert_equal [["c -> true"], ["c -> false"]], both("(x, y = pair) if c\n  x")
  end
  
  def test_never_runs_side_kept_when_there_is_an_else_or_no_nil_twin
    assert_equal [["c -> true"], ["c -> false"]], both("x\n  if c then d else e end")
    assert_equal [["c -> true"], ["c -> false"]], both("y = (d if c)\n  y")
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
