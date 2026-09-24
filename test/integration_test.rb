# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# End-to-end acceptance gate: run Mutineer against the fixtures via the library API
# (no CLI subprocess) and assert the EXACT survivor set. These fixtures are the
# spec's correctness oracle (spec §12) — if an assertion here fails, selection or
# execution is broken, not the test.
class IntegrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(sources:, tests:, operators: nil)
    config = Mutineer::Config.new(
      sources: sources, tests: tests, operators: operators,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    aggregate, = Mutineer::Runner.execute(config)
    aggregate
  end

  def source_token(result)
    src = File.read(File.expand_path(result.subject.file, ROOT))
    src[result.mutation.start_offset...result.mutation.end_offset]
  end

  # Scenario A — pricing boundary survivor (R9)
  def test_pricing_boundary_survivor
    result = run_mutineer(sources: ["test/fixtures/pricing.rb"],
                        tests: ["test/fixtures/pricing_test.rb"])

    assert_equal 1, result.survived_count,
                 "Expected exactly 1 survivor from pricing.rb + pricing_test.rb"
    assert_equal 50.0, result.mutation_score

    s = result.surviving_mutants.first
    assert_equal "Pricing", s.subject.namespace.last
    assert_equal "total", s.subject.name.to_s
    assert_equal :comparison, s.mutation.operator
    assert_equal ">=", source_token(s)
    assert_equal ">", s.mutation.replacement
  end

  # Scenario B — calculator + strong, perfect score (R10)
  def test_calculator_strong_kills_all
    result = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_strong_test.rb"])

    assert_equal 0, result.survived_count, "Expected 0 survivors with strong test"
    assert_equal 100.0, result.mutation_score, "Expected 100% mutation score"
    assert_equal 6, result.killed_count, "Expected 6 killed mutations"
  end

  # Scenario C — calculator + weak, exactly two survivors (R11)
  def test_calculator_weak_leaves_two
    result = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_weak_test.rb"])

    assert_equal 2, result.survived_count, "Expected exactly 2 survivors with weak test"

    add_s = result.surviving_mutants.find { |r| r.subject.name.to_s == "add" }
    sub_s = result.surviving_mutants.find { |r| r.subject.name.to_s == "subtract" }

    refute_nil add_s, "Expected Calculator#add + -> - to survive"
    assert_equal :arithmetic, add_s.mutation.operator
    assert_equal "+", source_token(add_s)
    assert_equal "-", add_s.mutation.replacement

    refute_nil sub_s, "Expected Calculator#subtract - -> + to survive"
    assert_equal :arithmetic, sub_s.mutation.operator
    assert_equal "-", source_token(sub_s)
    assert_equal "+", sub_s.mutation.replacement

    assert_equal 4, result.killed_count, "Expected multiply, divide, modulo, power killed"
    refute result.surviving_mutants.any? { |r| r.subject.name.to_s == "multiply" }
    refute result.surviving_mutants.any? { |r| r.subject.name.to_s == "divide" }
  end

  # A test that reopens $stdout (Minitest's capture_subprocess_io) must see the
  # same verdicts as the plain weak suite: no "not green" abort, no false kills.
  def test_suite_that_reopens_stdout_scores_like_weak_suite
    result = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_subprocess_io_test.rb"])

    assert_equal 2, result.survived_count
    assert_equal 4, result.killed_count
    assert_equal %w[add subtract], result.surviving_mutants.map { |r| r.subject.name.to_s }.sort
  end

  # A warm cache re-checks the clean suite in a separate script; that check must
  # also keep $stdout a real IO.
  def test_suite_that_reopens_stdout_scores_like_weak_suite_on_warm_cache
    cache = Dir.mktmpdir("mutineer-cache")
    run = lambda do
      config = Mutineer::Config.new(
        sources: ["test/fixtures/calculator.rb"],
        tests: ["test/fixtures/calculator_subprocess_io_test.rb"],
        cache_dir: cache, project_root: ROOT
      )
      Mutineer::Runner.execute(config).first
    end

    run.call
    assert File.exist?(File.join(cache, "coverage.json")), "first run must leave a cache for the second"
    result = run.call

    assert_equal 2, result.survived_count
    assert_equal 4, result.killed_count
  end

  # A test file that leaves $stdout as a StringIO (at load time and inside a
  # test) must not break the silencing that the reopen fix added.
  def test_suite_that_swaps_stdout_for_a_stringio_scores_like_weak_suite
    result = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_stdout_swap_test.rb"])

    assert_equal 2, result.survived_count
    assert_equal 4, result.killed_count
  end

  # A test file that prints at load time must not corrupt the coverage result
  # that the capture subprocess sends back, so no mutant becomes unscoreable.
  def test_suite_that_prints_at_load_time_scores_like_weak_suite
    result = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_load_time_puts_test.rb"])

    assert_equal 2, result.survived_count
    assert_equal 4, result.killed_count
    assert_equal %w[add subtract], result.surviving_mutants.map { |r| r.subject.name.to_s }.sort
  end

  # #97: changing only a required helper must not leave a stale no_coverage
  # verdict. Cached and fresh runs report the same survivor.
  def test_helper_change_matches_fresh_coverage
    Dir.mktmpdir("mutineer-helper-int") do |dir|
      src    = File.join(dir, "calculator.rb")
      test   = File.join(dir, "calculator_test.rb")
      helper = File.join(dir, "test_helper.rb")
      cache  = File.join(dir, "cache")
      File.write(src, <<~RUBY)
        class AuditIntCacheCalculator
          def compute(value)
            if value == 1
              1 + 2
            else
              4 + 5
            end
          end
        end
      RUBY
      File.write(test, <<~RUBY)
        require_relative "test_helper"
        require_relative "calculator"
        class AuditIntCacheCalculatorTest < Minitest::Test
          def test_compute
            AuditIntCases::VALUES.each do |value|
              result = AuditIntCacheCalculator.new.compute(value)
              value == 1 ? assert_equal(3, result) : refute_nil(result)
            end
          end
        end
      RUBY
      write_helper = lambda do |values|
        File.write(helper, "require 'minitest/autorun'\nmodule AuditIntCases\n  VALUES = #{values.inspect}\nend\n")
      end
      run = lambda do
        Mutineer::Config.new(
          sources: [src], tests: [test], operators: ["arithmetic"],
          cache_dir: cache, project_root: dir, jobs: 1
        ).then { |c| Mutineer::Runner.execute(c).first }
      end

      write_helper.call([1])
      first = run.call
      assert_equal 100.0, first.mutation_score
      assert_equal 1, first.no_coverage_count

      write_helper.call([1, 2])
      cached = run.call
      FileUtils.rm_rf(cache)
      fresh = run.call
      assert_equal fresh.survived_count, cached.survived_count
      assert_equal fresh.no_coverage_count, cached.no_coverage_count
      assert_equal 1, cached.survived_count
      assert_equal 0, cached.no_coverage_count
      assert_equal 50.0, cached.mutation_score
    end
  end

  # R2 — operator restriction
  def test_operators_flag_restricts_set
    result = run_mutineer(sources: ["test/fixtures/pricing.rb"],
                        tests: ["test/fixtures/pricing_test.rb"],
                        operators: ["arithmetic"])
    # Only the arithmetic *->/ mutation; the comparison >=->> survivor is absent.
    assert_equal 0, result.survived_count
    assert_equal 1, result.killed_count
  end
end
