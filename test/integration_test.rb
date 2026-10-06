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

  def run_mutineer(sources:, tests:, operators: nil, matrix: false)
    config = Mutineer::Config.new(
      sources: sources, tests: tests, operators: operators, matrix: matrix,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    aggregate, = Mutineer::Runner.execute(config)
    aggregate
  end

  def source_token(result)
    src = File.read(File.expand_path(result.subject.file, ROOT))
    src[result.mutation.start_offset...result.mutation.end_offset]
  end

  # One operator, one fixture pair, and exactly one survivor that nothing kills.
  def assert_sole_survivor(source:, test:, operator:, subject:, token:, replacement:)
    result = run_mutineer(sources: [source], tests: [test], operators: [operator.to_s])

    assert_equal 1, result.survived_count,
                 "Expected exactly 1 survivor from #{File.basename(source)} + #{File.basename(test)}"
    assert_equal 0.0, result.mutation_score

    s = result.surviving_mutants.first
    assert_equal subject, s.subject.name.to_s
    assert_equal operator, s.mutation.operator
    assert_equal token, source_token(s)
    assert_equal replacement, s.mutation.replacement
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
    assert_sole_survivor(source: "test/fixtures/greeting.rb", test: "test/fixtures/greeting_test.rb",
                         operator: :safe_navigation, subject: "name_of", token: "&.", replacement: ".")
  end

  def test_range_survivor
    assert_sole_survivor(source: "test/fixtures/steps.rb", test: "test/fixtures/steps_test.rb",
                         operator: :range, subject: "upto", token: "..", replacement: "...")
  end

  def test_negation_removal_survivor
    assert_sole_survivor(source: "test/fixtures/access.rb", test: "test/fixtures/access_test.rb",
                         operator: :negation_removal, subject: "guest?", token: "!", replacement: "")
  end

  def test_chain_link_survivor
    result = run_mutineer(sources: ["test/fixtures/roster.rb"],
                          tests: ["test/fixtures/roster_test.rb"],
                          operators: ["chain_link"])

    assert_equal 1, result.survived_count,
                 "Expected exactly 1 survivor from roster.rb + roster_test.rb"
    assert_equal 50.0, result.mutation_score

    s = result.surviving_mutants.first
    assert_equal "active_names", s.subject.name.to_s
    assert_equal :chain_link, s.mutation.operator
    assert_equal ".select(&:active)", source_token(s)
    assert_equal "", s.mutation.replacement
  end

  def test_operand_removal_survivor
    result = run_mutineer(sources: ["test/fixtures/discount.rb"],
                          tests: ["test/fixtures/discount_test.rb"],
                          operators: ["operand_removal"])

    assert_equal 1, result.survived_count,
                 "Expected exactly 1 survivor from discount.rb + discount_test.rb"
    assert_equal 50.0, result.mutation_score

    s = result.surviving_mutants.first
    assert_equal "eligible?", s.subject.name.to_s
    assert_equal :operand_removal, s.mutation.operator
    assert_equal "member && total >= 100", source_token(s)
    assert_equal "(member)", s.mutation.replacement
  end

  def test_array_literal_survivor
    assert_sole_survivor(source: "test/fixtures/tags.rb", test: "test/fixtures/tags_test.rb",
                         operator: :array_literal, subject: "defaults", token: "%w[ruby rails]", replacement: "[]")
  end

  def test_condition_forcing_survivor
    result = run_mutineer(sources: ["test/fixtures/shipping.rb"],
                          tests: ["test/fixtures/shipping_test.rb"],
                          operators: %w[condition_true condition_false])

    assert_equal 1, result.survived_count,
                 "Expected exactly 1 survivor from shipping.rb + shipping_test.rb"
    assert_equal 50.0, result.mutation_score

    s = result.surviving_mutants.first
    assert_equal "fee", s.subject.name.to_s
    assert_equal :condition_false, s.mutation.operator
    assert_equal "total >= 100", source_token(s)
    assert_equal "(false)", s.mutation.replacement
  end

  def test_operator_assignment_survivor
    assert_sole_survivor(source: "test/fixtures/tally.rb", test: "test/fixtures/tally_test.rb",
                         operator: :operator_assignment, subject: "sum", token: "+=", replacement: "-=")
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

  # --- kill matrix (--matrix) oracle -----------------------------------------
  # calculator.rb against the weak and the strong suite together. The weak
  # add/subtract tests use a 0 operand, so they kill nothing (blind). Both
  # suites kill multiply, divide, modulo and power, so each of those eight
  # tests is redundant on its own. Only the strong add/subtract tests kill the
  # add and subtract mutants.
  CALC_TESTS = ["test/fixtures/calculator_weak_test.rb", "test/fixtures/calculator_strong_test.rb"].freeze

  def weak(name) = ["test/fixtures/calculator_weak_test.rb", "CalculatorWeakTest##{name}", "CalculatorWeakTest##{name}"]
  def strong(name) = ["test/fixtures/calculator_strong_test.rb", "CalculatorStrongTest##{name}",
                      "CalculatorStrongTest##{name}"]

  def test_kill_matrix_oracle
    result = run_mutineer(sources: ["test/fixtures/calculator.rb"], tests: CALC_TESTS,
                          operators: ["arithmetic"], matrix: true)
    matrix = Mutineer::KillMatrix.new(result.results)

    assert_equal 6, matrix.rows.size
    assert_predicate matrix, :complete?
    assert_equal 12, matrix.tests.size
    assert_equal [weak("test_add"), weak("test_subtract")], matrix.blind
    expected = %w[test_divide test_modulo test_multiply test_power]
    assert_equal (expected.map { |n| strong(n) } + expected.map { |n| weak(n) }).sort, matrix.redundant

    add = result.results.find { |r| r.subject.name == :add }
    assert_equal [strong("test_add")], add.kills.killed_by
    assert_equal 12, add.kills.ran.size
  end

  # The matrix annotates verdicts and never decides them: every mutant gets the
  # same status with and without --matrix, so the score is the same.
  def test_matrix_leaves_every_verdict_unchanged
    [["test/fixtures/calculator_weak_test.rb"], CALC_TESTS].each do |tests|
      plain = run_mutineer(sources: ["test/fixtures/calculator.rb"], tests: tests)
      matrix = run_mutineer(sources: ["test/fixtures/calculator.rb"], tests: tests, matrix: true)

      assert_equal plain.results.to_h { |r| [r.id, r.status] }, matrix.results.to_h { |r| [r.id, r.status] }
      assert_equal plain.mutation_score, matrix.mutation_score
      assert(plain.results.none?(&:kills))
      assert(matrix.results.select { |r| r.killed? || r.survived? }.all?(&:kills))
    end
  end


  # --- regressions from the review of the first --matrix cut ------------------

  def statuses(aggregate) = aggregate.results.to_h { |r| [r.id, r.status] }
  def names(tests) = tests.map { |_file, name, _id| name }

  # A test fails, then the next test exits the process with status 0. The run
  # without --matrix stops at the failure and scores the mutant killed, and so
  # must the matrix: the exit is past the point where the verdict was decided.
  def test_matrix_keeps_a_kill_that_a_later_exit_would_erase
    sources = ["test/fixtures/matrix/gate.rb"]
    tests = ["test/fixtures/matrix/gate_test.rb"]
    plain = run_mutineer(sources: sources, tests: tests)
    matrix = run_mutineer(sources: sources, tests: tests, matrix: true)

    assert_equal statuses(plain), statuses(matrix)
    assert_equal plain.mutation_score, matrix.mutation_score
    big = matrix.results.find { |r| r.subject.name == :big? }
    assert_predicate big, :killed?
    assert_equal ["MatrixGateTest#test_a_boundary"], names(big.kills.killed_by)
    refute big.kills.complete, "the suite never returned, so the row cannot be complete"
  end

  # Setup errors, a skip, an error, a blind test, a module included in two
  # classes, and a parallel class, in one suite.
  def test_matrix_on_a_mixed_suite
    sources = ["test/fixtures/matrix/acct.rb"]
    tests = ["test/fixtures/matrix/acct_test.rb"]
    plain = run_mutineer(sources: sources, tests: tests)
    matrix = run_mutineer(sources: sources, tests: tests, matrix: true)
    km = Mutineer::KillMatrix.new(matrix.results)

    assert_equal statuses(plain), statuses(matrix)
    assert_equal 16, km.tests.size
    refute_includes names(km.tests), "MatrixAcctSetupTest#test_skipped"
    shared = km.tests.select { |_file, name, _id| name.end_with?("#test_shared_deposit") }
    assert_equal %w[MatrixAcctA#test_shared_deposit MatrixAcctB#test_shared_deposit], names(shared)
    assert_equal ["test/fixtures/matrix/support/shared_tests.rb"], shared.map(&:first).uniq
    assert_equal %w[MatrixAcctParallel#test_p0 MatrixAcctSetupTest#test_blind], names(km.blind)
    fee = matrix.results.select { |r| r.subject.name == :fee }.flat_map { |r| names(r.kills.killed_by) }
    assert_includes fee, "MatrixAcctSetupTest#test_errors_on_mutant"
  end

  # Minitest runs a serial class first, so a kill there still stops the run
  # without --matrix; the parallel class loaded beside it must not turn the
  # matrix run into one that keeps the exit status.
  def test_matrix_keeps_a_serial_kill_in_a_suite_that_also_has_a_parallel_class
    sources = ["test/fixtures/matrix/gate.rb"]
    tests = ["test/fixtures/matrix/gate_mixed_test.rb"]
    plain = run_mutineer(sources: sources, tests: tests)
    matrix = run_mutineer(sources: sources, tests: tests, matrix: true)

    assert_equal statuses(plain), statuses(matrix)
    big = matrix.results.find { |r| r.subject.name == :big? }
    assert_predicate big, :killed?
    refute big.kills.complete
  end

  # Minitest catches an Interrupt in a test and returns after the tests so far,
  # so a returned run proves nothing: the row must not claim every test ran.
  def test_matrix_row_is_incomplete_when_an_interrupt_cut_the_run_short
    sources = ["test/fixtures/matrix/gate.rb"]
    tests = ["test/fixtures/matrix/gate_interrupt_test.rb"]
    matrix = run_mutineer(sources: sources, tests: tests, matrix: true)
    big = matrix.results.find { |r| r.subject.name == :big? }

    assert_predicate big, :killed?
    refute big.kills.complete
  end

end
