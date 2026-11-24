# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# A mutant in a nested method under `redefine`. The test calls an enclosing
# method, and that call defines the inner method again from the enclosing
# method's body. So redefine also loads the mutated text into each enclosing
# method, and the mutant gets the same verdict as under `reload` (#290).
class NestedRedefineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_strategy(strategy, fixture = "nested", test = "#{fixture}_test")
    Dir.mktmpdir("mutineer-cache") do |cache_dir|
      config = Mutineer::Config.new(
        sources: ["test/fixtures/#{fixture}.rb"], tests: ["test/fixtures/#{test}.rb"],
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

  def test_redefine_kills_the_nested_mutant
    agg = run_strategy("redefine")
    assert_equal [1, 0], [agg.killed_count, agg.survived_count]
  end

  # `c` sits in `b` in `a`, and the test calls `b`, which already exists. Only
  # loading every enclosing level, not just the outermost, kills the mutant.
  def test_redefine_and_reload_agree_on_a_deeply_nested_mutant
    %w[reload redefine].each do |strategy|
      agg = run_strategy(strategy, "nested_deep")
      assert_equal [1, 0], [agg.killed_count, agg.survived_count], strategy
    end
  end

  # The test calls `a` first, which defines `b` again from `a`'s body. Only
  # loading the outermost level too, not just the immediate one, kills it.
  def test_redefine_and_reload_agree_when_the_test_calls_the_outermost_method
    %w[reload redefine].each do |strategy|
      agg = run_strategy(strategy, "nested_deep", "nested_deep_outer_test")
      assert_equal [1, 0], [agg.killed_count, agg.survived_count], strategy
    end
  end

  # The test calls `c` itself, without `a` or `b`. The innermost load replaces
  # `c` directly, so both strategies still kill the mutant.
  def test_redefine_and_reload_agree_when_the_test_calls_the_inner_method
    %w[reload redefine].each do |strategy|
      agg = run_strategy(strategy, "nested_deep", "nested_deep_inner_test")
      assert_equal [1, 0], [agg.killed_count, agg.survived_count], strategy
    end
  end
end
