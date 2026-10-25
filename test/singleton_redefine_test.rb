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

  def run_redefine(source, test, strategy: "redefine", only: nil, require_paths: [], matrix: false)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/singleton/#{source}"],
      tests: ["test/fixtures/singleton/#{test}"],
      require_paths: require_paths.map { |f| "test/fixtures/singleton/#{f}" },
      strategy: strategy, only: only, matrix: matrix,
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

  # #229: `module self::X` in a block is under the block's `self`, which the
  # redefine wrapper cannot reopen; before the fix it loaded the mutant onto a new
  # SelfPathApp::Calc, so the mutants falsely survived.
  def test_self_path_module_in_a_block_is_unplaceable_under_redefine_and_killed_under_reload
    files = %w[self_path_block.rb self_path_block_test.rb]
    %w[SelfPathApp::Calc.sum SelfPathApp::Built::Calc.product].each do |only|
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

  # #252: a def in an ActiveSupport::Concern `class_methods` block belongs to the
  # concern's ClassMethods. Before the fix, redefine loaded the mutant onto the
  # concern itself, the test called the includer's class method, and every
  # mutant falsely survived. #300: the concern body also defines `scaled(x, y)`,
  # so a mutant loaded onto the concern breaks `test_instance_scaled` and is
  # killed by the wrong test. The kill matrix shows which test killed each mutant.
  def test_class_methods_block_methods_are_mutated
    %w[redefine reload].each do |strategy|
      agg = run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb",
                         strategy: strategy, only: "ConcernPricing::ClassMethods#scaled", matrix: true)
      assert_killed(agg, "class_methods block (#{strategy})")
      agg.results.each do |r|
        assert r.kills.complete, "#{strategy}: the matrix row must run every covering test"
        assert_includes r.kills.ran.map { |_file, name, _id| name }, "ConcernClassMethodsTest#test_instance_scaled",
                        "#{strategy}: the instance twin must run against the mutant"
        assert_equal ["ConcernClassMethodsTest#test_scaled"], r.kills.killed_by.map { |_file, name, _id| name },
                     "#{strategy}: only the class method test may kill a class_methods mutant"
      end
    end
  end

  # An `included` block runs in each includer, so no constant names the owner of
  # its defs. Before, redefine loaded the mutant onto the concern and it falsely survived.
  def test_included_block_methods_are_unplaceable_under_redefine
    redefine = run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb", only: "ConcernPricing#doubled")
    assert_operator redefine.unplaceable_count, :>, 0
    assert_equal 0, redefine.survived_count + redefine.errored_count + redefine.killed_count + redefine.uncapturable_count
  end

  # #256: like ActiveSupport, the stub rejects a second `included` block from
  # another file, and reload loads each mutant from a temp file. Before the
  # fix every mutant in the concern file errored with MultipleIncludedBlocks.
  def test_concern_body_and_class_methods_are_mutated_under_reload
    assert_killed(run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb",
                               strategy: "reload", only: "ConcernPricing#halved"), "concern body under reload")
    assert_killed(run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb",
                               strategy: "reload", only: "ConcernPricing::ClassMethods#scaled"),
                  "class_methods block under reload")
  end

  # #297: the `included` block does not run again in a class that already
  # includes the concern (#256). Reload stores the mutated def before the hook
  # call and loads it into each class that has the method, so it is killed.
  def test_included_block_methods_are_killed_under_reload
    assert_killed(run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb",
                               strategy: "reload", only: "ConcernPricing#doubled"), "included block under reload")
  end

  # #297: the same for a `prepended` block.
  def test_prepended_block_methods_are_killed_under_reload
    assert_killed(run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb",
                               strategy: "reload", only: "ConcernWrapping#tripled"), "prepended concern body")
    assert_killed(run_redefine("concern_class_methods.rb", "concern_class_methods_test.rb",
                               strategy: "reload", only: "ConcernWrapping#decremented"), "prepended block under reload")
  end

  # #297: the hosts load in the parent, so each one already has the method when
  # the mutant loads. Every kind of host kills the mutant: a named class, an
  # anonymous class, a class through a plain module, and a class built later.
  def test_hook_block_mutants_reach_every_includer
    agg = run_redefine("hook_edges.rb", "hook_edges_test.rb", strategy: "reload", only: "HookEdges#bumped",
                                                              require_paths: ["hook_edges_hosts.rb"], matrix: true)
    assert_killed(agg, "hook block, every includer")
    agg.results.select(&:killed?).each do |result|
      names = result.kills.killed_by.map { |entry| entry[1].split("#").last }
      assert_empty %w[test_named_host test_anonymous_host test_mixin_host test_lazy_host
                      test_wrapped_host test_singleton_class_host] - names,
                   "#{result.mutation.operator}: #{names.inspect}"
    end
  end

  # #297: a `def self.`, a `class << self` def and a private def are placed too.
  def test_hook_block_singleton_and_private_defs_are_killed_under_reload
    %w[HookEdges.made HookEdges.tagged HookEdges#secret].each do |name|
      agg = run_redefine("hook_edges.rb", "hook_edges_test.rb", strategy: "reload", only: name,
                                                              require_paths: ["hook_edges_hosts.rb"], matrix: true)
      assert_killed(agg, name)
      expected = name == "HookEdges#secret" ? "test_wrapped_private_def" : "test_wrapped_singleton_defs"
      agg.results.select(&:killed?).each do |result|
        names = result.kills.killed_by.map { |entry| entry[1].split("#").last }
        assert_includes names, expected, name
      end
    end
  end

  # #297, the false-kill guard: a mutant that changes nothing must survive. The
  # block's other statements do not run again, the override keeps its own
  # method, and each def keeps its visibility.
  def test_equivalent_hook_block_mutants_survive
    source_file = File.join(ROOT, "test/fixtures/singleton/hook_edges.rb")
    require File.join(ROOT, "test/fixtures/singleton/hook_edges_hosts.rb")
    source = File.read(source_file)
    subjects = Mutineer::Project.discover([source_file]).select(&:reload_hook_call)
    assert_equal %w[HookEdges#bumped HookEdges.made HookEdges.tagged HookEdges#secret HookEdges#revealed],
                 subjects.map(&:qualified_name)
    tests = [File.join(ROOT, "test/fixtures/singleton/hook_edges_test.rb")]
    subjects.each do |subject|
      body = subject.body_loc
      mutation = Mutineer::Mutation.new(start_offset: body.start_offset, end_offset: body.end_offset,
                                        replacement: body.slice, operator: "equivalent")
      result = Mutineer::Isolation.run do
        code, hook_def = Mutineer::JobPlan.hook_mutant(mutation.apply(source), mutation, subject, source)
        Mutineer::Isolation.apply_whole_file(code, source_file)
        Mutineer::ConcernBlocks.place_hook_def(source_file: source_file, **hook_def)
        Mutineer::TestRunners.for("minitest").run(tests, stop_at_first_failure: true)
      end
      assert_equal :survived, result.status, subject.qualified_name
    end
  end

  # Parity control — this form already worked; it must keep working.
  def test_def_self_methods_are_mutated
    assert_killed(run_redefine("def_self.rb", "def_self_test.rb"), "def self.")
  end
end
