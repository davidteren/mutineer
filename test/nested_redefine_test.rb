# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Pins a known limit of `redefine` for a nested method. `redefine` loads only
# the mutated inner method, but the test calls the outer method, and that call
# defines the original inner method again. So the mutant survives, although
# the test kills it under `reload`.
class NestedRedefineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_strategy(strategy)
    Dir.mktmpdir("mutineer-cache") do |cache_dir|
      config = Mutineer::Config.new(
        sources: ["test/fixtures/nested.rb"], tests: ["test/fixtures/nested_test.rb"],
        operators: ["arithmetic"], strategy: strategy,
        cache_dir: cache_dir, project_root: ROOT
      )
      Mutineer::Runner.execute(config).first
    end
  end

  def test_reload_kills_the_nested_mutant
    agg = run_strategy("reload")
    assert_equal [1, 0], [agg.killed_count, agg.survived_count]
  end

  def test_redefine_lets_the_nested_mutant_survive
    agg = run_strategy("redefine")
    assert_equal [0, 1], [agg.killed_count, agg.survived_count]
  end
end
