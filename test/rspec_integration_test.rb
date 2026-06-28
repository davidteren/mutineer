# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# End-to-end: drive Runner.execute (standalone mode, real RSpec coverage Phase A
# + per-mutant runs) with framework: "rspec". A strong spec kills every mutant;
# a weak spec leaves a survivor — the RSpec mirror of the Minitest oracle.
class RSpecIntegrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(tests:)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/rspec/calculator.rb"], tests: tests,
      framework: "rspec", operators: ["arithmetic"],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    aggregate, = Mutineer::Runner.execute(config)
    aggregate
  end

  def test_strong_spec_kills_all_mutants
    result = run_mutineer(tests: ["test/fixtures/rspec/calculator_strong_spec.rb"])
    assert_equal 0, result.survived_count, "strong spec should kill every mutant"
    assert_equal 2, result.killed_count, "expected +->- and *->/ killed"
    assert_equal 100.0, result.mutation_score
  end

  def test_weak_spec_leaves_survivor
    result = run_mutineer(tests: ["test/fixtures/rspec/calculator_weak_spec.rb"])
    assert_equal 1, result.survived_count, "weak spec should leave the add mutant alive"
    survivor = result.surviving_mutants.first
    assert_equal "add", survivor.subject.name.to_s
    assert_equal :arithmetic, survivor.mutation.operator
  end
end
