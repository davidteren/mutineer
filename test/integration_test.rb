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

  def test_safe_navigation_survivor
    result = run_mutineer(sources: ["test/fixtures/greeting.rb"],
                          tests: ["test/fixtures/greeting_test.rb"],
                          operators: ["safe_navigation"])

    assert_equal 1, result.survived_count,
                 "Expected exactly 1 survivor from greeting.rb + greeting_test.rb"
    assert_equal 0.0, result.mutation_score

    s = result.surviving_mutants.first
    assert_equal "name_of", s.subject.name.to_s
    assert_equal :safe_navigation, s.mutation.operator
    assert_equal "&.", source_token(s)
    assert_equal ".", s.mutation.replacement
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
