# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# #20 regression: boot-mode `redefine` must mutate singleton methods defined via
# `class << self` and `module_function`, not just `def self.foo`. Before the fix
# these mutants falsely SURVIVED — redefine installed the mutated method on the
# instance scope, but the call (`Mod.calc`) dispatches to the singleton, so the
# mutation never ran. Reproduces in plain Ruby (no Rails) under strategy redefine.
class SingletonRedefineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_redefine(source, test, strategy: "redefine", only: nil)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/singleton/#{source}"],
      tests: ["test/fixtures/singleton/#{test}"],
      strategy: strategy, only: only,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    Mutineer::Runner.execute(config).first
  end

  def assert_killed(agg, form)
    assert_operator agg.killed_count, :>, 0, "#{form}: expected the mutant to be killed"
    assert_equal 0, agg.survived_count, "#{form}: mutant must not falsely survive (#20)"
    assert_equal 0, agg.uncapturable_count, "#{form}: should be capturable"
    assert_equal 100.0, agg.mutation_score, "#{form}: strong test should score 100%"
  end

  def test_class_self_methods_are_mutated
    assert_killed(run_redefine("class_self.rb", "class_self_test.rb"), "class << self")
  end

  def test_module_function_methods_are_mutated
    assert_killed(run_redefine("module_func.rb", "module_func_test.rb"), "module_function")
  end

  # #98: `module_function :compute` in one module must not turn an unrelated
  # class's `compute` into a singleton subject. Before the fix, redefine wrote a
  # class method the tests never call, so a killable mutant falsely survived.
  def test_module_function_scope_gives_same_verdict_under_reload_and_redefine
    %w[redefine reload].each do |strategy|
      assert_killed(run_redefine("module_func_scope.rb", "module_func_scope_test.rb", strategy: strategy),
                    "module_function scope (#{strategy})")
    end
  end

  def test_only_selects_the_unpromoted_instance_method
    agg = run_redefine("module_func_scope.rb", "module_func_scope_test.rb", only: "ScopeCalculator#compute")
    assert_operator agg.total, :>, 0, "--only ScopeCalculator#compute must select the instance method"
    assert_killed(agg, "--only ScopeCalculator#compute")

    agg = run_redefine("module_func_scope.rb", "module_func_scope_test.rb", only: "ScopeHelper.compute")
    assert_operator agg.total, :>, 0, "--only ScopeHelper.compute must select the promoted module function"
    assert_killed(agg, "--only ScopeHelper.compute")
  end

  # #145: redefine must rebuild the lexical scope as written (`module RootOuter;
  # class ::RootTop`), so a constant from the enclosing module resolves exactly
  # as it does under reload. Otherwise the mutated method raises NameError in the
  # test, and a mutant the weak test cannot detect is reported as a false kill.
  def test_root_anchored_class_keeps_enclosing_lexical_scope
    reload   = run_redefine("root_anchored.rb", "root_anchored_test.rb", strategy: "reload")
    redefine = run_redefine("root_anchored.rb", "root_anchored_test.rb", strategy: "redefine")
    assert_operator reload.survived_count, :>, 0, "the weak test must leave survivors under reload"
    assert_equal reload.survived_count, redefine.survived_count, "redefine must not turn survivors into NameError kills"
    assert_equal reload.killed_count, redefine.killed_count
  end

  def test_data_define_and_struct_new_block_methods_are_mutated
    %w[redefine reload].each do |strategy|
      assert_killed(run_redefine("data_define.rb", "data_define_test.rb", strategy: strategy),
                    "Data.define / Struct.new block (#{strategy})")
    end
  end

  def test_class_new_nested_in_a_data_define_block_is_mutated_on_its_own_constant
    assert_killed(run_redefine("nested_builder.rb", "nested_builder_test.rb", only: "NestedBuilderHost::Other#extra"),
                  "Class.new nested in Data.define")
  end

  def test_anonymous_class_new_is_unplaceable_under_redefine_and_killed_under_reload
    only = "NestedBuilderHost#twice"
    redefine = run_redefine("nested_builder.rb", "nested_builder_test.rb", only: only)
    assert_operator redefine.unplaceable_count, :>, 0
    assert_equal 0, redefine.survived_count + redefine.errored_count + redefine.killed_count + redefine.uncapturable_count
    assert_killed(run_redefine("nested_builder.rb", "nested_builder_test.rb", strategy: "reload", only: only),
                  "anonymous Class.new (reload)")
  end

  def test_owner_unknown_mutants_over_a_tenth_of_the_run_do_not_fail_the_threshold
    agg = run_redefine("nested_builder.rb", "nested_builder_test.rb")
    unscored = agg.total - agg.killed_count
    assert_operator agg.killed_count, :>, 0
    assert_operator unscored, :>, agg.killed_count * 0.1
    assert_equal 0, Mutineer::Reporter.new(agg, {}).exit_code(threshold: 80.0)
  end

  def test_parenthesized_and_or_assigned_builders_are_mutated
    %w[WrappedPoint#m WrappedOrA#m].each do |only|
      assert_killed(run_redefine("wrapped_builder.rb", "wrapped_builder_test.rb", only: only), only)
    end
  end

  def test_self_path_builders_are_mutated_on_the_class_self_names
    %w[PathRelease::Gate#open? PathRelease::Gate::Latch#shut?].each do |only|
      assert_killed(run_redefine("builder_path.rb", "builder_path_test.rb", only: only), only)
    end
  end

  def test_relative_path_builder_is_unplaceable_under_redefine_and_killed_under_reload
    only = "PathUser::Permission#allow?"
    redefine = run_redefine("builder_path.rb", "builder_path_test.rb", only: only)
    assert_operator redefine.unplaceable_count, :>, 0
    assert_equal 0, redefine.survived_count + redefine.errored_count + redefine.killed_count + redefine.uncapturable_count
    assert_killed(run_redefine("builder_path.rb", "builder_path_test.rb", strategy: "reload", only: only), only)
  end

  def test_builder_in_class_self_is_unplaceable_under_redefine_and_killed_under_reload
    only = "#<Class:SingletonBuilderApp>::Point#m"
    redefine = run_redefine("singleton_builder.rb", "singleton_builder_test.rb", only: only)
    assert_operator redefine.unplaceable_count, :>, 0
    assert_equal 0, redefine.survived_count + redefine.errored_count + redefine.killed_count + redefine.uncapturable_count
    assert_killed(run_redefine("singleton_builder.rb", "singleton_builder_test.rb", strategy: "reload", only: only),
                  only)
  end

  def test_class_opened_in_class_self_is_unplaceable_under_redefine_and_killed_under_reload
    files = %w[singleton_nested_class.rb singleton_nested_class_test.rb]
    %w[#<Class:SingletonNestedApp>::Q#q1 #<Class:SingletonNestedApp>::Z#z1].each do |only|
      redefine = run_redefine(*files, only: only)
      assert_operator redefine.unplaceable_count, :>, 0, only
      assert_equal 0, redefine.survived_count + redefine.errored_count + redefine.killed_count +
                      redefine.uncapturable_count, only
      assert_killed(run_redefine(*files, strategy: "reload", only: only), only)
    end
  end

  def test_module_function_in_a_module_new_block_is_mutated
    %w[ModuleNewHost::Helpers.calc ModuleNewHost::Helpers.twice].each do |only|
      assert_killed(run_redefine("module_new_function.rb", "module_new_function_test.rb", only: only), only)
    end
  end

  # Parity control — this form already worked; it must keep working.
  def test_def_self_methods_are_mutated
    assert_killed(run_redefine("def_self.rb", "def_self_test.rb"), "def self.")
  end
end
