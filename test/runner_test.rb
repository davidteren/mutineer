# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
# Pre-require the fixture (R5/KTD4): with it already in $LOADED_FEATURES, the
# test files' `require_relative "calculator"` is a no-op in the child, so the
# child's `load(tempfile)` of the MUTATED source is not clobbered.
require_relative "fixtures/calculator"

class RunnerTest < Minitest::Test
  ROOT        = File.expand_path("..", __dir__)
  CALC        = File.expand_path("fixtures/calculator.rb", __dir__)
  STRONG_TEST = File.expand_path("fixtures/calculator_strong_test.rb", __dir__)
  WEAK_TEST   = File.expand_path("fixtures/calculator_weak_test.rb", __dir__)

  # The `+` in `add`'s body `a + b`. Offsets derived from content (not magic
  # numbers) so the test survives whitespace changes in the fixture.
  def plus_mutation(replacement: "-")
    source = File.read(CALC)
    plus = source.index("a + b") + 2 # skip "a "
    Mutineer::Mutation.new(start_offset: plus, end_offset: plus + 1,
                         replacement: replacement, operator: :arithmetic)
  end

  # A CoverageMap built over the fixture and the given test file(s), cached in a
  # throwaway dir so the run is real (Phase A subprocess) but leaves no trace.
  def coverage_map(*test_paths)
    Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: test_paths,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    ).build_or_load
  end

  def test_mutation_killed_by_strong_suite
    result = Mutineer::Runner.run(plus_mutation, source_file: CALC, coverage_map: coverage_map(STRONG_TEST))
    assert_predicate result, :killed?, "expected killed, got #{result.status} (#{result.details})"
  end

  def test_mutation_survives_weak_suite
    result = Mutineer::Runner.run(plus_mutation, source_file: CALC, coverage_map: coverage_map(WEAK_TEST))
    assert_predicate result, :survived?, "expected survived, got #{result.status} (#{result.details})"
  end

  def test_syntactically_invalid_mutation_is_skipped
    # Replacing `+` with `)` makes `a ) b` — unparseable, so no fork happens.
    result = Mutineer::Runner.run(plus_mutation(replacement: ")"),
                                source_file: CALC, coverage_map: coverage_map(STRONG_TEST))
    assert_predicate result, :skipped?, "expected skipped, got #{result.status}"
  end

  # --since restricts the job list to mutations on changed lines. Deterministic:
  # stub ChangedLines.for (no real git) so only line 5 (`a + b`) is "changed",
  # then assert filter_since keeps only line-5 jobs and drops the rest.
  def test_filter_since_keeps_only_jobs_on_changed_lines
    config = Mutineer::Config.new(sources: [CALC], project_root: ROOT, since: "HEAD~1")
    source_map = { CALC => File.read(CALC) }
    jobs = build_jobs(config, source_map)

    lines = jobs.map { |_s, m| line_of(m, source_map[CALC]) }.uniq
    assert_includes lines, 5
    assert_operator lines.length, :>, 1, "fixture should yield mutations on several lines"

    Mutineer::ChangedLines.stub(:for, { CALC => Set[5] }) do
      kept = Mutineer::Runner.filter_since(jobs, source_map, config)
      assert kept.length.positive?, "line 5 mutations should survive"
      assert kept.length < jobs.length, "off-line mutations should be filtered out"
      assert(kept.all? { |_s, m| line_of(m, source_map[CALC]) == 5 })
    end
  end

  def test_filter_since_file_absent_from_diff_yields_no_jobs
    config = Mutineer::Config.new(sources: [CALC], project_root: ROOT, since: "HEAD~1")
    source_map = { CALC => File.read(CALC) }
    jobs = build_jobs(config, source_map)

    Mutineer::ChangedLines.stub(:for, {}) do
      assert_empty Mutineer::Runner.filter_since(jobs, source_map, config)
    end
  end

  # #7: --rails with an unset RAILS_ENV defaults to "test"; explicit is respected.
  def test_ensure_rails_env_defaults_to_test_when_unset
    with_rails_env(nil) do
      Mutineer::Runner.ensure_rails_env(Mutineer::Config.new(rails: true))
      assert_equal "test", ENV.fetch("RAILS_ENV")
    end
  end

  def test_ensure_rails_env_respects_explicit_value
    with_rails_env("staging") do
      Mutineer::Runner.ensure_rails_env(Mutineer::Config.new(rails: true))
      assert_equal "staging", ENV.fetch("RAILS_ENV")
    end
  end

  def test_ensure_rails_env_noop_without_rails
    with_rails_env(nil) do
      Mutineer::Runner.ensure_rails_env(Mutineer::Config.new(rails: false))
      assert_nil ENV["RAILS_ENV"]
    end
  end

  # #8: reconnect decision predicate — proven WITHOUT Rails via injected doubles.
  # A plain object exposing connection_pool (active_connection?) and connection
  # (open_transactions) stands in for ActiveRecord::Base.
  Pool = Struct.new(:active)        { def active_connection? = active }
  Conn = Struct.new(:open_txns)     { def open_transactions = open_txns }
  Base = Struct.new(:connection_pool, :connection)

  def fto?(base) = Mutineer::Runner.send(:fixture_transaction_open?, base)

  # open_transactions == 1, active -> true (reconnect skips the clear, preserving
  # the fixture transaction so write-heavy tests keep their fixture rows).
  def test_fixture_transaction_open_when_active_and_in_transaction
    assert fto?(Base.new(Pool.new(true), Conn.new(1)))
  end

  # open_transactions == 0, active -> false (clear runs; v0.2 write-safety intact).
  def test_fixture_transaction_not_open_when_no_transaction
    refute fto?(Base.new(Pool.new(true), Conn.new(0)))
  end

  # no active connection -> false (nothing to preserve; clear).
  def test_fixture_transaction_not_open_when_no_active_connection
    refute fto?(Base.new(Pool.new(false), Conn.new(1)))
  end

  # probe raises -> false (safe default = clear, existing behaviour).
  def test_fixture_transaction_open_safe_defaults_to_false_on_error
    boom = Object.new
    def boom.connection_pool = raise("no pool")
    refute fto?(boom)
  end

  private

  def with_rails_env(value)
    orig = ENV["RAILS_ENV"]
    value.nil? ? ENV.delete("RAILS_ENV") : (ENV["RAILS_ENV"] = value)
    yield
  ensure
    orig.nil? ? ENV.delete("RAILS_ENV") : (ENV["RAILS_ENV"] = orig)
  end

  def line_of(mutation, source)
    source.byteslice(0, mutation.start_offset).count("\n") + 1
  end

  def build_jobs(config, source_map)
    klass = Mutineer::MutatorRegistry.resolve(["arithmetic"]).first
    jobs = []
    Mutineer::Project.discover(config.sources).each do |subject|
      source = source_map[subject.file]
      klass.new.mutations_for(subject, source).each { |m| jobs << [subject, m] }
    end
    jobs
  end
end
