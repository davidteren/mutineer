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

  def run_redefine(source, test)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/singleton/#{source}"],
      tests: ["test/fixtures/singleton/#{test}"],
      strategy: "redefine",
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

  # Parity control — this form already worked; it must keep working.
  def test_def_self_methods_are_mutated
    assert_killed(run_redefine("def_self.rb", "def_self_test.rb"), "def self.")
  end
end
