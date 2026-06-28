# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Proves boot mode end to end WITHOUT Rails/DB: the parent starts Coverage,
# requires a plain boot file once (loading Widget), captures per-test coverage by
# forking the booted parent, then runs only the covering test files per mutant —
# the same coverage selection standalone mode uses.
class BootModeTest < Minitest::Test
  BOOT   = File.expand_path("fixtures/boot", __dir__)
  APP    = File.join(BOOT, "app_boot.rb")
  SRC    = File.join(BOOT, "widget.rb")
  STRONG = File.join(BOOT, "widget_strong_test.rb")
  WEAK   = File.join(BOOT, "widget_weak_test.rb")
  FAILING = File.join(BOOT, "widget_unrelated_failing_test.rb")

  def run_boot(*test_files, cache_dir:)
    config = Mutineer::Config.new(
      sources: [SRC], tests: test_files, boot: APP,
      strategy: "redefine", project_root: BOOT, cache_dir: cache_dir, jobs: 1
    )
    Mutineer::Runner.execute(config).first
  end

  def test_strong_suite_kills_every_covered_mutant
    Dir.mktmpdir("mutineer-boot") do |cache|
      agg = run_boot(STRONG, cache_dir: cache)

      assert_operator agg.killed_count, :>, 0, "strong suite should kill mutants"
      assert_empty agg.surviving_mutants, "strong suite should leave no survivors"
      assert_in_delta 100.0, agg.mutation_score, 0.0001

      # Boot mode now selects via coverage: #discount has no covering test, so its
      # mutants are :no_coverage (not survived) — proof selection ran.
      assert_operator agg.no_coverage_count, :>, 0,
                      "uncovered #discount should produce no_coverage mutants"
      assert_path_exists File.join(cache, "coverage.json"),
                         "boot mode should write a coverage cache"
    end
  end

  def test_weak_suite_leaves_a_survivor
    Dir.mktmpdir("mutineer-boot") do |cache|
      agg = run_boot(WEAK, cache_dir: cache)

      assert_operator agg.surviving_mutants.size, :>, 0, "weak suite should leave a survivor"
      assert_operator agg.killed_count, :>, 0
      assert_operator agg.mutation_score, :<, 100.0
      assert_operator agg.no_coverage_count, :>, 0
    end
  end

  # Direct proof: every mutation on the uncovered #discount method is :no_coverage
  # in boot mode (with run-all they would have SURVIVED, since no test checks it).
  def test_uncovered_method_is_no_coverage
    Dir.mktmpdir("mutineer-boot") do |cache|
      agg = run_boot(STRONG, cache_dir: cache)
      discount = agg.results.select { |r| r.subject.name == :discount }

      refute_empty discount, "fixture should generate #discount mutants"
      assert(discount.all?(&:no_coverage?),
             "uncovered method must be no_coverage, got #{discount.map(&:status).uniq}")
    end
  end

  # Selection isolates per mutant: given the covering weak suite AND an unrelated
  # always-failing test, only the covering one runs — so the weak survivor still
  # survives. If all --test files ran per mutant, the failing test would kill it.
  def test_only_covering_test_runs_when_multiple_given
    Dir.mktmpdir("mutineer-boot") do |cache|
      agg = run_boot(WEAK, FAILING, cache_dir: cache)

      assert_operator agg.surviving_mutants.size, :>, 0,
                      "unrelated failing test must not be selected for covered mutants"
    end
  end

  # The AR reconnect hook is a guarded no-op when ActiveRecord is absent (as here).
  def test_reconnect_active_record_is_noop_without_active_record
    refute defined?(ActiveRecord::Base), "this test assumes AR is not loaded"
    Mutineer::Runner.send(:reconnect_active_record) # must not raise
  end
end
